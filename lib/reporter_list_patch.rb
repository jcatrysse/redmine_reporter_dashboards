# frozen_string_literal: true
#
# Patches IssueListReportTemplate#generate_reports to pass IssueQuery#base_scope
# to liquidize() instead of the pre-loaded issues Array, and to make the report's
# own IssueQuery reachable from the Liquid tags.
#
# Without this patch:
#   generate_reports(issues, query_id)
#     → issues is a loaded Array of 10k Issue objects (loaded by the controller)
#     → liquidize(issues) stores the Array in IssuesDrop#@issues
#     → sql_aggregate reconstructs Issue.where(id: [10k ids]) — slow
#
# With this patch:
#   generate_reports(scope, query_id)
#     → liquidize(scope) stores an AR::Relation in IssuesDrop#@issues
#     → sql_aggregate uses the scope directly for COUNT(*) GROUP BY — fast
#     → if the template iterates issues, they are loaded lazily on demand
#
# public_link_params still receives the original loaded issues so that
# link generation (which may need Array behaviour) is unaffected.
#
# --- Why a thread-local ---
#
# Drill-through URLs ({% sql_aggregate drill: true %}) have to inherit the report
# query's filters, columns, grouping, totals and sort order, so the tags need the
# IssueQuery itself, not just its scope. Reporter's liquidize() takes no
# registers argument we can extend from the outside, and it deliberately receives
# the scope rather than the query, so the query is parked in a thread-local for
# the duration of the render. ScopeResolution#resolve_query reads it LAST, after
# every context.registers lookup, so a future Reporter release that passes the
# query properly wins over this fallback without a code change here.
#
# The assignment is always undone in an ensure — Rails reuses request threads, and
# a leaked query would let one user's filters bleed into another user's report.
#
# The query is now resolved on both paths, which costs one primary-key lookup per
# report render that the fast path did not do before. Deliberate: a template cannot
# be asked whether it uses drill: true before it is rendered, and one indexed
# lookup is nothing against rendering a report.

# For QUERY_THREAD_KEY: this patch is applied after the Liquid tags are
# registered, which loads the module already, but the tag registration is skipped
# when Liquid is absent — so require it explicitly rather than depend on that.
require_relative 'sql_aggregation/scope_resolution'

module ReporterListPatch
  def generate_reports(issues, query_id = nil)
    if query_id.present?
      begin
        query = IssueQuery.find_by(id: query_id.to_i)

        # If the controller already passed an AR scope (ReporterReportContentPatch),
        # use it directly. Otherwise use the query's base_scope.
        scope = if issues.respond_to?(:where) && issues.respond_to?(:group)
          issues
        else
          query&.base_scope
        end

        if scope
          Rails.logger.info("[reporter_list_patch] using base_scope for query #{query_id}")
          html = rrd_with_issue_query(query) { liquidize(scope) }
          return [Report.new(name, filename, html, public_link_params(issues, query_id), orientation)]
        end
      rescue => e
        Rails.logger.warn("[reporter_list_patch] #{e.class}: #{e.message} — falling back to full load")
      end
    end
    super
  end

  private

  # Restores the previous value rather than blindly clearing, so a nested render
  # can never strand an outer report without its query. The outermost frame had
  # nil, so nothing leaks either way.
  #
  # Prefixed: this module is PREPENDED into a Reporter class, so a helper of its
  # own must not be able to collide with a method there (or in another plugin's
  # patch). generate_reports is meant to override; this is not.
  def rrd_with_issue_query(query)
    key      = SqlAggregation::ScopeResolution::QUERY_THREAD_KEY
    previous = Thread.current[key]
    Thread.current[key] = query
    yield
  ensure
    Thread.current[key] = previous
  end
end
