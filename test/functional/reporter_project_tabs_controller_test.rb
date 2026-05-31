# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ReporterProjectTabsControllerTest < ActionController::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def setup
    @project = Project.find(1)
    Role.find(1).add_permission! :manage_reporter_project_tabs

    @project.enable_module!(:reporter_project_dashboards) unless @project.module_enabled?(:reporter_project_dashboards)
    @tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    @request.session[:user_id] = User.find_by!(login: 'jsmith').id
  end

  def test_destroy_rejects_last_tab
    assert_no_difference 'ReporterProjectTab.count' do
      delete :destroy, params: { project_id: @project.identifier, id: @tab.id }
    end
    assert_redirected_to project_reporter_page_path(@project, tab: @tab.id, anchor: 'reporter-dashboard-settings')
    assert_match I18n.t(:label_reporter_dashboard_tabs_required), flash[:error]
  end

  def test_destroy_removes_tab_when_multiple_exist
    second_tab = ReporterProjectTab.create!(project: @project, title: 'Second')

    assert_difference 'ReporterProjectTab.count', -1 do
      delete :destroy, params: { project_id: @project.identifier, id: second_tab.id }
    end
    assert_redirected_to project_reporter_page_path(@project, tab: @tab.id, anchor: 'reporter-dashboard-settings')
  end

  def test_create_redirects_without_anchor_on_success
    assert_difference 'ReporterProjectTab.count', 1 do
      post :create, params: { project_id: @project.identifier, reporter_project_tab: { title: 'New tab' } }
    end
    new_tab = ReporterProjectTab.order(:id).last
    assert_redirected_to project_reporter_page_path(@project, tab: new_tab.id)
  end

  def test_create_requires_title
    assert_no_difference 'ReporterProjectTab.count' do
      post :create, params: { project_id: @project.identifier, reporter_project_tab: { title: '' } }
    end
    assert_redirected_to project_reporter_page_path(@project, tab: @tab.id, anchor: 'reporter-dashboard-settings')
    assert_match(/cannot be blank/i, flash[:error])
  end

  def test_update_redirects_without_anchor_on_success
    patch :update, params: { project_id: @project.identifier, id: @tab.id, reporter_project_tab: { title: 'Updated' } }
    assert_redirected_to project_reporter_page_path(@project, tab: @tab.id)
  end

  def test_update_persists_new_title
    patch :update, params: { project_id: @project.identifier, id: @tab.id, reporter_project_tab: { title: 'Renamed' } }
    assert_equal 'Renamed', @tab.reload.title
  end

  def test_update_requires_title
    patch :update, params: { project_id: @project.identifier, id: @tab.id, reporter_project_tab: { title: '' } }
    assert_redirected_to project_reporter_page_path(@project, tab: @tab.id, anchor: 'reporter-dashboard-settings')
    assert_match(/cannot be blank/i, flash[:error])
  end

  def test_create_requires_dashboard_module
    @project.disable_module!(:reporter_project_dashboards)

    assert_no_difference 'ReporterProjectTab.count' do
      post :create, params: { project_id: @project.identifier, reporter_project_tab: { title: 'Hidden' } }
    end
    assert_response :not_found
  end

  def test_order_moves_tab_left
    second_tab = ReporterProjectTab.create!(project: @project, title: 'Second')
    # second_tab is at position 2 — moving left puts it before Overview
    post :order, params: { project_id: @project.identifier, id: second_tab.id, direction: 'left' }
    assert_equal 1, second_tab.reload.position
    assert_equal 2, @tab.reload.position
  end

  def test_order_moves_tab_right
    second_tab = ReporterProjectTab.create!(project: @project, title: 'Second')
    # first tab is @tab at position 1 — moving right puts it after Second
    post :order, params: { project_id: @project.identifier, id: @tab.id, direction: 'right' }
    assert_equal 2, @tab.reload.position
    assert_equal 1, second_tab.reload.position
  end
end
