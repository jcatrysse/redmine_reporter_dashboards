# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/charts'

# T-16 — the chart layer, everything except the two things that need a file on disk or a
# browser (`golden_svg_spec.rb`, `shared_layout_falsifier_spec.rb`).
RSpec.describe RedmineReporterDashboards::Charts do
  C = RedmineReporterDashboards::Charts

  def spec_for(**overrides)
    C::ChartSpec.new(**{ id: 'v1', type: :bar,
                         categories: %w[New Assigned Closed],
                         series: [{ label: 'Issues', values: [12, 7, 43] }] }.merge(overrides))
  end

  # ------------------------------------------------------------------
  describe C::ChartSpec do
    it 'accepts the six families §6 names, and doughnut as pie with a hole' do
      expect(C::ChartSpec::FAMILIES.length).to eq(6)
      C::ChartSpec::TYPES.each do |type|
        expect(spec_for(type: type)).to be_supported
      end
      expect(spec_for(type: :doughnut).family).to eq(:pie)
    end

    # THE DEGRADATION IS THE FEATURE. §6: anything else falls back to Chart.js, which
    # re-adds `:javascript` as essential. A spec that only checked "unknown type raises"
    # would have described the opposite design.
    it 'draws an unknown type rather than refusing it, and remembers what was asked for' do
      spec = spec_for(type: :radar)

      expect(spec).not_to be_supported
      expect(spec.unsupported_type).to eq(:radar)
      expect(spec.type).to eq(:bar), 'an unknown type still has to draw as something'
    end

    it 'refuses an id that would need escaping in a DOM attribute' do
      ['a"b', '<script>', '1leading-digit', '', 'a' * 100].each do |bad|
        expect { spec_for(id: bad) }.to raise_error(C::ChartSpec::InvalidSpec), bad.inspect
      end
    end

    # nil is NOT zero, and the distinction survives all the way to the SVG: a line chart
    # draws a gap for one and a point on the axis for the other. Folding them would draw
    # a trend through a month nobody measured.
    it 'keeps a nil value distinct from a zero one' do
      spec = spec_for(series: [{ label: 's', values: [1, nil, 0] }])

      expect(spec.series.first.values).to eq([1.0, nil, 0.0])
      expect(spec.values).to eq([1.0, 0.0])
    end

    it 'bounds categories and series, and says which it truncated' do
      spec = spec_for(categories: (1..300).map(&:to_s),
                      series: (1..30).map { |i| { label: "s#{i}", values: [1] } })

      expect(spec.categories.length).to eq(C::ChartSpec::MAX_CATEGORIES)
      expect(spec.series.length).to eq(C::ChartSpec::MAX_SERIES)
      expect(spec.truncated_categories).to be(true)
      expect(spec.truncated_series).to be(true)
    end

    it 'clamps a hostile size instead of trusting it' do
      expect(spec_for(width: 1_000_000).width).to eq(C::ChartSpec::MAX_SIZE)
      expect(spec_for(height: -5).height).to eq(C::ChartSpec::DEFAULT_HEIGHT)
      expect(spec_for(width: 'wide').width).to eq(C::ChartSpec::DEFAULT_WIDTH)
    end

    # A pie has ONE series and N categories, so "legend when there is more than one
    # series" hid it — three unlabelled coloured wedges, meaning carried by colour
    # alone, which FR-76 forbids. Found by rendering one.
    it 'shows a pie legend even though a pie has one series' do
      expect(spec_for(type: :pie).legend).to be(true)
      expect(spec_for(type: :progress).legend).to be(false)
      expect(spec_for(legend: false, type: :pie).legend).to be(false)
    end
  end

  # ------------------------------------------------------------------
  describe C::ChartLayout do
    let(:layout) { described_class.for(spec_for) }

    it 'gives Chart.js nothing left to decide: explicit min, max, step and tick array' do
      expect(layout.scale.min).to eq(0)
      expect(layout.scale.max).to eq(50)
      expect(layout.scale.step).to eq(10)
      expect(layout.scale.ticks).to eq([0, 10, 20, 30, 40, 50])
    end

    # A BAR CHART STARTS AT ZERO. The length of a bar is the only thing it encodes, so
    # an axis beginning at 40 makes 41 look like nothing.
    it 'anchors every bar family at zero and lets a line begin at its data' do
      bars = described_class.for(spec_for(series: [{ label: 's', values: [98, 99, 100] }]))
      line = described_class.for(spec_for(type: :line, series: [{ label: 's', values: [98, 99, 100] }]))

      expect(bars.scale.min).to eq(0)
      expect(line.scale.min).to be > 0
    end

    it 'produces nice steps rather than data-derived ones' do
      {
        [1, 3, 7] => 2,
        [0, 1000] => 200,
        [0, 4] => 1,
        [0, 0.4] => 0.1
      }.each do |values, step|
        got = described_class.for(spec_for(series: [{ label: 's', values: values }])).scale.step
        expect(got).to eq(step), "#{values.inspect} -> step #{got}, expected #{step}"
      end
    end

    it 'still draws an axis when every value is identical, and when they are all zero' do
      same = described_class.for(spec_for(series: [{ label: 's', values: [5, 5, 5] }]))
      zero = described_class.for(spec_for(series: [{ label: 's', values: [0, 0] }]))

      expect(same.scale.max).to be > 0
      expect(zero.scale.ticks).to eq([0, 1])
    end

    it 'stacks over cumulative sums, not raw values' do
      layout = described_class.for(spec_for(type: :stacked_bar,
                                            series: [{ label: 'a', values: [30, 10, 5] },
                                                     { label: 'b', values: [30, 10, 5] }]))

      expect(layout.scale.max).to be >= 60
    end

    # A diverging chart's zero is in the MIDDLE, and the baseline is the only thing
    # telling a reader which side of the argument a bar is on.
    it 'spans both signs for a diverging stack and puts zero inside the plot' do
      layout = described_class.for(spec_for(type: :diverging_stacked_bar,
                                            series: [{ label: 'neg', values: [-4, -2, -1] },
                                                     { label: 'pos', values: [3, 5, 2] }]))

      expect(layout.scale.min).to be < 0
      expect(layout.scale.max).to be > 0
      expect(layout.zero_px).to be_between(layout.plot.y, layout.plot.bottom)
    end

    it 'truncates a long label and RECORDS it — a silently shortened label is two projects reading as one' do
      long = 'Infrastructure — Networking, cabling and the rest of it'
      layout = described_class.for(spec_for(categories: [long, 'b', 'c']))

      expect(layout.labels.first.length).to eq(C::ChartLayout::MAX_LABEL_CHARS)
      expect(layout.labels.first).to end_with('…')
      expect(layout.degradations.map { |d| d[:code] }).to include(:chart_label_truncated)
    end

    it 'records a wrapped palette rather than drawing two series the same colour in silence' do
      many = (1..9).map { |i| { label: "s#{i}", values: [i] } }
      layout = described_class.for(spec_for(categories: %w[a], series: many))

      expect(layout.degradations.map { |d| d[:code] }).to include(:chart_palette_wrapped)
      expect(layout.color(0)).to eq(layout.color(C::Palette::SERIES.length))
    end

    it 'flips the value axis for a horizontal chart, in one place' do
      vertical = described_class.for(spec_for)
      horizontal = described_class.for(spec_for(orientation: :horizontal))

      expect(vertical.value_to_px(vertical.scale.max)).to eq(vertical.plot.y)
      expect(horizontal.value_to_px(horizontal.scale.max)).to eq(horizontal.plot.right)
    end

    # EVERY NUMBER ROUNDED. A layout emitting 128.33333333333334 makes the SVG goldens
    # differ by platform rounding, and a golden that cannot be diffed is not a golden.
    it 'emits nothing with more than two decimals' do
      layout = described_class.for(spec_for(categories: %w[a b c d e f g],
                                            series: [{ label: 's', values: [1, 3, 7, 11, 13, 17, 19] }]))
      numbers = [layout.plot.to_h.values, layout.bands.map(&:offset), layout.bands.map(&:size),
                 layout.scale.ticks.map { |t| layout.value_to_px(t) }].flatten

      numbers.each do |number|
        expect(number).to eq(number.round(2)), "#{number} has more than two decimals"
      end
    end

    it 'is deterministic across two constructions' do
      one = described_class.for(spec_for).to_h
      two = described_class.for(spec_for).to_h

      expect(one).to eq(two)
    end
  end

  # ------------------------------------------------------------------
  describe C::Palette do
    it 'pairs every fill with a darker stroke, so a greyscale print still separates them' do
      C::Palette::SERIES.each do |hex|
        fill = C::Palette.rgb(hex).sum
        stroke = C::Palette.rgb(C::Palette.stroke(hex)).sum

        expect(stroke).to be < fill, hex
      end
    end

    # An ordered scale whose middle is not the middle is worse than no scale.
    it 'keeps the diverging ramp symmetric around its neutral' do
      expect(C::Palette.diverging(1)).to eq([C::Palette::DIVERGING[2]])
      expect(C::Palette.diverging(3))
        .to eq([C::Palette::DIVERGING[0], C::Palette::DIVERGING[2], C::Palette::DIVERGING[4]])
      expect(C::Palette.diverging(5)).to eq(C::Palette::DIVERGING)
    end

    it 'refuses a colour that is not #rrggbb rather than emitting broken SVG' do
      expect { C::Palette.stroke('red') }.to raise_error(ArgumentError)
    end
  end

  # ------------------------------------------------------------------
  describe C::Collector do
    let(:collector) { described_class.new }

    def record(id, type = :bar)
      collector.record(C::ChartSpec.new(id: id, type: type, categories: %w[a],
                                        series: [{ label: 's', values: [1] }]))
    end

    # THE POINT OF COLLECTING AT ALL (§5). Today this question is answered by a
    # `<canvas>` regexp over the finished HTML, which is wrong in both directions.
    it 'answers the capability question as a fact, not a regexp over the document' do
      record('a')
      record('b')

      expect(collector).not_to be_javascript_required
      expect(collector.required_capabilities).to eq([])

      record('c', :radar)

      expect(collector).to be_javascript_required
      expect(collector.required_capabilities).to eq(%i[javascript readiness_expression])
    end

    it 'refuses a duplicate id rather than renaming it, and names the id in the degradation' do
      expect(record('a')).to eq('a')
      expect(record('a')).to be_nil
      expect(collector.length).to eq(1)
      expect(collector.degradations.last[:code]).to eq(:chart_duplicate_id)
      expect(collector.degradations.last[:data]).to eq('id' => 'a')
    end

    it 'stops at the cap — asserted AT it and one past it' do
      C::Collector::MAX_CHARTS.times { |i| expect(record("c#{i}")).to eq("c#{i}") }

      expect(record('one_more')).to be_nil
      expect(collector.degradations.last[:code]).to eq(:chart_limit_exceeded)
    end

    it 'keeps an unsupported chart AND degrades — it is a fallback, not a refusal' do
      expect(record('a', :radar)).to eq('a')
      expect(collector.length).to eq(1)
      expect(collector.degradations.map { |d| d[:code] }).to eq([:chart_type_unsupported])
    end
  end

  # ------------------------------------------------------------------
  describe C::ChartjsEmitter do
    def config_for(**overrides)
      output = overrides.delete(:output) || :html
      described_class.new(C::ChartLayout.for(spec_for(**overrides)), output: output).config
    end

    # THE ENTIRE CLASS OF THE ESCAPING DEFECT, asserted as an absence. A JS array literal
    # is what `verification-liquid-js-escaping.md` measured; there must not be one.
    it 'puts data in a JSON block and never in JavaScript' do
      html = described_class.emit(spec_for)

      expect(html).to include('<script type="application/json"')
      expect(html).not_to match(/new Chart|var \w+ =|\[\s*'/)
      expect(html.scan('<script').length).to eq(1)
    end

    it 'escapes the five characters that can end the script ELEMENT' do
      # `\u2028` written as an ESCAPE, not as the character. A literal line separator in
      # a source file is invisible, and an editor that normalises whitespace deletes the
      # only thing this example is about.
      hostile = spec_for(categories: ['</script><img src=x>', 'a&b', "u\u2028v"])
      html = described_class.emit(hostile)
      payload = html[%r{<script[^>]*>(.*?)</script>}m, 1]

      expect(payload).not_to include('</script>')
      expect(payload).not_to include('<')
      expect(payload).to include('\\u2028'), 'the line separator has to be escaped, not passed through'
      expect { JSON.parse(payload) }.not_to raise_error
      # AND IT ROUND-TRIPS. Escaping that lost the value would pass every assertion
      # above and produce a chart with the wrong labels on it.
      labels = JSON.parse(payload)['data']['labels']
      expect(labels).to include('</script><img src=x>')
      expect(labels).to include("u\u2028v")
    end

    it 'hands Chart.js the exact ticks and bounds the layout computed' do
      layout = C::ChartLayout.for(spec_for)
      axis = described_class.new(layout).config['axis']

      expect(axis['ticks']).to eq(layout.scale.ticks)
      expect(axis['tick_labels']).to eq(layout.scale.ticks.map { |t| layout.format_tick(t) })
      expect(axis['min']).to eq(layout.scale.min)
      expect(axis['max']).to eq(layout.scale.max)
      expect(axis['plot']).to eq(layout.plot.to_h)
    end

    # G3 / FR-34: a template needs no engine-specific workaround. The author cannot say
    # `responsive`, so this is where it comes from.
    it 'derives responsive, animation and devicePixelRatio from the output binding' do
      html = config_for['options']
      pdf = config_for(output: :pdf)['options']

      expect(html['responsive']).to be(true)
      expect(pdf['responsive']).to be(false)
      expect(pdf['devicePixelRatio']).to eq(1)
      expect(html).not_to have_key('devicePixelRatio')
      [html, pdf].each { |options| expect(options['animation']).to be(false) }
    end

    # F-14, DECIDED (T-33): the derivation stays and no `:responsive_canvas` capability is
    # added. The reasoning, so this is reviewable rather than merely settled:
    #
    #   * a capability answers "can the engine do X?" and feeds a NEGOTIATION with three
    #     outcomes — refuse, degrade-and-record, proceed. Responsiveness has none of them.
    #     No engine "cannot do responsive": it is a property of the OUTPUT BINDING, because
    #     a live page reflows and a PDF page is a fixed canvas of a known size
    #   * the `:html` binding has NO ENGINE AT ALL. `{% chart %}` renders into a live
    #     Redmine page with no `DocumentRequest` and no adapter — so a capability set, which
    #     is a property of an engine adapter, cannot be consulted on the very path where
    #     `responsive: true` is the right answer. A capability whose value must be known when
    #     no engine exists is not a capability
    #   * it would cost a row in `capabilities.yml` for all three engines, an equality
    #     assertion per adapter, and a matrix regeneration under G9 — to add a column that
    #     says "no" three times and "n/a" for the binding that wants it
    #
    # What the clause in §6 is FOR — "from the engine's capabilities, not the author's
    # choice" — is that the author cannot set it. That is what this example makes mechanical.
    it 'ignores an author who writes `responsive`, `animation` or `devicePixelRatio`' do
      # `ChartSpec` has no parameter for any of them, so the emitter cannot be reached; the
      # point of asserting it is that a future `ChartSpec` field named `responsive` would
      # have to break this line rather than quietly winning.
      %i[responsive animation devicePixelRatio device_pixel_ratio].each do |forbidden|
        expect(C::ChartSpec.instance_methods).not_to include(forbidden), forbidden.to_s
        expect { spec_for(forbidden => true) }.to raise_error(ArgumentError), forbidden.to_s
      end

      # And the derived values are unchanged by anything an author could put in the spec.
      expect(config_for(title: 'responsive: true')['options']['responsive']).to be(true)
      expect(config_for(output: :pdf, title: 'responsive: true')['options']['responsive'])
        .to be(false)
    end

    it 'performs the Chart.js 2→4 renames so no template has to' do
      horizontal = config_for(orientation: :horizontal)

      expect(horizontal['type']).to eq('bar'), 'horizontalBar is gone in Chart.js 4'
      expect(horizontal['options']['indexAxis']).to eq('y')
      expect(horizontal['options']['scales']).to have_key('x')
      expect(horizontal['options']['plugins']).to have_key('legend')
      expect(horizontal['options']['scales']['x']['ticks']['font']['size'])
        .to eq(C::ChartLayout::TICK_FONT)
    end

    it 'puts the tick array on the VALUE axis, which swaps with the orientation' do
      expect(config_for['axis']['value_axis']).to eq('y')
      expect(config_for(orientation: :horizontal)['axis']['value_axis']).to eq('x')
    end

    it 'stacks both scales for a stacked family and neither for a plain bar' do
      stacked = config_for(type: :stacked_bar)['options']['scales']
      plain = config_for['options']['scales']

      expect(stacked.values.map { |scale| scale['stacked'] }).to all(be(true))
      expect(plain.values.map { |scale| scale['stacked'] }).to all(be(false))
    end

    it 'colours a pie by slice, because the categories are what the reader compares' do
      pie = config_for(type: :pie)['data']['datasets'].first

      expect(pie['backgroundColor'].length).to eq(3)
      expect(pie['backgroundColor'].uniq.length).to eq(3)
    end

    it 'describes the chart for a screen reader, which a canvas otherwise cannot' do
      html = described_class.emit(spec_for)

      expect(html).to match(/aria-label="[^"]*Issues: 12, 7, 43/)
      expect(html).to include('role="img"')
    end

    it 'carries the drill URLs as data, aligned series × category' do
      urls = [['https://r/?a=1&b=2', nil, 'https://r/?c=3']]
      config = described_class.new(C::ChartLayout.for(spec_for(drill_urls: urls))).config

      expect(config['drill']).to eq(urls)
    end
  end

  # ------------------------------------------------------------------
  describe C::SvgRenderer do
    it 'is well-formed XML for every family, empty data included' do
      require 'rexml/document'
      types = C::ChartSpec::TYPES + [:radar]

      types.each do |type|
        svg = described_class.render(spec_for(type: type))
        expect { REXML::Document.new(svg) }.not_to raise_error, type.to_s
      end
      expect { REXML::Document.new(described_class.render(spec_for(categories: [], series: []))) }
        .not_to raise_error
    end

    it 'contains no JavaScript, no handshake and no <script> at all' do
      svg = described_class.render(spec_for)

      expect(svg).not_to include('<script')
      expect(svg).not_to include('onclick')
      expect(svg).not_to match(/window\.|__rd|javascript:/)
    end

    # FR-76. A `<title>` and a `<desc>` carrying the numbers, so a reader who cannot see
    # the chart reaches the same findings.
    it 'carries the numbers in its description, not only in its pixels' do
      svg = described_class.render(spec_for(title: 'By status'))

      expect(svg).to include('<title id="rrd-chart-v1-title">By status</title>')
      expect(svg).to match(%r{<desc id="rrd-chart-v1-desc">[^<]*Issues: 12, 7, 43</desc>})
      expect(svg).to include('aria-labelledby=')
    end

    # T-38 asks for it on EVERY output, not on the default one. `emit_title_and_desc` is
    # unconditional, which is easy to see by reading and easy to lose in an edit that makes
    # one family take a different path — `pie_body`, `progress_body` and `empty_state` each
    # replace the whole body, and a `<title>` emitted from inside one of them would be
    # missing from the other two. So every type in the closed vocabulary is driven, plus the
    # empty state, which is the one case with no numbers to describe.
    C::ChartSpec::TYPES.each do |type|
      it "carries a <title> and a <desc> on a #{type} chart" do
        svg = described_class.render(spec_for(type: type))

        expect(svg).to include('<title id="rrd-chart-v1-title">')
        expect(svg).to include('<desc id="rrd-chart-v1-desc">')
        expect(svg).to include('aria-labelledby="rrd-chart-v1-title rrd-chart-v1-desc"')
        expect(svg).to include('role="img"')
      end

      it "names the family in the #{type} chart's title when the author gave none" do
        svg = described_class.render(spec_for(type: type))
        title = svg[%r{<title[^>]*>([^<]*)</title>}, 1]

        expect(title).to eq("#{spec_for(type: type).family} chart")
      end
    end

    it 'carries both even when there is no data to describe' do
      svg = described_class.render(spec_for(categories: [], series: []))

      expect(svg).to include('<title id="rrd-chart-v1-title">')
      expect(svg).to match(%r{<desc id="rrd-chart-v1-desc">[^<]*with no data</desc>})
    end

    it 'escapes the five XML entities — an unescaped & is a document that does not open' do
      svg = described_class.render(spec_for(categories: ['a & b', '<x>', %(q"q)],
                                            title: "Tom's & Jerry's <report>"))

      expect(svg).to include('&amp;')
      expect(svg).to include('&lt;x&gt;')
      expect(svg).not_to match(/<text[^>]*>[^<]*<x>/)
      require 'rexml/document'
      expect { REXML::Document.new(svg) }.not_to raise_error
    end

    it 'links a datum with BOTH href spellings, so SVG 1.1 and SVG 2 readers agree' do
      svg = described_class.render(spec_for(drill_urls: [['https://r/issues?a=1&b=2', nil, nil]]))

      expect(svg).to include('xlink:href="https://r/issues?a=1&amp;b=2"')
      expect(svg).to include('href="https://r/issues?a=1&amp;b=2"')
      expect(svg.scan('<a ').length).to eq(1), 'only the datum with a URL is linked'
    end

    it 'breaks a line at a nil rather than interpolating a month nobody measured' do
      svg = described_class.render(spec_for(type: :line,
                                            categories: %w[jan feb mar apr],
                                            series: [{ label: 's', values: [3, nil, 7, 9] }]))

      expect(svg.scan('<polyline').length).to eq(1), 'one segment, not a line across the gap'
      expect(svg.scan('<circle').length).to eq(3)
    end

    it 'draws a single-category pie as a closed ring instead of a collapsed arc' do
      svg = described_class.render(spec_for(type: :doughnut, categories: %w[only],
                                            series: [{ label: 's', values: [7] }]))

      expect(svg).to match(/<path d="M [\d.]+ [\d.]+ A /)
      expect(svg).not_to include('d=""')
    end

    it 'says "No data" rather than drawing an empty frame' do
      expect(described_class.render(spec_for(categories: [], series: []))).to include('No data')
    end

    it 'is byte-identical across two renders' do
      spec = spec_for(type: :pie, title: 'Pie', drill_urls: [%w[a b c]])

      expect(described_class.render(spec)).to eq(described_class.render(spec))
    end
  end

  # ------------------------------------------------------------------
  # The vendored library. §6: "vendored with a recorded sha256, no CDN, ever."
  describe 'the vendored Chart.js' do
    ROOT_FOR_CHARTS = File.expand_path('../..', __dir__)

    let(:path) { File.join(ROOT_FOR_CHARTS, 'assets/javascripts', C::CHARTJS_ASSET) }

    it 'is on disk at the recorded digest' do
      require 'digest'

      expect(File.exist?(path)).to be(true)
      expect(Digest::SHA256.file(path).hexdigest).to eq(C::CHARTJS_SHA256)
    end

    it 'is the version THIRD_PARTY.md and the code both name' do
      manifest = File.read(File.join(ROOT_FOR_CHARTS, 'THIRD_PARTY.md'), encoding: 'UTF-8')

      expect(manifest).to include(C::CHARTJS_VERSION)
      expect(manifest).to include(C::CHARTJS_SHA256)
      expect(File.read(path, encoding: 'UTF-8')[0, 200]).to include("Chart.js v#{C::CHARTJS_VERSION}")
    end

    # A digest recorded from the same place the file came from proves the download did
    # not corrupt. It does not prove the file is what upstream published — and the
    # manifest has to say so rather than implying more than it checked.
    it 'records where it came from and what it was checked against' do
      manifest = File.read(File.join(ROOT_FOR_CHARTS, 'THIRD_PARTY.md'), encoding: 'UTF-8')

      expect(manifest).to match(/Obtained from/)
      expect(manifest).to match(/Verified against/)
      expect(manifest).to include('MIT')
    end
  end
end
