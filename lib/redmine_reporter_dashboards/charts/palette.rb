# frozen_string_literal: true

module RedmineReporterDashboards
  module Charts
    # The colours, in ONE place, because two chart paths that disagree about them are two
    # charts.
    #
    # `technical-spec.md` §9b: "the chart palette shared with `ChartLayout` so an HTML
    # chart and its SVG twin are the same colours". This is that sharing made mechanical
    # — `ChartLayout` resolves every colour through here, and both emitters read the
    # layout. Neither emitter contains a hex code.
    #
    # --- WHY OKABE-ITO AND NOT A PRETTIER ONE ---
    #
    # It is the qualitative palette designed for the three common colour-vision
    # deficiencies (Okabe & Ito 2008, *Color Universal Design*), and it is the one with a
    # published rationale rather than a nice screenshot. Roughly 1 in 12 men cannot
    # distinguish a red bar from a green one, and a report is read by whoever it is sent
    # to.
    #
    # **It is not sufficient on its own, and FR-76 says so**: "meaning never carried by
    # colour alone". The palette is the floor. `SvgRenderer` puts the value in a `<title>`
    # on every element and a `<desc>` on the chart, and the legend prints the series name
    # next to its swatch. A colour-blind reader and a screen-reader user reach the same
    # numbers.
    #
    # --- STROKE IS NOT DECORATION ---
    #
    # Every fill has a darker STROKE, and it is what keeps the chart readable when the
    # fills cannot be told apart — printed in greyscale, or with yellow (`#F0E442`) next
    # to white. Two adjacent slices of similar luminance stay two slices because there is
    # a line between them.
    module Palette
      module_function

      # Okabe-Ito, minus its black: black reads as an axis, not as a series, and the
      # eighth colour is worth less than that confusion costs.
      SERIES = %w[
        #0072B2 #E69F00 #009E73 #CC79A7 #56B4E9 #D55E00 #F0E442
      ].freeze

      # The diverging ramp for `diverging_stacked_bar` — the LL-01 widget, where the
      # question is "how far either side of neutral", not "which category". A
      # qualitative palette answers the wrong question there: the reader needs to see
      # ORDER, and Okabe-Ito is deliberately unordered.
      #
      # Blue-to-vermillion through a neutral grey, five steps, endpoints taken from
      # SERIES so the two palettes look like one system. Grey rather than white in the
      # middle: a neutral bucket that renders as the page background disappears, and
      # "no opinion" is a finding.
      DIVERGING = %w[
        #0072B2 #56B4E9 #BDBDBD #E69F00 #D55E00
      ].freeze

      # Progress bars are one series against a track. Not from SERIES: a progress bar
      # sitting next to a bar chart would otherwise claim to be that chart's first
      # category.
      PROGRESS_FILL = '#0072B2'
      PROGRESS_TRACK = '#E4E4E4'

      # Chrome. Named rather than inlined at the seven places that draw a line, because
      # "the axis is a slightly different grey in the PDF" is the kind of difference
      # nobody can find later.
      AXIS = '#767676'
      GRID = '#DDDDDD'
      TEXT = '#333333'
      MUTED_TEXT = '#666666'
      BACKGROUND = '#FFFFFF'

      # Cycles. A chart with more series than colours repeats rather than running out —
      # and `ChartLayout` records a `series_palette_wrapped` degradation when it does, so
      # the reader is told that two identically-coloured series are two series (INV-4).
      def series(index)
        SERIES[index % SERIES.length]
      end

      def wrapped?(count)
        count > SERIES.length
      end

      # The diverging ramp stretched over `count` buckets. With five or fewer it is a
      # subset picked symmetrically around the neutral middle, so three buckets are
      # blue/grey/vermillion rather than the first three of the ramp — an ordered scale
      # whose middle is not the middle is worse than no scale.
      def diverging(count)
        return [] if count <= 0
        return [DIVERGING[2]] if count == 1
        return [DIVERGING[0], DIVERGING[4]] if count == 2

        last = DIVERGING.length - 1
        (0...count).map do |index|
          position = (index * last).fdiv(count - 1)
          DIVERGING[position.round]
        end
      end

      # A darker companion for the fill, computed rather than tabulated so a palette
      # entry cannot acquire a stroke that does not match it. 0.72 is dark enough to
      # separate two adjacent fills and light enough not to read as the axis.
      STROKE_FACTOR = 0.72

      def stroke(hex)
        r, g, b = rgb(hex)
        format('#%02X%02X%02X', (r * STROKE_FACTOR).round, (g * STROKE_FACTOR).round,
               (b * STROKE_FACTOR).round)
      end

      def rgb(hex)
        digits = hex.to_s.delete('#')
        raise ArgumentError, "#{hex.inspect} is not a #rrggbb colour" unless /\A\h{6}\z/.match?(digits)

        [digits[0, 2], digits[2, 2], digits[4, 2]].map { |pair| pair.to_i(16) }
      end
    end
  end
end
