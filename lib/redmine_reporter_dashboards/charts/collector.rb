# frozen_string_literal: true

require_relative 'chart_spec'

module RedmineReporterDashboards
  module Charts
    # WHAT THE DOCUMENT ASKED FOR, in document order — `RenderContext#charts`.
    #
    # `{% chart %}` appends here and emits a placeholder. Nothing draws until the render
    # has finished and the output binding is known, which is what lets one authoring act
    # produce two different documents (technical-spec.md §6).
    #
    # --- `javascript_required?` IS THE POINT OF COLLECTING AT ALL ---
    #
    # §5: "`:javascript`/`:readiness_expression` are essential **iff** `ChartCollector`
    # recorded a JS-path chart". Today that question is answered by
    # `PdfPolyfills.charts?` running a `<canvas>` regexp over the finished HTML
    # (`pdf_polyfills.rb:45-47`) — a string search deciding an engine capability, which
    # is wrong in both directions: `<canvas>` in a comment says yes, and a chart drawn
    # by something that is not a canvas says no.
    #
    # Here it is a FACT the renderer holds rather than a guess it makes. Every supported
    # family renders as server-side SVG with no JavaScript at all, so a document of six
    # bar charts needs no `:javascript` — which is what puts a JS-less engine back on
    # the table. One radar chart in the same document flips it, because that one falls
    # back to Chart.js.
    #
    # --- DUPLICATE IDS ARE REFUSED, NOT RENAMED ---
    #
    # The id is a DOM id and a `data-rd-chart` selector. Two charts sharing one means
    # `chart_boot.js` builds the second into the first's canvas and the reader sees one
    # chart where the template says two. Renaming it silently would hide an authoring
    # mistake that is one character away from being obvious; the second chart is
    # dropped and the degradation names the id.
    class Collector
      MAX_CHARTS = 40

      def initialize(limit: MAX_CHARTS)
        @limit = Integer(limit)
        @specs = []
        @degradations = []
        @ids = {}
      end

      attr_reader :specs, :degradations

      # Returns the placeholder id on success and nil when the chart was refused, so the
      # tag can decide what to emit without asking a second question.
      def record(spec)
        return refuse(:chart_duplicate_id, spec) if @ids.key?(spec.id)
        return refuse(:chart_limit_exceeded, spec) if @specs.length >= @limit

        @ids[spec.id] = true
        @specs << spec
        note_spec_degradations(spec)
        spec.id
      end

      def [](id)
        @specs.find { |spec| spec.id == id }
      end

      def any?
        @specs.any?
      end

      def length
        @specs.length
      end

      # True when at least one recorded chart cannot be drawn as SVG. See the class
      # comment: this is the fact `Render::Capabilities.negotiate` needs, and it is a
      # fact rather than a regexp over the finished document.
      def javascript_required?
        @specs.any? { |spec| !spec.supported? }
      end

      # The capabilities this document's charts make ESSENTIAL. Empty for an all-SVG
      # document, which is the case worth having.
      def required_capabilities
        javascript_required? ? %i[javascript readiness_expression].freeze : [].freeze
      end

      def to_h
        { 'count' => @specs.length,
          'javascript_required' => javascript_required?,
          'ids' => @specs.map(&:id) }
      end

      private

      def refuse(code, spec)
        @degradations << degradation(code, refusal_detail(code, spec), 'id' => spec.id)
        nil
      end

      def refusal_detail(code, spec)
        case code
        when :chart_duplicate_id
          "two charts share the id #{spec.id.inspect}; the second was not drawn — an id is a " \
            'DOM id, and renaming it here would hide the mistake rather than fix it'
        else
          "this document already has #{@limit} charts; #{spec.id.inspect} and any after it were " \
            'not drawn'
        end
      end

      # An unsupported type is NOT a refusal — the chart still draws, through Chart.js,
      # and the degradation is what tells the reader (and the engine negotiation) that
      # this document now needs JavaScript. §6: "anything else → `Degradation(
      # :chart_type_unsupported)` and the Chart.js path, which re-adds `:javascript` as
      # essential."
      def note_spec_degradations(spec)
        unless spec.supported?
          @degradations << degradation(
            :chart_type_unsupported,
            "#{spec.unsupported_type} is not one of the six families this plugin draws " \
            "(#{ChartSpec::FAMILIES.join(', ')}), so it falls back to Chart.js — which means this " \
            'document needs an engine that runs JavaScript',
            'id' => spec.id, 'type' => spec.unsupported_type.to_s
          )
        end

        if spec.truncated_categories
          @degradations << degradation(
            :chart_categories_truncated,
            "only the first #{ChartSpec::MAX_CATEGORIES} categories were drawn",
            'id' => spec.id
          )
        end

        return unless spec.truncated_series

        @degradations << degradation(
          :chart_series_truncated,
          "only the first #{ChartSpec::MAX_SERIES} series were drawn",
          'id' => spec.id
        )
      end

      # A plain Hash, not a `Liquid::Diagnostics::Degradation` and not a
      # `Render::Degradation`. This object is named by both layers and must belong to
      # neither vocabulary; the tag converts these into the Liquid layer's type on the
      # way out, which is one line and keeps the two failure vocabularies apart for the
      # reason `TemplateRenderer` states about its own `Failure`.
      def degradation(code, detail, data)
        { code: code, detail: detail, data: data }.freeze
      end
    end
  end
end
