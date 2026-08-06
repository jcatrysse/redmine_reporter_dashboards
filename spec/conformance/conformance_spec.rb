# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'conformance'
require_relative 'matrix'
require_relative '../../lib/redmine_reporter_dashboards/render/registry'
require_relative '../../lib/redmine_reporter_dashboards/render/engine_catalogue'

module RedmineReporterDashboards
  module Conformance
    # The corpus, run against every engine that actually exists.
    #
    # --- WHY THIS IS OPT-IN ---
    #
    # It needs a browser. The `rspec` CI job deliberately has none — it stubs Redmine
    # away, boots nothing and runs on four Redmine branches, and adding a Chromium
    # install to it would quadruple the cost of the fastest feedback in the project. So
    # the corpus runs in one job, `render-smoke`, behind `RRD_CONFORMANCE=1`.
    #
    # --- AND WHY OPT-IN IS NOT THE SAME AS OPTIONAL ---
    #
    # An opt-in suite that nobody opts into is a directory of dead code, and this
    # repository has a rule about checks that quietly do not run. Two things stop that
    # here. The catalogue drives it: an engine declared `verification: corpus` with no
    # registered adapter is a FAILURE, not a skip, so the moment T-13 flips those flags
    # this suite becomes mandatory for the engines it names. And gate G9 compares the
    # committed support matrix with a fresh run, so a corpus that stopped running shows
    # up as a matrix that stopped matching.
    ENGINE_DIR = File.expand_path('../../lib/redmine_reporter_dashboards/render/engines', __dir__)

    RSpec.describe 'engine conformance' do
      before(:all) do
        Dir[File.join(ENGINE_DIR, '*.rb')].sort.each { |path| require path }
      end

      let(:catalogue) { Render::EngineCatalogue.load }

      # The one assertion that must run even where no engine can: an engine the
      # catalogue says has been conformance-verified, with no adapter behind it, is a
      # support claim with nothing under it. INV-7 is this project's record of what that
      # costs — four minor versions of a Redmine 5.1 claim CI never ran, and two defects
      # shipping since v0.5.0 in the configuration nobody tested.
      it 'has an adapter for every engine the catalogue says was conformance-verified' do
        claimed = catalogue.engines.select(&:corpus_verified?).map(&:id)
        registered = Render::Registry.ids.map(&:to_s)

        expect(claimed - registered).to be_empty,
                                        "#{(claimed - registered).join(', ')} claim `verification: corpus` in " \
                                        'config/capabilities.yml and have no registered adapter. Either the ' \
                                        'adapter is missing or the claim is.'
      end

      # The corpus itself has to be loadable everywhere, browser or not. A fixture with
      # a syntax error, a duplicate id or a missing document would otherwise be found
      # only in the one job that has an engine.
      it 'loads every fixture, each with a document and at least one check' do
        fixtures = Fixtures.load_all

        expect(fixtures).not_to be_empty
        fixtures.each do |fixture|
          expect(File.exist?(fixture.document_path)).to be(true), "#{fixture.id} has no document"
          expect(fixture.checks).not_to be_empty, "#{fixture.id} asserts nothing"
          expect(fixture.requires).to all(satisfy { |c| Render::Capabilities.known?(c) }),
                                      "#{fixture.id} requires a capability outside the closed vocabulary"
        end
      end
    end

    # One describe per registered engine, generated at load time. Generated rather than
    # written so that adding an adapter adds its conformance suite — a hand-written
    # block per engine is a block somebody forgets, and the forgetting looks like a pass.
    def self.selected_engine_ids
      wanted = ENV['RRD_ENGINE'].to_s.split(',').map(&:strip).reject(&:empty?)
      ids = Render::Registry.ids.map(&:to_s)
      wanted.empty? ? ids : ids & wanted
    end

    def self.corpus_enabled?
      ENV['RRD_CONFORMANCE'] == '1'
    end

    RSpec.describe 'the support matrix (G9)' do
      # The matrix is regenerated from whatever ran and compared with the committed
      # file. Where no engine ran, the committed file's engine columns are literal
      # ("no adapter") and this still checks the parts that do not need one — the
      # engine list, the declared capabilities, the fixture list. A matrix that is only
      # checked when a browser is present is a matrix that drifts on every other run.
      let(:committed) { File.expand_path('../../docs/engine-support-matrix.md', __dir__) }

      it 'matches a fresh generation' do
        # G9 HAS ONE HOME, and it is the job with the engines in it. Checked anywhere
        # else this example asks a machine with no browser whether a browser's cells are
        # right, and the only truthful answer is "cannot tell" — which is a skip with a
        # reason, not a red build and not a quiet pass.
        unless RedmineReporterDashboards::Conformance.corpus_enabled?
          skip 'G9 is checked in the render-smoke job (RRD_CONFORMANCE=1), which is the ' \
               'one place every engine the catalogue calls `corpus` can actually run'
        end

        fixtures = Fixtures.load_all
        Render::EngineCatalogue.load.engines.select(&:corpus_verified?).each do |engine|
          RenderedReports.for(engine.id)
        end
        generated = Matrix.render(reports: RenderedReports.measured, fixtures: fixtures)

        if ENV['RRD_MATRIX_WRITE'] == '1'
          File.write(committed, generated)
          skip 'RRD_MATRIX_WRITE=1 — the matrix was regenerated rather than checked'
        end

        expect(File.read(committed, encoding: 'UTF-8')).to eq(generated),
                                                           'docs/engine-support-matrix.md disagrees with a fresh conformance run. ' \
                                                           'Regenerate it in the same commit as the change that moved it: ' \
                                                           'RRD_CONFORMANCE=1 RRD_MATRIX_WRITE=1 rspec spec/conformance'
      end
    end

    # ONE RUN PER ENGINE, whoever asks for it first.
    #
    # `config.order = :random` is on in this project, so the matrix example and the
    # per-engine suite can execute in either order — and the first draft of this file
    # assumed one of them. When the matrix went first it found no reports and refused to
    # generate, which is the generator behaving correctly and the caller being wrong. A
    # memo shared by both is the fix; a `before(:all)` that another example depends on
    # is a defect waiting for a seed.
    module RenderedReports
      Unavailable = Struct.new(:engine_id, :reason, :claimed) do
        def available?
          false
        end
      end

      class << self
        def all
          @all ||= {}
        end

        # Reports for engines the catalogue says are conformance-verified. This is what
        # the matrix is generated from, and an unavailable engine is deliberately NOT in
        # it — the generator then refuses, rather than printing an empty column.
        def measured
          all.reject { |_id, report| report.respond_to?(:available?) }
        end

        def for(engine_id)
          all[engine_id.to_s] ||= execute(engine_id.to_s)
        end

        private

        def execute(engine_id)
          engine = Render::Registry.fetch(engine_id).new
          begin
            # PREFLIGHT IS A ROUND TRIP, never `File.exist?` (technical-spec.md §5). It
            # is also what warms the engine: the first render of a process pool pays for
            # a browser launch, and charging that to the first fixture would make the
            # readiness bounds a measurement of startup cost.
            preflight = engine.preflight
            return unavailable(engine_id, preflight) unless preflight.success?

            report = Runner.new(engine: engine).run(Fixtures.load_all)
            warn "\n[conformance] #{report.summary_line}"
            report
          ensure
            engine.shutdown if engine.respond_to?(:shutdown)
          end
        end

        # THE THREE-STATE RULE, APPLIED ONE LEVEL UP. A dead preflight means one of two
        # entirely different things, and collapsing them is how a support matrix starts
        # lying. An engine the catalogue calls `verification: corpus` is supposed to be
        # measured here, so a dead preflight is a FAILURE. One it does not is simply
        # absent from this environment — wkhtmltopdf on a container that cannot install
        # it — and the honest outcome is a skip naming the engine.
        def unavailable(engine_id, preflight)
          entry = Render::EngineCatalogue.load[engine_id]
          Unavailable.new(engine_id,
                          "#{preflight.code}: #{preflight.detail}",
                          entry&.corpus_verified? ? true : false)
        end
      end
    end
  end
end

# ---------------------------------------------------------------------------
# The per-engine suites.
#
# Built after the class bodies above so that `Registry` has been populated by the
# `require` of every adapter — which happens here rather than in a `before(:all)`,
# because a describe block has to exist at load time to contain examples at all.
# ---------------------------------------------------------------------------
Dir[File.join(RedmineReporterDashboards::Conformance::ENGINE_DIR, '*.rb')].sort.each do |path|
  require path
end

RedmineReporterDashboards::Conformance.selected_engine_ids.each do |engine_id|
  RSpec.describe "engine conformance: #{engine_id}" do
    conformance = RedmineReporterDashboards::Conformance

    before(:all) do
      skip 'set RRD_CONFORMANCE=1 to run the corpus' unless conformance.corpus_enabled?

      @report = conformance::RenderedReports.for(engine_id)
      if @report.respond_to?(:available?)
        if @report.claimed
          raise "#{engine_id} claims `verification: corpus` in config/capabilities.yml " \
                "and its preflight failed: #{@report.reason}"
        end

        skip "#{engine_id} is not available here (#{@report.reason}); the catalogue does " \
             'not claim a conformance run for it'
      end
      @engine = RedmineReporterDashboards::Render::Registry.fetch(engine_id).new
    end

    it 'declares exactly what config/capabilities.yml says it declares' do
      declared = RedmineReporterDashboards::Render::EngineCatalogue.load[engine_id].capabilities
      expect(@engine.capabilities.sort).to eq(declared.sort),
                                           'the adapter and the catalogue disagree about what this engine can do. ' \
                                           'They are the same fact written twice; either both change or neither does.'
    end

    it 'reports a version probed from the binary rather than a constant' do
      expect(@engine.version.to_s).not_to be_empty
    end

    # One example per fixture, so a red cell names itself in the CI output instead of
    # being one line inside a single giant example's failure message.
    RedmineReporterDashboards::Conformance::Fixtures.load_all.each do |fixture|
      it "#{fixture.id} — #{fixture.title}" do
        outcome = @report[fixture.id]

        case outcome.state
        when :skip then skip outcome.reason
        when :error then raise "harness error: #{outcome.reason}"
        else
          expect(outcome.state).to eq(:pass),
                                   "#{outcome.reason} (#{outcome.duration_ms} ms)"
        end
      end
    end
  end
end
