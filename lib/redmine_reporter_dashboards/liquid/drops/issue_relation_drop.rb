# frozen_string_literal: true

require_relative 'record_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # One relation of an issue, reached through `issue.relations_from` (this issue is
      # `issue_from`) or `issue.relations_to` (this issue is `issue_to`). The base plugin's
      # `IssueRelationDrop`: `relation_type delay issue_from issue_to`.
      #
      # Only relations whose OTHER issue the actor may see reach a template
      # (`BatchRelated#relations`). One side is the issue that listed the relation, handed
      # in as that same drop; the other comes preloaded.
      class IssueRelationDrop < RecordDrop
        def initialize(record, context:, issue_from:, issue_to:)
          @issue_from = issue_from
          @issue_to = issue_to
          super(record, context: context)
        end

        attr_reader :issue_from, :issue_to

        def relation_type
          record.relation_type
        end

        def delay
          record.delay
        end

        def to_s
          relation_type.to_s
        end
      end
    end
  end
end
