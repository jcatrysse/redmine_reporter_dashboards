# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/import/survey'
require_relative '../../lib/redmine_reporter_dashboards/import/plan_report'

# The formatter is the reason the survey returns a data object instead of printing.
# It runs DB-less, on every supported Redmine, because what an operator reads is as
# much a deliverable as the numbers behind it — and because the two properties that
# matter most here are about ABSENCE: that section 6 is never dropped, and that the
# detail is bounded.
RSpec.describe RedmineReporterDashboards::Import::PlanReport do
  Survey = RedmineReporterDashboards::Import::Survey unless defined?(Survey)
  Linter = RedmineReporterDashboards::TemplateLinter unless defined?(Linter)

  def table(name, present: true, missing: [])
    Survey::TableState.new(name: name, present: present, missing_columns: missing)
  end

  def template(id, type: 'IssueListReportTemplate', body: '<p>{{ issue.subject }}</p>')
    Survey::Template.new(id: id, type: type, name: "template #{id}", project_id: nil,
                         bytes: body.bytesize, analysis: Linter.analyse(body))
  end

  def result(templates: [], tables: nil, schedules: nil, recipients: nil, notes: ['a note'],
             counts: nil, truncated: false)
    Survey::Result.new(
      tables: tables || Survey::TABLES.map { |name| table(name) },
      templates: templates,
      template_counts: counts || { 'IssueListReportTemplate' => templates.length },
      schedules: schedules || { 'present' => true, 'total' => 2, 'enabled' => 1,
                                'enabled_column' => 'enabled', 'by_period' => { 'daily' => 2 } },
      recipients: recipients || { 'present' => true, 'rows' => 3, 'distinct_users' => 2,
                                  'addressable' => false },
      truncated: truncated,
      notes: notes
    )
  end

  def render(*args, **kwargs)
    described_class.render(result(*args, **kwargs))
  end

  it 'returns plain strings, so `puts` prints one line each' do
    expect(render(templates: [template(1)])).to all(be_a(String))
  end

  it 'says it wrote nothing, before any section' do
    lines = render
    notice = lines.index { |line| line.match?(/Nothing was written/) }
    first_section = lines.index { |line| line.match?(/^1\. /) }

    expect(notice).not_to be_nil
    expect(notice).to be < first_section
  end

  it 'renders the six sections in the order an operator needs them' do
    text = render(templates: [template(1)]).join("\n")
    headings = text.scan(/^\d+\. .+$/)

    expect(headings.length).to eq(6)
    expect(headings.first).to match(/reporter's tables/)
    expect(headings.last).to match(/could NOT answer/)
  end

  describe 'section 1 — what is there' do
    it 'marks an absent table as ABSENT rather than leaving it out' do
      text = render(tables: [table('report_templates'), table('report_schedules', present: false)])
                .join("\n")

      expect(text).to match(/report_schedules\s+ABSENT/)
    end

    it 'names each column it could not find' do
      text = render(tables: [table('report_templates', missing: %w[content updated_on])]).join("\n")

      expect(text).to match(/\(no content column\)/)
      expect(text).to match(/\(no updated_on column\)/)
    end
  end

  describe 'when reporter was never installed here' do
    subject(:text) do
      render(tables: Survey::TABLES.map { |name| table(name, present: false) },
             notes: ['R-15 query 4 … cannot be answered from the database']).join("\n")
    end

    it 'explains that an empty result is not evidence about production' do
      expect(text).to match(/not evidence that the\s*\n?\s*production installation has nothing/)
    end

    it 'does not invite the reader to conclude the survey is finished' do
      expect(text).to match(/Run this task against the/)
    end

    # The one section that must survive every early return.
    it 'still prints what it could not answer' do
      expect(text).to match(/could NOT answer/)
      expect(text).to match(/R-15 query 4/)
    end
  end

  describe 'section 4 — usage' do
    it 'says explicitly that no usage IS the answer, rather than printing nothing' do
      text = render(templates: [template(1)]).join("\n")

      expect(text).to match(/no tracked accessor, filter or tag appears/)
      expect(text).to match(/nothing here depends on them/)
    end

    it 'sums a marker across templates and sorts by count' do
      body = '{{ issue.story_points }} {{ issue.tags }}'
      text = render(templates: [template(1, body: body), template(2, body: body)]).join("\n")

      expect(text).to match(/story_points\s+2/)
      expect(text).to match(/tags\s+2/)
    end

    it 'reports "none" for a chart-less estate rather than an empty heading' do
      expect(render(templates: [template(1)]).join("\n")).to match(/Chart\.js instances: none/)
    end

    it 'counts chart instances by declared type' do
      body = "<script>new Chart(a, { type: 'bar' }); new Chart(b, { type: 'bar' });</script>"
      text = render(templates: [template(1, body: body)]).join("\n")

      expect(text).to match(/Chart\.js instances: 2, by type/)
      expect(text).to match(/bar\s+2/)
    end
  end

  describe 'section 5 — rework' do
    let(:broken) { template(1, body: "<footer>[page]</footer>") }

    it 'names the count out of the total' do
      text = described_class.render(result(templates: [broken, template(2)])).join("\n")

      expect(text).to match(/1 of 2 template\(s\) have at least one blocking finding/)
    end

    it 'says so plainly when nothing blocks' do
      expect(render(templates: [template(1)]).join("\n")).to match(/Nothing here blocks/)
    end

    it 'prints the rule, the line and the excerpt for each finding' do
      text = described_class.render(result(templates: [broken])).join("\n")

      expect(text).to match(/ERROR\s+line 1\s+footer\.engine_page_token/)
      expect(text).to match(/> <footer>\[page\]<\/footer>/)
    end

    it 'distinguishes a warning from an error in the margin' do
      warned = template(1, body: '<script>beginAtZero: true</script>')
      # A warning alone is not rework, so force the template into the section with an
      # error alongside it.
      both = template(2, body: "<script>xAxes: []\nbeginAtZero: true</script>")
      text = described_class.render(result(templates: [warned, both])).join("\n")

      expect(text).to match(/ERROR\s+line 1\s+chartjs2\.scales_axes/)
      expect(text).to match(/warning line 2\s+chartjs2\.begin_at_zero_moved/)
    end

    it 'never prints a template body, only bounded excerpts' do
      secret = "<footer>[page]</footer>\n<p>#{'S' * 400}</p>"
      text   = described_class.render(result(templates: [template(1, body: secret)])).join("\n")

      expect(text).not_to include('S' * 200)
    end
  end

  describe 'the bounds — at the limit and one past it' do
    def broken_templates(n)
      (1..n).map { |id| template(id, body: '<footer>[page]</footer>') }
    end

    it 'details every template AT the limit' do
      stub_const("#{described_class}::MAX_TEMPLATES_DETAILED", 2)
      text = described_class.render(result(templates: broken_templates(2))).join("\n")

      expect(text).not_to match(/not detailed here/)
      expect(text).to match(/template 1/).and match(/template 2/)
    end

    it 'stops detailing one PAST the limit and says the count is still complete' do
      stub_const("#{described_class}::MAX_TEMPLATES_DETAILED", 2)
      text = described_class.render(result(templates: broken_templates(3))).join("\n")

      expect(text).to match(/3 of 3 template\(s\)/)
      expect(text).to match(/and 1 more, not detailed here/)
      expect(text).to match(/The count above is complete; the detail is not/)
    end

    it 'bounds the findings printed per template and says how many it dropped' do
      stub_const("#{described_class}::MAX_FINDINGS_PER_TEMPLATE", 1)
      many = template(1, body: "<footer>[page]</footer>\n<footer>[topage]</footer>")
      text = described_class.render(result(templates: [many])).join("\n")

      expect(text).to match(/… and 1 more finding\(s\) in this template/)
    end

    # Deliberately asserted on the MESSAGE lines only. An excerpt line can be longer:
    # it is a code fragment, breaking it would make an identifier unsearchable, and it
    # is bounded instead by TemplateLinter::EXCERPT_LIMIT. Asserting a width over
    # every line would have passed here by accident — the template in this example has
    # a short excerpt — and claimed something the formatter does not do.
    it 'wraps message lines inside the terminal width' do
      body   = '<script src="https://cdnjs.cloudflare.com/a/very/long/path/to/Chart.min.js"></script>' \
               "\n<footer>[page]</footer>"
      lines  = described_class.render(result(templates: [template(1, body: body)]))
      indent = described_class::MESSAGE_INDENT
      messages = lines.select { |line| line.start_with?(indent) && !line.include?('> ') }

      expect(messages).not_to be_empty
      expect(messages.map(&:length).max).to be <= described_class::WRAP_WIDTH + indent.length
    end

    it 'leaves an excerpt line unwrapped, bounded by the linter instead' do
      body = "<footer>[page]</footer>\n"
      excerpt_line = described_class.render(result(templates: [template(1, body: body)]))
                                   .find { |line| line.include?('> <footer>') }

      expect(excerpt_line).not_to be_nil
      expect(excerpt_line.length).to be <= Linter::EXCERPT_LIMIT +
                                           described_class::MESSAGE_INDENT.length + 3
    end

    it 'says how many times a rule matched on one line instead of repeating it' do
      twice = template(1, body: '<footer>[page] / [topage]</footer>')
      text  = described_class.render(result(templates: [twice])).join("\n")

      expect(text).to match(/\(x2 on this line\)/)
      expect(text.scan(/footer\.engine_page_token/).length).to eq(1)
    end
  end

  describe 'section 6 — what was not answered' do
    it 'prints every note, one indented block each' do
      text = render(notes: ["first note\n  second line", 'another note']).join("\n")

      expect(text).to match(/  first note/)
      expect(text).to match(/  another note/)
    end

    it 'renders a multi-line note without losing its lines' do
      text = render(notes: ["line one\nline two"]).join("\n")

      expect(text).to match(/line one/)
      expect(text).to match(/line two/)
    end
  end
end
