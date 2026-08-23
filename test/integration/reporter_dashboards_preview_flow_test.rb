# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-23 — the preview flow, submitted the way a browser submits it.
#
# --- WHY THIS FILE EXISTS AT ALL ---
#
# `ActionController::TestCase` calls an action directly: `post :preview, params: …` never
# renders the form, never sends its hidden fields and never passes through Rack's
# middleware. Every preview assertion in the functional suite therefore passed while the
# button in the editor returned 404 for every user, every time — the independent review of
# T-23 found it by reading the form, not by running the tests.
#
# The mechanism, because it is not obvious and it will be met again: the editor's form is
# a PATCH, and Rails implements a non-GET/POST form as a POST carrying a hidden
# `_method=patch`. A submit button's `formmethod="post"` changes the HTTP verb of the
# request and leaves the BODY alone, so `Rack::MethodOverride` — in Rails' default
# middleware stack — reads that hidden field and rewrites `REQUEST_METHOD` to PATCH before
# routing happens. The route has to accept it.
#
# An integration test is the only level at which any of that is visible.
class ReporterDashboardsPreviewFlowTest < Redmine::IntegrationTest
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  Template = RedmineReporterDashboards::Template

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @jsmith = User.find_by!(login: 'jsmith')
    # ONE OBJECT. `Role.find(1).permissions = …` followed by `Role.find(1).save!` saves a
    # SECOND, freshly loaded role and throws the assignment away — which showed up here as
    # a 403 that looked like a permission bug in the controller.
    role = Role.find(1)
    role.permissions = %w[view_issues view_reporter_dashboards_reports
                          add_reporter_dashboards_templates
                          edit_own_reporter_dashboards_templates]
    role.save!
    User.current = nil
    log_user('jsmith', 'jsmith')

    @template = Template.create!(project: @project, author: @jsmith, name: 'Editable',
                                 content: '<p>stored</p>', source: 'issues',
                                 output: 'combined')
  end

  # THE HIDDEN FIELD IS THE TEST. `_method=patch` is what the editor's form really sends,
  # and it is what turned the preview into a 404.
  def test_the_editor_preview_button_reaches_the_preview_action
    post "/projects/#{@project.identifier}/reporter/templates/#{@template.id}/preview",
         params: { _method: 'patch',
                   template: { name: 'Editable', content: '<p>UNSAVED EDIT</p>',
                               output: 'combined', orientation: 'portrait',
                               page_size: 'A4' } }

    assert_response :success
    assert_include ERB::Util.html_escape('UNSAVED EDIT'), response.body
    assert_equal '<p>stored</p>', @template.reload.content
  end

  # And the plain POST — what the NEW form sends, which has no `_method` field because a
  # create is already a POST — still works. Both, because the route now names both and a
  # route that quietly lost one of them would break only one of the two buttons.
  def test_the_new_form_preview_button_reaches_the_preview_action
    post "/projects/#{@project.identifier}/reporter/templates/preview",
         params: { template: { name: 'Draft', content: '<p>BRAND NEW</p>',
                               output: 'combined', orientation: 'portrait',
                               page_size: 'A4' } }

    assert_response :success
    assert_include ERB::Util.html_escape('BRAND NEW'), response.body
  end

  # The editor page itself must contain a button pointing at that URL. Without this, the
  # route could be correct and the form could still be sending somewhere else.
  def test_the_editor_page_offers_a_preview_button_pointing_at_the_preview_route
    get "/projects/#{@project.identifier}/reporter/templates/#{@template.id}/edit"

    assert_response :success
    assert_select 'input[type=submit][formaction=?]',
                  "/projects/#{@project.identifier}/reporter/templates/#{@template.id}/preview"
    # The hidden field whose presence makes the dual-verb route necessary. Asserted so
    # that a future change removing it makes somebody read the route's comment.
    assert_select 'input[type=hidden][name=_method][value=patch]'
  end
end
