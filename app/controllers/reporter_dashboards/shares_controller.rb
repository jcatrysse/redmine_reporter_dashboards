# frozen_string_literal: true

module ReporterDashboards
  # T-28 — THE ONE ENDPOINT A SHARE TOKEN REACHES. FR-51/52/53/62, `technical-spec.md`
  # §7b.1 and §7b.6.
  #
  # --- WHY THIS CONTROLLER HAS NO PERMISSION CHECK, AND WHY THAT IS NOT A HOLE ---
  #
  # Every other controller in this plugin runs `before_action :authorize` and a second,
  # explicit guard naming the permission it really needs. This one runs neither, and the
  # difference is the whole design rather than an omission:
  #
  #   a permission answers  "may THIS PERSON do this thing"
  #   a share link answers  "may WHOEVER HOLDS THIS TOKEN have THESE BYTES"
  #
  # The second question has no user in it. The bytes were computed once, by a named
  # identity, inside that identity's own visible scope, and frozen (`Reporting::Snapshot`).
  # Serving them makes no query, resolves no permission and reads no issue — so there is no
  # visibility decision here to get wrong, which is FR-52 in one sentence and the exact
  # defect §7b.1 indicts the base plugin for: *"the token BYPASSES the visibility check
  # entirely rather than authorising a specific thing."* This token authorises a specific
  # thing.
  #
  # What guards the action instead is `find_link`, and it is listed with that reason in
  # `Permissions::NON_PERMISSION_GUARDS`, which is checked mechanically against this file.
  #
  # --- THE TWO KINDS OF LINK, AND WHY LOGIN IS STILL REQUIRED FOR ONE OF THEM ---
  #
  # T-28's `Accept:` asks for TWO grants and not one, *"because 'anyone holding this URL'
  # and 'anyone on the internet' are different decisions"*. That distinction has to mean
  # something at serving time or it is only a label on a form:
  #
  #   public_link = false   anyone holding the URL, WHO IS LOGGED IN. The token is the
  #                         authorisation; being an account-holder is what keeps the link
  #                         inside the organisation, so a forwarded mail does not become a
  #                         public URL by being forwarded once more
  #   public_link = true    anyone at all. This is what `publish_…_reports` grants, off by
  #                         default per FR-62, and it is served here without a session
  #
  # A public link is served even on an installation with `login_required` on. That is
  # deliberate and is recorded as a finding rather than assumed: the setting closes the
  # instance to anonymous BROWSING, and a public report link is an administrator granting
  # one role the right to publish one frozen document to a URL. If the setting silently won
  # instead, the capability would be dead on those installations with nothing anywhere
  # saying why.
  #
  # --- WHY EVERY OUTCOME IS LOGGED BEFORE IT IS ANSWERED ---
  #
  # FR-53: *"every share-link access is recorded"*. A refusal is the row most worth having
  # (see `ShareLinkAccess`), so the log write happens on every branch that had a link to
  # write it against — and it is NOT in a rescue, because failing to audit is a reason not
  # to serve rather than a detail to swallow.
  class SharesController < ApplicationController
    ShareLink = RedmineReporterDashboards::ShareLink
    ShareLinkAccess = RedmineReporterDashboards::ShareLinkAccess
    Snapshot = RedmineReporterDashboards::Reporting::Snapshot

    # THE ONE SKIP IN THIS PLUGIN, AND IT IS THE FEATURE. Redmine's
    # `check_if_login_required` sends an anonymous visitor to the login page when the
    # instance is closed; a public report link that did that would be a public link nobody
    # outside the organisation could open, which is the capability FR-62 names.
    #
    # It is NOT `skip_before_action :authorize` — this controller never declares one, so
    # there is nothing here that could be hollowed out by an `only:`/`except:` the way the
    # review of T-40 hollowed out a per-controller check.
    skip_before_action :check_if_login_required

    # THE GUARD. It resolves the token and refuses on its own when there is nothing behind
    # it, which is why `#show` can read `@link` without a nil check.
    before_action :find_link

    def show
      return unless holder_permitted?
      # A KIND THIS VERSION CANNOT SERVE IS REFUSED RATHER THAN GUESSED AT. Only snapshot
      # links can be minted today; `query` and `issue_ids` are §7b.1's other two and are
      # opt-in per template, which is a decision no UI has yet offered anybody. Falling back
      # to rendering here would be the one thing FR-52 forbids — a visibility decision at
      # request time — so it answers with a sentence instead.
      return refuse(:unsupported) unless @link.snapshot?

      bytes = @link.rendered_document&.bytes
      # RESOLVED BEFORE THE USE IS CLAIMED, and the order is the whole of the reasoning: a
      # single-use link whose snapshot has been purged would otherwise burn its one use on a
      # request that served nothing, and the holder could never try again.
      return refuse(:unavailable) if bytes.nil?

      # THE CLAIM. `use!` is one conditional UPDATE whose WHERE clause carries the whole
      # rule — see `ShareLink` — so two requests arriving together cannot both serve a
      # single-use link. It answers the refusal reason, or nil when this request won it.
      reason = @link.use!
      return refuse(reason) if reason

      serve(bytes)
    end

    private

    def find_link
      token = params[:token].to_s
      @link = ShareLink.find_by_token(token)
      return if @link

      # NO ROW, SO NO AUDIT ROW EITHER — `share_link_id` is NOT NULL and this endpoint is
      # reachable without an account, so a nullable column here would let anybody on the
      # internet write to that table by presenting gibberish. `ShareLinkAccess`' comment
      # carries the argument. The fact is still recorded, in the place an operator already
      # rotates.
      #
      # THE TOKEN IS NOT LOGGED. It is a credential; a log line carrying it would put the
      # working link in the one file most likely to be copied into a ticket.
      logger.info("[reporter_dashboards] share token not found (#{request.remote_ip})")
      refuse(:not_found, log: false)
    end

    # A NON-PUBLIC LINK STILL NEEDS AN ACCOUNT. See the class comment for why the two grants
    # have to differ here rather than only on the form that creates them.
    #
    # CORE'S `require_login` RATHER THAN A 401 PAGE OF OUR OWN, because it does the useful
    # half: it redirects to the sign-in page with this URL as `back_url`, so the holder
    # signs in and lands on the report instead of on a page telling them to try again. It
    # answers false and has already rendered when the visitor is anonymous, which is why the
    # caller returns rather than refusing.
    #
    # NO AUDIT ROW, and that is the right call rather than an omission: nothing was served
    # and the link's state did not decide it. `ShareLinkAccess::OUTCOMES` is a closed set an
    # administrator groups by, and "somebody followed the link while logged out" is a fact
    # about a browser rather than about the grant.
    def holder_permitted?
      return true if @link.public_link?

      require_login
    end

    # ONE PAGE FOR EVERY REFUSAL, and its status code says the same thing to a machine.
    #
    # `not_found` deliberately reads differently from the other three: a token matching
    # nothing must not be distinguishable from one that never existed, or the endpoint
    # becomes an oracle for guessing. The other three DO name their reason — the holder
    # already has the token, so telling them "this expired on the 3rd" discloses nothing to
    # anyone who did not already have it, and "this did not work" is the message this whole
    # task exists to stop shipping.
    STATUSES = {
      not_found: :not_found,
      revoked: :gone,
      expired: :gone,
      exhausted: :gone,
      unavailable: :gone,
      unsupported: :unprocessable_entity
    }.freeze

    def refuse(reason, log: true)
      code = reason.to_sym
      @reason = code
      @message = l(:"text_reporter_share_#{code}")
      record(code) if log

      render template: 'reporter_dashboards/shares/refused',
             layout: 'base',
             status: STATUSES.fetch(code, :not_found)
    end

    # ONLY THE FOUR OUTCOMES THE SCHEMA HAS. `unavailable` and `unsupported` are answers
    # about THIS REQUEST rather than about the link's state, and
    # `ShareLinkAccess::OUTCOMES` is a closed set a reader groups by — adding a category
    # for every future refusal shape would make that grouping mean less each time. They
    # reach the log instead, with the link id, so nothing is silent.
    def record(code)
      return if @link.nil?

      if ShareLinkAccess::OUTCOMES.include?(code.to_s)
        @link.record_access!(outcome: code, ip_address: request.remote_ip,
                             user_agent: request.user_agent)
      else
        logger.info("[reporter_dashboards] share link #{@link.id} refused: #{code}")
      end
    end

    def serve(bytes)
      @link.record_access!(outcome: ShareLinkAccess::OUTCOME_SERVED,
                           ip_address: request.remote_ip,
                           user_agent: request.user_agent)

      # `inline`, NOT `attachment`. A shared report is something somebody was sent a link to
      # and wants to look at; forcing a download for a document they cannot edit or resubmit
      # is friction with nothing on the other side of it.
      send_data bytes,
                filename: filename,
                type: Snapshot::CONTENT_TYPE,
                disposition: 'inline'
    end

    # THE FILENAME IS THE STORED ONE where there is one, so the file a recipient saves is
    # named the same thing every time they open the link.
    def filename
      @link.rendered_document&.attachment&.filename.presence || 'report.pdf'
    end
  end
end
