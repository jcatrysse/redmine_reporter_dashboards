# frozen_string_literal: true

require_relative 'support'

module RedmineReporterDashboards
  module Liquid
    module Filters
      # `group_by`, `group_by_custom_field`, `where_custom_field` — the three that turn a
      # flat collection into the shape a table or a legend needs.
      #
      # --- `where` AND `sort_natural` ARE NOT HERE, AND THAT IS OQ-C's ANSWER ---
      #
      # §3.6 lists both among the filters to reimplement and asks, in `[OQ-C]`, which of
      # the set Liquid's own `StandardFilters` already provides. Measured on **4.0.4 and
      # 5.13.0**: both are provided by BOTH majors, both behave identically, and both
      # already work on the owned drops — `{{ issues | where: "done_ratio", 50 }}`
      # resolves through `Drop#[]` exactly as Liquid intends, because that is the same
      # boundary `Support.read` uses.
      #
      # So they are INHERITED. Reimplementing them would mean two behaviours to keep in
      # step with each other and with Liquid's documentation, and a divergence would be
      # invisible until a template disagreed with the docs. `spec_liquid/filters_spec.rb`
      # asserts the inherited pair still works on a drop, so "inherited" is a tested
      # claim rather than an assumption about a gem we do not control.
      #
      # `where_custom_field` IS here, because Liquid's `where` reads a PROPERTY and a
      # custom field is not one — it is a lookup through `custom_field_value`.
      module Grouping
        # `[{ "name" => …, "items" => [...], "size" => n }, …]`
        #
        # String keys, because Liquid looks a Hash up by string and a symbol-keyed hash
        # renders blank everywhere while raising nothing — the quietest way for a report
        # to come out empty.
        #
        # ORDER IS FIRST-APPEARANCE, not sorted. A caller that wants alphabetical says
        # so with `| sort`; a caller that grouped a scope the query already ordered would
        # be silently re-sorted by a filter that decided it knew better, and on a report
        # that is a wrong answer rather than a cosmetic one.
        def group_by(input, property = nil)
          buckets = Support.each(input).group_by { |item| label(Support.read(item, property)) }
          buckets.map { |name, items| { 'name' => name, 'items' => items, 'size' => items.length } }
        end

        def group_by_custom_field(input, field)
          buckets = Support.each(input).group_by { |item| label(custom_field_value(item, field)) }
          buckets.map { |name, items| { 'name' => name, 'items' => items, 'size' => items.length } }
        end

        # With a value, the rows whose field equals it. Without one, the rows where the
        # field is filled in at all — which is Liquid's own two-arity `where` convention,
        # kept so an author does not have to learn a second rule.
        def where_custom_field(input, field, value = nil)
          Support.each(input).select do |item|
            found = custom_field_value(item, field)
            value.nil? ? truthy?(found) : found.to_s == value.to_s
          end
        end

        private

        # A nil group is a REAL group and it is named, because "(none)" in a table is
        # information — 40 issues with no target version is the finding. Dropping them
        # would make the group sizes stop summing to the total, which is how a reader
        # discovers a filter lost rows.
        NONE = '(none)'

        def label(value)
          return NONE if value.nil?

          text = value.to_s
          text.empty? ? NONE : text
        end

        def truthy?(value)
          return false if value.nil?
          return false if value.respond_to?(:empty?) && value.empty?

          value != false
        end

        def custom_field_value(item, field)
          lookup = Support.read(item, 'custom_field_value')
          lookup.nil? ? nil : Support.read(lookup, field)
        end
      end
    end
  end
end
