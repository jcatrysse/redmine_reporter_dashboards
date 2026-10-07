# frozen_string_literal: true

require_relative 'todo_list_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # `issue.todolists_with_positions`: the to-do lists the VIEWER may see that hold the
      # issue. `items` is the todo plugin's own name for the list (its CHANGELOG: "add method
      # `issue.todolists_with_positions.items`"), so `{% for l in
      # issue.todolists_with_positions.items %}` keeps working on the templates written for
      # it.
      #
      # Not a `CollectionDrop`: that one walks a scope. These rows are already loaded, for
      # the whole report at once, by `Batch#todo_lists`, so this is a plain list.
      #
      # When redmine_issue_todo_lists2 is not installed the list is empty rather than an
      # error: the plugin is optional, and a template that mentions to-do lists renders on
      # an install without them.
      class TodoListsDrop < ::Liquid::Drop
        def initialize(drops)
          @drops = drops
          super()
        end

        def items
          @drops
        end

        # So `{% for list in issue.todolists_with_positions %}` iterates too, rather than
        # rendering nothing without a word. Liquid keeps `each` off the template surface.
        def each(&block)
          @drops.each(&block)
        end

        def size
          @drops.size
        end

        def first
          @drops.first
        end

        def to_s
          @drops.map(&:to_s).join(', ')
        end

        def inspect
          "TodoListsDrop(#{size})"
        end
      end
    end
  end
end
