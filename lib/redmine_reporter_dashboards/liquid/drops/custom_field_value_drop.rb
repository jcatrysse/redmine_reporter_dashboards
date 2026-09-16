# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    module Drops
      # ONE custom field's value on one record: the field's id, its name, and what is
      # stored. `{{ cfv }}` prints the value, so a template that loops over
      # `issue.custom_field_values` and prints each one reads the way it always did.
      #
      # Not a `RecordDrop`: there is no ActiveRecord object here. `Batch` resolves the
      # values as a hash of scalars — that is the whole point of the batch key — and
      # instantiating a `CustomValue` per field per issue to wrap it would put back the
      # object churn the registry exists to avoid.
      #
      # --- WHAT IS NOT HERE: A FIELD THE ACTOR MAY NOT SEE ---
      #
      # This class does no visibility check, and that is deliberate rather than an
      # omission. The filter is in `Batch#custom_field_values`, which restricts to
      # `IssueCustomField.visible(actor)` and then applies Redmine's own per-project
      # `visible_by?`. One check, in the query, in one place. A second check here would
      # be a second rule to keep in step, and the failure mode of two visibility rules
      # is that the laxer one wins.
      #
      # The consequence is worth stating: an unentitled viewer sees no entry for the
      # field at all — not a blank value, not the field's NAME with an empty cell.
      # `test/unit/multi_actor_visibility_test.rb` makes that distinction explicit,
      # because a values-only assertion passes a leaky implementation.
      class CustomFieldValueDrop < ::Liquid::Drop
        attr_reader :id, :name, :value

        def initialize(id:, name:, value:)
          @id = id
          @name = name.to_s
          @value = value
          super()
        end

        # An Array for a `multiple` field, a String otherwise — the same shape Redmine's
        # own `custom_field_value` returns. Joined with ', ' when printed, because
        # `{{ cfv }}` on an Array would otherwise render Ruby's inspect form.
        def to_s
          value.is_a?(Array) ? value.join(', ') : value.to_s
        end

        def inspect
          "#<CustomFieldValueDrop #{name.inspect}=#{value.inspect}>"
        end
      end
    end
  end
end
