# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-31 — `Reporting::ReportScope`, the one place that decides which rows a report is about.
#
# --- WHY IT HAS ITS OWN TEST RATHER THAN ONLY ITS CALLERS' ---
#
# Because a caller can hide a branch. An independent review mutated the `else` arm to resolve
# ISSUES for an unknown source and the whole suite stayed green: `ReportRun#call` refuses such
# a template with a typed diagnostic before the scope is ever read, and `ScheduledDelivery`
# fails on the same check. The branch was therefore untested through both callers.
#
# It is not deleted the way `TemplatesController#report_scope`'s `else` was, and the
# difference is real: that one was unreachable, this module is SHARED and T-32 is a third
# caller that will not necessarily have a `ReportRun` in front of it. So it gets a subject.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# No `private` section; the helpers are above the tests.
class ReporterDashboardsReportScopeTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers,
           :time_entries, :queries

  Subject = RedmineReporterDashboards::Reporting::ReportScope

  def setup
    @project = Project.find(1)
    @jsmith = User.find_by!(login: 'jsmith')
    Role.find(1).update_columns(time_entries_visibility: 'all')
  end

  def template_for(source)
    RedmineReporterDashboards::Template.new(project: @project, author_id: @jsmith.id,
                                           name: 'x', source: source)
  end

  def build(source, **options)
    Subject.build(template: template_for(source), actor: @jsmith, project: @project,
                  **options)
  end

  # ------------------------------------------------------------------ the closed set

  def test_issues_resolves_an_issue_relation
    scope, = build('issues')

    assert_equal Issue, scope.klass
  end

  def test_time_entries_resolves_a_time_entry_relation
    scope, = build('time_entries')

    assert_equal TimeEntry, scope.klass
  end

  # THE BRANCH NEITHER CALLER EXERCISES. Nothing, rather than a fallback to issues — which
  # would be §Findings S-13 wearing a smaller hat, since the caller would then render a
  # report about the wrong table with no way to tell.
  def test_a_source_it_does_not_know_resolves_to_nothing
    scope, query = build('invoices')

    assert_nil scope
    assert_nil query
  end

  # ------------------------------------------------------------------ visibility

  def test_the_time_entry_scope_starts_from_the_models_visible_scope
    role = Role.find(1)
    role.permissions = ['view_issues']
    role.save!

    entries, = Subject.build(template: template_for('time_entries'),
                             actor: User.find_by!(login: 'jsmith'), project: @project)

    assert_equal 0, entries.count, 'a role without :view_time_entries saw hours'
  end

  # ------------------------------------------------------------------ the query

  def test_an_unresolvable_query_is_ignored_by_default
    scope, query = build('issues', query_id: 999_999)

    assert_nil query
    assert_equal Issue, scope.klass
  end

  # AND RAISES FOR A SCHEDULE, which is the one deliberate difference between the callers: a
  # scheduler has no requester to disclose anything to, and falling back would mail a
  # different report under the same name.
  def test_an_unresolvable_query_raises_when_the_caller_asks_it_to
    assert_raises(Subject::UnresolvableQuery) do
      build('issues', query_id: 999_999, on_missing_query: :raise)
    end
  end

  # STI-SCOPED, so a template cannot borrow the other source's query.
  def test_an_issue_template_cannot_use_a_time_entry_query
    query = TimeEntryQuery.create!(name: 'hours', project: @project, user: @jsmith,
                                   visibility: 2)

    _scope, resolved = build('issues', query_id: query.id)

    assert_nil resolved
  end

  def test_a_time_entry_template_cannot_use_an_issue_query
    query = IssueQuery.create!(name: 'bugs', project: @project, user: @jsmith,
                               visibility: 2)

    _scope, resolved = build('time_entries', query_id: query.id)

    assert_nil resolved
  end

  # ------------------------------------------------------------------ the project bound

  def test_with_no_project_nothing_is_constrained
    scope, = Subject.build(template: template_for('time_entries'), actor: @jsmith,
                           project: nil)

    assert_equal TimeEntry.visible(@jsmith).count, scope.count
  end

  # ------------------------------------------ T-51: the bound follows Redmine's own setting
  #
  # THE FIXTURE FACT EVERY EXAMPLE BELOW DEPENDS ON, and getting it wrong is how an earlier
  # measurement in this repository produced a false negative: project 1's descendants are
  # 3, 4, 5 and 6, so **project 3 is FAMILY**. Project 2 is the sibling, and therefore the
  # only place a row can sit outside project 1's subtree. An example that used project 3 as
  # "elsewhere" would pass with the bound deleted.
  #
  # These drive the SETTING rather than stubbing the method, because the claim is "we answer
  # what Redmine's own issue list answers" and the setting is what that list reads.

  # `User.current` IS SET HERE, AND THAT IS THE POINT RATHER THAN SETUP NOISE.
  #
  # `Query#base_scope` calls `Issue.visible` / `TimeEntry.visible` with NO argument, so on the
  # QUERY branch the rows are filtered by `User.current` and not by the `actor:` this module
  # threads. In production `Snapshot#as` and `ScheduledDelivery#as` set it; a controller runs
  # as the session user. A first draft of these examples left it unset, compared against
  # `Issue.visible(@jsmith)` and measured 9 against 13 — which is this fact, not a bound
  # defect. `report_scope.rb`'s `resolve` now says the same thing in prose; this is where it
  # is visible.
  def with_subprojects(included)
    previous = Setting.display_subprojects_issues
    previous_user = User.current
    Setting.display_subprojects_issues = included ? '1' : '0'
    User.current = @jsmith
    yield
  ensure
    Setting.display_subprojects_issues = previous
    User.current = previous_user
  end

  # A query that filters nothing, so the only thing deciding the answer is the project bound.
  def unfiltered_global_query(klass)
    query = klass.new(name: "global-#{klass.name}", project: nil, user: @jsmith, visibility: 2)
    query.filters = {}
    query.save!
    query
  end

  def project_ids_in(scope)
    scope.reorder(nil).distinct.pluck(:project_id).sort
  end

  def test_a_query_is_bounded_to_the_subtree_when_redmine_shows_subprojects
    query = unfiltered_global_query(IssueQuery)
    subtree = ([@project.id] + @project.descendants.ids).sort

    with_subprojects(true) do
      scope, = build('issues', query_id: query.id)

      assert_equal Issue.visible(@jsmith).where(project_id: subtree).count, scope.count
      assert_equal (project_ids_in(scope) - subtree), [],
                   'no row may come from outside the subtree'
    end
  end

  def test_a_query_is_bounded_to_this_project_alone_when_redmine_hides_subprojects
    query = unfiltered_global_query(IssueQuery)

    with_subprojects(false) do
      scope, = build('issues', query_id: query.id)

      assert_equal Issue.visible(@jsmith).where(project_id: @project.id).count, scope.count
      assert_equal [@project.id], project_ids_in(scope)
    end
  end

  # THE DISCRIMINATOR. Without it the two examples above still pass with the whole bound
  # deleted, because every other project in the fixture is a descendant of project 1.
  def test_a_sibling_projects_rows_never_appear_under_either_setting
    query = unfiltered_global_query(IssueQuery)
    sibling = Project.find(2)
    assert_nil sibling.parent_id, 'precondition: project 2 must be a sibling, not a descendant'
    assert Issue.visible(@jsmith).where(project_id: sibling.id).exists?,
           'precondition: the sibling must hold a visible row, or this proves nothing'

    [true, false].each do |included|
      with_subprojects(included) do
        scope, = build('issues', query_id: query.id)

        assert_not_includes project_ids_in(scope), sibling.id,
                            "a sibling's rows appeared with subprojects #{included}"
      end
    end
  end

  # THE SAME SETTING GOVERNS SPENT TIME, which is Redmine's own behaviour and is surprising
  # enough to pin: the setting is named for issues and narrows a time-entry report too.
  def test_the_same_setting_bounds_a_time_entry_query
    query = unfiltered_global_query(TimeEntryQuery)
    subtree = ([@project.id] + @project.descendants.ids).sort

    wide = with_subprojects(true) { build('time_entries', query_id: query.id).first.count }
    narrow = with_subprojects(false) { build('time_entries', query_id: query.id).first.count }

    assert_equal TimeEntry.visible(@jsmith).where(project_id: subtree).count, wide
    assert_equal TimeEntry.visible(@jsmith).where(project_id: @project.id).count, narrow
    assert_operator wide, :>, narrow,
                    'the fixture has no hours in a subproject, so this proves nothing'
  end

  # An archived descendant is excluded either way. `Project.allowed_to_condition` already does
  # this inside `Issue.visible`, so the example asserts the OUTCOME rather than the mechanism —
  # it must stay true if the explicit `where.not(status: ARCHIVED)` is ever removed as
  # redundant.
  def test_an_archived_descendant_contributes_nothing_under_either_setting
    query = unfiltered_global_query(IssueQuery)
    archived = Project.find(3)
    assert_equal @project.id, archived.parent_id, 'precondition: project 3 is a descendant'
    archived.update_columns(status: Project::STATUS_ARCHIVED)

    [true, false].each do |included|
      with_subprojects(included) do
        scope, = build('issues', query_id: query.id)

        assert_not_includes project_ids_in(scope), archived.id,
                            "an archived descendant appeared with subprojects #{included}"
      end
    end
  end

  # THE PATH THAT MUST NOT MOVE. T-51 changes the QUERY branch only; the no-query branch is
  # exactly this project under either setting, and widening it is DECISIONS-PENDING #19,
  # blocked on the spent-time notice. If this example ever goes red, that decision was taken
  # by accident.
  def test_the_no_query_path_is_exactly_this_project_under_either_setting
    [true, false].each do |included|
      with_subprojects(included) do
        scope, = build('issues')

        assert_equal Issue.visible(@jsmith).where(project_id: @project.id).count, scope.count
        assert_equal [@project.id], project_ids_in(scope)
      end
    end
  end
end
