# frozen_string_literal: true

require 'cgi'

require_relative '../capabilities'
require_relative '../document_request'
require_relative '../page_furniture'
require_relative '../failure'
require_relative '../result'
require_relative '../readiness'
require_relative '../registry'
require_relative '../process_pool'
require_relative 'cdp_client'

module RedmineReporterDashboards
  module Render
    module Engines
      # `:chromium_cdp` — the reference engine, and the default.
      #
      # Headless Chromium in a SEPARATE PROCESS, never inside a Puma worker. That is not
      # a performance preference. A resident browser inside the application process is a
      # browser that shares the application's memory limits, its crash domain and its
      # lifetime; `ferrum`-in-Puma was rejected for exactly this, plus the part nobody
      # notices until it bites — a self-updating Chrome whose rendering changes between
      # two `apt upgrade` runs with no plugin release involved.
      #
      # --- WHAT THIS ADAPTER IS NOT ALLOWED TO DO ---
      #
      #   no listening port      the control channel is a pipe (see CdpClient)
      #   no name resolution     --host-resolver-rules=MAP * 0.0.0.0
      #   no --no-sandbox        so Chromium itself enforces "not as root"
      #   no fetching            the document arrives complete; assets are inline
      #
      # The last one is the load-bearing invariant, INV-8: the renderer is never the
      # thing holding the network. Everything else on this list is defence in depth
      # behind it.
      #
      # --- VERSION IS PROBED, NEVER A CONSTANT ---
      #
      # From `Browser.getVersion` on the live process. A constant would be a claim about
      # a binary this code has never met, and the stamp exists precisely so that a PDF
      # someone opens in six months can say which build drew it.
      class ChromiumCdp
        ID = :chromium_cdp

        # Matches `config/capabilities.yml`, and the conformance suite asserts they are
        # equal rather than trusting that they look it. Two spellings of one fact is a
        # drift waiting to happen unless something compares them.
        CAPABILITIES = %i[
          javascript readiness_expression print_backgrounds header footer
          page_furniture_tokens custom_page_size landscape margins scale
          page_break_css media_print outline tagged_pdf pdf_metadata
          asset_inline timeout
        ].freeze

        # Points per inch, and millimetres per inch. Chromium's printToPDF speaks
        # INCHES, everything in `DocumentRequest` is millimetres, and getting this
        # conversion wrong produces a page that still looks plausible until somebody
        # measures it — which is what conformance fixture F-03 is for.
        MM_PER_INCH = 25.4

        PAGE_SIZES_MM = {
          'A3' => [297, 420], 'A4' => [210, 297], 'A5' => [148, 210],
          'Letter' => [215.9, 279.4], 'Legal' => [215.9, 355.6],
          'Tabloid' => [279.4, 431.8]
        }.freeze

        attr_reader :binary

        def initialize(binary: nil, pool_size: nil, queue_limit: nil, queue_timeout_ms: nil,
                       extra_flags: [], logger: nil)
          @binary = binary || CdpClient.detect_binary
          @extra_flags = Array(extra_flags)
          @logger = logger
          @pool = ProcessPool.new(
            size: pool_size || ProcessPool::DEFAULT_SIZE,
            queue_limit: queue_limit || ProcessPool::DEFAULT_QUEUE_LIMIT,
            queue_timeout_ms: queue_timeout_ms || ProcessPool::DEFAULT_QUEUE_TIMEOUT_MS,
            factory: -> { CdpClient.new(binary: @binary, extra_flags: @extra_flags).start },
            stopper: ->(client) { client.stop }
          )
        end

        def id
          ID
        end

        def capabilities
          CAPABILITIES
        end

        # Memoised from whichever browser answered first. Asking the POOL for it would
        # deadlock: `render` already holds the single worker when it stamps the result,
        # and a nested checkout would wait out the queue timeout against itself. The
        # first draft did exactly that, and the symptom was a ten-second pause between
        # a finished PDF and its Success.
        def version
          return @version if @version

          @version = @pool.with_worker { |client| client.version }
        rescue StandardError => e
          "unavailable (#{e.class})"
        end

        # PREFLIGHT IS A ROUND TRIP, never `File.exist?` (technical-spec.md §5). A
        # binary that exists and cannot start — a missing shared library, a sandbox the
        # kernel will not give it, a read-only home directory — passes every check that
        # is not a render, and fails the first real report instead. So this draws a
        # document and reads the bytes back.
        def preflight
          request = DocumentRequest.new(
            body: '<!DOCTYPE html><html><body><h1>rrd preflight</h1></body></html>',
            correlation_id: 'preflight', page_size: 'A4', timeout_ms: 30_000
          )
          render(request)
        end

        def render(request)
          started = monotonic_ms
          @pool.with_worker do |client|
            @version ||= client.version
            draw(client, request, started)
          end
        rescue ProcessPool::Busy => e
          # A REFUSAL, not a hang. The caller can tell a user the report service is
          # busy; it cannot do anything useful with a request that never returns.
          failure(request, :engine_unavailable,
                  'the report service is busy; try again in a moment',
                  detail: e.message, started: started)
        rescue CdpClient::LaunchFailed => e
          failure(request, :engine_unavailable, 'the render engine could not be started',
                  detail: e.message, started: started)
        rescue CdpClient::ProtocolTimeout => e
          failure(request, :timeout, 'the report took too long to draw',
                  detail: e.message, started: started)
        rescue CdpClient::CdpError => e
          failure(request, :engine_crashed, 'the render engine failed',
                  detail: e.message, started: started)
        end

        def shutdown
          @pool.shutdown
        end

        private

        def draw(client, request, started)
          client.with_page do |page|
            page.set_content(request.body, timeout_ms: request.timeout_ms)
            state, pending = await_readiness(page, request)

            if state == :strict_timeout
              return failure(request, :readiness_timeout,
                             'the report was not finished drawing in time',
                             detail: "pending=#{pending}", started: started)
            end

            bytes = page.print_to_pdf(print_options(request), timeout_ms: request.timeout_ms)
            success(bytes, started, readiness_degradation(request, state, pending))
          end
        end

        # --- READINESS ---------------------------------------------------------
        #
        # Polled at `poll_interval_ms` against the DOM contract's JavaScript expression,
        # which this engine can evaluate. ON TIMEOUT THE ENGINE STILL RENDERS: a
        # chart-less-but-otherwise-correct document beats no document, because the
        # tables, the totals and the narrative are all there and the reader is told what
        # is missing. `strict` inverts that for the caller who would rather have nothing.
        #
        # The page's own watchdog is deliberately set to fire BEFORE this one, so in the
        # normal broken case the page has already declared itself ready and recorded
        # WHY. Reaching the branch below means the page could not answer at all.
        def await_readiness(page, request)
          readiness = request.readiness
          return [:not_requested, nil] unless readiness

          deadline = monotonic_ms + readiness.timeout_ms
          interval = readiness.poll_interval_ms / 1000.0

          loop do
            return [:ready, nil] if page.evaluate("!!(#{Readiness::EXPRESSION})")

            if monotonic_ms >= deadline
              pending = page.evaluate('(window.__rd && window.__rd.pending) || 0') || 'unknown'
              warn_line("[render] #{ID} gave up waiting after #{readiness.timeout_ms}ms " \
                        "with pending=#{pending} (correlation_id=#{request.correlation_id})")
              return [readiness.strict? ? :strict_timeout : :timeout, pending]
            end

            sleep(interval)
          end
        end

        def readiness_degradation(request, state, pending)
          return [] unless state == :timeout

          [request.readiness.on_timeout(pending: pending)].compact
        end

        # --- THE REQUEST, IN CHROMIUM'S VOCABULARY -----------------------------
        def print_options(request)
          width_mm, height_mm = PAGE_SIZES_MM.fetch(request.page_size, PAGE_SIZES_MM['A4'])
          width_mm, height_mm = height_mm, width_mm if request.landscape?

          options = {
            paperWidth: mm_to_in(width_mm),
            paperHeight: mm_to_in(height_mm),
            marginTop: mm_to_in(request.margins_mm['top']),
            marginBottom: mm_to_in(request.margins_mm['bottom']),
            marginLeft: mm_to_in(request.margins_mm['left']),
            marginRight: mm_to_in(request.margins_mm['right']),
            scale: request.scale,
            # THE DEFAULT THIS ADAPTER MUST OVERRIDE. Chromium's own is false, and
            # every badge, progress bar and alternating table row in the existing
            # templates is a CSS background. A naive pass-through produces a report
            # that is technically correct and visibly ruined, with nothing failing.
            printBackground: request.print_backgrounds,
            preferCSSPageSize: false,
            transferMode: 'ReturnAsBase64',
            generateDocumentOutline: request.outline,
            generateTaggedPDF: request.tagged
          }
          options.merge(furniture_options(request))
        end

        # Header and footer are separate mini-documents in Chromium, with their own
        # (tiny) default font size and no inherited styles. `PageFurniture` compiles to
        # them here — and this is the only place in the plugin allowed to know that
        # `<span class="pageNumber">` is how this engine spells `{{page}}`.
        def furniture_options(request)
          return { displayHeaderFooter: false } unless request.page_furniture?

          { displayHeaderFooter: true,
            headerTemplate: furniture_html(request.header),
            footerTemplate: furniture_html(request.footer) }
        end

        # An EMPTY string is not an empty header to Chromium — it falls back to its own
        # built-in title/date template. A single empty span is how you say "nothing".
        def furniture_html(furniture)
          return '<span></span>' if furniture.nil? || furniture.empty?

          slots = furniture.slots.map do |position, text|
            align = { 'left' => 'flex-start', 'center' => 'center', 'right' => 'flex-end' }[position]
            "<div style=\"flex:1;display:flex;justify-content:#{align}\">#{compile_tokens(text)}</div>"
          end

          "<div style=\"width:100%;font-size:#{furniture.font_size_pt}pt;" \
            "padding:0 10mm;display:flex;color:#444\">#{slots.join}</div>"
        end

        # The closed token set, compiled — and TWO things the first version of this
        # method got wrong, both found by conformance fixture F-04.
        #
        # 1. THE SPACES DISAPPEAR. Chromium renders the footer template as its own
        #    document, and a whitespace-only text node next to an inline element is
        #    collapsed away there: `Page {{page}} of {{pages}}` came out of the printer
        #    reading "Page1of3". Not an extraction artefact — the pixels said it too.
        #    Non-breaking spaces survive, and a footer is exactly the place where you
        #    want no wrapping anyway.
        #
        # 2. THE LITERAL TEXT WAS INTERPOLATED RAW. Slot text comes from a template
        #    author, and while authoring is already a code-execution privilege (INV-9),
        #    "already privileged" is not a licence to build one more injection point:
        #    an unescaped `<` silently breaks the footer document on every page of every
        #    report. Literal segments are escaped; only the token substitutions emit
        #    markup, and they are a closed set of five.
        def compile_tokens(text)
          parts = []
          remainder = text.to_s
          while (match = PageFurniture::TOKEN_PATTERN.match(remainder))
            parts << literal(match.pre_match) << token_markup(match[1], match[0])
            remainder = match.post_match
          end
          parts << literal(remainder)
          parts.join
        end

        def literal(fragment)
          CGI.escapeHTML(fragment).gsub(' ', '&nbsp;')
        end

        # Only `{{page}}`, `{{pages}}`, `{{title}}` and `{{date}}` have an engine-native
        # spelling. The rest of the closed set is resolved by the caller before the
        # request is built — they are facts about the render, not about the page — and
        # anything unresolved is left as literal text rather than silently dropped.
        def token_markup(name, original)
          case name
          when 'page' then '<span class="pageNumber"></span>'
          when 'pages' then '<span class="totalPages"></span>'
          when 'title' then '<span class="title"></span>'
          when 'date' then '<span class="date"></span>'
          else literal(original)
          end
        end

        def mm_to_in(millimetres)
          (millimetres.to_f / MM_PER_INCH).round(4)
        end

        # --- RESULTS -----------------------------------------------------------

        # `page_count` stays nil, deliberately. Chromium's printToPDF does not report
        # one, and counting `/Type /Page` in the bytes is a guess that happens to work
        # for Skia's output and would be wrong for any engine writing object streams. A
        # nil field is honest and a guessed one gets believed — the conformance harness
        # reads the count from `pdfinfo`, where the answer is real.
        def success(bytes, started, degradations)
          Success.new(bytes: bytes, engine: ID, engine_version: @version,
                      page_count: nil, duration_ms: (monotonic_ms - started).round,
                      degradations: degradations)
        end

        def failure(request, code, message, detail:, started:)
          Failure.new(code: code, message: message, detail: detail, engine: ID,
                      # `@version` and not `version`: probing here would start the very
                      # engine that just failed to start. `'unknown'` rather than nil
                      # because a Failure that cannot say which build produced it
                      # defeats the stamp — and a COLD adapter, one that fails before
                      # any successful probe, is exactly the case that hits this.
                      engine_version: @version || 'unknown',
                      duration_ms: (monotonic_ms - started).round,
                      correlation_id: request.correlation_id)
        end

        def warn_line(line)
          @logger.warn(line) if @logger.respond_to?(:warn)
        end

        def monotonic_ms
          Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
        end
      end

      Registry.register(ChromiumCdp::ID, ChromiumCdp)
    end
  end
end
