# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-28 — the share link, against a real database. FR-51/52/53.
#
# --- WHY THE FULL APP ---
#
# Every claim this model makes is about the database or about concurrency, and a double
# cannot fail any of them: "only the digest is stored" needs a real row to read back, the
# unique index is what makes two links with one digest impossible, and `max_uses` is a
# promise a second connection has to be unable to break.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. There is none here; every
# helper is above the tests and the run count is checked against `grep -c '^  def test_'`.
class ReporterDashboardsShareLinkTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  ShareLink = RedmineReporterDashboards::ShareLink
  Template = RedmineReporterDashboards::Template

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @jsmith = User.find_by!(login: 'jsmith')
    @dlopper = User.find_by!(login: 'dlopper')
    @admin = User.find(1)
    assert @admin.admin?, 'user 1 must be an administrator'
    @template = Template.create!(project: @project, author: @jsmith, name: 'Shared',
                                 content: '<p>x</p>', source: 'issues', output: 'combined')
  end

  # ------------------------------------------------------------------ helpers

  def link_attributes(overrides = {})
    { template: @template, project: @project, created_by: @jsmith,
      scope_kind: ShareLink::SCOPE_QUERY, expires_at: 30.days.from_now }.merge(overrides)
  end

  def mint(overrides = {})
    ShareLink.create_with_token!(link_attributes(overrides))
  end

  # ------------------------------------------------------------------ the token

  # THE CENTRAL CLAIM, AND IT IS ABOUT WHAT IS *NOT* THERE. The base plugin's token is
  # derivable from the row; this one must not be recoverable from the database at all.
  def test_the_token_itself_is_nowhere_in_the_row
    link, token = mint

    assert_not_nil token
    row = ShareLink.connection.select_one(
      "SELECT * FROM #{ShareLink.table_name} WHERE id = #{link.id}"
    )
    row.each_value do |value|
      next unless value.is_a?(String)

      assert_not_equal token, value
      # ARGUMENT ORDER, AND IT IS NOT A NICETY. Redmine's helper is
      # `assert_not_include(expected, s)` → `!s.include?(expected)` (core
      # `test/test_helper.rb:258`), so the NEEDLE COMES FIRST. Written the other way round
      # — which is how this line shipped in T-28 increment 1 — it asked whether the
      # 43-character token contains a 64-character digest, which is false for every input,
      # and the central security claim of this file passed without testing anything.
      # Found by the same mistake failing loudly in a sibling test one increment later.
      assert_not_include token, value.to_s,
                         'the plain token appears in a column, so a database dump leaks it'
    end
  end

  # AND NOT IN ANY OTHER TABLE EITHER — which is the claim a dump actually tests. Written
  # as a sweep rather than against the one table, because the failure this guards against
  # is somebody later "helpfully" caching the token somewhere convenient.
  def test_no_table_in_this_schema_holds_the_plain_token
    _link, token = mint

    %w[reporter_dashboards_share_links reporter_dashboards_share_link_accesses
       reporter_dashboards_templates reporter_dashboards_documents].each do |table|
      next unless ShareLink.connection.table_exists?(table)

      columns = ShareLink.connection.columns(table).select { |c| c.type == :string || c.type == :text }
      columns.each do |column|
        found = ShareLink.connection.select_value(
          "SELECT COUNT(*) FROM #{table} WHERE #{column.name} = #{ShareLink.connection.quote(token)}"
        )
        assert_equal 0, found.to_i, "#{table}.#{column.name} holds the plain token"
      end
    end
  end

  def test_the_digest_is_sha256_hex_and_the_token_is_32_random_bytes
    _link, token = mint

    # 32 bytes of randomness, base64-urlsafe, is 43 characters — not 32, which is the
    # mistake `urlsafe_base64(32)` invites.
    assert_equal 43, token.length
    assert_match(/\A[A-Za-z0-9_-]+\z/, token)
    assert_equal 64, ShareLink.digest_for(token).length
  end

  def test_two_links_never_share_a_token
    _a, token_a = mint
    _b, token_b = mint

    assert_not_equal token_a, token_b
  end

  # THE UNIQUE INDEX IS THE ARBITER, not the model. Two rows with one digest would mean two
  # answers to "what does this token authorise" and the resolver takes the first.
  def test_the_database_refuses_a_duplicate_digest
    link, _token = mint

    duplicate = ShareLink.new(link_attributes)
    duplicate.token_digest = link.token_digest

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  # ------------------------------------------------------------------ lookup

  def test_a_valid_token_finds_its_link
    link, token = mint

    assert_equal link.id, ShareLink.find_by_token(token).id
  end

  def test_a_wrong_token_finds_nothing
    mint

    assert_nil ShareLink.find_by_token(ShareLink.generate_token)
  end

  # NOT A PREFIX, NOT A SUFFIX, NOT EMPTY. Each is a way a fuzzy lookup would leak: a
  # prefix match would let an attacker walk the token one character at a time.
  def test_a_partial_token_finds_nothing
    _link, token = mint

    [token[0, 20], token[0..-2], "#{token}x", '', ' '].each do |candidate|
      assert_nil ShareLink.find_by_token(candidate),
                 "#{candidate.inspect} resolved to a link"
    end
  end

  # THE CONSTANT-TIME COMPARE, WHICH IS UNREACHABLE ON THIS ENGINE AND TESTED ANYWAY.
  #
  # An independent review found that deleting `fixed_length_secure_compare` from
  # `find_by_token` breaks nothing — correctly, because on PostgreSQL a row found BY digest
  # necessarily HAS that digest, so the comparison can only ever agree. Its purpose is stated
  # in the model and is entirely about futures: a prefix index, a `LIKE`, or MySQL's
  # case-insensitive default collation (which this schema runs on in CI) would each turn the
  # exact match into a near match, silently.
  #
  # "Untestable because the lookup is exact today" is how a control gets deleted by somebody
  # tidying up. So the fuzzy lookup is SIMULATED: a subclass whose `find_by` answers a record
  # that does NOT carry the requested digest, which is exactly what those three futures
  # produce. With the compare in place the answer is nil; without it, the wrong link is
  # returned and this fails.
  class FuzzyLookupLink < RedmineReporterDashboards::ShareLink
    # `find_by` is what `find_by_token` calls. This one ignores the condition entirely,
    # standing in for a collation or an index that matched more than it should.
    def self.find_by(*)
      order(:id).first
    end
  end

  def test_a_lookup_that_matched_too_much_is_still_refused_by_the_digest_comparison
    link, _token = mint

    # The control: the subclass really does answer a row for a token that is not its own.
    assert_equal link.id, FuzzyLookupLink.find_by(token_digest: 'nonsense')&.id,
                 'the stand-in did not match loosely, so this test asserts nothing'

    assert_nil FuzzyLookupLink.find_by_token(ShareLink.generate_token),
               'a loose match was accepted, so the constant-time comparison is not guarding'
  end

  # ------------------------------------------------------------------ the three refusals

  def test_an_expired_link_is_refused_and_says_so
    link, _token = mint(expires_at: 1.hour.ago)

    assert_equal :expired, link.refusal
    assert_not link.usable?
  end

  def test_a_revoked_link_is_refused_and_says_so
    link, _token = mint

    assert link.revoke!
    assert_equal :revoked, link.reload.refusal
  end

  def test_a_link_at_its_use_limit_is_refused_and_says_so
    link, _token = mint(max_uses: 1)

    assert_nil link.use!
    assert_equal :exhausted, link.reload.refusal
  end

  # AT THE LIMIT AND ONE PAST IT — CLAUDE.md §3's rule for anything with a limit.
  def test_a_link_works_exactly_max_uses_times
    link, _token = mint(max_uses: 3)

    3.times { |i| assert_nil link.use!, "use #{i + 1} of 3 was refused" }
    assert_equal :exhausted, link.use!
    assert_equal 3, link.reload.use_count
  end

  def test_a_link_with_no_limit_keeps_working
    link, _token = mint(max_uses: nil)

    5.times { assert_nil link.use! }
    assert_equal 5, link.reload.use_count
  end

  # ------------------------------------------------------------------ concurrency
  #
  # MOVED OUT OF THIS FILE, AND THAT IS THE FINDING RATHER THAN A TIDY-UP. The test that was
  # here spawned two threads through `connection_pool.with_connection` and asserted that a
  # single-use link serves once. Its own comment said it needed SEPARATE CONNECTIONS to mean
  # anything. Measured, in this file's configuration:
  #
  #     use_transactional_tests=true
  #     distinct_connection_objects=1  backend_pids=[3693]
  #
  # `use_transactional_tests` PINS the pool to the fixture connection, so both threads shared
  # one PostgreSQL backend and the "race" was serialised by being the same session. An
  # independent review then proved the consequence: swapping `use!` for the exact lost-update
  # implementation it exists to prevent left the suite green.
  #
  # The property is real and is now tested in
  # `test/unit/reporter_dashboards_share_link_concurrency_test.rb`, which turns transactional
  # fixtures OFF — the only way to get two connections — and therefore has to be its own
  # class, because `use_transactional_tests` is per class.
  #
  # ------------------------------------------------------------------ using

  def test_using_a_link_records_when_it_was_last_used
    link, _token = mint

    assert_nil link.last_used_at
    link.use!
    assert_not_nil link.reload.last_used_at
  end

  def test_a_refused_link_does_not_consume_a_use
    link, _token = mint(max_uses: 5, expires_at: 1.hour.ago)

    assert_equal :expired, link.use!
    assert_equal 0, link.reload.use_count
  end

  # ------------------------------------------------------------------ revocation

  # REVOKING TWICE MUST NOT MOVE THE MOMENT IT HAPPENED — that is the one fact the column
  # carries, and an audit that can be rewritten by pressing a button twice is not one.
  def test_revoking_an_already_revoked_link_changes_nothing
    link, _token = mint
    link.revoke!
    first = link.reload.revoked_at

    assert_not link.revoke!
    assert_equal first, link.reload.revoked_at
  end

  # OWNERSHIP, NOT A PERMISSION — T-28's `Accept:` in as many words: *"revocation stays
  # with the link's creator, the template's owner and admins, which is ownership rather
  # than a permission, and a test asserts a third party holding BOTH permissions still
  # cannot revoke somebody else's link."*
  #
  # THE THIRD PARTY IS GIVEN EVERY GRANTABLE PERMISSION, not the two named ones, and that
  # is stronger rather than weaker. The first version granted
  # `share_reporter_dashboards_reports` and `publish_reporter_dashboards_reports` by name —
  # and its own discriminator caught that they are still PLANNED rather than registered
  # (they are promoted with the controller), so `allowed_to?` was false and the test
  # asserted nothing at all. Granting the whole setable set says the real thing: NO
  # permission confers revocation. The two share permissions join that set automatically
  # the moment they are promoted, so this test gets stronger rather than needing an edit.
  def test_a_third_party_holding_every_grantable_permission_cannot_revoke_anothers_link
    link, _token = mint(created_by: @jsmith)
    role = Role.find(1)
    role.permissions = role.setable_permissions.map(&:name)
    role.save!
    User.current = nil

    assert @dlopper.allowed_to?(:view_issues, @project),
           'the fixture must actually grant permissions, or this asserts nothing'
    assert role.permissions.length > 10,
           'the whole setable set should be a large list; a short one means it did not apply'
    assert_not link.revocable_by?(@dlopper)
  end

  def test_the_creator_the_template_owner_and_an_admin_may_revoke
    link, _token = mint(created_by: @dlopper)

    assert link.revocable_by?(@dlopper), 'the creator'
    assert link.revocable_by?(@jsmith), "the template's author"
    assert link.revocable_by?(@admin), 'an administrator'
  end

  def test_anonymous_may_never_revoke
    link, _token = mint

    assert_not link.revocable_by?(User.anonymous)
    assert_not link.revocable_by?(nil)
  end

  # ------------------------------------------------------------------ the schema's rules

  def test_an_expiry_is_mandatory
    link = ShareLink.new(link_attributes(expires_at: nil))
    link.token_digest = ShareLink.digest_for('x')

    assert_not link.valid?
    assert_includes link.errors.attribute_names, :expires_at
  end

  def test_a_scope_kind_outside_the_closed_set_is_refused
    link = ShareLink.new(link_attributes(scope_kind: 'anything'))
    link.token_digest = ShareLink.digest_for('x')

    assert_not link.valid?
    assert_includes link.errors.attribute_names, :scope_kind
  end

  # T-28 INCREMENT 2 — A LINK MUST NOT OUTLIVE THE ARTEFACT IT AUTHORISES. `Document` bounds
  # how long a stored snapshot may live; a link expiring after that would point at bytes the
  # purge task is entitled to collect, and would work for months and then answer "no longer
  # stored" for a reason nobody could reconstruct.
  #
  # AT THE BOUND AND ONE PAST IT — CLAUDE.md §3's rule for anything with a limit.
  def test_a_link_may_not_outlive_the_snapshot_stores_own_retention_bound
    at_the_bound = ShareLink.new(link_attributes(expires_at: Time.zone.now + ShareLink::MAX_LIFETIME - 1.day))
    at_the_bound.token_digest = ShareLink.digest_for('a')
    past_it = ShareLink.new(link_attributes(expires_at: Time.zone.now + ShareLink::MAX_LIFETIME + 1.day))
    past_it.token_digest = ShareLink.digest_for('b')

    assert at_the_bound.valid?, at_the_bound.errors.full_messages.join(', ')
    assert_not past_it.valid?
    assert_includes past_it.errors.attribute_names, :expires_at
  end

  # AND THE BOUND IS THE DOCUMENT STORE'S, not a second number that happens to agree today.
  # Two constants drifting apart is how a window opens in which one is right and the other
  # is nearly right.
  def test_the_lifetime_bound_is_the_document_stores_own
    assert_equal RedmineReporterDashboards::Document::MAX_RETENTION, ShareLink::MAX_LIFETIME
  end

  # ------------------------------------------------------------------ the access log

  def test_an_access_is_recorded_with_its_address_and_agent
    link, _token = mint

    access = link.record_access!(outcome: 'served', ip_address: '203.0.113.7',
                                 user_agent: 'Probe/1.0')

    assert_equal 'served', access.outcome
    assert_equal '203.0.113.7', access.ip_address
    assert_equal 'Probe/1.0', access.user_agent
    assert_not_nil access.created_at
  end

  # THE OUTCOME SET IS CLOSED, because a stored string a reader groups by turns a typo into
  # its own silent category in somebody's count.
  def test_an_outcome_outside_the_closed_set_is_refused
    link, _token = mint

    assert_raises(ActiveRecord::RecordInvalid) do
      link.record_access!(outcome: 'probably_fine')
    end
  end

  # BOTH ATTACKER-SUPPLIED FIELDS ARE BOUNDED, and truncated rather than refused: losing the
  # tail of a user agent is nothing, losing the audit row is the thing the table exists to
  # prevent.
  def test_an_enormous_user_agent_is_truncated_rather_than_losing_the_row
    link, _token = mint

    access = link.record_access!(outcome: 'served', ip_address: '9' * 4_000,
                                 user_agent: 'A' * 4_000)

    assert_equal RedmineReporterDashboards::ShareLinkAccess::MAX_STRING, access.user_agent.length
    assert_equal RedmineReporterDashboards::ShareLinkAccess::MAX_STRING, access.ip_address.length
  end

  # FR-52: a snapshot link exists to serve bytes that already exist. One with no document
  # would have to fall back to rendering — the opposite behaviour under the same name.
  def test_a_snapshot_link_without_a_document_is_refused
    link = ShareLink.new(link_attributes(scope_kind: ShareLink::SCOPE_SNAPSHOT))
    link.token_digest = ShareLink.digest_for('x')

    assert_not link.valid?
    assert_includes link.errors.attribute_names, :rendered_document_id
  end

  # DELETING THE TEMPLATE IS THE MOST EMPHATIC REVOCATION THERE IS. A link left behind
  # would mean deleting a report quietly failed to un-share it.
  def test_destroying_the_template_destroys_its_links
    mint

    assert_difference 'RedmineReporterDashboards::ShareLink.count', -1 do
      @template.destroy
    end
  end
end
