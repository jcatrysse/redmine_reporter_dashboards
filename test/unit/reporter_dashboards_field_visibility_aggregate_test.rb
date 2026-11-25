# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# redmine_issue_field_visibility and the aggregation tags (curator decision 2026-11-25,
# `docs/DECISIONS-2026-11-25.md`: "Ook de teltags afschermen").
#
# The Developer role (2) hides estimated_hours and assigned_to_id; the Manager role (1) hides
# nothing. dlopper (3) is Developer in project 1; jsmith (2) is Manager in project 1 and
# Developer in project 2, so a scope over both projects is the MIXED case.
#
# The real plugin is used when installed, a simulation of its one entry point otherwise (as
# in reporter_dashboards_base_accessors_test.rb). Every case is red on the code before the
# `field-visibility` kernel hunk.
class ReporterDashboardsFieldVisibilityAggregateTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :issues, :issue_statuses, :trackers, :projects_trackers,
           :enumerations, :user_preferences, :versions, :issue_categories, :time_entries

  Template = RedmineReporterDashboards::Template
  ReportRun = RedmineReporterDashboards::Reporting::ReportRun
  Batch = RedmineReporterDashboards::Liquid::Batch
  FieldVisibility = RedmineReporterDashboards::Aggregation::FieldVisibility

  HIDDEN = { 2 => %w[estimated_hours assigned_to_id] }.freeze

  BUCKETS = '{% for b in s.buckets %}{{ b.label }}={{ b.count }};{% endfor %}' \
            '|{{ s.total }}|{{ s.hidden_fields | join: "," }}'

  # A stand-in for the plugin: the method the Batch calls, answering by role per project.
  module SimulatedRule
    mattr_accessor :hidden, default: {}

    def self.hidden_core_fields(user, project = nil)
      return [] if user.admin? || project.nil?

      roles = user.roles_for_project(project).map(&:id)
      lists = roles.map { |id| Array(hidden[id]) }
      lists.empty? ? [] : lists.inject(:&)
    end
  end

  REAL_PLUGIN = Batch.field_visibility_rule?

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @admin = User.find_by!(login: 'admin')
    @manager = User.find(2)   # jsmith
    @developer = User.find(3) # dlopper
    User.current = nil
    # The bucket label is translated; every assertion below is in English (§6).
    @locale = I18n.locale
    I18n.locale = :en
    {
      1 => { assigned_to_id: 2, estimated_hours: 2.0 },
      2 => { assigned_to_id: 3, estimated_hours: 3.0 },
      3 => { assigned_to_id: 3, estimated_hours: 4.0 },
      4 => { assigned_to_id: 2, estimated_hours: 8.0 }
    }.each { |id, attrs| Issue.find(id).update_columns(attrs) }
  end

  def teardown
    User.current = nil
    I18n.locale = @locale
  end

  # Runs the block with the Developer role's fields hidden, by the real plugin's setting or
  # by the simulation.
  def with_hidden(hidden = HIDDEN, &)
    if REAL_PLUGIN
      setting = hidden.to_h { |role, fields| [role.to_s, fields.index_with('1')] }
      with_settings(plugin_redmine_issue_field_visibility: { 'hiddenfields' => setting }, &)
    else
      begin
        SimulatedRule.hidden = hidden
        Object.const_set(:RedmineIssueFieldVisibility, SimulatedRule)
        assert Batch.field_visibility_rule?
        yield
      ensure
        SimulatedRule.hidden = {}
        Object.send(:remove_const, :RedmineIssueFieldVisibility) if Object.const_defined?(:RedmineIssueFieldVisibility)
      end
    end
  end

  def run_report(actor, issue_ids, content, query: nil, scope: nil)
    template = Template.create!(project: @project, author: @admin, name: "ifv-#{SecureRandom.hex(4)}",
                                content: content, source: 'issues', output: 'combined',
                                visibility: Template::VISIBILITY_PUBLIC)
    scope ||= Issue.visible(actor).where(id: issue_ids).order(:id)
    outcome = ReportRun.new(template: template, actor: actor, scope: scope, query: query,
                            guard: RedmineReporterDashboards::Render::BatchGuard.new)
                       .call(pdf: false)
    assert_nil outcome.diagnostic, outcome.diagnostic&.message
    outcome
  end

  def render(actor, issue_ids, content, **)
    run_report(actor, issue_ids, content, **).sections.first.body.strip
  end

  def codes(outcome)
    Array(outcome.degradations).map { |degradation| degradation.code.to_s }
  end

  def statements(&)
    seen = []
    counter = lambda do |_name, _start, _finish, _id, payload|
      seen << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    seen
  end

  def tag(params)
    "{% sql_aggregate #{params} assign_to: s %}#{BUCKETS}"
  end

  # ------------------------------------------------------------------
  # Grouping by a hidden field: one bucket per hiding project, never split
  # ------------------------------------------------------------------

  def test_developer_groups_every_issue_into_one_hidden_bucket
    with_hidden do
      # the legacy breakdown (no dimension parameter) and the dimension path alike
      assert_equal 'Hidden=3;|3|assigned_to_id', render(@developer, [1, 2, 3], tag('group_by: assignee'))
      assert_equal 'Hidden=3;|3|assigned_to_id',
                   render(@developer, [1, 2, 3], tag('group_by: assignee sort: label'))
    end
  end

  def test_manager_and_admin_keep_todays_result_byte_for_byte
    expected = 'dlopper=2;jsmith=1;|3|'
    baseline = render(@manager, [1, 2, 3], tag('group_by: assignee'))
    assert_equal expected, baseline
    with_hidden do
      assert_equal expected, render(@manager, [1, 2, 3], tag('group_by: assignee'))
      assert_equal expected, render(@admin, [1, 2, 3], tag('group_by: assignee'))
      assert_equal 'Dave Lopper=2;John Smith=1;|3|',
                   render(@manager, [1, 2, 3], tag('group_by: assignee sort: label'))
    end
  end

  def test_mixed_scope_hides_only_the_project_that_hides_the_field
    with_hidden do
      # project 1 (Manager): split by assignee; project 2 (Developer): issue 4 in the bucket
      assert_equal 'dlopper=2;Hidden=1;jsmith=1;|4|assigned_to_id',
                   render(@manager, [1, 2, 3, 4], tag('group_by: assignee'))
    end
    # no tie left to the database's row order (§6)
    assert_equal 'dlopper=2;jsmith=2;|4|', render(@manager, [1, 2, 3, 4], tag('group_by: assignee user_label: login'))
  end

  def test_a_crosstab_over_a_hidden_field_has_one_hidden_row
    template = '{% sql_aggregate group_by: assignee split_by: tracker assign_to: s %}' \
               '{% for r in s.rows %}{{ r.label }}={{ r.total }};{% endfor %}'
    with_hidden do
      assert_equal 'Hidden=3;', render(@developer, [1, 2, 3], template)
    end
  end

  def test_drill_down_links_do_not_reveal_the_hidden_values
    template = '{% sql_aggregate group_by: assignee drill: true assign_to: s %}' \
               '{{ s.drill_available }}|{% for b in s.buckets %}{{ b.label }}=[{{ b.url }}][{{ b.value }}];{% endfor %}'
    with_hidden do
      # no URL, and no group key a template could mistake for a value
      assert_equal 'true|Hidden=[][];', render(@developer, [1, 2, 3], template)
      # mixed: no link on a visible value either, or its issue list would also count the
      # hidden project's issues with that value
      mixed = render(@manager, [1, 2, 3, 4], template)
      assert_not_includes mixed, 'assigned_to_id'
      assert_no_match(/=\[http/, mixed)
    end
  end

  def test_a_hidden_split_by_is_one_hidden_series
    template = '{% sql_aggregate group_by: tracker split_by: assignee assign_to: s %}' \
               '{{ s.series | join: "," }}|{% for e in s.series_entries %}[{{ e.value }}][{{ e.filter }}]{% endfor %}'
    with_hidden do
      assert_equal 'Hidden|[][]', render(@developer, [1, 2, 3], template)
    end
  end

  def test_the_hidden_bucket_folded_into_other_leaves_no_trace_in_its_values
    template = '{% sql_aggregate group_by: assignee limit: 1 user_label: login assign_to: s %}' \
               '{% for b in s.buckets %}{{ b.label }}={{ b.count }}[{{ b.values | join: "," }}];{% endfor %}'
    with_hidden do
      assert_equal 'dlopper=2[];Other=2[2];', render(@manager, [1, 2, 3, 4], template)
    end
  end

  def test_age_over_a_hidden_due_date_is_one_hidden_bucket
    Issue.where(id: [1, 2, 3]).update_all(due_date: Date.new(2026, 1, 15))
    template = '{% sql_aggregate group_by: age age_field: due assign_to: s %}' \
               '{% for b in s.buckets %}{{ b.label }}={{ b.count }}[{{ b.value }}];{% endfor %}|{{ s.hidden_fields | join: "," }}'
    with_hidden(2 => %w[due_date]) do
      out = render(@developer, [1, 2, 3], template)
      assert out.end_with?('Hidden=3[];|due_date'), out
      assert_no_match(/[^n]=[1-9]/, out.delete_suffix('Hidden=3[];|due_date'))
    end
  end

  def test_nothing_hidden_changes_no_path
    paths = [tag('group_by: assignee'), tag('group_by: status measure: sum of: estimated_hours'),
             '{% sql_aggregate group_by: flags assign_to: f %}{{ f.assigned }}|{{ f.no_estimate }}|{{ f.hidden_fields }}',
             '{% sql_aggregate group_by: completeness fields: "assignee;estimated" assign_to: c %}' \
             '{% for b in c.buckets %}{{ b.count }}/{{ b.total }}[{{ b.filter }}]{% endfor %}{{ c.hidden_fields }}',
             '{% sql_aggregate period: month periods: 2 assign_to: t %}{{ t.total }}']
    before = paths.map { |template| render(@developer, [1, 2, 3], template) }
    with_hidden({}) do
      assert_equal before, paths.map { |template| render(@developer, [1, 2, 3], template) }
    end
  end

  # ------------------------------------------------------------------
  # Measuring a hidden field: the visible projects' values only
  # ------------------------------------------------------------------

  def test_developer_gets_no_hours
    with_hidden do
      assert_equal 'Assigned=0.0;New=0.0;|0.0|estimated_hours',
                   render(@developer, [1, 2, 3], tag('group_by: status sort: label measure: sum of: estimated_hours'))
    end
    assert_equal 'Assigned=3.0;New=6.0;|9.0|',
                 render(@developer, [1, 2, 3], tag('group_by: status sort: label measure: sum of: estimated_hours'))
  end

  def test_mixed_scope_sums_the_visible_projects_and_says_part_was_hidden
    with_hidden do
      assert_equal 'Assigned=3.0;New=6.0;|9.0|estimated_hours',
                   render(@manager, [1, 2, 3, 4], tag('group_by: status sort: label measure: sum of: estimated_hours'))
      assert_equal 'Assigned=3.0;New=14.0;|17.0|',
                   render(@admin, [1, 2, 3, 4], tag('group_by: status sort: label measure: sum of: estimated_hours'))
    end
  end

  def test_a_distinct_count_of_a_hidden_reference_leaves_the_hidden_projects_out
    with_hidden do
      assert_equal 'Assigned=0;New=0;|0|assigned_to_id',
                   render(@developer, [1, 2, 3], tag('group_by: status sort: label measure: distinct of: assignee'))
    end
  end

  # ------------------------------------------------------------------
  # Flags and completeness
  # ------------------------------------------------------------------

  def test_flags_count_a_hidden_field_over_the_visible_projects_only
    template = '{% sql_aggregate group_by: flags assign_to: f %}' \
               '{{ f.total }}|{{ f.assigned }}|{{ f.unassigned }}|{{ f.no_estimate }}|' \
               '{{ f.flags.assigned }}|{{ f.hidden_fields | join: "," }}'
    with_hidden do
      assert_equal '3|0|0|0|0|assigned_to_id,estimated_hours', render(@developer, [1, 2, 3], template)
      assert_equal '4|3|0|0|3|assigned_to_id,estimated_hours', render(@manager, [1, 2, 3, 4], template)
      assert_equal '4|4|0|0|4|', render(@admin, [1, 2, 3, 4], template)
    end
  end

  def test_completeness_of_a_hidden_field_covers_the_visible_projects_only
    template = '{% sql_aggregate group_by: completeness fields: "assignee;estimated;due" assign_to: c %}' \
               '{% for b in c.buckets %}{{ b.value }}={{ b.count }}/{{ b.total }}[{{ b.filter }}];{% endfor %}'
    with_hidden do
      out = render(@developer, [1, 2, 3], template)
      assert_match(/\Aassigned_to_id=0\/0\[\];estimated_hours=0\/0\[\];due_date=\d\/3\[.+\];\z/, out)
    end
  end

  def test_a_hidden_funnel_stage_links_nowhere
    template = '{% sql_aggregate group_by: flags drill: true assign_to: f %}' \
               '{% for st in f.stages %}{{ st.key }}=[{{ st.url | size }}];{% endfor %}'
    with_hidden do
      out = render(@developer, [1, 2, 3], template)
      assert_includes out, 'assigned=[0];'
      assert_match(/total=\[[1-9]\d*\];/, out)
    end
  end

  # ------------------------------------------------------------------
  # A condition on a hidden field
  # ------------------------------------------------------------------

  def test_a_query_filtering_on_a_hidden_field_leaves_the_hiding_projects_out
    query = IssueQuery.new(name: 'ifv', project: nil, user: @admin, visibility: IssueQuery::VISIBILITY_PUBLIC)
    query.filters = { 'assigned_to_id' => { operator: '=', values: ['2'] } }
    scope = Issue.visible(@manager).where(id: [1, 2, 3, 4]).where(assigned_to_id: 2)
    with_hidden do
      outcome = run_report(@manager, nil, tag('group_by: status'), query: query, scope: scope)
      assert_equal 'New=1;|1|', outcome.sections.first.body.strip
      assert_includes codes(outcome), 'aggregation_hidden_filter'

      outcome = run_report(@admin, nil, tag('group_by: status'), query: query,
                                                                 scope: Issue.where(id: [1, 4], assigned_to_id: 2))
      assert_equal 'New=2;|2|', outcome.sections.first.body.strip
      assert_not_includes codes(outcome), 'aggregation_hidden_filter'
    end
  end

  def test_filter_names_map_to_the_field_they_read
    assert_equal 'assigned_to_id', FieldVisibility.filter_field('member_of_group')
    assert_equal 'assigned_to_id', FieldVisibility.filter_field('assigned_to.cf_4')
    assert_equal 'fixed_version_id', FieldVisibility.filter_field('issue.fixed_version_id')
    assert_equal 'description', FieldVisibility.filter_field('any_searchable')
    assert_nil FieldVisibility.filter_field('status_id')
  end

  Recorder = Struct.new(:records) do
    def degrade(code, **data)
      records << [code, data]
    end
  end

  def test_spent_time_grouped_by_a_hidden_issue_field_leaves_those_projects_out
    scope = TimeEntry.where(project_id: [1, 3])
    hidden = { 'fixed_version_id' => [1] }
    diagnostics = Recorder.new([])

    by_version = FieldVisibility.apply_time_entry_rule(scope, 'version', hidden, diagnostics)
    assert_equal [], by_version.where(project_id: 1).pluck(:id)
    assert_equal scope.where(project_id: 3).order(:id).pluck(:id), by_version.order(:id).pluck(:id)
    assert_equal [:aggregation_hidden_group], diagnostics.records.map(&:first)

    assert_same scope, FieldVisibility.apply_time_entry_rule(scope, 'activity', hidden, diagnostics)
    assert_equal 1, diagnostics.records.length
  end

  # ------------------------------------------------------------------
  # {% version_rollup %}
  # ------------------------------------------------------------------

  def test_version_rollup_leaves_out_the_projects_that_hide_what_it_reads
    Issue.where(id: [1, 2, 3]).update_all(fixed_version_id: 2)
    template = '{% version_rollup assign_to: v %}{% for r in v %}{{ r.total }}/{{ r.est_hours }};{% endfor %}'
    with_hidden do
      outcome = run_report(@developer, [1, 2, 3], template)
      assert_equal '', outcome.sections.first.body.strip
      assert_includes codes(outcome), 'aggregation_hidden_rollup'
      assert_equal '3/9.0;', render(@manager, [1, 2, 3], template)
    end
  end

  # ------------------------------------------------------------------
  # Query count: per project, never per issue
  # ------------------------------------------------------------------

  def test_the_query_count_does_not_grow_with_the_issue_count
    with_hidden do
      template = tag('group_by: assignee measure: sum of: estimated_hours')
      render(@developer, [1], template) # warm the schema and the role caches
      one = statements { render(@developer, [1], template) }.length
      many = statements { render(@developer, [1, 2, 3, 7, 8, 11, 12], template) }.length
      assert_equal one, many

      # two projects, one of them hiding: more issues, the same statements
      render(@manager, [1, 4], template)
      two = statements { render(@manager, [1, 4], template) }.length
      assert_equal two, statements { render(@manager, [1, 2, 3, 4, 7, 8], template) }.length
    end
  end
end
