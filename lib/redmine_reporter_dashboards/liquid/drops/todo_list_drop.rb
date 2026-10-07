# frozen_string_literal: true

require 'erb'

require_relative 'record_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # One to-do list of redmine_issue_todo_lists2 that holds an issue, with the issue's
      # POSITION on it. Reached through `issue.todolists_with_positions.items`.
      #
      # --- THE SURFACE IS THE TODO PLUGIN'S OWN, ON PURPOSE ---
      #
      # That plugin shipped this drop for the RedmineUP Liquid layer (`TodoListDrop`:
      # `id project_id title description last_updated remove_closed_issues position`, with
      # `id` the LIST's id), and templates in the wild call those names. Jan decided on
      # 2026-10-07 that this plugin offers the to-do lists itself, so the names are kept
      # as they were and `url` is the one addition.
      #
      # The record is the `IssueTodoListItem` (the position lives there); the list and its
      # project are preloaded by `Batch#todo_lists`, so nothing here queries.
      class TodoListDrop < RecordDrop
        def id
          record.issue_todo_list_id
        end

        def project_id
          list.project_id
        end

        def title
          list.title
        end

        def description
          list.description
        end

        def last_updated
          in_actor_zone(list.last_updated)
        end

        def remove_closed_issues
          list.remove_closed_issues ? true : false
        end

        def position
          record.position
        end

        def url
          project = list.project
          project && absolute("/projects/#{ERB::Util.url_encode(project.identifier.to_s)}" \
                              "/issue_todo_lists/#{list.id}")
        end

        def to_s
          title.to_s
        end

        private

        def list
          record.issue_todo_list
        end
      end
    end
  end
end
