# frozen_string_literal: true
#
# Patches IssueListReportTemplate#generate_reports to pass IssueQuery#base_scope
# to liquidize() instead of the pre-loaded issues Array.
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

module ReporterListPatch
  def generate_reports(issues, query_id = nil)
    if query_id.present?
      begin
        # If the controller already passed an AR scope (ReporterReportContentPatch),
        # use it directly. Otherwise look up the query and get base_scope.
        scope = if issues.respond_to?(:where) && issues.respond_to?(:group)
          issues
        else
          IssueQuery.find_by(id: query_id.to_i)&.base_scope
        end

        if scope
          Rails.logger.info("[reporter_list_patch] using base_scope for query #{query_id}")
          html = liquidize(scope)
          return [Report.new(name, filename, html, public_link_params(issues, query_id), orientation)]
        end
      rescue => e
        Rails.logger.warn("[reporter_list_patch] #{e.class}: #{e.message} — falling back to full load")
      end
    end
    super
  end
end
