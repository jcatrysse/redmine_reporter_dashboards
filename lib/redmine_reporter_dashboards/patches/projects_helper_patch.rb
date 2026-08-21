# frozen_string_literal: true

# One project SETTINGS tab, appended to Redmine's own list.
#
# --- THIS IS THE ONLY WAY, AND THAT IS A FACT ABOUT CORE RATHER THAN A PREFERENCE ---
#
# `app/views/projects/settings.html.erb` is three lines: an `<h2>`, `render_tabs
# project_settings_tabs`, and `html_title`. There is no `call_hook` on it. The only hooks
# anywhere near the settings page are `view_projects_form` (inside the Info tab) and two in
# the members table, so a plugin that wants a TAB has to reach the helper method. Checked
# against 7.0-devel on 2026-08-21.
#
# --- WHY `prepend` IS SAFE HERE, WITH NINE PLUGINS ALIAS-CHAINING THIS METHOD ---
#
# `project_settings_tabs` is the most-wrapped method in the Redmine plugin ecosystem. In one
# real installation nine plugins chain it — the base reporting plugin, agile, checklists,
# contacts, contacts_helpdesk, depending_custom_fields, itil_priority, mail_digest and
# questions — all with the `alias_method :x_without_y, :x` / `alias_method :x, :x_with_y`
# pair that replaced `alias_method_chain` when Rails 5.1 removed it.
#
# A prepend and an alias chain compose in ONE direction only, and the failure of the wrong
# direction was MEASURED rather than reasoned about — the first draft of this comment
# predicted infinite recursion and was wrong.
#
# Prepend first, and the next plugin's `alias_method :x_without_y, :x` resolves `:x` through
# `ProjectsHelper.ancestors`, finds OUR method at the front, and copies it into
# `ProjectsHelper` as `x_without_y`. Calling `x` then enters our method, whose `super` now
# resolves from `ProjectsHelper`'s own position — below which there is only the module the
# other plugin included, which does not define `x`. The measured result, on 1, 2 and 3 late
# chains and with chains on both sides:
#
#     NoMethodError: super: no superclass method `tabs'
#
# So the project settings page 500s for everybody, deterministically, in somebody else's
# plugin. Loud rather than subtle, which is the only good news in it.
#
# Chain first and prepend last, and the same code is correct: we sit in front, `super`
# enters the nine-deep chain once and unwinds. Measured on nine stacked chains.
# `spec/patches/projects_helper_patch_spec.rb` is that measurement, both directions.
#
# So the ordering is not a preference, and it is not left to luck either.
# `Redmine::PluginLoader.load` is:
#
#     Rails.application.config.to_prepare do
#       PluginLoader.directories.each(&:run_initializer)
#       Redmine::Hook.call_hook :after_plugins_loaded
#     end
#
# Every `init.rb` runs, and THEN `after_plugins_loaded` fires — in every `to_prepare` cycle,
# so it also holds after each development reload that throws `ProjectsHelper` away. This
# plugin installs its patches from that hook, which is the one position in the boot that is
# guaranteed to be after every alias chain in the process. (All nine also happen to sort
# alphabetically before `redmine_reporter_dashboards`, and `Dir.glob` has sorted since Ruby
# 3.0 — but that is a coincidence worth knowing about, not the mechanism.)
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

unless ProjectsHelper.ancestors.include?(RedmineReporterDashboards::Patches::ProjectsHelperPatch)
  ProjectsHelper.prepend(RedmineReporterDashboards::Patches::ProjectsHelperPatch)
end
