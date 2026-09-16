# frozen_string_literal: true

module ReporterDashboards
  # T-28 increment 3 — WHERE AN OWNER SEES WHAT THEY HAVE SHARED AND TAKES IT BACK.
  #
  # §7b.1's closing sentence is the requirement and it is worth quoting, because it is the
  # part that is about people rather than about tokens: *"you can see what you have shared,
  # to whom it is reaching, and take it back. Today none of that exists."*
  #
  # --- THIS IS NOT THE PUBLIC ENDPOINT ---
  #
  # `ReporterDashboards::SharesController` serves tokens and is deliberately mapped to no
  # permission. This one is ordinary Redmine: project-scoped, module-gated, `authorize`d per
  # action, and every action needs a permission. The two are separate controllers because
  # they answer separate questions, and merging them would put a `skip_before_action` next to
  # a permission check — which is exactly how the review of T-40 defeated one.
  #
  # --- THE THREE RULES THIS CONTROLLER ENFORCES, AND ONLY ONE IS A PERMISSION ---
  #
  #   MAKING a link         `share_reporter_dashboards_reports`, plus the ability to READ
  #                         the template — you cannot share a report you cannot open
  #   making it PUBLIC      additionally `publish_reporter_dashboards_reports`, checked per
  #                         REQUEST rather than per route: *"anyone holding this URL"* and
  #                         *"anyone on the internet"* are different decisions (T-28's
  #                         `Accept:`), and the second is a property of the form body
  #   REVOKING              **ownership, not a permission** (FR-53). The link's creator, the
  #                         template's author, and admins. A third party holding every
  #                         grantable permission in Redmine still cannot revoke somebody
  #                         else's link, and a test asserts exactly that
  #
  # The third is the one worth guarding carefully, because it is the one a reader will
  # assume is a permission. `ShareLink#revocable_by?` is the single place it is decided.
  class ShareLinksController < ApplicationController
    Reporting = RedmineReporterDashboards::Reporting
    ShareLink = RedmineReporterDashboards::ShareLink
    Template = RedmineReporterDashboards::Template

    # DECLARED, because Redmine sets `include_all_helpers = false` — a controller sees its
    # own helper and nothing else. `reporter_dashboard_icon` is the D-3 shim.
    helper :reporter_project_pages

    # UNSCOPED `authorize` — no `only:`, no `except:`, no `skip_before_action` — because the
    # review of T-40 defeated a per-controller check with exactly those two lines, and
    # `spec/permissions/permission_map_spec.rb` reads them out of the AST.
    before_action :find_project_by_project_id
    before_action :require_reports_module
    before_action :authorize
    # THE PERMISSION GUARD RUNS BEFORE THE LOOKUP, and the order is a disclosure
    # decision rather than a style. Reversed — which is how this shipped — a member
    # holding only `publish_…` got 403 for a template that exists and 404 for one that
    # does not, which is an existence oracle for somebody with no right to reach the
    # surface at all. It also inverts `find_template`s own reasoning below (404 rather
    # than 403 precisely because 403 confirms existence). Found by an independent review.
    before_action :require_share_permission
    before_action :find_template
    before_action :find_link, only: [:revoke]
    before_action :require_revocable, only: [:revoke]

    def index
      @links = ShareLink.for_template(@template).includes(:created_by, :rendered_document)
    end

    # NO `@link`. The form is `params`-driven — it has to be, because it re-renders the
    # values somebody just typed after a refusal, and an unsaved `ShareLink` cannot
    # carry `expires_in_days` (a form field with no column behind it). Three `@link =`
    # assignments used to sit here and in the two refusal paths, read by nothing at all;
    # an independent review found them. A model-backed form that is not one is a
    # standing invitation to write `@link.errors` in the view and get silence.
    def new; end

    # RENDER FIRST, THEN GRANT. The snapshot has to exist before the link that authorises
    # it — that is FR-52's whole shape — so a render that fails produces no link at all
    # rather than a link pointing at nothing.
    def create
      public_link = requested_public?
      # THE SECOND PERMISSION, CHECKED PER REQUEST. Redmine's map cannot express "this
      # field needs another permission", so it is checked here, where the field is read.
      # REFUSED rather than silently downgraded to a private link: a person who ticked
      # "public" and got a private link would hand it out believing it was public, and find
      # out from the recipient. `TemplatesController#apply_visibility` forces rather than
      # refuses in the same situation, and the difference is deliberate — forcing a template
      # to private discloses nothing, while a link's audience is the whole point of it.
      if public_link && !User.current.allowed_to?(:publish_reporter_dashboards_reports, @project)
        return deny_access
      end

      # EVERY FIELD IS CHECKED BEFORE THE RENDER RUNS, AND THAT ORDER IS THE FIX RATHER THAN
      # A TIDY-UP. An independent review measured what the other order costs: a `purpose`
      # of 256 characters — an ordinary value from an ordinary form — passed every check
      # here, drove a FULL PDF RENDER, wrote a `Document` row and an `Attachment` to disk,
      # and only then failed `ShareLink`'s own length validation in `mint`:
      #
      #     STATUS=422  DOCS delta=1  LINKS delta=0  ATT delta=1
      #     ORPHAN doc id=679 expires_at=2026-09-15 attachment_id=25
      #
      # The link never existed, so nothing could ever reach those bytes — and
      # `documents:purge` collects only EXPIRED rows, so they sat for 37 days (357 at the
      # expiry cap), repeatable without bound by any member holding `share_…`. A second
      # value did worse: `max_uses=99999999999` raised an uncaught `ActiveModel::RangeError`
      # — a 500 — and orphaned a snapshot on the way out.
      #
      # FR-15's rule is that over-limit input is "dropped with a log line rather than
      # stored"; the expensive half of this action is the render, so the check has to come
      # first or the bound protects nothing that costs anything.
      invalid = invalid_fields
      unless invalid.empty?
        flash.now[:error] = invalid.join(', ')
        return render(:new, status: :unprocessable_entity)
      end

      snapshot = Reporting::Snapshot.capture(
        template: @template, render_as: User.current, project: @project,
        query_id: params[:query_id], created_by: User.current,
        expires_at: snapshot_expiry, logger: Rails.logger
      )

      unless snapshot.ok?
        flash.now[:error] = l(:"error_reporter_snapshot_#{snapshot.code}",
                              default: snapshot.message.to_s)
        return render(:new, status: :unprocessable_entity)
      end

      mint(snapshot.document, public_link)
    end

    # ONE LINK. `revoke` rather than `destroy`, and the verb is the point: the row stays, so
    # the access log it owns stays with it and an administrator can still answer "who opened
    # this before I stopped it".
    def revoke
      @link.revoke!
      flash[:notice] = l(:notice_reporter_share_link_revoked)
      redirect_to project_reporter_template_share_links_path(@project, @template)
    end

    # EVERY LIVE LINK FOR THIS TEMPLATE — §7b.1 asks for it by name ("plus 'revoke all for
    # this template'"), and it is the button somebody reaches for when they already know
    # something has gone wrong.
    #
    # OWNERSHIP IS CHECKED PER LINK, not once for the template. A revoke-all that took the
    # links of everybody who ever shared this report would be a permission escalation with a
    # convenient name, so it revokes what THIS actor may revoke and says how many that was.
    def revoke_all
      # NOT `.live`, AND THE DIFFERENCE IS VISIBLE ON THE PAGE. `.live` excludes EXPIRED
      # links, but the index draws a Revoke button for anything not yet revoked — so after
      # "revoke all" an expired-but-unrevoked link kept its button and its "Expired" row,
      # on precisely the page somebody opens when they already think something has gone
      # wrong. Found by an independent review.
      #
      # `revoked_at: nil` is the right set: revoking an expired link is not pointless
      # bookkeeping — it is the difference between "this stopped working on its own" and
      # "I stopped it", which is the fact the audit is for.
      revocable = ShareLink.for_template(@template)
                           .where(revoked_at: nil)
                           .select { |link| link.revocable_by?(User.current) }
      revocable.each(&:revoke!)

      flash[:notice] = l(:notice_reporter_share_links_revoked, count: revocable.length)
      redirect_to project_reporter_template_share_links_path(@project, @template)
    end

    private

    # ------------------------------------------------------------------ minting

    # THE TOKEN EXISTS EXACTLY ONCE, IN THIS RESPONSE. There is nowhere to get it afterwards
    # — only its digest is stored — so it goes into `flash` for the redirect and the index
    # shows it once. A link the owner cannot copy is a link they will simply make again.
    def mint(document, public_link)
      link, token = ShareLink.create_with_token!(
        template: @template, project: @project, created_by: User.current,
        scope_kind: ShareLink::SCOPE_SNAPSHOT, rendered_document_id: document.id,
        render_as_user_id: User.current.id, public_link: public_link,
        purpose: params[:purpose].presence, max_uses: requested_max_uses,
        expires_at: requested_expiry
      )

      # NOT `flash[:notice]`. The token is a credential and the notice partial is rendered
      # into every page of the next request; keeping it in its own key means the view has to
      # ask for it deliberately, and nothing else can print it by accident.
      flash[:reporter_share_url] = reporter_share_url(token: token)
      flash[:notice] = l(:notice_reporter_share_link_created)
      redirect_to project_reporter_template_share_links_path(@project, @template)
    rescue ActiveRecord::RecordInvalid => e
      # The link's own validations — an expiry past the snapshot's, a `max_uses` of zero.
      # Caught narrowly: anything else is a defect and must reach the log as one.
      flash.now[:error] = e.record.errors.full_messages.join(', ')
      render :new, status: :unprocessable_entity
    end

    # ------------------------------------------------------------------ params

    # `Setting` DOES NOT DECIDE THIS AND NEITHER DOES THE FORM ALONE. §7b.1 proposes 30 days
    # as a default; it is a constant here rather than a plugin setting for FR-21b's reason —
    # this plugin's only settings are installation policy about egress and delivery.
    DEFAULT_EXPIRY_DAYS = 30

    # THE SNAPSHOT OUTLIVES THE LINK BY A MARGIN, deliberately. A link may not expire after
    # its snapshot (`ShareLink#expiry_within_the_snapshots_own`), and two independently
    # computed "30 days from now" differ by microseconds in whichever direction the clock
    # happens to fall — so the artefact is given room rather than the validation being
    # relaxed. It is bounded by `Document::MAX_RETENTION` either way.
    SNAPSHOT_GRACE = 7 * 24 * 60 * 60

    def snapshot_expiry
      requested_expiry + SNAPSHOT_GRACE
    end

    # MEMOISED, WHICH IS THE "ONE CLOCK READ" RULE THIS REPO ALREADY FOLLOWS ELSEWHERE
    # (`schedules:run` reads `Time.zone.now` once so a tick straddling midnight cannot
    # disagree with itself). Here it is read twice in one request — once for the snapshot's
    # expiry and once for the link's — and the two must be the same instant plus a known
    # grace, not two instants that happen to be close.
    def requested_expiry
      @requested_expiry ||= computed_expiry
    end

    def computed_expiry
      days = params[:expires_in_days].to_i
      days = DEFAULT_EXPIRY_DAYS unless days.positive?
      # BOUNDED HERE AS WELL AS IN THE MODEL. `Document::MAX_RETENTION` is the hard stop; a
      # form that submitted 4 000 days would otherwise reach a validation error rather than
      # a number, and the person filling it in learns nothing from that.
      days = MAX_EXPIRY_DAYS if days > MAX_EXPIRY_DAYS

      days.days.from_now
    end

    # One year, minus the grace the snapshot needs above it, so the two bounds cannot
    # collide at the top of the range.
    MAX_EXPIRY_DAYS = 350

    # THE LARGEST `max_uses` A FORM MAY ASK FOR. `use_count` and `max_uses` are 4-byte
    # integers, so anything past `2**31 - 1` is an `ActiveModel::RangeError` rather than a
    # validation failure — a 500 from a number somebody typed. Bounded well below that: a
    # link somebody wants opened a million times is a link with no limit, and they can say
    # so by leaving the field empty.
    MAX_USES_CAP = 10_000

    def requested_max_uses
      uses = params[:max_uses].to_i

      return nil unless uses.positive?

      uses > MAX_USES_CAP ? MAX_USES_CAP : uses
    end

    # WHAT IS WRONG WITH THE REQUEST, BEFORE ANYTHING EXPENSIVE HAPPENS. Answers a list of
    # sentences, empty when the request is fine.
    #
    # Deliberately NOT `ShareLink.new(...).valid?`: that would need a `rendered_document_id`
    # to satisfy the snapshot validation, which is the very thing this check exists to run
    # before. The two fields a form can get wrong on its own are checked here, and the model
    # remains the authority for everything that involves a document.
    def invalid_fields
      errors = []
      if params[:purpose].to_s.length > ShareLink::MAX_STRING
        errors << l(:error_reporter_share_link_purpose_too_long, max: ShareLink::MAX_STRING)
      end
      # NEGATIVE AND NONSENSE VALUES ARE NOT AN ERROR — `requested_max_uses` reads them as
      # "no limit", which is what an empty field means and what a person typing `-1` almost
      # certainly wants. Only a value that would overflow the column is refused, and it is
      # clamped rather than refused.
      errors
    end

    def requested_public?
      %w[1 true on yes].include?(params[:public_link].to_s)
    end

    def default_expiry
      DEFAULT_EXPIRY_DAYS.days.from_now
    end

    # ------------------------------------------------------------------ guards

    def require_reports_module
      render_404 unless @project.module_enabled?(:reporter_dashboards_reports)
    end

    # YOU CANNOT SHARE A REPORT YOU CANNOT OPEN. `authorize` only says the action is mapped
    # to a permission this actor holds; it says nothing about THIS template, and
    # `Template#visible?` is where private and role-restricted templates are decided.
    # `find_template` answers 404 for one this actor may not see — the same choice
    # `TemplatesController#find_template` makes, and for the same reason: 403 confirms it
    # exists.
    def find_template
      @template = Template.where(project_id: @project.id).find(params[:template_id])
      render_404 unless @template.visible?(User.current)
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    def require_share_permission
      deny_access unless User.current.allowed_to?(:share_reporter_dashboards_reports, @project)
    end

    def find_link
      @link = ShareLink.where(template_id: @template.id).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    # OWNERSHIP, NOT A PERMISSION. See the class comment; `revocable_by?` is the one place
    # it is decided, and holding `share_…` is emphatically not enough.
    def require_revocable
      deny_access unless @link.revocable_by?(User.current)
    end
  end
end
