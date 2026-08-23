# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'conformance'
require_relative 'matrix'
require_relative 'harness_engines'

module RedmineReporterDashboards
  module Conformance
    # THE HARNESS, NEGATIVE-TESTED.
    #
    # Everything here runs without an engine, without a browser and without a database.
    # It is the answer to the question a conformance suite has to answer about itself:
    # can any of these cells ever be red? `layer_purity.sh` shipped a version that
    # reported every layer clean while checking nothing, and the only reason that was
    # caught is that somebody planted the violation before trusting the gate. So each
    # arm of the three-state rule is driven here by an engine built to produce it.
    RSpec.describe 'the conformance harness' do
      let(:work_dir) { Dir.mktmpdir('rrd-harness') }

      after { FileUtils.rm_rf(work_dir) }

      # Synthetic fixtures, deliberately NOT the F-* corpus: those are about what a
      # browser does with a document, and a fake engine answering them would be the
      # harness testing itself and calling it an engine result.
      def synthetic(id:, requires: [], expect_failure: nil, allow_failure: false, &checks)
        dir = File.join(work_dir, id)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, 'document.html'), '<html><body>SYNTHETIC</body></html>')
        Fixture.new(id: id, title: "synthetic #{id}", dir: dir).tap do |f|
          f.requires!(*requires)
          f.expect_failure!(expect_failure) if expect_failure
          f.allow_failure! if allow_failure
          checks&.call(f)
        end
      end

      def run_one(engine, fixture)
        Runner.new(engine: engine, work_dir: work_dir).run([fixture])[fixture.id]
      end

      # THE PROBES ARE A HARD REQUIREMENT OF THIS SUITE AND AN OPTIONAL PACKAGE ON MOST
      # MACHINES, and those two facts have to be reconciled somewhere.
      #
      # `render-smoke` asserts poppler is installed in a step of its own and then runs
      # everything here for real. The four `rspec` jobs have no browser and no poppler
      # by design — they stub Redmine away and run on four branches, and this file has
      # nothing to do with Redmine. So the reconciliation is: where the probes exist,
      # run; where they do not, skip with the package named.
      #
      # That is a skip with a reason rather than a silent one, and the thing it must not
      # become — a check nobody runs — is answered by render-smoke running it on every
      # push. If that job ever stops asserting the probes are present, this becomes the
      # failure mode this repository keeps rediscovering, so the two belong together.
      before do
        if PdfProbe.missing_tools.any?
          skip "#{PdfProbe.missing_tools.join(', ')} not installed (#{PdfProbe::INSTALL_HINT}); " \
               'the render-smoke job runs this suite with them present'
        end
      end

      # ---- G12, arm by arm --------------------------------------------------

      describe 'the three-state rule (G12)' do
        it 'SKIPS a fixture whose capability the engine does not declare, and names it' do
          fixture = synthetic(id: 'S-01', requires: [:tagged_pdf]) do |f|
            f.check('never reached') { |v| v.expect_true(false, 'this check must not run') }
          end

          outcome = run_one(HarnessEngines.limited(without: :tagged_pdf), fixture)

          expect(outcome).to be_skip
          expect(outcome.reason).to include('tagged_pdf')
          expect(outcome.checks_run).to eq(0)
        end

        # The arm that makes the matrix worth reading. An engine that declares a
        # capability and does not deliver it is not "unsupported", it is WRONG.
        it 'FAILS HARD when the engine declares the capability and the fixture fails' do
          fixture = synthetic(id: 'S-02', requires: [:tagged_pdf]) do |f|
            f.check('the document says what it should') do |v|
              v.expect_includes(v.text, 'SOMETHING-ELSE', 'document text')
            end
          end

          outcome = run_one(HarnessEngines.perfect, fixture)

          expect(outcome).to be_fail
          expect(outcome.reason).to include('the document says what it should')
          expect(outcome.reason).to include('SOMETHING-ELSE')
        end

        it 'PASSES when the engine declares it and delivers it' do
          fixture = synthetic(id: 'S-03', requires: [:tagged_pdf]) do |f|
            f.check('the canned document is readable') do |v|
              v.expect_includes(v.text, 'HARNESS-CANNED-PDF', 'document text')
              v.expect_equal(v.page_count, 1, 'page count')
            end
          end

          outcome = run_one(HarnessEngines.perfect, fixture)

          expect(outcome).to be_pass
          expect(outcome.checks_run).to eq(1)
        end
      end

      # ---- what the harness must not let through ----------------------------

      describe 'engines that misbehave' do
        # INV-5's post-conditions live in Renderer, above every adapter. The harness
        # must report the resulting Failure as a fixture failure rather than crashing,
        # or the one defect the whole render layer exists to prevent goes unreported.
        it 'reports non-PDF bytes as a fixture failure, not as an exception' do
          fixture = synthetic(id: 'S-04') do |f|
            f.check('renders') { |v| v.expect_equal(v.page_count, 1, 'page count') }
          end

          outcome = run_one(HarnessEngines.liar, fixture)

          expect(outcome).to be_fail
          expect(outcome.reason).to include('output_not_pdf')
        end

        it 'reports a crashing engine as a typed failure' do
          fixture = synthetic(id: 'S-05') do |f|
            f.check('renders') { |v| v.expect_equal(v.page_count, 1, 'page count') }
          end

          outcome = run_one(HarnessEngines.crasher, fixture)

          expect(outcome).to be_fail
          expect(outcome.reason).to include('engine_crashed')
        end

        # A fixture expecting a refusal must not be satisfiable by a render, or
        # "refused correctly" and "did the wrong thing" become the same green cell.
        it 'fails a refusal fixture that got a document instead' do
          fixture = synthetic(id: 'S-06', expect_failure: :timeout)

          outcome = run_one(HarnessEngines.perfect, fixture)

          expect(outcome).to be_fail
          expect(outcome.reason).to include('expected Failure(timeout), got a Success')
        end

        it 'passes a refusal fixture that got the refusal it named' do
          fixture = synthetic(id: 'S-07', requires: [], expect_failure: :capability_unsupported)
          fixture.request_for! do |engine|
            wanted = [(Render::Capabilities::ALL - Array(engine.capabilities)).first]
            { required_capabilities: wanted, essential_capabilities: wanted }
          end
          fixture.check('typed') { |v| v.expect_failure_code(:capability_unsupported) }

          outcome = run_one(HarnessEngines.limited(without: :outline), fixture)

          expect(outcome).to be_pass
        end

        it 'lets a both-arms fixture accept either, and still bounds it' do
          fixture = synthetic(id: 'S-08', allow_failure: true) do |f|
            f.check('is a Result') do |v|
              v.expect_true(Render::Result.result?(v.result), "got #{v.result.class}")
            end
          end

          expect(run_one(HarnessEngines.perfect, fixture)).to be_pass
          expect(run_one(HarnessEngines.crasher, fixture)).to be_pass
        end
      end

      # ---- the harness's own faults are its own column ----------------------

      describe 'harness faults' do
        it 'reports a broken fixture as a harness ERROR, not as an engine failure' do
          fixture = Fixture.new(id: 'S-09', title: 'missing document', dir: File.join(work_dir, 'nope'))

          outcome = run_one(HarnessEngines.perfect, fixture)

          expect(outcome).to be_error
          expect(outcome.reason).to include('harness:')
        end

        # The failure mode this repository keeps rediscovering: a check that did not run
        # looks exactly like a check that passed.
        it 'refuses to run at all when the PDF probes are missing' do
          allow(PdfProbe).to receive(:missing_tools).and_return(['pdftotext'])

          expect { Runner.new(engine: HarnessEngines.perfect, work_dir: work_dir).run([]) }
            .to raise_error(PdfProbe::ToolMissing, /pdftotext.*poppler-utils/m)
        end
      end

      describe 'repeated attempts' do
        it 'reports the attempt that failed, not the ones that did not' do
          calls = 0
          fixture = synthetic(id: 'S-10') do |f|
            f.attempts!(3)
            f.check('flaky') do |v|
              calls += 1
              v.expect_true(calls != 2, "attempt #{calls} was made to fail")
            end
          end

          outcome = run_one(HarnessEngines.perfect, fixture)

          expect(outcome).to be_fail
          expect(outcome.reason).to include('attempt 2/3')
        end
      end

      # ---- G9, the generated matrix -----------------------------------------

      describe 'matrix generation (G9)' do
        let(:catalogue) { Render::EngineCatalogue.load }

        # Driven from a stand-in catalogue rather than the committed one, so it keeps
        # asserting whatever `config/capabilities.yml` currently claims. Written against
        # the real file it would have been a pass-by-vacuity the day both engines were
        # `pending` — which is the day it was written.
        it 'refuses to print a column for an engine that claims a corpus run and did not run' do
          claiming = Render::EngineCatalogue::Engine.new(
            id: 'claims_corpus', label: 'c', role: 'reference', default: true,
            verification: 'corpus', verification_note: nil, needs_service: false,
            renders_offline: true, install: 'x', version_floor: 'v1',
            asset_models: ['inline'], deprecated: false, deprecation: nil,
            trade: 'claims to have been run', capabilities: [:timeout]
          )
          stub = instance_double(Render::EngineCatalogue, engines: [claiming],
                                                          source_name: '`stub`')

          expect { Matrix.render(reports: {}, fixtures: [], catalogue: stub) }
            .to raise_error(HarnessError, /and none was supplied/)
        end

        it 'renders the three states into the three cells they mean' do
          fixtures = [
            synthetic(id: 'S-11', requires: [:tagged_pdf]) { |f| f.check('ok') { |_v| true } },
            synthetic(id: 'S-12', requires: [:outline]) { |f| f.check('ok') { |_v| true } }
          ]
          engine = HarnessEngines.limited(without: :outline)
          report = Runner.new(engine: engine, work_dir: work_dir).run(fixtures)

          # A stand-in catalogue entry, because the real one has no adapter yet.
          entry = Render::EngineCatalogue::Engine.new(
            id: 'limited', label: 'l', role: 'reference', default: true,
            verification: 'corpus', verification_note: nil, needs_service: false,
            renders_offline: true, install: 'x', version_floor: 'v1',
            asset_models: ['inline'], deprecated: false, deprecation: nil,
            trade: 'a stand-in', capabilities: engine.capabilities
          )
          stub = instance_double(Render::EngineCatalogue, engines: [entry],
                                                          source_name: '`stub`')

          markdown = Matrix.render(reports: { 'limited' => report }, fixtures: fixtures,
                                   catalogue: stub)

          expect(markdown).to include('| `S-11` | synthetic S-11 | PASS |')
          expect(markdown).to include('| `S-12` | synthetic S-12 | SKIP — limited does not declare :outline |')
          expect(markdown).to include('| `:outline` | — |')
          expect(markdown).to include('| `:tagged_pdf` | yes |')
        end

        # THE GENERATOR'S UNVERIFIED HALF, KEPT ALIVE BY A SYNTHETIC ENTRY. `Matrix#cell`'s
        # `'not verified'` branch and the whole `footer_section` became unreachable from the
        # shipped catalogue on 2026-08-11, and an unreachable branch with no stand-in test is
        # how the next engine's column silently prints wrong. Found by a UX review reading the
        # regenerated matrix.
        it 'prints "not verified" and the note for an engine that has not been run' do
          pending_engine = Render::EngineCatalogue::Engine.new(
            id: 'unrun', label: 'u', role: 'documented', default: true,
            verification: 'pending',
            verification_note: 'nobody has run this, and this sentence is what the matrix ' \
                               'prints instead of cells nobody measured',
            needs_service: true, renders_offline: true, install: 'a service you run',
            version_floor: 'v1', asset_models: ['upload'], deprecated: false, deprecation: nil,
            trade: 'a stand-in for an engine at pending', capabilities: [:timeout]
          )
          stub = instance_double(Render::EngineCatalogue, engines: [pending_engine],
                                                         source_name: '`stub`')
          markdown = Matrix.render(reports: {}, fixtures: [synthetic(id: 'S-90')],
                                   catalogue: stub)

          expect(markdown).to include('| `S-90` | synthetic S-90 | not verified |')
          expect(markdown).to include('## Columns that are not measurements')
          expect(markdown).to include('nobody has run this')
        end
      end
    end

    # ------------------------------------------------------------------------
    # The declaration file itself (DoR-5).
    # ------------------------------------------------------------------------
    RSpec.describe Render::EngineCatalogue do
      subject(:catalogue) { described_class.load }

      it 'validates every declared capability against the closed vocabulary' do
        catalogue.engines.each do |engine|
          expect(engine.capabilities).to all(satisfy { |c| Render::Capabilities.known?(c) })
        end
      end

      it 'names exactly one default engine' do
        expect(catalogue.engines.count(&:default)).to eq(1)
        expect(catalogue.default_engine.id).to eq('chromium_cdp')
      end

      it 'describes all three asset models, because the policy table reads across them' do
        expect(catalogue.asset_models.keys).to match_array(%w[inline upload fetch])
        expect(catalogue.asset_models['fetch']['egress']).to be(true)
        expect(catalogue.asset_models['inline']['egress']).to be(false)
      end

      it 'gives every engine a trade line an operator can read' do
        catalogue.engines.each do |engine|
          expect(engine.trade.to_s.length).to be > 40, "#{engine.id} has no usable trade line"
          expect(engine.install.to_s).not_to be_empty
        end
      end

      # An engine that is not corpus-verified must SAY why, in the file, where the
      # matrix generator can print it. INV-7 applied to engines.
      #
      # THIS LOOP IS EMPTY TODAY, AND SAYING SO IS THE POINT. Every shipped engine has been
      # `verification: corpus` since 2026-08-11, so it iterates nothing and passes — the
      # shape this repository keeps rediscovering. It stays, because the property has to hold
      # for the next engine added at `pending`; the SYNTHETIC example below is what keeps the
      # generator's unverified path alive, and the assertion on the catalogue itself is what
      # stops this passing because the file failed to load.
      it 'makes every unverified engine explain itself' do
        expect(catalogue.engines).not_to be_empty

        catalogue.engines.reject(&:corpus_verified?).each do |engine|
          expect(engine.verification_note.to_s.length).to be > 40,
                                                          "#{engine.id} is unverified and says nothing about why"
        end
      end

      it 'refuses a capability outside the vocabulary' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'capabilities.yml')
          File.write(path, File.read(described_class::DEFAULT_PATH, encoding: 'UTF-8')
                               .sub('      - javascript', '      - teleportation'))

          expect { described_class.new(path) }
            .to raise_error(described_class::InvalidCatalogue, /teleportation/)
        end
      end

      # AN ENGINE MUST DECLARE AT LEAST ONE ASSET MODEL (§Findings E-29 row 14, taken). An
      # empty list validated, and the settings screen printed `—` in the Assets column —
      # indistinguishable from an engine this file has never described — while the engine's
      # inability to carry ANY asset was excluded from "Not supported" as a matter of policy.
      it 'refuses an engine that declares no asset model at all' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'capabilities.yml')
          File.write(path, File.read(described_class::DEFAULT_PATH, encoding: 'UTF-8')
                               .sub("    asset_models: [inline]\n", "    asset_models: []\n"))

          expect { described_class.new(path) }
            .to raise_error(described_class::InvalidCatalogue, /declares no asset models/)
        end
      end

      it 'refuses a file with two defaults, because the fallback would depend on hash order' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'capabilities.yml')
          File.write(path, File.read(described_class::DEFAULT_PATH, encoding: 'UTF-8')
                               .sub("    role: compatibility\n    default: false",
                                    "    role: compatibility\n    default: true"))

          expect { described_class.new(path) }
            .to raise_error(described_class::InvalidCatalogue, /exactly one/)
        end
      end
    end
  end
end
