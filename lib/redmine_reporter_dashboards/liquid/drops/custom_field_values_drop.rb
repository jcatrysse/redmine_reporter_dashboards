# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    module Drops
      # Bracket access to an issue's custom fields, BY ID or BY NAME:
      #
      #   {{ issue.custom_field_value[20] }}
      #   {% assign fid = 21 %}{{ issue.custom_field_value[fid] }}
      #   {{ issue.custom_field_value["Department"] }}
      #
      # This is the addon's existing `issue.custom_field_value` surface, carried forward
      # verbatim in spelling and in return type — the RAW stored value, not a drop — so
      # the templates that use it keep working when `issue_drop_patch.rb` goes away with
      # T-20. Behaviour compatibility is R-10's cheapest mitigation, and this accessor
      # is one of the few places where the addon already had the better idea: by-id
      # access is stable across a field rename, which the gem's by-name filter is not.
      #
      # BY NAME AS WELL, because a template author reading a report definition knows the
      # field's label and not its id, and the alternative is a magic number in every
      # template. Ids win on stability, names win on legibility, and the two do not
      # collide: a key that parses as an integer is an id, and everything else is a name.
      #
      # The values arrive from `Batch`, already restricted to the fields this actor may
      # see in this issue's project. A key naming a field the viewer may not see resolves
      # to nil — the same answer as a field that does not exist, which is the answer that
      # leaks nothing: distinguishing "hidden" from "absent" is itself a disclosure.
      class CustomFieldValuesDrop < ::Liquid::Drop
        # `values` is `{ field_id => value }`, `names` is `{ field_id => name }`.
        def initialize(values:, names:)
          @values = values
          @names = names
          super()
        end

        # Whatever sits between the brackets: an Integer literal, a String, or a
        # resolved Liquid variable.
        def liquid_method_missing(key)
          id = Integer(key.to_s, 10)
          @values[id]
        rescue ArgumentError, TypeError
          by_name(key.to_s)
        end

        def to_s
          "CustomFieldValues(#{@values.size})"
        end

        def inspect
          to_s
        end

        private

        # Case-sensitive, exactly as Redmine's field names are. A case-insensitive match
        # would resolve two distinct fields to one on an install that has both, and
        # which one it picked would depend on hash order.
        def by_name(name)
          id = @names.key(name)
          id && @values[id]
        end
      end
    end
  end
end
