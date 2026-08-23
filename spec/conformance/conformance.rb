# frozen_string_literal: true

require 'socket'
require 'tmpdir'
require 'securerandom'

require_relative 'pdf_probe'
require_relative 'fixture'
require_relative '../../lib/redmine_reporter_dashboards/render/capabilities'
require_relative '../../lib/redmine_reporter_dashboards/render/page_furniture'
require_relative '../../lib/redmine_reporter_dashboards/render/document_request'
require_relative '../../lib/redmine_reporter_dashboards/render/failure'
require_relative '../../lib/redmine_reporter_dashboards/render/result'
require_relative '../../lib/redmine_reporter_dashboards/render/readiness'
require_relative '../../lib/redmine_reporter_dashboards/render/renderer'
# T-38 — the SHIPPED report stylesheet, for the fixtures that assert print behaviour is a
# property of it rather than of a copy in a fixture (`Fixture::REPORT_STYLESHEET_TOKEN`).
require_relative '../../lib/redmine_reporter_dashboards/report_stylesheet'

module RedmineReporterDashboards
  # T-12 — the engine conformance corpus.
  #
  # An interface with one implementation is a class with extra steps. This corpus is
  # what makes `Render`'s abstraction an abstraction: it states, executably, what any
  # engine has to do to be one of ours, and it answers the question a support matrix
  # is supposed to answer without anybody hand-writing a cell.
  #
  # It is deliberately built BEFORE the adapters (T-13). An engine conformance-tested
  # against a contract written afterwards is tested against itself.
  module Conformance
    class CheckFailed < StandardError; end

    # A harness fault — a missing probe tool, a fixture that cannot be read. NOT a
    # fixture failure, and reported separately so that "the engine is broken" and
    # "the harness is broken" never share a cell.
    class HarnessError < StandardError; end

    STATES = %i[pass fail skip error].freeze

    Outcome = Struct.new(:fixture_id, :title, :area, :state, :reason, :duration_ms,
                         :checks_run, :degradations, keyword_init: true) do
      # Plain defs throughout this file: the floor is Ruby 2.7 (Redmine 5.1) and
      # endless method definitions arrived in 3.0. The specs are what a packager runs
      # first, so they are held to the same floor as lib/.
      def pass?
        state == :pass
      end

      def fail?
        state == :fail
      end

      def skip?
        state == :skip
      end

      def error?
        state == :error
      end
    end

    # ------------------------------------------------------------------------
    # The check context handed to every `check` block.
    #
    # Every assertion here names WHAT was expected as well as what happened, because
    # the message ends up in a CI log read by somebody who has never seen the fixture.
    # "expected 2, got 1" is a puzzle; "page count: expected 4 (three explicit breaks),
    # got 1" is a diagnosis.
    # ------------------------------------------------------------------------
    class Verification
      attr_reader :result, :pdf_path, :duration_ms, :engine, :egress

      def initialize(result:, pdf_path:, duration_ms:, engine:, egress:)
        @result = result
        @pdf_path = pdf_path
        @duration_ms = duration_ms
        @engine = engine
        @egress = egress
      end

      # ---- readings ----------------------------------------------------------

      def page_count
        PdfProbe.page_count(pdf!)
      end

      def page_size_pt
        PdfProbe.page_size_pt(pdf!)
      end

      def text(page: nil)
        PdfProbe.text(pdf!, page: page)
      end

      # The same text with every run of whitespace collapsed to one space.
      #
      # A PDF has lines, not sentences. `PAYLOAD-CHECKSUM f13c6e5` is one phrase to a
      # reader and two lines to the extractor whenever the column happens to break
      # there, so a phrase assertion against the raw text fails on a layout accident
      # rather than on anything about the engine. Where the assertion is about WHAT the
      # document says, use this; where it is about WHERE the text sits on the page —
      # F-04's per-page footer — use `text`, because there the line matters.
      def flat_text(page: nil)
        text(page: page).gsub(/\s+/, ' ').strip
      end

      def pixel(page: 1, x: 0.5, y: 0.5, dpi: 24)
        PdfProbe.pixel(pdf!, page: page, x: x, y: y, dpi: dpi)
      end

      def byte_size
        File.size(pdf!)
      end

      # T-38 — every URI the document carries as a link ANNOTATION, which is what makes a
      # link a link rather than blue text. `PdfProbe.links` cross-checks its own reading
      # against poppler's and raises if the two disagree; see the comment there.
      def links
        PdfProbe.links(pdf!)
      end

      def degradations
        result.respond_to?(:degradations) ? result.degradations.map(&:capability) : []
      end

      # ---- assertions --------------------------------------------------------

      def expect_true(condition, what)
        return true if condition

        raise CheckFailed, what
      end

      def expect_equal(actual, expected, what)
        return true if actual == expected

        raise CheckFailed, "#{what}: expected #{expected.inspect}, got #{actual.inspect}"
      end

      def expect_within(actual, expected, tolerance, what)
        return true if (actual - expected).abs <= tolerance

        raise CheckFailed,
              "#{what}: expected #{expected} ± #{tolerance}, got #{actual}"
      end

      def expect_between(actual, low, high, what)
        return true if actual >= low && actual <= high

        raise CheckFailed, "#{what}: expected between #{low} and #{high}, got #{actual}"
      end

      def expect_includes(haystack, needle, what)
        return true if haystack.to_s.include?(needle)

        raise CheckFailed,
              "#{what}: #{needle.inspect} is absent from #{excerpt(haystack)}"
      end

      def expect_excludes(haystack, needle, what)
        return true unless haystack.to_s.include?(needle)

        raise CheckFailed,
              "#{what}: #{needle.inspect} is present and must not be, in #{excerpt(haystack)}"
      end

      def expect_colour(actual, expected, what)
        return true if PdfProbe.colour_matches?(actual, expected)

        raise CheckFailed,
              "#{what}: expected rgb#{expected.inspect} ± #{PdfProbe::COLOUR_TOLERANCE}, " \
              "got rgb#{actual.inspect}"
      end

      def expect_failure_code(code)
        expect_true(result.respond_to?(:code), "expected a Failure, got #{result.class}")
        expect_equal(result.code, code, 'failure code')
      end

      private

      def pdf!
        raise CheckFailed, "there is no document to read: #{result_summary}" if pdf_path.nil?

        pdf_path
      end

      def result_summary
        return "Failure(#{result.code}): #{result.message}" if result.respond_to?(:code)

        result.class.to_s
      end

      def excerpt(text)
        flat = text.to_s.gsub(/\s+/, ' ').strip
        flat.length > 400 ? "#{flat[0, 400]}…" : flat.inspect
      end
    end

    # ------------------------------------------------------------------------
    # A listening socket that must never be connected to.
    #
    # This is the egress falsifier and it is worth stating why it is shaped this way.
    # Asserting that the PAGE saw an error proves nothing: an image can fail to load
    # for a dozen reasons, and a page that reports failure while the engine happily
    # opened the connection is the exact posture INV-8 forbids. So the harness listens,
    # and the assertion is about what arrived HERE. Zero connections is the pass.
    #
    # It also gives the gate its negative test: point an engine WITHOUT the egress
    # flags at the same fixture and this listener records the hit, which is how we
    # know the check can fail at all (HANDOVER §1: negative-test a gate before
    # trusting it).
    # ------------------------------------------------------------------------
    class EgressListener
      attr_reader :hits

      def initialize
        @server = TCPServer.new('127.0.0.1', 0)
        @hits = []
        @mutex = Mutex.new
        @thread = Thread.new { accept_loop }
        @thread.abort_on_exception = false
      end

      def url(path = '/beacon.png')
        "http://127.0.0.1:#{@server.addr[1]}#{path}"
      end

      def hit_count
        @mutex.synchronize { @hits.length }
      end

      def close
        @thread&.kill
        @server.close unless @server.closed?
      end

      private

      def accept_loop
        loop do
          socket = @server.accept
          line = begin
            socket.gets
          rescue StandardError
            nil
          end
          @mutex.synchronize { @hits << (line || '<no request line>') }
          # A 1x1 GIF, so a hit does not also become a hang: an engine waiting for a
          # response body would turn "egress happened" into "the render timed out",
          # and the second diagnosis hides the first.
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: 0\r\n\r\n")
          socket.close
        rescue StandardError
          nil
        end
      end
    end

    # ------------------------------------------------------------------------
    # The runner.
    # ------------------------------------------------------------------------
    class Runner
      CHART_SHELL = File.expand_path('../../assets/javascripts/chart_shell.js', __dir__)

      attr_reader :engine, :work_dir

      def initialize(engine:, work_dir: nil, logger: nil)
        @engine = engine
        @work_dir = work_dir || Dir.mktmpdir('rrd-conformance')
        @logger = logger
      end

      def run(fixtures)
        PdfProbe.require_tools!
        outcomes = fixtures.map { |fixture| run_fixture(fixture) }
        Report.new(engine_id: safe(:id, 'unknown'),
                   engine_version: safe(:version, 'unknown'),
                   capabilities: Array(safe(:capabilities, [])),
                   outcomes: outcomes)
      end

      def run_fixture(fixture)
        missing = fixture.requires - Array(safe(:capabilities, []))
        return skipped(fixture, missing) unless missing.empty?

        dynamic, inapplicable = fixture.dynamic_request(engine)
        return outcome(fixture, :skip, inapplicable, 0) if inapplicable

        attempt_outcomes = (1..fixture.repeat_attempts).map { |n| attempt(fixture, n, dynamic) }
        worst(fixture, attempt_outcomes)
      rescue HarnessError => e
        outcome(fixture, :error, e.message, 0)
      rescue StandardError => e
        # NOT a fixture failure. Something in the harness itself — a malformed fixture,
        # an unreadable document — went wrong, and calling that a red cell for the
        # engine would blame the wrong component. `:error` is red too; it is red in the
        # right column.
        outcome(fixture, :error, "harness: #{e.class}: #{e.message}", 0)
      end

      private

      # THE SKIP ARM OF G12. The reason names the capability, always — a bare skip is
      # a forbidden construct in this repository (CLAUDE.md §5) precisely because it
      # turns "unsupported" into a green run nobody reads.
      def skipped(fixture, missing)
        outcome(fixture, :skip,
                "#{safe(:id, 'engine')} does not declare #{missing.map(&:inspect).join(', ')}", 0)
      end

      def attempt(fixture, number, dynamic = {})
        egress = fixture.needs_egress_listener? ? EgressListener.new : nil
        request = build_request(fixture, egress, dynamic)
        started = monotonic_ms
        result = Render::Renderer.new(engine: engine, logger: @logger).render(request)
        duration = monotonic_ms - started

        pdf_path = write_document(fixture, number, result)
        verify(fixture, result, pdf_path, duration, egress)
      rescue CheckFailed => e
        outcome(fixture, :fail, "attempt #{number}/#{fixture.repeat_attempts}: #{e.message}",
                duration || 0, degradations: degradations_of(result))
      ensure
        egress&.close
      end

      def verify(fixture, result, pdf_path, duration, egress)
        assert_arm(fixture, result)
        context = Verification.new(result: result, pdf_path: pdf_path, duration_ms: duration,
                                   engine: engine, egress: egress)
        fixture.checks.each do |(name, block)|
          begin
            block.call(context)
          rescue CheckFailed => e
            raise CheckFailed, "#{name} — #{e.message}"
          end
        end
        outcome(fixture, :pass, nil, duration,
                checks_run: fixture.checks.length, degradations: degradations_of(result))
      end

      # Which arm of `Result` this fixture is asserting. Stated explicitly so that a
      # fixture expecting a refusal cannot pass by rendering, and a fixture expecting a
      # document cannot pass by failing.
      def assert_arm(fixture, result)
        if fixture.expect_failure
          raise CheckFailed, "expected Failure(#{fixture.expect_failure}), got a Success" unless
            result.is_a?(Render::Failure)

          raise CheckFailed, "expected Failure(#{fixture.expect_failure}), got " \
                             "Failure(#{result.code}): #{result.message}" unless
            result.code == fixture.expect_failure
        elsif result.is_a?(Render::Failure) && !fixture.allow_failure
          raise CheckFailed, "the engine refused: Failure(#{result.code}) #{result.message} " \
                             "[#{result.detail}]"
        end
      end

      def build_request(fixture, egress, dynamic = {})
        overrides = fixture.request_overrides.merge(dynamic)
        readiness = fixture.readiness_options && Render::Readiness.new(**fixture.readiness_options)
        body = fixture.body(chart_shell: chart_shell_tag(fixture),
                            egress_url: egress ? egress.url : '',
                            report_stylesheet: report_stylesheet_tag(fixture))

        Render::DocumentRequest.new(
          body: body,
          correlation_id: "conformance-#{fixture.id}-#{SecureRandom.hex(4)}",
          readiness: readiness,
          **overrides
        )
      end

      # The SHIPPED stylesheet, from the module every report goes through — same rule as
      # the chart shell below it, and the same reason: a fixture carrying its own copy of
      # `thead { display: table-header-group }` would assert something about the engine and
      # nothing about `ReportStylesheet`, which is what T-38's two print clauses are about.
      def report_stylesheet_tag(fixture)
        return '' unless fixture.needs_report_stylesheet?

        RedmineReporterDashboards::ReportStylesheet.style_element
      end

      # The SHIPPED shell, inlined. A fixture that exercised a copy would pass while
      # the file everyone actually loads was broken.
      def chart_shell_tag(fixture)
        return '' unless fixture.needs_chart_shell?

        raise HarnessError, "the chart shell is missing at #{CHART_SHELL}" unless File.exist?(CHART_SHELL)

        "<script>\n#{File.read(CHART_SHELL, encoding: 'UTF-8')}\n</script>"
      end

      def write_document(fixture, number, result)
        return nil unless result.is_a?(Render::Success)

        path = File.join(work_dir, "#{fixture.id}-#{number}.pdf")
        File.binwrite(path, result.bytes)
        path
      end

      # Every attempt must pass. The first non-pass is what gets reported, because the
      # useful artefact of a flaky wall-clock case is the attempt that failed, not the
      # two that happened to work.
      def worst(fixture, outcomes)
        outcomes.find { |o| !o.pass? } || outcomes.last
      end

      def outcome(fixture, state, reason, duration, checks_run: 0, degradations: [])
        Outcome.new(fixture_id: fixture.id, title: fixture.title, area: fixture.area,
                    state: state, reason: reason, duration_ms: duration.round,
                    checks_run: checks_run, degradations: degradations)
      end

      def degradations_of(result)
        result.respond_to?(:degradations) ? result.degradations.map { |d| d.capability.to_s } : []
      end

      def monotonic_ms
        # CLOCK_MONOTONIC, and it has to be: the aggregation corpus runs under a frozen
        # clock and a wall-clock reading there measures zero for everything
        # (HANDOVER §1). A render harness has no such pin today, and inheriting the
        # habit costs nothing.
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      end

      def safe(method, fallback)
        engine.respond_to?(method) ? engine.public_send(method) : fallback
      rescue StandardError
        fallback
      end
    end

    # ------------------------------------------------------------------------
    # The result of one engine's run over the corpus.
    # ------------------------------------------------------------------------
    class Report
      attr_reader :engine_id, :engine_version, :capabilities, :outcomes

      def initialize(engine_id:, engine_version:, capabilities:, outcomes:)
        @engine_id = engine_id
        @engine_version = engine_version
        @capabilities = Array(capabilities).map(&:to_sym)
        @outcomes = outcomes
      end

      def counts
        STATES.to_h { |state| [state, outcomes.count { |o| o.state == state }] }
      end

      def green?
        counts[:fail].zero? && counts[:error].zero?
      end

      def [](fixture_id)
        outcomes.find { |o| o.fixture_id == fixture_id }
      end

      def summary_line
        c = counts
        "#{engine_id} #{engine_version}: #{c[:pass]} pass, #{c[:fail]} fail, " \
          "#{c[:skip]} skip, #{c[:error]} harness error"
      end
    end
  end
end
