# frozen_string_literal: true

require_relative 'record_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A project. Reached as `{{ issue.project }}`.
      #
      # `project_name` is deliberately NOT here: §3.2 folds the base plugin's
      # `IssueDrop#project_name` into `project.name`, because two spellings of one fact
      # is how a template ends up printing them inconsistently. `IssueDrop` keeps the
      # old spelling as a documented alias so nothing breaks; the vocabulary this class
      # offers is the single one.
      class ProjectDrop < RecordDrop
        def name
          record.name.to_s
        end

        def identifier
          record.identifier
        end

        def description
          record.description
        end

        # Redmine's project status is an integer (1 active, 5 closed, 9 archived) and a
        # template printing `5` helps nobody. `STATUS_LABELS` is this plugin's own
        # mapping rather than a call into `Project::STATUS_*`, because those constants
        # moved between branches and the compat directory has a size budget.
        STATUS_LABELS = { 1 => 'active', 5 => 'closed', 9 => 'archived' }.freeze

        def status
          STATUS_LABELS[record.status] || record.status.to_s
        end

        # A project URL is keyed on the identifier, not the id — that is the form
        # Redmine itself links to, and the form that survives a copy-paste out of a PDF
        # into a browser.
        def url
          absolute("/projects/#{identifier}")
        end

        def to_s
          name
        end
      end
    end
  end
end
