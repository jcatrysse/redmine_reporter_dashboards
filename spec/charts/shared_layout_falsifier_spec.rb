# frozen_string_literal: true

require 'json'
require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/charts'
require_relative '../../lib/redmine_reporter_dashboards/render/engines/cdp_client'

# THE FALSIFIER FOR THE SHARED-LAYOUT CLAIM — T-16's `Verify:` line, verbatim:
#
#   "Plus the falsifier for the shared-layout claim: render a horizontal bar with 12 long
#    labels in both paths and compare plot-area bounding boxes — **>2% and 'by
#    construction' collapses to 'by careful tuning'**, with server-side SVG for *both*
#    outputs as the fallback."
#
# --- WHY THIS EXAMPLE AND NOT A UNIT TEST ---
#
# `SvgRenderer` and `ChartjsEmitter` both read `ChartLayout`, so a Ruby-only test that
# compared what each was TOLD would compare a number with itself and pass for ever. The
# claim is not "both were handed the same rectangle"; it is "both DRAW the same
# rectangle", and only one of them is drawn by Ruby. Chart.js measures the real font in
# the real browser and lays its own axis out from that; this plugin measures text with
# `characters × font_size × 0.55`. Those two are allowed to differ, and this is the
# example that says by how much.
#
# So the measurement has to happen in a browser, against the vendored library, at the
# size a reader sees. `chart.chartArea` is Chart.js's own answer for where it put the
# plot; `layout.plot` is ours.
#
# --- WHY TWELVE LONG LABELS AND A HORIZONTAL BAR ---
#
# It is the worst case for the approximation, which is what a falsifier should pick. On a
# horizontal bar the CATEGORY labels sit on the value-axis side, so the plot's left edge
# is decided entirely by the widest label — a single number, straight out of the
# character-count estimate, with no other reservation to dilute it. Twelve of them makes
# it likely that at least one is genuinely wide. A vertical bar with short labels would
# agree to within a pixel and prove nothing.
#
# --- WHAT A FAILURE MEANS, AND WHAT TO DO ABOUT IT ---
#
# Not "fix the number until it passes". The plan names the answer: server-side SVG for
# BOTH outputs. `SvgRenderer` already draws every one of the six families, so that
# fallback is available today rather than hypothetical — the change would be to have the
# HTML binding emit SVG as well, and to keep `ChartjsEmitter` only for the unsupported
# types that genuinely need Chart.js.
RSpec.describe 'the shared-layout claim, falsified in a browser' do
  Charts = RedmineReporterDashboards::Charts unless defined?(Charts)
  CdpClient = RedmineReporterDashboards::Render::Engines::CdpClient unless defined?(CdpClient)

  # §6's threshold, and it is the plan's rather than a number chosen after seeing the
  # result. Recorded as a constant so the commit that changes it is a commit that
  # changed the standard, not one that adjusted a literal in an assertion.
  TOLERANCE = 0.02

  ASSETS = File.expand_path('../../assets/javascripts', __dir__)

  # NAMED FOR THIS FILE. `golden_svg_spec.rb` has its own twelve labels and the two are
  # deliberately the same list — the golden freezes the layout, this measures the browser
  # against it — but a bare `LONG_LABELS` in both files is one constant assigned twice on
  # Object, and Ruby warns about it in a full run.
  FALSIFIER_LABELS = [
    'Infrastructure — Networking', 'Client Services — Onboarding', 'Platform — Data Ingest',
    'Platform — Reporting', 'Field Operations — Survey', 'Field Operations — Bathymetry',
    'Quality — Inspection', 'Quality — Calibration', 'Finance — Procurement',
    'Finance — Invoicing', 'People — Recruitment', 'People — Training'
  ].freeze

  let(:spec) do
    Charts::ChartSpec.new(
      id: 'falsifier', type: :bar, orientation: :horizontal,
      title: 'Open issues by team',
      categories: FALSIFIER_LABELS,
      series: [{ label: 'Open', values: [14, 9, 31, 22, 7, 3, 18, 11, 5, 26, 2, 8] }]
    )
  end

  let(:layout) { Charts::ChartLayout.for(spec) }

  # The document the browser gets. Everything inline, nothing fetched — this is the same
  # posture the render path takes (INV-8), and it is also what makes the measurement
  # reproducible: a chart drawn against a CDN copy of Chart.js measures whatever that
  # CDN served today.
  def document
    <<~HTML
      <!doctype html>
      <html><head><meta charset="utf-8">
      <style>html,body{margin:0;padding:0;font-family:Helvetica,Arial,sans-serif}</style>
      <script>#{File.read(File.join(ASSETS, 'chart_shell.js'), encoding: 'UTF-8')}</script>
      <script>#{File.read(File.join(ASSETS, 'vendor/chart.umd.js'), encoding: 'UTF-8')}</script>
      </head><body>
      #{Charts::ChartjsEmitter.emit(layout, output: :html)}
      <script>#{File.read(File.join(ASSETS, 'chart_boot.js'), encoding: 'UTF-8')}</script>
      </body></html>
    HTML
  end

  # A tolerance, not an equality: a browser lays out asynchronously and `chartArea` is
  # only final once Chart.js has drawn. The readiness contract already answers "has every
  # chart finished", so this waits on that rather than on a sleep — the same reason
  # `Readiness` exists at all (§5, and T-11's whole finding).
  def measure(page)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      area = page.evaluate(<<~JS)
        (function () {
          if (!window.__rd || !window.__rd.ready) { return null; }
          var canvas = document.querySelector('canvas');
          var chart = window.Chart && window.Chart.getChart ? window.Chart.getChart(canvas) : null;
          if (!chart) { return null; }
          var a = chart.chartArea;
          return JSON.stringify({ left: a.left, top: a.top, right: a.right, bottom: a.bottom,
                                  ticks: chart.scales.x.ticks.map(function (t) { return t.value; }),
                                  min: chart.scales.x.min, max: chart.scales.x.max,
                                  degraded: window.__rd.degraded });
        }())
      JS
      return JSON.parse(area) if area

      raise 'the chart never became ready' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
  end

  # THE THREE-STATE RULE (G12), applied to an example rather than to an engine. No
  # browser means this was NOT VERIFIED, and it says so with the reason. It must never
  # read as a pass: the whole value of this file is that it is the one thing in T-16 a
  # Ruby-only run cannot answer.
  #
  # --- AND THE BROWSER HAS TO HAVE BEEN GIVEN, NOT MERELY FOUND ---
  #
  # `detect_binary` finding something is not the same question as "this run may start a
  # browser", and conflating them kept the four `RSpec` CI jobs RED for four commits.
  # GitHub's `ubuntu-latest` image has a Chromium on PATH; the plain `rspec` job installs
  # none of what it needs, so that binary launched and died mid-session
  # (`the browser exited while we were waiting for it`) and two examples FAILED — in a job
  # whose own description says it "stubs Redmine away and never boots Rails".
  #
  # A failure there is noise: it says nothing about the shared-layout claim and it buries
  # the signal from the 2 081 other examples beside it. So the browser must be OFFERED, by
  # the same flag `spec/render/chromium_containment_spec.rb` already uses — one flag
  # meaning "a real browser is available and this run may start it" — and `render-smoke`,
  # which installs one deliberately, stays the place the claim is answered. It is green
  # there, and that is the evidence.
  def browser_offered?
    ENV['RRD_CONFORMANCE'] == '1'
  end

  UNOFFERED = 'not a browser run — set RRD_CONFORMANCE=1 (the render-smoke job does). ' \
              'The shared-layout claim is UNVERIFIED here, which is not a pass'

  def browser_available?
    binary = CdpClient.detect_binary
    !binary.to_s.empty? && File.executable?(binary)
  end

  # Chromium refuses to run as root, and that is the design working — `--no-sandbox` is
  # deliberately never passed. HANDOVER §1 records the invocation for this container.
  def root?
    Process.uid.zero?
  end

  it 'draws its plot area where the shared layout says, within 2%' do
    skip UNOFFERED unless browser_offered?
    skip "no Chromium on PATH (set RRD_CHROMIUM_BINARY) — the shared-layout claim is UNVERIFIED without one" unless browser_available?
    skip 'Chromium will not run as root, and --no-sandbox is deliberately never set. ' \
         'Run as a non-root user: useradd -m rrd && chmod -R a+rX . && su rrd -s /bin/bash -c ' \
         "'rspec -I spec spec/charts/shared_layout_falsifier_spec.rb'" if root?

    client = CdpClient.new
    measured = nil
    begin
      client.with_page do |page|
        page.set_content(document, timeout_ms: 20_000)
        measured = measure(page)
      end
    ensure
      client.stop
    end

    drawn = { left: measured['left'], top: measured['top'],
              right: measured['right'], bottom: measured['bottom'] }
    expected = { left: layout.plot.x, top: layout.plot.y,
                 right: layout.plot.right, bottom: layout.plot.bottom }

    # Each edge as a fraction of the canvas dimension it lies along. Comparing edges
    # rather than areas because an area can agree while both edges are wrong in
    # opposite directions, which is the failure that would make a chart and its PDF
    # twin visibly offset from each other while this test passed.
    deviations = {
      left: (drawn[:left] - expected[:left]).abs / spec.width.to_f,
      right: (drawn[:right] - expected[:right]).abs / spec.width.to_f,
      top: (drawn[:top] - expected[:top]).abs / spec.height.to_f,
      bottom: (drawn[:bottom] - expected[:bottom]).abs / spec.height.to_f
    }
    worst = deviations.max_by { |_edge, value| value }

    report = deviations.map { |edge, value| format('%s %+.1fpx (%.2f%%)', edge,
                                                   drawn[edge] - expected[edge], value * 100) }
    puts "  [shared layout] chartArea vs ChartLayout#plot: #{report.join(', ')}"

    expect(worst.last).to be <= TOLERANCE,
                          lambda {
                            <<~MESSAGE
                              The HTML and PDF paths do not agree about where the plot is.

                              Chart.js drew:      #{drawn.inspect}
                              ChartLayout says:   #{expected.inspect}
                              Worst edge:         #{worst.first} at #{(worst.last * 100).round(2)}% \
                              (tolerance #{(TOLERANCE * 100).round}%)

                              T-16: ">2% and 'by construction' collapses to 'by careful tuning'".
                              Do NOT widen the tolerance. The plan's own fallback is server-side SVG
                              for BOTH outputs — SvgRenderer already draws all six families, so the
                              change is to have the HTML binding emit SVG and keep ChartjsEmitter
                              only for the unsupported types that genuinely need Chart.js.
                            MESSAGE
                          }
  end

  # A SECOND CLAIM, AND THE CHEAPER HALF. The plot rectangle is where the approximation
  # can bite; the AXIS is where Chart.js was told not to think. If it ever chose its own
  # bounds or its own tick count, the two documents would disagree about what the numbers
  # ARE rather than about where they sit — a worse failure, and one nothing else here
  # would catch.
  it 'uses exactly the ticks and bounds it was given, choosing none of its own' do
    skip UNOFFERED unless browser_offered?
    skip 'no Chromium on PATH — UNVERIFIED' unless browser_available?
    skip 'Chromium will not run as root; see the example above for the invocation' if root?

    client = CdpClient.new
    measured = nil
    begin
      client.with_page do |page|
        page.set_content(document, timeout_ms: 20_000)
        measured = measure(page)
      end
    ensure
      client.stop
    end

    expect(measured['min']).to eq(layout.scale.min)
    expect(measured['max']).to eq(layout.scale.max)
    expect(measured['ticks']).to eq(layout.scale.ticks)
    expect(measured['degraded']).to eq([]), 'the readiness contract recorded a degradation'
  end
end
