# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-21 — THE MULTI-ACTOR VISIBILITY SUITE.
#
# INV-1 is this project's first invariant: every aggregation starts from the VIEWER's
# visible scope, and a permission grant never implies private issues, hidden trackers or
# restricted custom-field values. INV-3 adds that when a visibility condition cannot be
# constructed the answer fails CLOSED.
#
# Until now that was asserted by the adapter harness's four actors — which is real SQL
# but STUBBED visibility: the harness defines its own `visible_condition` because its
# whole point is not booting Redmine. A stub cannot tell you that Redmine's own rules
# still hold, only that the SQL shape survives. So this suite runs the aggregator in the
# real application against real `Role#issues_visibility`, a real private issue, a real
# role-restricted custom field and a real private `IssueQuery`.
#
# --- Why a second substrate, when golden_scope_fixture_test.rb has one ---
#
# Deliberate, and argued rather than accidental (CLAUDE.md §6 asks for one way to do a
# thing). That fixture is a FROZEN ORACLE: its answers are recorded in
# spec/golden/scope/scope.jsonl, it is explicitly irrecoverable once
# scope_resolution.rb is deleted, and HANDOVER §2 says not to disturb it. Extracting its
# builder would mean editing the file whose output must not move. These two substrates
# also answer different questions and need different rows — this one needs a
# role-restricted custom field and an actor without time-entry permission, which the
# scope fixture has no use for. Different reserved id range, so the two cannot collide.
#
# --- What "exact" means here ---
#
# Every actor's total is asserted as a NUMBER, and the numbers are asserted to be
# strictly ordered. Both halves are load-bearing: exact totals alone pass an
# implementation that shows everyone everything (they would just be wrong in one place,
# and one wrong constant is easy to "fix"), and inequality alone passes an
# implementation that shows everyone nothing.
class MultiActorVisibilityTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :issue_statuses, :trackers, :projects_trackers, :enumerations

  AGG = SqlAggregation::QueryAggregator

  # Explicit ids in a reserved range of their own. Rails inserts every fixture set ANY
  # test class in this process declares, so Redmine's own issues are in the database
  # whether this class wants them or not — every query below is therefore restricted to
  # this project, and one test asserts that nothing reaches outside it.
  PROJECT_ID = 940_001
  ROLE_ALL      = 940_010
  ROLE_DEFAULT  = 940_011
  ROLE_OWN      = 940_012
  CF_SALARY     = 940_020
  QUERY_PRIVATE = 940_030
  USER_IDS = { 'manager' => 940_101, 'member' => 940_102,
               'owner' => 940_103, 'outsider' => 940_104 }.freeze
  ISSUE_IDS = { 'mav-1' => 940_201, 'mav-2' => 940_202, 'mav-3' => 940_203,
                'mav-4' => 940_204, 'mav-5' => 940_205 }.freeze

  # The four logged-in actors plus anonymous, ordered from most to least visibility.
  # `outsider` is logged in and holds no membership; the project is NOT public, so it
  # and anonymous are the fail-closed end of the chain.
  ACTORS = %w[manager member owner outsider anonymous].freeze

  # Derived from Redmine's own Issue.visible_condition, read at 6.1-stable rather than
  # assumed — 'all' is literally `1=1` (so it DOES include private issues), 'default' is
  # "not private OR author OR assignee", 'own' drops the not-private disjunct.
  #
  #   mav-1  manager/manager            public
  #   mav-2  manager/owner              public   → owner sees it as assignee
  #   mav-3  owner/manager              public   → owner sees it as author
  #   mav-4  manager/manager            PRIVATE  → 'all' only
  #   mav-5  manager/(unassigned)       public
  EXPECTED_TOTALS = { 'manager' => 5, 'member' => 4, 'owner' => 2,
                      'outsider' => 0, 'anonymous' => 0 }.freeze

  def setup
    @tracker  = Tracker.order(:id).first
    @status   = IssueStatus.order(:id).first
    @priority = IssuePriority.order(:id).first
    build_substrate!
  end

  # ------------------------------------------------------------------
  # Exact totals, and strict inequality
  # ------------------------------------------------------------------

  test 'each actor sees exactly the issues their role allows' do
    ACTORS.each do |actor|
      as_actor(actor) do
        assert_equal EXPECTED_TOTALS.fetch(actor), AGG.flags(base_scope)['total'],
                     "#{actor} sees the wrong number of issues"
      end
    end
  end

  # The other half. Exact totals alone would pass an implementation that shows everyone
  # everything and happens to be wrong by a constant; this pins that the actors are
  # genuinely SEPARATED, and it is written as strict `<` so an equality regression —
  # two actors converging on the same answer — fails here rather than looking fine.
  test 'visibility is strictly ordered, not merely different' do
    totals = ACTORS.to_h { |actor| [actor, as_actor(actor) { AGG.flags(base_scope)['total'] }] }

    assert_operator totals['manager'], :>, totals['member'],
                    'issues_visibility all must see strictly more than default (the private issue)'
    assert_operator totals['member'], :>, totals['owner'],
                    'default must see strictly more than own'
    assert_operator totals['owner'], :>, totals['outsider'],
                    'a member must see strictly more than a non-member'
    assert_equal 0, totals['outsider']
    assert_equal 0, totals['anonymous']
  end

  test 'the private issue is visible only to the role that may see private issues' do
    ACTORS.each do |actor|
      seen = as_actor(actor) { visible_subjects }
      if actor == 'manager'
        assert_includes seen, 'mav-4', 'issues_visibility all includes private issues'
      else
        refute_includes seen, 'mav-4', "#{actor} must not see the private issue"
      end
    end
  end

  test 'no actor resolves an issue outside this substrate' do
    ACTORS.each do |actor|
      seen = as_actor(actor) { visible_subjects }
      assert_empty seen - ISSUE_IDS.keys,
                   "#{actor} reached outside the substrate — another test class's fixtures " \
                   'are in this database, so an unrestricted scope silently widens'
    end
  end

  # ------------------------------------------------------------------
  # The role-restricted custom field — values AND the name
  # ------------------------------------------------------------------

  # THE POINT OF THIS ONE: a values-only assertion passes a leaky implementation. If the
  # aggregator refuses the values but still labels the axis "Salary", an unentitled
  # viewer learns the field exists, what it is called, and (from the bucket count) how
  # many distinct values it has. So the assertion is that the NAME appears NOWHERE in
  # anything the aggregator hands back — across every entry point that takes a field.
  test 'an unentitled viewer sees the restricted field nowhere in any result' do
    %w[member owner outsider anonymous].each do |actor|
      as_actor(actor) do
        results = [
          AGG.dimension_breakdown(base_scope, group_by: "cf_#{CF_SALARY}"),
          AGG.dimension_breakdown(base_scope, group_by: 'status', split_by: "cf_#{CF_SALARY}"),
          AGG.dimension_breakdown(base_scope, group_by: 'status', measure: 'sum',
                                              of: "cf_#{CF_SALARY}"),
          AGG.completeness(base_scope, fields: ["cf_#{CF_SALARY}"]),
          AGG.version_rollup(base_scope, cost_field_ids: [CF_SALARY])
        ]

        serialized = results.map(&:inspect).join(' ')
        refute_includes serialized, 'Salary',
                        "#{actor} is not entitled to the restricted field, and its NAME leaked"
        refute_includes serialized, '1234.5',
                        "#{actor} is not entitled to the restricted field, and its VALUE leaked"
      end
    end
  end

  test 'the entitled viewer does see the restricted field, so the refusal means something' do
    as_actor('manager') do
      result = AGG.dimension_breakdown(base_scope, group_by: "cf_#{CF_SALARY}")

      refute_nil result, 'the manager holds the entitled role and must get an answer'
      assert_includes result['buckets'].map { |b| b['label'] }, '1234.5'
    end
  end

  # ------------------------------------------------------------------
  # Time entries — a permission, not a visibility rule
  # ------------------------------------------------------------------

  test 'spent time is summed only for actors holding view_time_entries' do
    entitled   = as_actor('manager') { spent_total }
    unentitled = as_actor('owner')   { spent_total }

    assert_equal 3.5, entitled, 'the manager holds :view_time_entries in this project'
    assert_equal 0.0, unentitled,
                 'the owner role has no :view_time_entries, and a LEFT JOIN whose ON clause ' \
                 'fails closed must contribute nothing rather than everything'
  end

  # ------------------------------------------------------------------
  # A private saved query is not another user's numbers (FR-08)
  # ------------------------------------------------------------------

  test 'a private saved query is invisible to everyone but its owner' do
    assert_equal QUERY_PRIVATE, as_actor('manager') { visible_query_id },
                 'the owner must still resolve their own private query'

    %w[member owner outsider anonymous].each do |actor|
      assert_nil as_actor(actor) { visible_query_id },
                 "#{actor} must not resolve another user's private query — an invisible query " \
                 'has to be indistinguishable from a missing one'
    end
  end

  # ------------------------------------------------------------------
  # A true zero is not a refusal
  # ------------------------------------------------------------------

  # FR-23 says "a refusal is distinguishable from a true zero". That FR introduces a
  # `degraded` flag on every result and NOTHING BUILDS IT YET — no task in the plan
  # names FR-23 (§Findings F-6). What is testable today is the same distinction in
  # today's contract: a refusal answers `nil`, a correctly-applied filter that matches
  # nothing answers a RESULT whose numbers are zero. Both halves are asserted, so the
  # day the flag arrives this test says what it should become.
  test 'a filter that legitimately matches nothing answers zero, not a refusal' do
    as_actor('manager') do
      empty = base_scope.where(subject: 'no such issue')
      result = AGG.dimension_breakdown(empty, group_by: 'status')

      refute_nil result, 'an empty match is a result, not a refusal'
      assert_equal 0, result['total']
      assert_equal [], result['buckets']
    end
  end

  test 'a refusal answers nil, so it cannot be mistaken for a zero' do
    as_actor('manager') do
      assert_nil AGG.dimension_breakdown(base_scope, group_by: 'cf_nonexistent'),
                 'an unusable argument is refused, and a refusal is nil rather than an empty result'
    end
  end

  # ------------------------------------------------------------------
  # Ordering — the failure mode a per-actor suite is blind to by default
  # ------------------------------------------------------------------

  # A memoised User.current, a cached visibility condition or a class-level ivar gives
  # the SECOND actor in a process the FIRST one's answer. Every test above would still
  # pass: each asserts one actor at a time, and whichever ran first would be right.
  #
  # Not paranoia — this aggregator already memoises its adapter family on the class
  # (`@adapter_family`), so class-level caching is an established habit in this file.
  test 'two actors in one process answer independently, in either order' do
    forwards = { 'manager' => as_actor('manager') { total }, 'owner' => as_actor('owner') { total } }
    backwards = { 'owner' => as_actor('owner') { total }, 'manager' => as_actor('manager') { total } }

    assert_equal EXPECTED_TOTALS['manager'], forwards['manager']
    assert_equal EXPECTED_TOTALS['owner'],   forwards['owner']
    assert_equal forwards, backwards,
                 'the answers depend on the order the actors ran in — something is cached across ' \
                 'actors, which is the shape of one user seeing another user\'s numbers'
  end

  # A/B/A specifically: A→B→A catches a cache that is populated on the first call and
  # never invalidated, which the two-order test above can still miss if B happens to
  # populate nothing.
  test 'an actor asked twice around another actor answers the same both times' do
    first  = as_actor('manager') { total }
    _other = as_actor('owner')   { total }
    second = as_actor('manager') { total }

    assert_equal EXPECTED_TOTALS['manager'], first
    assert_equal first, second,
                 'the manager got a different answer after another actor ran in the same process'
  end

  # ------------------------------------------------------------------
  # The monotonicity property
  # ------------------------------------------------------------------

  # For actors u1 ⊆ u2, every count for u1 ≤ u2 — over every parameter combination
  # below rather than a hand-maintained expected value per combination. TWO LIMITS, and
  # they are written here rather than discovered later, because a property test that
  # produces false failures gets deleted within a week:
  #
  #   1. ONE-SIDED. A regression where BOTH actors see too much passes by equality. It
  #      only means something paired with the strict-inequality test above, which is why
  #      that test exists separately and must not be merged into this one.
  #   2. NOT APPLICABLE TO avg/distinct. Removing rows can RAISE an average, and a
  #      distinct count is not additive either. Only the additive measures are swept.
  SUBSET_PAIRS = [%w[owner member], %w[member manager], %w[outsider owner]].freeze
  SWEEP = [
    { group_by: 'status' },
    { group_by: 'assignee' },
    { group_by: 'author' },
    { group_by: 'period', period: 'month', periods: 6 },
    { group_by: 'age', age_buckets: [30, 60, 90, 180] },
    { group_by: 'status', split_by: 'assignee' },
    { group_by: 'status', measure: 'sum', of: 'estimated_hours' }
  ].freeze

  test 'a narrower actor never counts more than a wider one, over every shape' do
    SWEEP.each do |args|
      counts = ACTORS.to_h do |actor|
        [actor, as_actor(actor) { AGG.dimension_breakdown(base_scope, **args)&.fetch('total') }]
      end

      SUBSET_PAIRS.each do |narrow, wide|
        assert_operator counts[narrow], :<=, counts[wide],
                        "#{args.inspect}: #{narrow} counted more than #{wide}, so a narrower " \
                        'actor is seeing something a wider one cannot'
      end
    end
  end

  private

  # Redmine's own visible scope, which is what every aggregator entry point is supposed
  # to be handed. Restricted to this project for the reason in the class comment.
  def base_scope
    Issue.visible(User.current).where(project_id: PROJECT_ID)
  end

  def total
    AGG.flags(base_scope)['total']
  end

  def visible_subjects
    base_scope.reorder(nil).distinct.pluck(:subject).sort
  end

  def spent_total
    AGG.dimension_breakdown(base_scope, group_by: 'status', measure: 'sum',
                                        of: 'spent_hours')['total']
  end

  def visible_query_id
    IssueQuery.visible(User.current).find_by(id: QUERY_PRIVATE)&.id
  end

  def as_actor(name)
    previous = User.current
    User.current = name == 'anonymous' ? User.anonymous : @users.fetch(name)
    yield
  ensure
    User.current = previous
  end

  # ------------------------------------------------------------------
  # The substrate
  # ------------------------------------------------------------------

  def build_substrate!
    build_roles!
    build_project!
    build_users!
    build_issues!
    build_custom_field!
    build_time_entry!
    build_private_query!
  end

  def build_roles!
    @roles = {}
    # :view_issues everywhere; :view_time_entries only where an actor is meant to have
    # it, because that permission is the whole subject of one test above.
    @roles['all'] = create_role(ROLE_ALL, 'all', %i[view_issues view_time_entries])
    @roles['default'] = create_role(ROLE_DEFAULT, 'default', %i[view_issues view_time_entries])
    @roles['own'] = create_role(ROLE_OWN, 'own', %i[view_issues])
  end

  def create_role(id, visibility, permissions)
    Role.create!(id: id, name: "RRD MAV #{visibility} #{id}", permissions: permissions,
                 issues_visibility: visibility)
  end

  # NOT public: `outsider` and `anonymous` are the fail-closed end of the chain, and a
  # public project would give them Redmine's built-in Non-member/Anonymous roles —
  # making this suite depend on Redmine's own fixtures rather than on its own substrate.
  def build_project!
    @project = Project.create!(id: PROJECT_ID, name: 'rrd-mav', identifier: 'rrd-mav',
                               is_public: false)
    @project.enabled_module_names = %w[issue_tracking time_tracking]
    @project.trackers = [@tracker]
    @project
  end

  def build_users!
    @users = USER_IDS.keys.to_h { |key| [key, create_user(key)] }
    Member.create!(principal: @users['manager'], project: @project, roles: [@roles['all']])
    Member.create!(principal: @users['member'], project: @project, roles: [@roles['default']])
    Member.create!(principal: @users['owner'], project: @project, roles: [@roles['own']])
    # `outsider` gets no membership on purpose.
  end

  def create_user(key)
    User.generate!(id: USER_IDS.fetch(key), login: "rrd-mav-#{key}", firstname: 'Mav',
                   lastname: key, mail: "rrd-mav-#{key}@example.net", language: 'en')
  end

  def build_issues!
    @issues = {}
    @issues['mav-1'] = create_issue('mav-1', author: 'manager', assignee: 'manager')
    @issues['mav-2'] = create_issue('mav-2', author: 'manager', assignee: 'owner')
    @issues['mav-3'] = create_issue('mav-3', author: 'owner',   assignee: 'manager')
    @issues['mav-4'] = create_issue('mav-4', author: 'manager', assignee: 'manager', private: true)
    @issues['mav-5'] = create_issue('mav-5', author: 'manager')
  end

  def create_issue(subject, author:, assignee: nil, private: false)
    Issue.create!(id: ISSUE_IDS.fetch(subject), project: @project, tracker: @tracker,
                  status: @status, priority: @priority, subject: subject,
                  author: @users.fetch(author),
                  assigned_to: assignee && @users.fetch(assignee),
                  estimated_hours: 1.0, is_private: private)
  end

  # `visible: false` plus a role list is Redmine's ROLE-restricted custom field: the
  # values are readable only where the viewer holds one of those roles in the issue's
  # project. The manager holds ROLE_ALL here; nobody else does.
  def build_custom_field!
    @custom_field = IssueCustomField.create!(
      id: CF_SALARY, name: 'Salary', field_format: 'float',
      is_for_all: true, visible: false, role_ids: [ROLE_ALL], tracker_ids: [@tracker.id]
    )
    # RELOADED, not the object from build_issues!. Redmine's Issue carries a
    # `lock_version`, and creating an `is_for_all` custom field touches the issues it
    # now applies to — so the in-memory copy is stale by the time we get here and
    # `save!` raises StaleObjectError. Reading it back is the whole fix.
    issue = Issue.find(ISSUE_IDS.fetch('mav-1'))
    issue.custom_field_values = { CF_SALARY => '1234.5' }
    issue.save!
    @issues['mav-1'] = issue
  end

  def build_time_entry!
    TimeEntry.create!(project: @project, issue: @issues['mav-1'], user: @users['manager'],
                      author: @users['manager'], hours: 3.5, spent_on: Date.current,
                      activity: TimeEntryActivity.order(:id).first)
  end

  # Owned by the manager, PRIVATE. Nobody else may resolve it, and FR-08 says an
  # invisible query must be indistinguishable from a missing one.
  def build_private_query!
    query = IssueQuery.new(id: QUERY_PRIVATE, name: 'RRD MAV private',
                           user: @users['manager'], visibility: IssueQuery::VISIBILITY_PRIVATE,
                           project: @project)
    query.filters = { 'project_id' => { operator: '=', values: [PROJECT_ID.to_s] } }
    query.save!
    query
  end
end
