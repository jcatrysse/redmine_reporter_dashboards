# frozen_string_literal: true

require 'logger'
require 'active_support'
require_relative '../spec_helper'

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

require_relative '../../lib/redmine_reporter_dashboards/liquid/tags/chart_tag'

# T-16 — `{% chart %}`.
#
# THE THING UNDER TEST IS AN ABSENCE. §6 says the tag emits no markup, and that is not a
# stylistic claim: every chart defect this plugin has had came from a template emitting
# its own — the string-concatenated data array (`verification-liquid-js-escaping.md`), the
# hand-rolled readiness handshake, the `responsive: false` that exists because of one PDF
# engine. So the first block below asserts what the output does NOT contain, and it is the
# most important block in the file.
RSpec.describe RedmineReporterDashboards::Liquid::Tags::ChartTag do
  RRD = RedmineReporterDashboards unless defined?(RRD)

  let(:actor) { Object.new }
  let(:render_context) { RRD::Liquid::RenderContext.new(actor: actor) }

  # A breakdown result, in the exact shape `{% sql_aggregate group_by: status %}` assigns.
  let(:buckets) do
    { 'buckets' => [{ 'label' => 'New', 'count' => 12, 'url' => 'https://r/i?a=1&b=2' },
                    { 'label' => 'Closed', 'count' => 43, 'url' => 'https://r/i?a=2' }],
      'total' => 55 }
  end

  # THE HASH IS BRACED AT EVERY CALL SITE, and it has to be. This method declares a
  # keyword parameter, so `context({ 'stats' => x })` is parsed as a keyword argument named
  # "stats" and raises — the same Ruby trap `SvgRenderer#element` records. Six examples
  # here failed on it before the braces went in.
  def context(assigns = { 'stats' => buckets }, with_render_context: true)
    registers = {}
    registers[RRD::Liquid::RenderContext::REGISTER_KEY] = render_context if with_render_context
    Liquid::Context.new({}, assigns, registers)
  end

  def render(markup, ctx = context)
    described_class.new('chart', markup, []).render(ctx)
  end

  describe 'the markup it emits' do
    it 'is a placeholder and nothing else' do
      output = render('id: v1, from: stats')

      expect(output).to eq('<div class="rrd-chart-placeholder" data-rd-chart="v1"></div>')
    end

    # Each of these is a defect this plugin has actually shipped. Asserted by absence
    # because that is the only way to test a design whose value is what it refuses to do.
    it 'emits no canvas, no script, no Chart.js config and no handshake' do
      output = render('id: v1, from: stats')

      expect(output).not_to include('<canvas')
      expect(output).not_to include('<script')
      expect(output).not_to include('new Chart')
      expect(output).not_to match(/window\.status|geoChart|__rd/)
      expect(output).not_to include('responsive')
    end

    # THE AUTHOR CANNOT SAY IT. Not "should not" — there is no parameter, so a template
    # that writes one is ignored rather than obeyed, and the HTML and the PDF cannot be
    # made to disagree from a template (G3 / FR-34).
    it 'ignores an author trying to set an engine property' do
      render('id: v1, from: stats, responsive: true, animation: true, devicePixelRatio: 4')
      config = RRD::Charts::ChartjsEmitter.new(
        RRD::Charts::ChartLayout.for(render_context.charts['v1']), output: :pdf
      ).config

      expect(config['options']['responsive']).to be(false)
      expect(config['options']['animation']).to be(false)
      expect(config['options']['devicePixelRatio']).to eq(1)
    end
  end

  describe 'what it records' do
    it 'appends one ChartSpec to the render context, in document order' do
      ctx = context
      render('id: a, from: stats', ctx)
      render('id: b, from: stats, type: line', ctx)

      expect(render_context.charts.specs.map(&:id)).to eq(%w[a b])
      expect(render_context.charts['b'].type).to eq(:line)
    end

    it 'reads a breakdown result into categories and one series' do
      render('id: v1, from: stats')
      spec = render_context.charts['v1']

      expect(spec.categories).to eq(%w[New Closed])
      expect(spec.series.first.values).to eq([12.0, 43.0])
    end

    it 'carries the drill URLs the aggregator put on each bucket' do
      render('id: v1, from: stats')

      expect(render_context.charts['v1'].drill_url(0, 0)).to eq('https://r/i?a=1&b=2')
    end

    it 'reads a crosstab result, transposing rows × series into series × categories' do
      crosstab = { 'rows' => [{ 'label' => 'Team A' }, { 'label' => 'Team B' }],
                   'series' => %w[Open Closed],
                   'matrix' => [[3, 9], [5, 1]] }
      render('id: v1, from: stats, type: stacked_bar', context({ 'stats' => crosstab }))
      spec = render_context.charts['v1']

      expect(spec.categories).to eq(['Team A', 'Team B'])
      expect(spec.series.map(&:label)).to eq(%w[Open Closed])
      expect(spec.series.first.values).to eq([3.0, 5.0])
    end

    # A time series has several parallel arrays and the author picks. Guessing "all of
    # them" produces a chart nobody asked for; `open_now` on the same axis as `created`
    # is the concrete case.
    it 'reads a time series, and only the named arrays' do
      series = { 'labels' => %w[Jan Feb], 'created' => [3, 5], 'closed' => [1, 2],
                 'open_now' => [90, 93] }
      render('id: v1, from: stats, y: "created,closed"', context({ 'stats' => series }))

      expect(render_context.charts['v1'].series.map(&:label)).to eq(%w[created closed])
    end

    it 'lets an author point at a different bucket key' do
      measured = { 'buckets' => [{ 'label' => 'a', 'count' => 1, 'value' => 42.5 }] }
      render('id: v1, from: stats, y: value', context({ 'stats' => measured }))

      expect(render_context.charts['v1'].series.first.values).to eq([42.5])
    end

    # CURATOR DECISION #3 — A QUOTED PARAMETER IS LITERAL TEXT, HERE TOO.
    #
    # This tag reads three of its parameters through the context, and a chart title is
    # the likeliest of all of them to collide with a variable — every report assigns
    # `user` and `project`, and a title is a plain word. Added after a mutation:
    # replacing this tag's `TagParams.parse` with one that throws the quoting away left
    # the whole suite green, so the rule was provably untested on this tag.
    it 'takes a quoted title as the text, not as a variable of that name' do
      render('id: v1, from: stats, title: "project"',
             context({ 'stats' => buckets, 'project' => 'eCookbook' }))

      expect(render_context.charts['v1'].title).to eq('project')
    end

    it 'still resolves a BARE title from a variable, which is unchanged' do
      render('id: v1, from: stats, title: heading',
             context({ 'stats' => buckets, 'heading' => 'Open issues' }))

      expect(render_context.charts['v1'].title).to eq('Open issues')
    end

    # THE ABSENT CASE, which had no example at all and is why a `default:` had to be
    # chosen when this tag moved onto `TagParams`. `ChartSpec` normalises `''` and nil
    # through `presence`, so the two are indistinguishable downstream — this asserts the
    # observable, not the spelling.
    it 'leaves the title unset when the parameter is absent' do
      render('id: v1, from: stats')

      expect(render_context.charts['v1'].title).to be_nil
    end
  end

  describe 'when it cannot draw' do
    # INV-4. A reader looking at a gap cannot tell a refused chart from one the author
    # never wrote, and the degradation list is downstream of a reader already confused.
    it 'still emits a placeholder, marked refused, for a duplicate id' do
      ctx = context
      render('id: v1, from: stats', ctx)

      expect(render('id: v1, from: stats', ctx))
        .to include('data-rd-chart-refused="not_recorded"')
      expect(render_context.charts.length).to eq(1)
    end

    it 'refuses without a render context rather than dropping the chart silently' do
      output = render('id: v1, from: stats', context(with_render_context: false))

      expect(output).to include('data-rd-chart-refused="no_render_context"')
    end

    it 'degrades on a from: that is not an aggregation result' do
      output = render('id: v1, from: stats', context({ 'stats' => 'not a result' }))

      expect(output).to include('data-rd-chart-refused="invalid"')
      expect(render_context.diagnostics).to include(:chart_refused)
    end

    it 'degrades on a missing from: variable' do
      expect(render('id: v1, from: nothing')).to include('data-rd-chart-refused="invalid"')
    end

    it 'degrades on a missing or hostile id rather than emitting it' do
      expect(render('from: stats')).to include('data-rd-chart-refused="invalid"')
      output = render('id: "a\"><script>", from: stats')

      expect(output).not_to include('<script>')
      expect(output).to include('data-rd-chart-refused="invalid"')
    end

    # INV-5. An error is never the document — the placeholder says a chart was refused,
    # it does not print the exception into the report.
    it 'never writes the reason into the document' do
      output = render('id: v1, from: stats', context({ 'stats' => Object.new }))

      expect(output).not_to match(/Error|error|exception|NoMethod/)
    end
  end

  describe 'the degradations it publishes' do
    it 'translates the collector s findings into the Liquid vocabulary' do
      render('id: v1, from: stats, type: radar')

      expect(render_context.diagnostics).to include(:chart_type_unsupported)
      # The DETAIL is what an author reads, so it has to name the six families and say
      # what the fallback costs — a code alone sends them to the source.
      detail = render_context.diagnostics.to_a
                             .find { |entry| entry['code'] == 'chart_type_unsupported' }['detail']
      expect(detail).to include('radar')
      expect(detail).to include('JavaScript')
    end

    # §5's fact, reachable from the render context, so the renderer can negotiate
    # capabilities instead of running a `<canvas>` regexp over the finished document.
    it 'makes the JavaScript requirement answerable from the context' do
      ctx = context
      render('id: a, from: stats', ctx)

      expect(render_context.charts).not_to be_javascript_required

      render('id: b, from: stats, type: radar', ctx)

      expect(render_context.charts).to be_javascript_required
    end
  end

  describe 'the output binding' do
    # ONE AUTHORING ACT, TWO DOCUMENTS. The recording is shared across the derivation;
    # only the emitter differs.
    it 'draws the same recording as SVG or as a canvas' do
      render('id: v1, from: stats')
      spec = render_context.charts['v1']

      svg = RRD::Charts::SvgRenderer.render(spec)
      html = RRD::Charts::ChartjsEmitter.emit(spec)

      expect(svg).to start_with('<svg')
      expect(svg).not_to include('<script')
      expect(html).to include('<canvas')
      expect(html).to include('<script type="application/json"')
    end

    it 'carries the collector through a derived context rather than rebuilding it' do
      render('id: v1, from: stats')
      derived = render_context.with_output(:pdf)

      expect(derived.output).to eq(:pdf)
      expect(derived.charts).to equal(render_context.charts)
    end
  end
end
