# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-28 — the share endpoint, over HTTP, as the recipient of a link actually meets it.
# FR-51/52/53/62.
#
# --- WHY THIS IS AN INTEGRATION TEST AND NOT A FUNCTIONAL ONE ---
#
# Two of the claims cannot be made at `ActionController::TestCase` level at all, and T-29
# lost a round to exactly this (§Findings E-6):
#
#   * `ActionController::TestCase` calls the action directly, so no middleware runs. The
#     anonymous path goes through `check_if_login_required`, `user_setup` and the session —
#     all middleware-and-filter behaviour — and this controller SKIPS one of those filters.
#     A test that never runs them cannot tell a working skip from a missing one.
#   * "identical bytes regardless of who opens it" is a claim about two whole requests made
#     by two different sessions.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. There is none here; the
# helpers are above the tests.
class ReporterDashboardsShareLinkFlowTest < Redmine::IntegrationTest
  # §Findings E-21, and it cost this file one round: a test case that calls `l()` needs the
  # module that defines it, and without the include every assertion about the refusal COPY
  # errors with `NoMethodError: undefined method 'l'`. Two of T-33's tests sat in the tree
  # for a release doing exactly that — a test that does not exist and a test that passes
  # look identical in a summary line.
  include Redmine::I18n

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  ShareLink = RedmineReporterDashboards::ShareLink
  ShareLinkAccess = RedmineReporterDashboards::ShareLinkAccess
  Snapshot = RedmineReporterDashboards::Reporting::Snapshot
  Template = RedmineReporterDashboards::Template

  PDF_BYTES = "%PDF-1.4\n#{'0' * 2_000}\n%%EOF"

  class FakeEngine
    def capabilities
      []
    end

    def id
      'fake'
    end

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: PDF_BYTES, engine: 'fake', engine_version: '1.0'
      )
    end
  end

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @jsmith = User.find_by!(login: 'jsmith')
    # ONE OBJECT — `Role.find(1).permissions = …` then `Role.find(1).save!` saves a second,
    # freshly loaded role and throws the assignment away.
    role = Role.find(1)
    role.permissions = %w[view_issues view_reporter_dashboards_reports]
    role.save!
    @template = Template.create!(project: @project, author: @jsmith, name: 'Quarterly',
                                 content: '<p>hello</p>', source: 'issues',
                                 output: 'combined')
    @document = build_snapshot
  end

  def teardown
    User.current = nil
  end

  # ------------------------------------------------------------------ helpers

  def build_snapshot
    result = RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, FakeEngine)
      # THE SNAPSHOT OUTLIVES THE LINKS ON PURPOSE. A link may not expire after its
      # document (T-28 increment 3), and two separate `30.days.from_now` calls differ by
      # microseconds in the wrong direction — so the fixture states the relationship the
      # feature actually has: the artefact is kept a while, the grant over it is shorter.
      Snapshot.capture(template: @template, render_as: @jsmith, project: @project,
                       created_by: @jsmith, expires_at: 90.days.from_now)
    end
    raise "the fixture snapshot could not be built: #{result.code} #{result.message}" unless result.ok?

    result.document
  end

  def mint(overrides = {})
    ShareLink.create_with_token!({ template: @template, project: @project,
                                   created_by: @jsmith,
                                   scope_kind: ShareLink::SCOPE_SNAPSHOT,
                                   rendered_document_id: @document.id,
                                   render_as_user_id: @jsmith.id,
                                   public_link: true,
                                   expires_at: 30.days.from_now }.merge(overrides))
  end

  def open_link(token)
    get "/reporter/s/#{token}"
  end

  # ------------------------------------------------------------------ a public link

  # THE CENTRAL CLAIM OF FR-62, AND EVERY WORD OF IT IS LOAD-BEARING: no session, no
  # account, no membership, no permission — and the bytes come back.
  def test_a_public_link_serves_the_snapshot_to_a_visitor_with_no_account
    _link, token = mint

    open_link(token)

    assert_response :success
    assert_equal PDF_BYTES, response.body
    assert_equal 'application/pdf', response.media_type
    # `inline`, WHICH IS CORE'S OWN RULE FOR A PDF (`AttachmentsController#disposition`).
    # Pinned because a review found it could be flipped to `attachment` with nothing going
    # red — and the difference is whether a recipient who was sent a link sees their report
    # or gets a download prompt for a file they cannot do anything else with.
    assert_include 'inline', response.headers['Content-Disposition'].to_s
    # THE SESSION, NOT `User.current`. The first version asserted `User.current.id.nil?`
    # and failed against a request that WAS anonymous: `User.anonymous` is a real row with
    # a real id (6 in the fixtures), so that check could never have passed and would have
    # said nothing about the request in any case — `User.current` here is the TEST
    # process's, not the one the request ran under. `session[:user_id]` is what actually
    # distinguishes a signed-in request from this one.
    assert_nil session[:user_id], 'the request carried a session, so it asserts less than it says'
  end

  # §7b.6: *"a public link serves a snapshot rather than running a live query as nobody. So
  # 'public link' stops meaning 'visibility check skipped'."* The mechanical form of that
  # sentence is that the SAME BYTES come back for two unrelated readers — the anonymous one
  # above and a logged-in user who is not a member of the project and could not see a single
  # one of these issues by asking.
  def test_the_same_bytes_come_back_whoever_opens_it
    _link, token = mint(max_uses: nil)

    open_link(token)
    anonymous_body = response.body

    log_user('dlopper', 'foo')
    open_link(token)
    member_body = response.body

    assert_equal anonymous_body, member_body
    assert_equal @document.digest, Digest::SHA256.hexdigest(member_body),
                 'the served bytes are not the frozen ones'
  end

  # A CLOSED INSTANCE STILL PUBLISHES A PUBLIC LINK, and this is a decision rather than an
  # accident — see the controller's comment. `login_required` closes the instance to
  # anonymous BROWSING; a public report link is an administrator having granted one role the
  # right to publish one frozen document. If the setting silently won, the capability would
  # be dead on those installations with nothing anywhere saying why.
  def test_a_public_link_still_serves_on_an_instance_that_requires_login
    _link, token = mint

    with_settings login_required: '1' do
      open_link(token)
    end

    assert_response :success
    assert_equal PDF_BYTES, response.body
  end

  # ------------------------------------------------------------------ a private link

  # THE TWO GRANTS HAVE TO DIFFER SOMEWHERE, and T-28's `Accept:` says where: *"'anyone
  # holding this URL' and 'anyone on the internet' are different decisions."* A link that is
  # not public sends an anonymous visitor to sign in — and the `back_url` brings them back
  # here, so the difference costs the legitimate holder one login rather than the link.
  def test_a_non_public_link_sends_an_anonymous_visitor_to_sign_in
    _link, token = mint(public_link: false)

    open_link(token)

    assert_redirected_to(/\/login/)
  end

  # THE REDIRECT IS NOT A REFUSAL OF THE LINK, so nothing is consumed and nothing is logged:
  # `ShareLinkAccess::OUTCOMES` is a closed set an administrator groups by, and "somebody
  # followed the link while logged out" is a fact about a browser rather than about the
  # grant.
  def test_being_sent_to_sign_in_consumes_no_use_and_writes_no_access_row
    link, token = mint(public_link: false, max_uses: 1)

    assert_no_difference 'RedmineReporterDashboards::ShareLinkAccess.count' do
      open_link(token)
    end
    assert_equal 0, link.reload.use_count
  end

  # AND THE TOKEN IS STILL THE AUTHORISATION ONCE THEY ARE IN. dlopper is not a member of
  # project 1 in the fixtures and holds no permission on it; they get the bytes because they
  # hold the link, which is precisely what a share link means.
  def test_a_non_public_link_serves_any_signed_in_holder
    _link, token = mint(public_link: false)
    log_user('dlopper', 'foo')

    open_link(token)

    assert_response :success
    assert_equal PDF_BYTES, response.body
  end

  # ------------------------------------------------------------------ the three refusals

  def test_an_expired_link_is_refused_and_says_so
    link, token = mint
    link.update_columns(expires_at: 1.hour.ago)

    open_link(token)

    assert_response :gone
    assert_include l(:text_reporter_share_expired), response.body
    assert_equal 'expired', link.accesses.reload.first.outcome
  end

  def test_a_revoked_link_is_refused_and_says_so
    link, token = mint
    link.revoke!

    open_link(token)

    assert_response :gone
    assert_include l(:text_reporter_share_revoked), response.body
    assert_equal 'revoked', link.accesses.reload.first.outcome
  end

  # AT THE LIMIT AND ONE PAST IT — CLAUDE.md §3's rule for anything with a limit.
  def test_a_single_use_link_works_once_and_then_stops
    link, token = mint(max_uses: 1)

    open_link(token)
    assert_response :success

    open_link(token)
    assert_response :gone
    assert_include l(:text_reporter_share_exhausted), response.body
    assert_equal 1, link.reload.use_count
    assert_equal %w[exhausted served], link.accesses.reload.map(&:outcome).sort
  end

  # ------------------------------------------------------------------ a token that is not one

  # A TOKEN MATCHING NOTHING MUST NOT BE DISTINGUISHABLE FROM ONE THAT NEVER EXISTED, or the
  # endpoint is an oracle for guessing. It is also the one refusal that writes NO row:
  # `share_link_id` is NOT NULL, and this endpoint is reachable without an account, so a
  # nullable column would let anyone on the internet grow that table with gibberish.
  def test_an_unknown_token_is_a_404_that_writes_nothing
    mint

    assert_no_difference 'RedmineReporterDashboards::ShareLinkAccess.count' do
      open_link(ShareLink.generate_token)
    end

    assert_response :not_found
    assert_include l(:text_reporter_share_not_found), response.body
  end

  # NOT A PREFIX, NOT A SUFFIX. A prefix match would let an attacker walk the token one
  # character at a time, which is the disclosure the constant-time comparison exists for.
  def test_a_partial_token_reaches_nothing
    _link, token = mint

    [token[0, 20], token[0..-2], "#{token}x"].each do |candidate|
      open_link(candidate)

      assert_response :not_found, "#{candidate.inspect} was not refused"
    end
  end

  # ------------------------------------------------------------------ a snapshot that is gone

  # THE PURGE TASK IS ENTITLED TO COLLECT AN EXPIRED DOCUMENT, and a link outliving its
  # snapshot is therefore a state that happens rather than one to assume away. It must not
  # burn a use: a single-use link whose bytes are missing would otherwise be spent on a
  # request that served nothing, and the holder could never try again.
  def test_a_link_whose_snapshot_is_gone_refuses_without_consuming_a_use
    link, token = mint(max_uses: 1)
    ::Attachment.find(@document.attachment_id).destroy
    @document.update_columns(attachment_id: nil)

    open_link(token)

    assert_response :gone
    assert_include l(:text_reporter_share_unavailable), response.body
    assert_equal 0, link.reload.use_count, 'a use was consumed for a request that served nothing'
  end

  # ------------------------------------------------------------------ a kind we cannot serve

  # `query` AND `issue_ids` ARE §7b.1's OTHER TWO KINDS and no UI mints them yet. The branch
  # exists so that a row created by hand — or by a later increment — cannot fall back to
  # RENDERING at request time, which is the one thing FR-52 forbids.
  def test_a_live_query_link_is_refused_rather_than_rendered
    link, token = mint(scope_kind: ShareLink::SCOPE_QUERY, rendered_document_id: nil)

    open_link(token)

    assert_response :unprocessable_entity
    assert_include l(:text_reporter_share_unsupported), response.body
    assert_equal 0, link.reload.use_count
  end

  # ------------------------------------------------------------------ an expired snapshot

  # A LINK MUST NOT SERVE A SNAPSHOT THAT HAS EXPIRED, and before this it did. An
  # independent review measured a link outliving its document by 300 days and receiving
  # `status=200` with the bytes — `expires_at` on a document was consulted by a validation
  # and by nothing else, so the mandatory TTL was decorative on the only path that reads it.
  def test_a_snapshot_past_its_own_ttl_is_refused_even_while_the_file_is_there
    link, token = mint(max_uses: 1)
    @document.update_columns(expires_at: 1.hour.ago)

    open_link(token)

    assert_response :gone
    assert_include l(:text_reporter_share_unavailable), response.body
    assert ::Attachment.exists?(@document.attachment_id),
           'the file was gone anyway, so this asserts nothing about the TTL'
    assert_equal 0, link.reload.use_count, 'a use was spent on a request that served nothing'
  end

  # AND THE VALIDATION AT THE OTHER END: a link cannot be CREATED outliving its snapshot.
  # The two together are the fix — this one stops the bad link existing, the one above stops
  # a link made before the validation existed from serving stale bytes.
  def test_a_link_may_not_be_minted_outliving_its_snapshot
    @document.update_columns(expires_at: 2.days.from_now)

    link = ShareLink.new(template: @template, project: @project, created_by: @jsmith,
                         scope_kind: ShareLink::SCOPE_SNAPSHOT,
                         rendered_document_id: @document.id,
                         expires_at: 30.days.from_now)
    link.token_digest = ShareLink.digest_for('x')

    assert_not link.valid?
    assert_includes link.errors.attribute_names, :expires_at
  end

  # ------------------------------------------------------------------ HEAD

  # A `HEAD` MUST NOT SPEND SOMEBODY'S LINK. Rails routes `HEAD` to the `GET` action and Rack
  # discards the body, so a mail scanner, a chat unfurler or a link-preview fetcher consumed
  # a `max_uses` slot and received nothing — measured by an independent review as
  # `head_status=200 body_bytesize=0 use_count=1`, after which the human's own click got 410.
  def test_a_head_request_does_not_spend_a_use_and_the_next_get_still_works
    link, token = mint(max_uses: 1)

    assert_no_difference 'RedmineReporterDashboards::ShareLinkAccess.count' do
      head "/reporter/s/#{token}"
    end
    assert_response :success
    assert_equal 0, link.reload.use_count

    open_link(token)

    assert_response :success
    assert_equal PDF_BYTES, response.body
    assert_equal 1, link.reload.use_count
  end

  # ------------------------------------------------------------------ the audit log

  # FR-53: *"every share-link access is recorded (timestamp, address, agent)"*. Asserted on
  # the fields rather than only on the count, because a row with three NULLs answers none of
  # the questions the table exists for.
  def test_every_access_is_recorded_with_its_address_and_agent
    link, token = mint(max_uses: nil)

    get "/reporter/s/#{token}", headers: { 'HTTP_USER_AGENT' => 'ShareTest/1.0' }
    assert_response :success

    access = link.accesses.reload.first
    assert_equal ShareLinkAccess::OUTCOME_SERVED, access.outcome
    assert_not_nil access.created_at
    assert_not_nil access.ip_address
    assert_equal 'ShareTest/1.0', access.user_agent
  end

  def test_three_opens_are_three_rows
    link, token = mint(max_uses: nil)

    3.times { open_link(token) }

    assert_equal 3, link.accesses.reload.count
  end

  # AN AUDIT ROW THAT CAN BE REWRITTEN IS NOT ONE. The schema has no `updated_at` and the
  # model refuses the write; asserted here because the endpoint is what creates these rows
  # and a later "helpful" `touch` would land in this file's blast radius.
  def test_an_access_row_cannot_be_changed_afterwards
    link, token = mint

    open_link(token)

    access = link.accesses.reload.first
    assert access.readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { access.update!(outcome: 'revoked') }
  end

  # A REVOKED LINK IS STILL AN UNAUTHENTICATED WRITE ENDPOINT, and revocation does not close
  # it. An independent review measured twenty requests on a revoked link writing twenty rows,
  # each carrying up to 255 attacker-chosen bytes of `User-Agent` — which undoes the care
  # taken to keep `share_link_id` NOT NULL for exactly that reason.
  #
  # The FIRST refusal is kept, because "somebody is still using the link you revoked" is the
  # signal this table exists for. The repeats are what is dropped.
  def test_a_flood_of_requests_on_a_revoked_link_does_not_flood_the_audit_table
    link, token = mint
    link.revoke!

    assert_difference 'RedmineReporterDashboards::ShareLinkAccess.count', 1 do
      20.times { open_link(token) }
    end
    assert_response :gone
    assert_equal 'revoked', link.accesses.reload.first.outcome
  end

  # ...AND THE COLLAPSE IS BY REASON, NOT BLANKET. A different refusal is a different fact,
  # and losing it would be losing the log's meaning rather than its volume.
  def test_a_change_of_refusal_reason_always_writes_a_row
    link, token = mint

    link.update_columns(expires_at: 1.hour.ago)
    open_link(token)
    link.revoke!
    open_link(token)

    assert_equal %w[expired revoked], link.accesses.reload.map(&:outcome).sort
  end

  # A SUCCESS IS NEVER COLLAPSED. `served` rows are facts about a person receiving data,
  # they are what `max_uses` bounds, and FR-53's "every access is recorded" is about these.
  def test_repeated_successful_opens_are_each_recorded
    link, token = mint(max_uses: nil)

    assert_difference 'RedmineReporterDashboards::ShareLinkAccess.count', 3 do
      3.times { open_link(token) }
    end
    assert_equal %w[served served served], link.accesses.reload.map(&:outcome)
  end

  # ------------------------------------------------------------------ FR-54 / INV-8

  # FR-54 IS **NOT SATISFIED**, AND THESE TWO TESTS DO NOT CLAIM IT IS — see §Findings
  # **S-28**. They were written under a claim since REFUTED BY MEASUREMENT: that
  # `Assets::Policy`s `:bundled` default rewrites a same-origin Redmine URL to disk, so a
  # snapshot could carry no live reference. `Assets::Resolver` and `Render::AssetBinding`
  # have **no production call site** — `ReportRun#document_request` passes `body:` straight
  # through — and a real render puts `/attachments/download/1` into the PDF verbatim. The
  # policy is real, correct and tested, and nothing calls it; the pre-existing half of that
  # is §Findings **F-16**.
  #
  # WHAT THESE TWO DO TEST is worth keeping and is a narrower, TRUE claim: a share link
  # authorises ONE DOCUMENT and grants nothing else. Nothing leaks today — the renderer is
  # never handed a session credential (INV-8), so a referenced attachment simply fails to
  # load — but *"the fetch fails"* is not *"attachment URLs are scoped to the link, and
  # expire and revoke with it"*, which is what FR-54 asks for and what T-28 still owes.
  #
  # The mechanical form of "no scoped URL is needed" is that the endpoint HAS NOTHING ELSE
  # TO GIVE: one route parameter, one document, and no way to ask it for a second thing. A
  # scoped-URL scheme would have been a SECOND bearer-token surface to expire and revoke;
  # not issuing one removes the problem rather than managing it.
  def test_the_endpoint_cannot_be_asked_for_anything_but_its_own_document
    _link, token = mint(max_uses: nil)
    other = build_snapshot

    open_link(token)
    expected = response.body

    # Every parameter a caller might hope means "give me that one instead". None of them is
    # read, so all of them answer the same bytes.
    [{ id: other.id }, { document_id: other.id }, { attachment_id: @document.attachment_id },
     { rendered_document_id: other.id }, { template_id: @template.id }].each do |extra|
      get "/reporter/s/#{token}", params: extra

      assert_response :success
      assert_equal expected, response.body, "#{extra.inspect} changed what was served"
    end
  end

  # AND THE SHARE LINK NEVER WIDENS ACCESS TO ANYTHING ELSE. A template author can write a
  # literal `<a href="/attachments/download/1">` into a report, and that hyperlink survives
  # into the PDF. Following it does NOT get the file: it reaches core's own
  # `AttachmentsController`, which asks `Attachment#visible?` about the person clicking —
  # who, for a public link, is anonymous.
  #
  # Pinned because the claim being made is *"a share link authorises one document and
  # nothing it points at"*, and that claim depends on core behaviour this plugin does not
  # own.
  def test_holding_a_share_link_grants_nothing_at_redmines_own_attachment_route
    _link, token = mint

    open_link(token)
    assert_response :success

    # Same anonymous session, immediately afterwards.
    get "/attachments/download/#{@document.attachment_id}"
    assert_response :redirect

    get "/attachments/#{@document.attachment_id}"
    assert_response :redirect
  end

  # ------------------------------------------------------------------ the token itself

  # THE TOKEN IS A CREDENTIAL AND MUST NOT COME BACK IN THE PAGE. A refusal page echoing it
  # would put a working link into anything that archives the response — a proxy cache, a
  # browser's reading list, a screenshot in a ticket.
  def test_no_response_echoes_the_token
    link, token = mint

    open_link(token)
    assert_not_include token, response.body

    link.revoke!
    open_link(token)
    assert_not_include token, response.body
  end

  # THE ONE PLACE THE TOKEN *DOES* TRAVEL ONWARD, PINNED RATHER THAN LEFT AS A SURPRISE.
  #
  # An independent review pointed out that the test above claims more than it tests: the
  # sign-in redirect for a non-public link puts the token in a `Location` header and into the
  # login page's HTML, because core's `require_login` uses `request.original_url` as
  # `back_url` (`application_controller.rb:290`).
  #
  # It is kept, and §Findings **S-27** carries the argument: the token is a bearer credential
  # IN A PATH, so it is already in `production.log` and in every proxy access log one line
  # earlier — and it was already in this browser's address bar and history, since the visitor
  # just followed the link. The redirect therefore opens no surface that the design does not
  # already have, and it buys the legitimate holder the thing that makes a private link
  # usable: they sign in and land on the report.
  #
  # Pinned here so that "the token appears in the 302" is a recorded decision with a reason
  # beside it, rather than something the next reviewer finds and files again.
  def test_the_sign_in_redirect_carries_the_token_by_design_and_this_is_where_that_is_recorded
    _link, token = mint(public_link: false)

    open_link(token)

    assert_response :redirect
    assert_include token, response.headers['Location'],
                   'the redirect no longer carries the token — if that was deliberate, ' \
                   'S-27 and this test need updating together'
  end
end
