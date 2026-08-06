# frozen_string_literal: true

require 'fileutils'
require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/charts'

# THE SVG GOLDENS — T-16's `Verify:` line: "SVG goldens are **deterministic text**; the
# Chart.js visual diff is **advisory, never a gate**."
#
# --- WHY TEXT AND NOT PIXELS ---
#
# A pixel diff of a chart answers "does it look the same on this machine, with these
# fonts, at this anti-aliasing setting". That is a different question from "did the
# layout change", it is answered differently on two machines, and a test that fails for
# reasons nobody can act on is a test somebody disables. The SVG is the layout, written
# down. If two renders differ, something in `ChartLayout` or `SvgRenderer` moved, and the
# diff says which number.
#
# So this is a GATE and the perceptual comparison is not. Same discipline as
# `spec/golden/` applies to the aggregation kernel.
#
# --- HOW TO REGENERATE, AND WHEN NOT TO ---
#
#     RRD_CHART_GOLDEN_WRITE=1 rspec -I spec spec/charts/golden_svg_spec.rb
#
# A DIFFERENCE IS A FINDING TO EXPLAIN, NOT A FILE TO REGENERATE. Read the diff first:
# these files are the only place a layout change is visible as a layout change rather
# than as a number in a hash. Regenerate when you have decided the new output is right,
# and say so in the commit — the same rule `spec/golden/README.md` states for the
# aggregation corpus.
#
# --- THE FIXTURES ARE CHOSEN, NOT SAMPLED ---
#
# One per family, plus the four cases that have broken something: a horizontal bar with
# long labels (the falsifier's own shape), a line with a gap, a diverging stack whose
# zero is in the middle, and a chart whose data is hostile text.
RSpec.describe 'SVG goldens' do
  Charts = RedmineReporterDashboards::Charts unless defined?(Charts)

  GOLDEN_DIR = File.expand_path('golden', __dir__)
  WRITE = ENV['RRD_CHART_GOLDEN_WRITE'] == '1'

  LONG_LABELS = [
    'Infrastructure — Networking', 'Client Services — Onboarding', 'Platform — Data Ingest',
    'Platform — Reporting', 'Field Operations — Survey', 'Field Operations — Bathymetry',
    'Quality — Inspection', 'Quality — Calibration', 'Finance — Procurement',
    'Finance — Invoicing', 'People — Recruitment', 'People — Training'
  ].freeze

  FIXTURES = {
    'bar-vertical' => {
      id: 'bar', type: :bar, title: 'Issues by status', y_title: 'Issues',
      categories: %w[New Assigned Resolved Feedback Closed Rejected],
      series: [{ label: 'Issues', values: [12, 7, 43, 3, 98, 5] }]
    },
    # THE FALSIFIER'S SHAPE. Twelve long labels on a horizontal bar is the case where a
    # server-side text measurement and a browser's real font metrics disagree most, so
    # it is the one worth freezing.
    'bar-horizontal-long-labels' => {
      id: 'hbar', type: :bar, orientation: :horizontal, title: 'Open issues by team',
      categories: LONG_LABELS,
      series: [{ label: 'Open', values: [14, 9, 31, 22, 7, 3, 18, 11, 5, 26, 2, 8] }]
    },
    'stacked-bar' => {
      id: 'stack', type: :stacked_bar, title: 'Issues by status and quarter',
      categories: %w[Q1 Q2 Q3 Q4],
      series: [{ label: 'Open', values: [12, 18, 9, 22] },
               { label: 'Closed', values: [30, 25, 41, 19] }]
    },
    'diverging-stacked-bar' => {
      id: 'diverge', type: :diverging_stacked_bar, title: 'Sentiment',
      categories: ['Documentation', 'Release process', 'On-call'],
      series: [{ label: 'Strongly disagree', values: [-8, -3, -14] },
               { label: 'Disagree', values: [-12, -9, -6] },
               { label: 'Neutral', values: [4, 6, 3] },
               { label: 'Agree', values: [18, 22, 9] },
               { label: 'Strongly agree', values: [7, 11, 2] }]
    },
    'line-with-a-gap' => {
      id: 'line', type: :line, title: 'Created and closed', x_title: 'Month',
      categories: %w[Jan Feb Mar Apr May Jun],
      series: [{ label: 'created', values: [12, 18, nil, 22, 9, 14] },
               { label: 'closed', values: [8, 20, 15, nil, 11, 19] }]
    },
    'pie' => {
      id: 'pie', type: :pie, title: 'Time by activity',
      categories: ['Development', 'Design', 'Support', 'Meetings'],
      series: [{ label: 'Hours', values: [120, 45, 78, 33] }]
    },
    'doughnut' => {
      id: 'doughnut', type: :doughnut, title: 'Storage',
      categories: %w[Used Free], series: [{ label: 'GB', values: [340, 160] }]
    },
    'progress' => {
      id: 'progress', type: :progress, title: 'Release 2026.1',
      categories: ['complete'], series: [{ label: 'percent', values: [67] }]
    },
    'empty' => {
      id: 'empty', type: :bar, title: 'Nothing matched', categories: [], series: []
    },
    # Drill-through as real links, and hostile text in every position that reaches the
    # output: a category label, a series label and a URL with an ampersand in it.
    'drill-and-hostile-text' => {
      id: 'hostile', type: :bar, title: %(Tom's & Jerry's <report>),
      categories: ['a & b', '<script>alert(1)</script>', %(q"q)],
      series: [{ label: 'x & y', values: [3, 5, 1] }],
      drill_urls: [['https://redmine.example/issues?set_filter=1&status_id=o', nil,
                    'https://redmine.example/issues?a=1&b=2']]
    }
  }.freeze

  before(:all) { FileUtils.mkdir_p(GOLDEN_DIR) }

  FIXTURES.each do |name, attrs|
    context name do
      let(:svg) { Charts::SvgRenderer.render(Charts::ChartSpec.new(**attrs)) }
      let(:path) { File.join(GOLDEN_DIR, "#{name}.svg") }

      it 'matches its committed golden byte for byte' do
        if WRITE
          File.write(path, "#{svg}\n")
          skip "regenerated #{name}.svg — read the diff before committing it"
        end

        expect(File.exist?(path)).to be(true),
                                     "#{name}.svg is missing. Generate it with " \
                                     'RRD_CHART_GOLDEN_WRITE=1 and READ THE DIFF before committing.'
        expect(svg).to eq(File.read(path, encoding: 'UTF-8').chomp)
      end

      # Not a duplicate of the byte comparison: a golden that was itself generated from
      # broken output would pass that one. This asserts a property of the STRING rather
      # than agreement with a file.
      it 'is well-formed XML' do
        require 'rexml/document'

        expect { REXML::Document.new(svg) }.not_to raise_error
      end

      it 'renders identically twice in the same process' do
        expect(Charts::SvgRenderer.render(Charts::ChartSpec.new(**attrs))).to eq(svg)
      end
    end
  end

  # THE GUARD AGAINST A GOLDEN SUITE THAT CHECKS NOTHING. The directory is the source of
  # truth for "which fixtures exist", so a golden deleted along with its fixture leaves
  # no trace — and a suite that silently shrank is exactly the failure mode this
  # repository keeps rediscovering (HANDOVER §1).
  it 'has one golden per fixture and no orphans' do
    skip 'regenerating' if WRITE

    on_disk = Dir.glob(File.join(GOLDEN_DIR, '*.svg')).map { |p| File.basename(p, '.svg') }.sort

    expect(on_disk).to eq(FIXTURES.keys.sort)
  end

  it 'covers every one of the six families' do
    drawn = FIXTURES.values.map { |attrs| Charts::ChartSpec.new(**attrs).family }.uniq

    expect(drawn).to match_array(Charts::ChartSpec::FAMILIES)
  end
end
