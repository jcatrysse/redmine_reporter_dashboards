# frozen_string_literal: true

require 'stringio'

require_relative '../spec_helper'
require_relative '../conformance/harness_engines'
require_relative '../../lib/redmine_reporter_dashboards/render/preflight_command'
require_relative '../../lib/redmine_reporter_dashboards/render/preflight_suite'

module RedmineReporterDashboards
  module Render
    # T-14 — the rake task's decisions, where a test can reach them.
    #
    # The Accept list asks for a task that EXITS NON-ZERO, and an exit code is the one
    # part of a diagnostic nobody reads carefully: it is consumed by a deploy step. So
    # every code this can return is driven here, including the two that are easy to get
    # wrong — an engine that cannot even be constructed, and no engine at all.
    RSpec.describe PreflightCommand do
      # Adapters, not instances: `Registry` maps an id to a CLASS the command news up,
      # which is the part of the contract the rake task depends on. Built on the
      # harness's `Scripted` rather than a fresh fake, so there is one fake engine in
      # this repository and not two that can disagree.
      let(:good) do
        Class.new(Conformance::HarnessEngines::Scripted) do
          def initialize(*)
            super(id: :good, version: 'good-1')
          end
        end
      end

      # A report whose only check is in the state the example is about. Preflight's own
      # behaviour is spec'd next door; what is under test here is what the COMMAND does
      # with the answer.
      def report(state, engine_id: :good, detail: 'd')
        Preflight::Report.new(
          engine_id: engine_id, engine_version: 'good-1', duration_ms: 1,
          checks: [Preflight::Check.new(id: :engine, title: 't', state: state,
                                        detail: detail, duration_ms: 1)]
        )
      end

      def stub_preflight(state)
        allow_any_instance_of(Preflight).to receive(:run).and_return(report(state))
      end

      let(:out) { StringIO.new }

      def run(**options)
        described_class.new(out: out, **options).call
      end

      # `isolated` rather than `reset!`: this suite runs with a random seed and the real
      # adapters register when their files load, so a reset without a restore leaves
      # every later example looking at an empty map. That has already happened once.
      around { |example| Registry.isolated { example.run } }

      describe 'the exit code' do
        it 'is 0 when every check that ran passed' do
          Registry.register(:good, good)
          stub_preflight(:pass)

          expect(run).to eq(described_class::OK)
        end

        it 'is 1 when a check failed' do
          Registry.register(:good, good)
          stub_preflight(:fail)

          expect(run).to eq(described_class::FAILURES)
        end

        # A SKIP IS NOT A FAILURE — poppler is an optional package, and treating a
        # missing microscope as a sick patient is how an exit code stops being read.
        # The report still says so; see Preflight::Check.
        it 'is 0 when a check could only be skipped, and the text says so' do
          Registry.register(:good, good)
          stub_preflight(:skip)

          expect(run).to eq(described_class::OK)
          expect(out.string).to include('could not run')
        end

        # And the third state: the Redmine-hosted image is SUPPOSED to be blocked under
        # the default policy. Colouring it like a real failure is how the real one gets
        # ignored.
        it 'is 0 for an expected_failure' do
          Registry.register(:good, good)
          stub_preflight(:expected_failure)

          expect(run).to eq(described_class::OK)
        end

        # THE ONE THAT MUST NOT BE 0. "No engine is registered" is not a render defect,
        # so it is not a 1 — but a green preflight that verified nothing is the failure
        # mode this repository keeps rediscovering, so it is not a 0 either.
        it 'is 2 when no engine is registered, and says nothing was verified' do
          expect(run).to eq(described_class::NOTHING_TO_RUN)
          expect(out.string).to include('NO ENGINE REGISTERED')
          expect(out.string).to include('nothing was verified')
        end

        # An unstartable engine is the single most likely thing this command finds —
        # Chromium not installed — and it is an ANSWER, not a crash out of a diagnostic.
        it 'is 1, not an exception, when the adapter cannot even be constructed' do
          broken = Class.new do
            def initialize(*)
              raise Errno::ENOENT, 'chromium'
            end
          end
          Registry.register(:broken, broken)

          expect(run).to eq(described_class::FAILURES)
          expect(out.string).to include('FAIL')
          expect(out.string).to include('chromium')
        end
      end

      describe 'engine selection' do
        before do
          Registry.register(:a, good)
          Registry.register(:b, good)
          stub_preflight(:pass)
        end

        it 'runs every registered engine when none was named' do
          run

          expect(out.string.scan('render preflight:').length).to eq(2)
        end

        it 'accepts a comma-separated list, as the env var supplies it' do
          run(engine_ids: 'a, b')

          expect(out.string.scan('render preflight:').length).to eq(2)
        end

        it 'runs only the engine named' do
          run(engine_ids: 'a')

          expect(out.string.scan('render preflight:').length).to eq(1)
        end

        # A TYPO MUST NOT LOOK LIKE A CLEAN RUN — and it must not look like a broken
        # renderer either. The first version let `UnknownEngine` out of `call`, so rake
        # aborted with a stack trace and exit **1**, indistinguishable from FAILURES: an
        # operator who typed `chromium_cpd` in a deploy step was told render is broken.
        # It lands on 2, with the rest of "nothing was verified".
        it 'exits 2 on an id the registry does not have, naming it and the known ids' do
          expect(run(engine_ids: 'chromium_cpd')).to eq(described_class::NOTHING_TO_RUN)
          expect(out.string).to include('chromium_cpd')
          expect(out.string).to include('Known: a, b')
          expect(out.string).to include('Nothing was verified')
        end

        # The suite still raises rather than matching nothing — that is where the
        # decision belongs, and the command is what turns it into an exit code.
        it 'is the suite that refuses, not the command that guesses' do
          expect { PreflightSuite.new(engine_ids: 'nope').resolved_ids }
            .to raise_error(Registry::UnknownEngine, /nope.*Known: a, b/m)
        end

        # E-27 row 8. `RRD_ENGINE='  '` and `RRD_ENGINE=','` normalised to an EMPTY list,
        # and an empty list means "run the defaults" — so a mangled selection in a deploy
        # step silently verified engines nobody named, while `RRD_ENGINE=chromium_cpd`
        # correctly exited 2. Given-but-unparseable is now the typo case.
        ['  ', ',', ' , ', "\t"].each do |mangled|
          it "exits 2 on #{mangled.inspect} — a selection was given and it names nothing" do
            expect(run(engine_ids: mangled)).to eq(described_class::NOTHING_TO_RUN)
            expect(out.string).to include('names no render engine')
            expect(out.string).to include('Known: a, b')
            expect(out.string).to include('Nothing was verified')
          end
        end

        # And the rule cuts at NON-EMPTY, deliberately: unset and `VAR=` are both how an
        # environment says "nobody selected", and refusing those would turn every deploy
        # script that does not export RRD_ENGINE into exit 2.
        [nil, ''].each do |unset|
          it "still runs the default set for #{unset.inspect}" do
            expect(run(engine_ids: unset)).to eq(described_class::OK)
            expect(out.string.scan('render preflight:').length).to eq(2)
          end
        end
      end

      describe 'output format' do
        before do
          Registry.register(:a, good)
          stub_preflight(:pass)
        end

        it 'prints text by default' do
          run

          expect(out.string).to start_with('render preflight: good good-1')
        end

        it 'prints parseable JSON when asked, so it can go in an issue' do
          run(format: :json)

          parsed = JSON.parse(out.string)
          expect(parsed.length).to eq(1)
          expect(parsed.first['engine']).to eq('good')
          expect(parsed.first['checks'].first['state']).to eq('pass')
        end

        it 'refuses an unknown format at construction, not halfway through a run' do
          expect { described_class.new(format: :xml) }
            .to raise_error(ArgumentError, /xml.*text.*json/m)
        end
      end

      # A DIAGNOSTIC MUST NOT LEAK THE RESOURCE IT DIAGNOSES. The Chromium adapter owns
      # a process pool that starts a browser on its first render; running two engines in
      # one invocation is the default, and leaving the first one's browser alive while
      # the second launches doubles what this costs on a box whose render path is
      # already suspect.
      describe 'cleanup' do
        let(:closing) do
          Class.new(Conformance::HarnessEngines::Scripted) do
            attr_reader :shutdowns

            def initialize(*)
              super(id: :closing, version: 'closing-1')
              @shutdowns = 0
            end

            def shutdown
              @shutdowns += 1
            end
          end
        end

        it 'shuts every engine down, including on the failure path' do
          shut = []
          allow(closing).to receive(:new).and_wrap_original do |original|
            instance = original.call
            allow(instance).to receive(:shutdown) { shut << instance }
            instance
          end
          Registry.register(:a, closing)
          Registry.register(:b, closing)
          stub_preflight(:fail)

          expect(run).to eq(described_class::FAILURES)
          expect(shut.length).to eq(2)
        end

        # The report is already built by the time shutdown runs. Losing it to a cleanup
        # error would be the worst possible trade — and it is REPORTED, on the logger,
        # which is where every other render-layer diagnostic goes (`Renderer` logs its
        # degradations there too). `rescue nil` is a forbidden construct; silence would
        # be the same thing spelled differently.
        it 'reports a shutdown that failed without losing the report' do
          broken = Class.new(Conformance::HarnessEngines::Scripted) do
            def initialize(*)
              super(id: :broken, version: 'broken-1')
            end

            def shutdown
              raise IOError, 'the browser would not stop'
            end
          end
          Registry.register(:broken, broken)
          stub_preflight(:pass)

          logger = instance_double('Logger')
          lines = []
          allow(logger).to receive(:warn) { |line| lines << line }

          expect(run(logger: logger)).to eq(described_class::OK)
          expect(out.string).to include('render preflight:')
          expect(out.string).to include('PASS')
          expect(lines.join("\n")).to include('could not shut down broken')
          expect(lines.join("\n")).to include('the browser would not stop')
        end

        # An engine that never had a shutdown method must not be a NoMethodError out of
        # a diagnostic — most fakes, and any minimal adapter, have none.
        it 'is silent about an engine that has no shutdown' do
          Registry.register(:a, good)
          stub_preflight(:pass)

          expect(run).to eq(described_class::OK)
          expect(out.string).not_to include('shut down')
        end
      end

      describe 'the Redmine base URL' do
        # A PORT, not a lookup: `render/**` may not reach `Setting`, and the rake task
        # is the one line that knows Redmine has one. What this asserts is only that
        # whatever it is given reaches the Preflight.
        it 'is handed to the Preflight rather than discovered' do
          Registry.register(:a, good)

          expect(Preflight).to receive(:new)
            .with(hash_including(redmine_base_url: 'https://redmine.example'))
            .and_call_original

          run(redmine_base_url: 'https://redmine.example')
        end

      end
    end
  end
end
