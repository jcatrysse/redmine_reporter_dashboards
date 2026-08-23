# frozen_string_literal: true

require_relative 'support'

module RedmineReporterDashboards
  module Liquid
    module Filters
      # `custom_field`, `custom_field_by_id`, `custom_fields` — reading a Redmine custom
      # field off a drop.
      #
      #   {{ issue | custom_field: "Department" }}
      #   {{ issue | custom_field_by_id: 20 }}
      #   {% for cf in issue | custom_fields %}{{ cf.name }}: {{ cf }}{% endfor %}
      #
      # --- THE VISIBILITY IS NOT HERE, AND THAT IS THE POINT ---
      #
      # Every one of these reaches the value through `IssueDrop#custom_field_value` /
      # `#custom_field_values`, which read it from `Batch` — and `Batch` restricts to
      # `IssueCustomField.visible(actor)` and then applies Redmine's per-project
      # `visible_by?`. One filter, in the query, in one place.
      #
      # A second check here would be a second rule to keep in step, and the failure mode
      # of two visibility rules is that the laxer one wins. A field the actor may not see
      # therefore resolves to nil through all three of these — the same answer as a field
      # that does not exist, which is the answer that leaks nothing: distinguishing
      # "hidden" from "absent" is itself a disclosure.
      #
      # BY ID AND BY NAME BOTH, because they fail differently. An id survives a field
      # rename and a translation; a name is what an author reading a report definition
      # actually knows. Neither is right for every template, and the gem shipped only the
      # by-name form — which is why the addon grew `custom_field_value[20]` on its own.
      module CustomFields
        def custom_field(input, field_name)
          Support.custom_field_value(input, field_name)
        end

        # `Integer(...)` rather than `to_i`: `to_i` turns "Department" into 0 and then
        # looks up field zero, which resolves to nothing and looks like a missing value
        # rather than a mistake. An id argument that is not an id is an authoring error
        # and should read as one.
        def custom_field_by_id(input, field_id)
          id = Integer(field_id.to_s, 10)
          Support.custom_field_value(input, id)
        rescue ArgumentError, TypeError
          nil
        end

        # Every field the actor may see on this record, each carrying `id`, `name` and
        # its value — the list form, for a template that renders a definition table
        # rather than naming fields one at a time.
        def custom_fields(input)
          Support.read(input, 'custom_field_values') || []
        end

        # NO `private` SECTION. The lookup this module used to keep here was a second copy
        # of `Support.custom_field_value`, which `Grouping` also needed — so moving it out
        # removed a duplicate as well as a hazard. Liquid inspects a filter module's private
        # and protected methods too, and `Strainer.add_filter` refuses the whole module when
        # one of those names is already a registered filter (`colors.rb` has the render that
        # 500'd because of it).
      end
    end
  end
end
