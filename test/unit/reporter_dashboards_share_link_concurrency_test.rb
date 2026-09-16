# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-28 — `max_uses` IS A PROMISE ANOTHER CONNECTION MUST NOT BE ABLE TO BREAK, and this file
# exists because the first version of this test could not have caught it breaking.
#
# --- WHY THIS IS A SEPARATE FILE WITH TRANSACTIONAL FIXTURES TURNED OFF ---
#
# The original test lived in `reporter_dashboards_share_link_test.rb` and drove two threads
# through `ActiveRecord::Base.connection_pool.with_connection`. Its own comment said what it
# needed — *"through SEPARATE CONNECTIONS, because on one connection the second `update_all`
# simply sees the first one's write and the test would pass against the broken implementation
# too"* — and then did not get them. MEASURED, in that file's own configuration:
#
#     use_transactional_tests=true
#     distinct_connection_objects=1  backend_pids=[3693]
#
# Under `use_transactional_tests`, Rails PINS the pool to the fixture connection so that
# every thread can see the uncommitted fixture data. `with_connection` therefore hands back
# the same connection, on the same PostgreSQL backend, and the two "concurrent" claims were
# serialised by being the same session. An independent review proved the consequence: replacing
# the conditional UPDATE with the exact lost-update implementation the class comment is built
# to avoid left the whole suite green — `64 runs, 245 assertions, 0 failures, 0 errors`.
#
# So the fixture pin has to go, which means `use_transactional_tests = false`, which means
# this test COMMITS and must clean up after itself. That is why it is a file of its own
# rather than a method: `use_transactional_tests` is per class, and turning it off for the
# other 29 examples in that file would make them slower and able to leak into each other.
#
# --- WHY IT RACES REPEATEDLY RATHER THAN ONCE ---
#
# A race is not a deterministic input. One paired attempt can pass against a broken
# implementation simply because the two threads did not overlap, and CLAUDE.md §6's rule is
# that a test must mean the same thing on somebody else's machine. `ROUNDS` independent
# single-use links, each raced by two threads through a real barrier, turns "did they
# collide" into "did they collide at least once in N" — and the assertion is made on the
# TOTAL, so one lost update anywhere in the run fails it.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. There is none here.
class ReporterDashboardsShareLinkConcurrencyTest < ActiveSupport::TestCase
  # THE WHOLE POINT OF THE FILE. Without this line the pool is pinned and the test below is
  # the one it replaced.
  self.use_transactional_tests = false

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  ShareLink = RedmineReporterDashboards::ShareLink
  Template = RedmineReporterDashboards::Template

  # Ten pairs. Enough that a lost update is overwhelmingly likely to be observed at least
  # once, few enough that the file stays under a second.
  ROUNDS = 10

  def setup
    @project = Project.find(1)
    @jsmith = User.find_by!(login: 'jsmith')
    @template = Template.create!(project: @project, author: @jsmith, name: 'Raced',
                                 content: '<p>x</p>', source: 'issues', output: 'combined')
  end

  # NOT TRANSACTIONAL, SO CLEANING UP IS THIS FILE'S JOB. Written to survive a failure
  # part-way through `setup` (`@template` may be nil) and to take the access rows first,
  # because they reference the links.
  def teardown
    if @template
      link_ids = ShareLink.where(template_id: @template.id).pluck(:id)
      RedmineReporterDashboards::ShareLinkAccess.where(share_link_id: link_ids).delete_all
      ShareLink.where(id: link_ids).delete_all
      Template.where(id: @template.id).delete_all
    end
    User.current = nil
  end

  # ------------------------------------------------------------------ helpers

  def mint_single_use
    link, = ShareLink.create_with_token!(template: @template, project: @project,
                                         created_by: @jsmith,
                                         scope_kind: ShareLink::SCOPE_QUERY,
                                         max_uses: 1,
                                         expires_at: 30.days.from_now)
    link
  end

  # TWO THREADS, EACH ON ITS OWN CONNECTION, RELEASED TOGETHER.
  #
  # The barrier is two `Queue`s and no `sleep`: each thread checks out a connection, reports
  # that it has arrived, and blocks on `go`. The main thread waits for BOTH arrivals before
  # releasing either, so the window between the two `use!` calls is as small as the runtime
  # can make it. `sleep` would be both slower and less reliable, and CLAUDE.md §6 forbids
  # the timing-dependent fixture it would amount to.
  #
  # Answers `[results, backend_pids]` — the PIDs so the CALLER can assert the connections
  # really were distinct. That assertion is the one this whole file turns on, so it is
  # returned as evidence rather than checked out of sight.
  def race(link)
    arrived = Queue.new
    go = Queue.new
    results = Queue.new
    pids = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          pids << connection.select_value('SELECT pg_backend_pid()')
          arrived << :ready
          go.pop
          results << ShareLink.find(link.id).use!
        end
      end
    end

    2.times { arrived.pop }
    2.times { go << :go }
    threads.each(&:join)

    [Array.new(2) { results.pop }, Array.new(2) { pids.pop }]
  end

  # ------------------------------------------------------------------ the discriminator

  # THE ASSERTION THAT MAKES THE REST MEAN ANYTHING. If the two threads share a backend, the
  # second `update_all` simply reads the first one's write and a lost-update implementation
  # passes — which is exactly the state the test this replaces was in, undetected, for two
  # increments. It is asserted per round rather than once, because the pool hands out
  # connections per checkout and a later round could differ from the first.
  def test_the_two_claims_really_do_run_on_different_database_connections
    link = mint_single_use

    _results, pids = race(link)

    assert_equal 2, pids.uniq.length,
                 "both threads ran on backend #{pids.inspect} — this file asserts nothing " \
                 'unless the connections are distinct'
  end

  # `max_uses: 1` MEANS ONE DOWNLOAD, EVEN WHEN TWO REQUESTS ARRIVE TOGETHER.
  #
  # `README.md` sells this in as many words: *"Two people opening a single-use link at the
  # same moment get one download and one refusal, never two downloads."* This is the test
  # that makes that sentence true rather than hopeful.
  #
  # Read-then-write cannot hold it: both requests read `use_count = 0`, both conclude they
  # are under a limit of 1, and the link serves twice. `ShareLink#use!` is one conditional
  # UPDATE whose WHERE clause carries the whole rule, and the row count it changed is the
  # answer.
  def test_no_single_use_link_can_ever_be_claimed_twice
    successes = 0
    refusals = 0
    counts = []

    ROUNDS.times do |round|
      link = mint_single_use
      results, pids = race(link)

      assert_equal 2, pids.uniq.length, "round #{round} did not use two connections"
      successes += results.count(&:nil?)
      refusals += results.count { |r| r == :exhausted }
      counts << link.reload.use_count
    end

    # ON THE TOTALS, so one lost update anywhere in the run fails the test — a per-round
    # assertion would report only the first round that happened to collide.
    assert_equal ROUNDS, successes, 'a single-use link was claimed more than once'
    assert_equal ROUNDS, refusals, 'the loser was not told why'
    assert_equal [1], counts.uniq, "use_count went past its limit: #{counts.inspect}"
  end
end
