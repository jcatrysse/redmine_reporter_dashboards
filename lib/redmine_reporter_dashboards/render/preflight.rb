# frozen_string_literal: true

require 'json'
require 'securerandom'

require_relative 'capabilities'
require_relative 'document_request'
require_relative 'page_furniture'
require_relative 'readiness'
require_relative 'pdf_inspector'
require_relative 'renderer'
require_relative 'result'

module RedmineReporterDashboards
  module Render
    # Does the render path actually work on THIS machine? Asked by drawing a document,
    # never by looking at the filesystem.
    #
    # --- THE FAILURE THIS EXISTS TO CATCH ---
    #
    # "The container is healthy but every PDF silently loses its assets." Nothing is
    # down. The binary is present, the process starts, the bytes come back, the file
    # opens. The reports are just missing their images and their badge colours, and
    # nobody notices until somebody reads one — which, for a quarterly report, is a
    # quarter later. `File.exist?` answers yes to all of it.
    #
    # So every check here is a ROUND TRIP: a real document goes through the real engine
    # and the real post-conditions, and the answer comes back out of the PDF. Slower,
    # and the only kind of check worth having at install time.
    #
    # --- WHY THE REDMINE-HOSTED IMAGE IS AN EXPECTED FAILURE ---
    #
    # Under the default `:bundled` asset policy the renderer has no network at all —
    # that is INV-8, and it is deliberate. So a `<img src="https://redmine.example/...">`
    # CANNOT load, and the preflight says so out loud rather than hiding it. An operator
    # who was going to point a template at a Redmine-hosted logo finds out here, at
    # install time, instead of from a report with a hole in it.
    #
    # A check that is expected to fail is `:expected_failure`, not `:fail` — the two
    # must not share a colour, or the one that matters gets ignored along with the one
    # that does not.
    #
    # --- STRUCTURED OUTPUT, SO IT CAN BE ASSERTED ON ---
    #
    # `#to_h` is the artefact; the human rendering is built from it. A diagnostic that
    # exists only as log lines gets checked by grepping, and a grep is a test that
    # breaks when somebody improves the wording.
    class Preflight
      # An 8x8 solid `#00ff00` PNG. Inline, small, and its COLOUR is the assertion:
      # an engine can accept a data: URI, fail to decode it, and draw the broken-image
      # glyph — same document size, no error, wrong report.
      #
      # --- IT IS GREEN, AND THAT IS THE WHOLE POINT OF THIS CONSTANT ---
      #
      # The first version of this file used `#00aaff`, WHICH IS ALSO THE PAGE
      # BACKGROUND. The `<img>` has an explicit height, so a data: URI that failed to
      # decode showed the page through it — the identical rgb — and the check returned
      # PASS. It carried no information the `background` check did not already carry,
      # and it could not fail for the reason its own comment gives. Caught in review and
      # confirmed by decoding the IDAT.
      #
      # So the plate's colour must appear NOWHERE else in the probe document. Changing
      # either this or `body { background }` to the other's value silently disarms the
      # check; `spec/render/preflight_spec.rb` asserts the two are different for that
      # reason.
      PROBE_PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSnc' \
                  'AAAAEElEQVR42mNg+M+AHQ0tCQDpMD/BHYHcAQAAAABJRU5ErkJggg=='

      # THE SHIPPED SHELL, not a copy of it. A probe document that hand-rolled its own
      # readiness signal would verify a signal nobody uses; this one exercises the file
      # every real report gets, so `assets/javascripts/chart_shell.js` failing to settle
      # is something an operator finds here rather than in a report that waited out the
      # engine's timeout and lost its charts.
      #
      # MEASURED, and it is why this is here at all: without the shell the probe took
      # 17.5 s against real Chromium and came back with
      # `readiness_timeout: 0 chart(s) had not finished` — the chart-free case waiting
      # out the full watchdog, which is exactly the defect `settle()` exists to prevent.
      CHART_SHELL_PATH = File.expand_path('../../../assets/javascripts/chart_shell.js', __dir__)

      # Sampled from the rendered page. Flat fills, so each has a right answer rather
      # than a resemblance.
      BACKGROUND_RGB = [0, 170, 255].freeze
      BADGE_RGB = [204, 0, 0].freeze
      # The inline plate. DISTINCT FROM `BACKGROUND_RGB` on purpose — see `PROBE_PNG`.
      PLATE_RGB = [0, 255, 0].freeze

      STATES = %i[pass fail skip expected_failure].freeze

      # THE CHECKS THAT NEED TO LOOK INSIDE THE DOCUMENT, and their titles, in one
      # place. The list is a CONTRACT rather than a convenience: the report must have
      # the same shape whether or not poppler is installed, so the skip path and the run
      # path are built from this same table. Two JSON artefacts from two installs are
      # only comparable if the check list does not move.
      DOCUMENT_CHECKS = {
        page_breaks: 'page breaks produce more than one page',
        footer: 'the page-number footer is compiled and numbered',
        background: 'backgrounds are printed, so badges keep their colour',
        inline_asset: 'an inline (data:) image decodes to the right colour',
        javascript: 'the JavaScript path runs, so charts can draw',
        readiness: 'the readiness shell loads, so a chart-free page does not wait',
        hosted_asset: 'a Redmine-hosted image is blocked (expected: the renderer has no network)'
      }.freeze

      # --- WHAT MAKES THE RUN RED, AND WHAT ONLY MAKES IT INCOMPLETE ---
      #
      # `failed?` is the only thing that turns the exit code non-zero, and `:skip` is
      # deliberately not it: poppler is an OPTIONAL package, and treating "the
      # microscope is missing" as "the patient is sick" would make the first thing an
      # operator does with this tool be to ignore its exit code.
      #
      # The hazard that creates is exactly the one this repository keeps rediscovering —
      # a check that did not run reading as a check that passed — so it is answered
      # where it can be answered honestly: `Report#complete?` is false, the headline
      # never says a bare OK, and every skip names the package it needs. Unknown is
      # reported as unknown; it just is not reported as broken.
      Check = Struct.new(:id, :title, :state, :detail, :duration_ms, keyword_init: true) do
        def failed?
          state == :fail
        end

        def skipped?
          state == :skip
        end

        def ok?
          !failed?
        end

        def to_h
          { 'id' => id.to_s, 'title' => title, 'state' => state.to_s,
            'detail' => detail, 'duration_ms' => duration_ms }
        end
      end

      # `redmine_base_url` is a PORT, not a lookup. This layer must not know how to ask
      # Redmine for its own URL — that is `Setting.protocol`/`host_name`, which lives in
      # the application and would drag `Rails.` under `render/**` (mechanism E5, and the
      # boundary `layer_purity.sh` enforces).
      def initialize(engine:, redmine_base_url: nil, logger: nil)
        @engine = engine
        @redmine_base_url = redmine_base_url
        @logger = logger
      end

      attr_reader :engine, :redmine_base_url

      def run
        started = monotonic_ms
        render_started = started
        result = render_probe
        render_ms = (monotonic_ms - render_started).round
        checks = if result.is_a?(Success)
                   inspect_document(result, render_ms)
                 else
                   [engine_check(result, render_ms)]
                 end

        Report.new(engine_id: safe(:id, 'unknown'),
                   engine_version: safe(:version, 'unknown'),
                   checks: checks,
                   duration_ms: (monotonic_ms - started).round,
                   bytes: result.is_a?(Success) ? result.bytes : nil)
      end

      # The probe document. Every element is here because something specific breaks it,
      # and nothing is here for decoration.
      def probe_document
        <<~HTML
          <!DOCTYPE html>
          <html lang="en"><head><meta charset="utf-8"><title>rrd preflight</title>
          <style>
            html, body { margin: 0; padding: 0; height: 100%; }
            /* A coloured page background: the check that catches printBackground
               defaulting false, which costs every badge and progress bar its colour
               while every word still renders. */
            body { background: #00aaff; font-family: sans-serif; }
            .badge { position: absolute; top: 55%; left: 0; width: 100%; height: 15%;
                     background: #cc0000; color: #ffffff; }
            /* ABSOLUTELY POSITIONED, LIKE THE BADGE, SO THE SAMPLE POINT IS NOT A
               GUESS ABOUT FLOW LAYOUT. It was `display: block; height: 20mm` in flow,
               which put it wherever the engine's default <h1> margins happened to end
               — fine on Chromium and unfalsifiable anywhere else. wkhtmltopdf then
               reported the page background at the sample point, and there was no way
               to tell "the data: URI did not decode" from "the plate is 4mm lower".
               The badge proves this positioning works on both engines in this very
               document, so using it here makes the check answer ONE question. */
            img.plate { position: absolute; top: 8%; left: 0; width: 100%; height: 8%; }
            .brk { page-break-before: always; break-before: page; }
          </style>
          <!-- THE SHIPPED READINESS SHELL, in <head> so that anything below can call
               `__rd.begin()` inline — which is the contract's own idiom ("every
               {% chart %} emits its begin() inline"), and what lets the hosted-image
               probe hold the document open until its load actually resolves. With no
               chart registered, `settle()` fires at DOMContentLoaded and the document
               is ready immediately: the chart-free path, which without this shell waited
               out the full 8-second watchdog. -->
          <script>#{chart_shell}</script>
          </head><body>
          <h1>PREFLIGHT-MARKER</h1>

          <!-- Inline asset: must decode, and must decode to the right colour. -->
          <img class="plate" alt="" src="#{PROBE_PNG}">

          <!-- Redmine-hosted asset: EXPECTED to fail under the default policy, and the
               page records which way it went so the PDF can be asked. -->
          <p id="hosted">HOSTED-IMAGE unknown</p>
          #{hosted_image_markup}

          <div class="badge">BADGE</div>

          <!-- A canvas, drawn by script: the JavaScript path every chart depends on. -->
          <canvas id="probe-canvas" width="80" height="20"></canvas>
          <p id="canvas-state">CANVAS-STATE unknown</p>
          <p id="shell-state">SHELL missing</p>

          <div class="brk"><h1>PREFLIGHT-PAGE-TWO</h1></div>

          <script>
            if (window.__rd) {
              document.getElementById('shell-state').textContent = 'SHELL present';
            }
          </script>

          <script>
            (function () {
              try {
                var c = document.getElementById('probe-canvas').getContext('2d');
                c.fillStyle = '#000000';
                c.fillRect(0, 0, 80, 20);
                document.getElementById('canvas-state').textContent = 'CANVAS-STATE drawn';
              } catch (e) {
                document.getElementById('canvas-state').textContent = 'CANVAS-STATE failed';
              }
            }());
          </script>
          </body></html>
        HTML
      end

      private

      # Read at render time, not memoised into a constant: this is a diagnostic, and an
      # operator who has just edited the shell is entitled to have the next run read
      # what is on disk.
      #
      # A shell that cannot be read does NOT stall the probe — it would wait out the
      # watchdog and report a readiness timeout, which is a true statement about the
      # wrong thing. It leaves the `SHELL missing` marker in the document instead, and
      # the `readiness` check reads it back and says which file it wanted.
      # `encoding: 'UTF-8'` is not decoration. `File.read` tags the result with the
      # DEFAULT EXTERNAL encoding, which on a server with a POSIX locale is US-ASCII —
      # and interpolating that into this file's UTF-8 heredoc raises
      # `Encoding::CompatibilityError`, so the preflight would die on exactly the hosts
      # that most need one. Measured: the whole spec file went red under `LANG` unset.
      # `spec/conformance/fixture.rb` had already learned this; the lesson is now in
      # both places rather than in the one that was written second.
      def chart_shell
        File.read(CHART_SHELL_PATH, encoding: 'UTF-8')
      rescue SystemCallError, IOError => e
        "/* #{CHART_SHELL_PATH} could not be read: #{e.class} */"
      end

      def hosted_image_markup
        return '<!-- no Redmine base URL was supplied; that check is skipped -->' if
          redmine_base_url.to_s.empty?

        url = "#{redmine_base_url.to_s.chomp('/')}/favicon.ico"
        # `onload`/`onerror` rather than a pixel probe: what matters is whether the
        # engine could FETCH it, and a favicon's colours are not ours to predict.
        #
        # WRAPPED IN THE READINESS PROTOCOL, and that is the difference between a
        # trustworthy answer and a race. A blocked fetch resolves asynchronously; without
        # `begin()` the document goes ready at DOMContentLoaded and the PDF captures
        # `HOSTED-IMAGE unknown` — a marker that means "the check did not finish" and
        # would be read as "the network was reached". `begin()` holds the document open
        # until the fetch has actually gone one way or the other, and the shell's
        # watchdog bounds the wait either way. This is also the only place the probe
        # exercises begin/end at all, which is the half of the shell a chart-free page
        # never touches.
        %(<script>if (window.__rd) { window.__rd.begin(); }</script>
          <img src="#{url}" alt="" style="width:1px;height:1px"
             onload="document.getElementById('hosted').textContent='HOSTED-IMAGE loaded';
                     if (window.__rd) { window.__rd.end(); }"
             onerror="document.getElementById('hosted').textContent='HOSTED-IMAGE blocked';
                      if (window.__rd) { window.__rd.end(); }">)
      end

      def render_probe
        request = DocumentRequest.new(
          body: probe_document,
          # A RANDOM SUFFIX, because a whole-second timestamp is not unique here: both
          # callers loop over every registered engine in one invocation, so two engines
          # diagnosed in the same second would share a correlation id — and INV-5's
          # point is that a correlation id identifies ONE render in the log.
          correlation_id: "preflight-#{Time.now.to_i}-#{SecureRandom.hex(3)}",
          page_size: 'A4',
          print_backgrounds: true,
          margins_mm: { 'top' => 0, 'right' => 0, 'bottom' => 10, 'left' => 0 },
          footer: PageFurniture.new(right: 'Page {{page}} of {{pages}}'),
          readiness: Readiness.new(timeout_ms: 8_000, client_timeout_ms: 6_000),
          # REQUIRED AND DELIBERATELY NOT ESSENTIAL. An essential capability the engine
          # lacks makes `Renderer` refuse before it draws anything, and a diagnostic
          # that declines to run on the engine it was asked to diagnose has answered
          # nothing. Declared `required`, a missing capability becomes a DEGRADATION —
          # so the run continues, the `degradations` check goes red naming it, and the
          # document check for that same capability goes red too. Two independent
          # reports of one defect is what a preflight is for.
          required_capabilities: %i[javascript print_backgrounds footer],
          timeout_ms: 30_000
        )
        Renderer.new(engine: engine, logger: @logger).render(request)
      end

      # When the engine could not draw at all there is nothing to inspect, and one
      # honest check is better than eight speculative ones.
      def engine_check(failure, render_ms)
        Check.new(id: :engine, title: 'the render engine produced a document',
                  state: :fail,
                  detail: "#{failure.code}: #{failure.message} — #{failure.detail}",
                  duration_ms: failure.duration_ms || render_ms)
      end

      # Everything that can be answered from the Result alone comes first, because
      # those checks work on any install. The rest need to look INSIDE the document,
      # and say so when they cannot.
      def inspect_document(success, render_ms)
        checks = [
          Check.new(id: :engine, title: 'the render engine produced a document',
                    state: :pass,
                    detail: "#{success.bytes.bytesize} bytes from #{success.engine} " \
                            "#{success.engine_version}",
                    # The adapter's own figure where it reported one, and the wall clock
                    # where it did not — a timing column with a hole in it is read as
                    # "instant", which is the wrong lesson from a slow engine.
                    duration_ms: success.duration_ms || render_ms),
          degradation_check(success)
        ]
        checks + document_checks(success.bytes)
      end

      # NOT EVERY DEGRADATION IS A DEFECT, and the first version of this check said they
      # all were. Measured in CI, on wkhtmltopdf, which failed it for two reasons that
      # are both correct behaviour:
      #
      #   legacy_engine      stamped on EVERY wkhtmltopdf render, by design. A check
      #                      that can never pass on an engine says nothing about that
      #                      engine's install.
      #   asset_unresolved   the blocked Redmine-hosted image — the degradation this
      #                      probe deliberately provokes, and which `hosted_asset`
      #                      already reports as an `expected_failure`. Counting it twice,
      #                      once as expected and once as a failure, is the two states
      #                      contradicting each other in one report.
      #
      # So the expected ones are named, reported in the detail (never hidden), and carry
      # `:expected_failure`; anything else is a real silent degradation and fails. The
      # asset one is only expected when the probe ASKED for a blocked asset — with no
      # Redmine base URL the only remote reference is the inline data: URI, and that
      # failing to resolve is a genuine defect.
      LEGACY_DEGRADATIONS = %i[legacy_engine].freeze

      def degradation_check(success)
        unless success.degraded?
          return Check.new(id: :degradations, title: 'nothing was silently degraded',
                           state: :pass, detail: 'none', duration_ms: 0)
        end

        expected = LEGACY_DEGRADATIONS.dup
        expected << :asset_unresolved unless redmine_base_url.to_s.empty?
        unexpected = success.degradations.reject { |d| expected.include?(d.capability.to_sym) }

        Check.new(id: :degradations, title: 'nothing was silently degraded',
                  state: unexpected.empty? ? :expected_failure : :fail,
                  detail: success.degradations.map(&:to_s).join('; '),
                  duration_ms: 0)
      end

      # THE CHECKS THAT NEEDED A PREFLIGHT IN THE FIRST PLACE. Every one of these passes
      # its "did bytes come back" equivalent on an install where every report is losing
      # its images, which is exactly why looking inside is the whole job.
      def document_checks(bytes)
        unless PdfInspector.available?
          # A SKIP PER CHECK, EACH WITH THE PACKAGE NAMED — not one umbrella skip, and
          # certainly not silence.
          #
          # The first version returned a single `:document` skip and returned early,
          # which DELETED the remaining checks from the report rather than skipping
          # them. Two things went wrong at once. The INV-8 containment question — the
          # one T-14's Accept list singles out — simply was not in the report, so an
          # operator was told the document had not been inspected rather than that the
          # network question went unanswered. And the artefact changed SHAPE between
          # installs, so two JSON reports could not be diffed. Caught by review, and
          # independently by CI: a spec asserting `hosted_asset` skips found it absent.
          #
          # `complete?` counts skips, so every one of these is now counted.
          return DOCUMENT_CHECKS.map do |id, title|
            Check.new(id: id, title: title, state: :skip,
                      detail: PdfInspector::INSTALL_HINT, duration_ms: 0)
          end
        end

        [timed(:page_breaks, DOCUMENT_CHECKS[:page_breaks]) do
           count = PdfInspector.page_count(bytes)
           [count >= 2, "#{count} page(s)"]
         end,
         timed(:footer, DOCUMENT_CHECKS[:footer]) do
           first = PdfInspector.flat_text(bytes, page: 1)
           [first.include?('Page 1 of 2'), first[/Page \d+ of \d+/] || 'no page number found']
         end,
         timed(:background, DOCUMENT_CHECKS[:background]) do
           page = PdfInspector.pixel(bytes, x: 0.5, y: 0.30)
           badge = PdfInspector.pixel(bytes, x: 0.5, y: 0.60)
           ok = PdfInspector.colour_matches?(page, BACKGROUND_RGB) &&
                PdfInspector.colour_matches?(badge, BADGE_RGB)
           [ok, "page rgb#{page.inspect}, badge rgb#{badge.inspect}"]
         end,
         timed(:inline_asset, DOCUMENT_CHECKS[:inline_asset]) do
           # SAMPLED AGAINST `PLATE_RGB`, WHICH IS NOT THE PAGE BACKGROUND. Compared
           # against the background — as the first version did, because the probe image
           # happened to be that same colour — this passes when the image does not
           # decode at all, because the page shows through where the plate should be.
           # See `PROBE_PNG`.
           #
           # `y: 0.12` is the middle of the plate's absolutely-positioned band (8%–16%),
           # so this asks about DECODING and not about layout. See the CSS.
           sample = PdfInspector.pixel(bytes, x: 0.5, y: 0.12)
           [PdfInspector.colour_matches?(sample, PLATE_RGB),
            "rgb#{sample.inspect}, wanted rgb#{PLATE_RGB.inspect}"]
         end,
         timed(:javascript, DOCUMENT_CHECKS[:javascript]) do
           state = PdfInspector.flat_text(bytes, page: 1)
           [state.include?('CANVAS-STATE drawn'),
            state[/CANVAS-STATE \w+/] || 'no canvas state reported']
         end,
         timed(:readiness, DOCUMENT_CHECKS[:readiness]) do
           # Three outcomes, not two. The marker says `present`, or it says `missing`,
           # or it is not in the document at all — and the first draft reported that
           # third case as "loaded" while failing the check, which is a failure whose
           # detail contradicts it. Every branch here says what was actually seen.
           state = PdfInspector.flat_text(bytes, page: 1)
           [state.include?('SHELL present'),
            state[/SHELL \w+/] || "no shell marker in the document (#{CHART_SHELL_PATH})"]
         end,
         hosted_image_check(bytes)]
      end

      # THE ONE THAT IS SUPPOSED TO FAIL. Under the default `:bundled` policy the
      # renderer has no network, so a Redmine-hosted image cannot load — and an operator
      # who was going to point a template at a hosted logo needs to learn that here
      # rather than from a report with a hole in it. `:expected_failure` and `:fail` are
      # deliberately different states: give them the same colour and the one that
      # matters gets ignored along with the one that does not.
      def hosted_image_check(bytes)
        title = DOCUMENT_CHECKS[:hosted_asset]
        if redmine_base_url.to_s.empty?
          return Check.new(id: :hosted_asset, title: title, state: :skip,
                           detail: 'no Redmine base URL was supplied', duration_ms: 0)
        end

        timed(:hosted_asset, title) do
          # THREE OUTCOMES, and conflating any two of them is a lie about INV-8.
          # `blocked` is what should happen. `loaded` means the renderer has network
          # access it must not have. `unknown` means the fetch never resolved before the
          # document went ready — the readiness wrapper in `hosted_image_markup` exists
          # to prevent that, so seeing it means the wrapper stopped working, NOT that
          # the network was reached. Reporting it as a reachable network would send an
          # operator hunting for a firewall hole that is not there.
          case PdfInspector.flat_text(bytes, page: 1)[/HOSTED-IMAGE \w+/]
          when 'HOSTED-IMAGE blocked'
            [:expected_failure, 'blocked, as the :bundled policy intends']
          when 'HOSTED-IMAGE loaded'
            [:fail, "the renderer REACHED #{redmine_base_url} — it has network access " \
                    'it is not supposed to have (INV-8)']
          else
            [:fail, 'the fetch never resolved before the document went ready; this check ' \
                    'did not conclude, and says so rather than guessing which way it went']
          end
        end
      end

      # Times the check and turns a boolean-or-state plus a detail into a Check.
      def timed(id, title)
        started = monotonic_ms
        outcome, detail = yield
        state = outcome.is_a?(Symbol) ? outcome : (outcome ? :pass : :fail)
        Check.new(id: id, title: title, state: state, detail: detail,
                  duration_ms: (monotonic_ms - started).round)
      rescue StandardError => e
        Check.new(id: id, title: title, state: :fail,
                  detail: "#{e.class}: #{e.message}",
                  duration_ms: (monotonic_ms - started).round)
      end

      # An adapter that cannot even say what it is must not take the report down with
      # it — but the failure is LOGGED rather than swallowed. A silent `rescue` around a
      # question asked of a possibly-broken object is how this project's worst hidden
      # coupling stayed invisible for four minor versions (CLAUDE.md §5, the swallowed
      # `NameError` around a registration), and a report headed `unknown` with no trace
      # anywhere gives an operator nothing to search for.
      #
      # A `nil` ANSWER IS ALSO ABSENCE. `respond_to?` is true and nothing raises when an
      # adapter's `version` simply returns nil, so without the `.nil?` arm the fallback
      # never applies and the admin page renders a blank cell.
      def safe(method, fallback)
        return fallback unless engine.respond_to?(method)

        value = engine.public_send(method)
        value.nil? ? fallback : value
      rescue StandardError => e
        warn_line("[render] preflight could not read #{method} from the engine: " \
                  "#{e.class}: #{e.message}")
        fallback
      end

      def warn_line(line)
        @logger.warn(line) if @logger.respond_to?(:warn)
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      end

      # The artefact. JSON so it can be asserted on, diffed and pasted into an issue —
      # a diagnostic that exists only as prose gets checked by grepping, and a grep is a
      # test that breaks when somebody improves the wording.
      class Report
        attr_reader :engine_id, :engine_version, :checks, :duration_ms, :bytes

        def initialize(engine_id:, engine_version:, checks:, duration_ms:, bytes: nil)
          @engine_id = engine_id
          @engine_version = engine_version
          @checks = checks
          @duration_ms = duration_ms
          @bytes = bytes
        end

        # An EXPECTED failure does not make the run red. The Redmine-hosted image is
        # supposed to be blocked under the default policy, and colouring it the same as
        # a real failure is how the real one gets ignored.
        def ok?
          failures.empty?
        end

        # Not the same question as `ok?`, and both are reported. A run with skips has
        # nothing wrong with it and has not answered everything it was asked — see the
        # note on `Check`.
        def complete?
          skipped.empty?
        end

        def failures
          checks.select(&:failed?)
        end

        def skipped
          checks.select(&:skipped?)
        end

        def to_h
          { 'engine' => engine_id.to_s, 'engine_version' => engine_version.to_s,
            'duration_ms' => duration_ms, 'ok' => ok?, 'complete' => complete?,
            'checks' => checks.map(&:to_h) }
        end

        def to_json(*args)
          JSON.pretty_generate(to_h, *args)
        end

        # One line per check, for a terminal. The state is first so a column of them
        # can be scanned without reading any of the titles.
        def to_text
          lines = ["render preflight: #{engine_id} #{engine_version} (#{headline}, #{duration_ms}ms)"]
          checks.each do |check|
            # SQUISHED. `Failure#detail` routinely carries an engine's stderr, which is
            # multi-line — and this method promises one line per check, which
            # `preflight_spec.rb` asserts by counting them. Truncating without
            # flattening kept the newlines inside the 90 characters and silently broke
            # both the promise and any per-report parsing of this format.
            lines << format('  %-18s %-46s %s', check.state.to_s.upcase, check.title,
                            check.detail.to_s.gsub(/\s+/, ' ').strip[0, 90])
          end
          lines.join("\n")
        end

        # NEVER A BARE "OK" WHEN SOMETHING DID NOT RUN. The exit code forgives a skip
        # (see `Check`); the headline must not, or the operator reads "OK" off a run
        # that never looked inside the document.
        def headline
          return 'PROBLEMS FOUND' unless ok?
          return 'OK' if complete?

          "OK so far — #{skipped.length} check(s) could not run"
        end
      end
    end
  end
end
