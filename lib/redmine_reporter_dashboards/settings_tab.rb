# frozen_string_literal: true

module RedmineReporterDashboards
  # The project SETTINGS tab, as data and as bounded queries — everything about it except
  # the two lines of markup and the one `prepend` that hands it to Redmine.
  #
  # --- WHY A TAB AT ALL, WHEN THREE MENU ITEMS ALREADY WORKED ---
  #
  # Curator decision 2026-08-21: configuration, logs and management belong under Project
  # settings, which is where a Redmine administrator looks for them. The dashboard stays a
  # project MENU item, because a dashboard is a working surface like Issues or the Roadmap
  # rather than a setting.
  #
  # --- WHY THIS TAB IS A SUMMARY AND NOT THE PAGES THEMSELVES ---
  #
  # `app/views/common/_tabs.html.erb` renders EVERY tab's partial on every request and
  # hides the unselected ones with `display:none`. So whatever goes in here is paid for by
  # somebody who came to rename the project. The base plugin puts its whole template index
  # in its tab (`partial: 'report_templates/index'`); this one must not, because
  # `templates#index` is unpaginated and `schedules#index` adds a heartbeat scan on top.
  #
  # Everything below is therefore COUNTS and one heartbeat: four statements at most,
  # constant in the number of templates, schedules, tabs and sends. The work surfaces keep
  # their own controllers, their own pagination and their own permissions, and this tab
  # links to them. That is what makes G6 hold for a page this plugin does not own.
  #
  # --- AND WHY THE PERMISSION CHECK HERE IS THE ONLY ONE ---
  #
  # Core's `project_settings_tabs` filters its OWN array inside the method
  # (`projects_helper.rb:44-46`), so a tab appended after `super` has already missed both
  # `select`s. Nothing downstream re-checks it. `tabs` below is that check, and
  # `spec/permissions/settings_tab_spec.rb` is why it is a pure function of (project,
  # actor) rather than a condition inside an ERB template.
  module SettingsTab
    NAME = 'reporter_dashboards'
    PARTIAL = 'projects/settings/reporter_dashboards'
    LABEL = :label_reporter_settings_tab

    # The sections this tab can show, in the order the partial prints them, each with the
    # permission that opens it.
    #
    # THE ORDER IS ALSO THE TAB'S `action:`. Redmine allows a tab exactly ONE permission
    # (`User.current.allowed_to?(tab[:action], @project)`), and this tab covers four
    # surfaces belonging to two modules. So the tab is registered under the FIRST of these
    # the actor actually holds, and the partial then prints only the sections that actor
    # holds. An operator with `view_…_schedules` and nothing else still gets the tab, which
    # a single hard-coded `action:` could not have given them.
    SECTIONS = [
      [:dashboard, :manage_reporter_project_tabs],
      [:templates, :view_reporter_dashboards_reports],
      [:schedules, :view_reporter_dashboards_schedules],
      [:mail,      :mail_reporter_dashboards_reports]
    ].freeze

    # `SECTIONS` as a lookup, built once. `SECTIONS.to_h` per call was eight allocations per
    # settings-page render for a table of four frozen pairs.
    SECTION_PERMISSIONS = SECTIONS.to_h.freeze

    # A section's own visibility. `allowed_to?(permission, project)` already answers the
    # whole question — `User#allowed_to?` returns false unless `project.allows_to?` passes,
    # which is the module check AND the closed-project `read:` check, and returns true for
    # an administrator (`user.rb:777-780`). A second `module_enabled?` here would be a
    # second way to ask one question, and the two would eventually disagree.
    def self.allowed?(section, project, actor)
      permission = SECTION_PERMISSIONS[section]
      return false if permission.nil? || project.nil? || actor.nil?

      actor.allowed_to?(permission, project)
    end

    # The permission the tab is registered under, or nil when the actor may see no section.
    def self.tab_action(project, actor)
      return nil if project.nil? || actor.nil?

      SECTIONS.each do |section, permission|
        return permission if allowed?(section, project, actor)
      end
      nil
    end

    # Zero or one tab, in the shape core's `render_tabs` reads.
    def self.tabs(project, actor)
      action = tab_action(project, actor)
      return [] if action.nil?

      [{ name: NAME, action: action, partial: PARTIAL, label: LABEL }]
    end

    # What the partial prints. Every field is nil when its section is not visible, so a
    # query is never run for a section the actor cannot see — the cheapest way to be sure
    # the tab discloses nothing is not to ask.
    Summary = Struct.new(:dashboard_tabs, :templates, :schedules, keyword_init: true)

    def self.summary(project, actor)
      Summary.new(
        dashboard_tabs: (project.reporter_project_tabs.count if allowed?(:dashboard, project, actor)),
        templates: (template_count(project, actor) if allowed?(:templates, project, actor)),
        schedules: (heartbeat(project, actor) if allowed?(:schedules, project, actor))
      )
    end

    # `Template.visible` refuses a nil actor (INV-1) and is the same scope the index uses,
    # so the count cannot disagree with the list it links to.
    def self.template_count(project, actor)
      Template.visible(actor).where(project_id: project.id).count
    end

    # The SAME `Status` the schedules index renders, through the same two locale keys — so
    # "the scheduler is not running" reads identically in both places. `today:` is passed
    # rather than read here, per CLAUDE.md §6: the caller reads the clock once.
    def self.heartbeat(project, actor)
      Scheduling::Heartbeat.status(
        today: actor.today,
        scope: Schedule.where(project_id: project.id, enabled: true)
      )
    end
  end
end
