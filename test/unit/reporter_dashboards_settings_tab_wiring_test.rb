require File.expand_path('../test_helper', __dir__)

# WHERE the settings-tab override sits, which is the whole of its safety.
#
# `lib/.../patches/projects_helper_patch.rb` puts the module in
# `ProjectsController._helpers` and deliberately NOT in `ProjectsHelper`. That absence is
# what makes it immune to the eight plugins that alias-chain `project_settings_tabs`:
# `alias_method` resolves its source through `ProjectsHelper.ancestors`, so a chain can only
# copy — and strand the `super` of — something that is in there.
#
# The predecessor was `ProjectsHelper.prepend`, which was correct only while this plugin was
# installed after every one of those chains. This file exists so that a return to it fails
# HERE and not on an operator's settings page.
class ReporterDashboardsSettingsTabWiringTest < ActiveSupport::TestCase
  PATCH = RedmineReporterDashboards::Patches::ProjectsHelperPatch

  # ------------------------------------------------------------------ position

  def test_the_override_is_not_in_projects_helper
    assert_not_includes ProjectsHelper.ancestors, PATCH,
                        'the override is back inside ProjectsHelper — the next plugin to ' \
                        'install an alias chain will copy it and strand its `super`'
  end

  def test_the_override_is_in_the_controller_helper_chain_above_projects_helper
    chain = ProjectsController._helpers.ancestors

    assert_includes chain, PATCH, 'ProjectsController.helper never ran'
    assert_includes chain, ProjectsHelper, 'core helper missing from the controller chain'
    assert chain.index(PATCH) < chain.index(ProjectsHelper),
           "the override must come BEFORE ProjectsHelper so `super` reaches it; got #{chain.take(6).inspect}"
  end

  # `to_prepare` re-runs `after_plugins_loaded` on every reload, so the installer runs again
  # in a long-lived process. `Module#include` is a no-op for a module already in the chain —
  # asserted rather than assumed, because a duplicate would double the tab.
  def test_installing_twice_adds_nothing
    before = ProjectsController._helpers.ancestors.count(PATCH)

    ProjectsController.helper(PATCH)

    assert_equal before, ProjectsController._helpers.ancestors.count(PATCH)
    assert_equal 1, before
  end

  # ------------------------------------------------------------------ composition

  # A NEIGHBOUR'S ALIAS CHAIN, BUILT THE ONLY WAY THAT MEASURES THE RIGHT THING.
  #
  # `alias_method :x_without_y, :x` inside a test resolves `:x` through
  # `ProjectsHelper.ancestors` AT TEST TIME, so it would capture whatever happens to be at
  # the front right now — including another plugin's live prepend — and the stand-in would
  # then sit at the wrong position in the chain. Taking `ProjectsHelper`'s OWN definition by
  # walking `super_method` until the owner is `ProjectsHelper` pins it to exactly where a
  # neighbour's chain lands: `_without_` holds core's implementation, and the wrapper is
  # defined on `ProjectsHelper` itself.
  def with_neighbour_chain
    original = ProjectsHelper.instance_method(:project_settings_tabs)
    original = original.super_method until original.owner == ProjectsHelper

    ProjectsHelper.send(:define_method, :project_settings_tabs_without_neighbour, original)
    ProjectsHelper.send(:define_method, :project_settings_tabs) do
      project_settings_tabs_without_neighbour +
        [{ name: 'neighbour', action: :edit_project, partial: 'projects/settings/issues',
           label: :label_project }]
    end

    yield
  ensure
    ProjectsHelper.send(:remove_method, :project_settings_tabs)
    ProjectsHelper.send(:define_method, :project_settings_tabs, original)
    ProjectsHelper.send(:remove_method, :project_settings_tabs_without_neighbour)
  end

  # The real view context: the class Rails builds for ProjectsController, which includes
  # `_helpers` and therefore both the override and ProjectsHelper, in their real order.
  #
  # THE REQUEST IS NOT DECORATION. Core's own `project_settings_tabs` reads
  # `params[:version_status]` for the Versions tab (`projects_helper.rb:31-32`), so a
  # controller without one fails with `undefined method 'filtered_parameters' for nil`
  # BEFORE any of this plugin's code runs — a green-looking test that never reached its
  # subject.
  def helper_object(project, actor)
    controller = ProjectsController.new
    controller.set_request!(ActionDispatch::TestRequest.create)
    controller.set_response!(ProjectsController.make_response!(controller.request))

    view = ProjectsController.view_context_class.new(
      ActionView::LookupContext.new([]), {}, controller
    )
    view.instance_variable_set(:@project, project)
    User.current = actor
    view
  end

  def setup
    super
    @project = Project.find(1)
    @project.enabled_module_names =
      @project.enabled_module_names | %w[reporter_project_dashboards reporter_dashboards_reports]
    @project.save!
    @admin = User.find(1)
  end

  def teardown
    User.current = nil
    super
  end

  def test_core_tabs_and_ours_come_through_with_no_neighbour
    names = helper_object(@project, @admin).project_settings_tabs.map { |tab| tab[:name] }

    assert_includes names, 'info', "core's own tabs must survive"
    assert_includes names, RedmineReporterDashboards::SettingsTab::NAME
    assert_equal 1, names.count(RedmineReporterDashboards::SettingsTab::NAME)
  end

  # THE CASE THE MOVE EXISTS FOR. With the old `prepend` this raised
  # `NoMethodError: super: no superclass method` — the chain installed after the prepend
  # captured our method as its `_without_`. From the controller's helper chain it cannot,
  # and all three sets of tabs arrive.
  def test_core_tabs_a_neighbours_chain_and_ours_all_come_through
    with_neighbour_chain do
      names = helper_object(@project, @admin).project_settings_tabs.map { |tab| tab[:name] }

      assert_includes names, 'info', "core's own tabs were lost"
      assert_includes names, 'neighbour', "the neighbour's tab was lost"
      assert_includes names, RedmineReporterDashboards::SettingsTab::NAME, 'our tab was lost'

      # RELATIVE, NOT ABSOLUTE. Ours is appended after `super`, so it must come after
      # everything `super` produced — core's and the neighbour's alike. Asserting it is
      # LAST would be asserting something about the other plugins in the helper chain
      # (`redmine_ai_triage` and `redmine_issue_view_columns` add tabs there too), which
      # is not this plugin's property to hold.
      assert names.index(RedmineReporterDashboards::SettingsTab::NAME) > names.index('neighbour'),
             "ours must follow what `super` returned; got #{names.inspect}"
      assert names.index(RedmineReporterDashboards::SettingsTab::NAME) > names.index('info'),
             "ours must follow core's own tabs; got #{names.inspect}"
    end
  end

  # ORDER-INDEPENDENCE, STATED AS A TEST. The neighbour's chain is installed AFTER the
  # override is already in the helper chain — the direction that used to be fatal — and the
  # override is then re-installed on top, which is what a reload does. Neither order breaks.
  def test_neither_installation_order_breaks_the_page
    with_neighbour_chain do
      ProjectsController.helper(PATCH)

      names = helper_object(@project, @admin).project_settings_tabs.map { |tab| tab[:name] }

      assert_includes names, 'neighbour'
      assert_equal 1, names.count(RedmineReporterDashboards::SettingsTab::NAME)
    end
  end

  # ------------------------------------------------------------------ the entry point

  # The measurement behind the comment's "ProjectsController is the only entry point that
  # needs it": if core ever renders that template from somewhere else, this fails and the
  # module has to be added there too.
  def test_the_settings_template_is_still_the_only_caller
    template = Rails.root.join('app/views/projects/settings.html.erb')

    assert_match(/render_tabs\s+project_settings_tabs/, template.read,
                 'core stopped calling project_settings_tabs from projects/settings')
  end
end
