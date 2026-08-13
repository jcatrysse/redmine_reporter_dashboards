# frozen_string_literal: true

module RedmineReporterDashboards
  module Conformance
    # One conformance case: a document, the request that draws it, the capabilities the
    # engine must DECLARE for the case to apply, and the checks its output must satisfy.
    #
    # --- THE THREE-STATE RULE LIVES IN `requires` (G12) ---
    #
    # `requires` is the whole mechanism. It is not "what this fixture is about", it is
    # "what the engine has to have claimed for a failure here to be its fault":
    #
    #   the engine does NOT declare it   -> SKIP, with the capability named in the reason
    #   the engine DOES declare it, fail -> HARD FAILURE; a declaration is a promise
    #   the engine DOES declare it, pass -> PASS
    #
    # The two-state version of this rule is what makes support matrices lie. An engine
    # that cannot draw a footer and never said so gets a red cell it did not earn; an
    # engine that said it could and cannot gets a green one it did not earn either.
    # Both are fixed by asking the engine first and holding it to its own answer.
    #
    # --- WHY THE DOCUMENT COMPUTES ITS OWN ANSWER ---
    #
    # Several fixtures (escaping, readiness, asset resolution) need to know what the
    # ENGINE'S OWN JS parser did with an input. The harness cannot ask an arbitrary
    # engine to evaluate an expression — only some declare `:readiness_expression` —
    # so instead the document writes its findings into the DOM and the harness reads
    # them out of the rendered PDF's text. One mechanism, every engine, and it tests
    # the thing that actually ships rather than a control channel nothing uses.
    class Fixture
      # Substituted into `document.html` before rendering. Placeholders rather than
      # `format` because a stylesheet is full of `%` and `50%` is not a format string.
      CHART_SHELL_TOKEN = '@@CHART_SHELL@@'
      EGRESS_URL_TOKEN = '@@EGRESS_URL@@'
      # T-38. The SHIPPED report stylesheet, inlined — for the reason `CHART_SHELL_TOKEN`
      # exists: a fixture that carried its own `display: table-header-group` would prove
      # that the ENGINE can repeat a table header, which nobody doubts, and nothing about
      # whether the stylesheet every report gets asks it to. What the two clauses T-38
      # asserts here are about is `ReportStylesheet`, so that is what goes in the document.
      REPORT_STYLESHEET_TOKEN = '@@REPORT_STYLESHEET@@'

      attr_reader :id, :title, :area, :dir, :requires, :harness_notes,
                  :request_overrides, :checks, :expect_failure, :readiness_options,
                  :repeat_attempts, :allow_failure

      def initialize(id:, title:, dir:)
        @id = id
        @title = title
        @dir = dir
        @area = id.downcase.gsub(/\AF-\d+-/, '').tr('-', '_').to_sym
        @requires = []
        @request_overrides = {}
        @readiness_options = nil
        @checks = []
        @expect_failure = nil
        @allow_failure = false
        @harness_notes = nil
        @repeat_attempts = 1
      end

      # ---- the declaration DSL, used by each F-nn-*/fixture.rb ----------------

      def requires!(*capabilities)
        @requires = capabilities.flatten.map(&:to_sym).uniq.freeze
      end

      def request!(**overrides)
        @request_overrides = overrides.freeze
      end

      # Overrides that can only be computed once the engine is known — the one real
      # case being "ask for something THIS engine cannot do", which is how a refusal is
      # provoked without hard-coding a capability that some future adapter happens to
      # have. Returning nil means the fixture does not apply to this engine, and the
      # runner skips it with the block's own reason rather than inventing one.
      def request_for!(&block)
        @dynamic_request = block
      end

      def dynamic_request(engine)
        return [{}, nil] unless @dynamic_request

        outcome = @dynamic_request.call(engine)
        return [{}, outcome] if outcome.is_a?(String)
        return [{}, 'the fixture does not apply to this engine'] if outcome.nil?

        [outcome, nil]
      end

      # A document too big or too repetitive to be worth committing as a file. The
      # block receives the substituted HTML and returns the final body — used by the
      # resource-envelope case, whose whole subject is a document with 2 000 rows in it.
      def expand!(&block)
        @expand = block
      end

      def expand(html)
        @expand ? @expand.call(html) : html
      end

      def readiness!(**options)
        @readiness_options = options.freeze
      end

      # A fixture whose PASS condition is a typed Failure. Without this, "the engine
      # refused correctly" and "the engine broke" are the same red cell.
      def expect_failure!(code)
        @expect_failure = code.to_sym
      end

      # BOTH ARMS ARE CORRECT for this fixture, and the checks decide which one it got.
      # The one case this exists for is pathological input: an engine that refuses a
      # 40 000-element table with a typed Failure has behaved WELL, and so has one that
      # renders it inside the envelope. What neither may do is hang, crash, or return
      # something that is not a Result — which is what the checks then assert.
      def allow_failure!
        @allow_failure = true
      end

      # Wall-clock cases are run more than once and must pass EVERY attempt. T-11's
      # Accept list asks for 3/3 with generous bounds rather than 1/1 with tight ones,
      # and the reasoning is written down there: a tight bound gets loosened after the
      # first flake and then proves nothing, while a bound that has to hold three times
      # cannot be satisfied by one lucky run.
      def attempts!(count)
        @repeat_attempts = Integer(count)
      end

      def note!(text)
        @harness_notes = text
      end

      # Each check is named. The name is what appears in the failure message and in
      # the generated matrix, so it has to read as a statement about the ENGINE
      # ("footer carries the page number on every page"), never about the harness.
      def check(name, &block)
        @checks << [name, block].freeze
      end

      # ---- what the runner needs ---------------------------------------------

      def document_path
        File.join(dir, 'document.html')
      end

      # THE BLOCK FORM FOR THE NEW TOKEN, and the reason is a latent defect rather than style:
      # `String#gsub` with a String replacement interprets `\\`, `\0` and `\1` in it, so a
      # replacement that ever contained a backslash would be mangled. A block replacement is
      # taken literally. The stylesheet has no backslash today (a spec asserts the CSS carries
      # no `url(`, and nothing else in it could) — this is the class of bug closed rather than
      # a bug fixed, and the two older tokens are left alone because changing them is not this
      # task's to do.
      def body(chart_shell: '', egress_url: '', report_stylesheet: '')
        expand(
          File.read(document_path, encoding: 'UTF-8')
              .gsub(CHART_SHELL_TOKEN, chart_shell)
              .gsub(EGRESS_URL_TOKEN, egress_url)
              .gsub(REPORT_STYLESHEET_TOKEN) { report_stylesheet }
        )
      end

      def needs_chart_shell?
        File.read(document_path, encoding: 'UTF-8').include?(CHART_SHELL_TOKEN)
      end

      def needs_egress_listener?
        File.read(document_path, encoding: 'UTF-8').include?(EGRESS_URL_TOKEN)
      end

      def needs_report_stylesheet?
        File.read(document_path, encoding: 'UTF-8').include?(REPORT_STYLESHEET_TOKEN)
      end

      def to_s
        "#{id} (#{title})"
      end
    end

    # The registry. `load_all` reads every `F-nn-*/fixture.rb` and each of those calls
    # `Conformance.fixture`. Plain `load` — never `constantize` on a name read from the
    # filesystem, which is the construct CLAUDE.md §5 forbids and FR-55 answers.
    module Fixtures
      class DuplicateFixture < StandardError; end

      class << self
        def root
          File.expand_path(__dir__)
        end

        def all
          @all ||= {}
        end

        def register(fixture)
          if all.key?(fixture.id)
            raise DuplicateFixture,
                  "#{fixture.id} is declared twice; a fixture id is how a matrix cell is " \
                  'addressed, so two of them means one silently replaces the other'
          end

          all[fixture.id] = fixture
        end

        # Idempotent, because it is called from more than one place and `load` would
        # otherwise re-execute every fixture file and hit `DuplicateFixture` — a
        # confusing way to discover that two callers both wanted the corpus.
        def load_all
          if all.empty?
            Dir[File.join(root, 'F-*', 'fixture.rb')].sort.each { |path| load path }
          end
          # Sorted by id so the matrix rows are stable across machines: Dir order is
          # not, and a matrix whose rows move fails G9's diff for no reason.
          all.values.sort_by(&:id)
        end

        def reset!
          @all = {}
        end
      end
    end

    def self.fixture(id, title, dir:)
      fixture = Fixture.new(id: id, title: title, dir: dir)
      yield fixture
      Fixtures.register(fixture)
      fixture
    end
  end
end
