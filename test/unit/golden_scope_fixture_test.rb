# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require File.expand_path('../../spec/golden/scope_fixture', __dir__)

# THE SCOPE FIXTURE (T-01) — what `ScopeResolution` resolves, frozen before it is
# replaced.
#
# The aggregation NUMBERS are regenerable from the baseline commit; the SCOPE is not.
# `lib/sql_aggregation/scope_resolution.rb` answers two questions — "what do I count?"
# (`resolve_scope`) and "which IssueQuery was this built from?" (`resolve_query`) — for
# every combination of tag markup, render context, stored query and viewer. T-07
# replaces it with `Liquid::ScopeBinding` and T-08 deletes it. After that there is no
# way to ask the old code anything, and no way to notice that the new code resolves a
# different set of issues.
#
# So this runs the real thing, in the real application, and writes down the answers.
#
# --- Why here and not in spec/adapter ---
#
# Corrected in the plan on 2026-08-05, and it is the reason this file exists at all:
# the value corpus can be generated from the adapter harness, but the scope cannot.
# `resolve_scope` reaches `Issue.visible`, `IssueQuery.visible` and a thread-local —
# none of which exist in a harness whose whole point is not booting Redmine. Real
# roles, real `issues_visibility`, real private issues and a real `IssueQuery` only
# exist here.
#
# --- The substrate is ours, and bounded ---
#
# Everything the triples touch is created by this test at EXPLICIT ids in a reserved
# range: four projects, three roles, five users, ten issues, three queries. Two
# reasons, both learned the hard way on the first run:
#
#   * Rails inserts every fixture set any test class in the process declares, and
#     other tests here declare :issues. Nine of Redmine's own fixture issues therefore
#     appeared in a cross-project query — in SOME of these tests, depending on the
#     order the classes ran in. So every query and every drop the triples use is
#     restricted to this substrate, and one test asserts that no resolved scope ever
#     reaches outside it. Order-dependence is not a thing to hope about.
#   * ids must be unique ACROSS TABLES for the SQL tokeniser below to be exact — a
#     project and a query that happen to share an id would tokenise each other's
#     literals. Explicit ids in one reserved range give that, and make the recorded
#     issue-id set stable on every branch as well.
#
#   RRD_SCOPE_WRITE=1  regenerates spec/golden/scope/scope.jsonl and
#                      spec/golden/sql/scope_sql.jsonl. Commit both.
class GoldenScopeFixtureTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :issue_statuses, :trackers, :projects_trackers, :enumerations

  # The two methods of Liquid::Context that ScopeResolution actually uses: `[]` for a
  # named variable and `registers` for what the host stored. A stand-in rather than a
  # real Liquid::Context because Liquid is redmine_reporter's gem, and this suite has
  # to run STANDALONE — the configuration CI proves.
  class FakeContext
    attr_reader :registers

    def initialize(variables = {}, registers = {})
      @variables = variables
      @registers = registers
    end

    def [](key)
      @variables[key.to_s]
    end
  end

  # An IssuesDrop stand-in. Its ivars are what scope_from_drop rummages through, so
  # what matters is which ivar holds what, not the class.
  class FakeDrop
    def initialize(issues: nil, scope: nil)
      @issues = issues if issues
      @sql_base_scope = scope if scope
    end
  end

  # The host tag: ScopeResolution is a mixin expecting @raw_params.
  class Host
    include SqlAggregation::ScopeResolution

    def initialize(raw_params)
      @raw_params = raw_params
    end
  end

  # (template, query, actor) — the triples, as the plan's acceptance list names them.
  # `template` is the tag markup plus how the render context arrives, because that is
  # what a template can actually vary; the eleven of them are exactly the resolution
  # paths the module's own comment documents, so a path nobody thought to freeze would
  # have to be a path nobody documented either.
  TEMPLATES = %w[query_id_param query_id_context registers_sql_issue_query
                 registers_container_query registers_container_relation
                 registers_controller thread_local drop_array drop_relation
                 drop_base_scope no_source].freeze

  QUERIES = %w[public_all private_other project_scoped absent none].freeze
  ACTORS  = %w[manager developer reporter anonymous].freeze

  # 46 triples. Not the full 11 x 5 x 4 cross product — that would be 220 records
  # dominated by combinations that cannot differ (a `no_source` template resolves the
  # same nil whichever query it is not given). Every path is covered under at least
  # two actors, every actor sees every visibility rule at least once, and the paths
  # whose answer is actor-dependent are covered under all four.
  def self.triples
    core = %w[query_id_param registers_sql_issue_query registers_container_relation
              registers_controller drop_array no_source]
    rest = %w[query_id_context registers_container_query drop_relation drop_base_scope
              thread_local]

    # `no_source` is paired with the 'none' query because that is what it means: no
    # query is offered at all. Everything else names one.
    triples = ACTORS.flat_map do |actor|
      core.map { |template| [template, template == 'no_source' ? 'none' : 'public_all', actor] }
    end
    triples += ACTORS.map { |actor| ['query_id_param', 'private_other', actor] }
    triples += ACTORS.map { |actor| ['registers_sql_issue_query', 'project_scoped', actor] }
    triples += ACTORS.map { |actor| ['query_id_param', 'absent', actor] }
    triples += %w[manager reporter].flat_map { |actor| rest.map { |t| [t, 'public_all', actor] } }
    triples
  end

  TRIPLES = triples.freeze

  # Set once per process by #regenerate_once!, never reset: a regenerating run must
  # write the fixture BEFORE any example reads it, and minitest runs the methods of a
  # class in a random order, so the write cannot live inside one of them. It did, on the
  # first regeneration, and the SQL example failed against the file the scope example
  # had not written yet.
  class << self
    attr_accessor :regenerated
  end

  def setup
    @previous_user = User.current
    User.current = User.find(1) # admin, for the setup writes only
    build_substrate!
    User.current = nil
    regenerate_once!
  end

  def teardown
    Thread.current[SqlAggregation::ScopeResolution::QUERY_THREAD_KEY] = nil
    User.current = @previous_user
  end

  # ------------------------------------------------------------------
  # The fixture
  # ------------------------------------------------------------------

  # TEMPLATES and QUERIES are the documented surface; this is what stops the triple
  # list from quietly covering less than it claims.
  def test_every_documented_resolution_path_and_query_is_covered
    assert_equal TEMPLATES.sort, TRIPLES.map(&:first).uniq.sort
    assert_equal QUERIES.sort, TRIPLES.map { |triple| triple[1] }.uniq.sort
    assert_equal ACTORS.sort, TRIPLES.map(&:last).uniq.sort
    assert_equal 46, TRIPLES.length
    assert_equal TRIPLES.length, TRIPLES.uniq.length
  end

  def test_the_reserved_id_range_is_ours
    # If a future Redmine fixture set reaches into this range, the tokeniser below
    # would rewrite someone else's literals and the SQL tree would quietly stop
    # describing these scopes. Cheap to check, silent to lose.
    assert_equal [], Project.where(id: ID_RANGE).where.not(id: @tokens.keys).pluck(:id)
    assert_equal [], Issue.where(id: ID_RANGE).where.not(id: @tokens.keys).pluck(:id)
    assert_equal [], User.where(id: ID_RANGE).where.not(id: @tokens.keys).pluck(:id)
    assert_equal ISSUE_KEYS.sort, Issue.where(id: ID_RANGE).pluck(:subject).sort
  end

  # The invariant that replaces "no other issue exists": other issues may well exist —
  # Rails inserts whatever fixture sets the process declares — so what has to hold is
  # that nothing the triples resolve can reach them.
  def test_no_resolved_scope_reaches_outside_the_substrate
    TRIPLES.each do |triple|
      resolved = issues_for(*triple)
      next if resolved.nil?

      assert_equal [], resolved - ISSUE_KEYS,
                   "#{triple.join('|')} resolved an issue this test did not create. Every query " \
                   'and drop the triples use must be restricted to the substrate, or the fixture ' \
                   'depends on which other test classes ran first.'
    end
  end

  def test_the_resolved_scope_matches_the_frozen_fixture
    records  = TRIPLES.map { |triple| record_for(*triple) }
    expected = RrdGolden::ScopeFixture.scopes
    assert_equal TRIPLES.length, expected.length,
                 'the committed scope fixture does not have one record per triple — regenerate ' \
                 "it with #{RrdGolden::ScopeFixture::WRITE_ENV}=1"

    mismatches = records.filter_map do |record|
      frozen = expected[record['triple']]
      next "#{record['triple']}: no committed record" if frozen.nil?

      differences = %w[issues count query_resolved].filter_map do |field|
        next if frozen[field] == record[field]

        "#{field}: frozen #{frozen[field].inspect} -> now #{record[field].inspect}"
      end
      next if differences.empty?

      "#{record['triple']}\n      #{differences.join("\n      ")}"
    end

    assert_equal [], mismatches, <<~MESSAGE
      the resolved scope has changed for #{mismatches.length} triple(s):

          #{mismatches.join("\n\n    ")}

      This fixture is the record of what 0.5.0's ScopeResolution resolved. A difference is
      either a regression in scope resolution or the deliberate change T-07 was meant to
      make — and if it is the latter, say so in the pull request and regenerate with
      #{RrdGolden::ScopeFixture::WRITE_ENV}=1. It is not a fixture to nudge into line.
    MESSAGE
  end

  # The sibling tree. SQL is EXPECTED to change at the re-seam, so it is recorded
  # rather than frozen — but "recorded" must still mean something, hence two
  # assertions: the tokens and tables a statement references cannot change silently
  # even on a Redmine whose own visibility SQL is spelled differently.
  def test_the_generated_sql_is_recorded_and_still_references_the_same_things
    records = TRIPLES.map { |triple| record_for(*triple) }
    committed = RrdGolden::ScopeFixture.sql
    same_redmine = committed.values.first && committed.values.first['redmine'] == redmine_series

    mismatches = records.filter_map do |record|
      frozen = committed[record['triple']]
      next "#{record['triple']}: no committed SQL" if frozen.nil?

      if same_redmine
        next if frozen['sql'] == record['sql']

        "#{record['triple']}: SQL differs"
      else
        next if signature(frozen['sql']) == signature(record['sql'])

        "#{record['triple']}: references #{signature(record['sql']).inspect}, " \
          "frozen #{signature(frozen['sql']).inspect}"
      end
    end

    assert_equal [], mismatches,
                 "the recorded SQL no longer describes these scopes (comparison mode: " \
                 "#{same_redmine ? 'byte-for-byte, same Redmine series' : 'referenced tokens and tables, different Redmine series'}). " \
                 "#{mismatches.join('; ')}"
  end

  def test_the_tokeniser_leaves_no_record_id_behind
    leaked = TRIPLES.map { |triple| record_for(*triple) }
                    .select { |record| record['sql'].to_s.match?(/\b#{@leak_pattern}\b/) }

    assert_equal [], leaked.map { |record| record['triple'] },
                 'an id this test created survived tokenisation, so the recorded SQL describes ' \
                 'one run rather than the scope. Add it to #build_token_table!.'
  end

  def test_generating_the_records_twice_gives_the_same_bytes
    first  = RrdGolden::CorpusCanonicaliser.digest(TRIPLES.map { |triple| record_for(*triple) })
    second = RrdGolden::CorpusCanonicaliser.digest(TRIPLES.map { |triple| record_for(*triple) })

    assert_equal first, second
  end

  # ------------------------------------------------------------------
  # What the fixture MEANS — the assertions a recorded file cannot make
  # ------------------------------------------------------------------

  def test_visibility_differs_by_role_on_the_same_template_and_query
    seen = ACTORS.to_h { |actor| [actor, issues_for('drop_array', 'public_all', actor)] }

    # 'all' sees the private issues, 'default' only its own, 'own' only what it
    # authored or is assigned, anonymous only public projects' public issues.
    assert_includes seen['manager'], 'sf-03'
    refute_includes seen['developer'], 'sf-03'
    assert_includes seen['developer'], 'sf-04', 'the author of a private issue must still see it'
    assert_equal %w[sf-05 sf-06 sf-07], seen['reporter'],
                 "issues_visibility 'own' must see only what it authored or is assigned"
    assert_equal %w[sf-07], seen['anonymous']
    assert_equal 4, seen.values.uniq.length, 'all four actors must resolve a different set'
  end

  def test_no_actor_sees_an_issue_in_a_project_they_are_not_a_member_of
    ACTORS.each do |actor|
      refute_includes issues_for('drop_array', 'public_all', actor), 'sf-09',
                      "#{actor} resolved an issue from a project with no membership"
    end
  end

  def test_no_actor_sees_an_issue_in_an_archived_project
    ACTORS.each do |actor|
      refute_includes issues_for('drop_array', 'public_all', actor), 'sf-10',
                      "#{actor} resolved an issue from an archived project"
    end
  end

  def test_a_query_the_actor_may_not_see_resolves_to_nothing_rather_than_to_everything
    %w[developer reporter anonymous].each do |actor|
      assert_nil issues_for('query_id_param', 'private_other', actor),
                 "#{actor} resolved a scope through another user's private query"
    end
    # Its owner is not one of the four actors, so even the manager gets nothing: the
    # lookup is IssueQuery.visible, not IssueQuery.find_by.
    assert_nil issues_for('query_id_param', 'private_other', 'manager')
  end

  def test_a_missing_query_id_resolves_to_nil_with_no_fallback
    ACTORS.each { |actor| assert_nil issues_for('query_id_param', 'absent', actor) }
  end

  def test_a_template_with_no_source_resolves_to_nil
    ACTORS.each { |actor| assert_nil issues_for('no_source', 'none', actor) }
  end

  # FINDING F-2, frozen deliberately rather than fixed: the registers path returns an
  # AR relation from :container AS IS. resolve_scope only intersects the DROP path with
  # Issue.visible, on the documented grounds that every registers path is
  # IssueQuery#base_scope and therefore already visible. A raw relation is not, and
  # this triple records that — an unentitled actor resolves an issue in a project they
  # cannot see. It is not reachable from a template (only the host plugin writes
  # registers), which is why it is a finding and not an emergency; T-07 owns the
  # decision, and this record is what makes the decision visible when it changes.
  def test_the_registers_relation_path_is_not_visibility_scoped
    ACTORS.each do |actor|
      assert_includes issues_for('registers_container_relation', 'public_all', actor), 'sf-09',
                      'the registers relation path has started enforcing visibility. That is ' \
                      'probably right — see finding F-2 — but it is a behaviour change and the ' \
                      'fixture has to be regenerated deliberately.'
    end
  end

  def test_resolve_query_answers_independently_of_resolve_scope
    # The thread-local feeds drill-through only: resolve_scope has no such branch, so
    # the scope is nil while the query resolves. Frozen because a re-seam that unified
    # the two would silently change which filters a drill-through URL inherits.
    assert_nil issues_for('thread_local', 'public_all', 'manager')
    assert_equal 'public_all', record_for('thread_local', 'public_all', 'manager')['query_resolved']
  end

  def test_resolve_query_refuses_a_query_the_actor_may_not_see
    %w[manager developer reporter anonymous].each do |actor|
      assert_nil record_for('query_id_param', 'private_other', actor)['query_resolved'],
                 "#{actor} got drill-through URLs from a private query"
    end
  end

  private

  def regenerate_once!
    return unless RrdGolden::ScopeFixture.write?
    return if self.class.regenerated

    self.class.regenerated = true
    warn "\n[scope fixture] #{RrdGolden::ScopeFixture::WRITE_ENV} is set: REGENERATING " \
         "#{RrdGolden::ScopeFixture::SCOPES}"
    RrdGolden::ScopeFixture.save(TRIPLES.map { |triple| record_for(*triple) })
  end

  # ------------------------------------------------------------------
  # Substrate
  # ------------------------------------------------------------------

  ISSUE_KEYS = (1..10).map { |n| format('sf-%02d', n) }.freeze

  # One reserved range, one table per hundred, so an id is unique across tables and
  # identical on every run and every branch.
  ID_RANGE     = 9_000..9_499
  PROJECT_IDS  = { 'rrd-member' => 9_001, 'rrd-public' => 9_002, 'rrd-outside' => 9_003,
                   'rrd-archived' => 9_004 }.freeze
  USER_IDS     = { 'manager' => 9_101, 'developer' => 9_102, 'reporter' => 9_103,
                   'outsider' => 9_104 }.freeze
  ROLE_IDS     = { 'all' => 9_301, 'default' => 9_302, 'own' => 9_303 }.freeze
  QUERY_IDS    = { 'public_all' => 9_401, 'private_other' => 9_402,
                   'project_scoped' => 9_403 }.freeze
  ISSUE_ID_OF  = ISSUE_KEYS.each_with_index.to_h { |key, index| [key, 9_200 + index + 1] }.freeze

  def build_substrate!
    @role_all     = create_role('all',     'all')
    @role_default = create_role('default', 'default')
    @role_own     = create_role('own',     'own')

    @tracker  = Tracker.order(:id).first
    @status   = IssueStatus.order(:id).first
    @priority = IssuePriority.order(:id).first

    @project_member  = create_project('rrd-member',  public: false)
    @project_public  = create_project('rrd-public',  public: true)
    @project_outside = create_project('rrd-outside', public: false)
    @project_archived = create_project('rrd-archived', public: true)

    @users = {}
    @users['manager']   = create_user('manager')
    @users['developer'] = create_user('developer')
    @users['reporter']  = create_user('reporter')
    @users['outsider']  = create_user('outsider')
    @users['anonymous'] = User.anonymous

    add_member(@users['manager'],   @project_member, @role_all)
    add_member(@users['developer'], @project_member, @role_default)
    add_member(@users['reporter'],  @project_member, @role_own)
    # Nobody is a member of the PUBLIC project, deliberately: there our actors fall
    # back on Redmine's built-in Non member role (issues_visibility 'default') and the
    # anonymous actor on the Anonymous role. That is a second, different visibility
    # rule per actor in the same fixture, and it is the one most installs actually run.

    build_issues!
    build_queries!

    @project_archived.update_columns(status: Project::STATUS_ARCHIVED)
    build_token_table!
  end

  def build_issues!
    @issues = {}
    @issues['sf-01'] = create_issue('sf-01', @project_member,  author: 'outsider')
    @issues['sf-02'] = create_issue('sf-02', @project_member,  author: 'manager', assignee: 'developer')
    @issues['sf-03'] = create_issue('sf-03', @project_member,  author: 'outsider', private: true)
    @issues['sf-04'] = create_issue('sf-04', @project_member,  author: 'developer', private: true)
    @issues['sf-05'] = create_issue('sf-05', @project_member,  author: 'reporter')
    @issues['sf-06'] = create_issue('sf-06', @project_member,  author: 'outsider', assignee: 'reporter')
    @issues['sf-07'] = create_issue('sf-07', @project_public,  author: 'outsider')
    @issues['sf-08'] = create_issue('sf-08', @project_public,  author: 'outsider', private: true)
    @issues['sf-09'] = create_issue('sf-09', @project_outside, author: 'outsider')
    @issues['sf-10'] = create_issue('sf-10', @project_archived, author: 'outsider')
  end

  def build_queries!
    @queries = {}
    # Every query carries the substrate's project filter and NOT Redmine's default
    # status_id=o: an open-only window would hide half of what the visibility rules do
    # (the two closed-status cases), and the whole point is to exercise them.
    @queries['public_all'] = create_query('public_all', @users['manager'],
                                          IssueQuery::VISIBILITY_PUBLIC)
    @queries['private_other'] = create_query('private_other', @users['outsider'],
                                             IssueQuery::VISIBILITY_PRIVATE)
    @queries['project_scoped'] = create_query('project_scoped', @users['manager'],
                                              IssueQuery::VISIBILITY_PUBLIC,
                                              project: @project_member)
  end

  def create_role(key, visibility)
    Role.create!(id: ROLE_IDS.fetch(key), name: "RRD #{key}", permissions: [:view_issues],
                 issues_visibility: visibility)
  end

  def create_project(identifier, public:)
    project = Project.create!(id: PROJECT_IDS.fetch(identifier), name: identifier,
                              identifier: identifier, is_public: public)
    project.enabled_module_names = ['issue_tracking']
    project.trackers = [@tracker]
    project
  end

  # User.generate! rather than User.create!: it fills in whatever Redmine's user
  # validations require on the branch being tested, and the login and mail are given
  # explicitly so nothing depends on its internal counter.
  def create_user(key)
    User.generate!(id: USER_IDS.fetch(key), login: "rrd-#{key}", firstname: 'Rrd',
                   lastname: key, mail: "rrd-#{key}@example.net", language: 'en')
  end

  def add_member(user, project, role)
    Member.create!(principal: user, project: project, roles: [role])
  end

  def create_issue(subject, project, author:, assignee: nil, private: false)
    Issue.create!(id: ISSUE_ID_OF.fetch(subject), project: project, tracker: @tracker,
                  status: @status, priority: @priority, subject: subject,
                  author: @users[author], assigned_to: assignee && @users[assignee],
                  is_private: private)
  end

  # RESTRICTED TO THE SUBSTRATE, always. A query with no filters would resolve every
  # issue the actor may see, and this process contains whatever fixture issues another
  # test class declared — which made two of these tests order-dependent on the first
  # run. The project filter is what keeps a cross-project query cross-project without
  # making it cross-EVERYTHING.
  def create_query(key, user, visibility, project: nil)
    query = IssueQuery.new(id: QUERY_IDS.fetch(key), name: "RRD #{key}", user: user,
                           visibility: visibility, project: project)
    query.filters = { 'project_id' => { operator: '=',
                                        values: PROJECT_IDS.values.map(&:to_s) } }
    query.save!
    query
  end

  # ------------------------------------------------------------------
  # Running one triple
  # ------------------------------------------------------------------

  def record_for(template, query, actor)
    scope = nil
    resolved_query = nil

    as_actor(actor) do
      host = Host.new(raw_params_for(template, query))
      context = context_for(template, query)
      Thread.current[SqlAggregation::ScopeResolution::QUERY_THREAD_KEY] =
        template == 'thread_local' ? @queries[query] : nil

      scope = host.resolve_scope(context)
      resolved_query = host.resolve_query(context)
    end

    {
      'triple'         => "#{template}|#{query}|#{actor}",
      'template'       => template,
      'query'          => query,
      'actor'          => actor,
      'issues'         => scope.nil? ? nil : keys_of(scope),
      'count'          => scope.nil? ? nil : keys_of(scope).length,
      'query_resolved' => query_key(resolved_query),
      'issue_ids'      => scope.nil? ? nil : scope.reorder(nil).distinct.pluck(:id).sort,
      'sql'            => scope.nil? ? nil : tokenise(scope.reorder(nil).to_sql),
      'redmine'        => redmine_series
    }
  end

  def issues_for(template, query, actor)
    record_for(template, query, actor)['issues']
  end

  def raw_params_for(template, query)
    case template
    when 'query_id_param'   then { 'query_id' => query_id_for(query).to_s }
    when 'query_id_context' then { 'query_id' => 'qid' }
    else {}
    end
  end

  def query_id_for(name)
    return 9_499 if name == 'absent' # inside the reserved range, deliberately unused

    @queries[name]&.id
  end

  def context_for(template, query)
    stored = @queries[query]

    case template
    when 'query_id_context'
      FakeContext.new({ 'qid' => query_id_for(query) })
    when 'registers_sql_issue_query'
      FakeContext.new({}, { sql_issue_query: stored })
    when 'registers_container_query'
      FakeContext.new({}, { container: stored })
    when 'registers_container_relation'
      # Deliberately a scope no actor may fully see — see finding F-2.
      FakeContext.new({}, { container: Issue.where(project_id: @project_outside.id) })
    when 'registers_controller'
      FakeContext.new({}, { controller: FakeController.new(stored) })
    when 'drop_array'
      # OUR ten issues, not Issue.all: this path rebuilds Issue.where(id: ids) and then
      # intersects with Issue.visible, so it is the purest per-actor visibility probe
      # in the fixture — and it must probe a known set.
      FakeContext.new({ 'issues' => FakeDrop.new(issues: @issues.values) })
    when 'drop_relation'
      FakeContext.new({ 'issues' => FakeDrop.new(scope: Issue.where(project_id: @project_member.id)) })
    when 'drop_base_scope'
      FakeContext.new({ 'issues' => FakeDrop.new(scope: nil).tap do |drop|
        drop.instance_variable_set(:@query_holder, stored)
      end })
    else
      FakeContext.new
    end
  end

  # A controller stand-in: ScopeResolution reads its @query ivar, nothing else.
  class FakeController
    def initialize(query)
      @query = query
    end
  end

  def as_actor(name)
    previous = User.current
    User.current = name == 'anonymous' ? User.anonymous : @users.fetch(name)
    yield
  ensure
    User.current = previous
  end

  def keys_of(scope)
    scope.reorder(nil).distinct.pluck(:subject).sort
  end

  def query_key(query)
    return nil if query.nil?

    @queries.key(query) || "unknown:#{query.id}"
  end

  def redmine_series
    Redmine::VERSION.to_s.split('.').first(2).join('.')
  end

  # ------------------------------------------------------------------
  # Tokenising the SQL
  # ------------------------------------------------------------------

  # Every id this test created, mapped to a stable name. The records are recreated on
  # every run — the suite runs inside a transaction that is rolled back — so a raw id
  # in the recorded SQL would make the file differ on each run for no reason.
  def build_token_table!
    @tokens = {}
    PROJECT_IDS.each { |name, id| @tokens[id] = "{{project:#{name}}}" }
    USER_IDS.each    { |name, id| @tokens[id] = "{{user:#{name}}}" }
    ROLE_IDS.each    { |name, id| @tokens[id] = "{{role:#{name}}}" }
    QUERY_IDS.each   { |name, id| @tokens[id] = "{{query:#{name}}}" }
    ISSUE_ID_OF.each { |key, id| @tokens[id] = "{{issue:#{key}}}" }
    # The anonymous user is Redmine's, not ours, so its id is not in the reserved
    # range — but it appears in every anonymous actor's visibility SQL and would
    # otherwise be a bare number that differs between fixture sets.
    @tokens[User.anonymous.id] = '{{user:anonymous}}'

    expected = PROJECT_IDS.size + USER_IDS.size + ROLE_IDS.size + QUERY_IDS.size +
               ISSUE_ID_OF.size + 1
    raise "the reserved ids are not unique across tables: #{@tokens.size} of #{expected}" unless
      @tokens.size == expected

    @leak_pattern = Regexp.union(@tokens.keys.map(&:to_s))
  end

  # Longest first, so 1234 is never rewritten as {{...}}34.
  def tokenise(sql)
    @tokens.keys.sort_by { |id| -id.to_s.length }.inject(sql) do |text, id|
      text.gsub(/\b#{id}\b/, @tokens[id])
    end
  end

  # The version-independent half of a SQL comparison: which of our records the
  # statement refers to, and which tables it reads. Both must hold even where
  # Redmine's own visibility SQL is spelled differently.
  def signature(sql)
    return nil if sql.nil?

    tokens = sql.scan(/\{\{[^}]+\}\}/).uniq.sort
    # Quote-agnostic: PostgreSQL writes "issues" and the MySQL family writes `issues`,
    # and a regex that only knew one of them would return an empty table list on the
    # other — two empty lists compare equal, so the assertion would pass vacuously.
    tables = sql.scan(/\b(?:FROM|JOIN)\s+["`]?([a-z_]+)["`]?/i).flatten.map(&:downcase).uniq.sort
    { 'tokens' => tokens, 'tables' => tables }
  end
end
