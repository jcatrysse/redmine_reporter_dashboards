# frozen_string_literal: true

require 'date'

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/permissions'
require_relative '../../lib/redmine_reporter_dashboards/settings_tab'

# `project_settings_tabs`, and WHERE the override is installed.
#
# --- WHAT THIS FILE USED TO BE, AND WHY IT CHANGED ---
#
# It used to assert the two directions of `prepend` against an `alias_method` chain, because
# the patch was `ProjectsHelper.prepend` and its safety was its boot POSITION: chains first
# and the prepend last works; the prepend first and a chain after it is
# `NoMethodError: super: no superclass method`, i.e. a 500 on the settings page inside
# somebody else's plugin. That measurement is still true and it is why the patch moved.
#
# The patch now installs into `ProjectsController._helpers` instead
# (`ProjectsController.helper`), and the module is deliberately NOT in `ProjectsHelper`.
# `alias_method` resolves through `ProjectsHelper.ancestors`, so a chain can only capture —
# and strand the `super` of — something that is in there. Out of it, BOTH orders work, and
# the direction that used to be fatal is asserted below to be fine.
#
# --- WHAT IS TESTED WHERE ---
#
# This file runs without Rails, so it tests the two things that do not need it: the
# installer's CONTRACT (it must reach for the controller and must leave `ProjectsHelper`
# alone), and the module's own composition through `super`.
#
# The POSITION in the real chain — absent from `ProjectsHelper.ancestors`, present in
# `ProjectsController._helpers.ancestors` above `ProjectsHelper` — is asserted against the
# real classes in `test/unit/reporter_dashboards_settings_tab_wiring_test.rb`, because a
# stub cannot lie about that convincingly enough to be worth anything.
module RedmineReporterDashboards
  # A STRING and not the constant: the patch file DEFINES that constant, and this spec
  # loads it inside its examples, so naming it here would be a NameError at describe time.
  RSpec.describe 'RedmineReporterDashboards::Patches::ProjectsHelperPatch' do
    PATCH_PATH = File.expand_path(
      '../../lib/redmine_reporter_dashboards/patches/projects_helper_patch.rb', __dir__
    ).freeze

    # A stand-in for core's helper: one method returning core's own tab list.
    def core_helper
      Module.new do
        def project_settings_tabs
          [{ name: 'info' }]
        end
      end
    end

    # A stand-in for `ProjectsController`, recording what `helper` was handed. `_helpers` is
    # a real module so `include` behaves exactly as Rails' does.
    def controller_double(helper)
      klass = Class.new do
        class << self
          attr_reader :_helpers, :helper_calls
        end

        def self.helper(mod)
          @helper_calls << mod
          @_helpers.send(:include, mod)
        end
      end
      klass.instance_variable_set(:@_helpers, Module.new { include helper })
      klass.instance_variable_set(:@helper_calls, [])
      klass
    end

    # One plugin's alias chain, in the exact shape the real ones use — a module holding the
    # `_with_` body, included into the helper, then two `alias_method` calls.
    def alias_chain!(helper, tag)
      body = Module.new do
        define_method("project_settings_tabs_with_#{tag}") do
          send("project_settings_tabs_without_#{tag}") + [{ name: tag }]
        end
      end
      helper.send(:include, body)
      helper.class_eval do
        alias_method "project_settings_tabs_without_#{tag}", :project_settings_tabs
        alias_method :project_settings_tabs, "project_settings_tabs_with_#{tag}"
      end
    end

    # Installs the committed patch against the stubs, the way `after_plugins_loaded` does.
    def install_patch!(helper, controller)
      stub_const('ProjectsHelper', helper)
      stub_const('ProjectsController', controller)
      load PATCH_PATH
    end

    # Redmine renders through a view context that includes the controller's `_helpers`.
    def tabs_from(controller, project:, actor:)
      instance = Class.new { include controller._helpers }.new
      instance.instance_variable_set(:@project, project)
      stub_const('User', class_double('User', current: actor))
      instance.project_settings_tabs
    end

    let(:actor) { double('User', allowed_to?: true, today: ::Date.new(2026, 8, 21)) }
    let(:project) do
      double('Project', reporter_project_tabs: double('tabs', count: 2), id: 1)
    end

    # ------------------------------------------------------------------
    describe 'the installer' do
      it 'hands the module to the controller and never touches ProjectsHelper' do
        helper = core_helper
        controller = controller_double(helper)

        install_patch!(helper, controller)

        patch = RedmineReporterDashboards::Patches::ProjectsHelperPatch
        expect(controller.helper_calls).to eq([patch])
        expect(controller._helpers.ancestors).to include(patch)
        expect(helper.ancestors).not_to include(patch),
                                        'back inside ProjectsHelper: the next alias chain ' \
                                        'installed after us would capture it'
      end

      it 'sits ahead of the core helper, so `super` reaches it' do
        helper = core_helper
        controller = controller_double(helper)
        install_patch!(helper, controller)

        chain = controller._helpers.ancestors
        patch = RedmineReporterDashboards::Patches::ProjectsHelperPatch

        expect(chain.index(patch)).to be < chain.index(helper)
      end

      it 'is idempotent, because `to_prepare` runs the installer on every reload' do
        helper = core_helper
        controller = controller_double(helper)
        install_patch!(helper, controller)
        load PATCH_PATH

        names = tabs_from(controller, project: project, actor: actor).map { |tab| tab[:name] }

        expect(names).to eq(%w[info reporter_dashboards])
      end
    end

    # ------------------------------------------------------------------
    describe 'composition with the plugins that alias-chain the core helper' do
      it 'appends our tab after nine stacked chains and unwinds them exactly once' do
        helper = core_helper
        9.times { |i| alias_chain!(helper, "plugin#{i}") }
        controller = controller_double(helper)
        install_patch!(helper, controller)

        names = tabs_from(controller, project: project, actor: actor).map { |tab| tab[:name] }

        expect(names).to eq(%w[info plugin0 plugin1 plugin2 plugin3 plugin4 plugin5 plugin6
                               plugin7 plugin8 reporter_dashboards])
      end

      # THE DIRECTION THAT USED TO BE FATAL. With `ProjectsHelper.prepend` this raised
      # `NoMethodError: super: no superclass method` — the late chain copied our method into
      # ProjectsHelper as its `_without_` and the copy's `super` had nothing below it. From
      # the controller's helper chain there is nothing in `ProjectsHelper.ancestors` for
      # `alias_method` to copy, so the same code is simply correct.
      it 'survives a chain installed AFTER the patch' do
        helper = core_helper
        controller = controller_double(helper)
        install_patch!(helper, controller)
        alias_chain!(helper, 'late_plugin')

        names = tabs_from(controller, project: project, actor: actor).map { |tab| tab[:name] }

        expect(names).to eq(%w[info late_plugin reporter_dashboards])
      end

      it 'survives chains on both sides of it' do
        helper = core_helper
        4.times { |i| alias_chain!(helper, "early#{i}") }
        controller = controller_double(helper)
        install_patch!(helper, controller)
        4.times { |i| alias_chain!(helper, "late#{i}") }

        names = tabs_from(controller, project: project, actor: actor).map { |tab| tab[:name] }

        expect(names).to eq(%w[info early0 early1 early2 early3 late0 late1 late2 late3
                               reporter_dashboards])
      end
    end

    # ------------------------------------------------------------------
    describe 'the permission filter, which is ours because core has already run its own' do
      it 'adds nothing for an actor who may see no section' do
        helper = core_helper
        alias_chain!(helper, 'someone_else')
        controller = controller_double(helper)
        install_patch!(helper, controller)
        blind = double('User', allowed_to?: false)

        names = tabs_from(controller, project: project, actor: blind).map { |tab| tab[:name] }

        expect(names).to eq(%w[info someone_else])
      end
    end
  end
end
