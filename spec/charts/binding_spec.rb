# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/charts'

# T-41 — the output binding, and §Findings **M-1** is why this file exists at all.
#
# `ChartjsEmitter` and `SvgRenderer` were both written, both unit-tested and both given
# goldens by T-16, and NEITHER HAD A CALLER. Every one of those tests passed while a
# chart was an empty `<div>` in every browser and blank space in every PDF. So the two
# things this file has to establish are different from what a normal emitter spec
# establishes:
#
#   1. a placeholder actually BECOMES markup, per binding;
#   2. something in the production render path actually CALLS this module.
#
# (2) is the last example in the file and it is a source-level assertion, deliberately —
# see its own comment.
#
# NAMESPACED, because a constant assigned inside `RSpec.describe` lands on `Object` — and
# `B` and `CH` were exactly that until an independent review pointed at them, in a suite of
# 2 900 examples running under `config.order = :random`. The trap has a header in
# `spec/frame_auto_height_spec.rb` and three other files in this tree; this file is now the
# fifth to obey it rather than the first to re-learn it.
module ChartBindingSpecSupport
  B = RedmineReporterDashboards::Charts::Binding
  CH = RedmineReporterDashboards::Charts
end

RSpec.describe RedmineReporterDashboards::Charts::Binding do
  # METHODS, not constants. A constant here would land on `Object` all the same; a method
  # is scoped to the example group and reads identically at the call sites.
  def binder
    ChartBindingSpecSupport::B
  end

  def charts
    ChartBindingSpecSupport::CH
  end

  def spec_for(id: 'st', type: :bar, **overrides)
    charts::ChartSpec.new(**{ id: id, type: type,
                          categories: %w[New Assigned Closed],
                          series: [{ label: 'Issues', values: [12, 7, 43] }] }.merge(overrides))
  end

  # The tag's own markup, built the way `chart_tag.rb` builds it rather than pasted, so
  # this file cannot drift from the producer without failing.
  def placeholder(id, refused: nil)
    attrs = %(data-rd-chart="#{id}")
    attrs += %( data-rd-chart-refused="#{refused}") if refused
    %(<div class="rrd-chart-placeholder" #{attrs}></div>)
  end

  def collector_with(*specs)
    collector = charts::Collector.new
    specs.each { |one| collector.record(one) }
    collector
  end

  # ------------------------------------------------------------------ the HTML binding

  describe 'the HTML binding' do
    it 'replaces every placeholder with a canvas and its data block' do
      body = "<h1>R</h1>\n#{placeholder('st')}\n<p>after</p>"
      result = binder.apply(body, collector_with(spec_for), output: :html)

      expect(result.body).not_to include('rrd-chart-placeholder')
      expect(result.body.scan('<canvas').length).to eq(1)
      expect(result.body).to include('data-rd-chart-config="st"')
      # The surrounding document is untouched — a substitution, not a rewrite.
      expect(result.body).to include('<h1>R</h1>')
      expect(result.body).to include('<p>after</p>')
    end

    it 'emits the three scripts once, in the order they have to run in' do
      body = "#{placeholder('a')}#{placeholder('b')}"
      result = binder.apply(body, collector_with(spec_for(id: 'a'), spec_for(id: 'b')),
                       output: :html)

      expect(result).to be_javascript
      %w[chart_shell.js vendor/chart.umd.js chart_boot.js].each do |name|
        expect(result.body.scan(%(/javascripts/#{name}")).length).to eq(1)
      end
      shell = result.body.index('chart_shell.js')
      library = result.body.index('chart.umd.js')
      boot = result.body.index('chart_boot.js')
      expect([shell, library, boot]).to eq([shell, library, boot].sort)
    end

    # FR-19, and it is the defect class CLAUDE.md §5's table names: a value carrying a
    # quote, a backslash or a `</script>` used to break the JavaScript token it sat in and
    # take the whole block — chart, drill links and every later statement — with it.
    it 'survives a label that would end the script element or break a JS string' do
      hostile = %(Bad</script><script>alert(1)</script> "quoted" back\\slash)
      spec = spec_for(categories: [hostile, 'Ok'],
                      series: [{ label: 'Issues', values: [1, 2] }])
      result = binder.apply(placeholder('st'), collector_with(spec), output: :html)

      block = result.body[/<script type="application\/json"[^>]*>(.*?)<\/script>/m, 1]
      expect(block).not_to be_nil
      expect(block).not_to include('</script')
      expect(block).to include('\\u003c')
    end
  end

  # ------------------------------------------------------------------- the PDF binding

  describe 'the PDF binding' do
    it 'draws a supported family as inline SVG and needs no JavaScript' do
      result = binder.apply(placeholder('st'), collector_with(spec_for), output: :pdf)

      expect(result.body).to include('<svg')
      expect(result.body).not_to include('<canvas')
      expect(result.body).not_to include('rrd-chart-placeholder')
      expect(result).not_to be_javascript
      expect(result.body).not_to include('chart_boot.js')
    end

    # `ChartSpec` chose to CARRY an unfamiliar type rather than raise, and `#supported?`
    # exists to say "this one cannot be SVG". The binding is the only place that answer is
    # ever acted on, so the fallback belongs here rather than in a comment.
    it 'falls back to Chart.js for a type it cannot draw, and then owes the scripts' do
      result = binder.apply(placeholder('st'), collector_with(spec_for(type: :radar)),
                       output: :pdf)

      expect(result.body).to include('<canvas')
      expect(result).to be_javascript
      expect(result.body).to include('chart_boot.js')
    end

    it 'draws one SVG and one canvas when a document holds both kinds' do
      collector = collector_with(spec_for(id: 'ok'), spec_for(id: 'odd', type: :radar))
      result = binder.apply("#{placeholder('ok')}#{placeholder('odd')}", collector, output: :pdf)

      expect(result.body.scan('<canvas').length).to eq(1)
      expect(result.body.scan('<svg').length).to eq(1)
      expect(result.body.scan('chart_boot.js').length).to eq(1)
    end
  end

  # ------------------------------------------------------- what is deliberately untouched

  describe 'what it leaves alone' do
    # INV-4: a refused chart stays an ELEMENT, so a reader can tell it from a chart the
    # author never wrote. The collector already carries the degradation saying why.
    it 'leaves a refused placeholder exactly as the tag emitted it' do
      body = placeholder('st', refused: 'invalid')
      expect(binder.apply(body, collector_with(spec_for), output: :html).body).to eq(body)
    end

    it 'leaves a placeholder whose id was never recorded, and says so once' do
      logger = double('logger')
      expect(logger).to receive(:warn).once.with(/no recorded chart.*"ghost"/)

      body = placeholder('ghost')
      result = binder.apply(body, collector_with(spec_for), output: :html, logger: logger)
      expect(result.body).to eq(body)
      expect(result).not_to be_javascript
    end

    it 'returns the body untouched for an empty or absent collector' do
      body = "<p>no charts here</p>#{placeholder('st')}"
      expect(binder.apply(body, charts::Collector.new, output: :html).body).to eq(body)
      expect(binder.apply(body, nil, output: :html).body).to eq(body)
    end

    # A caller's typo must not cost the document. `:pdf` is the only value that changes
    # the answer; everything else is the HTML binding.
    it 'treats an unknown output as HTML rather than refusing' do
      result = binder.apply(placeholder('st'), collector_with(spec_for), output: :postscript)
      expect(result.body).to include('<canvas')
    end
  end

  # THE DUPLICATE-ID CONTROL, ON THE SURFACE THE COLLECTOR CANNOT SEE.
  #
  # `Collector#record` refuses a second `{% chart %}` with an id it already holds. It sees
  # tags, and this module sees markup, so an author who hand-writes the placeholder beside
  # a real tag defeats it. Found by an independent review.
  it 'binds the first placeholder for an id and leaves a repeat of it alone' do
    body = "#{placeholder('st')}#{placeholder('st')}"

    result = binder.apply(body, collector_with(spec_for), output: :html)

    expect(result.body.scan('<canvas').length).to eq(1)
    expect(result.body).to include(placeholder('st'))
  end

  it 'says so in the log, because a silent half-binding is what confused the reader' do
    logger = double('logger')
    expect(logger).to receive(:warn).once.with(/appears more than once/)

    binder.apply("#{placeholder('st')}#{placeholder('st')}",
                 collector_with(spec_for), output: :html, logger: logger)
  end

  # ------------------------------------------------------------------ the missing caller

  # THE EXAMPLE THAT WOULD HAVE CAUGHT M-1, and it is a source-level assertion because
  # the thing being asserted is a WIRING fact: `ReportRun` needs Rails to run and cannot
  # appear in this DB-less suite, so "does the production path call the binding" has no
  # behavioural expression here. It has a textual one, and a textual assertion that fails
  # when the call is deleted is worth more than a green suite that never noticed the call
  # was absent for an entire release.
  #
  # THE SENTENCE THAT USED TO BE HERE WAS FALSE, and an independent review was right to
  # call it the worst kind of comment: it said *"`spec/reporting/` covers what the binding
  # then produces end to end"* when `spec/reporting/` contained no chart coverage at all.
  # That is a claim a later reader checks INSTEAD of checking the code — the same defect
  # `template.rb` writes a paragraph about over a security-bearing query — and it is how
  # the next finding stayed invisible: `with_pdf` bound the sections and then returned the
  # UNBOUND ones, so the editor's own preview still showed the placeholder.
  #
  # The end-to-end examples now exist and are named here so the claim can be checked:
  # `spec/reporting/report_run_spec.rb`, *"returns sections whose charts are bound"* — one
  # per output, plus the no-engine failure return. This example keeps only the WIRING
  # claim, which has no behavioural expression in this DB-less file.
  it 'is called from both of ReportRun\'s binding sites, with both outputs' do
    source = File.read(
      File.expand_path('../../lib/redmine_reporter_dashboards/reporting/report_run.rb', __dir__)
    )

    expect(source).to include('Charts::Binding.apply')
    expect(source).to include('bind_charts(sections, output: :html)')
    expect(source).to include('bind_charts(sections, output: :pdf)')
  end
end
