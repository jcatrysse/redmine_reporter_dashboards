# frozen_string_literal: true

require 'open3'
require 'tempfile'

require_relative '../capabilities'
require_relative '../document_request'
require_relative '../page_furniture'
require_relative '../failure'
require_relative '../result'
require_relative '../readiness'
require_relative '../registry'

module RedmineReporterDashboards
  module Render
    module Engines
      # `:wkhtmltopdf` — the COMPATIBILITY engine. Not the default, and deprecated on
      # arrival.
      #
      # --- WHY SHIP AN ENGINE YOU HAVE ALREADY DEPRECATED ---
      #
      # Because it is the only one `bundle install` provisions. Every existing install
      # of this plugin renders through wkhtmltopdf today; a migration that requires an
      # operator to install a browser BEFORE their reports keep working is a migration
      # that breaks every install on the day of the upgrade. This adapter is what makes
      # the switch survivable: the same templates, the same output, through the new
      # interface, with `Degradation(:legacy_engine)` stamped into every result so that
      # nobody is surprised later about which engine drew a document.
      #
      # It also works where the reference engine cannot: shared hosting, air-gapped
      # networks, no services, no configuration. That is a real constituency and it is
      # not served by telling it to install Chromium.
      #
      # --- REMOVAL CONDITION, INV-7-SHAPED, STATED ON ARRIVAL ---
      #
      # It goes when: (1) `:chromium_cdp` has been green in the render-smoke job for two
      # releases, AND (2) no supported install still selects it, AND (3) the shims in
      # `glue/legacy/wk_legacy_shims.rb` have no other caller. Not "when it feels old" —
      # three conditions somebody can check.
      #
      # --- THE RUNAWAY-SCRIPT GUARD GOES BACK ON ---
      #
      # Today's render path passes `no_stop_slow_scripts: true` together with a flat
      # `javascript_delay: 3000`: the engine's own protection against a script that
      # never finishes is switched OFF, and nothing replaces it. This adapter does not
      # pass that flag at all. With a real readiness signal there was never a reason to
      # — `--window-status` tells the engine when the page is finished, and a script
      # that runs away is then a bug the engine is allowed to stop.
      class Wkhtmltopdf
        ID = :wkhtmltopdf

        # Conservative on purpose. Under the three-state rule an UNDECLARED capability
        # skips with a reason, and a DECLARED one that fails is a hard failure — so the
        # cost of over-claiming is a red cell that blames the engine for a promise this
        # file made on its behalf. Absent, and each for a reason:
        #
        #   :readiness_expression  it cannot evaluate one; readiness is --window-status
        #   :scale                 --zoom is not the same thing and rounds differently
        #   :outline, :tagged_pdf  no accessible-PDF support at all
        #   :asset_upload/:http    inline only, by policy as well as by capability
        CAPABILITIES = %i[
          javascript print_backgrounds header footer page_furniture_tokens
          custom_page_size landscape margins media_print page_break_css
          pdf_metadata asset_inline timeout
        ].freeze

        BINARY_CANDIDATES = %w[wkhtmltopdf].freeze

        # Its `--window-status` watcher can miss a status that was set before it started
        # watching, which is a race and not a slow page. A floor is the documented shape
        # of this engine's signal — per-engine for exactly that reason, rather than a
        # global fudge applied to engines that do not need it.
        WINDOW_STATUS_FLOOR_MS = Readiness::WINDOW_STATUS_FLOOR_MS

        PAGE_SIZES = %w[A3 A4 A5 Letter Legal Tabloid].freeze

        attr_reader :binary

        def initialize(binary: nil, logger: nil)
          @binary = binary || self.class.detect_binary
          @logger = logger
        end

        class << self
          def detect_binary
            from_env = ENV['RRD_WKHTMLTOPDF_BINARY'].to_s
            return from_env unless from_env.empty?

            BINARY_CANDIDATES.each do |name|
              ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
                candidate = File.join(dir, name)
                return candidate if File.executable?(candidate) && !File.directory?(candidate)
              end
            end
            BINARY_CANDIDATES.first
          end
        end

        def id
          ID
        end

        def capabilities
          CAPABILITIES
        end

        # PROBED FROM THE BINARY, never a constant — the same rule as the reference
        # engine, and it matters more here: 0.12.5 and 0.12.6 differ in how they handle
        # `--enable-local-file-access`, and a document that renders on one silently
        # loses its images on the other.
        def version
          return @version if @version

          out, _err, status = Open3.capture3(@binary, '--version')
          @version = status.success? ? out.strip.split("\n").first : 'unavailable'
        rescue Errno::ENOENT, Errno::EACCES => e
          @version = "unavailable (#{e.class})"
        end

        # A ROUND TRIP, never `File.exist?`. wkhtmltopdf's classic failure is a binary
        # that exists and cannot run — the famous "cannot open shared object file" and
        # "version `LIBJPEG_8.0' not found" — which every existence check passes and
        # every render fails.
        def preflight
          render(DocumentRequest.new(
                   body: '<!DOCTYPE html><html><body><h1>rrd preflight</h1></body></html>',
                   correlation_id: 'preflight', page_size: 'A4', timeout_ms: 30_000
                 ))
        end

        def render(request)
          started = monotonic_ms
          Tempfile.create(['rrd-render', '.pdf']) do |output|
            output.close
            argv = build_argv(request, output.path)
            bytes, refusal = run(argv, request, started)
            next refusal if refusal

            Success.new(bytes: bytes, engine: ID, engine_version: version,
                        page_count: nil, duration_ms: (monotonic_ms - started).round,
                        degradations: degradations(request))
          end
        rescue StandardError => e
          failure(request, :internal, 'the report could not be produced',
                  detail: "#{e.class}: #{e.message}", started: started)
        end

        def shutdown
          true
        end

        private

        # STDIN IN, FILE OUT. The document never becomes a file on disk — nothing to
        # leak, nothing left behind if the process dies mid-render — and the PDF does,
        # because wkhtmltopdf's stdout PDF is unreliable across builds.
        #
        # AND IT IS KILLED IF IT DOES NOT FINISH. wkhtmltopdf has no timeout flag of its
        # own, so `Open3.capture3` on a hung engine waits forever and holds the caller's
        # thread with it. This adapter declares `:timeout`, and a declaration is a
        # promise: the deadline is enforced here, with SIGKILL rather than SIGTERM
        # because a wedged QtWebKit does not always answer the polite one.
        #
        # --- WHY `IO.select` AND NOT THREE READER THREADS ---
        #
        # The obvious shape is a thread per stream. `script/gates/no_thread_local.sh`
        # forbids `Thread.new` outside the legacy glue and was right to fail the first
        # version of this method — but the gate is not the reason this is written the way
        # it is, it is only what prompted looking again. Threads here would need to be
        # joined on every exit path including the timeout one, and a reader thread
        # blocked on a pipe that nobody will ever write to again is a leak that outlives
        # the render. One select loop over all three descriptors has no such path: when
        # the deadline passes, the loop stops and the process is killed, and there is
        # nothing left running.
        #
        # DRAINING IS NOT OPTIONAL. A child that fills the 64 KiB pipe buffer blocks in
        # `write` and never exits, so "read the output afterwards" deadlocks against
        # "wait for it to finish" — and wkhtmltopdf is chatty on stderr.
        def run(argv, request, started)
          Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thread|
            stdin.binmode
            deadline = monotonic_ms + request.timeout_ms
            captured = pump(stdin, stdout, stderr, request.body.dup.b, deadline)

            remaining = [(deadline - monotonic_ms) / 1000.0, 0].max
            unless wait_thread.join(remaining)
              kill(wait_thread.pid)
              wait_thread.join
              next [nil, failure(request, :timeout, 'the report took too long to draw',
                                 detail: "killed after #{request.timeout_ms}ms", started: started)]
            end

            status = wait_thread.value
            next [nil, engine_failure(request, captured, status, started)] unless status.success?

            [File.binread(argv.last), nil]
          end
        rescue Errno::ENOENT, Errno::EACCES => e
          [nil, failure(request, :engine_unavailable,
                        'the render engine is not installed or cannot be started',
                        detail: "#{@binary}: #{e.class}: #{e.message}", started: started)]
        end

        # Feeds the document in and drains both output streams until the child closes
        # them or the deadline passes. Returns whatever stderr said, which is where
        # wkhtmltopdf keeps the reason for anything it did.
        def pump(stdin, stdout, stderr, body, deadline)
          offset = 0
          collected = +''
          readers = [stdout, stderr]

          until readers.empty? || monotonic_ms >= deadline
            writers = stdin.closed? ? [] : [stdin]
            ready = IO.select(readers, writers, nil, 0.1)
            next unless ready

            ready[1].each { offset = feed(stdin, body, offset) }
            ready[0].each do |io|
              chunk = drain(io)
              if chunk.nil?
                readers.delete(io)
              elsif io.equal?(stderr)
                # Bounded: a runaway engine can produce megabytes of warnings, and none
                # of it belongs in a Failure's detail.
                collected << chunk if collected.bytesize < 64 * 1024
              end
            end
          end

          close_quietly(stdin)
          collected
        end

        def feed(stdin, body, offset)
          written = stdin.write_nonblock(body.byteslice(offset..) || '', exception: false)
          return offset if written == :wait_writable

          offset += written
          close_quietly(stdin) if offset >= body.bytesize
          offset
        rescue Errno::EPIPE, IOError
          # The engine stopped reading — it has either finished or failed, and either
          # way there is nothing useful left to send it.
          close_quietly(stdin)
          body.bytesize
        end

        def drain(io)
          io.read_nonblock(16_384, exception: false).then do |chunk|
            chunk == :wait_readable ? '' : chunk
          end
        rescue EOFError, IOError
          nil
        end

        def close_quietly(io)
          io.close unless io.closed?
        rescue IOError
          nil
        end

        def kill(pid)
          Process.kill('KILL', pid)
        rescue Errno::ESRCH
          nil
        end

        def build_argv(request, output_path)
          argv = [@binary, '--quiet', '--encoding', 'UTF-8']

          # --- EGRESS DENIAL, IN TWO PARTS, AND THE FIRST PART IS NOT ENOUGH ---
          #
          # `--disable-local-file-access` stops it reading the filesystem. It does NOT
          # stop it reaching the network, and the first CI run of this adapter proved it:
          # conformance fixture F-15 watched three subresources — a stylesheet, an image
          # and an XHR — arrive at the harness's own listening socket. Exactly the same
          # defect as the reference engine's, found the same way, one engine later. That
          # repetition is the argument for having the corpus at all: the second instance
          # cost minutes rather than a security review.
          #
          # So every request is also pointed at a proxy that does not exist. There is
          # nothing to connect to at 127.0.0.1:1, so a fetch fails at connect — before
          # DNS, before any real target. INV-8: the renderer is never the thing holding
          # the network.
          argv += ['--disable-local-file-access', '--proxy', '127.0.0.1:1']

          # A subresource that cannot be loaded is the EXPECTED case under that policy,
          # not an error worth abandoning a report over. Without these, a single
          # unresolvable reference exits non-zero and the reader gets nothing instead of
          # a document with one image missing.
          argv += ['--load-error-handling', 'ignore',
                   '--load-media-error-handling', 'ignore']

          argv += page_argv(request)
          argv += margin_argv(request)
          argv += furniture_argv(request)
          argv += readiness_argv(request)
          argv += metadata_argv(request)
          argv += ['--print-media-type'] if request.media == :print
          argv += request.print_backgrounds ? ['--background'] : ['--no-background']
          # STDIN, then the output path: both positional, both last, in that order.
          argv + ['-', output_path]
        end

        def page_argv(request)
          size = PAGE_SIZES.include?(request.page_size) ? request.page_size : 'A4'
          ['--page-size', size,
           '--orientation', request.landscape? ? 'Landscape' : 'Portrait']
        end

        def margin_argv(request)
          %w[top right bottom left].flat_map do |edge|
            ["--margin-#{edge}", "#{request.margins_mm[edge]}mm"]
          end
        end

        # `[page]` and `[topage]` are this engine's native spelling, and this is the only
        # place in the plugin allowed to know that. A template that wrote them itself
        # would render as literal text on every other engine — which is the entire
        # reason `PageFurniture` exists and the linter rejects them in template source.
        def furniture_argv(request)
          argv = []
          argv += slot_argv('header', request.header) if request.header && !request.header.empty?
          argv += slot_argv('footer', request.footer) if request.footer && !request.footer.empty?
          argv
        end

        def slot_argv(which, furniture)
          argv = []
          furniture.slots.each do |position, text|
            next if text.empty?

            argv += ["--#{which}-#{position}", compile_tokens(text)]
          end
          argv + ["--#{which}-font-size", furniture.font_size_pt.to_s] +
            (furniture.separator ? ["--#{which}-line"] : [])
        end

        def compile_tokens(text)
          text.gsub(PageFurniture::TOKEN_PATTERN) do
            case Regexp.last_match(1)
            when 'page' then '[page]'
            when 'pages' then '[topage]'
            when 'title' then '[doctitle]'
            when 'date' then '[date]'
            else Regexp.last_match(0)
            end
          end
        end

        # THE READINESS SIGNAL, and the flag that is NOT here.
        #
        # `--window-status rd-ready` is the third of the DOM contract's three signals,
        # and the shell sets it at the same instant as the other two — so the same
        # document serves this engine and the reference one. `--javascript-delay` is the
        # floor described above, not a guess at how long charts take: the engine waits
        # for the STATUS, and the floor only closes the race where the status was set
        # before the watcher started.
        #
        # `--no-stop-slow-scripts` is deliberately absent. Today's path passes it, which
        # switches off the engine's only protection against a script that never returns,
        # with a fixed three-second delay in its place. With a real signal there is
        # nothing to gain from it and a hung render to lose.
        def readiness_argv(request)
          readiness = request.readiness
          return [] unless readiness

          ['--window-status', Readiness::STATUS,
           '--javascript-delay', WINDOW_STATUS_FLOOR_MS.to_s]
        end

        def metadata_argv(request)
          title = request.pdf_metadata['title'] || request.pdf_metadata[:title]
          title ? ['--title', title.to_s] : []
        end

        # EVERY result from this engine carries it. A PDF drawn by a deprecated engine
        # has to say so somewhere a reader can find it six months later, and a
        # degradation is the channel that already reaches the diagnostics view, the log
        # and the document's own metadata.
        def degradations(request)
          list = [Degradation.new(capability: :legacy_engine,
                                  detail: 'drawn by wkhtmltopdf, a compatibility engine ' \
                                          'scheduled for removal; modern CSS is not supported')]
          missing = Capabilities.negotiate(required: request.required_capabilities,
                                           essential: [], available: CAPABILITIES)[:missing]
          list + missing.map do |capability|
            Degradation.new(capability: capability, detail: "wkhtmltopdf cannot #{capability}")
          end
        end

        def failure(request, code, message, detail:, started:)
          Failure.new(code: code, message: message, detail: detail, engine: ID,
                      engine_version: @version, duration_ms: (monotonic_ms - started).round,
                      correlation_id: request.correlation_id)
        end

        def monotonic_ms
          Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
        end
      end

      Registry.register(Wkhtmltopdf::ID, Wkhtmltopdf)
    end
  end
end
