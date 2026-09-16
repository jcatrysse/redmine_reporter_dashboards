# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-31 — the two things about `TimeEntryAggregator` that only a BOOTED REDMINE can answer.
#
# Everything else about the module is asserted elsewhere and deliberately so: its figures
# against a real engine in `spec/adapter/time_entry_aggregator_spec.rb` (computed twice, once
# in SQL and once in Ruby, on three engines), and its structure with the rows under the
# example's control in `spec/aggregation/time_entry_aggregator_source_spec.rb`. Neither of
# those processes has a `TimeEntryQuery` or a real private issue, and those are exactly what
# an independent review's two most serious findings needed.
#
# --- 1. THE DRILL-THROUGH FILTER NAMES ---
#
# A bucket carries `filter: {field, operator, values}` so a drill-through link can be built
# from it. Six of the first version's eleven named a filter `TimeEntryQuery` does not have —
# `tracker_id`, `status_id`, `fixed_version_id`, `category_id` are `IssueQuery` names, and the
# time-entry equivalents are prefixed `issue.` — while `priority` and `assignee` had no
# equivalent at all. The dangerous one was `author`: `author_id` IS a `TimeEntryQuery` filter
# and it means **who recorded the entry**, not the issue's author, so that payload resolved to
# a plausible, WRONG row set rather than to nothing.
#
# The check is three lines and it is mechanical, which is the point (CLAUDE.md §3 phase 2: a
# control specified as mechanical must not be implemented as a comment).
#
# --- 2. THE ISSUE LABEL AND VISIBILITY ---
#
# `time_entries.issue_id` is a column on the ENTRY, so it survives the `Issue.visible_condition`
# core puts inside `left_join_issue` (`app/models/time_entry.rb:64-70`). The first version then
# read the label from an unscoped `Issue.where(id: ids)`, and an actor who could see the entry
# but not the private issue read its SUBJECT off their own hours report. On the scheduled path
# that output is mailed to other people.
#
# Redmine refuses this in two places and both fall back to `"##{id}"`:
# `timelog_helper.rb:80-85` (the spent-time report itself) and `application_helper.rb:307`.
# The adapter spec models it with an issue in an unreachable project; THIS test uses a real
# `is_private` issue, which is the shape the review measured.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. There is none here; the helpers
# sit above the tests.
class ReporterDashboardsTimeEntryAggregatorTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers,
           :issue_categories, :versions, :time_entries

  Subject = RedmineReporterDashboards::Aggregation::TimeEntryAggregator

  def setup
    @project = Project.find(1)
    @jsmith = User.find_by!(login: 'jsmith')
    @dlopper = User.find_by!(login: 'dlopper')
  end

  # ------------------------------------------------------------------ helpers

  # EXACTLY these permissions, so the subject is the grant and not the fixture.
  def grant(permissions, visibility = 'all')
    role = Role.find(1)
    role.permissions = permissions.map(&:to_s)
    role.time_entries_visibility = visibility
    role.save!
    @jsmith = User.find_by!(login: 'jsmith')
  end

  # The scope both callers build, through the one place that decides it.
  def report_scope(actor, query_id: nil)
    template = RedmineReporterDashboards::Template.new(source: 'time_entries')
    scope, = RedmineReporterDashboards::Reporting::ReportScope.build(
      template: template, actor: actor, project: @project, query_id: query_id
    )
    scope
  end

  def labels_of(result)
    result['buckets'].map { |bucket| bucket['label'] }
  end

  # ------------------------------------------------------------------ the filter names

  # EVERY EMITTED FILTER IS A REAL `TimeEntryQuery` FILTER, or it is nil. Nil is honest — it
  # means "this dimension has no drill-through" — and a name that does not exist is not.
  def test_every_dimension_filters_on_a_field_TimeEntryQuery_actually_has
    available = TimeEntryQuery.new(project: @project).available_filters.keys

    Subject::DIMENSIONS.each do |name, dimension|
      next if dimension[:field].nil?

      # `assert_include(expected, collection)` — Redmine's helper asserts
      # `collection.include?(expected)`, and the first version had the two the wrong way round
      # and died on `String#include?(Array)` rather than on the subject.
      assert_include dimension[:field], available,
                     "group_by: #{name} drills through #{dimension[:field].inspect}, which " \
                     "TimeEntryQuery has no filter for. Available: #{available.sort.inspect}"
    end
  end

  # AND THE LIST IS NOT EMPTY, or the loop above proves nothing.
  def test_most_dimensions_do_carry_a_drill_through
    with_filter = Subject::DIMENSIONS.count { |_, dimension| dimension[:field] }

    assert_operator with_filter, :>=, 7, 'the dimensions lost their drill-through payloads'
  end

  # THE ISSUE-ATTRIBUTE NAMES ARE PREFIXED, and this is the assertion that would have failed
  # on the first version. `tracker_id` alone is an `IssueQuery` filter.
  def test_an_issue_attribute_uses_the_prefixed_filter_name
    assert_equal 'issue.tracker_id', Subject::DIMENSIONS['tracker'][:field]
    assert_equal 'issue.status_id', Subject::DIMENSIONS['status'][:field]
    assert_equal 'issue.fixed_version_id', Subject::DIMENSIONS['version'][:field]
    assert_equal 'issue.category_id', Subject::DIMENSIONS['category'][:field]
  end

  # AND `author_id` IS NOT EMITTED AT ALL. It exists on `TimeEntryQuery` and means the
  # ENTRY's author, so a dimension over the ISSUE's author must not borrow it — that is a
  # wrong answer rather than a missing one, which is why the dimension is gone.
  def test_the_issue_author_is_not_a_dimension_borrowing_the_entry_author_filter
    assert_nil Subject::DIMENSIONS['author']
    fields = Subject::DIMENSIONS.values.map { |dimension| dimension[:field] }
    assert_not_includes fields, 'author_id'
  end

  # THE DIMENSION SET IS CORE'S. `time_report.rb`'s `load_available_criteria` is the
  # authority, and a dimension outside it needs a drill-through answer first.
  # CUSTOM FIELDS ARE EXCLUDED FROM THE COMPARISON AND THAT IS A NAMED GAP, not a fudge.
  # Core's list also holds one `cf_<id>` per visible time-entry, project and issue custom
  # field — this fixture contributes four — and `TimeEntryAggregator` has no custom-field
  # dimension at all, where the issue kernel does (`cf_92` in the README). Recorded as
  # §Findings S-18 rather than built here: it needs `TimeEntryCustomField` visibility, a
  # `custom_values` join and a `cf_` filter payload, which is its own task.
  def test_the_dimensions_are_the_ones_core_offers_for_a_spent_time_report
    core = Redmine::Helpers::TimeReport
           .new(@project, nil, [], TimeEntry.none)
           .available_criteria.keys
           .reject { |key| key.start_with?('cf_') }

    assert_equal core.sort, Subject::DIMENSIONS.keys.sort,
                 'the dimension set drifted from the core criteria Redmine offers itself'
  end

  # AND THE CUSTOM-FIELD GAP IS ASSERTED RATHER THAN LEFT IMPLIED, so the day somebody adds
  # one this test says the comment above is stale.
  def test_no_custom_field_dimension_exists_yet
    assert_empty Subject::DIMENSIONS.keys.grep(/\Acf_/)
  end

  # ------------------------------------------------------------------ the disclosure

  # A REAL PRIVATE ISSUE, and the entry that points at it is visible.
  def private_issue_with_hours
    issue = Issue.where(project_id: @project.id).first
    issue.update_columns(is_private: true, author_id: @dlopper.id, assigned_to_id: @dlopper.id,
                         subject: 'CONFIDENTIAL ACQUISITION')
    TimeEntry.create!(project: @project, user: @jsmith, author: @jsmith, issue: issue,
                      hours: 3.0, spent_on: Date.new(2026, 3, 10),
                      activity: TimeEntryActivity.where(active: true).first)
    issue
  end

  def test_an_issue_the_actor_cannot_see_is_labelled_by_id_and_never_by_subject
    issue = private_issue_with_hours
    grant([:view_time_entries])
    assert_not issue.visible?(@jsmith),
               'the issue is visible to the actor, so this test proves nothing'

    result = Subject.breakdown(report_scope(@jsmith), group_by: 'issue', actor: @jsmith)

    bucket = result['buckets'].find { |b| b['value'] == issue.id.to_s }
    assert_not_nil bucket, 'the hours vanished instead of being attributed to the issue'
    assert_equal "##{issue.id}", bucket['label']
    assert_not_includes labels_of(result).join(' '), 'CONFIDENTIAL'
  end

  # AND THE HOURS ARE STILL COUNTED. Fail-closed on the LABEL, not on the figure: the actor
  # may see the time entry, so its hours belong in their report.
  def test_the_invisible_issues_hours_are_still_reported
    issue = private_issue_with_hours
    grant([:view_time_entries])

    result = Subject.breakdown(report_scope(@jsmith), group_by: 'issue', actor: @jsmith)
    bucket = result['buckets'].find { |b| b['value'] == issue.id.to_s }

    assert_equal TimeEntry.visible(@jsmith).where(issue_id: issue.id).sum(:hours).to_f.round(2),
                 bucket['count']
  end

  # AND AN ISSUE THE ACTOR *CAN* SEE KEEPS ITS SUBJECT, or the fix is just "print no labels".
  def test_a_visible_issue_keeps_its_id_and_its_subject
    grant([:view_issues, :view_time_entries])
    issue = Issue.visible(@jsmith).where(project_id: @project.id).first
    assert_not_nil issue, 'no visible issue, so this test proves nothing'
    TimeEntry.create!(project: @project, user: @jsmith, author: @jsmith, issue: issue,
                      hours: 1.0, spent_on: Date.new(2026, 3, 11),
                      activity: TimeEntryActivity.where(active: true).first)

    result = Subject.breakdown(report_scope(@jsmith), group_by: 'issue', actor: @jsmith)

    assert_include "##{issue.id}: #{issue.subject}", labels_of(result)
  end

  # FAIL CLOSED WITH NO ACTOR. A caller that forgot one gets ids, never unscoped labels.
  def test_no_actor_means_no_issue_labels_rather_than_unscoped_ones
    grant([:view_issues, :view_time_entries])
    issue = Issue.visible(@jsmith).where(project_id: @project.id).first
    TimeEntry.create!(project: @project, user: @jsmith, author: @jsmith, issue: issue,
                      hours: 1.0, spent_on: Date.new(2026, 3, 11),
                      activity: TimeEntryActivity.where(active: true).first)

    result = Subject.breakdown(report_scope(@jsmith), group_by: 'issue')

    assert_include "##{issue.id}", labels_of(result)
    assert_not_includes labels_of(result).join(' '), issue.subject
  end

  # ------------------------------------------------------------------ the activity roll-up

  # A PROJECT OVERRIDE IS ONE BUCKET, not two carrying the same name — `time_report.rb:125`.
  # Redmine's own override mechanism, driven the way the settings form drives it.
  # THE ORDER OF THESE THREE STEPS IS THE REAL WORLD'S ORDER, and it is not optional.
  # `Project#activities` EXCLUDES a parent once the project has overridden it
  # (`project.rb:267-274`), and `TimeEntry` validates its activity against that list — so an
  # entry on the parent can only be created BEFORE the override exists. MEASURED: creating the
  # override first made `TimeEntry.create!` raise *"Activity is not included in the list"*,
  # which is Redmine telling us the fixture was impossible. Pre-override entries keeping the
  # parent id is exactly why two buckets appear at all.
  def test_a_project_overridden_activity_is_rolled_up_to_its_parent
    parent = TimeEntryActivity.where(active: true, project_id: nil).first
    grant([:view_time_entries])
    issue = Issue.where(project_id: @project.id).first

    TimeEntry.create!(project: @project, user: @jsmith, author: @jsmith, issue: issue,
                      hours: 2.0, spent_on: Date.new(2026, 3, 12), activity: parent)

    child = TimeEntryActivity.new(name: parent.name, position: parent.position, active: true)
    child.project_id = @project.id
    child.parent_id = parent.id
    child.save!
    @project = Project.find(@project.id)

    TimeEntry.create!(project: @project, user: @jsmith, author: @jsmith, issue: issue,
                      hours: 3.0, spent_on: Date.new(2026, 3, 12), activity: child)

    result = Subject.breakdown(report_scope(@jsmith), group_by: 'activity', actor: @jsmith)

    assert_equal 1, labels_of(result).count(parent.name),
                 "two buckets named #{parent.name.inspect}: #{labels_of(result).inspect}"
    assert_not_includes result['buckets'].map { |b| b['value'] }, child.id.to_s

    # EVERY visible entry on either id, which is more than the two this test created: project
    # 1's fixture already logs hours against the parent. The first version expected 5.0 and
    # read 160.25, which was the aggregator being right about a fixture the test had not read.
    rolled = result['buckets'].find { |b| b['value'] == parent.id.to_s }
    expected = TimeEntry.visible(@jsmith).where(project_id: @project.id)
                        .where(activity_id: [parent.id, child.id]).sum(:hours).to_f.round(2)

    assert_equal expected, rolled['count']
    assert_operator expected, :>=, 5.0, 'the two entries this test created are not in there'
  end

  # ------------------------------------------------------------------ the visibility notice

  # THE `own` STATE NARROWS THE FIGURES, and the aggregator inherits that from
  # `TimeEntry.visible` rather than reimplementing it (§Findings S-14). Asserted at VALUE
  # level with two actors, because that is what makes INV-1 testable rather than claimed.
  def test_a_role_limited_to_own_entries_aggregates_only_its_own_hours
    issue = Issue.where(project_id: @project.id).first
    TimeEntry.create!(project: @project, user: @dlopper, author: @dlopper, issue: issue,
                      hours: 9.0, spent_on: Date.new(2026, 3, 13),
                      activity: TimeEntryActivity.where(active: true).first)
    grant([:view_time_entries], 'own')

    result = Subject.breakdown(report_scope(@jsmith), group_by: 'user', actor: @jsmith)

    assert_equal [@jsmith.id.to_s], result['buckets'].map { |b| b['value'] }
    assert_not_includes result['buckets'].map { |b| b['value'] }, @dlopper.id.to_s
    assert Subject::DIMENSIONS.key?('user'), 'the user dimension is what this reads'
  end

  def test_no_permission_means_no_buckets_and_a_zero_total
    grant([:view_issues])

    result = Subject.breakdown(report_scope(@jsmith), group_by: 'activity', actor: @jsmith)

    assert_equal [], result['buckets']
    assert_equal 0, result['total']
  end
end
