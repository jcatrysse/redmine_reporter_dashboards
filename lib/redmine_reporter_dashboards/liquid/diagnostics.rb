# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # Where a render says "you did not get everything, and here is what was missing".
    #
    # INV-4: a degradation is VISIBLE, never silent. The base plugin's habit is the
    # opposite — a collection that hit a limit simply stops, a custom field the viewer
    # may not see simply resolves to blank — and the reader of the report has no way to
    # tell a small answer from a truncated one.
    #
    # --- WHY THIS IS NOT `Render::Degradation` ---
    #
    # `script/gates/layer_purity.sh` forbids `liquid/**` from naming the render layer,
    # and the reason behind the gate is the better argument, the same one
    # `TemplateRenderer` states for owning its own `Failure`: these are different
    # vocabularies. "The collection was truncated at 5 000 issues" and "the browser
    # could not fetch a font" are fixed by different people. A caller that cannot tell
    # them apart tells a template author their PDF engine is broken.
    #
    # --- WHY IT DEDUPLICATES ---
    #
    # A degradation raised inside a 5 000-iteration loop is raised 5 000 times. A list
    # with 5 000 identical entries is a list nobody reads, and a log with 5 000
    # identical lines is an outage in the logging system. So a code+key pair is recorded
    # ONCE, with a count, and logged once. The count is the honest part: it says how
    # often the condition was hit without pretending each hit was a separate finding.
    class Diagnostics
      # A single thing that was lost, and why. A value object — `count` is the one
      # thing that moves, and it moves through `Diagnostics#degrade` rather than
      # through a setter on the record.
      class Degradation
        attr_reader :code, :detail, :data, :count

        def initialize(code:, detail: nil, data: {}, count: 1)
          @code = code.to_sym
          @detail = detail.to_s.freeze
          @data = data.transform_keys(&:to_s).freeze
          @count = count
        end

        # `key` is what makes two occurrences THE SAME degradation. The code alone
        # would fold "custom field 20 is not visible" into "custom field 31 is not
        # visible"; the data alone would separate them from a second render of the
        # same template. Both, and nothing else — `detail` is prose and must not
        # affect identity, or a message that interpolates an id splits the bucket it
        # was meant to fill.
        def key
          [code, data]
        end

        def to_h
          { 'code' => code.to_s, 'detail' => detail, 'data' => data,
            'count' => count }.freeze
        end

        def to_s
          suffix = count > 1 ? " (#{count}x)" : ''
          detail.empty? ? "#{code}#{suffix}" : "#{code}: #{detail}#{suffix}"
        end

        # Not public API for templates — `Diagnostics` owns the counter, so that
        # incrementing it is something only the collector can do.
        def increment!
          @count += 1
          self
        end
      end

      # A hard ceiling on how many DISTINCT degradations one render will record.
      # Without it a template that degrades on a per-issue key (an unresolvable custom
      # field id built from the issue's own subject, say) turns this collector into the
      # unbounded output INV-4 exists to prevent. Past the ceiling the collector records
      # one final `:diagnostics_truncated` and drops the rest — which is itself visible.
      MAX_DISTINCT = 100

      attr_reader :logger

      # `logger` is a constructor port, not `Rails.logger` — mechanism E5, the same
      # reason `TemplateRenderer` and `Render::Renderer` take one.
      def initialize(logger: nil, correlation_id: nil)
        @logger = logger
        @correlation_id = correlation_id
        @records = {}
        @truncated = false
      end

      # THE ONE ENTRY POINT. Returns the Degradation so a caller can name it in a log
      # line of its own without looking it up again.
      def degrade(code, detail: nil, **data)
        record = Degradation.new(code: code, detail: detail, data: data)
        existing = @records[record.key]
        return existing.increment! if existing

        return truncate! if @records.size >= MAX_DISTINCT

        @records[record.key] = record
        warn_line("[liquid] degradation #{record} (correlation_id=#{@correlation_id})")
        record
      end

      # Insertion-ordered, which is the order they happened in — a reader following a
      # report's degradations is reconstructing a sequence, not reading a set.
      def degradations
        @records.values.freeze
      end

      def any?
        !@records.empty?
      end

      def include?(code)
        @records.each_key.any? { |(recorded, _data)| recorded == code.to_sym }
      end

      def to_a
        degradations.map(&:to_h)
      end

      private

      def truncate!
        return @truncation if @truncated

        @truncated = true
        @truncation = Degradation.new(
          code: :diagnostics_truncated,
          detail: "more than #{MAX_DISTINCT} distinct degradations; the rest were dropped"
        )
        @records[@truncation.key] = @truncation
        warn_line("[liquid] degradation #{@truncation} (correlation_id=#{@correlation_id})")
        @truncation
      end

      def warn_line(line)
        @logger.warn(line) if @logger.respond_to?(:warn)
      end
    end
  end
end
