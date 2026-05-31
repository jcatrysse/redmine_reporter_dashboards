# frozen_string_literal: true

require File.dirname(__FILE__) + '/redmine_reporter_dashboards/project_page'

module RedmineReporterDashboards
  # Patches that include/prepend into core (Project, ProjectsHelper, Report).
  # Loaded from after_plugins_loaded so the target classes are present.
  PATCH_FILES = %w[
    redmine_reporter_dashboards/patches/project_patch
    redmine_reporter_dashboards/patches/report_patch
  ].freeze

  module_function

  def lib_root
    File.dirname(__FILE__)
  end

  def load_patches
    PATCH_FILES.each { |file| require File.join(lib_root, file) }
  end

  # Primary Liquid tag name; the legacy name is kept as a backward-compatible
  # alias so report templates written against the old plugin keep working.
  TAG_NAME = 'sql_aggregate'
  TAG_ALIAS = 'geo_aggregate'

  # Register the sql_aggregate Liquid tag (and its geo_aggregate alias).
  # QueryAggregator is required unconditionally because SqlStatsController
  # depends on it; the tag itself is only registered when Liquid is available
  # (it always is under Redmine, but we stay defensive so a missing dependency
  # degrades gracefully).
  def register_sql_aggregate_tag
    require File.join(lib_root, 'sql_aggregation/query_aggregator')

    return unless defined?(Liquid::Tag)

    require File.join(lib_root, 'sql_aggregation/liquid_aggregate_tag')
    Liquid::Template.register_tag(TAG_NAME, SqlAggregation::LiquidAggregateTag)
    Liquid::Template.register_tag(TAG_ALIAS, SqlAggregation::LiquidAggregateTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] sql_aggregate tag registration failed: #{e.message}")
  end

  # Apply the performance patches to reporter classes when they are present.
  # Object.const_get triggers Zeitwerk autoload in development; in production the
  # classes are already loaded. NameError simply means reporter is not installed
  # (should not happen given the hard dependency, but we stay defensive).
  def apply_reporter_patches
    apply_patch('IssueListReportTemplate', 'reporter_list_patch', 'ReporterListPatch')
    apply_patch('ReportTemplatesController', 'reporter_report_content_patch', 'ReporterReportContentPatch')
  end

  def apply_patch(class_name, require_path, module_name)
    klass = Object.const_get(class_name)
    require File.join(lib_root, require_path)
    patch = Object.const_get(module_name)
    klass.prepend(patch) unless klass.ancestors.include?(patch)
    Rails.logger.info("[reporter_dashboards] #{module_name} applied to #{class_name}")
  rescue NameError
    nil
  rescue => e
    Rails.logger.warn("[reporter_dashboards] #{class_name} patch failed: #{e.message}")
  end
end
