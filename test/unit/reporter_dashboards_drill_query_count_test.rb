# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-47's COST, MEASURED — FR-48 / gate G6, and the finding that produced this file was
# refuted by the first run of it.
#
# --- WHAT THE REVIEW SAID, AND WHAT THE MEASUREMENT SAYS ---
#
# An independent review read T-47 and reported that `drill_builder` now constructs an
# `IssueQuery` per `{% sql_aggregate drill: true %}` tag per document, with no memoisation,
# so a 4 000-issue per-record export would pay `documents × drill tags` of them where it
# previously paid none. The reasoning is exactly right about the code and wrong about what
# the code can reach, and the difference is one fact neither of us had in front of us:
#
#     a PER-RECORD job renders with `scope: nil`.
#
# `ReportRun#render_context` passes `job.record ? nil : scope_for_render`, because a
# per-record document is about ONE issue and handing it the whole collection would make
# `{{ issues.size }}` print 4 000 on every page. `{% sql_aggregate %}` therefore cannot
# resolve a relation there at all — it logs *"could not resolve an AR scope — skipping
# aggregation"* and returns before `apply_drill`, which is where `drill_builder` is called
# from. The per-record export does not build one fallback query. It builds none.
#
# So the growth this file exists to refuse is not reachable through the path the finding
# names — and that is precisely why it is pinned rather than argued in a commit message. A
# later change that gives per-record jobs a scope (a reasonable thing to want) would make
# the finding correct retroactively, and this file is what would say so.
#
# --- WHAT IS ASSERTED ---
#
#   1. a per-record run's query count does not grow with the number of documents;
#   2. a combined run with drill-through and no saved query — the path T-47 added, and the
#      one every PDF, mail and share link takes — costs a bounded number of queries, stated
#      as a number rather than as "not many".
#
# THE WARM-UP IS NOT DECORATION. The first run in a process pays for schema reflection,
# `Setting` loads and Redmine's own first-touch caches; measured, that is three extra
# statements, and a test that counted them would fail on the day somebody added a fourth.
class ReporterDashboardsDrillQueryCountTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  Template = RedmineReporterDashboards::Template
  ReportRun = RedmineReporterDashboards::Reporting::ReportRun

  DRILL_TEMPLATE =
    '{% sql_aggregate group_by: status, drill: true, assign: stats %}' \
    '{{ stats.drill_available }}|{{ stats.buckets.size }}'

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @actor = User.find_by!(login: 'admin')
    User.current = @actor
  end

  def template(output:, content: DRILL_TEMPLATE)
    Template.create!(project: @project, author: @actor, name: "drill-#{output}",
                     content: content, source: 'issues', output: output,
                     visibility: Template::VISIBILITY_PUBLIC)
  end

  def run_report(record, limit: nil)
    scope = Issue.visible(@actor).where(project_id: @project.id)
    scope = scope.limit(limit) if limit
    ReportRun.new(template: record, actor: @actor, scope: scope,
                  guard: RedmineReporterDashboards::Render::BatchGuard.new(max_documents: 50))
             .call(pdf: false)
  end

  def count_queries
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      next if %w[CACHE SCHEMA TRANSACTION].include?(payload[:name])

      count += 1
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    count
  end

  # FR-48, stated as the shape rather than as a number: whatever a run costs, it must cost
  # the same for two documents as for six.
  def test_a_per_record_run_does_not_cost_more_queries_for_more_documents
    record = template(output: 'per_record')
    run_report(record, limit: 1) # warm-up, see the class comment

    two = count_queries { run_report(record, limit: 2) }
    six = count_queries { run_report(record, limit: 6) }

    assert_equal two, six,
                 "a per-record run cost #{two} queries for 2 documents and #{six} for 6"
  end

  # AND THE DOCUMENTS ARE REALLY PRODUCED, or the assertion above would hold for a run that
  # refused. This is the control the query-count assertion cannot do without.
  def test_the_per_record_run_really_rendered_one_document_per_record
    record = template(output: 'per_record')

    assert_equal 6, run_report(record, limit: 6).sections.length
  end

  # THE PATH T-47 ACTUALLY ADDED. No saved query, so `resolve_query` answers nil and the
  # fallback builds one from the report's project — and the drill URLs appear, which is the
  # behaviour M-9 was about. The number is pinned so that a future change which starts
  # issuing a query per BUCKET fails here with a number instead of passing quietly.
  def test_a_combined_run_with_the_fallback_costs_a_bounded_number_of_queries
    record = template(output: 'combined')
    run_report(record) # warm-up

    count = count_queries { @outcome = run_report(record) }

    assert_match(/\Atrue\|[1-9]/, @outcome.sections.first.body,
                 'precondition: the fallback really produced drill URLs')
    assert_operator count, :<=, 20, "the combined run cost #{count} queries"
  end
end
