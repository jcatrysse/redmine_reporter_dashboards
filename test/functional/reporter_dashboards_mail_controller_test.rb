# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-32 / FR-61 — ad-hoc report mail, in the full application.
#
# --- WHY THE LOAD-BEARING HALF OF T-32 IS TESTED HERE AND NOT DB-LESS ---
#
# Every claim FR-61 makes is about something a double cannot fail. "An issue the requester
# cannot see is refused" needs a real private issue, a real `Role#issues_visibility` and a
# real `Issue.visible`; "the sender is server-controlled" needs Redmine's own `Mailer#mail`
# to have run; "every send is audited" needs a row in a database. `spec/reporting/
# mail_policy_spec.rb` covers the decision procedure with no database at all — this file
# covers everything the decision procedure is applied to.
#
# The shape is the one T-25's controller test uses: hold ONE permission, walk every action,
# and assert 403 on what it must not reach. Redmine's `authorize` passes on ANY permission
# mapping an action, so a controller whose permission is deliberately weaker than its
# neighbours (`require: :loggedin`, not `:member`) needs the negative half written down.
class ReporterDashboardsMailControllerTest < Redmine::ControllerTest
  tests ReporterDashboards::MailController

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :email_addresses, :issues, :issue_statuses, :trackers, :enumerations,
           :projects_trackers

  Template = RedmineReporterDashboards::Template
  MailSend = RedmineReporterDashboards::MailSend
  MailSendRecipient = RedmineReporterDashboards::MailSendRecipient

  def setup
    @project = Project.find(1)
    EnabledModule.create!(project: @project, name: 'reporter_dashboards_reports') unless
      @project.module_enabled?(:reporter_dashboards_reports)
    @requester = User.find(2)
    @colleague = User.find(3)
    @role = Role.find(1)
    @template = Template.create!(project: @project, author_id: @requester.id,
                                 name: 'Weekly', content: '<p>hi</p>')

    # `:view_issues` IS PART OF THE BASELINE, and finding out why cost two red tests.
    # `Reporting::ReportScope` starts from `Issue.visible(actor)`, which is empty for a
    # member whose role holds no `:view_issues` — so a "the requester CAN see this one"
    # fixture silently had nothing in it and the refusal test would have passed whether or
    # not the refusal worked. It is granted here so that the visibility tests below
    # discriminate; the authorization tests re-grant what they mean to hold.
    grant(:view_issues, :view_reporter_dashboards_reports,
          :mail_reporter_dashboards_reports)
    reset_settings
    ActionMailer::Base.deliveries.clear
    User.current = nil
    @request.session[:user_id] = @requester.id
  end

  def teardown
    reset_settings
    User.current = nil
  end

  # `Role#permissions=` does not clear a user's memoised permission set, and a stale one
  # turns a 403 example green for the wrong reason. Same helper, same reason, as T-25's.
  def grant(*permissions)
    @role.permissions = permissions
    @role.save!
    @requester = User.find(@requester.id)
    @colleague = User.find(@colleague.id)
  end

  def reset_settings
    Setting.plugin_redmine_reporter_dashboards = {
      'mail_external_addresses' => false, 'mail_external_domains' => '',
      'mail_rate_limit' => '12', 'mail_rate_window_minutes' => '60'
    }
  end

  def with_settings_for_mail(overrides)
    Setting.plugin_redmine_reporter_dashboards =
      (Setting.plugin_redmine_reporter_dashboards || {}).merge(overrides)
  end

  # An adapter answering a valid-looking PDF. There is no browser here, so without one the
  # SUCCESS path — the only path that puts mail on the wire — would never execute and every
  # assertion in this file would be about a failure. Over `Renderer::MIN_PDF_BYTES`, with
  # the magic bytes and the trailer, because `Render::Renderer` enforces both above it.
  class FakeEngine
    def capabilities
      []
    end

    def id
      'fake'
    end

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: "%PDF-1.4\n#{'0' * 2_000}\n%%EOF", engine: 'fake', engine_version: '1.0'
      )
    end
  end

  def with_engine(&block)
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, FakeEngine)
      block.call
    end
  end

  def send_params(extra = {})
    { project_id: @project.id, template_id: @template.id,
      recipient_user_ids: [@colleague.id.to_s] }.merge(extra)
  end

  # ------------------------------------------------------------------ authorization

  # THE CONJUNCTION. `mail_…_reports` carries `require: :loggedin` and says nothing about
  # reading; mailing a report is a way of reading it, so the controller additionally
  # requires `view_…_reports`. Redmine's permission model cannot express "and", so if this
  # test goes green with the guard deleted, the guard was never doing anything.
  def test_the_mail_permission_alone_is_refused
    grant(:mail_reporter_dashboards_reports)

    get :new, params: { project_id: @project.id, template_id: @template.id }
    assert_response 403

    post :create, params: send_params
    assert_response 403
    assert_equal 0, MailSend.count
  end

  def test_the_view_permission_alone_is_refused
    grant(:view_reporter_dashboards_reports)

    get :new, params: { project_id: @project.id, template_id: @template.id }
    assert_response 403

    post :create, params: send_params
    assert_response 403
  end

  def test_both_permissions_together_reach_the_form
    get :new, params: { project_id: @project.id, template_id: @template.id }

    assert_response :success
  end

  def test_a_project_without_the_reports_module_404s
    EnabledModule.where(project_id: @project.id,
                        name: 'reporter_dashboards_reports').delete_all

    get :new, params: { project_id: @project.id, template_id: @template.id }
    assert_response 404
  end

  # 404 AND NOT 403 FOR AN INVISIBLE TEMPLATE — a 403 confirms the row exists, and a
  # private template's existence is the thing being protected. Same rule as
  # `TemplatesController#find_template`.
  def test_a_template_this_actor_cannot_see_404s
    private_template = Template.create!(project: @project, author_id: @colleague.id,
                                        name: 'Theirs', content: 'x',
                                        visibility: Template::VISIBILITY_PRIVATE)

    get :new, params: { project_id: @project.id, template_id: private_template.id }
    assert_response 404
  end

  # ------------------------------------------------------------------ the GET sends nothing

  # A GET THAT PUT MAIL ON THE WIRE would be fireable by a crawler, a prefetching proxy or
  # an `<img src>`. The route declares GET for the form and POST for the send; this asserts
  # the form itself has no side effect, which is the half a route cannot state.
  def test_the_compose_form_sends_nothing_and_writes_no_audit_row
    with_engine do
      get :new, params: { project_id: @project.id, template_id: @template.id }
    end

    assert_response :success
    assert_equal 0, ActionMailer::Base.deliveries.length
    assert_equal 0, MailSend.count
  end

  # ------------------------------------------------------------------ visibility

  # THE CLAUSE T-32'S `Accept:` NAMES: "a test asserts an issue the requester cannot see is
  # REFUSED, not silently included".
  #
  # It asserts BOTH failure modes, because they are different defects and only one of them
  # is the base plugin's. Silently INCLUDING it is `Issue.where(id: params[:issue_ids])`
  # with no visibility check. Silently DROPPING it is the plausible-looking fix: the
  # requester asks for a report over two issues, gets one covering one, and nothing says
  # which is missing or why.
  def test_an_issue_the_requester_cannot_see_refuses_the_whole_send
    hidden = issue_the_requester_cannot_see
    visible = Issue.visible(@requester).where(project_id: @project.id).first
    assert visible, 'the fixture must give the requester at least one visible issue'

    with_engine do
      post :create, params: send_params(issue_ids: "#{visible.id},#{hidden.id}")
    end

    assert_response :unprocessable_entity
    # REFUSED, not partially fulfilled.
    assert_equal 0, ActionMailer::Base.deliveries.length
    # The audit records the attempt and says it failed — a refused send is still something
    # that happened, and the rate limit counts it.
    send_row = MailSend.order(:id).last
    assert_equal MailSend::STATUS_FAILED, send_row.status
    assert_includes send_row.error.to_s, 'issues_not_visible'
  end

  def test_naming_only_visible_issues_sends
    visible = Issue.visible(@requester).where(project_id: @project.id).first

    with_engine do
      post :create, params: send_params(issue_ids: visible.id.to_s)
    end

    assert_response :redirect
    assert_equal 1, ActionMailer::Base.deliveries.length
  end

  # ------------------------------------------------------------------ the sender

  # §7b.5: "`From` is server-controlled … the requester's address goes in `Reply-To`."
  #
  # Asserted on the MESSAGE rather than on the mailer's source, because Redmine's
  # `Mailer#mail` merges its `From` with `reverse_merge!` — a caller-supplied header would
  # WIN — so the only thing that proves nothing supplied one is the header that came out.
  def test_the_sender_is_the_installations_and_the_requester_is_in_reply_to
    with_engine do
      post :create, params: send_params
    end

    assert_response :redirect
    mail = ActionMailer::Base.deliveries.last
    assert mail, 'nothing was delivered'
    assert_equal [Setting.mail_from], mail.from
    assert_equal [@requester.mail], mail.reply_to
    assert_equal [@colleague.mail], mail.to
    assert_equal 1, mail.attachments.length
  end

  # THE ABSENCE OF A PARAMETER IS THE MECHANISM, so it is asserted as an absence. A future
  # edit adding a `from:` to either mailer action has to delete this test to pass.
  def test_no_mailer_action_takes_anything_a_sender_could_travel_in
    %i[adhoc_report adhoc_report_to_address].each do |action|
      names = ReporterDashboardsMailer.instance_method(action).parameters.map(&:last)

      %i[from sender headers reply_to options].each do |forbidden|
        assert_not_includes names, forbidden,
                            "#{action} takes #{forbidden}, which is a channel for a forged sender"
      end
    end
  end

  # ------------------------------------------------------------------ the audit

  def test_a_send_is_audited_with_who_when_which_template_and_which_recipients
    with_engine do
      post :create, params: send_params(issue_ids: '')
    end

    row = MailSend.order(:id).last
    assert row, 'no audit row was written'
    assert_equal @requester.id, row.author_id
    assert_equal @project.id, row.project_id
    assert_equal @template.id, row.template_id
    # THE NAME IS COPIED, not read through the association: a renamed or deleted template
    # must not make the audit describe something other than what was sent.
    assert_equal 'Weekly', row.template_name
    assert_equal MailSend::STATUS_SUCCESS, row.status
    assert_equal 1, row.recipients_count
    assert_equal 0, row.external_count
    assert row.correlation_id.present?
    assert row.finished_at.present?
    assert_equal [@colleague.id], row.recipients.map(&:user_id)
    # A REDMINE RECIPIENT STORES NO ADDRESS. The column exists for the allowlisted external
    # case and the common send must not populate it.
    assert_equal [nil], row.recipients.map(&:address)
  end

  # THE AUDIT OUTLIVES ITS SUBJECT. A template deleted next March must not take the record
  # of what it mailed with it — the same argument T-22 made for documents.
  def test_the_audit_row_survives_its_template_being_deleted
    with_engine { post :create, params: send_params }
    row = MailSend.order(:id).last

    @template.destroy

    row.reload
    assert_equal 'Weekly', row.template_name
    assert_nil row.template_id
  end

  def test_the_audit_list_shows_an_admin_every_row_and_a_member_only_their_own
    with_engine { post :create, params: send_params }
    MailSend.claim(author_id: @colleague.id, project_id: @project.id,
                   template_id: @template.id, template_name: 'Theirs',
                   created_at: Time.now)

    get :index, params: { project_id: @project.id }
    assert_response :success
    assert_equal [@requester.id], assigns(:mail_sends).map(&:author_id).uniq

    @request.session[:user_id] = User.find(1).id
    assert User.find(1).admin?, 'user 1 must be an administrator for this test to mean anything'
    get :index, params: { project_id: @project.id }
    assert_response :success
    assert_equal [@requester.id, @colleague.id].sort,
                 assigns(:mail_sends).map(&:author_id).uniq.sort
  end

  # ------------------------------------------------------------------ external addresses

  def test_an_external_address_is_refused_when_the_setting_is_off
    with_engine do
      post :create, params: send_params(recipient_user_ids: [],
                                        recipient_addresses: 'someone@example.com')
    end

    assert_response :unprocessable_entity
    assert_equal 0, ActionMailer::Base.deliveries.length
  end

  # THE DROP IS AS BAD AS THE SEND. Refusing the external address while mailing the
  # Redmine users in the same request would leave the requester believing everybody got it.
  def test_a_refused_external_address_does_not_silently_send_to_the_redmine_users
    with_engine do
      post :create, params: send_params(recipient_addresses: 'someone@example.com')
    end

    assert_response :unprocessable_entity
    assert_equal 0, ActionMailer::Base.deliveries.length
  end

  def test_an_allowlisted_external_address_is_delivered_and_audited_with_the_address
    with_settings_for_mail('mail_external_addresses' => '1',
                           'mail_external_domains' => 'example.com')

    with_engine do
      post :create, params: send_params(recipient_user_ids: [],
                                        recipient_addresses: 'someone@example.com')
    end

    assert_response :redirect
    mail = ActionMailer::Base.deliveries.last
    assert_equal ['someone@example.com'], mail.to
    assert_equal [Setting.mail_from], mail.from

    row = MailSend.order(:id).last
    assert_equal 1, row.external_count
    # THE ADDRESS IS THE POINT OF THE AUDIT. An auditor asking "has anything gone to
    # example.com" is asking exactly this, and a count cannot answer it.
    assert_equal ['someone@example.com'], row.recipients.map(&:address)
  end

  # WHY THIS EXISTS: MUTATION TESTING SAID THE CONTROLLER'S CHECK WAS NOT LOAD-BEARING.
  #
  # Deleting `resolve_recipients`' external checks left the whole file GREEN, because
  # `AdhocDelivery` re-checks the same policy and refuses too — two mechanisms for one
  # property, neither individually killable, which is the shape T-25 deleted rather than
  # kept. Both are worth keeping HERE (the delivery is a separate object with its own
  # callers), so what was missing was the observable that separates them.
  #
  # It is the AUDIT ROW. The controller refuses BEFORE claiming one; the delivery can only
  # refuse after. So a request whose addresses were never permissible must cost nothing —
  # no row, and therefore no quota, which matters because the quota is what a refused
  # requester has to wait out.
  def test_a_disallowed_address_is_refused_before_any_audit_row_is_claimed
    with_engine do
      post :create, params: send_params(recipient_addresses: 'someone@example.com')
    end

    assert_response :unprocessable_entity
    assert_equal 0, MailSend.count,
                 'a request refused before any work must not consume the quota it was refused by'
  end

  def test_an_address_outside_the_allowlist_is_refused_before_any_audit_row_is_claimed
    with_settings_for_mail('mail_external_addresses' => '1',
                           'mail_external_domains' => 'example.com')

    with_engine do
      post :create, params: send_params(recipient_addresses: 'someone@elsewhere.com')
    end

    assert_response :unprocessable_entity
    assert_equal 0, MailSend.count
  end

  # AND THE DELIVERY'S OWN RE-CHECK, driven DIRECTLY — because through the controller it is
  # unreachable (the controller refuses first), so mutation testing proved it dead on that
  # path. It is not decoration: `AdhocDelivery` is a separate object, T-32 is not its only
  # future caller, and HANDOVER §1's rule is that the caller is not the check. This is the
  # test that makes it a live guard rather than a comment.
  def test_the_delivery_refuses_a_disallowed_address_on_its_own
    # BRACED, and HANDOVER §1 is why: `from_settings(settings, logger: nil)` declares a
    # keyword parameter, so a trailing BARE hash is parsed as keywords and the method is
    # called with no positional argument at all. It cost T-16 two rounds in two files.
    policy = RedmineReporterDashboards::Reporting::MailPolicy
             .from_settings({ 'mail_external_addresses' => '1',
                              'mail_external_domains' => 'example.com' })
    # NOT an endless method definition (`def self.sent = …`). That is Ruby 3.0 syntax and
    # this plugin's floor is 2.7 — `.codex/check_ruby_floor.sh` catches it, and HANDOVER
    # records it catching exactly this in a T-31 test.
    mailer = Class.new do
      class << self
        def sent
          @sent ||= []
        end

        def deliver_adhoc_report(*)
          sent << :user
        end

        def deliver_adhoc_report_to_address(*)
          sent << :address
        end
      end
    end
    row = MailSend.claim(author_id: @requester.id, project_id: @project.id,
                         template_id: @template.id, created_at: Time.now)

    result = RedmineReporterDashboards::Reporting::AdhocDelivery
             .new(mailer: mailer, policy: policy)
             .call(template: @template, actor: @requester, project: @project,
                   mail_send: row, recipient_addresses: ['someone@elsewhere.com'])

    assert_not result.ok?
    assert_equal :external_not_permitted, result.code
    assert_equal [], mailer.sent
  end

  def test_an_address_outside_the_allowlist_is_refused
    with_settings_for_mail('mail_external_addresses' => '1',
                           'mail_external_domains' => 'example.com')

    with_engine do
      post :create, params: send_params(recipient_user_ids: [],
                                        recipient_addresses: 'someone@elsewhere.com')
    end

    assert_response :unprocessable_entity
    assert_equal 0, ActionMailer::Base.deliveries.length
  end

  # THE COLLAPSE, END TO END. Ticked box, empty allowlist: no external address is accepted.
  def test_an_empty_allowlist_refuses_every_external_address_even_when_enabled
    with_settings_for_mail('mail_external_addresses' => '1', 'mail_external_domains' => '')

    with_engine do
      post :create, params: send_params(recipient_user_ids: [],
                                        recipient_addresses: 'someone@example.com')
    end

    assert_response :unprocessable_entity
    assert_equal 0, ActionMailer::Base.deliveries.length
  end

  # ------------------------------------------------------------------ the rate limit

  def test_the_rate_limit_refuses_once_it_is_reached
    with_settings_for_mail('mail_rate_limit' => '1')

    with_engine { post :create, params: send_params }
    assert_response :redirect
    assert_equal 1, ActionMailer::Base.deliveries.length

    with_engine { post :create, params: send_params }
    assert_response :unprocessable_entity
    assert_equal 1, ActionMailer::Base.deliveries.length
  end

  # THE LIMIT COUNTS ATTEMPTS, NOT SUCCESSES, and this is the example that separates the
  # two. A failing render costs the worker exactly what a working one does, so a limit that
  # only counted completed sends would not bound the cost of a template that fails.
  #
  # THE FAILURE HAS TO BE ONE THAT GOT AS FAR AS RENDERING, and the first version of this
  # test used "no recipients" and went green for the wrong reason — that refusal happens in
  # the controller BEFORE the row is claimed, so it consumed nothing and the second send
  # succeeded. That is the intended split and the test below asserts it directly: a request
  # refused before any work is done must not consume the quota it was refused by, or a
  # rate-limited user can never recover.
  def test_a_render_failure_still_counts_against_the_limit
    with_settings_for_mail('mail_rate_limit' => '1')
    @template.update_columns(source: 'nonsense')

    post :create, params: send_params
    assert_response :unprocessable_entity
    assert_equal 1, MailSend.count, 'a render failure must still be audited'

    @template.update_columns(source: 'issues')
    with_engine { post :create, params: send_params }

    assert_response :unprocessable_entity
    assert_equal 0, ActionMailer::Base.deliveries.length
  end

  # A REFUSED REQUEST MUST NOT CONSUME THE QUOTA IT WAS REFUSED BY, or a rate-limited user
  # can never recover: every attempt would add a row and push the window out.
  def test_a_rate_limited_request_writes_no_audit_row
    with_settings_for_mail('mail_rate_limit' => '1')
    with_engine { post :create, params: send_params }
    before = MailSend.count

    with_engine { post :create, params: send_params }

    assert_equal before, MailSend.count
  end

  def test_a_zero_limit_switches_ad_hoc_mail_off
    with_settings_for_mail('mail_rate_limit' => '0')

    with_engine { post :create, params: send_params }

    assert_response :unprocessable_entity
    assert_equal 0, ActionMailer::Base.deliveries.length
  end

  # ------------------------------------------------------------------ failures

  def test_a_send_with_no_recipient_is_refused_and_mails_nobody
    with_engine do
      post :create, params: send_params(recipient_user_ids: [])
    end

    assert_response :unprocessable_entity
    assert_equal 0, ActionMailer::Base.deliveries.length
  end

  # FR-61's last clause: "a render failure produces a failure notice, never a mail with a
  # broken attachment." Nobody is mailed at all — the requester is standing here and reads
  # the diagnostics panel, which is the notice.
  def test_a_render_failure_mails_nobody_and_shows_the_diagnostic
    @template.update_columns(content: '{% sql_aggregate %}{% endsql_aggregate %}',
                             source: 'nonsense')

    post :create, params: send_params

    assert_response :unprocessable_entity
    assert_equal 0, ActionMailer::Base.deliveries.length
    row = MailSend.order(:id).last
    assert_equal MailSend::STATUS_FAILED, row.status
  end

  private

  # A PRIVATE issue in THIS project, authored by somebody else.
  #
  # --- WHY IT IS BUILT HERE RATHER THAN PICKED OUT OF THE FIXTURES ---
  #
  # The first version took "an issue in another project" and the assertion below caught it:
  # fixture issue 6 is in a PUBLIC project, so `Issue.visible(@requester)` includes it and
  # the refusal test would have gone green whether or not the refusal worked. That is the
  # "what would still pass if the rule were deleted" question T-23's actor matrix exists
  # to ask, and it is also HANDOVER §1's warning about building a fixture on the ABSENCE of
  # rows — which fixture sets another test class declared is not something this file
  # controls.
  #
  # A private issue with `issues_visibility = 'default'` is invisible by a rule the test
  # sets itself: not author, not assignee, and no `view_private_issues`. The assertion is
  # kept anyway, because a fixture that stops discriminating must fail loudly rather than
  # quietly prove nothing.
  def issue_the_requester_cannot_see
    @role.issues_visibility = 'default'
    @role.save!
    @requester = User.find(@requester.id)

    hidden = Issue.generate!(project: @project, author: User.find(1), is_private: true,
                             subject: 'not for you')

    assert_not Issue.visible(@requester).exists?(hidden.id),
               "issue #{hidden.id} is visible to the requester, so this test proves nothing"
    hidden
  end
end
