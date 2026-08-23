# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-31 / §Findings **S-14** — which hours an actor may see, and why it needed writing down.
#
# --- WHY THIS IS A FULL-APPLICATION TEST AND NOT A DB-LESS ONE ---
#
# The whole subject is `Role#time_entries_visibility` and `Role#allowed_to?` interacting
# with `User#roles_for_project`. Doubles for those three would be doubles for the exact
# thing being asserted — the same argument T-21 makes for the multi-actor issue suite:
# "real `Role#issues_visibility`, a real private issue and a real `IssueQuery` exist nowhere
# else".
#
# The four states are ALL asserted, and the middle two are the finding: an actor whose role
# says `own` reads a smaller, entirely believable project total and has no way to know it is
# their own timesheet.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. There is no `private` here;
# the helpers are above the tests and the run count is checked against
# `grep -c '^  def test_'`.
class ReporterDashboardsTimeEntryVisibilityTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers,
           :time_entries

  Subject = RedmineReporterDashboards::Reporting::TimeEntryVisibility

  def setup
    @project = Project.find(1)
    @jsmith = User.find_by!(login: 'jsmith')
    @role = Role.find(1)
  end

  # ------------------------------------------------------------------ helpers

  # EXACTLY these permissions, for the reason the controller test gives: a test that adds to
  # whatever the fixture already holds is a test whose subject is the fixture.
  # SOMEBODY ELSE'S HOURS, so `own` narrows something. Project 1's three fixture rows are
  # all jsmith's as far as `user_id` goes for only one of them, and none of them makes the
  # `own` branch observably smaller on its own.
  def others_entry
    dlopper = User.find_by!(login: 'dlopper')
    TimeEntry.create!(project: @project, user: dlopper, author: dlopper,
                      issue: Issue.where(project_id: @project.id).first,
                      hours: 3.0, spent_on: Date.new(2026, 3, 10),
                      activity: TimeEntryActivity.where(active: true).first)
  end

  # THE USER IS RE-FETCHED, AND WITHOUT THAT THIS HELPER LIES ON ITS SECOND CALL.
  # `User#roles_for_project` memoises its memberships, so a test that changes a role and
  # then asks the SAME user object gets the role it loaded the first time. Measured: the
  # agreement test below asserted `own` and read `:all`, because the `all` iteration one
  # line earlier had already cached the role. Same family as HANDOVER §1's memoised-actor
  # trap — the second actor in a process silently gets the first one's answer.
  def role_grants(permissions, visibility)
    @role.permissions = permissions.map(&:to_s)
    @role.time_entries_visibility = visibility
    @role.save!
    @jsmith = User.find_by!(login: 'jsmith')
  end

  # ------------------------------------------------------------------ the three states

  def test_a_role_with_full_visibility_sees_everything
    role_grants([:view_time_entries], 'all')

    assert_equal :all, Subject.state(@jsmith, @project)
    assert_not Subject.narrowed?(@jsmith, @project)
  end

  # THE FINDING. The report is correct and the number is smaller, and without a notice the
  # reader cannot tell those two facts apart.
  def test_a_role_limited_to_own_entries_is_narrowed
    role_grants([:view_time_entries], 'own')

    assert_equal :own, Subject.state(@jsmith, @project)
    assert Subject.narrowed?(@jsmith, @project)
  end

  def test_a_role_without_the_permission_sees_nothing
    role_grants([:view_issues], 'all')

    assert_equal :none, Subject.state(@jsmith, @project)
    assert Subject.narrowed?(@jsmith, @project)
  end

  # THE COMBINATION THAT LOOKS SAFE AND IS NOT. `time_entries_visibility` is a column on
  # every role whether or not that role may see time entries at all, so a role holding no
  # `:view_time_entries` while carrying `'all'` must contribute NOTHING — which is what
  # `Project.allowed_to_condition` does by yielding only permitted roles to its block.
  # Answering `:all` here would announce no narrowing on a report that shows zero rows.
  def test_visibility_all_without_the_permission_is_still_nothing
    role_grants([:view_issues], 'all')

    assert_equal :none, Subject.state(@jsmith, @project)
  end

  # ------------------------------------------------------------------ the edges

  # AND THE SHORT-CIRCUIT HAS TO BE OBSERVABLE. The first version of this test granted only
  # Role 1 and passed with the `user.admin?` line deleted, because an administrator who is
  # not a member falls through to the BUILT-IN Non-member role, which holds
  # `:view_time_entries` with `'all'` on a stock Redmine — so both paths answered `:all` and
  # the example proved nothing. Every role in the installation is stripped here, builtins
  # included, so `:all` can only come from the admin flag.
  def test_an_administrator_sees_everything_without_a_role
    Role.find_each { |role| role.update_columns(permissions: [:view_issues].to_yaml) }

    assert_equal :none, Subject.state(User.find_by!(login: 'jsmith'), @project),
                 'the strip did not take, so the assertion below proves nothing'
    assert_equal :all, Subject.state(User.find(1), @project)
  end

  # ANONYMOUS IS NOT A SPECIAL CASE, and the first version of this test asserted it fails
  # closed. MEASURED, and that was wrong: the built-in Anonymous role holds
  # `:view_time_entries` with `time_entries_visibility: 'all'` on this fixture, and
  # `TimeEntry.visible(User.anonymous)` duly returns all three rows in project 1. `:all` is
  # therefore the CORRECT answer, and a module that said `:none` would print a narrowing
  # notice on a report that is not narrowed. The assertion that earns its place is the one
  # below: agreement with the scope.
  def test_anonymous_is_answered_from_its_role_like_anybody_else
    assert_equal :all, Subject.state(User.anonymous, @project)
  end

  # THE INDEPENDENT ORACLE, APPLIED TO VISIBILITY. This module exists only to NAME the
  # narrowing that `TimeEntry.visible` applies in SQL, so the claim worth asserting is that
  # the two agree — computed two different ways, one in Ruby off the roles and one by the
  # database off `visible_condition`. A module that drifted from the scope would announce a
  # narrowing that is not there, or stay silent about one that is.
  def test_the_state_agrees_with_what_TimeEntry_visible_actually_returns
    others_entry

    { 'all' => :all, 'own' => :own }.each do |column, expected|
      role_grants([:view_time_entries], column)
      assert_equal expected, Subject.state(@jsmith, @project), "role visibility #{column}"

      visible = TimeEntry.visible(@jsmith).where(project_id: @project.id).count
      total = TimeEntry.where(project_id: @project.id).count

      if expected == :all
        assert_equal total, visible, 'said :all, but the scope narrowed'
      else
        assert visible < total, 'said :own, but the scope narrowed nothing'
      end
    end

    role_grants([:view_issues], 'all')
    assert_equal :none, Subject.state(@jsmith, @project)
    assert_equal 0, TimeEntry.visible(@jsmith).where(project_id: @project.id).count,
                 'said :none, but the scope returned rows'
  end

  # THE TIME-TRACKING MODULE, WHICH THE FIRST VERSION DID NOT CONSULT AT ALL.
  # `Project.allowed_to_condition` adds an `enabled_modules` EXISTS clause for EVERYONE,
  # administrators included, so with the module off `TimeEntry.visible` returns nothing while
  # this answered `:all` — an empty hours report with no notice and no explanation. Measured
  # by an independent review: `module DISABLED (admin): state=all visible=0`.
  def test_the_module_being_off_is_none_even_with_full_role_visibility
    role_grants([:view_time_entries], 'all')
    @project.disable_module!(:time_tracking)
    # RE-FOUND, because `enabled_modules` is a cached association and `module_enabled?`
    # reads it — the first version asserted against the object that still remembered the
    # module being on, and read `:all`. Same family as the memoised-roles note above.
    @project = Project.find(@project.id)

    assert_equal :none, Subject.state(@jsmith, @project)
    assert_equal 0, TimeEntry.visible(@jsmith).where(project_id: @project.id).count,
                 'said :none, but the scope returned rows'
  end

  # ...AND FOR AN ADMINISTRATOR TOO, which is the case the admin short-circuit would
  # otherwise skip straight past.
  def test_the_module_being_off_is_none_for_an_administrator_as_well
    @project.disable_module!(:time_tracking)
    @project = Project.find(@project.id)

    assert_equal :none, Subject.state(User.find(1), @project)
    assert_equal 0, TimeEntry.visible(User.find(1)).where(project_id: @project.id).count
  end

  # AN `own` ROLE HELD BY SOMEBODY NOT LOGGED IN SEES NOTHING, because core's branch reads
  # `user.id && user.logged?` and falls through to `1=0` otherwise. Announcing "only your own
  # spent time" over an empty report would be a notice that is simply false.
  def test_an_own_role_on_an_actor_who_is_not_logged_in_is_none
    anonymous_role = Role.anonymous
    anonymous_role.permissions = ['view_time_entries']
    anonymous_role.time_entries_visibility = 'own'
    anonymous_role.save!

    assert_equal :none, Subject.state(User.anonymous, @project)
    assert_equal 0, TimeEntry.visible(User.anonymous).where(project_id: @project.id).count,
                 'said :none, but the scope returned rows'
  end

  # FAIL CLOSED ON NIL, both ways. A caller with no project (a template outside a project,
  # which the schema permits — `project_id` is nullable) must not be told it may see
  # everything.
  def test_a_nil_user_or_project_is_none
    assert_equal :none, Subject.state(nil, @project)
    assert_equal :none, Subject.state(@jsmith, nil)
  end

  # A ROLE OBJECT THAT CANNOT ANSWER IS TREATED AS THE NARROWEST THING IT COULD BE. The
  # column is core's rather than this plugin's, so a Redmine that renamed it must degrade
  # towards showing the notice, not towards suppressing it (INV-1/INV-3: fail closed).
  #
  # DRIVEN WITH A PLAIN OBJECT, not by stubbing `respond_to?` on the real class. The first
  # version did the latter and mocha refused it — `Role.any_instance.stubs(:respond_to?)`
  # intercepts EVERY `respond_to?`, including the `:allowed_to?` one two lines earlier, so
  # the stub failed on an invocation it had not been told about. A double that genuinely
  # does not answer is both simpler and closer to the thing being modelled.
  def test_a_role_that_cannot_answer_the_column_is_not_read_as_full_visibility
    mute = Object.new

    assert_nil Subject.visibility_of(mute)
  end

  # ...AND `state` DEGRADES WITH IT rather than answering `:all` off a role it cannot read.
  def test_a_role_that_cannot_answer_the_column_does_not_widen_the_state
    role_grants([:view_time_entries], 'all')
    # NOT an endless method definition — `.codex/check_ruby_floor.sh` caught one here and it
    # was right: the floor is Ruby 2.7 and `def x = y` needs 3.0.
    mute = Object.new
    def mute.allowed_to?(_action)
      true
    end

    Subject.stubs(:permitted_roles).returns([mute])

    assert_equal :none, Subject.state(@jsmith, @project)
  end

  # THE PLUGIN'S OWN PERMISSIONS ARE IRRELEVANT HERE, and that is the decision: core's
  # `:view_time_entries` governs the data, and a second permission over it would be a
  # second answer to one question (§Findings S-14).
  def test_the_reporting_permission_does_not_widen_time_entry_visibility
    role_grants([:view_reporter_dashboards_reports], 'all')

    assert_equal :none, Subject.state(@jsmith, @project)
  end

  # ---------------------------------------------- T-26a increment 3: no project to ask about

  # A MY-PAGE HOURS WIDGET SPANS EVERY PROJECT, so `state` is the wrong question there: it
  # takes a project and answers `:none` for a nil one, which would print "your role does not
  # let you see spent time IN THIS PROJECT" over a report drawing on several. A false
  # sentence is worse than the silence S-14 exists to remove.
  #
  # jsmith is a member of projects 1, 2 and 5 in Redmine's own fixtures (measured), all with
  # `@role` or role 2, so setting the roles here decides the whole answer.
  def test_across_projects_full_visibility_everywhere_needs_no_notice
    every_role_grants([:view_time_entries], 'all')

    assert_equal :all, Subject.state_across_projects(@jsmith)
  end

  # THE CASE THE NOTICE EXISTS FOR: one project narrows and another does not, so the report
  # is a MIX and neither "all" nor "own" describes it on its own.
  #
  # PROJECT 2 HAS TIME TRACKING OFF IN REDMINE'S FIXTURES (measured), so the first version of
  # this test set role 2 to `own` and got `:all` back — role 2's only project contributed
  # `:none`, and the example was asserting nothing about a mix at all. The module is enabled
  # here and the mix is asserted before the subject is asked.
  def test_across_projects_one_own_only_role_makes_the_whole_answer_own
    Project.find(2).enable_module!(:time_tracking)
    every_role_grants([:view_time_entries], 'all')
    Role.find(2).update!(time_entries_visibility: 'own')
    @jsmith = User.find_by!(login: 'jsmith')

    assert_equal :all, Subject.state(@jsmith, Project.find(1)),
                 'precondition: one project must be unrestricted'
    assert_equal :own, Subject.state(@jsmith, Project.find(2)),
                 'precondition: the other must be restricted, or this is not a mix'

    assert_equal :own, Subject.state_across_projects(@jsmith)
  end

  def test_across_projects_no_permission_anywhere_is_none
    every_role_grants([:view_issues], 'all')

    assert_equal :none, Subject.state_across_projects(@jsmith)
  end

  # A PROJECT WITH TIME TRACKING OFF CONTRIBUTES NOTHING, and this is the claim that used to
  # be a redundant filter in `state_across_projects`. Core's `allowed_to_condition` adds an
  # `enabled_modules` clause for EVERYONE, administrators included, so a role in such a
  # project grants no hours at all — announcing full visibility off it would be false.
  # `state`'s own module gate is what delivers this; the extra filter above it was removed
  # after mutation testing showed it could not change any answer.
  def test_across_projects_a_module_disabled_project_does_not_widen_the_answer
    Project.find(2).enable_module!(:time_tracking)
    every_role_grants([:view_time_entries], 'all')
    Role.find(1).update!(time_entries_visibility: 'own')
    @jsmith = User.find_by!(login: 'jsmith')
    assert_equal :own, Subject.state_across_projects(@jsmith),
                 'precondition: project 2 must be widening the answer to a mix'

    # Take the MODULE off the widening project. Its role still says `all` and the actor is
    # still a member — core's `allowed_to_condition` adds an `enabled_modules` clause for
    # everyone, so it grants no hours, and announcing full visibility off it would be false.
    Project.find(2).disable_module!(:time_tracking)
    @jsmith = User.find_by!(login: 'jsmith')

    assert_equal :own, Subject.state_across_projects(@jsmith)

    Project.find(1).disable_module!(:time_tracking)
    @jsmith = User.find_by!(login: 'jsmith')

    assert_equal :none, Subject.state_across_projects(@jsmith),
                 'with the module off everywhere there is nothing to see and nothing to narrow'
  end

  # AN ADMINISTRATOR IS `:all` AND MUST NOT BE SHOWN A NARROWING NOTICE, because
  # `TimeEntry.visible` gives them every entry — the notice would simply be false.
  def test_across_projects_an_administrator_is_all
    every_role_grants([:view_time_entries], 'own')

    assert_equal :all, Subject.state_across_projects(User.find_by!(login: 'admin'))
  end

  def test_across_projects_a_nil_actor_fails_closed
    assert_equal :none, Subject.state_across_projects(nil)
  end

  # EXACTLY these permissions on every role jsmith actually holds. Setting only `@role`
  # leaves role 2 (his membership in project 2) answering whatever the fixture says, which
  # is the fixture-as-subject problem the helper above already warns about.
  def every_role_grants(permissions, visibility)
    [Role.find(1), Role.find(2)].each do |role|
      role.permissions = permissions.map(&:to_s)
      role.time_entries_visibility = visibility
      role.save!
    end
    @jsmith = User.find_by!(login: 'jsmith')
  end
end
