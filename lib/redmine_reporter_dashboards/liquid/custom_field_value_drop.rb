# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # Liquid drop exposed on the Reporter issue drop as `issue.custom_field_value`,
    # giving report templates access to ANY custom field on the issue BY ID:
    #
    #   {{ issue.custom_field_value[20] }}          # value of custom field 20
    #   {% assign fid = 21 %}{{ issue.custom_field_value[fid] }}
    #
    # Reporter/Redmineup already ship a by-NAME filter (`issue | custom_field: "Name"`);
    # this is the by-ID counterpart, which is stable across field renames/translations.
    #
    # Bracket access resolves through Liquid::Drop#[] -> liquid_method_missing(key),
    # so any id (integer literal, string, or a Liquid variable) works. The raw stored
    # value is returned (a String for text/numeric fields, an Array for multi-value
    # fields, nil when the field is unset on the issue). For numeric fields coerce in
    # the template, e.g. `{{ issue.custom_field_value[20] | times: 1.0 }}` (nil -> 0).
    class CustomFieldValueDrop < ::Liquid::Drop
      def initialize(issue)
        @issue = issue
      end

      # key is whatever sits between the brackets: an Integer literal (20), a String
      # ('20'), or a resolved Liquid variable. Issue#custom_field_value (Redmine's
      # Acts::Customizable) takes a field id and returns the stored value or nil.
      def liquid_method_missing(key)
        @issue.custom_field_value(key.to_i)
      end
    end
  end
end
