# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../conformance/harness_engines'
require_relative '../../lib/redmine_reporter_dashboards/render/preflight'

module RedmineReporterDashboards
  module Render
    # T-14 — the diagnostic, negative-tested.
    #
    # --- WHY THE INTERESTING TESTS HERE ARE THE RED ONES ---
    #
    # A preflight is a gate, and this repository's rule about gates is that until you
    # have watched one fail you do not know it can (`HANDOVER.md` §1: `layer_purity.sh`
    # reported every layer clean while checking nothing). A preflight that returns eight
    # green checks against a real browser proves the browser works; it proves nothing
    # about the preflight. So most of this file drives it with documents that are
    # WRONG in exactly the ways the checks exist to catch, and asserts each check goes
    # red on its own.
    #
    # The canned harness PDF is perfect for that: it is a valid, single-page, text-only
    # document with no footer, no colour and no script. Every one of the six document
    # checks must fail on it, and `:engine` must still pass — because "bytes came back"
    # was the check that was already passing while every report lost its images.
    #
    # The real round trip against a real engine is at the bottom, behind
    # `RRD_CONFORMANCE=1`, next to the corpus that has the same requirement.
    RSpec.describe Preflight do
      let(:engine) { Conformance::HarnessEngines.perfect }

      def report_for(engine, **options)
        described_class.new(engine: engine, **options).run
      end

      def check(report, id)
        report.checks.find { |c| c.id == id } ||
          raise("no check #{id.inspect} in #{report.checks.map(&:id).inspect}")
      end

      describe 'the probe document' do
        subject(:html) { described_class.new(engine: engine).probe_document }

        # Each element is here because a specific defect hides behind its absence, so
        # each gets an assertion rather than being trusted to survive an edit.
        it 'carries an inline data: image, a canvas, a page break and a coloured fill' do
          expect(html).to include(described_class::PROBE_PNG)
          expect(html).to include('<canvas')
          expect(html).to include('page-break-before: always')
          expect(html).to include('#00aaff')
          expect(html).to include('#cc0000')
        end

        # THE SHIPPED SHELL, not a copy of it. Measured, and it is why the element is
        # there at all: without it the probe took 17.5 s against real Chromium and came
        # back with `readiness_timeout: 0 chart(s) had not finished` — the chart-free
        # case waiting out the watchdog, which is the defect `settle()` exists to
        # prevent. A probe that hand-rolled its own signal would have verified a signal
        # nobody uses.
        # THE ASSERTION THAT KEEPS `inline_asset` FROM BEING A TAUTOLOGY. The first
        # version's probe image was `#00aaff` — the page background — so a data: URI
        # that failed to decode showed the page through the fixed-height <img>, the
        # sampled pixel matched, and the check PASSED for the exact failure it was
        # written to catch. Nothing in the suite could see it: the negative test failed
        # that check against a blank white page, which is not the discriminating case.
        it 'draws the plate in a colour that appears nowhere else on the page' do
          expect(described_class::PLATE_RGB).not_to eq(described_class::BACKGROUND_RGB)
          expect(described_class::PLATE_RGB).not_to eq(described_class::BADGE_RGB)
          expect(html).not_to include('#00ff00')
        end

        it 'inlines assets/javascripts/chart_shell.js itself' do
          shipped = File.read(described_class::CHART_SHELL_PATH, encoding: 'UTF-8')

          expect(html).to include(shipped)
          expect(html).to include('SHELL missing')
        end

        it 'omits the hosted-image element when no Redmine base URL was supplied' do
          expect(html).not_to include('onerror=')
          expect(html).to include('no Redmine base URL was supplied')
        end

        it 'points the hosted image at the supplied base URL, exactly once' do
          with_url = described_class.new(engine: engine,
                                         redmine_base_url: 'https://redmine.example/')
                                    .probe_document

          expect(with_url.scan('https://redmine.example/favicon.ico').length).to eq(1)
        end
      end

      describe 'when the engine cannot draw at all' do
        # One honest check beats eight speculative ones: there is no document, so
        # there is nothing to inspect and nothing to report about it.
        it 'reports a single failed engine check and nothing else' do
          report = report_for(Conformance::HarnessEngines.crasher(message: 'chrome is gone'))

          expect(report.checks.map(&:id)).to eq([:engine])
          expect(check(report, :engine).state).to eq(:fail)
          expect(check(report, :engine).detail).to include('chrome is gone')
          expect(report).not_to be_ok
        end


        # An engine that answers something that is not a PDF must not reach the
        # inspector, which would report "not a P6 bitmap" — a true statement about the
        # wrong thing.
        it 'reports non-PDF output as an engine failure, not as six document failures' do
          report = report_for(Conformance::HarnessEngines.liar)

          expect(report.checks.map(&:id)).to eq([:engine])
          expect(check(report, :engine).detail).to include('output_not_pdf')
        end
      end

      describe 'the document checks, against a document that fails all of them' do
        # THE NEGATIVE TEST. The canned PDF is one page of plain text: no second page,
        # no footer, no background, no image, no script. If any of these came back
        # green the check is not looking at the document.
        before do
          skip "#{PdfInspector.missing_tools.join(', ')} not installed " \
               "(#{PdfInspector::INSTALL_HINT}); the render-smoke job runs this with them present" unless
            PdfInspector.available?
        end

        let(:report) { report_for(engine) }

        it 'still passes the engine check, which is the one that was never the problem' do
          expect(check(report, :engine).state).to eq(:pass)
          expect(report).not_to be_ok
        end

        {
          page_breaks: '1 page',
          footer: 'no page number found',
          background: 'page rgb',
          inline_asset: 'rgb',
          javascript: 'no canvas state reported',
          readiness: 'no shell marker in the document'
        }.each do |id, fragment|
          it "fails #{id}, and says what it saw" do
            expect(check(report, id).state).to eq(:fail)
            expect(check(report, id).detail).to include(fragment)
          end
        end

        # THE CASE THE TAUTOLOGY HID: background right, plate missing. Driven through
        # the inspector rather than through a browser, because what is under test is
        # whether the CHECK can tell the two apart — not whether Chromium can draw.
        it 'fails inline_asset when the page renders but the plate does not' do
          allow(PdfInspector).to receive(:pixel) do |_bytes, opts|
            opts[:y] == 0.12 ? described_class::BACKGROUND_RGB.dup : described_class::BACKGROUND_RGB.dup
          end

          expect(check(report, :inline_asset).state).to eq(:fail)
          expect(check(report, :inline_asset).detail).to include('wanted rgb[0, 255, 0]')
        end

        it 'passes inline_asset only when the plate is its own colour' do
          allow(PdfInspector).to receive(:pixel) do |_bytes, opts|
            case opts[:y]
            when 0.12 then described_class::PLATE_RGB.dup
            when 0.30 then described_class::BACKGROUND_RGB.dup
            else described_class::BADGE_RGB.dup
            end
          end

          expect(check(report, :inline_asset).state).to eq(:pass)
          expect(check(report, :background).state).to eq(:pass)
        end

        it 'times every check it ran' do
          timed = report.checks.reject { |c| c.id == :degradations }
          expect(timed.map(&:duration_ms)).to all(be_a(Numeric))
        end

        # A check that raised is a failed check with the exception in its detail — not
        # an exception out of a diagnostic. An operator running this is already having
        # a bad day.
        it 'turns an inspector error into a failed check rather than raising' do
          allow(PdfInspector).to receive(:page_count)
            .and_raise(PdfInspector::InspectionFailed, 'pdfinfo went sideways')

          expect(check(report, :page_breaks).state).to eq(:fail)
          expect(check(report, :page_breaks).detail).to include('pdfinfo went sideways')
        end
      end

      describe 'degradations' do
        # NOT EVERY DEGRADATION IS A DEFECT, and the first version said they all were.
        # Measured in CI on wkhtmltopdf, which failed for two reasons that are both
        # correct behaviour: `legacy_engine` is stamped on every one of its renders by
        # design, and `asset_unresolved` is the blocked hosted image this probe
        # deliberately provokes — the very thing `hosted_asset` reports as an
        # `expected_failure`. Counting it twice, once as expected and once as a failure,
        # is two states in one report contradicting each other.
        it 'treats an engine that always stamps legacy_engine as expected, not broken' do
          legacy = Conformance::HarnessEngines::Scripted.new(
            id: :legacy,
            degradations: [Degradation.new(capability: :legacy_engine, detail: 'compat engine')]
          )
          check = check(report_for(legacy), :degradations)

          expect(check.state).to eq(:expected_failure)
          expect(check).to be_ok
          # Reported, never hidden: the operator still reads what was degraded.
          expect(check.detail).to include('legacy_engine')
        end

        # ...but only when the probe ASKED for a blocked asset. With no Redmine base URL
        # the only remote reference is the inline data: URI, and that failing to resolve
        # is a genuine defect.
        it 'expects asset_unresolved only when a hosted image was requested' do
          degraded = lambda do
            Conformance::HarnessEngines::Scripted.new(
              id: :blocked,
              degradations: [Degradation.new(capability: :asset_unresolved, detail: 'blocked')]
            )
          end

          with_url = report_for(degraded.call, redmine_base_url: 'https://redmine.example')
          without = report_for(degraded.call)

          expect(check(with_url, :degradations).state).to eq(:expected_failure)
          expect(check(without, :degradations).state).to eq(:fail)
        end

        it 'still fails on a degradation nobody expected' do
          surprising = Conformance::HarnessEngines::Scripted.new(
            id: :surprising,
            degradations: [Degradation.new(capability: :legacy_engine, detail: 'fine'),
                           Degradation.new(capability: :readiness_timeout, detail: 'not fine')]
          )
          check = check(report_for(surprising), :degradations)

          expect(check.state).to eq(:fail)
          expect(check.detail).to include('readiness_timeout')
        end

        # THE CASE THAT DECIDED `required` OVER `essential`. An engine that cannot do
        # JavaScript must still be diagnosable — a preflight that refuses to run on the
        # engine it was asked about has answered nothing — so a missing capability is a
        # degradation, the probe still renders, and the defect is reported TWICE: once
        # by this check naming the capability, once by the document check for it.
        it 'renders anyway on an engine that lacks a capability, and reports it twice' do
          report = report_for(Conformance::HarnessEngines.limited(without: :javascript))

          expect(check(report, :engine).state).to eq(:pass)
          expect(check(report, :degradations).state).to eq(:fail)
          expect(check(report, :degradations).detail).to include('javascript')
          expect(report.failures.map(&:id)).to include(:degradations)
        end

        it 'fails when the engine silently dropped a capability' do
          degraded = Conformance::HarnessEngines::Scripted.new(
            id: :degrading,
            degradations: [Degradation.new(capability: :footer, detail: 'no footer support')]
          )

          expect(check(report_for(degraded), :degradations).state).to eq(:fail)
          expect(check(report_for(degraded), :degradations).detail).to include('footer')
        end

        it 'passes when nothing was degraded' do
          expect(check(report_for(engine), :degradations).state).to eq(:pass)
          expect(check(report_for(engine), :degradations).detail).to eq('none')
        end
      end

      describe 'when poppler is not installed' do
        before { allow(PdfInspector).to receive(:available?).and_return(false) }

        # A SKIP WITH THE PACKAGE NAMED. Never a pass — the operator has to know the
        # interesting half did not run — and never six speculative skips either.
        # THE REPORT KEEPS ITS SHAPE. The first version returned one umbrella
        # `:document` skip and returned early, which DELETED the rest — so the INV-8
        # containment question was absent from the report rather than unanswered, and
        # two installs' JSON could not be diffed. Caught by review, and independently by
        # CI when a spec asserting `hosted_asset` skips found it missing entirely.
        it 'skips every document check by name, and drops none of them' do
          report = report_for(engine)

          expect(report.checks.map(&:id))
            .to eq(%i[engine degradations] + described_class::DOCUMENT_CHECKS.keys)
          described_class::DOCUMENT_CHECKS.each_key do |id|
            expect(check(report, id).state).to eq(:skip), "#{id} is not a skip"
            expect(check(report, id).detail).to include('poppler-utils')
          end
        end

        # The one the Accept list singles out. It must be present and unanswered, never
        # absent — "the network question did not run" and "there is no network question"
        # are different reports.
        it 'still carries the INV-8 containment check, as a skip' do
          expect(check(report_for(engine), :hosted_asset).state).to eq(:skip)
        end

        # The decision recorded on `Check`: a missing optional tool does not make the
        # render path broken, so the exit code forgives it...
        it 'is still ok, because a missing microscope is not a sick patient' do
          expect(report_for(engine)).to be_ok
        end

        # ...and the report says so anyway, in both of the places somebody reads.
        it 'is NOT complete, and the headline never says a bare OK' do
          report = report_for(engine)

          expect(report).not_to be_complete
          expect(report.headline).to include('could not run')
          expect(report.to_text).not_to match(/\(OK,/)
          expect(report.to_h['complete']).to be(false)
        end
      end

      describe 'the hosted-image check' do
        # THE INSPECTOR IS STUBBED AVAILABLE IN EVERY EXAMPLE HERE, INCLUDING THIS ONE.
        # What is under test is the check's own reasoning, and leaving it to whether the
        # machine happens to have poppler makes the outcome environmental: this example
        # passed locally and failed on all four CI branches, where the skip's reason is
        # the install hint rather than the missing URL. Both are correct skips for
        # different reasons — CLAUDE.md §6, set it in the test rather than inherit it.
        before { allow(PdfInspector).to receive(:available?).and_return(true) }

        it 'skips when no Redmine base URL was supplied, rather than pretending' do
          hosted = check(report_for(engine), :hosted_asset)

          expect(hosted.state).to eq(:skip)
          expect(hosted.detail).to include('no Redmine base URL')
        end

        # THE ONE THAT IS SUPPOSED TO FAIL. `:expected_failure` and `:fail` must not be
        # the same state, or the one that matters gets ignored along with the one that
        # does not.
        it 'is an expected_failure — not a failure — when the image was blocked' do
          allow(PdfInspector).to receive(:flat_text).and_return('HOSTED-IMAGE blocked')

          report = report_for(engine, redmine_base_url: 'https://redmine.example')
          hosted = check(report, :hosted_asset)

          expect(hosted.state).to eq(:expected_failure)
          expect(hosted).to be_ok
          expect(report.failures.map(&:id)).not_to include(:hosted_asset)
        end

        # INV-8: the renderer never holds the network. If the probe REACHED Redmine,
        # the containment that F-15 asserts has a hole in it on this install, and that
        # is a real failure with the invariant named.
        it 'is a hard failure when the renderer reached the network, and names INV-8' do
          allow(PdfInspector).to receive(:flat_text).and_return('HOSTED-IMAGE loaded')

          hosted = check(report_for(engine, redmine_base_url: 'https://redmine.example'),
                         :hosted_asset)

          expect(hosted.state).to eq(:fail)
          expect(hosted.detail).to include('INV-8')
          expect(hosted.detail).to include('https://redmine.example')
        end
      end

      describe 'the artefact' do
        # JSON so it can be asserted on, diffed and pasted into an issue. A diagnostic
        # that exists only as prose gets checked by grepping, and a grep is a test that
        # breaks when somebody improves the wording.
        it 'round-trips through JSON with every check and its state' do
          report = report_for(engine)
          parsed = JSON.parse(report.to_json)

          expect(parsed['engine']).to eq('perfect')
          expect(parsed['ok']).to be(report.ok?)
          expect(parsed['checks'].map { |c| c['id'] })
            .to eq(report.checks.map { |c| c.id.to_s })
          expect(parsed['checks'].map { |c| c['state'] }).to all(be_a(String))
        end

        it 'prints one scannable line per check, state first' do
          text = report_for(engine).to_text.lines

          expect(text.first).to include('render preflight: perfect')
          expect(text.length).to eq(report_for(engine).checks.length + 1)
          expect(text[1]).to match(/\A\s+(PASS|FAIL|SKIP|EXPECTED_FAILURE)\s/)
        end

        # ONE LINE PER CHECK, INCLUDING WHEN THE DETAIL IS NOT ONE LINE. `Failure#detail`
        # routinely carries an engine's stderr. The count assertion above cannot fail on
        # its own — every detail it exercises is single-line — so the multi-line case is
        # driven explicitly.
        it 'keeps one line per check when a detail carries engine stderr' do
          report = described_class::Report.new(
            engine_id: :x, engine_version: '1', duration_ms: 1,
            checks: [described_class::Check.new(id: :engine, title: 't', state: :fail,
                                                detail: "chrome died\nline1\nline2",
                                                duration_ms: 1)]
          )

          expect(report.to_text.lines.length).to eq(2)
          expect(report.to_text).to include('chrome died line1 line2')
        end

        it 'reports every state it knows about as a symbol the caller can branch on' do
          expect(report_for(engine).checks.map(&:state)).to all(satisfy { |s|
            described_class::STATES.include?(s)
          })
        end
      end

    end
  end
end

# ---------------------------------------------------------------------------
# THE REAL ROUND TRIP.
#
# Behind `RRD_CONFORMANCE=1`, next to the corpus, for the same reason: it needs an
# engine, and the four `rspec` jobs deliberately have none. Everything above is about
# whether the checks can go RED; this is the only thing that says the probe document
# renders at all — and a preflight whose own document does not render is worse than no
# preflight, because it reports a defect in the install that is really a defect here.
#
# The adapters are required HERE rather than in a `before(:all)`, because a describe
# block has to exist at load time to contain examples — the same shape, and the same
# comment, as `spec/conformance/conformance_spec.rb`. Under `RRD_CONFORMANCE=1` only,
# so an ordinary `rspec spec/render` run does not acquire a populated registry as a
# side effect of loading this file.
# ---------------------------------------------------------------------------
if ENV['RRD_CONFORMANCE'] == '1'
  require_relative '../../lib/redmine_reporter_dashboards/render/engine_catalogue'
  Dir[File.expand_path('../../lib/redmine_reporter_dashboards/render/engines/*.rb', __dir__)]
    .sort.each { |path| require path }

  RSpec.describe 'the render preflight, against a real engine' do
    it 'is not verifying nothing' do
      expect(RedmineReporterDashboards::Render::Registry.ids).not_to be_empty,
                                          'RRD_CONFORMANCE=1 with no registered engine: this example would ' \
                                          'have reported a clean run of zero engines'
    end

    # THE THREE-STATE RULE, one level up — the same distinction `conformance_spec`
    # draws, and for the same reason. An engine the catalogue calls
    # `verification: corpus` is supposed to work here, so a dead one is a FAILURE. One
    # it does not is simply absent from this environment — wkhtmltopdf on a container
    # whose package 404'd — and the honest outcome is a skip that names the engine.
    RedmineReporterDashboards::Render::Registry.ids.each do |engine_id|
      it "passes every check against #{engine_id}" do
        entry = RedmineReporterDashboards::Render::EngineCatalogue.load[engine_id.to_s]
        claimed = entry ? entry.corpus_verified? : false

        begin
          engine = RedmineReporterDashboards::Render::Registry.fetch(engine_id).new
        rescue StandardError => e
          raise "#{engine_id}: #{e.class}: #{e.message}" if claimed

          skip "#{engine_id} cannot be started here (#{e.class}: #{e.message}) and the " \
               'catalogue does not claim it was conformance-verified'
        end

        begin
          # A base URL IS supplied here, so the INV-8 containment check actually runs
          # rather than skipping. The renderer has no network under the default policy,
          # so the honest outcome is `expected_failure` — and if this host ever lets the
          # fetch through, that is the finding.
          report = RedmineReporterDashboards::Render::Preflight.new(
            engine: engine, redmine_base_url: 'https://redmine.example'
          ).run
          RSpec.configuration.reporter.message("\n#{report.to_text}")

          engine_check = report.checks.first
          if engine_check.state != :pass && !claimed
            skip "#{engine_id} is registered but did not render here " \
                 "(#{engine_check.detail}); the catalogue does not claim a conformance run"
          end

          # A `pending` ENGINE'S RESULTS ARE REPORTED, NOT ENFORCED — the same rule
          # `conformance_spec.rb` applies per fixture, and for the same reason.
          # `verification: corpus` says "these results are the contract";
          # `verification: pending` says "we run it and print what happened, and nobody
          # has yet decided that this is what it must do". Holding an engine to a
          # contract before anyone has read a single one of its results is how a support
          # matrix acquires cells that were never argued.
          #
          # This must never become a way to keep a red engine green, so the results are
          # LOUD: every failure is warned and repeated in the skip reason. Promotion to
          # `corpus` is the moment somebody has to look at each one and either fix it,
          # express it as a capability the engine does not declare, or argue it.
          #
          # It is already load-bearing. wkhtmltopdf's first run through the REPAIRED
          # `inline_asset` check came back `rgb[0, 170, 255]` where the plate should be —
          # the page background, not the plate. See §Findings E-11: that is a real
          # measurement, and it is not yet discriminated between "does not decode the
          # data: URI" and "lays the plate out somewhere else".
          unless claimed || report.failures.empty?
            report.failures.each do |failure|
              warn "[preflight] #{engine_id} #{failure.id}: #{failure.detail}"
            end
            skip "#{engine_id} is `verification: #{entry&.verification}` — these results are " \
                 'INFORMATIONAL and not yet a contract: ' +
                 report.failures.map { |c| "#{c.title} — #{c.detail}" }.join('; ')
          end

          expect(report.failures).to be_empty,
                                     "#{engine_id}: " +
                                     report.failures.map { |c| "#{c.title} — #{c.detail}" }.join('; ')
          expect(report).to be_complete,
                            "#{engine_id}: #{report.skipped.map(&:title).join(', ')} could not run"
        ensure
          engine.shutdown if engine.respond_to?(:shutdown)
        end
      end
    end
  end
end
