# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class SqlStatsControllerTest < ActionController::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :projects_trackers, :enumerations

  def setup
    @project = Project.find(1)
    Role.find(1).add_permission! :view_issues
    @request.session[:user_id] = User.find_by!(login: 'jsmith').id
  end

  # All GETs omit format: :json deliberately.
  # Redmine's api_request? returns true for params[:format]=='json', which skips
  # session auth entirely in find_current_user. Since this endpoint is a
  # session-authenticated AJAX endpoint (not an API-key endpoint), we must NOT
  # send format=json. The controller uses render json: unconditionally so the
  # response is always JSON regardless of the request format.

  def test_monthly_flow_returns_json_with_expected_keys
    get :monthly_flow, params: { project_id: @project.identifier }
    assert_response :success

    json = ActiveSupport::JSON.decode(response.body)
    assert json.key?('labels')
    assert json.key?('created')
    assert json.key?('closed')
    assert json.key?('open_now')
    assert json.key?('total')
    assert json.key?('project')
    assert json.key?('months')
    assert json.key?('generated_at')
  end

  def test_monthly_flow_defaults_to_6_months
    get :monthly_flow, params: { project_id: @project.identifier }
    assert_response :success

    json = ActiveSupport::JSON.decode(response.body)
    assert_equal 6, json['months']
    assert_equal 6, json['labels'].size
  end

  def test_monthly_flow_caps_at_24_months
    get :monthly_flow, params: { project_id: @project.identifier, months: '30' }
    assert_response :success

    json = ActiveSupport::JSON.decode(response.body)
    assert_equal 24, json['months']
  end

  def test_monthly_flow_uses_specified_months
    get :monthly_flow, params: { project_id: @project.identifier, months: '3' }
    assert_response :success

    json = ActiveSupport::JSON.decode(response.body)
    assert_equal 3, json['months']
    assert_equal 3, json['labels'].size
  end

  def test_monthly_flow_labels_in_ascending_order
    get :monthly_flow, params: { project_id: @project.identifier, months: '3' }
    assert_response :success

    labels = ActiveSupport::JSON.decode(response.body)['labels']
    assert_equal labels.sort, labels
  end

  def test_monthly_flow_returns_404_for_nonexistent_project
    get :monthly_flow, params: { project_id: 'nonexistent-project' }
    assert_response :not_found

    json = ActiveSupport::JSON.decode(response.body)
    assert json.key?('error')
  end

  def test_monthly_flow_returns_403_for_private_project_without_permission
    # Remove view_issues from jsmith's role in @project to trigger the 403 branch.
    # Using a non-member project is unreliable: Role.find(1) is jsmith's member role
    # and has no effect on non-member or public-project access (different role applies).
    Role.find(1).remove_permission! :view_issues
    get :monthly_flow, params: { project_id: @project.identifier }
    assert_response :forbidden
  ensure
    Role.find(1).add_permission! :view_issues
  end

  def test_monthly_flow_requires_login
    @request.session[:user_id] = nil
    get :monthly_flow, params: { project_id: @project.identifier }
    # Without format=json, require_login redirects to login page (302) for HTML
    assert_response :redirect
  end
end
