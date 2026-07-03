# frozen_string_literal: true

require File.dirname(__FILE__) + '/redmine_reporter_dashboards/row_layout'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/pdf_polyfills'
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
  rescue LoadError, StandardError => e
    # A patch failing to load must never abort the after_plugins_loaded chain
    # (which would take the Liquid tag registration down with it).
    Rails.logger.warn("[reporter_dashboards] load_patches failed: #{e.message}")
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

    # NOTE: use the top-level ::Liquid explicitly. This plugin also defines a
    # RedmineReporterDashboards::Liquid namespace (VersionDrop), which would
    # otherwise shadow a bare `Liquid` constant here and make this guard/register
    # silently target the wrong (nonexistent) constant.
    return unless defined?(::Liquid::Tag)

    require File.join(lib_root, 'sql_aggregation/liquid_aggregate_tag')
    ::Liquid::Template.register_tag(TAG_NAME, SqlAggregation::LiquidAggregateTag)
    ::Liquid::Template.register_tag(TAG_ALIAS, SqlAggregation::LiquidAggregateTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] sql_aggregate tag registration failed: #{e.message}")
  end

  # Liquid tag exposing a version-name → id/metadata lookup, so report templates
  # can build version-filtered URLs from the Reporter issue drop (which only
  # exposes issue.version as a scalar name).
  VERSION_MAP_TAG_NAME = 'geo_version_map'

  # Register the geo_version_map Liquid tag. Mirrors register_sql_aggregate_tag:
  # only registers when Liquid is available and degrades gracefully otherwise.
  def register_geo_version_map_tag
    return unless defined?(::Liquid::Tag)

    require File.join(lib_root, 'version_mapping/liquid_version_map_tag')
    ::Liquid::Template.register_tag(VERSION_MAP_TAG_NAME, VersionMapping::LiquidVersionMapTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] geo_version_map tag registration failed: #{e.message}")
  end

  # Expose issue.target_version on the Reporter issue drop by prepending
  # IssueDropPatch into RedmineReporter::Liquid::Drops::IssueDrop. Loaded from
  # after_plugins_loaded so Reporter's drop class is already defined.
  #
  # Liquid::Drop memoises the set of invokable methods per class on first use;
  # we clear that memo after prepending so target_version is recognised even if
  # the class was touched before this runs.
  def register_issue_target_version_drop
    return unless defined?(::Liquid::Drop)

    require File.join(lib_root, 'redmine_reporter_dashboards/liquid/version_drop')
    require File.join(lib_root, 'redmine_reporter_dashboards/liquid/issue_drop_patch')

    klass = Object.const_get('RedmineReporter::Liquid::Drops::IssueDrop')
    patch = RedmineReporterDashboards::Liquid::IssueDropPatch
    klass.prepend(patch) unless klass.ancestors.include?(patch)
    if klass.instance_variable_defined?(:@invokable_methods)
      klass.remove_instance_variable(:@invokable_methods)
    end
    Rails.logger.info('[reporter_dashboards] issue.target_version exposed on Reporter issue drop')
  rescue NameError => e
    # Reporter (or its drop class) not present — hard dependency should prevent
    # this, but degrade gracefully rather than break boot.
    Rails.logger.warn("[reporter_dashboards] target_version not registered: #{e.message}")
  rescue LoadError, StandardError => e
    # LoadError is not a StandardError, so catch it explicitly — a require
    # failure here must not propagate and abort after_plugins_loaded.
    Rails.logger.warn("[reporter_dashboards] target_version registration failed: #{e.message}")
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
