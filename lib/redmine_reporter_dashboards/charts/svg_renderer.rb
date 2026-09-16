# frozen_string_literal: true

require_relative 'chart_layout'
require_relative 'palette'

module RedmineReporterDashboards
  module Charts
    # THE PDF PATH — inline `<svg>`, computed here, drawn by nothing.
    #
    # technical-spec.md §6: "vector, selectable, deterministic, no JS, no readiness
    # handshake, no polyfills, with `<a xlink:href>` per element for drill-through".
    # Each of those five is a property this file has to hold, and four of them are
    # properties of what it does NOT do.
    #
    # --- WHY A CHART WITH NO JAVASCRIPT IS THE INTERESTING PART ---
    #
    # It is what takes `:javascript` off the essential-capability list for the common
    # case (§5), which is what puts a JS-less engine back on the table and de-risks the
    # whole engine decision. It also deletes the readiness handshake, the polyfills and
    # the flat `javascript_delay` for any document whose charts are all supported
    # families — the PDF is drawn from markup that is already finished.
    #
    # And it is what a rasterised chart cannot do: the text is selectable, the drill
    # links are real links, and the whole thing scales to the printer's resolution
    # rather than to 96 dpi (FR-76).
    #
    # --- DETERMINISM IS A TESTABILITY DECISION, NOT A PURITY ONE ---
    #
    # The output is compared against committed goldens as TEXT. That only works if two
    # runs on two machines produce the same bytes, so: every number comes from
    # `ChartLayout` already rounded, attributes are written in a fixed order, ids are
    # derived from the chart id rather than generated, and nothing reads a clock, a
    # locale or a hash seed. A pixel diff is available and is **advisory only, never a
    # gate** (§6) — this text diff is the gate.
    #
    # --- ESCAPING ---
    #
    # Everything author-supplied goes through `xml`. Not `html_safe` anywhere: INV-9,
    # and an SVG is XML, where an unescaped `&` is a parse error rather than a rendering
    # curiosity — so the failure mode of getting this wrong is a document that does not
    # open.
    class SvgRenderer
      NS = 'http://www.w3.org/2000/svg'
      XLINK_NS = 'http://www.w3.org/1999/xlink'

      # The font stack, once, in one attribute on the root. Naming it here rather than
      # per-element keeps the file small and keeps the HTML and PDF text metrics as
      # close as the CHAR_WIDTH_RATIO approximation allows.
      FONT_FAMILY = 'Helvetica, Arial, sans-serif'

      def initialize(layout)
        @layout = layout
        @spec = layout.spec
        @out = []
      end

      def self.render(spec_or_layout)
        layout = spec_or_layout.is_a?(ChartLayout) ? spec_or_layout : ChartLayout.for(spec_or_layout)
        new(layout).render
      end

      def render
        @out = []
        open_root
        emit_title_and_desc
        emit_chart_title
        body
        emit_legend
        @out << '</svg>'
        @out.join("\n")
      end

      private

      attr_reader :layout, :spec

      def body
        return empty_state if spec.empty?

        case spec.family
        when :pie then pie_body
        when :progress then progress_body
        when :line then axes_body { line_series }
        else axes_body { bar_series }
        end
      end

      # ------------------------------------------------------------------
      # Root, title, description
      # ------------------------------------------------------------------

      # `role="img"` plus `aria-labelledby` is what makes a screen reader announce the
      # chart as one object with a name and a description, instead of reading out
      # several hundred unlabelled path elements.
      def open_root
        @out << tag('svg', 'xmlns' => NS, 'xmlns:xlink' => XLINK_NS,
                           'width' => spec.width, 'height' => spec.height,
                           'viewBox' => "0 0 #{spec.width} #{spec.height}",
                           'role' => 'img',
                           'aria-labelledby' => "#{dom_id(:title)} #{dom_id(:desc)}",
                           'font-family' => FONT_FAMILY,
                           'class' => 'rrd-chart')
        @out << element('rect', 'x' => 0, 'y' => 0, 'width' => spec.width,
                                'height' => spec.height, 'fill' => Palette::BACKGROUND)
      end

      # FR-76's first clause. The `<desc>` is where the numbers go — a reader who cannot
      # see the chart gets the same findings, not an apology for a chart.
      def emit_title_and_desc
        @out << text_node('title', spec.title || default_title, 'id' => dom_id(:title))
        @out << text_node('desc', description, 'id' => dom_id(:desc))
      end

      def default_title
        "#{spec.family} chart"
      end

      def description
        return "#{default_title} with no data" if spec.empty?

        parts = ["#{spec.family} chart"]
        parts << "#{spec.categories.length} categories: #{spec.categories.join(', ')}"
        spec.series.each do |series|
          numbers = series.values.map { |value| value.nil? ? '—' : layout.format_tick(value) }
          parts << "#{series.label}: #{numbers.join(', ')}"
        end
        parts.join('. ')
      end

      def emit_chart_title
        return if spec.title.nil?

        @out << text_node('text', spec.title,
                          'x' => ChartLayout::PADDING,
                          'y' => ChartLayout::PADDING + ChartLayout::TITLE_FONT,
                          'font-size' => ChartLayout::TITLE_FONT,
                          'font-weight' => 'bold',
                          'fill' => Palette::TEXT)
      end

      def empty_state
        @out << text_node('text', 'No data',
                          'x' => (spec.width / 2.0).round(2),
                          'y' => (spec.height / 2.0).round(2),
                          'text-anchor' => 'middle',
                          'font-size' => ChartLayout::LABEL_FONT,
                          'fill' => Palette::MUTED_TEXT)
      end

      # ------------------------------------------------------------------
      # Cartesian frame
      # ------------------------------------------------------------------

      def axes_body
        grid_lines
        yield
        axis_lines
        category_labels
        tick_labels
        axis_titles
      end

      def grid_lines
        layout.scale.ticks.each do |tick|
          position = layout.value_to_px(tick)
          @out << if spec.horizontal?
                    element('line', 'x1' => position, 'y1' => layout.plot.y,
                                    'x2' => position, 'y2' => layout.plot.bottom,
                                    'stroke' => Palette::GRID, 'stroke-width' => 1)
                  else
                    element('line', 'x1' => layout.plot.x, 'y1' => position,
                                    'x2' => layout.plot.right, 'y2' => position,
                                    'stroke' => Palette::GRID, 'stroke-width' => 1)
                  end
        end
      end

      # The baseline is drawn LAST and darker. On a diverging chart it sits at zero
      # rather than at the edge, and that line is the only thing telling a reader which
      # side of the argument a bar is on.
      def axis_lines
        baseline = layout.zero_px
        if spec.horizontal?
          @out << element('line', 'x1' => baseline, 'y1' => layout.plot.y,
                                  'x2' => baseline, 'y2' => layout.plot.bottom,
                                  'stroke' => Palette::AXIS, 'stroke-width' => 1)
          @out << element('line', 'x1' => layout.plot.x, 'y1' => layout.plot.bottom,
                                  'x2' => layout.plot.right, 'y2' => layout.plot.bottom,
                                  'stroke' => Palette::AXIS, 'stroke-width' => 1)
        else
          @out << element('line', 'x1' => layout.plot.x, 'y1' => baseline,
                                  'x2' => layout.plot.right, 'y2' => baseline,
                                  'stroke' => Palette::AXIS, 'stroke-width' => 1)
          @out << element('line', 'x1' => layout.plot.x, 'y1' => layout.plot.y,
                                  'x2' => layout.plot.x, 'y2' => layout.plot.bottom,
                                  'stroke' => Palette::AXIS, 'stroke-width' => 1)
        end
      end

      def tick_labels
        layout.scale.ticks.each do |tick|
          position = layout.value_to_px(tick)
          label = layout.format_tick(tick)
          @out << if spec.horizontal?
                    text_node('text', label,
                              'x' => position,
                              'y' => (layout.plot.bottom + ChartLayout::TICK_LENGTH +
                                      ChartLayout::TICK_FONT).round(2),
                              'text-anchor' => 'middle',
                              'font-size' => ChartLayout::TICK_FONT, 'fill' => Palette::MUTED_TEXT)
                  else
                    text_node('text', label,
                              'x' => (layout.plot.x - ChartLayout::TICK_LENGTH -
                                      ChartLayout::TICK_GAP).round(2),
                              'y' => (position + (ChartLayout::TICK_FONT / 3.0)).round(2),
                              'text-anchor' => 'end',
                              'font-size' => ChartLayout::TICK_FONT, 'fill' => Palette::MUTED_TEXT)
                  end
        end
      end

      def category_labels
        layout.bands.each do |band|
          @out << if spec.horizontal?
                    text_node('text', band.label,
                              'x' => (layout.plot.x - ChartLayout::TICK_LENGTH -
                                      ChartLayout::TICK_GAP).round(2),
                              'y' => (band.center + (ChartLayout::LABEL_FONT / 3.0)).round(2),
                              'text-anchor' => 'end',
                              'font-size' => ChartLayout::LABEL_FONT, 'fill' => Palette::TEXT)
                  else
                    text_node('text', band.label,
                              'x' => band.center,
                              'y' => (layout.plot.bottom + ChartLayout::TICK_LENGTH +
                                      ChartLayout::LABEL_FONT).round(2),
                              'text-anchor' => 'middle',
                              'font-size' => ChartLayout::LABEL_FONT, 'fill' => Palette::TEXT)
                  end
        end
      end

      def axis_titles
        if spec.x_title
          @out << text_node('text', spec.x_title,
                            'x' => (layout.plot.x + (layout.plot.width / 2.0)).round(2),
                            'y' => (spec.height - ChartLayout::PADDING -
                                    (spec.legend ? layout.legend_height : 0)).round(2),
                            'text-anchor' => 'middle',
                            'font-size' => ChartLayout::AXIS_TITLE_FONT, 'fill' => Palette::TEXT)
        end
        return if spec.y_title.nil?

        centre = (layout.plot.y + (layout.plot.height / 2.0)).round(2)
        @out << text_node('text', spec.y_title,
                          'x' => ChartLayout::PADDING,
                          'y' => centre,
                          'text-anchor' => 'middle',
                          'transform' => "rotate(-90 #{ChartLayout::PADDING} #{centre})",
                          'font-size' => ChartLayout::AXIS_TITLE_FONT, 'fill' => Palette::TEXT)
      end

      # ------------------------------------------------------------------
      # Series
      # ------------------------------------------------------------------

      def bar_series
        spec.categories.each_index do |category_index|
          if spec.stacked?
            layout.stack(category_index).each do |series_index, from, to|
              emit_bar(series_index, category_index, from, to)
            end
          else
            spec.series.each_index do |series_index|
              value = spec.series[series_index].values[category_index]
              next if value.nil?

              emit_bar(series_index, category_index, 0.0, value)
            end
          end
        end
      end

      def emit_bar(series_index, category_index, from, to)
        band = layout.band(category_index)
        thickness = layout.bar_width
        offset = band.offset + layout.bar_offset(spec.stacked? ? 0 : series_index)
        near = layout.value_to_px(from)
        far = layout.value_to_px(to)
        low = [near, far].min
        span = (near - far).abs.round(2)

        attrs =
          if spec.horizontal?
            { 'x' => low, 'y' => offset.round(2), 'width' => span, 'height' => thickness }
          else
            { 'x' => offset.round(2), 'y' => low, 'width' => thickness, 'height' => span }
          end

        wrap_drill(series_index, category_index) do
          @out << element('rect',
                          attrs.merge('fill' => layout.color(series_index),
                                      'stroke' => layout.stroke(series_index),
                                      'stroke-width' => 1,
                                      'data-rd-series' => series_index,
                                      'data-rd-category' => category_index),
                          text_node('title', datum_title(series_index, category_index)))
        end
      end

      # A line is a `<polyline>` per series plus a `<circle>` per point, and the circles
      # are what carry the drill links and the `<title>`s — a polyline can only be one
      # link, and a reader wants the point they are pointing at.
      #
      # A nil value BREAKS the line rather than joining across it. Interpolating over a
      # month with no data draws a trend that was never measured.
      def line_series
        spec.series.each_with_index do |series, series_index|
          segments(series).each do |points|
            next if points.length < 2

            @out << element('polyline',
                            'points' => points.map { |x, y| "#{x},#{y}" }.join(' '),
                            'fill' => 'none',
                            'stroke' => layout.color(series_index),
                            'stroke-width' => 2)
          end

          series.values.each_with_index do |value, category_index|
            next if value.nil?

            wrap_drill(series_index, category_index) do
              @out << element('circle',
                              { 'cx' => point_x(category_index, value),
                                'cy' => point_y(category_index, value),
                                'r' => 3,
                                'fill' => layout.color(series_index),
                                'stroke' => layout.stroke(series_index),
                                'stroke-width' => 1,
                                'data-rd-series' => series_index,
                                'data-rd-category' => category_index },
                              text_node('title', datum_title(series_index, category_index)))
            end
          end
        end
      end

      def segments(series)
        series.values.each_with_index
              .chunk_while { |(a, _), (b, _)| !a.nil? && !b.nil? }
              .map { |chunk| chunk.reject { |value, _| value.nil? } }
              .reject(&:empty?)
              .map { |chunk| chunk.map { |value, index| [point_x(index, value), point_y(index, value)] } }
      end

      def point_x(category_index, value)
        spec.horizontal? ? layout.value_to_px(value) : layout.band(category_index).center
      end

      def point_y(category_index, value)
        spec.horizontal? ? layout.band(category_index).center : layout.value_to_px(value)
      end

      # ------------------------------------------------------------------
      # Pie / doughnut
      # ------------------------------------------------------------------

      def pie_body
        geometry = layout.pie
        layout.slices.each do |index, from, to|
          wrap_drill(0, index) do
            @out << element('path',
                            { 'd' => arc_path(geometry, from, to),
                              'fill' => layout.color(index),
                              'stroke' => Palette::BACKGROUND,
                              'stroke-width' => 1,
                              'data-rd-category' => index },
                            text_node('title', slice_title(index, to - from)))
          end
        end
      end

      # A full circle cannot be an arc — start and end coincide and the path collapses
      # to nothing. One category is a legitimate pie, so it is drawn as a circle (or an
      # annulus) instead of silently disappearing.
      def arc_path(geometry, from, to)
        return full_ring(geometry) if (to - from) >= 0.999999

        outer = geometry['radius']
        inner = geometry['inner_radius']
        large = (to - from) > 0.5 ? 1 : 0
        sx, sy = polar(geometry, outer, from)
        ex, ey = polar(geometry, outer, to)

        if inner.zero?
          "M #{geometry['cx']} #{geometry['cy']} L #{sx} #{sy} " \
            "A #{outer} #{outer} 0 #{large} 1 #{ex} #{ey} Z"
        else
          isx, isy = polar(geometry, inner, to)
          iex, iey = polar(geometry, inner, from)
          "M #{sx} #{sy} A #{outer} #{outer} 0 #{large} 1 #{ex} #{ey} " \
            "L #{isx} #{isy} A #{inner} #{inner} 0 #{large} 0 #{iex} #{iey} Z"
        end
      end

      def full_ring(geometry)
        outer = geometry['radius']
        cx = geometry['cx']
        cy = geometry['cy']
        "M #{cx} #{(cy - outer).round(2)} " \
          "A #{outer} #{outer} 0 1 1 #{cx} #{(cy + outer).round(2)} " \
          "A #{outer} #{outer} 0 1 1 #{cx} #{(cy - outer).round(2)} Z"
      end

      # Twelve o'clock, clockwise — the direction every pie chart in every spreadsheet
      # goes, so a reader does not have to work out which way this one runs.
      def polar(geometry, radius, fraction)
        angle = (fraction * 2 * Math::PI) - (Math::PI / 2)
        [(geometry['cx'] + (radius * Math.cos(angle))).round(2),
         (geometry['cy'] + (radius * Math.sin(angle))).round(2)]
      end

      def slice_title(index, fraction)
        value = layout.pie_values[index]
        "#{spec.categories[index]}: #{layout.format_tick(value)} (#{(fraction * 100).round(1)}%)"
      end

      # ------------------------------------------------------------------
      # Progress
      # ------------------------------------------------------------------

      def progress_body
        fraction = layout.progress_fraction
        filled = (layout.plot.width * fraction).round(2)
        @out << element('rect', 'x' => layout.plot.x, 'y' => layout.plot.y,
                                'width' => layout.plot.width, 'height' => layout.plot.height,
                                'rx' => 4, 'fill' => Palette::PROGRESS_TRACK)
        wrap_drill(0, 0) do
          @out << element('rect',
                          { 'x' => layout.plot.x, 'y' => layout.plot.y,
                            'width' => filled, 'height' => layout.plot.height,
                            'rx' => 4, 'fill' => layout.color(0) },
                          text_node('title', datum_title(0, 0)))
        end
        # The number, in text, next to the bar. FR-76 again: a bar whose only encoding
        # is its length is a bar a greyscale printer flattens.
        @out << text_node('text', "#{(fraction * 100).round}%",
                          'x' => layout.plot.right,
                          'y' => (layout.plot.bottom + ChartLayout::LABEL_FONT + 4).round(2),
                          'text-anchor' => 'end',
                          'font-size' => ChartLayout::LABEL_FONT, 'fill' => Palette::TEXT)
      end

      # ------------------------------------------------------------------
      # Legend
      # ------------------------------------------------------------------

      def emit_legend
        box = layout.legend_box
        return if box.nil?

        entries = spec.family == :pie ? spec.categories : spec.series.map(&:label)
        cursor = box.x
        baseline = (box.y + ChartLayout::LEGEND_FONT).round(2)

        entries.each_with_index do |label, index|
          @out << element('rect', 'x' => cursor.round(2),
                                  'y' => (baseline - ChartLayout::LEGEND_SWATCH).round(2),
                                  'width' => ChartLayout::LEGEND_SWATCH,
                                  'height' => ChartLayout::LEGEND_SWATCH,
                                  'fill' => layout.color(index),
                                  'stroke' => layout.stroke(index), 'stroke-width' => 1)
          @out << text_node('text', label,
                            'x' => (cursor + ChartLayout::LEGEND_SWATCH + ChartLayout::LEGEND_GAP)
                                     .round(2),
                            'y' => baseline,
                            'font-size' => ChartLayout::LEGEND_FONT, 'fill' => Palette::TEXT)
          cursor += ChartLayout::LEGEND_SWATCH + ChartLayout::LEGEND_GAP +
                    layout.text_width(label, ChartLayout::LEGEND_FONT) + ChartLayout::LEGEND_ITEM_GAP
        end
      end

      # ------------------------------------------------------------------
      # Drill-through and markup helpers
      # ------------------------------------------------------------------

      # `<a xlink:href>` — §6's wording, and `xlink:` rather than plain `href` because
      # this SVG is read by PDF engines as well as browsers, and SVG 1.1's spelling is
      # the one both understand. Both are emitted: SVG 2 deprecated the xlink form and a
      # modern browser prefers `href`, so writing one of them would work in one place.
      def wrap_drill(series_index, category_index)
        url = spec.drill_url(series_index, category_index)
        return yield if url.nil?

        @out << tag('a', 'xlink:href' => url, 'href' => url, 'target' => '_blank')
        yield
        @out << '</a>'
      end

      def datum_title(series_index, category_index)
        series = spec.series[series_index]
        value = series&.values&.[](category_index)
        category = spec.categories[category_index]
        number = value.nil? ? 'no data' : layout.format_tick(value)
        return "#{category}: #{number}" if spec.series.length <= 1

        "#{series.label} — #{category}: #{number}"
      end

      def dom_id(suffix)
        "rrd-chart-#{spec.id}-#{suffix}"
      end

      # `attrs.each` in INSERTION ORDER, which Ruby guarantees for a Hash. That is what
      # makes the goldens diffable — an attribute order that depended on hashing would
      # change between runs and every golden would be noise.
      def tag(name, attrs = {})
        "<#{name}#{attributes(attrs)}>"
      end

      # NO BLOCK FORM, deliberately, and the reason is a Ruby parsing trap rather than a
      # style preference: `@out << element(...) do … end` attaches the block to `<<`,
      # not to `element`, so the inner content silently disappears and the element comes
      # out self-closing. An explicit third argument cannot be got wrong that way.
      # BOTH ARGUMENTS POSITIONAL, and neither is a keyword. A trailing bare hash is
      # collected into `attrs` only while this method declares no keyword parameter —
      # add one and `element('rect', 'x' => 0)` starts raising "unknown keywords: x",
      # which is how the first version of this file failed on its first run.
      def element(name, attrs = {}, inner = nil)
        return "<#{name}#{attributes(attrs)}/>" if inner.nil?

        "<#{name}#{attributes(attrs)}>#{inner}</#{name}>"
      end

      def text_node(name, content, attrs = {})
        "<#{name}#{attributes(attrs)}>#{xml(content)}</#{name}>"
      end

      def attributes(attrs)
        attrs.map { |key, value| %( #{key}="#{xml(value)}") }.join
      end

      # The five XML predefined entities, and no more. A `>` does not strictly need
      # escaping in content, and it is escaped anyway: a rule with an exception is a
      # rule somebody applies inconsistently.
      def xml(value)
        value.to_s
             .gsub('&', '&amp;')
             .gsub('<', '&lt;')
             .gsub('>', '&gt;')
             .gsub('"', '&quot;')
             .gsub("'", '&apos;')
      end
    end
  end
end
