# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/render/readiness'

module RedmineReporterDashboards
  module Render
    RSpec.describe Readiness do
      it 'defaults to a 10s engine timeout with the page watchdog firing first' do
        readiness = described_class.new

        expect(readiness.timeout_ms).to eq(10_000)
        expect(readiness.client_timeout_ms).to eq(8_000)
        expect(readiness.client_timeout_ms).to be < readiness.timeout_ms
      end

      # A watchdog that fires after the engine gave up never runs, and the degradation
      # it would have recorded — the only thing that says WHY — is lost.
      it 'refuses a watchdog that could never fire' do
        expect { described_class.new(timeout_ms: 1_000, client_timeout_ms: 5_000) }
          .to raise_error(ArgumentError, /never runs/)
      end

      it 'gives a JS engine the expression and a DOM-only engine the attribute' do
        readiness = described_class.new

        expect(readiness.signal_for([:readiness_expression]))
          .to eq(kind: :expression, value: described_class::EXPRESSION)
        expect(readiness.signal_for([:print_backgrounds]))
          .to eq(kind: :attribute, value: described_class::ATTRIBUTE, expected: '1')
      end

      # A chart-less-but-otherwise-correct document beats no document.
      it 'degrades rather than failing when charts do not finish' do
        degradation = described_class.new.on_timeout(pending: 2)

        expect(degradation).to be_a(Degradation)
        expect(degradation.capability).to eq(:readiness_timeout)
        expect(degradation.detail).to include('2 chart(s)')
      end

      it 'refuses to degrade when the caller asked for strict' do
        expect(described_class.new(strict: true).on_timeout(pending: 2)).to be_nil
      end
    end

    # The DOM contract, EXECUTED rather than described. This runs the shipped file in
    # node against a stub document — it is the same code the engine loads, so a change
    # that breaks the protocol fails here instead of in a PDF nobody looks at closely.
    #
    # T-11's THREE-FIXTURE FALSIFIER (0 charts <1s / 3 charts <3s / 1 chart never ending
    # ≈timeout, measured monotonically through a real engine) is NOT this. It needs an
    # engine driving a real page, which arrives with T-13 — see §Findings F-7. What is
    # below is the protocol's logic; what is owed is its timing through Chromium.
    RSpec.describe 'chart_shell.js' do
      SHELL = File.expand_path('../../assets/javascripts/chart_shell.js', __dir__)

      def run_js(body)
        require 'open3'
        script = <<~JS
          globalThis.document = {
            readyState: 'complete',
            documentElement: {
              dataset: {},
              removeAttribute: function (n) { delete this.dataset.rdReady; }
            },
            addEventListener: function () {}
          };
          require(#{SHELL.dump});
          var rd = globalThis.__rd;
          #{body}
        JS
        out, err, status = Open3.capture3('node', '-e', script)
        raise "node failed: #{err}" unless status.success?

        out.strip
      end

      before do
        skip 'node is not installed — the DOM contract is executed, not mocked' unless
          system('which node > /dev/null 2>&1')
      end

      # The first falsifying fixture, at the level this suite can reach: without the
      # settle step a chart-free page never calls end(), so it would wait out the
      # watchdog and be the SLOWEST document on the site.
      it 'is ready immediately when the document has no charts' do
        expect(run_js('console.log(rd.ready);')).to eq('true')
      end

      it 'stays pending until every chart that began has ended' do
        expect(run_js('rd.begin(); rd.begin(); rd.end(); console.log(rd.ready + " " + rd.pending);'))
          .to eq('false 1')
        expect(run_js('rd.begin(); rd.begin(); rd.end(); rd.end(); console.log(rd.ready);'))
          .to eq('true')
      end

      # All three signals at the same instant, so one document serves every engine.
      it 'sets the expression, the attribute and the status together' do
        out = run_js('rd.begin(); rd.end(); console.log([rd.ready, ' \
                     'document.documentElement.dataset.rdReady, globalThis.status].join("|"));')

        expect(out).to eq('true|1|rd-ready')
      end

      # A chart that gave up still FINISHES. Otherwise one broken chart holds the whole
      # document open until the timeout, and the reader loses every chart, not one.
      it 'counts a failed chart as finished, and records why' do
        out = run_js('rd.begin(); rd.begin(); rd.fail("boom"); rd.end(); ' \
                     'console.log(rd.ready + " " + JSON.stringify(rd.degraded));')

        expect(out).to eq('true ["boom"]')
      end

      # A chart registering after the page settled must REOPEN readiness, or it draws
      # into a document the engine has already been told is finished.
      it 'reopens readiness when a late chart begins' do
        out = run_js('rd.begin(); console.log(rd.ready + " " + ' \
                     'JSON.stringify(document.documentElement.dataset.rdReady));')

        expect(out).to eq('false undefined')
      end

      # begin/end are never the author's job — the shell owns them, and nothing in the
      # shipped file asks a template to call the old hand-rolled handshake.
      #
      # Comments are stripped first, and that is not a weakening: the file's own header
      # NAMES the handshake it replaces, which is exactly the documentation this project
      # wants written down. The same false positive bit compat_size.sh and
      # layer_purity.sh, and the answer is the same — a check that punishes explaining
      # itself teaches people to stop explaining.
      it 'carries none of the hand-rolled handshake it replaces' do
        code = File.read(SHELL, encoding: 'UTF-8')
                   .gsub(%r{/\*.*?\*/}m, '')
                   .gsub(%r{^\s*//.*$}, '')

        expect(code).not_to match(/geoChartBegin|geoChartEnd|__geoChartsPending/)
        expect(code).to include('rd-ready'), 'the stripper must not have eaten the file'
      end
    end
  end
end
