# frozen_string_literal: true

module RedmineReporterDashboards
  module Reporting
    # T-31 / §Findings **S-14** — which hours this actor is actually allowed to see.
    #
    # --- WHY THIS EXISTS AND HAS NO EQUIVALENT ON THE ISSUE PATH ---
    #
    # `TimeEntry.visible_condition` (`redmine/app/models/time_entry.rb:82`) does not merely
    # check a permission. It branches on `Role#time_entries_visibility`, which has three
    # states, and the middle one is the defect:
    #
    #   'all'                        every entry in scope — correct
    #   'own'                        ONLY THIS ACTOR'S OWN HOURS, and the report looks fine
    #   no :view_time_entries        `1=0`, so nothing — fail-closed and correct
    #
    # An ordinary member opens the team's hours report, sees a total that is smaller and
    # completely believable, and has no way to know they are looking at their own
    # timesheet. `Issue.visible` has no analogous mode — it narrows by project and by
    # `Role#issues_visibility`, but there is no "your own issues only" that a whole-project
    # report silently collapses into — which is why no existing invariant or test covers
    # this and why it had to be written down before it could be built.
    #
    # The curator's decision (2026-08-08): fail closed on both narrowing states AND SAY SO
    # ON THE PAGE, following §9b.2's existing *"Preview of 50 of 1 284 issues"* pattern. Not
    # refusing the report — "my own hours" is a legitimate report, it simply has to admit
    # that is what it is. And no new permission: core's `:view_time_entries` already governs
    # the data, and a second permission over it would be a second answer to one question.
    #
    # --- THIS DOES NOT FILTER ANYTHING, AND MUST NOT START ---
    #
    # The narrowing is applied by `TimeEntry.visible`, in SQL, where it belongs. This
    # answers only *which* narrowing happened, so a view can name it. A second filter here
    # would be a second rule to keep in step with core's — the mistake §3.5 calls out.
    module TimeEntryVisibility
      STATES = %i[all own none].freeze

      module_function

      # `:all`, `:own` or `:none`. Mirrors the branch in `TimeEntry.visible_condition`
      # rather than reimplementing the decision — the roles consulted are the ones that
      # actually HOLD the permission, which is what `Project.allowed_to_condition` yields
      # to its block, and a role holding no `:view_time_entries` contributes nothing even
      # if its `time_entries_visibility` column says `all`.
      def state(user, project)
        return :none if user.nil? || project.nil?
        return :all if user.respond_to?(:admin?) && user.admin?

        permitted = permitted_roles(user, project)
        return :none if permitted.empty?
        return :all if permitted.any? { |role| visibility_of(role) == 'all' }
        return :own if permitted.any? { |role| visibility_of(role) == 'own' }

        :none
      end

      # True when this actor sees less than the whole project's hours for a reason that is
      # about their ROLE rather than about the report — which is the thing a reader has to
      # be told.
      def narrowed?(user, project)
        state(user, project) != :all
      end

      def permitted_roles(user, project)
        return [] unless user.respond_to?(:roles_for_project)

        user.roles_for_project(project).select do |role|
          role.respond_to?(:allowed_to?) && role.allowed_to?(:view_time_entries)
        end
      end

      # `respond_to?` guarded because the column is core's, not this plugin's, and a role
      # object that cannot answer is treated as the narrowest thing it could be rather
      # than as permission to show everything. Fail closed (INV-1/INV-3).
      def visibility_of(role)
        return nil unless role.respond_to?(:time_entries_visibility)

        role.time_entries_visibility
      end
    end
  end
end
