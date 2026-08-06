# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/template_linter'

# The linter is pure string work, so it is tested here, DB-less, on every supported
# Redmine. Two things this file is built to prove, beyond "the regex matches":
#
#   1. every rule has a NEGATIVE case. A rule that only ever fires is indistinguishable
#      from a rule that always fires, and the second one gets switched off within a week.
#   2. SCOPE holds. `color:` in a stylesheet is not `issue.color`, and `legend:` in CSS
#      is not a Chart.js option. Scope is what makes the counts worth reading, so it is
#      asserted per scope rather than assumed from the constant.
RSpec.describe RedmineReporterDashboards::TemplateLinter do
  def script(body)
    "<script>\n#{body}\n</script>"
  end

  describe 'the rule table itself' do
    it 'gives every rule an id, a severity this file knows, and a scope' do
      described_class.rules.each do |rule|
        expect(rule.id).to match(/\A[a-z_0-9]+\.[a-z_0-9]+\z/), "#{rule.inspect} has an odd id"
        expect(described_class::SEVERITIES).to include(rule.severity), rule.id
        expect(described_class::SCOPES).to include(rule.scope), rule.id
        expect(rule.message.to_s.length).to be > 30, "#{rule.id}'s message says too little"
      end
    end

    it 'has unique rule ids' do
      ids = described_class.rules.map(&:id)

      expect(ids.tally.select { |_id, n| n > 1 }).to eq({})
    end

    it 'says what to do, not only what is wrong' do
      # Every message names the replacement or the reason. A finding an author cannot
      # act on is a finding they learn to ignore.
      described_class.rules.each do |rule|
        # ONE LINE, no `/x`. The extended flag strips insignificant whitespace, which
        # turns `write the` into `writethe` and silently stops matching — found the
        # hard way while adding the last four alternatives.
        expect(rule.message).to match(
          /v3|v4|owned|engine|document request|json|js|chart layer|readiness|replaced|vendors|write the|ask the|use the|not provided by/i
        ), "#{rule.id}'s message offers no way forward"
      end
    end
  end

  describe 'Chart.js 2 idioms' do
    {
      'chartjs2.scales_axes' => 'scales: { xAxes: [{}] }',
      'chartjs2.horizontal_bar' => "type: 'horizontalBar'",
      'chartjs2.element_at_event' => 'chart.getElementAtEvent(evt)',
      'chartjs2.font_size' => 'ticks: { fontSize: 11 }',
      'chartjs2.scale_label' => 'scaleLabel: { display: true }'
    }.each do |rule, snippet|
      it "reports #{rule} as an error" do
        findings = described_class.lint(script(snippet))

        expect(findings.map(&:rule)).to include(rule)
        expect(findings.find { |f| f.rule == rule }).to be_error
      end
    end

    it 'reports the two keys that only MOVED as warnings, not errors' do
      findings = described_class.lint(script('legend: {}, beginAtZero: true'))
      moved    = findings.select { |f| f.rule.start_with?('chartjs2.') }

      expect(moved.map(&:rule)).to contain_exactly('chartjs2.legend_moved',
                                                   'chartjs2.begin_at_zero_moved')
      expect(moved).to all(satisfy { |f| !f.error? })
    end

    it 'reports the PLURAL tooltips as an error, because that spelling is v2-only' do
      # v3+ is options.plugins.tooltip, singular. Unlike legend, no nesting makes the
      # plural key valid, so it is unambiguous — and `plugins:` must not suppress it.
      findings = described_class.lint(script('plugins: { tooltips: {} }'))

      expect(findings.map(&:rule)).to eq(['chartjs2.tooltips_plural'])
      expect(findings.first).to be_error
    end

    it 'does not report the singular v3+ tooltip' do
      expect(described_class.lint(script('plugins: { tooltip: { enabled: false } }')).map(&:rule))
        .to eq([])
    end

    it 'suppresses the legend warning in a script that already knows about plugins' do
      # A config carrying a plugins: block has been migrated, so its legend: is nested.
      # Nobody half-migrates one chart's options, which is why the question is asked of
      # the whole script rather than of a look-behind window.
      expect(described_class.lint(script('plugins: { legend: { display: false } }')).map(&:rule))
        .to eq([])
    end

    it 'still reports legend in a script with no plugins block at all' do
      expect(described_class.lint(script('options: { legend: { display: false } }')).map(&:rule))
        .to eq(['chartjs2.legend_moved'])
    end

    it 'admits in the message that beginAtZero may be a false positive' do
      finding = described_class.lint(script('beginAtZero: true')).first

      expect(finding.message).to match(/false positive/)
    end

    it 'does not fire on a clean Chart.js 4 configuration' do
      clean = script(<<~JS)
        new Chart(ctx, {
          type: 'bar',
          data: payload,
          options: { indexAxis: 'y', plugins: { legend: { display: false } },
                     scales: { x: { ticks: { font: { size: 11 } } } } }
        });
      JS

      expect(described_class.lint(clean).map(&:rule)).to eq([])
    end

    # Scope. `legend:` and `color:` are ordinary CSS.
    it 'ignores Chart.js keywords outside a <script> element' do
      css = "<style>.legend: { color: red } .x { fontSize: 3 }</style>\n<p>xAxes</p>"

      expect(described_class.lint(css).map(&:rule)).to eq([])
    end
  end

  describe 'the readiness handshake' do
    it 'reports window.status assignment, the chart counter and the src global' do
      body = "#{script("window.status = 'ready'; geoChartBegin();")}\n" \
             '<script src="{{ GEO_CHARTJS_SRC }}"></script>'

      expect(described_class.lint(body).map(&:rule)).to include(
        'handshake.window_status', 'handshake.geo_chart_counter', 'handshake.chartjs_src_global'
      )
    end

    it 'does not fire on a READ of window.status, only on an assignment' do
      # Reading it is harmless; the finding is about a template driving readiness.
      expect(described_class.lint(script('if (window.status) { }')).map(&:rule)).to eq([])
    end
  end

  describe 'engine-specific markup' do
    it 'reports setLineDash inside a script' do
      expect(described_class.lint(script('ctx.setLineDash([4, 2]);')).map(&:rule))
        .to eq(['canvas.set_line_dash'])
    end

    it 'reports wkhtmltopdf footer tokens anywhere in the body' do
      findings = described_class.lint('<footer>[page] / [topage]</footer>')

      expect(findings.map(&:rule)).to eq(['footer.engine_page_token'])
    end

    it 'collapses two matches of one rule on one line into a single counted finding' do
      # A line is the unit an author fixes. Printing the same message and the same
      # excerpt twice is noise that teaches the reader to skim — seen in the first real
      # run of the rake task, which is what put this here.
      findings = described_class.lint('<footer>[page] / [topage]</footer>')

      expect(findings.length).to eq(1)
      expect(findings.first.count).to eq(2)
    end

    it 'keeps two matches on DIFFERENT lines as two findings' do
      findings = described_class.lint("<footer>[page]</footer>\n<footer>[topage]</footer>")

      expect(findings.map(&:line)).to eq([1, 2])
      expect(findings.map(&:count)).to eq([1, 1])
    end

    it 'defaults the count to 1 for a single match' do
      expect(described_class.lint('[page]').first.count).to eq(1)
    end

    it 'does not mistake an ordinary bracketed word for a footer token' do
      expect(described_class.lint('<p>see [appendix] and [1]</p>').map(&:rule)).to eq([])
    end

    it 'reports a CDN script tag as a warning' do
      body = '<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/2.8.0/Chart.min.js"></script>'
      finding = described_class.lint(body).find { |f| f.rule == 'assets.cdn_script' }

      expect(finding).not_to be_nil
      expect(finding).not_to be_error
    end

    it 'does not report a script served from the Redmine host' do
      expect(described_class.lint('<script src="/plugin_assets/x/chart.js"></script>').map(&:rule))
        .to eq([])
    end
  end

  describe 'interpolation inside <script> (FR-19)' do
    it 'reports an unfiltered interpolation' do
      findings = described_class.lint(script('var labels = ["{{ version.name }}"];'))

      expect(findings.map(&:rule)).to eq(['script.unfiltered_interpolation'])
      expect(findings.first).to be_error
    end

    it 'accepts json and js' do
      expect(described_class.lint(script('var a = {{ x | json }}; var b = {{ y | js }};')).map(&:rule))
        .to eq([])
    end

    it 'reports an interpolation whose chain merely CONTAINS json but does not end with it' do
      # `| json | upcase` re-opens the hole json closed: the last filter decides.
      findings = described_class.lint(script('var a = {{ x | json | upcase }};'))

      expect(findings.map(&:rule)).to eq(['script.unfiltered_interpolation'])
    end

    it 'reports `| escape`, which the escaping experiment measured as insufficient' do
      expect(described_class.lint(script('var a = "{{ x | escape }}";')).map(&:rule))
        .to eq(['script.unfiltered_interpolation'])
    end

    it 'does not report interpolation outside a script element' do
      expect(described_class.lint('<p>{{ issue.subject }}</p>').map(&:rule)).to eq([])
    end

    it 'does not report a Liquid TAG inside a script — a tag emits nothing' do
      expect(described_class.lint(script('{% if x %}var a = 1;{% endif %}')).map(&:rule)).to eq([])
    end

    it 'describes the measured effect rather than calling it XSS' do
      # reference/verification-liquid-js-escaping.md: 0 of 2 940 payloads executed;
      # reclassified Medium, availability. The message must not overstate it.
      finding = described_class.lint(script('var a = "{{ x }}";')).first

      expect(finding.message).to match(/SyntaxError/)
      expect(finding.message).not_to match(/XSS/i)
    end

    it 'handles a script element with attributes and mixed case' do
      body = %(<SCRIPT type="text/javascript">var a = "{{ x }}";</SCRIPT>)

      expect(described_class.lint(body).map(&:rule)).to eq(['script.unfiltered_interpolation'])
    end

    it 'scopes each finding to its own script element' do
      body = "#{script('var a = {{ x | json }};')}\n<p>text</p>\n#{script('var b = "{{ y }}";')}"
      findings = described_class.lint(body)

      expect(findings.length).to eq(1)
      expect(findings.first.line).to eq(6)
    end
  end

  # T-20. The tag still works; it stops working next minor. That is a WARNING, and the
  # examples below are as much about the severity as about the match — `Analysis#rework?`
  # is `errors.any?`, and `import:plan` uses it to answer "which templates need rework".
  # Calling a working template broken would make that answer useless in exactly the
  # release where an operator is deciding what to migrate first.
  describe 'the deprecated geo_version_map tag' do
    it 'reports the tag as a warning, not an error' do
      finding = described_class.lint('{% geo_version_map assign_to: v %}').first

      expect(finding.rule).to eq('deprecated.geo_version_map')
      expect(finding).not_to be_error
    end

    it 'does not put a template that merely uses it into rework' do
      analysis = described_class.analyse('{% geo_version_map %}')

      expect(analysis.warnings.map(&:rule)).to eq(['deprecated.geo_version_map'])
      expect(analysis).not_to be_rework
    end

    it 'names the accessors that replace it' do
      finding = described_class.lint('{% geo_version_map %}').first

      expect(finding.message).to include('issue.version.id')
      expect(finding.message).to include('.roadmap_url')
    end

    it 'counts it as usage as well, so a migration can be scoped' do
      usage = described_class.analyse('{% geo_version_map %}').usage
      group = usage.keys.find { |key| key.include?('own surface') }

      expect(usage[group]).to include('{% geo_version_map %} — deprecated' => 1)
    end

    # The two accessors the same task retired from the HOST plugin's drop are NOT
    # flagged, and that is a decision rather than an omission: `Drops::IssueDrop` keeps
    # `target_version` as an alias of `version` and `custom_field_value` as the bracket
    # drop, so a template using either is still correct against the owned layer. A rule
    # here would tell an author to rewrite working Liquid.
    it 'leaves issue.target_version and issue.custom_field_value alone — still valid surface' do
      body = '{{ issue.target_version.name }} {{ issue.custom_field_value[20] }}'

      expect(described_class.lint(body).map(&:rule)).to eq([])
    end
  end

  # §Findings E-14 generalised. The HTML scanner already skips `{% comment %}` and
  # `{% raw %}` bodies; the :liquid scope did not, so a comment EXPLAINING a migration
  # was linted as if it performed one. Every example here is a case the previous version
  # got wrong, which is the same standard `spec/html_scanner_spec.rb` is written to.
  describe 'inert Liquid blocks' do
    it 'does not lint inside a {% comment %} body' do
      body = '{% comment %} we used to call {% geo_version_map %} here {% endcomment %}'

      expect(described_class.lint(body).map(&:rule)).to eq([])
    end

    it 'does not lint inside a {% raw %} body' do
      body = '{% raw %}{% geo_version_map %}{% endraw %}'

      expect(described_class.lint(body).map(&:rule)).to eq([])
    end

    it 'honours the whitespace-control spellings' do
      body = '{%- comment -%}{% geo_version_map %}{%- endcomment -%}'

      expect(described_class.lint(body).map(&:rule)).to eq([])
    end

    it 'still lints the same construct outside the comment' do
      body = "{% comment %}{% geo_version_map %}{% endcomment %}\n{% geo_version_map %}"
      findings = described_class.lint(body)

      expect(findings.map(&:rule)).to eq(['deprecated.geo_version_map'])
      expect(findings.first.line).to eq(2)
    end

    it 'suppresses every :liquid rule inside a comment, not only the new one' do
      body = '{% comment %} do not write {{ x | md5 }} or {% if "a" == b %} {% endcomment %}'

      expect(described_class.lint(body).map(&:rule)).to eq([])
    end

    # FAILS OPEN. An unterminated comment must not silence the rest of the document —
    # a missed exclusion costs one false finding, an over-eager one hides everything
    # after it, and only one of those is recoverable by reading the output.
    it 'lints normally when a comment is never closed' do
      body = "{% comment %} oops\n{% geo_version_map %}"

      expect(described_class.lint(body).map(&:rule)).to eq(['deprecated.geo_version_map'])
    end

    # USAGE COUNTING TOO, and it has to be the same answer. A commented-out
    # `{% sql_aggregate %}` is not a dependency, and counting it would tell an operator
    # planning a migration that a template needs work it does not need. Asserted
    # separately from the findings because these are two different code paths that would
    # otherwise drift.
    it 'does not count usage inside a comment either' do
      body = '{% comment %} we could use {% sql_aggregate %} and {{ issue.story_points }} {% endcomment %}'

      expect(described_class.analyse(body).usage).to eq({})
    end

    it 'counts the same constructs when they are outside the comment' do
      body = '{% comment %}{% sql_aggregate %}{% endcomment %}{% sql_aggregate %}'
      usage = described_class.analyse(body).usage
      group = usage.keys.find { |key| key.include?('own surface') }

      expect(usage[group]['{% sql_aggregate %}']).to eq(1)
    end

    # SCOPE-SPECIFIC, deliberately. A `<script>` inside a Liquid comment is already
    # handled by `HtmlScanner`; this change is only about the :liquid regions, and a
    # :body rule (which searches the whole document) is unaffected. Pinned so the two
    # mechanisms cannot silently merge.
    it 'leaves a :body rule matching inside a comment, which is HtmlScanner\'s question' do
      body = '{% comment %} the footer token [page] is engine-specific {% endcomment %}'

      expect(described_class.lint(body).map(&:rule)).to eq(['footer.engine_page_token'])
    end
  end

  describe 'line numbers and excerpts' do
    it 'reports the line the match is on, 1-indexed' do
      body = "line one\nline two\n<script>\nctx.setLineDash([1]);\n</script>\n"

      expect(described_class.lint(body).map(&:line)).to eq([4])
    end

    it 'excerpts the whole line, stripped' do
      body = script('    ctx.setLineDash([1, 2]);    ')

      expect(described_class.lint(body).first.excerpt).to eq('ctx.setLineDash([1, 2]);')
    end

    it 'truncates an excerpt AT the limit and marks it' do
      long = "ctx.setLineDash([1]); // #{'x' * described_class::EXCERPT_LIMIT}"
      excerpt = described_class.lint(script(long)).first.excerpt

      expect(excerpt.length).to eq(described_class::EXCERPT_LIMIT + 1) # the ellipsis
      expect(excerpt).to end_with('…')
    end

    it 'leaves an excerpt exactly at the limit untouched' do
      exact = "ctx.setLineDash([1]);#{' ' * 2}//#{'x' * (described_class::EXCERPT_LIMIT - 25)}"
      excerpt = described_class.lint(script(exact)).first.excerpt

      expect(excerpt.length).to be <= described_class::EXCERPT_LIMIT
      expect(excerpt).not_to end_with('…')
    end

    it 'reports a match on the first line' do
      expect(described_class.lint('[page]').map(&:line)).to eq([1])
    end
  end

  describe 'usage counting' do
    it 'counts drop accessors inside Liquid expressions only' do
      body = <<~LIQUID
        <style>.badge { color: #333; background-color: #eee }</style>
        <p>{{ issue.color }} {{ issue.tags }} {% if issue.color %}x{% endif %}</p>
      LIQUID
      usage = described_class.analyse(body).usage
      group = usage.keys.find { |key| key.include?('paid-plugin') }

      expect(usage[group]['color']).to eq(2)
      expect(usage[group]['tags']).to eq(1)
    end

    it 'omits a marker that does not appear rather than reporting a zero' do
      usage = described_class.analyse('{{ issue.subject }}').usage

      expect(usage).to eq({})
    end

    it 'counts this plugin\'s own tags and accessors separately from the gem\'s' do
      body = '{% sql_aggregate from: issues, group_by: status %}{{ issue.target_version.name }}'
      usage = described_class.analyse(body).usage
      group = usage.keys.find { |key| key.include?('own surface') }

      expect(group).not_to be_nil
      expect(group).to satisfy { |g| usage[g].key?('{% sql_aggregate %}') }
      expect(usage[group]['issue.target_version']).to eq(1)
    end

    it 'counts jsonify as gem usage AND now flags it as a removed filter' do
      analysis = described_class.analyse(script('var a = {{ x | jsonify }};'))
      group = analysis.usage.keys.find { |key| key.include?('gem filters') }

      # T-19 added the second finding, and this example used to assert its absence.
      # The behaviour moved for a stated reason rather than by accident: `jsonify`
      # escapes correctly — it was never an ESCAPING defect, and it still is not — but
      # `Filters::REMOVED` drops it as gem-coupled, so a template using it will stop
      # working when the vendor gem goes. Telling the author now is the whole job.
      expect(analysis.findings.map(&:rule))
        .to eq(%w[filter.removed_jsonify script.unfiltered_interpolation])
      # Still counted as usage as well, which is a different question: findings are
      # what breaks, usage is what the migration has to reproduce.
      expect(analysis.usage[group]['jsonify']).to eq(1)
    end
  end

  describe 'chart inventory' do
    it 'records every new Chart( and the type it declares' do
      body = script(<<~JS)
        new Chart(a, { type: 'bar', data: {} });
        new Chart(b, { type: 'doughnut', data: {} });
        new Chart(c, { data: {} });
      JS
      analysis = described_class.analyse(body)

      expect(analysis.charts.length).to eq(3)
      expect(analysis.chart_types).to eq(%w[bar doughnut (type\ not\ found)])
    end

    it 'says "type not found" rather than guessing when the type is out of window' do
      far = "new Chart(a, {#{' ' * (described_class::CHART_TYPE_WINDOW + 10)}type: 'bar' });"

      expect(described_class.analyse(script(far)).chart_types).to eq(['(type not found)'])
    end

    it 'finds no charts in a chart-less template' do
      expect(described_class.analyse('<p>{{ issue.subject }}</p>').charts).to eq([])
    end
  end

  describe 'rework and bounding' do
    it 'needs rework when there is an error and not when there is only a warning' do
      expect(described_class.analyse(script('legend: {}')).rework?).to be(false)
      expect(described_class.analyse(script('xAxes: []')).rework?).to be(true)
    end

    it 'lints a body exactly AT the size limit without truncating' do
      body = 'x' * described_class::MAX_BODY_BYTES
      analysis = described_class.analyse(body)

      expect(analysis.truncated).to be(false)
      expect(analysis.findings.map(&:rule)).not_to include('body.truncated')
    end

    it 'reports truncation one byte PAST the limit rather than silently sampling' do
      body = "[page]#{'x' * described_class::MAX_BODY_BYTES}"
      analysis = described_class.analyse(body)

      expect(analysis.truncated).to be(true)
      expect(analysis.findings.map(&:rule)).to include('body.truncated', 'footer.engine_page_token')
    end

    it 'survives a body cut mid-character at the limit' do
      # A multi-byte character straddling the boundary must not raise; it is scrubbed.
      body = ('é' * (described_class::MAX_BODY_BYTES / 2)) + 'é'

      expect { described_class.analyse(body) }.not_to raise_error
    end

    it 'says nothing about an empty body' do
      analysis = described_class.analyse('')

      expect(analysis.findings).to eq([])
      expect(analysis.usage).to eq({})
      expect(analysis.rework?).to be(false)
    end

    it 'treats nil as an empty body rather than raising' do
      expect(described_class.analyse(nil).findings).to eq([])
    end

    # T-19 CHANGED THE ANSWER HERE, and the change is the point rather than a
    # casualty. The regexp this rule used to run on needed a closing tag to match at
    # all, so an unterminated `<script>` was linted as if it contained nothing. A
    # browser does not agree: raw text runs to end-of-file, so that interpolation is
    # live script content and the unescaped value in it is a real finding.
    #
    # The example's original purpose — the scanner TERMINATES rather than looping —
    # still holds and is still what the timeout would have hidden. So it now asserts
    # both: the call returns, and it returns the finding that is actually there.
    it 'does not hang on an unterminated script element, and still lints its content' do
      found = described_class.lint('<script>var a = "{{ x }}";')

      expect(found.map(&:rule)).to eq(['script.unfiltered_interpolation'])
      expect(found.first.line).to eq(1)
    end
  end

  describe 'ordering' do
    it 'returns findings in line order, then rule order, so output is stable' do
      body = "[page]\n#{script("xAxes: []\nwindow.status = 'x';")}\n[topage]"
      findings = described_class.lint(body)

      expect(findings.map(&:line)).to eq(findings.map(&:line).sort)
    end

    it 'orders two findings on the same line by rule id' do
      findings = described_class.lint(script("xAxes: []; window.status = 'x';"))

      expect(findings.map(&:rule)).to eq(findings.map(&:rule).sort)
    end
  end
end
