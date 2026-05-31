# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ReporterProjectPagesControllerTest < ActionController::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def setup
    @project = Project.find(1)
    Role.find(1).add_permission! :view_reporter_project_page
    Role.find(1).add_permission! :manage_reporter_project_page
    Role.find(1).add_permission! :manage_reporter_project_tabs

    @project.enable_module!(:reporter_project_dashboards) unless @project.module_enabled?(:reporter_project_dashboards)
    @tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    @request.session[:user_id] = User.find_by!(login: 'jsmith').id
  end

  def test_show
    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :success
  end

  def test_show_renders_tab_order_icons_for_middle_tab
    first_tab = ReporterProjectTab.create!(project: @project, title: 'First')
    middle_tab = ReporterProjectTab.create!(project: @project, title: 'Middle')
    ReporterProjectTab.create!(project: @project, title: 'Last')

    get :show, params: { project_id: @project.identifier, tab: middle_tab.id }
    assert_response :success
    assert_select "a[href*='direction=left']", 1
    assert_select "a[href*='direction=right']", 1
    assert_select 'input[name="reporter_project_tab[title]"][value="Middle"]', 1
  end

  def test_show_collapses_empty_columns
    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :success
    # All groups (GROUPS has 7 entries) should be collapsed when the layout is empty.
    expected_collapsed = RedmineReporterDashboards::ProjectPage::GROUPS.size
    assert_select '.reporter-column-collapsible.reporter-column-collapsed', expected_collapsed
  end

  def test_show_keeps_column_visible_when_blocks_present
    layout = RedmineReporterDashboards::ProjectPage.default_layout.merge('left' => ['unknown_block'])
    @tab.update!(layout: layout)

    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :success
    assert_select '#reporter-list-left.reporter-column-collapsible.reporter-column-collapsed', 0
  end

  def test_show_with_activity_block
    @tab.update!(layout: RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['activity']))

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-activity', 1
    assert_select '#activity-settings', 1
  end

  def test_show_with_activity_block_instance_suffix
    @tab.update!(layout: RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['activity__2']))

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-activity__2', 1
    assert_select '#activity__2-settings', 1
  end

  def test_show_with_timelog_block_uses_block_variable
    @tab.update!(layout: RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['timelog']))

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-timelog', 1
    # Settings div and form field must use the block variable, not the hard-coded string
    assert_select '#timelog-settings', 1
    assert_select 'input[name="settings[timelog][days]"]', 1
  end

  def test_show_with_timelog_block_suffix_uses_block_variable
    @tab.update!(layout: RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['timelog__2']))

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#timelog__2-settings', 1
    assert_select 'input[name="settings[timelog__2][days]"]', 1
    # Must NOT render the old hard-coded id
    assert_select '#timelog-settings', 0
  end

  def test_show_with_activity_block_without_manage_permission
    role = Role.find(1)
    role.remove_permission! :manage_reporter_project_page
    @tab.update!(layout: RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['activity']))

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-activity', 1
    assert_select '#activity-settings', 0
    assert_select '.icon-only.icon-close', 0
  ensure
    role.add_permission! :manage_reporter_project_page
  end

  def test_update_page_ignores_malformed_settings
    @tab.update!(layout: RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['news']))

    compatible_xhr_request :post, :update_page, project_id: @project.identifier, tab: @tab.id, settings: 'invalid'

    assert_response :success
    assert_equal({}, @tab.reload.block_settings)
  end

  def test_update_page_ignores_unknown_block_settings
    compatible_xhr_request :post, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { unknown: { limit: '50' } }

    assert_response :success
    assert_equal({}, @tab.reload.block_settings)
  end

  def test_update_page_saves_valid_block_settings
    @tab.update!(layout: RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['news']))

    compatible_xhr_request :post, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { news: { limit: '10' } }

    assert_response :success
    assert_equal '10', @tab.reload.block_settings('news')[:limit]
  end

  def test_order_blocks_ignores_malformed_blocks_param
    layout = RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['news'])
    @tab.update!(layout: layout)

    post :order_blocks, params: { project_id: @project.identifier, tab: @tab.id, group: 'top', blocks: 'news' }

    assert_response :success
    assert_equal ['news'], @tab.reload.block_layout['top']
  end

  def test_order_blocks_reorders_blocks
    layout = RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['news', 'activity'])
    @tab.update!(layout: layout)

    post :order_blocks, params: {
      project_id: @project.identifier, tab: @tab.id,
      group: 'top', blocks: ['activity', 'news']
    }

    assert_response :success
    assert_equal ['activity', 'news'], @tab.reload.block_layout['top']
  end

  def test_add_block
    compatible_xhr_request :post, :add_block, project_id: @project.identifier, tab: @tab.id, block: 'news'

    assert_response :success
    assert_includes @tab.reload.block_layout['top'], 'news'
  end

  def test_remove_block
    @tab.update!(layout: RedmineReporterDashboards::ProjectPage.default_layout.merge('top' => ['news']))

    compatible_xhr_request :post, :remove_block, project_id: @project.identifier, tab: @tab.id, block: 'news'

    assert_response :success
    refute_includes @tab.reload.block_layout.values.flatten, 'news'
  end

  def test_show_requires_dashboard_module
    @project.disable_module!(:reporter_project_dashboards)
    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :not_found
  end

  def test_show_creates_default_tab_when_module_enabled_without_tabs
    @project.reporter_project_tabs.destroy_all

    assert_difference 'ReporterProjectTab.count', 1 do
      get :show, params: { project_id: @project.identifier }
    end
    assert_response :success
    assert_select '.tabs a.selected', I18n.t(:label_reporter_default_dashboard_tab)
  end
end
