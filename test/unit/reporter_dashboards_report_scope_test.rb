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
end
