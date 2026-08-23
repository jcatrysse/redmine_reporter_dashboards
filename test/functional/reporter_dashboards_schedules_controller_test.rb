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

  def test_manage_alone_can_both_write_and_read
    # `#index`/`#show` are mapped into `manage_` as well, and leaving them out made the
    # permission unusable alone: a role holding it created a schedule and was answered 403
    # on the redirect to it, with no menu entry either. Redmine's `manage_public_queries`
    # does not stand alone in that sense. The SPLIT is unaffected — `view_` still grants
    # read-only, and holding it still changes nothing about who receives a report.
    grant(:view_reporter_dashboards_reports, :manage_reporter_dashboards_schedules)

    get :new, params: { project_id: @project.id }
    assert_response :success

    get :index, params: { project_id: @project.id }
    assert_response :success

    get :show, params: { project_id: @project.id, id: @schedule.id }
    assert_response :success
  end

  def test_creating_a_schedule_lands_somewhere_the_creator_can_actually_read
    # The bug the mapping above fixes, asserted end to end rather than by inspecting a list.
    grant(:view_reporter_dashboards_reports, :manage_reporter_dashboards_schedules)

    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01' } }
    assert_response :redirect
    schedule = Schedule.order(:id).last

    get :show, params: { project_id: @project.id, id: schedule.id }
    assert_response :success
  end

  def test_the_explicit_manage_guard_holds_when_the_action_map_does_not
    # THE GUARD THE CLASS COMMENT IS ABOUT, and it had ZERO coverage: every 403 example
    # above is satisfied by the action map alone, so `require_manage_permission` could be
    # DELETED OUTRIGHT and all 23 examples passed. An independent review measured that. The
    # comment argues the guard is what holds the line when somebody widens the map — so this
    # widens the map and asserts the guard still refuses.
    grant(:view_reporter_dashboards_schedules)
    permission = Redmine::AccessControl.permission(:view_reporter_dashboards_schedules)
    widened = permission.actions + ['reporter_dashboards/schedules/destroy',
                                    'reporter_dashboards/schedules/test_send']
    permission.stubs(:actions).returns(widened)

    delete :destroy, params: { project_id: @project.id, id: @schedule.id }
    assert_response :forbidden

    post :test_send, params: { project_id: @project.id, id: @schedule.id }
    assert_response :forbidden
  end

  # --- the render identity, which decides whose visibility the SQL runs under -----------

  def test_a_member_cannot_bind_a_schedule_to_somebody_elses_identity
    # THE BLOCKER. `render_as_user_id` was in `permit` and filtered against nothing: a
    # member holding `manage_…_schedules` posted `render_as_user_id=1`, pressed Send a test,
    # and received an ADMINISTRATOR-visibility report in their own inbox. An independent
    # review reproduced it against a private issue the attacker could not see.
    admin = User.find(1)
    assert admin.admin?, 'fixture precondition'

    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01',
                                        render_as: 'user',
                                        render_as_user_id: admin.id.to_s } }

    assert_response :unprocessable_entity
    assert_nil Schedule.order(:id).last.render_as_user_id
  end

  def test_the_identity_cannot_be_planted_under_a_benign_policy_and_activated_later
    # The two-step variant the review also found: the id was stored even while the policy
    # said `author`, so it could be planted first and the policy flipped by a later request
    # that never mentions the id.
    admin = User.find(1)

    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01',
                                        render_as: 'author',
                                        render_as_user_id: admin.id.to_s } }
    assert_response :redirect
    schedule = Schedule.order(:id).last
    assert_nil schedule.render_as_user_id, 'nothing is stored under a benign policy'

    patch :update, params: { project_id: @project.id, id: schedule.id,
                             schedule: { template_id: @template.id, repeat: 'daily',
                                         start_date: '2026-03-01', render_as: 'user' } }

    assert_response :unprocessable_entity
    assert_nil schedule.reload.render_as_user_id
  end

  def test_a_member_cannot_bind_a_schedule_to_another_MEMBERS_identity
    # "A PROJECT MEMBER" IS NOT A SAFE BOUND, and the example above does not prove that: it
    # targets an administrator, who is not a member of this project, so widening the bound to
    # `@project.users` leaves it green. Measured. Every member with wider visibility than
    # yours — a lead who can see private issues you cannot — is an escalation target, which
    # is the whole of the finding. `@other` IS a member of project 1.
    assert_includes @project.users.map(&:id), @other.id, 'fixture precondition'

    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01', render_as: 'user',
                                        render_as_user_id: @other.id.to_s } }

    assert_response :unprocessable_entity
    assert_nil Schedule.order(:id).last.render_as_user_id
  end

  def test_a_member_may_render_as_themselves
    # The bound is "yourself, or anybody if you are an administrator" — §7b.5's rule applied
    # to this field: you can only mail what you can see.
    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01', render_as: 'user',
                                        render_as_user_id: @author.id.to_s } }

    assert_response :redirect
    assert_equal @author.id, Schedule.order(:id).last.render_as_user_id
  end

  def test_the_render_as_others_permission_is_what_widens_the_bound
    # THE CURATOR'S ANSWER TO S-10: a permission, granted per role per project, whose label
    # says what it really grants. Same role, same request, one extra checkbox.
    grant(:view_reporter_dashboards_reports, :view_reporter_dashboards_schedules,
          :manage_reporter_dashboards_schedules,
          :render_reporter_dashboards_reports_as_others)

    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01', render_as: 'user',
                                        render_as_user_id: @other.id.to_s } }

    assert_response :redirect
    assert_equal @other.id, Schedule.order(:id).last.render_as_user_id
  end

  def test_the_permission_alone_lets_you_do_nothing
    # It maps no action, deliberately: it widens a field behind `manage_…_schedules` rather
    # than opening a door. Mapping it would make it sufficient for `authorize` on actions it
    # is not sufficient for.
    grant(:render_reporter_dashboards_reports_as_others)

    get :index, params: { project_id: @project.id }
    assert_response :forbidden

    get :new, params: { project_id: @project.id }
    assert_response :forbidden
  end

  def test_the_bound_is_still_the_project_even_with_the_permission
    # The permission authorises borrowing a colleague's visibility, not naming an arbitrary
    # account: an administrator who is not a member of this project is still not offered,
    # because the schedule's blast radius is the project it lives in.
    grant(:view_reporter_dashboards_reports, :view_reporter_dashboards_schedules,
          :manage_reporter_dashboards_schedules,
          :render_reporter_dashboards_reports_as_others)
    outsider = User.find(4)
    assert_not_includes @project.users.map(&:id), outsider.id, 'fixture precondition'

    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01', render_as: 'user',
                                        render_as_user_id: outsider.id.to_s } }

    assert_response :unprocessable_entity
    assert_nil Schedule.order(:id).last.render_as_user_id
  end

  def test_an_administrator_may_render_as_another_member_without_the_permission
    # Not a second rule — `User#allowed_to?` answers `return true if admin?` for every
    # permission (user.rb:378), so the administrator exemption falls out of Redmine's own
    # model rather than from a hand-written `|| User.current.admin?` that could drift from it.
    @request.session[:user_id] = 1

    post :create, params: { project_id: @project.id,
                            schedule: { template_id: @template.id, repeat: 'daily',
                                        start_date: '2026-03-01', render_as: 'user',
                                        render_as_user_id: @other.id.to_s } }

    assert_response :redirect
    assert_equal @other.id, Schedule.order(:id).last.render_as_user_id
  end

  def test_a_test_send_of_somebody_elses_identity_is_refused
    # THE SECOND BLOCKER, and it needed no tampering at all: any schedule authored by an
    # administrator could be test-sent by any `manage_…_schedules` holder, and the output
    # landed in the presser's mailbox. FR-45 says a test renders as the stored identity, so
    # the OTHER half gives way — you may test-send only a schedule that renders as you.
    @schedule.update_columns(render_as: Schedule::RENDER_AS_USER,
                             render_as_user_id: @other.id)

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      post :test_send, params: { project_id: @project.id, id: @schedule.id }
    end

    assert_response :forbidden
  end

  def test_the_same_permission_is_what_allows_test_sending_somebody_elses_identity
    # ONE CAPABILITY, ONE GRANT. Binding a schedule to another identity and reading that
    # identity's report on demand are the same thing exercised twice — two permissions would
    # let an administrator hand out half of it and believe they had withheld the other half.
    @schedule.update_columns(render_as: Schedule::RENDER_AS_USER,
                             render_as_user_id: @other.id)
    grant(:view_reporter_dashboards_reports, :view_reporter_dashboards_schedules,
          :manage_reporter_dashboards_schedules,
          :render_reporter_dashboards_reports_as_others)
    RedmineReporterDashboards::Reporting::ScheduledDelivery.any_instance
      .stubs(:call)
      .returns(RedmineReporterDashboards::Scheduling::Runner::Delivered.new(
                 recipients_count: 1, document_count: 1, bytes_total: 10
               ))

    post :test_send, params: { project_id: @project.id, id: @schedule.id }

    assert_redirected_to project_reporter_schedule_path(@project, @schedule)
  end

  def test_an_administrator_may_test_send_any_schedule
    @schedule.update_columns(render_as: Schedule::RENDER_AS_USER,
                             render_as_user_id: @other.id)
    @request.session[:user_id] = 1
    RedmineReporterDashboards::Reporting::ScheduledDelivery.any_instance
      .stubs(:call)
      .returns(RedmineReporterDashboards::Scheduling::Runner::Delivered.new(
                 recipients_count: 1, document_count: 1, bytes_total: 10
               ))

    post :test_send, params: { project_id: @project.id, id: @schedule.id }

    assert_redirected_to project_reporter_schedule_path(@project, @schedule)
  end

  def test_a_failed_test_send_does_not_mail_the_schedules_owner
    # The class comment and the confirmation dialog both promise a test "goes only to you",
    # in nine languages. On the failure path it mailed the OWNER — telling them their
    # SCHEDULED run had failed when no run happened, once per click.
    @template.update_columns(content: '{% this is not a tag %}')
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @other.id)

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      post :test_send, params: { project_id: @project.id, id: @schedule.id }
    end

    assert_match(/could not be sent/, flash[:error])
  end

  def test_a_delivery_that_raises_is_a_flash_and_not_a_500
    # `ScheduledDelivery` states its own contract — "it may also raise" — and `Runner`
    # honours it. This did not: an MTA outage gave the operator a Redmine 500 page instead
    # of the flash this action exists to produce.
    RedmineReporterDashboards::Reporting::ScheduledDelivery.any_instance
      .stubs(:call).raises(RuntimeError, 'smtp exploded')

    post :test_send, params: { project_id: @project.id, id: @schedule.id }

    assert_redirected_to project_reporter_schedule_path(@project, @schedule)
    assert_match(/smtp exploded/, flash[:error])
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

  def test_a_patch_that_does_not_mention_recipients_keeps_them
    # "Absent" and "empty" are not the same request. `requested_recipient_ids` returned `[]`
    # for both, so any partial update — a future inline toggle, a REST client, a renamed
    # field — silently deleted the distribution list and answered "Successful update".
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @other.id)

    patch :update, params: { project_id: @project.id, id: @schedule.id,
                             schedule: { enabled: '0' } }

    assert_response :redirect
    assert_equal [@other.id], @schedule.reload.recipients.map(&:user_id)
  end

  def test_an_empty_recipient_list_still_clears_it
    # The other half: an emptied list must still clear it, or the form could never remove
    # the last recipient.
    #
    # `['']` AND NOT `[]`, and the difference is the whole reason the partial carries a
    # hidden blank: Rails drops an empty array from the parameters entirely, so `[]` over
    # HTTP is indistinguishable from "not requested" — a browser with nothing selected sends
    # no key at all. The hidden element is what makes an emptied list expressible, and this
    # is the request it produces. (An assertion on the literal `[]` was written here first
    # and failed, which is how the distinction got pinned down.)
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @other.id)

    patch :update, params: { project_id: @project.id, id: @schedule.id,
                             schedule: { template_id: @template.id, repeat: 'weekly',
                                         start_date: '2026-01-01',
                                         recipient_user_ids: [''] } }

    assert_response :redirect
    assert_empty @schedule.reload.recipients
  end

  def test_clearing_the_template_fails_rather_than_keeping_the_old_one
    # `return if id.blank?` did the exact thing its own comment refused — clearing the
    # picker and saving returned "Successful update" and changed nothing, which also kept an
    # invisible template attached to a schedule its editor cannot see.
    patch :update, params: { project_id: @project.id, id: @schedule.id,
                             schedule: { template_id: '', repeat: 'weekly',
                                         start_date: '2026-01-01' } }

    assert_response :unprocessable_entity
    assert_equal @template.id, @schedule.reload.template_id, 'and nothing was written'
  end

  def test_a_query_from_another_project_is_refused
    # The picker offers this project's and global queries; the controller used only
    # `IssueQuery.visible`, so a schedule in project A could be bound to a query scoped to
    # project B — a report silently covering a different project than the one whose
    # permissions were checked to create it.
    other_project = Project.find(2)
    foreign = IssueQuery.create!(name: 'Elsewhere', project: other_project, user: @author,
                                 visibility: Query::VISIBILITY_PUBLIC)

    patch :update, params: { project_id: @project.id, id: @schedule.id,
                             schedule: { template_id: @template.id, repeat: 'weekly',
                                         start_date: '2026-01-01',
                                         query_id: foreign.id.to_s } }

    assert_nil @schedule.reload.query_id
    assert_nil @schedule.query_type
  end

  # --- what the pages show, and what they must not ---------------------------------------

  def test_the_edit_form_round_trips_without_the_operator_touching_anything
    # THE EXAMPLE THAT WOULD HAVE CAUGHT THE PICKER BUG. `principals_options_for_select`
    # compares an Integer id to a String, so the identity option was never marked selected:
    # the browser showed blank, and pressing Save posted an empty id — every schedule using
    # the policy FR-45 exists for was uneditable until somebody re-picked the identity by
    # hand, on the one field where a mis-click changes whose data is mailed.
    @schedule.update_columns(render_as: Schedule::RENDER_AS_USER,
                             render_as_user_id: @author.id)

    get :edit, params: { project_id: @project.id, id: @schedule.id }
    assert_response :success
    assert_select "select#schedule_render_as_user_id option[selected][value=?]",
                  @author.id.to_s

    # And what that form posts back is accepted unchanged.
    patch :update, params: { project_id: @project.id, id: @schedule.id,
                             schedule: { template_id: @template.id, repeat: 'weekly',
                                         start_date: '2026-01-01', render_as: 'user',
                                         render_as_user_id: @author.id.to_s } }
    assert_response :redirect
    assert_equal @author.id, @schedule.reload.render_as_user_id
  end

  def test_the_recipient_selection_survives_a_failed_save
    # Every other field survived a 422 and the one that takes eight clicks did not, because
    # the partial read the unsaved record's association.
    post :create, params: { project_id: @project.id,
                            schedule: { repeat: 'daily', start_date: '2026-03-01',
                                        email_subject: 'Keep me',
                                        recipient_user_ids: [@other.id.to_s] } }

    assert_response :unprocessable_entity
    assert_select "select#schedule_recipient_user_ids option[selected][value=?]",
                  @other.id.to_s
  end

  def test_a_private_templates_name_is_not_disclosed_to_a_viewer
    # `TemplatesController#find_template` renders 404 for a template that is not visible, so
    # the plugin has already decided its existence is protected — and these pages printed
    # its NAME as the heading and as every row link, to any `view_…_schedules` holder.
    secret = Template.create!(project: @project, author_id: @other.id, name: 'Q3 LAYOFFS',
                              visibility: Template::VISIBILITY_PRIVATE)
    @schedule.update_columns(template_id: secret.id)
    grant(:view_reporter_dashboards_schedules)
    assert_not secret.visible?(@author), 'fixture precondition'

    get :index, params: { project_id: @project.id }
    assert_response :success
    assert_not_includes response.body, 'Q3 LAYOFFS'

    get :show, params: { project_id: @project.id, id: @schedule.id }
    assert_response :success
    assert_not_includes response.body, 'Q3 LAYOFFS'
  end

  def test_no_page_renders_a_missing_translation
    # `field_enabled` existed neither in Redmine core nor in any of the nine locale files,
    # so `#show` printed the raw I18n miss as a table header. The suite rendered that page
    # three times and never looked.
    get :index, params: { project_id: @project.id }
    assert_not_includes response.body, 'ranslation missing'

    get :show, params: { project_id: @project.id, id: @schedule.id }
    assert_not_includes response.body, 'ranslation missing'

    get :new, params: { project_id: @project.id }
    assert_not_includes response.body, 'ranslation missing'

    get :edit, params: { project_id: @project.id, id: @schedule.id }
    assert_not_includes response.body, 'ranslation missing'
  end

  def test_a_schedule_whose_author_is_gone_says_so_rather_than_showing_a_blank
    # `link_to_user(nil)` returns `""`, which is truthy, so the `||` fallback could never
    # fire — nine translations for a branch that was unreachable on the path that needs it
    # most: a schedule whose author account was removed is what an operator opens this page
    # to diagnose.
    @schedule.update_columns(author_id: 999_999)

    get :show, params: { project_id: @project.id, id: @schedule.id }

    assert_response :success
    assert_includes response.body, I18n.t(:text_reporter_schedule_identity_missing)
  end

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
    # stored identity and somebody else is pressing the button.
    #
    # THE PRESSER HOLDS `render_…_as_others`, which is the grant that makes pressing this
    # button on somebody else's identity legitimate at all. Without it this is the second
    # blocker an independent review found — the output landed in the presser's mailbox with
    # somebody else's visibility in it. FR-45 still holds for the authorised case, and this
    # is what asserts it.
    @schedule.update_columns(render_as: Schedule::RENDER_AS_USER,
                             render_as_user_id: @other.id)
    grant(:view_reporter_dashboards_reports, :view_reporter_dashboards_schedules,
          :manage_reporter_dashboards_schedules,
          :render_reporter_dashboards_reports_as_others)
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
