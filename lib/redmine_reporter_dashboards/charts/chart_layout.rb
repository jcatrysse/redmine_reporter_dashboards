# frozen_string_literal: true

require_relative 'chart_spec'
require_relative 'palette'

module RedmineReporterDashboards
  module Charts
    # THE MECHANISM THAT MAKES "IDENTICAL IN HTML AND PDF" A CONSTRUCTION.
    #
    # technical-spec.md §6: "one shared `ChartLayout` computed **server-side in Ruby for
    # both paths** — scales, tick arrays, palette, label truncation. Chart.js is handed
    # explicit bounds and ticks and is **not** allowed to auto-scale."
    #
    # That last clause is the whole design. Chart.js's defaults are excellent and they
    # are also *its own*: it picks its own tick count, its own axis maximum, its own
    # label rotation and its own plot rectangle, all from the font metrics of the
    # browser it happens to be running in. A server-side SVG cannot reproduce any of
    # those decisions, so two paths that both "look right" drift — and the drift is
    # invisible until somebody puts the HTML and the PDF side by side.
    #
    # So neither path decides anything. This object decides, once, and both emitters
    # read it. `ChartjsEmitter` writes the tick array, the min, the max and the padding
    # into the config; `SvgRenderer` draws the same numbers. The falsifier in
    # `spec/charts/shared_layout_falsifier_spec.rb` is what stops that being a claim.
    #
    # --- TEXT IS MEASURED BY A RULE, NOT BY A FONT ---
    #
    # Ruby has no font metrics and the browser will not tell us its own in time to lay
    # out a PDF. So text width is `characters × font_size × CHAR_WIDTH_RATIO` — an
    # approximation, deliberately, and the approximation is the point: it is the SAME
    # approximation on both paths. A layout that measured the real font in the browser
    # and guessed in Ruby would be *more* accurate in HTML and *less* consistent between
    # the two, which is the trade this design refuses.
    #
    # Everything here is integers or two-decimal floats. A layout that emitted
    # `128.33333333333334` would produce SVG goldens that differ by platform rounding,
    # and a golden that cannot be diffed is not a golden.
    class ChartLayout
      # A rectangle. Plain, frozen, and rounded on the way in.
      Box = Struct.new(:x, :y, :width, :height) do
        def right
          (x + width).round(2)
        end

        def bottom
          (y + height).round(2)
        end

        def to_h
          { 'x' => x, 'y' => y, 'width' => width, 'height' => height }
        end
      end

      # One category's slot along the category axis.
      Band = Struct.new(:index, :label, :offset, :size) do
        def center
          (offset + (size / 2.0)).round(2)
        end
      end

      # The value axis: an explicit domain and an explicit tick array, which is exactly
      # what Chart.js has to be handed to stop it choosing its own.
      Scale = Struct.new(:min, :max, :step, :ticks) do
        def span
          (max - min).abs
        end

        def to_h
          { 'min' => min, 'max' => max, 'step' => step, 'ticks' => ticks }
        end
      end

      # --- Type scale. ONE, shared by HTML and PDF (§9b). ---
      TITLE_FONT = 14
      AXIS_TITLE_FONT = 12
      TICK_FONT = 11
      LEGEND_FONT = 11
      LABEL_FONT = 11

      # See the class comment. 0.55 em per character is the usual working figure for a
      # humanist sans at text sizes; it is wrong for `iii` and wrong for `WWW`, equally
      # wrong on both paths, and that is what it is for.
      CHAR_WIDTH_RATIO = 0.55
      LINE_HEIGHT_RATIO = 1.3

      PADDING = 12
      TICK_LENGTH = 4
      TICK_GAP = 4
      LEGEND_SWATCH = 10
      LEGEND_GAP = 6
      LEGEND_ITEM_GAP = 14

      # A category label longer than this is truncated with an ellipsis and the
      # truncation is RECORDED. Not silently shortened: "Infrastructure — Netwo…" and
      # "Infrastructure — Netwe…" are two different projects reading as one, and a
      # reader who is not told cannot know to widen the chart.
      MAX_LABEL_CHARS = 24

      # How many ticks to aim for. Aim, not require: the nice-number step is chosen
      # first and the count follows from it, because ticks at 0/7/14/21 are worse than
      # four ticks at 0/10/20/30.
      TARGET_TICKS = 5

      # Pie charts get a square plot and a legend beside them; a pie whose plot is the
      # full width has its labels in the margin.
      PIE_LEGEND_WIDTH_RATIO = 0.38

      PROGRESS_BAR_HEIGHT = 24

      attr_reader :spec, :plot, :scale, :bands, :colors, :labels, :legend_box,
                  :degradations

      def initialize(spec)
        @spec = spec
        @degradations = []
        @labels = truncate_labels(spec.categories)
        @colors = resolve_colors
        @scale = build_scale
        @legend_box = nil
        @plot = build_plot
        @bands = build_bands
        @degradations.freeze
        freeze
      end

      def self.for(spec)
        new(spec)
      end

      def width
        spec.width
      end

      def height
        spec.height
      end

      # THE ONE CONVERSION. Both emitters ask this object where a value sits; neither
      # computes it. For a horizontal chart the value axis runs left-to-right, for a
      # vertical one bottom-to-top, and the sign flip is here rather than in two places
      # that could disagree about it.
      def value_to_px(value)
        return spec.horizontal? ? plot.x : plot.bottom if scale.span.zero?

        fraction = (value - scale.min) / scale.span.to_f
        if spec.horizontal?
          (plot.x + (fraction * plot.width)).round(2)
        else
          (plot.bottom - (fraction * plot.height)).round(2)
        end
      end

      # The pixel distance a magnitude occupies, for a bar's length. Separate from
      # `value_to_px` because a bar from 0 to 5 and a bar from 10 to 15 are the same
      # length and different positions.
      def length_px(magnitude)
        return 0.0 if scale.span.zero?

        axis = spec.horizontal? ? plot.width : plot.height
        ((magnitude.abs / scale.span.to_f) * axis).round(2)
      end

      def zero_px
        value_to_px(scale.min.negative? && scale.max.positive? ? 0 : scale.min)
      end

      def band(index)
        bands[index]
      end

      def color(index)
        colors[index % colors.length]
      end

      def stroke(index)
        Palette.stroke(color(index))
      end

      # The cumulative stack for one category: [[series_index, from, to], …] in draw
      # order. Negatives stack downward from zero and positives upward, which is what
      # makes `diverging_stacked_bar` a diverging chart rather than a stacked one with
      # some bars pointing the wrong way.
      def stack(category_index)
        positive = 0.0
        negative = 0.0
        spec.series.each_with_index.filter_map do |series, series_index|
          value = series.values[category_index]
          next if value.nil? || value.zero?

          if value.negative?
            from = negative
            negative += value
            [series_index, from, negative]
          else
            from = positive
            positive += value
            [series_index, from, positive]
          end
        end
      end

      # Pie geometry, in the layout for the same reason everything else is: the HTML pie
      # and the SVG pie must agree about where the centre is.
      def pie
        radius = ([plot.width, plot.height].min / 2.0).round(2)
        { 'cx' => (plot.x + (plot.width / 2.0)).round(2),
          'cy' => (plot.y + (plot.height / 2.0)).round(2),
          'radius' => radius,
          'inner_radius' => (spec.type == :doughnut ? (radius * 0.55).round(2) : 0.0) }
      end

      # Every slice as [series_or_category_index, start_fraction, end_fraction]. A pie
      # reads its numbers from the FIRST series across categories — a pie of several
      # series is not a pie — and that decision is recorded rather than assumed.
      def slices
        values = pie_values
        total = values.sum
        return [] if total.zero?

        cursor = 0.0
        values.each_with_index.filter_map do |value, index|
          next if value.zero?

          from = cursor
          cursor += value / total
          [index, from.round(6), cursor.round(6)]
        end
      end

      def pie_values
        return [] if spec.series.empty?

        spec.series.first.values.map { |value| value.nil? ? 0.0 : value.abs }
      end

      # The progress family: one number against a whole. `max` comes from the scale, so
      # `{% chart type: progress %}` with an explicit y_max behaves like every other
      # family rather than having its own bounds rule.
      def progress_fraction
        values = spec.series.first&.values&.compact
        return 0.0 if values.nil? || values.empty? || scale.max.zero?

        (values.first / scale.max.to_f).clamp(0.0, 1.0).round(6)
      end

      def text_width(text, font_size)
        (text.to_s.length * font_size * CHAR_WIDTH_RATIO).round(2)
      end

      # Public because `SvgRenderer` places the x-axis title above the legend and needs
      # the same number this object reserved. A renderer that recomputed it would be a
      # second opinion about the layout, which is the one thing this class exists to
      # prevent.
      def legend_height
        line_height(LEGEND_FONT) + LEGEND_GAP
      end

      def to_h
        { 'width' => width, 'height' => height, 'plot' => plot.to_h,
          'scale' => scale.to_h, 'colors' => colors,
          'labels' => labels, 'legend' => legend_box&.to_h }
      end

      # ------------------------------------------------------------------
      # Construction
      # ------------------------------------------------------------------

      private

      def degrade(code, detail, data = {})
        @degradations << { code: code, detail: detail, data: data }
      end

      def truncate_labels(categories)
        categories.map do |label|
          next label if label.length <= MAX_LABEL_CHARS

          degrade(:chart_label_truncated,
                  "category label #{label.inspect} is longer than #{MAX_LABEL_CHARS} characters " \
                  'and was shortened — widen the chart or shorten the label',
                  'label' => label)
          "#{label[0, MAX_LABEL_CHARS - 1]}…"
        end.freeze
      end

      def resolve_colors
        if spec.type == :diverging_stacked_bar
          return Palette.diverging(spec.series.length).freeze
        end

        return [Palette::PROGRESS_FILL].freeze if spec.type == :progress

        count = spec.family == :pie ? spec.categories.length : spec.series.length
        if Palette.wrapped?(count)
          degrade(:chart_palette_wrapped,
                  "#{count} series share #{Palette::SERIES.length} colours, so two of them are " \
                  'drawn the same — the legend still tells them apart',
                  'count' => count)
        end

        list = spec.series.map(&:color)
        (0...[count, 1].max).map { |index| list[index] || Palette.series(index) }.freeze
      end

      # --- The value domain ---
      #
      # A BAR CHART STARTS AT ZERO. Always, and it is not a preference: the length of a
      # bar is the only thing it encodes, so a bar axis that begins at 40 makes 41 look
      # like nothing and 50 look like ten times it. A line encodes position rather than
      # length, so it may begin where its data does.
      def build_scale
        low, high = domain
        return Scale.new(0, 1, 1, [0, 1].freeze).freeze if low.nil?

        low = 0 if zero_based? && low > 0
        high = 0 if zero_based? && high < 0
        return degenerate_scale(low) if (high - low).abs < Float::EPSILON

        step = nice_step((high - low) / TARGET_TICKS.to_f)
        min = (low / step).floor * step
        max = (high / step).ceil * step
        Scale.new(round_tick(min), round_tick(max), round_tick(step), ticks(min, max, step)).freeze
      end

      def zero_based?
        %i[bar stacked_bar progress].include?(spec.type)
      end

      def domain
        return [nil, nil] if spec.empty?
        return [0.0, [spec.values.max, 0.0].max] if spec.family == :pie

        if spec.stacked?
          sums = (0...spec.categories.length).map do |index|
            positive = 0.0
            negative = 0.0
            spec.series.each do |series|
              value = series.values[index]
              next if value.nil?

              value.negative? ? negative += value : positive += value
            end
            [negative, positive]
          end
          return [sums.map(&:first).min || 0.0, sums.map(&:last).max || 0.0]
        end

        [spec.values.min, spec.values.max]
      end

      # A chart whose values are all the same number still needs an axis. Anchoring it
      # at zero with the value at the top is the reading a bar chart already implies,
      # and it beats an axis from 5 to 5 where every bar has zero length.
      def degenerate_scale(value)
        return Scale.new(0, 1, 1, [0, 1].freeze).freeze if value.zero?

        step = nice_step(value.abs / TARGET_TICKS.to_f)
        bound = (value.abs / step).ceil * step
        if value.negative?
          Scale.new(round_tick(-bound), 0, round_tick(step), ticks(-bound, 0, step)).freeze
        else
          Scale.new(0, round_tick(bound), round_tick(step), ticks(0, bound, step)).freeze
        end
      end

      # 1 / 2 / 2.5 / 5 / 10 × a power of ten. The textbook set, and the reason `2.5` is
      # in it is quarters: an axis of 0/25/50/75/100 is one people read without effort
      # and 0/20/40/60/80/100 is one they count.
      NICE_STEPS = [1.0, 2.0, 2.5, 5.0, 10.0].freeze

      def nice_step(raw)
        return 1.0 if raw <= 0 || !raw.finite?

        magnitude = 10.0**Math.log10(raw).floor
        normalised = raw / magnitude
        NICE_STEPS.find { |candidate| normalised <= candidate } * magnitude
      end

      def ticks(min, max, step)
        count = ((max - min) / step).round
        (0..count).map { |index| round_tick(min + (index * step)) }.freeze
      end

      # Integers stay integers. `0.0` printed on an axis of issue counts is noise, and
      # `10.000000000000002` is the floating-point artefact every tick generator has to
      # answer for.
      def round_tick(value)
        rounded = value.round(6)
        rounded == rounded.to_i ? rounded.to_i : rounded
      end

      # --- The plot rectangle ---
      #
      # Reserve, then subtract. Each reservation is one named quantity so a reader can
      # follow where a pixel went — and so the falsifier can point at the number it
      # disagrees with.
      def build_plot
        top = PADDING + (spec.title ? line_height(TITLE_FONT) : 0)
        bottom = PADDING
        left = PADDING
        right = PADDING

        if spec.family == :pie
          legend_width = spec.legend ? (width * PIE_LEGEND_WIDTH_RATIO).round : 0
          @legend_box = legend_box_for(:right, legend_width, top) if legend_width.positive?
          return box(left, top, width - left - right - legend_width, height - top - bottom)
        end

        if spec.type == :progress
          return box(left, top, width - left - right, PROGRESS_BAR_HEIGHT)
        end

        if spec.legend
          @legend_box = legend_box_for(:bottom, width - (2 * PADDING), height - PADDING - legend_height)
          bottom += legend_height
        end

        if spec.horizontal?
          left += category_label_width + axis_title_reserve(spec.y_title)
          bottom += tick_label_height + axis_title_reserve(spec.x_title)
        else
          left += tick_label_width + axis_title_reserve(spec.y_title)
          bottom += category_label_height + axis_title_reserve(spec.x_title)
        end

        box(left, top, width - left - right, height - top - bottom)
      end

      def box(x, y, w, h)
        Box.new(x.round(2), y.round(2), [w, 1].max.round(2), [h, 1].max.round(2)).freeze
      end

      def legend_box_for(side, box_width, y)
        Box.new(PADDING.round(2),
                y.round(2),
                [box_width, 1].max.round(2),
                (side == :right ? (height - y - PADDING) : legend_height).round(2)).freeze
      end

      def line_height(font_size)
        (font_size * LINE_HEIGHT_RATIO).ceil
      end

      def axis_title_reserve(title)
        title ? line_height(AXIS_TITLE_FONT) : 0
      end

      def tick_label_width
        widest = scale.ticks.map { |tick| text_width(format_tick(tick), TICK_FONT) }.max || 0
        (widest + TICK_LENGTH + TICK_GAP).ceil
      end

      def tick_label_height
        line_height(TICK_FONT) + TICK_LENGTH + TICK_GAP
      end

      def category_label_width
        widest = labels.map { |label| text_width(label, LABEL_FONT) }.max || 0
        (widest + TICK_LENGTH + TICK_GAP).ceil
      end

      def category_label_height
        line_height(LABEL_FONT) + TICK_LENGTH + TICK_GAP
      end

      public

      # A tick as it is PRINTED — and both paths print it the same way, which matters
      # more than which way. Chart.js is given this array as literal strings so it
      # cannot apply its own number formatting on top.
      def format_tick(value)
        return value.to_s if value.is_a?(Integer)
        return value.to_i.to_s if value == value.to_i

        format('%.2f', value).sub(/0\z/, '')
      end

      private

      # Bands along the category axis. `BAND_PADDING` is the gap either side of a bar
      # group, as a fraction of the band — 0.12 leaves the bars clearly separated
      # without making a two-category chart look like two isolated columns.
      BAND_PADDING = 0.12

      def build_bands
        count = spec.categories.length
        return [].freeze if count.zero?

        axis = spec.horizontal? ? plot.height : plot.width
        origin = spec.horizontal? ? plot.y : plot.x
        size = axis / count.to_f

        labels.each_with_index.map do |label, index|
          Band.new(index, label, (origin + (index * size)).round(2), size.round(2)).freeze
        end.freeze
      end

      public

      # The drawable width of one bar inside its band. Grouped when several series are
      # not stacked; the full band (minus padding) when they are.
      def bar_width
        band_size = bands.first&.size || 0
        usable = band_size * (1 - (2 * BAND_PADDING))
        return usable.round(2) if spec.stacked? || spec.series.length <= 1

        (usable / spec.series.length).round(2)
      end

      def bar_offset(series_index)
        band_size = bands.first&.size || 0
        start = band_size * BAND_PADDING
        return start.round(2) if spec.stacked? || spec.series.length <= 1

        (start + (series_index * bar_width)).round(2)
      end
    end
  end
end
