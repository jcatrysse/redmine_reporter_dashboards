# frozen_string_literal: true

module ReporterDashboards
  # T-32 / FR-61 — the ad-hoc report mail surface.
  #
  # --- WHAT THE BASE PLUGIN DID, AND WHERE EACH CLAUSE IS ANSWERED ---
  #
  # `technical-spec.md` §7b.5: `find_issues` is `Issue.where(id: params[:issue_ids])` with
  # **no visibility check**, and `to`/`cc`/`bcc`/**`from`** are free text — *"a report over
  # any issue in the instance, mailed anywhere, with a forged sender"*.
  #
  #   the issues     `Reporting::ReportScope` starts from the model's own `visible(actor)`
  #                  scope, and `AdhocDelivery` REFUSES a request naming an id outside it
  #   the recipients `#resolve_recipients` below — Redmine users through `User.active`, and
  #                  addresses only through `Reporting::MailPolicy`, which is the
  #                  administrator's setting and domain allowlist
  #   the sender     `ReporterDashboardsMailer` has no parameter one could travel in
  #   the audit      `MailSend` is claimed before the render and finished after it
  #   the rate limit counted off that same table, per requester
  #
  # --- AUTHORIZATION IS PER ACTION, AND `authorize` IS AGAIN ONLY THE FIRST HALF ---
  #
  # `before_action :authorize` is UNSCOPED — no `only:`, no `except:`, no
  # `skip_before_action` — because `spec/permissions/permission_map_spec.rb` reads those out
  # of the AST and T-40's review defeated a per-controller check with exactly those two
  # lines.
  #
  # The second half is `require_view_permission`. `mail_…_reports` carries
  # `require: :loggedin` rather than `:member`, deliberately (§4.1: *"a logged-in non-member
  # legitimately mails themselves a report they can already read"*) — so on its own it says
  # nothing at all about whether the holder may READ the report they are mailing. Mailing
  # is a way of reading, so it needs the reading permission as well, and that conjunction is
  # one Redmine's permission model cannot express. Same shape as `#import` needing both
  # authoring permissions.
  class MailController < ApplicationController
    Reporting = RedmineReporterDashboards::Reporting
    Template = RedmineReporterDashboards::Template
    MailSend = RedmineReporterDashboards::MailSend

    # Redmine sets `include_all_helpers = false`, so a controller sees its own helper and
    # nothing else. `reporter_dashboard_icon` (the D-3 `sprite_icon` shim) lives in the
    # dashboard helper and the views use it; without this line they 500 in production and
    # pass in every controller test. HANDOVER §1's first trap.
    helper :reporter_project_pages
    helper :'reporter_dashboards/templates'

    before_action :find_project_by_project_id
    before_action :require_reports_module
    before_action :authorize
    before_action :require_view_permission
    before_action :find_template, only: [:new, :create]

    # The compose form. It RENDERS NOTHING that sends — a GET that put mail on the wire
    # would be fireable by a crawler, a prefetching proxy or an `<img src>`, which is the
    # same reason `#test_send` and the preflight's `#run` are POSTs.
    def new
      @mail_send = MailSend.new
      @policy = mail_policy
      @remaining = remaining_sends
    end

    def create
      @policy = mail_policy
      @remaining = remaining_sends

      # THE LIMIT IS CHECKED BEFORE THE ROW IS CLAIMED, so a refused request does not
      # consume the quota it was refused by. The check-then-act window this leaves is
      # deliberate and bounded: two requests racing can both pass and produce one send over
      # the limit. A limit is a cost control, not an at-most-once guarantee — that one is
      # T-25's, it is held by a unique index, and buying it here would mean refusing two
      # colleagues who legitimately pressed send in the same second.
      return refuse(:rate_limited) if @policy.rate_limited?(sends_in_window)

      users, addresses, refusal = resolve_recipients
      return refuse(refusal) if refusal

      mail_send = claim_audit_row(users, addresses)
      @result = delivery.call(template: @template, actor: User.current, project: @project,
                              mail_send: mail_send, recipient_users: users,
                              recipient_addresses: addresses,
                              query_id: params[:query_id].presence,
                              issue_ids: named_issue_ids,
                              subject: params[:subject])
      record_recipients(mail_send, users, addresses)

      if @result.ok?
        flash[:notice] = l(:notice_reporter_adhoc_mail_sent, count: @result.recipients_count)
        redirect_to project_reporter_template_path(@project, @template)
      else
        # THE DIAGNOSTICS PANEL IS THE FAILURE NOTICE (T-32's `Accept:`: "a render failure
        # produces a failure notice, never a mail with a broken attachment"). Nothing was
        # mailed to anybody — see `AdhocDelivery` — and the requester is standing here, so
        # the notice is the page they are already looking at, carrying the same correlation
        # id that went into the audit row.
        @diagnostic = @result.diagnostic
        # AND THE OTHER SEVEN CODES GET A SENTENCE TOO, which they did not.
        #
        # Only `:render_failed` carries a diagnostic, so the panel above drew nothing for
        # `:issues_not_visible`, `:issue_ids_malformed`, `:query_unavailable`,
        # `:no_documents`, `:external_not_permitted`, `:attachments_too_large` or
        # `:partial_delivery`: the reason was computed, written to the audit row, and then
        # withheld from the one person standing in front of it, who saw a blank form and a
        # 422. Found by an independent review. `:partial_delivery` was the worst of them —
        # some recipients already hold the report, the obvious next action is to press send
        # again, and nothing said so.
        flash.now[:error] = adhoc_failure_text(@result)
        @remaining = remaining_sends
        render :new, status: :unprocessable_entity
      end
    end

    # THE AUDIT, and §7b.5's whole justification for it: *"today nothing records what left
    # the building. Now there is a log you can answer questions from."*
    def index
      # ADMINS SEE THE PROJECT'S SENDS; EVERYBODY ELSE SEES THEIR OWN.
      #
      # "visible to admins" is what FR-61 requires and it is the part that matters — an
      # auditor asking "has anything gone to example.com" needs every row. Showing a
      # non-admin holder the whole project's list would be a new disclosure: who mails
      # which report to whom is not something `mail_…_reports` says you may read about
      # other people, and no requirement asks for it. Their own rows are strictly theirs.
      scope = MailSend.where(project_id: @project.id)
      scope = scope.where(author_id: User.current.id) unless User.current.admin?

      @mail_sends = scope.includes(:recipients).order(created_at: :desc, id: :desc)
                         .limit(INDEX_LIMIT).to_a
      # THE PAGE'S USERS, RESOLVED IN ONE QUERY (G6). `includes(:recipients)` preloaded the
      # rows and not the PEOPLE, so the view did `User.find_by` per row and `recipient.user`
      # per recipient — about 1.5 extra statements per row, measured by an independent
      # review. Bounded by `INDEX_LIMIT`, so never fatal; but G6 asks for `includes`/
      # `preload` deliberately rather than for a bound that happens to be small.
      #
      # `MailSendRecipient` and the author cannot be a Rails association: `author_id` and
      # `user_id` point at Redmine's `User`, which this plugin does not own and must not
      # grow a `has_many` on. One `where(id: …)` over both sets is the honest equivalent.
      ids = @mail_sends.map(&:author_id) +
            @mail_sends.flat_map { |send| send.recipients.map(&:user_id) }
      @page_users = ::User.where(id: ids.compact.uniq).index_by(&:id)
      # BOUNDED, AND THE PAGE SAYS SO. An unbounded audit list is the "unbounded axis" the
      # T-31 review found one layer over: it works for a month and then times out, at the
      # moment somebody actually needs it. `#total` is what lets the view print
      # §9b.2's "50 of 1 284" rather than implying the list is complete.
      @mail_sends_total = scope.count
    end

    # The most rows `#index` will draw. Deliberately a constant rather than a setting: it
    # bounds a page, not a policy, and §4.1's rule is that a setting is for installation
    # policy — everything else is a decision this code makes and states.
    INDEX_LIMIT = 100

    private

    # ------------------------------------------------------------------ guards

    def require_reports_module
      render_404 unless @project.module_enabled?(:reporter_dashboards_reports)
    end

    # THE CONJUNCTION. See the class comment: `mail_…_reports` is `require: :loggedin` and
    # says nothing about reading, so mailing a report additionally needs the permission that
    # lets you open one. A functional test holds `mail_…` ALONE and asserts 403.
    def require_view_permission
      deny_access unless User.current.allowed_to?(:view_reporter_dashboards_reports,
                                                  @project)
    end

    # 404 AND NOT 403 FOR AN INVISIBLE TEMPLATE, identically to `TemplatesController`: a
    # 403 confirms the row exists, and a private template's existence is the thing being
    # protected.
    def find_template
      @template = Template.where(project_id: @project.id).find(params[:template_id])
      render_404 unless @template.visible?(User.current)
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    # ------------------------------------------------------------------ recipients

    # Answers `[users, addresses, refusal_code]`.
    #
    # --- THE PICKER IS NOT THE CHECK ---
    #
    # HANDOVER §1, from T-25's escalation: *"a `select` narrowed to project members proves
    # nothing about what the controller accepts."* So every id posted here is resolved
    # through `User.active` and every address through `MailPolicy`, and neither reads the
    # form's own options.
    #
    # --- A USER ID IS NOT A PRIVILEGE FIELD HERE, AND IT IS WORTH SAYING WHY NOT ---
    #
    # `render_as_user_id` needed a whole permission because it decided WHOSE VISIBILITY THE
    # SQL RAN UNDER. A recipient id decides who receives bytes that were already rendered as
    # the requester, so naming somebody with wider access gains the requester nothing: the
    # report contains what the requester could see, and no more. Mailing a colleague a
    # report is the capability, and `mail_…_reports` is the grant for it.
    def resolve_recipients
      ids = Array(params[:recipient_user_ids]).reject(&:blank?)
      users = ids.empty? ? [] : ::User.active.where(id: ids).to_a

      # THE RECIPIENT MUST BE ENTITLED TO REPORTS IN THIS PROJECT — curator decision,
      # §Findings S-20, replacing "any active account in the instance".
      #
      # --- WHY IT IS A PERMISSION CHECK AND NOT A MEMBERSHIP CHECK ---
      #
      # §4.1 answers every "who may do what, in which project" question with a role grant,
      # and `Member.where(...)` would be a second, weaker vocabulary for the same question.
      # Asking `allowed_to?` lands in the right place by construction: a member whose roles
      # do not include the reports permission is refused, a non-member is refused UNLESS an
      # administrator deliberately granted it to the Non-member role in a public project,
      # and an administrator is permitted because they can already read everything.
      #
      # The REQUESTER is always eligible without a special case, because
      # `require_view_permission` has already demanded the same permission of them — so
      # §4.1's "a logged-in non-member legitimately mails themselves a report they can
      # already read" survives with no second rule to keep in step.
      #
      # --- WHAT THIS DOES NOT CLAIM ---
      #
      # It does NOT mean the recipient could have produced the report themselves. The
      # document is rendered as the REQUESTER (FR-61) and the mail says whose access
      # produced it (FR-47) — that is the point of sharing one, and a recipient with
      # narrower issue visibility legitimately sees more than they could query. What this
      # closes is the envelope: before it, any active account in the instance could be
      # mailed a PDF from this server with a requester-controlled subject.
      #
      # REFUSED WHOLESALE, not filtered. Same rule as the addresses below and the issue ids
      # in the delivery: dropping the ineligible recipients would mail the rest and leave
      # the requester believing everybody got it.
      ineligible = users.reject { |user| may_receive_reports?(user) }
      return [users, [], :recipients_not_permitted] if ineligible.any?

      addresses = split_addresses(params[:recipient_addresses])

      # EXTERNAL ADDRESSES ARE REFUSED WHOLESALE WHEN THE POLICY IS OFF, and the refusal
      # names the policy rather than the address. Dropping them silently would mail the
      # report to the Redmine users in the same request and leave the requester believing
      # the external recipients got it too.
      return [users, [], :external_disabled] if addresses.any? && !@policy.external_enabled

      rejected = addresses.reject { |a| @policy.external_permitted?(a) }
      return [users, [], :external_not_allowlisted] if rejected.any?

      return [users, addresses, :no_recipients] if users.empty? && addresses.empty?

      [users, addresses, nil]
    end

    # ONE PLACE, because the picker below and the check above must not be able to disagree.
    # The picker is not the check — HANDOVER §1, from T-25's escalation — but a picker that
    # offers what the check will refuse is a form that answers 422 for no visible reason.
    def may_receive_reports?(user)
      user.allowed_to?(:view_reporter_dashboards_reports, @project)
    end

    # The accounts the compose form offers. Active project members who may actually open a
    # report here, ordered so two renders of the page agree (CLAUDE.md §6).
    #
    # Deliberately NARROWER than what `#create` accepts: an administrator is eligible and is
    # not listed, because listing every administrator in the picker is noise for the common
    # case and they are reachable by anybody who really means to name them.
    def recipient_choices
      @project.users.active.sorted.select { |user| may_receive_reports?(user) }
    end
    helper_method :recipient_choices

    def split_addresses(raw)
      raw.to_s.split(/[\s,;]+/).map(&:strip).reject(&:empty?).uniq
    end

    # The ids the request named, kept as strings for the audit and parsed by the delivery.
    # `nil` rather than `[]` when none were named, because "no set" and "an empty set" are
    # different requests: the first means "the whole scope", and an empty set would mean
    # "no issues at all".
    def named_issue_ids
      raw = params[:issue_ids]
      list = raw.is_a?(Array) ? raw : raw.to_s.split(/[\s,;]+/)
      cleaned = list.map { |id| id.to_s.strip }.reject(&:empty?)

      cleaned.empty? ? nil : cleaned
    end

    # ------------------------------------------------------------------ the audit

    def claim_audit_row(users, addresses)
      MailSend.claim(
        author_id: User.current.id,
        project_id: @project.id,
        template_id: @template.id,
        # COPIED, NOT REFERENCED. A template can be renamed or deleted after the send, and
        # an audit row whose only answer to "which template" is a dangling id answers
        # nothing.
        template_name: @template.name,
        source: @template.source,
        issue_ids: named_issue_ids&.join(','),
        query_id: params[:query_id].presence,
        query_type: params[:query_id].presence && query_type_for(@template),
        correlation_id: SecureRandom.uuid,
        recipients_count: users.length + addresses.length,
        external_count: addresses.length,
        created_at: Time.now
      )
    end

    # The same two classes `ReportScope` resolves through, named here so the audit row
    # records which one the query id belonged to. A `query_id` with no type is ambiguous
    # the moment both kinds of saved query exist, which they do from T-31 on.
    def query_type_for(template)
      template.source.to_s == 'time_entries' ? 'TimeEntryQuery' : 'IssueQuery'
    end

    # WRITTEN AFTER THE DELIVERY, and it must not be able to take a successful send down
    # with it. The bytes are already in somebody's mailbox by the time this runs; an
    # exception here would turn a delivered report into a 500 and invite the requester to
    # press send again.
    def record_recipients(mail_send, users, addresses)
      return if mail_send.nil?

      rows = users.map { |user| { mail_send_id: mail_send.id, user_id: user.id,
                                  created_at: Time.now } } +
             addresses.map { |address| { mail_send_id: mail_send.id, address: address,
                                         created_at: Time.now } }

      rows.each { |attributes| RedmineReporterDashboards::MailSendRecipient.create!(attributes) }
    rescue StandardError => e
      Rails.logger.warn("[adhoc-mail] send #{mail_send.id} completed but its recipient " \
                        "rows could not be written: #{e.class}: #{e.message}")
    end

    # ------------------------------------------------------------------ the limit

    def mail_policy
      @mail_policy ||= Reporting::MailPolicy.current(logger: Rails.logger)
    end

    def window_start
      Time.now - (mail_policy.rate_window_minutes * 60)
    end

    def sends_in_window
      MailSend.count_since(User.current.id, window_start)
    end

    def remaining_sends
      [mail_policy.rate_limit - sends_in_window, 0].max
    end

    # ------------------------------------------------------------------ refusals

    # ONE PLACE, so a refusal cannot be answered with a 200 by accident. 422 rather than
    # 403: the request was authorised and is unacceptable, which is a different fact from
    # "you may not do this at all" and is what an operator reading an access log needs.
    def refuse(code)
      flash.now[:error] = l(:"error_reporter_adhoc_#{code}")
      @mail_send = MailSend.new
      @remaining = remaining_sends
      render :new, status: :unprocessable_entity
    end

    # THE SAME MECHANISM T-31 SETTLED FOR DEGRADATION CODES (§Findings S-17): look up
    # `error_reporter_adhoc_<code>`, and fall back to the delivery's own English sentence
    # when there is no key.
    #
    # The fallback is deliberate and is not a licence to skip a key. A code with no
    # translation prints the raw message, which is a sentence rather than a symbol and is
    # strictly better than the blank form this replaced — but every code T-32 can produce
    # HAS a key in all nine locales, and `test_every_delivery_refusal_code_has_a_locale_key`
    # is what stops the next one arriving without one.
    def adhoc_failure_text(result)
      key = :"error_reporter_adhoc_#{result.code}"
      text = l(key, default: '')
      text.to_s.strip.empty? ? result.message.to_s : text
    end

    def delivery
      @delivery ||= Reporting::AdhocDelivery.new(logger: Rails.logger, policy: mail_policy)
    end
  end
end
