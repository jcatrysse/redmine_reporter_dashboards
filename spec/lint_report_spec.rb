# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/lint_report'

# T-37 — the CLI half of FR-71, DB-less, so it runs on every supported Redmine.
#
# The task's WIRING is `test/unit/reporter_dashboards_lint_rake_test.rb` (a rake file cannot
# be reached from here) and the EQUALITY of this module's finding list with the editor's is
# `test/functional/reporter_dashboards_lint_panel_test.rb`. What is left for this file is the
# report itself: the counts, the bounds, the exit rule, and the promise that a body never
# reaches the terminal whole.

# METHODS IN A NAMED MODULE, NOT CONSTANTS INSIDE THE `describe`. A constant assigned
# inside an `RSpec.describe` block lands on `Object`, which HANDOVER §1 records as a real
# defect rather than a style point: T-22's review found exactly that breaking two of T-16's
# examples in the randomised full run while passing in isolation.
#
# They are methods rather than constants on this module because a constant would then have
# to be spelled `LintReportFixtures::ERROR_BODY` at every use — Ruby resolves a constant
# through the LEXICAL scope, which inside an RSpec block is the top level, so `include`
# does not bring one into reach. A method does, because method lookup walks the ancestors.
module LintReportFixtures
  def error_body
    "<p>ok</p>\n<script>xAxes: []</script>"
  end

  def warning_body
    '<script>beginAtZero: true</script>'
  end

  def clean_body
    '<h1>{{ project.name }}</h1>'
  end
end

RSpec.describe RedmineReporterDashboards::LintReport do
  include LintReportFixtures

  # `[label, body]` pairs, which is the shape the rake task maps its rows into. Deliberately
  # not a model double: this module must not learn what a Template is, or it could not also
  # be pointed at a file.
  def analyse(*subjects)
    described_class.analyse(subjects)
  end

  def render(*subjects)
    described_class.render(analyse(*subjects)).join("\n")
  end

  describe 'the analysis' do
    it 'keeps the label the caller gave it, so a row can be identified' do
      entries = analyse(['#7 Quarterly', clean_body])

      expect(entries.map(&:label)).to eq(['#7 Quarterly'])
    end

    it 'runs the same linter, so the findings are the linter\'s own objects' do
      expected = RedmineReporterDashboards::TemplateLinter.analyse(error_body).findings

      expect(analyse(['#1 x', error_body]).first.analysis.findings).to eq(expected)
    end

    it 'analyses each subject separately rather than concatenating them' do
      entries = analyse(['#1 a', error_body], ['#2 b', clean_body])

      expect(entries.first.rework?).to be(true)
      expect(entries.last.rework?).to be(false)
    end
  end

  describe 'the exit rule' do
    # ERRORS FAIL, WARNINGS DO NOT — a non-zero exit that is always non-zero is one nobody
    # reads, which is the same argument T-25 records for a draft schedule.
    it 'fails on an error' do
      expect(described_class.failed?(analyse(['#1 x', error_body]))).to be(true)
    end

    it 'does not fail on a warning' do
      expect(described_class.failed?(analyse(['#1 x', warning_body]))).to be(false)
    end

    it 'does not fail on nothing at all' do
      expect(described_class.failed?(analyse)).to be(false)
      expect(described_class.failed?(analyse(['#1 x', clean_body]))).to be(false)
    end

    it 'fails when ONE of many templates has an error' do
      entries = analyse(['#1 a', clean_body], ['#2 b', warning_body], ['#3 c', error_body])

      expect(described_class.failed?(entries)).to be(true)
    end
  end

  describe 'the report' do
    it 'counts the templates it examined' do
      expect(render(['#1 a', clean_body], ['#2 b', clean_body])).to include('2 template(s) examined')
    end

    it 'says so plainly when everything is clean, rather than printing an empty section' do
      expect(render(['#1 a', clean_body])).to include('every template is clean')
    end

    # COUNTS MATCHES, NOT ROWS. `collapse` keeps one finding per (rule, line) with a count,
    # so a line carrying two `[page]` tokens is one row and two problems; a total that said
    # "1" would understate the work by exactly the factor the collapsing saved.
    it 'counts every match, not every row' do
      expect(render(['#1 a', '<p>[page] [topage]</p>'])).to include('2 error(s)')
    end

    it 'separates errors from warnings and says which blocks' do
      text = render(['#1 a', error_body], ['#2 b', warning_body])

      expect(text).to include('1 error(s), 1 warning(s)')
      expect(text).to include('1 template(s) have at least one error')
    end

    it 'prints the position in the same spelling the editor prints' do
      finding = RedmineReporterDashboards::TemplateLinter.analyse(error_body).findings.first

      expect(render(['#1 a', error_body])).to include(finding.position)
    end

    it 'prints the rule id, the label and the excerpt' do
      text = render(['#42 Quarterly', error_body])

      expect(text).to include('chartjs2.scales_axes')
      expect(text).to include('#42 Quarterly')
      expect(text).to include('> <script>xAxes: []</script>')
    end

    it 'names how many times a rule matched on one line' do
      expect(render(['#1 a', '<p>[page] [topage]</p>'])).to include('(x2 on this line)')
    end
  end

  describe 'the bounds — at the limit and one past it' do
    def bodies(count)
      (1..count).map { |n| ["##{n} t", error_body] }
    end

    it 'details every template at the limit' do
      text = described_class.render(described_class.analyse(bodies(described_class::MAX_DETAILED)))
                            .join("\n")

      expect(text).not_to include('not detailed here')
    end

    it 'states the truncation one past the limit, and keeps the COUNT complete' do
      over = described_class::MAX_DETAILED + 3
      text = described_class.render(described_class.analyse(bodies(over))).join("\n")

      expect(text).to include("#{over} template(s) examined")
      expect(text).to include('3 more template(s) with findings, not detailed here')
      expect(text).to include('The counts above are complete')
    end

    it 'bounds the findings of one template and says how many it dropped' do
      cap = described_class::MAX_FINDINGS_PER_TEMPLATE
      body = (1..(cap + 4)).map { |n| "<p>#{n} [page]</p>" }.join("\n")

      text = render(['#1 a', body])

      expect(text).to include('and 4 more finding(s) in this template')
    end

    it 'exactly at the per-template limit says nothing about more' do
      cap = described_class::MAX_FINDINGS_PER_TEMPLATE
      body = (1..cap).map { |n| "<p>#{n} [page]</p>" }.join("\n")

      expect(render(['#1 a', body])).not_to include('more finding(s) in this template')
    end

    # A template body is operator-supplied and one minified line can be 40 KB. The excerpt
    # is bounded by the LINTER (EXCERPT_LIMIT); this asserts the report does not undo that.
    it 'never prints a template body, only bounded excerpts' do
      secret = "<p>[page]</p>\n<p>#{'S' * 400}</p>"

      expect(render(['#1 a', secret])).not_to include('S' * 200)
    end
  end

  # Nothing to lint is a legitimate state — a fresh installation — and it must not read as
  # a clean bill of health for templates that do not exist.
  describe 'an installation with no templates' do
    it 'says nothing was examined rather than reporting a clean bill of health' do
      text = described_class.render(described_class.analyse([])).join("\n")

      expect(text).to include('0 template(s) examined')
      expect(text).to include('no report templates in this installation yet')
      expect(text).not_to include('every template is clean')
    end
  end
end
