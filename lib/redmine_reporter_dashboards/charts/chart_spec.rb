# frozen_string_literal: true

require_relative 'palette'

module RedmineReporterDashboards
  module Charts
    # WHAT THE AUTHOR ASKED FOR — validated, frozen, and containing no markup at all.
    #
    # `{% chart %}` emits no `<canvas>`, no `<svg>` and no `<script>`. It records one of
    # these and drops a `<div data-rd-chart="id">` placeholder, and the OUTPUT BINDING
    # decides later what fills it. That is technical-spec.md §6's hybrid split, and the
    # reason it is worth the indirection is the escaping defect: as long as a tag emits
    # markup, some version of that markup interpolates a value into JavaScript, and the
    # `verification-liquid-js-escaping.md` finding comes back. A tag that emits no markup
    # cannot have that bug.
    #
    # --- WHY THIS LIVES IN `charts/` AND NOT IN `render/charts/` ---
    #
    # §1.1's tree puts it under `render/`. Mechanism E3 (`script/gates/layer_purity.sh`)
    # forbids `liquid/**` from naming `…Dashboards::Render`, and §3.5 puts `charts` on
    # `RenderContext`, which IS the Liquid layer — so the tag that has to build one of
    # these could not name it there. The two halves of the spec disagree; the mechanism
    # wins over the directory listing, and `implementation-plan.md` §Findings F-13
    # records it rather than resolving it silently. Nothing else changes: this file names
    # neither layer, so both may name it.
    #
    # --- SIX TYPES, AND THE SEVENTH IS A DEGRADATION ---
    #
    # §6 names six families from measured use. Anything else is not an error — it is
    # `Degradation(:chart_type_unsupported)` plus the Chart.js path, which re-adds
    # `:javascript` as an essential capability. `supported?` is the whole of that
    # decision, asked once here rather than re-derived by each emitter.
    class ChartSpec
      # The six families. `doughnut` is `pie` with a hole, not a seventh family — it
      # shares every scale, label and legend decision, and splitting it would mean two
      # code paths that must agree about all of them.
      TYPES = %i[bar stacked_bar diverging_stacked_bar line pie doughnut progress].freeze
      FAMILIES = %i[bar stacked_bar diverging_stacked_bar line pie progress].freeze

      ORIENTATIONS = %i[vertical horizontal].freeze

      # Bounds. Not style preferences — an unbounded chart is an unbounded document, and
      # `{% chart %}` is reachable from a template an author edits in a browser.
      MAX_SERIES = 24
      MAX_CATEGORIES = 200
      MIN_SIZE = 40
      MAX_SIZE = 4000
      DEFAULT_WIDTH = 640
      DEFAULT_HEIGHT = 360

      # A DOM id, and it ends up in an attribute selector and in JSON. Restricted rather
      # than escaped: an id is authored, short, and there is no legitimate reason for one
      # to contain a quote. Escaping would work; refusing is simpler to prove.
      ID_PATTERN = /\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/

      class InvalidSpec < ArgumentError; end

      # One series: a name and its numbers, one per category.
      #
      # `values` may contain nil — a category a series has no number for. nil is not 0:
      # "no data" and "zero" are different findings, and a line chart draws a gap for one
      # and a point on the axis for the other.
      class Series
        attr_reader :label, :values, :color

        def initialize(label:, values:, color: nil)
          @label = label.to_s
          @values = Array(values).map { |value| value.nil? ? nil : Float(value) }.freeze
          @color = color&.to_s
          freeze
        end

        def max
          values.compact.max
        end

        def min
          values.compact.min
        end

        def to_h
          { 'label' => label, 'values' => values, 'color' => color }
        end
      end

      attr_reader :id, :type, :orientation, :categories, :series, :title, :x_title,
                  :y_title, :width, :height, :drill_urls, :legend, :unsupported_type,
                  :truncated_categories, :truncated_series

      # `unsupported_type` is carried rather than raised. A template asking for a radar
      # chart gets a Chart.js radar chart and a recorded degradation; refusing would turn
      # one unfamiliar type into a failed report.
      def initialize(id:, type:, categories:, series:, orientation: :vertical,
                     title: nil, x_title: nil, y_title: nil,
                     width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT,
                     drill_urls: nil, legend: nil)
        @id = validate_id(id)
        @type, @unsupported_type = resolve_type(type)
        @orientation = ORIENTATIONS.include?(orientation.to_s.to_sym) ? orientation.to_s.to_sym : :vertical

        all_categories = Array(categories).map(&:to_s)
        @truncated_categories = all_categories.length > MAX_CATEGORIES
        @categories = all_categories.first(MAX_CATEGORIES).freeze

        all_series = Array(series)
        @truncated_series = all_series.length > MAX_SERIES
        @series = all_series.first(MAX_SERIES).map { |one| normalise_series(one) }.freeze

        @title = presence(title)
        @x_title = presence(x_title)
        @y_title = presence(y_title)
        @width = clamp_size(width, DEFAULT_WIDTH)
        @height = clamp_size(height, DEFAULT_HEIGHT)
        @drill_urls = normalise_drill(drill_urls)
        @legend = legend.nil? ? default_legend : !!legend
        freeze
      end

      # THE QUESTION BOTH EMITTERS ASK. A supported family can be drawn as SVG with no
      # JavaScript; anything else needs Chart.js and therefore needs `:javascript` to be
      # an essential capability for this document.
      def supported?
        unsupported_type.nil?
      end

      def family
        return :pie if type == :doughnut

        type
      end

      def stacked?
        %i[stacked_bar diverging_stacked_bar].include?(type)
      end

      def horizontal?
        orientation == :horizontal
      end

      # A chart with no categories or no numbers is not an error and not a blank canvas
      # either: `SvgRenderer` draws the frame and an "no data" label, so the reader sees
      # a chart that is empty rather than a hole where a chart should be.
      def empty?
        categories.empty? || series.empty? || series.all? { |one| one.values.compact.empty? }
      end

      # Every number, once. Used by the scale, so nil holes never reach it.
      def values
        series.flat_map(&:values).compact
      end

      def drill_url(series_index, category_index)
        return nil if drill_urls.nil?

        row = drill_urls[series_index]
        row && row[category_index]
      end

      def drill?
        !drill_urls.nil?
      end

      def to_h
        { 'id' => id, 'type' => type.to_s, 'orientation' => orientation.to_s,
          'categories' => categories, 'series' => series.map(&:to_h),
          'title' => title, 'x_title' => x_title, 'y_title' => y_title,
          'width' => width, 'height' => height, 'legend' => legend }
      end

      private

      # A PIE'S LEGEND KEYS ON CATEGORIES, NOT SERIES, and this defaulted wrongly on its
      # first run: a pie has ONE series, so "show the legend when there is more than one
      # series" hid it, and the chart came out as three unlabelled coloured wedges —
      # meaning carried by colour alone, which is exactly what FR-76 forbids. Caught by
      # rendering one and looking at it.
      #
      # A progress bar has one number and prints it as text, so it needs no legend at
      # all; giving it one would label a single blue bar "blue".
      def default_legend
        return @categories.length > 1 if family == :pie
        return false if @type == :progress

        @series.length > 1
      end

      def validate_id(value)
        candidate = value.to_s
        return candidate if ID_PATTERN.match?(candidate)

        raise InvalidSpec,
              "chart id #{value.inspect} must match #{ID_PATTERN.source} — it becomes a DOM " \
              'id and a JSON key, and an id that needs escaping is an id worth refusing'
      end

      # Returns [drawn_type, unsupported_original]. An unknown type still draws — as a
      # bar, which is the least misleading default — and carries the original name so the
      # degradation can say what was asked for.
      def resolve_type(value)
        candidate = value.to_s.downcase.to_sym
        return [candidate, nil] if TYPES.include?(candidate)

        [:bar, candidate]
      end

      def normalise_series(one)
        return one if one.is_a?(Series)
        return Series.new(**symbolize(one)) if one.is_a?(Hash)

        raise InvalidSpec, "a series must be a Series or a Hash, got #{one.class}"
      end

      def symbolize(hash)
        hash.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
             .slice(:label, :values, :color)
      end

      # `drill_urls[series_index][category_index]`, aligned with `series` and
      # `categories`. Ragged input is padded with nil rather than rejected: the
      # aggregator emits a URL per bucket and a chart may have fewer buckets than
      # series slots, and a missing URL means "no link here", never an exception in
      # the middle of a render.
      def normalise_drill(urls)
        return nil if urls.nil?

        Array(urls).map { |row| Array(row).map { |url| presence(url) }.freeze }.freeze
      end

      def presence(value)
        text = value.to_s
        text.empty? ? nil : text
      end

      def clamp_size(value, fallback)
        number = Integer(value)
        return fallback if number <= 0

        number.clamp(MIN_SIZE, MAX_SIZE)
      rescue TypeError, ArgumentError
        fallback
      end
    end
  end
end
