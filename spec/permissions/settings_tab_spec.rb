# frozen_string_literal: true

require 'date'

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/permissions'
require_relative '../../lib/redmine_reporter_dashboards/settings_tab'

# The project settings tab, as a pure function of (project, actor).
#
# WHY THIS IS TESTABLE WITHOUT REDMINE, and why that mattered: core filters
# `project_settings_tabs` INSIDE the method, so a tab appended after `super` has already
# missed both `select`s and nothing downstream re-checks it. This module is therefore the
# ONLY permission check standing between a settings tab and an actor who may not see it. A
# check that can only be exercised by booting Redmine and driving a browser is a check that
# gets exercised once.
module RedmineReporterDashboards
  RSpec.describe SettingsTab do
    # A project double that counts its dashboard tabs and nothing else. `allowed_to?` lives
    # on the ACTOR in Redmine, so the project needs no permission behaviour here.
    def project_double(tab_count: 3)
      instance_double('Project', reporter_project_tabs: double('tabs', count: tab_count))
    end

    # An actor holding exactly the named permissions. Mirrors `User#allowed_to?(permission,
    # project)`, which is the only method this module calls on it.
    def actor_holding(*permissions)
      actor = double('User')
      allow(actor).to receive(:allowed_to?) { |permission, _project| permissions.include?(permission) }
      allow(actor).to receive(:today).and_return(::Date.new(2026, 8, 21))
      actor
    end

    describe '.tab_action' do
      it 'is nil for an actor holding none of the four, so no tab is offered' do
        expect(described_class.tab_action(project_double, actor_holding)).to be_nil
      end

      it 'is the schedules permission for an operator holding only that' do
        # THE CASE THE WHOLE `SECTIONS` LIST EXISTS FOR. Redmine allows a tab exactly one
        # `action:`, so a single hard-coded permission would have hidden this tab from the
        # read-only operator `view_…_schedules` was split out for (§4.1, T-25's Accept:).
        actor = actor_holding(:view_reporter_dashboards_schedules)

        expect(described_class.tab_action(project_double, actor))
          .to eq(:view_reporter_dashboards_schedules)
      end

      it 'is the first section the actor holds, in SECTIONS order, when they hold several' do
        actor = actor_holding(:view_reporter_dashboards_reports,
                              :mail_reporter_dashboards_reports)

        expect(described_class.tab_action(project_double, actor))
          .to eq(:view_reporter_dashboards_reports)
      end

      it 'is nil without a project rather than raising inside a view' do
        expect(described_class.tab_action(nil, actor_holding(:view_reporter_dashboards_reports)))
          .to be_nil
      end

      it 'is nil without an actor rather than raising inside a view' do
        # `ProjectsController#settings` is behind `authorize`, so `User.current` is never
        # anonymous-and-unpermitted here in practice. FAIL CLOSED anyway (INV-1/INV-3): a
        # missing actor is not evidence of permission.
        expect(described_class.tab_action(project_double, nil)).to be_nil
      end
    end

    describe '.tabs' do
      it 'is empty for an actor who may see nothing' do
        expect(described_class.tabs(project_double, actor_holding)).to eq([])
      end

      it 'is one tab in the shape render_tabs reads' do
        actor = actor_holding(:manage_reporter_project_tabs)

        expect(described_class.tabs(project_double, actor)).to eq(
          [{ name: 'reporter_dashboards',
             action: :manage_reporter_project_tabs,
             partial: 'projects/settings/reporter_dashboards',
             label: :label_reporter_settings_tab }]
        )
      end

      it 'names a partial this repository actually contains' do
        # A tab with a `partial:` core cannot find is an ActionView::MissingTemplate on the
        # project settings page — for every user, including one who never enabled this
        # plugin's modules. The string is checked here rather than trusted.
        path = File.expand_path("../../app/views/#{File.dirname(described_class::PARTIAL)}/" \
                                "_#{File.basename(described_class::PARTIAL)}.html.erb",
                                __dir__)

        expect(File.file?(path)).to be(true), "no such partial: #{path}"
      end
    end

    describe '.summary' do
      it 'asks nothing about a section the actor cannot see' do
        # NOT MERELY "returns nil". The models are not even defined in this run, so a query
        # for an invisible section would raise NameError — which is the assertion: the
        # cheapest way to be sure the tab discloses nothing is not to ask.
        summary = described_class.summary(project_double, actor_holding)

        expect(summary.dashboard_tabs).to be_nil
        expect(summary.templates).to be_nil
        expect(summary.schedules).to be_nil
      end

      it 'counts only the dashboard tabs for an actor who may see only those' do
        actor = actor_holding(:manage_reporter_project_tabs)

        summary = described_class.summary(project_double(tab_count: 7), actor)

        expect(summary.dashboard_tabs).to eq(7)
        expect(summary.templates).to be_nil
        expect(summary.schedules).to be_nil
      end

      it 'counts templates through the same visible scope the index uses' do
        project = project_double
        scoped = double('scope')
        allow(scoped).to receive(:where).with(project_id: project.object_id).and_return(scoped)
        # `Template.visible(actor)` and then `.where(project_id:)` — the index's own scope,
        # so the number cannot disagree with the list it links to.
        template = class_double('RedmineReporterDashboards::Template')
        stub_const('RedmineReporterDashboards::Template', template)
        allow(project).to receive(:id).and_return(project.object_id)
        allow(template).to receive(:visible).and_return(scoped)
        allow(scoped).to receive(:count).and_return(4)

        actor = actor_holding(:view_reporter_dashboards_reports)

        expect(described_class.summary(project, actor).templates).to eq(4)
        expect(template).to have_received(:visible).with(actor)
      end
    end

    # ------------------------------------------------------------------
    # The invariant that makes the tab reachable at all.
    describe 'the contract with the permission model' do
      it 'gives every section a permission that opens the settings page' do
        # THE FAILURE THIS CATCHES IS INVISIBLE OTHERWISE. `ProjectsController#settings` is
        # behind `before_action :authorize`. A section whose permission does not map
        # `projects#settings` produces a tab that is listed and 403s when opened — and only
        # for the role that holds exactly that one permission, which is not the role anybody
        # tests with.
        without = described_class::SECTIONS.reject do |_section, permission|
          Permissions.find(permission)&.settings_tab
        end

        expect(without).to eq([]),
                           "these sections' permissions do not carry settings_tab: " \
                           "#{without.inspect}"
      end

      it 'has a section for every permission that carries the flag' do
        # The other direction. A permission mapping `projects#settings` with no section to
        # show is a role that can open the project settings page and see nothing there — a
        # widening with no feature attached to it.
        flagged = Permissions::ALL.select(&:settings_tab).map(&:name).sort

        expect(flagged).to eq(described_class::SECTIONS.map(&:last).sort)
      end

      it 'maps exactly one core action, deeply frozen' do
        # A generic `core_actions:` field would let a later edit map `projects#destroy` or
        # `projects#update` and hand a reader-level role the project form. This pins the
        # blast radius of the whole mechanism to one action.
        expect(Permissions::SETTINGS_TAB_ACTIONS).to eq(projects: [:settings])
        expect(Permissions::SETTINGS_TAB_ACTIONS).to be_frozen
        expect(Permissions::SETTINGS_TAB_ACTIONS[:projects]).to be_frozen
      end

      it 'leaves `actions` untouched, so the map still describes only our controllers' do
        # `permission_map_spec.rb` asserts that every controller in `actions` has a file
        # here, that every action is public and that `authorize` runs for it. Those three
        # can only read controllers this repository contains, so the core action must NOT
        # leak into `actions`.
        Permissions::ALL.each do |entry|
          expect(entry.actions&.keys || []).not_to include(:projects), entry.name.to_s
        end
      end

      it 'flags no PLANNED permission, which guards nothing yet' do
        expect(Permissions::PLANNED.select(&:settings_tab)).to eq([])
      end

      it 'adds the core action only where the flag is set' do
        unflagged = Permissions::REGISTERED.reject(&:settings_tab)

        expect(unflagged.map(&:registered_actions)).to eq(unflagged.map(&:actions))
      end
    end
  end
end
