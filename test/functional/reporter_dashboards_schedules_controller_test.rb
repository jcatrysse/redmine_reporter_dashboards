# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-25's UI, and the permission split that is its whole design.
#
# §4.1 gives scheduling two permissions where one would have done, and T-25's `Accept:`
# says why: *"the split exists so an operator can answer 'did it run' without being able to
# change who receives it."* So the shape of this file is: hold ONE permission, walk every
# action, and assert 403 on everything it must not reach. Redmine's `authorize` passes on
# ANY permission mapping an action, so a controller with two permissions in it needs the
# negative half written down or the map is the only thing holding the line.
class ReporterDashboardsSchedulesControllerTest < Redmine::ControllerTest
  tests ReporterDashboards::SchedulesController

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :email_addresses

  Template = RedmineReporterDashboards::Template
  Schedule = RedmineReporterDashboards::Schedule
  ScheduleRun = RedmineReporterDashboards::ScheduleRun
  ScheduleRecipient = RedmineReporterDashboards::ScheduleRecipient

  def setup
    @project = Project.find(1)
    EnabledModule.create!(project: @project, name: 'reporter_dashboards_reports') unless
      @project.module_enabled?(:reporter_dashboards_reports)
    @author = User.find(2)
    @other = User.find(3)
    @role = Role.find(1)
    @template = Template.create!(project: @project, author_id: @author.id, name: 'Weekly',
                                 content: '<p>hi</p>')
    @schedule = Schedule.create!(project: @project, template_id: @template.id,
                                 author_id: @author.id, repeat: 'weekly',
                                 start_date: Date.new(2026, 1, 1))
    # `view_reporter_dashboards_reports` IS PART OF THE BASELINE, and finding out why cost
    # four red examples. A schedule points at a report template, and the picker — and the
    # controller behind it — resolve that id through `Template.visible`, which needs the
    # reports permission. So somebody who can manage schedules but cannot see a template
    # cannot attach one, which is right: pointing a schedule at a template is choosing to
    # mail its output to a list of people. There is an example for that below.
    grant(:view_reporter_dashboards_reports, :view_reporter_dashboards_schedules,
          :manage_reporter_dashboards_schedules)
    User.current = nil
    @request.session[:user_id] = @author.id
  end

  # Replaces the role's permissions outright, so an example says exactly what is held.
  # `User.find` afterwards because `Role#permissions=` does not clear the user's memoised
  # permission set, and a stale one turns a 403 example green for the wrong reason.
  def grant(*permissions)
    @role.permissions = permissions
    @role.save!
    @author = User.find(@author.id)
    @other = User.find(@other.id)
  end

  # --- reading, which is what view_… is for --------------------------------------------

  def test_index_lists_the_projects_schedules
    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select 'table.list td a', text: 'Weekly'
  end

  def test_show_lists_the_run_history
    ScheduleRun.claim(@schedule, Date.new(2026, 3, 10), status: ScheduleRun::STATUS_SUCCESS,
                                                        correlation_id: 'cid-visible')

    get :show, params: { project_id: @project.id, id: @schedule.id }

    assert_response :success
    assert_select 'table.list', text: /cid-visible/
  end

  def test_a_viewer_sees_the_run_history_without_holding_manage
    # §4.1's sentence in one example: "an operator can answer *did it run* without being
    # able to change who receives it."
    grant(:view_reporter_dashboards_schedules)

    get :show, params: { project_id: @project.id, id: @schedule.id }

    assert_response :success
    assert_select 'a.icon-edit', count: 0
  end

  def test_a_schedule_is_not_reachable_through_another_projects_url
    # `find_schedule` scopes by project, so an id from elsewhere is a 404 rather than a
    # cross-project read. The actor is a member of BOTH projects here on purpose: without
    # that the request stops at `authorize` with a 403 and the example proves nothing about
    # the scoping it is named for.
    other_project = Project.find(2)
    EnabledModule.create!(project: other_project, name: 'reporter_dashboards_reports')
    # user 2 is already a member of project 2 in the fixtures; add the role rather than the
    # membership, or `Member` refuses the duplicate.
    membership = Member.find_by(project: other_project, user_id: @author.id) ||
                 Member.create!(project: other_project, principal: @author, roles: [@role])
    membership.roles << @role unless membership.roles.include?(@role)
    @author = User.find(@author.id)

    get :show, params: { project_id: other_project.id, id: @schedule.id }

    assert_response :not_found
  end

  def test_managing_schedules_does_not_let_you_attach_a_template_you_cannot_see
    # The dependency stated as a rule rather than left to a fixture: a schedule points at a
    # template, and choosing one is choosing to mail its output. `Template.visible` needs
    # `view_reporter_dashboards_reports`, so without it the id resolves to nothing and the
    # form says the template is blank — rather than silently scheduling something.
    grant(:view_reporter_dashboards_schedules, :manage_reporter_dashboards_schedules)

    assert_no_difference 'Schedule.count' do
      post :create, params: { project_id: @project.id,
                              schedule: { template_id: @template.id, repeat: 'daily',
                                          start_date: '2026-03-01' } }
    end

    assert_response :unprocessable_entity
  end

  # --- the split, negatively -------------------------------------------------------------

  def test_view_alone_cannot_reach_any_writing_action
    grant(:view_reporter_dashboards_schedules)

    get :new, params: { project_id: @project.id }
    assert_response :forbidden

    post :create, params: { project_id: @project.id, schedule: { repeat: 'daily' } }
    assert_response :forbidden

    get :edit, params: { project_id: @project.id, id: @schedule.id }
    assert_response :forbidden

    patch :update, params: { project_id: @project.id, id: @schedule.id,
                             schedule: { repeat: 'daily' } }
    assert_response :forbidden

    delete :destroy, params: { project_id: @project.id, id: @schedule.id }
    assert_response :forbidden
  end

  def test_view_alone_cannot_send_a_test
    # THE ONE THAT MATTERS MOST OF THE FIVE. `#test_send` puts mail on the wire, and a read
    # permission that could send e-mail would not be a read permission.
    grant(:view_reporter_dashboards_schedules)

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      post :test_send, params: { project_id: @project.id, id: @schedule.id }
    end

    assert_response :forbidden
  end

  def test_manage_alone_can_write_and_read
    # The other direction. `manage_` maps neither `#index` nor `#show`, so somebody who can
    # edit a schedule but not view one would be an absurdity — Redmine's `authorize` refuses
    # an unmapped action outright, which is why `view_` is what the menu link is gated on.
    grant(:manage_reporter_dashboards_schedules)

    get :new, params: { project_id: @project.id }
    assert_response :success

    get :index, params: { project_id: @project.id }
    # `manage_` does not map #index, and nothing pretends it does.
    assert_response :forbidden
  end

  def test_holding_neither_permission_reaches_nothing
    grant(:view_reporter_dashboards_reports)

    get :index, params: { project_id: @project.id }
    assert_response :forbidden

    get :show, params: { project_id: @project.id, id: @schedule.id }
    assert_response :forbidden
  end

  def test_the_module_must_be_enabled
    # 404 and not 403: with the module off, this project has no schedules surface at all,
    # and that is the answer `TemplatesController` gives too.
    @project.enabled_modules.where(name: 'reporter_dashboards_reports').destroy_all

    get :index, params: { project_id: @project.id }

    assert_response :not_found
  end

  # --- creating ---------------------------------------------------------------------------

  def test_create_stores_the_schedule_and_its_recipients
    assert_difference 'Schedule.count', 1 do
      post :create, params: { project_id: @project.id,
                              schedule: { template_id: @template.id, repeat: 'daily',
                                          start_date: '2026-03-01', enabled: '1',
                                          render_as: 'author',
                                          recipient_user_ids: [@other.id.to_s] } }
    end

    schedule = Schedule.order(:id).last
    assert_redirected_to project_reporter_schedule_path(@project, schedule)
    assert_equal [@other.id], schedule.recipients.map(&:user_id)
    assert_equal @author.id, schedule.author_id, 'the author is the requester, never a param'
    assert_equal @project.id, schedule.project_id
  end

  def test_the_author_and_the_project_cannot_be_set_from_params
    # `author_id` decides who a failure notice goes to and `project_id` decides which
    # project's permissions are checked, so a request able to set them could aim both
    # somewhere else.
    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01',
                                        author_id: @other.id.to_s, project_id: '2' } }

    schedule = Schedule.order(:id).last
    assert_equal @author.id, schedule.author_id
    assert_equal @project.id, schedule.project_id
  end

  def test_a_template_this_actor_cannot_see_is_refused
    # THE DISCLOSURE HOLE REACHED THROUGH A FORM FIELD: without this, a member could point a
    # schedule at somebody else's PRIVATE template and have it mailed to a list of their
    # choosing. The picker lists `Template.visible`, and the controller resolves the id
    # against the same scope rather than trusting what came back.
    private_template = Template.create!(project: @project, author_id: @other.id,
                                        name: 'Secret',
                                        visibility: Template::VISIBILITY_PRIVATE)
    assert_not private_template.visible?(@author), 'fixture precondition'

    assert_no_difference 'Schedule.count' do
      post :create, params: { project_id: @project.id,
                              schedule: { template_id: private_template.id,
                                          repeat: 'daily', start_date: '2026-03-01' } }
    end

    assert_response :unprocessable_entity
  end

  def test_a_recipient_outside_the_project_is_dropped
    # §7's row: "`user_id` only — no free-text to/cc/bcc/from, which is the
    # exfiltration-and-spoofing-relay finding." The ids are additionally intersected with
    # the project's own members, so the form cannot address somebody with no business here.
    outsider = User.find(4)
    assert_not @project.users.include?(outsider), 'fixture precondition'

    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01',
                                        recipient_user_ids: [outsider.id.to_s,
                                                             @other.id.to_s] } }

    schedule = Schedule.order(:id).last
    assert_equal [@other.id], schedule.recipients.map(&:user_id)
  end

  def test_a_schedule_that_does_not_validate_is_not_saved_with_recipients
    # The two writes are in ONE transaction: a schedule saved with the previous recipient
    # list is a schedule that mails the wrong people until somebody notices.
    assert_no_difference ['Schedule.count', 'ScheduleRecipient.count'] do
      post :create, params: { project_id: @project.id,
                              schedule: { repeat: 'daily', start_date: '2026-03-01',
                                          recipient_user_ids: [@other.id.to_s] } }
    end

    assert_response :unprocessable_entity
  end

  # --- updating ------------------------------------------------------------------------

  def test_update_replaces_the_recipient_list_rather_than_adding_to_it
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @other.id)

    patch :update, params: { project_id: @project.id, id: @schedule.id,
                             schedule: { template_id: @template.id, repeat: 'weekly',
                                         start_date: '2026-01-01',
                                         recipient_user_ids: [@author.id.to_s] } }

    assert_redirected_to project_reporter_schedule_path(@project, @schedule)
    assert_equal [@author.id], @schedule.reload.recipients.map(&:user_id)
  end

  def test_run_state_cannot_be_written_from_the_form
    # A form that could write `last_status` could hide a failure. Those columns belong to
    # the runner, and `update_columns` is the only thing that writes them.
    @schedule.update_columns(last_status: Schedule::STATUS_FAILED,
                             last_error: 'the real failure')

    patch :update, params: { project_id: @project.id, id: @schedule.id,
                             schedule: { template_id: @template.id, repeat: 'weekly',
                                         start_date: '2026-01-01',
                                         last_status: 'success', last_error: '',
                                         consecutive_failures: '0' } }

    @schedule.reload
    assert_equal Schedule::STATUS_FAILED, @schedule.last_status
    assert_equal 'the real failure', @schedule.last_error
  end

  def test_clearing_the_query_clears_its_type_too
    query = IssueQuery.create!(name: 'Mine', project: @project, user: @author,
                               visibility: Query::VISIBILITY_PUBLIC)
    @schedule.update_columns(query_id: query.id, query_type: 'IssueQuery')

    patch :update, params: { project_id: @project.id, id: @schedule.id,
                             schedule: { template_id: @template.id, repeat: 'weekly',
                                         start_date: '2026-01-01', query_id: '' } }

    @schedule.reload
    assert_nil @schedule.query_id
    assert_nil @schedule.query_type, 'a type with no id is a row nothing can interpret'
  end

  # --- destroying --------------------------------------------------------------------------

  def test_destroy_removes_the_schedule_and_its_children
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @other.id)
    ScheduleRun.claim(@schedule, Date.new(2026, 3, 10))

    assert_difference 'Schedule.count', -1 do
      delete :destroy, params: { project_id: @project.id, id: @schedule.id }
    end

    assert_redirected_to project_reporter_schedules_path(@project)
    assert_equal 0, ScheduleRecipient.where(schedule_id: @schedule.id).count
    assert_equal 0, ScheduleRun.where(schedule_id: @schedule.id).count
  end

  # --- the test send (FR-45) -----------------------------------------------------------------

  def test_a_test_send_goes_to_the_requester_and_claims_no_occurrence
    # IT CLAIMS NOTHING, and that is the half a naive implementation gets wrong: creating a
    # run row here would consume today's occurrence and leave the real 06:00 run refused by
    # the unique index — silently costing somebody a report.
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @other.id)
    delivered = []
    RedmineReporterDashboards::Reporting::ScheduledDelivery.any_instance
      .stubs(:call).with { |kwargs| delivered << kwargs; true }
      .returns(RedmineReporterDashboards::Scheduling::Runner::Delivered.new(
                 recipients_count: 1, document_count: 1, bytes_total: 10
               ))

    assert_no_difference 'ScheduleRun.count' do
      post :test_send, params: { project_id: @project.id, id: @schedule.id }
    end

    assert_redirected_to project_reporter_schedule_path(@project, @schedule)
    assert_equal [[@author]], delivered.map { |kwargs| kwargs[:recipients] },
                 'a test goes to the person who pressed the button, not to the list'
  end

  def test_a_test_send_uses_the_schedules_stored_identity_and_not_the_requester
    # FR-45, verbatim: "a test send uses the SAME identity as the real run." `@other` is the
    # stored identity and `@author` is pressing the button.
    @schedule.update_columns(render_as: Schedule::RENDER_AS_USER,
                             render_as_user_id: @other.id)
    seen = []
    RedmineReporterDashboards::Reporting::ScheduledDelivery.any_instance
      .stubs(:call).with { |kwargs| seen << kwargs[:actor]; true }
      .returns(RedmineReporterDashboards::Scheduling::Runner::Delivered.new(
                 recipients_count: 1, document_count: 1, bytes_total: 10
               ))

    post :test_send, params: { project_id: @project.id, id: @schedule.id }

    assert_equal [@other], seen
  end

  def test_a_test_send_with_an_unusable_identity_says_so_rather_than_raising
    locked = User.find(5)
    assert_not locked.active?, 'fixture precondition: user 5 is locked'
    @schedule.update_columns(render_as: Schedule::RENDER_AS_USER,
                             render_as_user_id: locked.id)

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      post :test_send, params: { project_id: @project.id, id: @schedule.id }
    end

    assert_redirected_to project_reporter_schedule_path(@project, @schedule)
    assert_match(/not an active account/, flash[:error])
  end

  def test_a_test_send_is_not_reachable_by_GET
    # It puts mail on the wire, so it must not be reachable by following a link, by a
    # prefetcher or by an <img src>. Asked of the ROUTE SET rather than of the controller:
    # a functional test dispatches straight to the action and would answer 200 for a verb
    # no route accepts, which is how this example passed while proving nothing.
    path = "/projects/#{@project.id}/reporter/schedules/#{@schedule.id}/test_send"
    routes = Rails.application.routes

    assert_equal({ controller: 'reporter_dashboards/schedules', action: 'test_send',
                   project_id: @project.id.to_s, id: @schedule.id.to_s },
                 routes.recognize_path(path, method: :post))
    assert_raises(ActionController::RoutingError) do
      routes.recognize_path(path, method: :get)
    end
  end
end
