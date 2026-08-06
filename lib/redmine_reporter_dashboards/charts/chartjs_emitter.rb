# frozen_string_literal: true

require_relative 'chart_layout'
require_relative 'palette'
require_relative '../script_safe_json'

module RedmineReporterDashboards
  module Charts
    # THE HTML PATH — a `<canvas>` and a `<script type="application/json">` data block.
    #
    # technical-spec.md §6: "**never** a string-concatenated JS array literal, which is
    # the entire class of the escaping defect".
    #
    # --- WHY THE DATA BLOCK IS THE WHOLE POINT ---
    #
    # `reference/verification-liquid-js-escaping.md` measured what the old idiom costs:
    # a version name ending in a backslash breaks the string it sits in, the `<script>`
    # block dies with a SyntaxError, and the chart, its drill links and every statement
    # after it disappear with no log line. 2 940 payloads, 0 executed — a denial of
    # rendering rather than an XSS, and one payload shape from being both.
    #
    # A data block closes the class rather than an instance of it. There is no JavaScript
    # syntax for a value to break out of: the browser hands the element's text to
    # `JSON.parse`, which either parses or throws where we can see it. The five
    # characters that can still end the ELEMENT (`<`, `>`, `&`, U+2028/9) are escaped by
    # `ScriptSafeJson`, in `\uXXXX` form so the result stays valid JSON.
    #
    # **No value from a template is ever interpolated into executable position.** Not
    # once, not for the id, not for the drill URL. `assets/javascripts/chart_boot.js`
    # reads the block and builds the chart; it is plugin code with no interpolation in
    # it at all.
    #
    # --- CHART.JS IS NOT ALLOWED TO AUTO-SCALE ---
    #
    # Every scale carries an explicit `min`, `max` and tick array from `ChartLayout`, and
    # `chart_boot.js` installs an `afterBuildTicks` that returns exactly those. Left to
    # itself Chart.js picks its own bounds from the data and its own tick count from the
    # canvas size, and a PDF drawn from the same numbers would then disagree with the
    # screen about what the axis says. §6 calls this the mechanism that makes "identical
    # in HTML and PDF" a construction; this is that mechanism's HTML half.
    #
    # --- `responsive` COMES FROM THE OUTPUT BINDING, NOT THE AUTHOR (G3 / FR-34) ---
    #
    # A template must need no engine-specific workaround. Today every shipped example
    # hand-writes `responsive: false` and a fixed canvas because wkhtmltopdf's WebKit
    # fires no resize event and a responsive canvas measures 0 there. That is an engine
    # fact and belongs nowhere near a template, so `{% chart %}` never accepts it and
    # this emitter derives it: a print target gets a fixed canvas, deterministic
    # `devicePixelRatio` and no animation; a screen target gets a responsive one.
    #
    # A formal `:responsive_canvas` capability in `Render::Capabilities` would be one
    # notch better and is deliberately not added here: the vocabulary is closed, adding
    # to it changes `config/capabilities.yml` for every engine, and gate G9 then requires
    # the generated support matrix to move in the same PR. Recorded in
    # `implementation-plan.md` §Findings F-14 rather than done quietly on the way past.
    class ChartjsEmitter
      OUTPUTS = %i[html pdf].freeze

      # Chart.js 4 type names. The mapping is the 2→4 work package §6 names, done once
      # here instead of in every template: `horizontalBar` is gone and is `bar` plus
      # `indexAxis: 'y'`, and the three stacked families are all `bar` with `stacked`
      # on both scales.
      CHARTJS_TYPES = {
        bar: 'bar', stacked_bar: 'bar', diverging_stacked_bar: 'bar',
        line: 'line', pie: 'pie', doughnut: 'doughnut', progress: 'bar'
      }.freeze

      def initialize(layout, output: :html)
        @layout = layout
        @spec = layout.spec
        @output = OUTPUTS.include?(output.to_sym) ? output.to_sym : :html
      end

      def self.emit(spec_or_layout, output: :html)
        layout = spec_or_layout.is_a?(ChartLayout) ? spec_or_layout : ChartLayout.for(spec_or_layout)
        new(layout, output: output).emit
      end

      def emit
        [%(<div class="rrd-chart-frame" data-rd-chart="#{attr(spec.id)}" style="#{frame_style}">),
         canvas,
         data_block,
         '</div>'].join("\n")
      end

      # THE FRAME IS SIZED, AND THE FALSIFIER IS WHY.
      #
      # With `responsive: true` Chart.js ignores the canvas's width/height ATTRIBUTES and
      # sizes itself to its parent's content box. In an 800px-wide document a chart the
      # layout computed for 640px was drawn 768px wide — the HTML chart and its SVG twin
      # were then literally different sizes, and asking them to agree about a plot
      # rectangle was meaningless. Measured at 21.88% on the right edge, which is what
      # `spec/charts/shared_layout_falsifier_spec.rb` exists to catch.
      #
      # `max-width` rather than `width`, because §9b wants the HTML path responsive down
      # to a phone: below the authored width the chart shrinks, and at or above it the
      # canvas is exactly the size the layout was computed for. An explicit `height` is
      # needed too — `maintainAspectRatio: false` makes Chart.js read the parent's height,
      # and an auto-height div has none to read.
      def frame_style
        "position:relative;width:100%;max-width:#{layout.width}px;height:#{layout.height}px"
      end

      # The payload, before serialisation. Public so a spec can assert the numbers
      # without parsing HTML — and so the falsifier can compare them with the layout
      # directly.
      def config
        { 'id' => spec.id,
          'type' => CHARTJS_TYPES.fetch(spec.type),
          'output' => output.to_s,
          'canvas' => { 'width' => layout.width, 'height' => layout.height },
          'data' => data,
          'options' => options,
          'axis' => axis_contract,
          'drill' => drill }
      end

      private

      attr_reader :layout, :spec, :output

      def print?
        output == :pdf
      end

      def canvas
        %(<canvas id="#{attr(canvas_id)}" width="#{layout.width}" height="#{layout.height}" ) +
          %(role="img" aria-label="#{attr(aria_label)}"></canvas>)
      end

      # `data-rd-chart-config` is what `chart_boot.js` selects on. An id would work for
      # one chart and need a registry for several; an attribute selector finds all of
      # them in document order with no shared state.
      def data_block
        %(<script type="application/json" data-rd-chart-config="#{attr(spec.id)}">) +
          ScriptSafeJson.generate(config) +
          '</script>'
      end

      def canvas_id
        "rrd-chart-#{spec.id}"
      end

      # The same sentence the SVG puts in its `<desc>`, so the two paths are equally
      # readable to a screen reader (FR-76). A canvas is a black box to assistive
      # technology; without this the chart is announced as "graphic" and nothing else.
      def aria_label
        return "#{spec.family} chart with no data" if spec.empty?

        summary = spec.series.map do |series|
          "#{series.label}: #{series.values.map { |v| v.nil? ? '—' : layout.format_tick(v) }.join(', ')}"
        end
        [spec.title || "#{spec.family} chart",
         "categories: #{spec.categories.join(', ')}", *summary].join('. ')
      end

      # ------------------------------------------------------------------
      # Data
      # ------------------------------------------------------------------

      def data
        return pie_data if spec.family == :pie

        { 'labels' => layout.labels,
          'datasets' => spec.series.each_with_index.map { |series, index| dataset(series, index) } }
      end

      # A pie's colours are per SLICE, not per series — the categories are what the
      # reader is comparing. `ChartLayout#resolve_colors` already keys the palette that
      # way for the pie family, so both paths colour slice 3 the same.
      def pie_data
        { 'labels' => layout.labels,
          'datasets' => [{
            'label' => spec.series.first&.label.to_s,
            'data' => layout.pie_values,
            'backgroundColor' => (0...spec.categories.length).map { |i| layout.color(i) },
            'borderColor' => Palette::BACKGROUND,
            'borderWidth' => 1
          }] }
      end

      def dataset(series, index)
        base = { 'label' => series.label,
                 'data' => series.values,
                 'backgroundColor' => layout.color(index),
                 'borderColor' => layout.stroke(index),
                 'borderWidth' => 1 }
        return base.merge('fill' => false, 'tension' => 0, 'pointRadius' => 3) if spec.type == :line

        base
      end

      # ------------------------------------------------------------------
      # Options
      # ------------------------------------------------------------------

      def options
        base = {
          'responsive' => !print?,
          'maintainAspectRatio' => false,
          # Determinism, and on the print path it is correctness rather than taste: an
          # engine that snapshots mid-animation gets a half-drawn canvas, which is the
          # defect `animation: { duration: 0 }` is hand-written into every shipped
          # example to avoid. The author should never have had to know.
          'animation' => false,
          'devicePixelRatio' => print? ? 1 : nil,
          'layout' => { 'padding' => ChartLayout::PADDING },
          'plugins' => plugins
        }.compact
        return base if spec.family == :pie

        base.merge('indexAxis' => spec.horizontal? ? 'y' : 'x', 'scales' => scales)
      end

      def plugins
        { 'legend' => { 'display' => spec.legend, 'position' => 'bottom',
                        'labels' => { 'font' => { 'size' => ChartLayout::LEGEND_FONT },
                                      'boxWidth' => ChartLayout::LEGEND_SWATCH } },
          # THE TITLE BOX IS PINNED, for the same reason the ticks are.
          #
          # Chart.js's title box is `lineHeight + padding.top + padding.bottom`, and its
          # defaults are 1.2 and 10/10 — so a 14px title reserves 36.8px while
          # `ChartLayout` reserves `ceil(14 × 1.3) = 19`. Measured at 17.8px, 4.94% of the
          # canvas height, by the shared-layout falsifier: the whole plot sat 18px lower
          # in HTML than in its SVG twin.
          #
          # This is not tuning a constant until a number goes green. It is the same
          # mechanism §6 already applies to the axis — hand Chart.js the explicit value
          # rather than let it choose — extended to the one other box that moves the plot.
          # Both sides now compute the height from `LINE_HEIGHT_RATIO`, so changing the
          # type scale moves them together.
          'title' => { 'display' => !spec.title.nil?, 'text' => spec.title.to_s,
                       'padding' => { 'top' => 0, 'bottom' => 0 },
                       'font' => { 'size' => ChartLayout::TITLE_FONT,
                                   'lineHeight' => ChartLayout::LINE_HEIGHT_RATIO } },
          'tooltip' => { 'enabled' => !print? } }
      end

      # The value axis is `y` on a vertical chart and `x` on a horizontal one, and this
      # is the one place that swap happens. Getting it backwards puts the tick array on
      # the category axis, where Chart.js quietly ignores it — a failure that looks like
      # "the ticks did not apply" rather than like a bug.
      def scales
        value_key = spec.horizontal? ? 'x' : 'y'
        category_key = spec.horizontal? ? 'y' : 'x'

        { value_key => value_scale, category_key => category_scale }
      end

      def value_scale
        { 'type' => 'linear',
          'min' => layout.scale.min,
          'max' => layout.scale.max,
          'stacked' => spec.stacked?,
          'beginAtZero' => layout.scale.min.zero?,
          'grid' => { 'color' => Palette::GRID },
          'border' => { 'color' => Palette::AXIS },
          'ticks' => { 'font' => { 'size' => ChartLayout::TICK_FONT },
                       'color' => Palette::MUTED_TEXT,
                       'autoSkip' => false,
                       'stepSize' => layout.scale.step },
          'title' => axis_title(spec.horizontal? ? spec.x_title : spec.y_title) }
      end

      def category_scale
        { 'stacked' => spec.stacked?,
          'grid' => { 'display' => false },
          'border' => { 'color' => Palette::AXIS },
          'ticks' => { 'font' => { 'size' => ChartLayout::LABEL_FONT },
                       'color' => Palette::TEXT,
                       'autoSkip' => false },
          'title' => axis_title(spec.horizontal? ? spec.y_title : spec.x_title) }
      end

      def axis_title(text)
        { 'display' => !text.nil?, 'text' => text.to_s,
          'font' => { 'size' => ChartLayout::AXIS_TITLE_FONT } }
      end

      # THE CONTRACT `chart_boot.js` READS.
      #
      # Chart.js takes a function for `afterBuildTicks` and another for the tick label
      # callback, and a function cannot travel in JSON — which is the whole reason the
      # data block is data and the behaviour is in a shipped file. So the exact tick
      # VALUES and their exact printed LABELS go here as arrays, and the boot script
      # installs the two functions that return them. Chart.js then has nothing left to
      # decide.
      #
      # `plot` travels too, and it is not used for drawing: it is what the shared-layout
      # falsifier compares Chart.js's own `chartArea` against, in the browser, at the
      # size the reader sees.
      def axis_contract
        { 'ticks' => layout.scale.ticks,
          'tick_labels' => layout.scale.ticks.map { |tick| layout.format_tick(tick) },
          'min' => layout.scale.min,
          'max' => layout.scale.max,
          'value_axis' => spec.horizontal? ? 'x' : 'y',
          'plot' => layout.plot.to_h }
      end

      # `drill[series_index][category_index]`, matching the SVG's `<a xlink:href>` — the
      # same URLs, reached by a click instead of by a link. `chart_boot.js` uses
      # `getElementsAtEventForMode`, which is the Chart.js 4 spelling of the
      # `getElementAtEvent` every shipped example still calls.
      def drill
        return nil unless spec.drill?

        (0...[spec.series.length, 1].max).map do |series_index|
          (0...spec.categories.length).map { |category_index| spec.drill_url(series_index, category_index) }
        end
      end

      # Attribute values only. The JSON payload never comes through here — it goes
      # through `ScriptSafeJson`, which is a different question with a different answer.
      def attr(value)
        value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end
    end
  end
end
