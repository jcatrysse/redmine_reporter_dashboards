# frozen_string_literal: true
#
# Patches ReportTemplatesController#report_content to pass IssueQuery#base_scope
# instead of calling @query.issues, which materialises all Issue objects into memory.
#
# The original action (report_templates_controller.rb ~line 76) does:
#   collection = @query.is_a?(IssueQuery) ? @query.issues : @query.results_scope
#
# With this patch, IssueQuery reports use base_scope (lazy AR::Relation) so no
# Issue objects are loaded for templates that only use {% sql_aggregate %}.
# Templates that do {% for issue in issues %} still work — the relation
# materialises lazily when Liquid iterates it.
#
# For non-IssueQuery reports (time entries etc.) we fall through to super unchanged.
# On any exception we fall through to super so Reporter continues to work.

module ReporterReportContentPatch
  def report_content
    unless @query.is_a?(IssueQuery) && @query.respond_to?(:base_scope)
      Rails.logger.info("[reporter_report_content_patch] skipping patch: query=#{@query.class} base_scope=#{@query.respond_to?(:base_scope)}")
      return super
    end

    t0         = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    collection = @query.base_scope
    Rails.logger.info("[reporter_report_content_patch] using base_scope (#{collection.class}) for query #{@query.id}")

    @content = @report_template.generate_reports(collection, @query.id).first&.content
    Rails.logger.info("[reporter_report_content_patch] generate_reports done in #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)}ms")
    render layout: false
  rescue => e
    Rails.logger.warn("[reporter_report_content_patch] #{e.class}: #{e.message} — falling back")
    super
  end
end
