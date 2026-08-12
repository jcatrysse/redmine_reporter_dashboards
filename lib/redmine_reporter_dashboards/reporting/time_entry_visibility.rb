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

        # THE MODULE GATE COMES BEFORE THE ADMIN FLAG, and the first version had no module
        # gate at all. `Project.allowed_to_condition` (`redmine/app/models/project.rb:195`)
        # adds an `enabled_modules` EXISTS clause for EVERYONE, administrators included, so
        # with time tracking switched off `TimeEntry.visible` returns nothing while this
        # answered `:all` — an empty hours report with no notice and no explanation. Measured
        # by an independent review: `module DISABLED (admin): state=all visible=0`.
        #
        # `require_reports_module` does not cover it: that checks
        # `reporter_dashboards_reports`, which is this plugin's module, not core's
        # `time_tracking`.
        return :none unless time_tracking_enabled?(project)
        return :all if user.respond_to?(:admin?) && user.admin?

        permitted = permitted_roles(user, project)
        return :none if permitted.empty?
        return :all if permitted.any? { |role| visibility_of(role) == 'all' }

        # `own` NEEDS A LOGGED-IN USER, because core's own branch does: `visible_condition`
        # reads `role.time_entries_visibility == 'own' && user.id && user.logged?` and falls
        # through to `1=0` otherwise. Anonymous with an `own` role therefore sees NOTHING,
        # and announcing "only your own spent time" over an empty report would be a notice
        # that is simply false. Low reachability — the role form hides the column for
        # Anonymous — but `Role#safe_attributes` still permits it, so it is reachable.
        if permitted.any? { |role| visibility_of(role) == 'own' }
          return logged_in?(user) ? :own : :none
        end

        :none
      end

      # True when this actor sees less than the whole project's hours for a reason that is
      # about their ROLE rather than about the report — which is the thing a reader has to
      # be told.
      def narrowed?(user, project)
        state(user, project) != :all
      end

      # `respond_to?` guarded like everything else core-owned here: a project object that
      # cannot answer is treated as the narrowest thing it could be.
      def time_tracking_enabled?(project)
        return false unless project.respond_to?(:module_enabled?)

        project.module_enabled?(:time_tracking) ? true : false
      end

      def logged_in?(user)
        user.respond_to?(:logged?) && user.logged?
      end

      # T-26a INCREMENT 3 — THE SAME QUESTION WITH NO PROJECT TO ASK IT ABOUT.
      #
      # A my-page hours widget spans every project the actor can see, so `state` is the
      # wrong question: it takes a project and answers `:none` for a nil one, which on
      # my-page would print *"your role does not let you see spent time in this project"*
      # over a report that is showing hours from four projects. A false sentence is worse
      # than no sentence, and S-14 exists precisely because the silent version was worse
      # than both.
      #
      # So this answers the honest cross-project version:
      #
      #   :all    every project this actor may see hours in shows them ALL of them
      #   :own    at least one narrows to their own — the report is a mix and says so
      #   :none   no membership grants `view_time_entries` anywhere
      #
      # DERIVED FROM MEMBERSHIPS, NOT FROM A QUERY OVER THE RESULT SET. Asking which
      # projects actually contributed rows would be a query per render on a page that
      # already runs one widget per box, and it would answer differently for two people
      # looking at the same report. A role the actor holds is a fact about the actor.
      #
      # `time_tracking` IS NOT RE-CHECKED HERE, and the first version did check it.
      # Mutation testing removed that filter and nothing failed, so the case analysis was
      # done rather than a test invented for it: `state` carries its own module gate and
      # answers `:none` for a project with time tracking off, and `:none` changes none of
      # the three outcomes below — `all?(:none)` is unaffected by adding another `:none`,
      # `include?(:own)` is unaffected, and the fallthrough is reached in both. A guard with
      # no observable effect is a comment, so it is gone rather than wrapped in a test of
      # its fiction (the precedent is T-25's, where the surviving mutant's guard was deleted
      # rather than kept). The BEHAVIOUR it was reaching for is still pinned, by an example
      # asserting a module-disabled project contributes nothing.
      #
      # AN ADMINISTRATOR IS `:all`, and that is not a shortcut: `TimeEntry.visible` gives an
      # administrator every entry, so any narrowing notice shown to them would be false.
      def state_across_projects(user)
        return :none if user.nil?
        return :all if user.respond_to?(:admin?) && user.admin?
        return :none unless user.respond_to?(:memberships)

        states = user.memberships.filter_map do |membership|
          project = membership.project
          state(user, project) if project
        end
        return :none if states.empty? || states.all? { |s| s == :none }
        return :own if states.include?(:own)

        :all
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
