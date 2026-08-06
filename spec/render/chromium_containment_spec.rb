# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/render/engines/chromium_cdp'
require_relative '../../lib/redmine_reporter_dashboards/render/renderer'

module RedmineReporterDashboards
  module Render
    module Engines
      # T-15's hardest assertion, and the one that cannot be faked: after a render times
      # out, IS THE BROWSER ACTUALLY GONE?
      #
      # `technical-spec.md` §7 names the failure this exists to prevent — *"a timeout
      # that returns while the browser keeps burning CPU is the 504-with-a-burning-worker
      # failure"*. Every part of that is invisible to a normal test: the caller got its
      # typed `Failure(:timeout)` on time, the log line is correct, the user saw a clean
      # error. The only symptom is a machine that gets slower every time somebody
      # exports a broken template, and by the time anyone connects the two there are
      # forty orphaned browsers on it.
      #
      # So this spec asserts on the PROCESS TABLE, not on the return value. It needs a
      # real browser and is therefore skipped where there is none — the `render-smoke`
      # job is where it runs.
      RSpec.describe 'render-path containment (Chromium)' do
        # A synchronous loop in the parser blocks the renderer's main thread. Nothing
        # in CDP answers after this — not the readiness poll, not `printToPDF` — which
        # is precisely the wedged-renderer case, and precisely what a template author
        # writes by accident at four in the afternoon.
        WEDGE = '<!DOCTYPE html><html><body><h1>WEDGED</h1>' \
                '<script>while (true) { /* deliberately */ }</script></body></html>'

        def browser_children
          # `comm` truncates at 15 characters, so the browser shows as "chrome" or
          # "headless_shell" whatever the binary is called. Children of THIS process
          # only: another suite's browser is not this spec's business.
          `ps -o pid=,comm= --ppid #{Process.pid} 2>/dev/null`.lines.map(&:strip)
                                                              .select { |line| line =~ /chrom|headless/i }
        end

        before(:all) do
          skip 'needs a real browser; the render-smoke job is where this runs' unless
            ENV['RRD_CONFORMANCE'] == '1'
        end

        after { @adapter&.shutdown }

        it 'kills the browser when a render wedges, and leaves nothing behind' do
          baseline = browser_children
          @adapter = ChromiumCdp.new

          # Warm the pool first, so the browser under test is one this example started
          # and the timing below measures a render rather than a launch.
          expect(@adapter.preflight).to be_success
          expect(browser_children.length).to eq(baseline.length + 1),
                                             'the warm-up did not leave exactly one browser to kill'

          request = DocumentRequest.new(body: WEDGE, correlation_id: 'wedge-1',
                                        timeout_ms: 4_000)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = Renderer.new(engine: @adapter).render(request)
          elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000

          # 1. The caller gets a typed refusal, not an exception and not a blank PDF.
          expect(result).to be_a(Failure)
          expect(result.code).to eq(:timeout)
          expect { result.bytes }.to raise_error(NoMethodError)

          # 2. Bounded, and MONOTONIC — a wall-clock reading here would be measuring the
          #    machine's clock rather than the timeout.
          expect(elapsed_ms).to be_between(3_500, 20_000),
                                "the timeout was not bounded (#{elapsed_ms.round} ms)"

          # 3. THE ONE THAT MATTERS. The browser that was wedged is gone, not detached
          #    and still spinning.
          expect(browser_children).to eq(baseline),
                                      "a browser survived the timeout: #{browser_children.inspect}"
        end

        # A poisoned worker must not be handed to the next caller: one bad template
        # would otherwise take the whole queue down behind it, and every subsequent
        # render would inherit the first one's failure.
        it 'serves the next render from a fresh browser, not the wedged one' do
          @adapter = ChromiumCdp.new
          expect(@adapter.preflight).to be_success

          wedged = Renderer.new(engine: @adapter).render(
            DocumentRequest.new(body: WEDGE, correlation_id: 'wedge-2', timeout_ms: 4_000)
          )
          expect(wedged).to be_a(Failure)

          recovered = Renderer.new(engine: @adapter).render(
            DocumentRequest.new(body: '<!DOCTYPE html><html><body><h1>AFTER</h1></body></html>',
                                correlation_id: 'after-wedge', timeout_ms: 20_000)
          )

          expect(recovered).to be_success,
                               "the pool handed on a poisoned worker: #{recovered.inspect}"
        end

        it 'leaves no browser behind on shutdown either' do
          baseline = browser_children
          adapter = ChromiumCdp.new
          expect(adapter.preflight).to be_success
          expect(browser_children.length).to eq(baseline.length + 1)

          adapter.shutdown

          expect(browser_children).to eq(baseline)
        end

        # Concurrency is observably bounded, through the adapter rather than through
        # the pool's own unit spec: what matters to an operator is how many BROWSERS
        # exist, and that is a different question from how many objects the pool holds.
        it 'never runs more than one browser at a time by default' do
          baseline = browser_children
          @adapter = ChromiumCdp.new
          peak = baseline.length

          threads = 4.times.map do |i|
            Thread.new do
              Renderer.new(engine: @adapter).render(
                DocumentRequest.new(body: "<html><body>#{i}</body></html>",
                                    correlation_id: "concurrent-#{i}", timeout_ms: 20_000)
              )
            end
          end
          10.times do
            peak = [peak, browser_children.length].max
            sleep 0.05
          end
          results = threads.map(&:value)

          expect(results).to all(be_success)
          expect(peak - baseline.length).to be <= 1,
                                            "#{peak - baseline.length} browsers ran at once; the pool size is 1"
        end
      end
    end
  end
end
