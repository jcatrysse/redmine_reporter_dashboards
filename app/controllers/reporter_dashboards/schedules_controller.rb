# frozen_string_literal: true

module ReporterDashboards
  # T-25's UI — and the reason the two permissions guarding it are SPLIT.
  #
  # §4.1 gives scheduling two permissions where one would have done, and T-25's `Accept:`
  # says why in a sentence: *"the split exists so an operator can answer 'did it run'
  # without being able to change who receives it."* That is the whole design of this
  # controller. Reading a schedule's run state is a support question; changing its
  # recipients is a decision about who sees somebody's numbers, and the second is not a
  # milder form of the first.
  #
  #   view_reporter_dashboards_schedules    index, show                    read: true
  #   manage_reporter_dashboards_schedules  new create edit update destroy test_send
  #
  # `#test_send` sits with `manage_` rather than with `view_`, and that placement is the
  # one worth arguing: it is the only action in the plugin that puts mail on the wire
  # without a schedule firing. A read permission that could send e-mail would not be a read
  # permission.
  #
  # --- AUTHORIZATION IS PER ACTION, AND `authorize` IS ONLY THE FIRST HALF ---
  #
  # Same shape as `TemplatesController`, same reasons. `before_action :authorize` is
  # UNSCOPED — no `only:`, no `except:`, no `skip_before_action` — because the review of
  # T-40 defeated a per-controller check with exactly those two lines, and
  # `spec/permissions/permission_map_spec.rb` now reads them out of the AST.
  #
  # The second half is `require_manage_permission`. Redmine's `authorize` passes when the
  # actor holds ANY permission mapping the action, and both permissions here map into the
  # same controller — so without it a holder of `view_…_schedules` alone would be stopped
  # only by the action map, which is a list somebody edits. The explicit guard says the
  # rule in the place the rule is about.
  #
  # --- WHAT THIS CONTROLLER DELIBERATELY DOES NOT LET YOU DO ---
  #
  # There is no field for a free-text recipient, a `from`, a `cc` or a `bcc`, and there is
  # no column behind one either. §7b.5's finding about the base plugin is *"a report over
  # any issue in the instance, mailed anywhere, with a forged sender"*; the answer is a
  # schema and a form that cannot express it, rather than a validation that rejects it.
  class SchedulesController < ApplicationController
    # The plugin's `lib/` is not on Redmine's autoload paths; these are shorter names for
    # constants `lib/redmine_reporter_dashboards.rb` required at boot.
    Reporting = RedmineReporterDashboards::Reporting
    Scheduling = RedmineReporterDashboards::Scheduling
    Schedule = RedmineReporterDashboards::Schedule
    Template = RedmineReporterDashboards::Template

    # DECLARED, because Redmine sets `include_all_helpers = false` — a controller sees its
    # OWN helper and nothing else. `reporter_dashboard_icon` is the D-3 shim (`sprite_icon`
    # exists on Redmine 6+ and raises on 5.1) and lives in the dashboard's helper.
    helper :reporter_project_pages

    before_action :find_project_by_project_id
    before_action :require_reports_module
    before_action :authorize
    before_action :find_schedule, only: [:show, :edit, :update, :destroy, :test_send]
    before_action :require_manage_permission, only: [:new, :create, :edit, :update,
                                                     :destroy, :test_send]

    # ------------------------------------------------------------------ reading

    def index
      @schedules = Schedule.where(project_id: @project.id)
                           .preload(:template, :author, :render_as_user)
                           .order(:id)
      @heartbeat = Scheduling::Heartbeat.status(today: User.current.today,
                                                scope: Schedule.where(project_id: @project.id,
                                                                      enabled: true))
    end

    def show
      # The last few runs, most recent first — which is what `has_many :runs` already
      # orders by. Bounded, because a daily schedule three years old has a thousand of them
      # and nobody reads past the first screen.
      @runs = @schedule.runs.limit(RUNS_SHOWN)
    end

    # ------------------------------------------------------------------ writing

    def new
      @schedule = Schedule.new(project_id: @project.id,
                               author_id: User.current.id,
                               render_as: Schedule::RENDER_AS_AUTHOR,
                               enabled: false,
                               repeat: Scheduling::Occurrences::WEEKLY,
                               start_date: User.current.today)
    end

    def create
      @schedule = Schedule.new(schedule_params)
      # NEVER FROM PARAMS, EITHER OF THEM. `project_id` decides which project's permissions
      # are checked and `author_id` is who a failure notice goes to, so a request able to
      # set them could aim both somewhere else.
      @schedule.project_id = @project.id
      @schedule.author_id = User.current.id
      apply_template(@schedule)
      apply_query(@schedule)
      apply_render_identity(@schedule)

      if save_with_recipients(@schedule)
        flash[:notice] = l(:notice_successful_create)
        redirect_to project_reporter_schedule_path(@project, @schedule)
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      @schedule.attributes = schedule_params
      apply_template(@schedule)
      apply_query(@schedule)
      apply_render_identity(@schedule)

      if save_with_recipients(@schedule)
        flash[:notice] = l(:notice_successful_update)
        redirect_to project_reporter_schedule_path(@project, @schedule)
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @schedule.destroy
      flash[:notice] = l(:notice_successful_delete)
      redirect_to project_reporter_schedules_path(@project)
    end

    # FR-45: "a test send uses the SAME identity as the real run."
    #
    # Same identity, and the same `ScheduledDelivery` — `Schedule#render_identity` is one
    # method with two callers precisely so this cannot drift from the 06:00 run. What
    # differs is the recipient list: a test goes to the person who pressed the button and
    # to nobody else. Mailing twenty people every time an author adjusts a template would
    # make the button unusable, and the tester needs to see what recipients WOULD get, not
    # to send it to them.
    #
    # IT CLAIMS NOTHING. `ScheduleRun.claim` is not called, so a test send cannot consume
    # today's occurrence and leave the real run refused by the unique index — which is the
    # obvious way to build this and would silently cost somebody a report.
    def test_send
      actor = @schedule.render_identity

      # THE SECOND ESCALATION, AND IT NEEDED NO TAMPERING AT ALL.
      #
      # This action deliberately couples "render as the schedule's stored identity" (FR-45)
      # with "deliver to whoever pressed the button". Each half is safe; together they are
      # an exfiltration primitive — any schedule authored by an administrator could be
      # test-sent by any `manage_…_schedules` holder and the output landed in the presser's
      # mailbox. Measured by an independent review on an untouched schedule:
      # `actor=admin recipients=["jsmith"]`.
      #
      # FR-45 is not negotiable — a test send that renders as somebody else would prove
      # nothing about the real run — so the OTHER half gives way: you may test-send only a
      # schedule that renders as you, OR hold the permission that says you may hold somebody
      # else's visibility.
      #
      # THE SAME PERMISSION AS THE FIELD, deliberately. Binding a schedule to another
      # identity and reading that identity's report on demand are one capability exercised
      # twice, so they are one grant; two would let an administrator hand out half of it and
      # believe they had withheld the other half. The curator chose the permission model for
      # S-10 and asked for this to follow it.
      unless actor == User.current ||
             User.current.allowed_to?(:render_reporter_dashboards_reports_as_others, @project)
        return deny_access
      end
      result = Reporting::ScheduledDelivery.new(logger: Rails.logger)
                                           .call(schedule: @schedule,
                                                 occurrence_date: User.current.today,
                                                 actor: actor,
                                                 run: TestRun.new(SecureRandom.uuid),
                                                 recipients: [User.current],
                                                 notify_owner: false)

      if result.ok?
        flash[:notice] = l(:notice_reporter_schedule_test_sent, mail: User.current.mail)
      else
        flash[:error] = l(:error_reporter_schedule_test_failed, message: result.error)
      end
      redirect_to project_reporter_schedule_path(@project, @schedule)
    rescue Schedule::IdentityUnavailable => e
      # The one failure a test send has that a real run reports through the run row. There
      # is no row here, so it goes to the screen — and it is the message the operator needs,
      # because a schedule whose identity is locked will fail at 06:00 for the same reason.
      flash[:error] = l(:error_reporter_schedule_test_failed, message: e.message)
      redirect_to project_reporter_schedule_path(@project, @schedule)
    rescue StandardError => e
      # `ScheduledDelivery` states its own contract — "it may also raise; `Runner` handles
      # both identically" — and `Runner` does. This did not: an MTA outage gave the operator
      # a Redmine 500 page instead of the flash this action exists to produce. Bounded,
      # because the message can carry a whole backtrace.
      Rails.logger.error("[scheduler] test send for schedule #{@schedule.id} raised: " \
                         "#{e.class}: #{e.message}")
      flash[:error] = l(:error_reporter_schedule_test_failed,
                        message: "#{e.class}: #{e.message}".slice(0, 500))
      redirect_to project_reporter_schedule_path(@project, @schedule)
    end

    private

    # How many run rows `#show` lists. A daily schedule three years old has a thousand.
    RUNS_SHOWN = 20

    # `ScheduledDelivery` reads exactly one thing off the run it is handed, and a test send
    # has no run row to hand it — deliberately, because creating one would consume the
    # occurrence. A Struct with the one member is the honest shape; a `ScheduleRun.new` that
    # is never saved would look like a row and invite somebody to save it.
    TestRun = Struct.new(:correlation_id)

    # The same 404 `TemplatesController` gives, and DELIBERATELY DUPLICATED as four words
    # rather than extracted to a shared base class. A `ReporterDashboards::BaseController`
    # would put `before_action :authorize` somewhere `permission_map_spec.rb` reads it from
    # a file it is not looking at — and that spec exists because the review of T-40 got past
    # a per-controller check. Two four-line methods are cheaper than a place for a guard to
    # hide.
    def require_reports_module
      render_404 unless @project.module_enabled?(:reporter_dashboards_reports)
    end

    def find_schedule
      @schedule = Schedule.where(project_id: @project.id).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    # THE SECOND GUARD. See the class comment: `authorize` passes on any mapped permission,
    # and both of this controller's permissions map into this controller.
    def require_manage_permission
      deny_access unless User.current.allowed_to?(:manage_reporter_dashboards_schedules,
                                                  @project)
    end

    # ------------------------------------------------------------------ params

    # Strong params. `template_id` and `query_id` are NOT here — both are applied below
    # after being resolved against what this actor may actually see, and permitting them
    # would let a request name a template in another project or a saved query it cannot
    # open. Neither is `author_id`, `project_id`, or any of the run-state columns: those are
    # the runner's, and a form that could write `last_status` could hide a failure.
    def schedule_params
      params.require(:schedule).permit(:repeat, :start_date, :end_date, :email_subject,
                                       :render_as, :timezone, :enabled)
    end

    # THE TEMPLATE HAS TO BE ONE THIS ACTOR CAN SEE, and `Template.visible` is the same
    # scope the picker is built from. Without this a member could point a schedule at
    # somebody else's PRIVATE template and have it mailed to a list of their choosing —
    # which is a disclosure hole reached entirely through a form field.
    def apply_template(schedule)
      attributes = params[:schedule] || {}
      # ABSENT AND BLANK ARE DIFFERENT REQUESTS, and the first version conflated them: the
      # comment below said "left unset rather than silently kept" while `return if
      # id.blank?` did exactly the thing it refused. Clearing the picker and saving returned
      # "Successful update" and changed nothing — which also kept an invisible template
      # attached to a schedule its editor cannot see.
      return unless attributes.key?(:template_id)

      id = attributes[:template_id]
      if id.blank?
        schedule.template_id = nil
        return
      end

      template = Template.visible(User.current).where(project_id: @project.id).find_by(id: id)
      # Left unset rather than silently kept: `template_id` is `presence: true`, so an
      # unresolvable one fails validation and the form says so, instead of quietly keeping
      # whatever the row had before.
      schedule.template_id = template&.id
    end

    # Same rule for the saved query, and the same reason. `IssueQuery.visible` is what the
    # picker lists, so a query chosen here is one this actor may already run.
    def apply_query(schedule)
      attributes = params[:schedule] || {}
      return unless attributes.key?(:query_id)

      if attributes[:query_id].blank?
        schedule.query_id = nil
        schedule.query_type = nil
        return
      end

      # `.where(project_id: …)` MATCHING THE PICKER EXACTLY. The comment above used to say
      # "IssueQuery.visible is what the picker lists", and the picker was narrower: a
      # schedule in project A could be bound to a query scoped to project B, so the report
      # silently covered a different project than the one whose permissions were checked to
      # create it. The same asymmetry `apply_template` was written to avoid, in its sibling.
      query = IssueQuery.visible(User.current)
                        .where(project_id: [nil, @project.id])
                        .find_by(id: attributes[:query_id])
      schedule.query_id = query&.id
      schedule.query_type = query ? 'IssueQuery' : nil
    end

    # THE FIELD THAT DECIDES WHOSE VISIBILITY THE SQL RUNS UNDER, and it was in `permit`.
    #
    # `render_as_user_id` went straight from the form into the column. The picker offered
    # only project members, and nothing behind the picker checked anything — so a member
    # holding `manage_…_schedules` could POST `render_as_user_id=1`, press "Send a test",
    # and receive an ADMINISTRATOR-visibility report in their own inbox. An independent
    # review reproduced it end to end, against a private issue the attacker could not see:
    # "attacker sees 7, admin sees 8 … SCOPE SIZE=8; contains PAYROLL? true". It was also
    # plantable in two steps, because the id is stored even while the policy says `author`.
    #
    # `apply_template` and `apply_query` exist for exactly this reason and this field is
    # strictly stronger than either. It is resolved the same way now.
    #
    # --- WHO MAY NAME SOMEBODY ELSE: THE CURATOR'S ANSWER TO S-10, 2026-08-08 ---
    #
    # "A project member" is not a bound at all — every member with wider visibility than
    # yours is an escalation target, which is the whole of the finding above. The question of
    # who *should* be able to name another identity was reported rather than answered, and
    # the answer is `render_reporter_dashboards_reports_as_others`: a permission, granted per
    # role per project, which an administrator ticks deliberately and whose label says what
    # it really grants.
    #
    # Without it you may name YOURSELF, which is §7b.5's rule for on-demand mail — *"you can
    # only mail what you can see"* — applied to this field.
    #
    # THE ADMINISTRATOR CASE IS NOT WRITTEN HERE ANY MORE. It used to be `|| User.current
    # .admin?`, and it did not need to be: Redmine's `User#allowed_to?` answers `return true
    # if admin?` for every permission once the project allows the action (`user.rb:378`). One
    # rule, and the administrator exemption falls out of Redmine's own model instead of a
    # hand-written disjunction that could drift from it.
    def apply_render_identity(schedule)
      attributes = params[:schedule] || {}
      # Not the chosen policy — the STORED one is irrelevant, because the id is cleared
      # whenever the policy is not RENDER_AS_USER. That is what stops it being planted under
      # a benign policy and activated later by a request that never mentions it.
      unless schedule.render_as == Schedule::RENDER_AS_USER
        schedule.render_as_user_id = nil
        return
      end
      return unless attributes.key?(:render_as_user_id)

      wanted = attributes[:render_as_user_id].to_s
      schedule.render_as_user_id =
        assignable_identity_ids.include?(wanted.to_i) && wanted.present? ? wanted.to_i : nil
    end

    def assignable_identity_ids
      @assignable_identity_ids ||=
        if User.current.allowed_to?(:render_reporter_dashboards_reports_as_others, @project)
          @project.users.active.pluck(:id)
        else
          [User.current.id]
        end
    end

    # RECIPIENTS ARE REDMINE USERS AND THE LIST IS BOUNDED BY THE PROJECT.
    #
    # §7's row for `reporter_dashboards_schedule_recipients`: "**`user_id` only** — no
    # free-text `to`/`cc`/`bcc`/`from`, which is the exfiltration-and-spoofing-relay
    # finding." The ids are additionally intersected with the project's own members, so the
    # form cannot address somebody who has no business with this project at all.
    #
    # In ONE transaction with the schedule, because a schedule saved with the previous
    # recipient list is a schedule that mails the wrong people until somebody notices.
    def save_with_recipients(schedule)
      ids = requested_recipient_ids
      Schedule.transaction do
        raise ActiveRecord::Rollback unless schedule.save

        # `nil` MEANS "NOT REQUESTED" AND `[]` MEANS "CLEAR IT". The first version returned
        # `[]` for both, so any partial update — a future inline toggle, a REST client, a
        # renamed field — silently deleted every recipient and answered "Successful update".
        # Nothing said the list was gone; the operator found out when nobody got the report.
        # The form always sends the key, because of the hidden element in the partial.
        unless ids.nil?
          schedule.recipients.delete_all
          ids.each { |id| schedule.recipients.create!(user_id: id) }
        end
        true
      end || false
    end

    def requested_recipient_ids
      attributes = params[:schedule] || {}
      return nil unless attributes.key?(:recipient_user_ids)

      requested = Array(attributes[:recipient_user_ids]).reject(&:blank?).map(&:to_i)
      requested & assignable_recipient_ids
    end

    def assignable_recipient_ids
      @assignable_recipient_ids ||= @project.users.active.pluck(:id)
    end

    # WHAT THE FORM SHOULD SHOW AS SELECTED, which is not the same as what is stored once a
    # save has failed. Every other field survived a 422 and the one that takes eight clicks
    # did not, because the partial read the unsaved record's association.
    helper_method :reporter_selected_recipient_ids

    def reporter_selected_recipient_ids
      requested_recipient_ids || @schedule.recipients.map(&:user_id)
    end
  end
end
