# frozen_string_literal: true

# One project SETTINGS tab, appended to Redmine's own list.
#
# --- REACHING THE HELPER IS THE ONLY WAY, AND THAT IS A FACT ABOUT CORE ---
#
# `app/views/projects/settings.html.erb` is three lines: an `<h2>`, `render_tabs
# project_settings_tabs`, and `html_title`. There is no `call_hook` on it. The only hooks
# anywhere near the settings page are `view_projects_form` (inside the Info tab) and two in
# the members table, so a plugin that wants a TAB has to reach that helper method.
#
# --- AND IT IS REACHED THROUGH THE CONTROLLER'S HELPER CHAIN, NOT THROUGH ProjectsHelper ---
#
# `ProjectsController.helper` puts the module below into `ProjectsController._helpers`, which
# the view context class includes AFTER `ProjectsHelper`. So at render time the lookup order
# is: this module, then `ProjectsHelper` with whatever every other plugin has done to it.
# `super` therefore resolves to whatever `ProjectsHelper` holds AT CALL TIME.
#
# THIS MODULE IS DELIBERATELY NOT IN `ProjectsHelper.ancestors`, and that absence is the
# whole design. `project_settings_tabs` is the most-wrapped method in the Redmine plugin
# ecosystem — eight plugins in one real installation wrap it with the
# `alias_method :x_without_y, :x` / `alias_method :x, :x_with_y` pair that replaced
# `alias_method_chain` when Rails 5.1 removed it. `alias_method` resolves its source through
# `ProjectsHelper.ancestors`, so anything sitting in there can be COPIED by the next plugin
# to install a chain. Nothing that is not in there can be.
#
# --- WHAT THIS REPLACED, AND WHY THE OLD VERSION WAS NOT WRONG BUT WAS FRAGILE ---
#
# This used to be `ProjectsHelper.prepend`, and it worked — but only because it was installed
# LAST. A prepend and an alias chain compose in one direction only, and the failure of the
# wrong direction was MEASURED rather than reasoned about (the first draft of the comment it
# replaced predicted infinite recursion and was wrong):
#
#     prepend, THEN a neighbour's chain
#       -> the neighbour's `alias_method :x_without_y, :x` finds OUR method at the front of
#          ProjectsHelper.ancestors and copies it into ProjectsHelper as `x_without_y`.
#          Calling `x` enters our method, whose `super` now resolves from ProjectsHelper's
#          own position, below which nothing defines `x`:
#
#              NoMethodError: super: no superclass method `project_settings_tabs'
#
#          i.e. the project settings page 500s for everybody, in somebody else's plugin.
#
# So the old arrangement was correct only for as long as `after_plugins_loaded` kept us
# behind every chain in the process. That held, but it made a page other plugins own depend
# on our boot position — and `redmine_ai_triage` shipped exactly that bug by prepending from
# its `init.rb` instead.
#
# Out of the helper module, the question does not arise: **both orders work**, because no
# `alias_method` on `ProjectsHelper` can see this module at all.
# `test/unit/reporter_dashboards_settings_tab_wiring_test.rb` asserts the absence and the
# position against the REAL `ProjectsHelper` and the REAL `ProjectsController._helpers`, so
# a return to `prepend` fails in the suite rather than on somebody's settings page.
#
# --- WHAT DID NOT CHANGE ---
#
# The install still happens from `after_plugins_loaded`, for a different and smaller reason:
# `Rails.application.config.to_prepare` throws the controller classes away on every reload,
# and `_helpers` is rebuilt with them. That hook fires at the end of every `to_prepare`
# cycle, so the module goes back in each time. It is reload-safety now, not
# ordering-safety.
#
# `ProjectsController` is also the only entry point that needs it. Measured across core and
# all 42 plugins of one real installation: the sole caller of `project_settings_tabs` is
# `app/views/projects/settings.html.erb`, and no plugin renders that template from another
# controller. Adding the module anywhere else would be surface with no reader.
#
# --- AND WHY THE PERMISSION FILTER IS OURS ---
#
# Core filters its own array INSIDE the method (`projects_helper.rb:44-46`), so anything
# appended after `super` has already missed both `select`s and nothing downstream re-checks
# it. `SettingsTab.tabs` is that check. It is there and not here so it can be tested without
# booting Redmine.
module RedmineReporterDashboards
  module Patches
    module ProjectsHelperPatch
      # `@project` is ProjectsController#settings' own instance variable, which the helper
      # already reads three lines up in core's own version. nil in no reachable state, and
      # `SettingsTab.tabs` returns [] for it anyway rather than raising inside a view.
      def project_settings_tabs
        super + RedmineReporterDashboards::SettingsTab.tabs(@project, User.current)
      end
    end
  end
end

# `helper` is public API on ActionController::Base and has been since Rails 3, and it is
# idempotent: `Module#include` of a module already in the chain is a no-op, so the reload
# cycle above cannot stack copies of this. Both facts are asserted in the wiring test rather
# than trusted, because "public since Rails 3" is a claim about four Rails majors this
# plugin supports and only running it makes it true.
ProjectsController.helper(RedmineReporterDashboards::Patches::ProjectsHelperPatch)
