# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A list of drops that is ALREADY LOADED and already bounded: the journals, the
      # relations and the helpdesk messages of one issue, read for the whole report at once
      # by `Batch` and capped there (`BatchRelated::JOURNALS_PER_ISSUE` and friends).
      #
      # The surface is the base plugin's (`JournalsDrop`, `IssueRelationsDrop` in the
      # vendor gem): `all`, `visible`, `each`, `size`. `all` is safe HERE, unlike on an
      # issue collection, because there is nothing left to materialise: the rows are in
      # memory and their number is bounded. `visible` was the base plugin's filter on a
      # method its drops did not have; every row here is already one the actor may see, so
      # it answers the same list. `first` and `last` because a template asks for them.
      class ListDrop < ::Liquid::Drop
        def initialize(drops)
          @drops = drops.freeze
          super()
        end

        def all
          @drops
        end

        def visible
          @drops
        end

        def each(&block)
          @drops.each(&block)
        end

        def size
          @drops.size
        end

        def first
          @drops.first
        end

        def last
          @drops.last
        end

        def empty?
          @drops.empty?
        end

        def to_s
          @drops.map(&:to_s).join(', ')
        end

        def inspect
          "#{self.class.name.split('::').last}(#{size})"
        end
      end

      # `issue.journals`, the base plugin's name.
      class JournalsDrop < ListDrop; end

      # `issue.relations_from` / `issue.relations_to`, the base plugin's name.
      class IssueRelationsDrop < ListDrop; end
    end
  end
end
