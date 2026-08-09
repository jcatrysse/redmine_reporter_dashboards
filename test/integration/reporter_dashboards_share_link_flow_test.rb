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
      Snapshot.capture(template: @template, render_as: @jsmith, project: @project,
                       created_by: @jsmith, expires_at: 30.days.from_now)
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
end
