# frozen_string_literal: true

require 'date'

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/permissions'
require_relative '../../lib/redmine_reporter_dashboards/settings_tab'

# `project_settings_tabs`, and the composition rule the whole loading order rests on.
#
# --- WHY THIS FILE EXISTS AT ALL ---
#
# The patch's header claims a boot-order requirement: `prepend` composes with an
# `alias_method` chain in one direction only, so the patch has to be installed after every
# other plugin's. That claim is the reason `PATCH_FILES` is loaded from
# `after_plugins_loaded` rather than from `init.rb`, and an unmeasured claim of that kind is
# how a future session "simplifies" the loading and breaks nine other plugins.
#
# The first draft of that header predicted INFINITE RECURSION for the wrong order. Measured,
# it is a `NoMethodError` on `super`. Both examples below are that measurement, and the
# reason the header now says what it says.
#
# --- AND WHY IT LOADS THE REAL FILE ---
#
# `ProjectsHelper` is stubbed and the patch file is `load`ed, so what is exercised is the
# committed patch and not a copy of its body written into this spec. CLAUDE.md's "the specs
# are the contract" cuts both ways: a spec asserting a paraphrase asserts nothing.
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

    # One plugin's alias chain, in the exact shape the nine real ones use — a module holding
    # the `_with_` body, included into the helper, then two `alias_method` calls.
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

    # Installs the committed patch against the stubbed helper, the way
    # `after_plugins_loaded` does.
    def install_patch!(helper)
      stub_const('ProjectsHelper', helper)
      load PATCH_PATH
    end

    # Redmine calls this on a view context that has INCLUDED the helper, so resolution has
    # to be exercised through an including class rather than on the module itself.
    def tabs_from(helper, project:, actor:)
      klass = Class.new { include helper }
      instance = klass.new
      instance.instance_variable_set(:@project, project)
      stub_const('User', class_double('User', current: actor))
      instance.project_settings_tabs
    end

    let(:actor) { double('User', allowed_to?: true, today: ::Date.new(2026, 8, 21)) }
    let(:project) do
      double('Project', reporter_project_tabs: double('tabs', count: 2), id: 1)
    end

    # ------------------------------------------------------------------
    describe 'the real boot order: every alias chain first, this prepend last' do
      it 'appends our tab after nine stacked chains and unwinds them exactly once' do
        helper = core_helper
        9.times { |i| alias_chain!(helper, "plugin#{i}") }
        install_patch!(helper)

        names = tabs_from(helper, project: project, actor: actor).map { |tab| tab[:name] }

        expect(names).to eq(%w[info plugin0 plugin1 plugin2 plugin3 plugin4 plugin5 plugin6
                               plugin7 plugin8 reporter_dashboards])
      end

      it 'is idempotent, because `to_prepare` runs the installer on every reload' do
        helper = core_helper
        install_patch!(helper)
        load PATCH_PATH

        names = tabs_from(helper, project: project, actor: actor).map { |tab| tab[:name] }

        expect(names).to eq(%w[info reporter_dashboards])
      end

      it 'adds nothing for an actor who may see no section' do
        helper = core_helper
        alias_chain!(helper, 'someone_else')
        install_patch!(helper)
        blind = double('User', allowed_to?: false)

        names = tabs_from(helper, project: project, actor: blind).map { |tab| tab[:name] }

        expect(names).to eq(%w[info someone_else])
      end
    end

    # ------------------------------------------------------------------
    describe 'the wrong order, which is why the patch is not installed from init.rb' do
      # NOT A HYPOTHETICAL. Installing from `init.rb` puts this plugin's prepend before the
      # init.rb of every plugin sorting after `redmine_reporter_dashboards`, and there is no
      # rule that a settings-tab chainer sorts before us — `redmine_tags`,
      # `redmine_view_issue_description` and `redmine_zenedit` all sort after, and any of
      # them could grow a settings tab in a release.
      it 'breaks loudly when a chain is installed after the prepend' do
        helper = core_helper
        install_patch!(helper)
        alias_chain!(helper, 'late_plugin')

        expect { tabs_from(helper, project: project, actor: actor) }
          .to raise_error(NoMethodError, /super: no superclass method/)
      end

      it 'breaks the same way with chains on both sides of the prepend' do
        # Measured for 1, 2 and 3 late chains and for 4-before-4-after; every combination
        # with at least one LATE chain fails, and it is always this error.
        helper = core_helper
        4.times { |i| alias_chain!(helper, "early#{i}") }
        install_patch!(helper)
        4.times { |i| alias_chain!(helper, "late#{i}") }

        expect { tabs_from(helper, project: project, actor: actor) }
          .to raise_error(NoMethodError, /super: no superclass method/)
      end
    end
  end
end
