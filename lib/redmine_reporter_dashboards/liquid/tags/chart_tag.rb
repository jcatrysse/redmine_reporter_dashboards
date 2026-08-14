# frozen_string_literal: true

require_relative '../execution_policy'
require_relative '../render_context'
require_relative '../tag_params'
require_relative '../../charts'

module RedmineReporterDashboards
  module Liquid
    module Tags
      # `{% chart %}` — ONE AUTHORING ACT, AND NO MARKUP.
      #
      # technical-spec.md §6: "The tag **emits no markup**: it appends a `ChartSpec` to
      # `RenderContext#charts` and a placeholder `<div data-rd-chart="v1">`. At the end
      # of the render the **output binding** decides."
      #
      # --- WHY A TAG THAT DRAWS NOTHING IS THE WHOLE DESIGN ---
      #
      # Every chart in this plugin's history has been drawn by the template: the author
      # writes a `<canvas>`, a `<script>`, a Chart.js config, a data array built by
      # string concatenation, a `window.status` handshake and a `responsive: false` that
      # exists only because of one PDF engine. Six things, five of which are facts about
      # the RENDERER and none of which an author should have to know (FR-34, gate G3).
      # And the data array is the escaping defect: measured in
      # `reference/verification-liquid-js-escaping.md`, a value ending in a backslash
      # kills the whole `<script>` block.
      #
      # A tag that emits no markup cannot have any of those problems. It records what
      # was asked for; `ChartjsEmitter` or `SvgRenderer` answers it later, knowing which
      # document is being produced.
      #
      # --- WHAT THE AUTHOR MAY NOT SAY ---
      #
      # `responsive`, `animation`, `devicePixelRatio`, the canvas element, the readiness
      # handshake, the Chart.js version, the tick algorithm. Not "should not" —
      # **cannot**: there is no parameter for any of them, because each is a property of
      # the engine or of the shared layout, and an author who can override one can make
      # the HTML and the PDF disagree. That is what §6 means by emitting `responsive`
      # from the engine's capabilities rather than from the author's choice.
      #
      # --- THE PLACEHOLDER IS EMITTED EVEN WHEN THE CHART IS REFUSED ---
      #
      # A duplicate id or a chart past the per-document cap produces a placeholder
      # carrying `data-rd-chart-refused`, not nothing. INV-4: a reader looking at a gap
      # in a report cannot tell a refused chart from a chart the author never wrote, and
      # the degradation list is downstream of a reader who has already been confused.
      class ChartTag < ::Liquid::Tag

        # `from:` reads a variable the aggregation tags assigned. Those results are
        # String-keyed Hashes (`buckets`, `labels`, `rows`, `matrix`, …), which is what
        # `SeriesReader` knows how to turn into categories and series.
        DEFAULT_FROM = 'stats'

        def initialize(tag_name, markup, tokens)
          super
          @raw_params = TagParams.parse(markup)
        end

        def render(context)
          Budget.from(context).check!('chart')

          render_context = RenderContext.from(context)
          return placeholder(chart_id, refused: 'no_render_context') if render_context.nil?

          spec = build_spec(context)
          recorded = render_context.charts.record(spec)
          publish_degradations(render_context)

          return placeholder(spec.id, refused: 'not_recorded') if recorded.nil?

          placeholder(spec.id)
        rescue ChartSpecError => e
          # An authoring mistake — a bad id, a `from:` that is not a result hash. It is
          # named in the diagnostics and the document keeps rendering; a template with
          # one broken chart out of six is still five charts of report.
          log_and_degrade(context, e)
          placeholder(chart_id_or_fallback, refused: 'invalid')
        rescue StandardError => e
          # NOT `rescue Exception` (CLAUDE.md §5). And the error never becomes the
          # document (INV-5): the placeholder says a chart was refused, it does not
          # print why into the report.
          log_and_degrade(context, e)
          placeholder(chart_id_or_fallback, refused: 'error')
        end

        # Raised for anything the author can fix. Distinct from a bug in here, because
        # the two are read by different people.
        class ChartSpecError < StandardError; end

        private

        # ------------------------------------------------------------------
        # The placeholder
        # ------------------------------------------------------------------

        # The ONLY markup this tag produces. No interpolation of a value into script or
        # attribute position beyond the id, which `ChartSpec` has already restricted to
        # `[A-Za-z][A-Za-z0-9_-]*` — restricted rather than escaped, so there is nothing
        # to get wrong later.
        def placeholder(id, refused: nil)
          attrs = %(data-rd-chart="#{id}")
          attrs += %( data-rd-chart-refused="#{refused}") if refused
          %(<div class="rrd-chart-placeholder" #{attrs}></div>)
        end

        def chart_id
          @raw_params['id'].to_s
        end

        def chart_id_or_fallback
          Charts::ChartSpec::ID_PATTERN.match?(chart_id) ? chart_id : 'chart'
        end

        # ------------------------------------------------------------------
        # Building the spec
        # ------------------------------------------------------------------

        def build_spec(context)
          source = resolve_from(context)
          reader = SeriesReader.new(source, @raw_params, context)

          Charts::ChartSpec.new(
            id: chart_id.empty? ? raise(ChartSpecError, 'a chart needs an id:') : chart_id,
            type: @raw_params.fetch('type', 'bar'),
            orientation: @raw_params.fetch('orientation', 'vertical'),
            categories: reader.categories,
            series: reader.series,
            title: str_param('title', context),
            x_title: str_param('x_title', context),
            y_title: str_param('y_title', context),
            width: int_param('width', Charts::ChartSpec::DEFAULT_WIDTH),
            height: int_param('height', Charts::ChartSpec::DEFAULT_HEIGHT),
            drill_urls: reader.drill_urls,
            legend: bool_param('legend', nil)
          )
        rescue Charts::ChartSpec::InvalidSpec => e
          raise ChartSpecError, e.message
        end

        def resolve_from(context)
          name = @raw_params.fetch('from', DEFAULT_FROM)
          value = context[name]
          raise ChartSpecError, "chart from: #{name} resolved to nothing" if value.nil?

          value
        end

        # Every degradation the collector recorded, translated into the Liquid layer's
        # vocabulary. The collector belongs to neither layer and speaks in plain Hashes
        # for that reason; this is the one line that converts, and it is here rather
        # than in the collector so `Diagnostics` stays a Liquid-layer type.
        def publish_degradations(render_context)
          diagnostics = render_context.diagnostics
          return if diagnostics.nil?

          render_context.charts.degradations.each do |entry|
            diagnostics.degrade(entry[:code], detail: entry[:detail], data: entry[:data])
          end
        end

        def log_and_degrade(context, error)
          render_context = RenderContext.from(context)
          render_context&.diagnostics&.degrade(:chart_refused, detail: error.message)
          return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

          ::Rails.logger.warn("[chart] #{error.class}: #{error.message}")
        end

        # ------------------------------------------------------------------
        # Parameters
        # ------------------------------------------------------------------

        # QUOTED MEANS LITERAL, BARE MEANS A VARIABLE — decided once, in `TagParams`.
        # `nil` rather than `''` for an absent parameter, because `ChartSpec` treats "no
        # title" and "an empty title" differently.
        def str_param(name, context)
          TagParams.resolve(@raw_params[name], context, default: nil)
        end

        def int_param(name, fallback)
          raw = @raw_params[name]
          return fallback if raw.nil? || raw.empty?

          Integer(raw)
        rescue ArgumentError, TypeError
          fallback
        end

        # nil is a real answer: `ChartSpec` shows the legend when there is more than one
        # series unless the author said otherwise, and "the author said nothing" has to
        # be distinguishable from "the author said false".
        def bool_param(name, fallback)
          raw = @raw_params[name]
          return fallback if raw.nil? || raw.empty?

          %w[true yes 1].include?(raw.downcase)
        end
      end

      # HOW AN AGGREGATION RESULT BECOMES A CHART.
      #
      # `{% sql_aggregate %}` and `{% version_rollup %}` assign String-keyed Hashes, and
      # their shapes differ by mode: a breakdown has `buckets`, a crosstab has `rows`
      # plus `series` plus `matrix`, a time series has `labels` plus named arrays. This
      # reads all three, because the alternative is a template author reshaping data in
      # Liquid — which is the O(rows) loop the aggregator exists to delete.
      #
      # `x:` and `y:` name the KEYS to read, so an author with a shape this does not
      # recognise can still point at two columns.
      class SeriesReader
        def initialize(source, params, context)
          @source = source
          @params = params
          @context = context
        end

        def categories
          @categories ||= resolve[:categories]
        end

        def series
          @series ||= resolve[:series]
        end

        def drill_urls
          @drill_urls ||= resolve[:drill_urls]
        end

        private

        def resolve
          @resolve ||=
            if crosstab?
              from_crosstab
            elsif buckets?
              from_buckets
            elsif time_series?
              from_time_series
            else
              raise ChartTag::ChartSpecError,
                    'chart from: is not an aggregation result — expected buckets, rows or labels. ' \
                    'Pass the variable a {% sql_aggregate %} or {% version_rollup %} assigned.'
            end
        end

        def hash
          @source.respond_to?(:[]) ? @source : {}
        end

        def crosstab?
          hash['rows'].is_a?(Array) && hash['series'].is_a?(Array)
        end

        def buckets?
          hash['buckets'].is_a?(Array)
        end

        def time_series?
          hash['labels'].is_a?(Array)
        end

        # A crosstab is already a category × series matrix, which is the shape a stacked
        # bar wants. `matrix` is rows × series, so it transposes to series × categories.
        def from_crosstab
          rows = hash['rows']
          names = hash['series'].map(&:to_s)
          matrix = hash['matrix'] || rows.map { |row| row['counts'] || [] }

          { categories: rows.map { |row| row['label'].to_s },
            series: names.each_with_index.map do |name, index|
              { label: name, values: matrix.map { |row| row[index] } }
            end,
            drill_urls: transpose_cell_urls(hash['cell_urls'], names.length) }
        end

        # The commonest case by far: one bucket per category, one number each.
        # `value_key` lets a template chart `count`, or a measure the aggregator put in
        # `value`, without reshaping anything.
        def from_buckets
          buckets = hash['buckets']
          value_key = @params.fetch('y', 'count')
          label_key = @params.fetch('x', 'label')

          { categories: buckets.map { |bucket| bucket[label_key].to_s },
            series: [{ label: @params.fetch('series_label', value_key),
                       values: buckets.map { |bucket| bucket[value_key] } }],
            drill_urls: bucket_urls(buckets) }
        end

        # A time series has several parallel arrays and the author picks which. Named
        # rather than "all of them": `total` and `created` on one axis is usually right
        # and `open_now` alongside them usually is not, and guessing produces a chart
        # nobody asked for.
        def from_time_series
          keys = @params.fetch('y', 'created,closed').split(/[;,]/).map(&:strip).reject(&:empty?)
          { categories: hash['labels'].map(&:to_s),
            series: keys.map { |key| { label: key, values: Array(hash[key]) } },
            drill_urls: nil }
        end

        def bucket_urls(buckets)
          urls = buckets.map { |bucket| bucket['url'] }
          return nil if urls.compact.empty?

          [urls]
        end

        # `cell_urls` is rows × series; the chart wants series × categories.
        def transpose_cell_urls(cell_urls, series_count)
          return nil if cell_urls.nil? || cell_urls.empty?

          (0...series_count).map { |index| cell_urls.map { |row| row[index] } }
        end
      end
    end
  end
end
