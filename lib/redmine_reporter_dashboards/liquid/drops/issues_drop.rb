# frozen_string_literal: true

require_relative 'collection_drop'
require_relative 'issue_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A scope of issues. `{% for issue in issues %}`, `{{ issues.size }}`,
      # `{{ issues[42] }}`.
      #
      # --- THE PRELOAD LIST IS §3.4's M1, AND IT IS LOAD-BEARING ---
      #
      # Eight associations, chosen because they are what an issue-list template touches
      # on every row: the four named references, the target version, the two people and
      # the project. Without them a 500-row table is 4 000 queries and the report times
      # out; with them it is nine.
      #
      # `fixed_version: :project` rather than a bare `:fixed_version`, because
      # `VersionDrop#roadmap_url` and `#issues_url` are keyed on the project's
      # IDENTIFIER — a version whose project is not loaded puts the N+1 back one level
      # down, in the accessor least likely to be exercised by a test.
      #
      # What is NOT preloaded is as deliberate: `custom_values`, `attachments`,
      # `time_entries` and children are served by `Batch` on first touch, so a template
      # that never mentions them pays nothing. That split — associations eagerly,
      # everything else lazily — is why §3.4 says both mechanisms are required.
      class IssuesDrop < CollectionDrop
        PRELOADS = [:status, :tracker, :priority, :category, :assigned_to, :author,
                    :project, { fixed_version: :project }].freeze

        private

        def drop_class
          IssueDrop
        end
      end
    end
  end
end
