# frozen_string_literal: true

require File.dirname(__FILE__) + '/redmine_reporter_dashboards/compat'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/block_settings'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/positioned'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporter_presence'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/row_layout'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/pdf_polyfills'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/project_page'

module RedmineReporterDashboards
  # Patches that include/prepend into Redmine core (Project, ProjectsHelper).
  # Loaded from after_plugins_loaded so the target classes are present.
  PATCH_FILES = %w[
    redmine_reporter_dashboards/patches/project_patch
  ].freeze

  # Patches that touch redmine_reporter's own classes. Split out from PATCH_FILES
  # because they are loaded only when reporter is actually installed: loading
  # report_patch standalone would warn on every boot about a Report class that is
  # not missing so much as irrelevant.
  REPORTER_PATCH_FILES = %w[
    redmine_reporter_dashboards/patches/report_patch
  ].freeze

  # Glue that is not a patch: code loaded only because reporter is installed, which
  # something else then uses. Loaded with the reporter patches and for the same
  # reason, but listed separately because it prepends into nothing.
  #
  # `glue/legacy/scope_resolution` is here rather than left to
  # `reporter_list_patch`'s own require: `Liquid::ScopeBinding` falls back to it when
  # no RenderContext is present, so on a reporter install it has to be loaded whether
  # or not the prepend into IssueListReportTemplate succeeded. Tying it to that would
  # mean one failed patch silently costing a reporter install its scope resolution.
  REPORTER_GLUE_FILES = %w[
    redmine_reporter_dashboards/glue/legacy/scope_resolution
  ].freeze

  module_function

  def lib_root
    File.dirname(__FILE__)
  end

  # Whether the optional redmine_reporter plugin is installed. One memo, owned by
  # ReporterPresence; see that file for why detection is a positive question asked
  # once at after_plugins_loaded rather than a rescued NameError.
  def reporter_present?
    ReporterPresence.present?
  end

  def reset_reporter_presence!
    ReporterPresence.reset!
  end

  def load_patches
    files = PATCH_FILES + (reporter_present? ? REPORTER_GLUE_FILES + REPORTER_PATCH_FILES : [])
    files.each { |file| require File.join(lib_root, file) }
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

  # Liquid tag that aggregates a report's issues per target version entirely in
  # SQL, so version dashboards avoid an O(versions x issues) Liquid loop.
  VERSION_ROLLUP_TAG_NAME = 'version_rollup'

  # Register the version_rollup Liquid tag. Mirrors register_sql_aggregate_tag:
  # only registers when Liquid is available and degrades gracefully otherwise.
  def register_version_rollup_tag
    require File.join(lib_root, 'sql_aggregation/query_aggregator')

    return unless defined?(::Liquid::Tag)

    require File.join(lib_root, 'sql_aggregation/liquid_version_rollup_tag')
    ::Liquid::Template.register_tag(VERSION_ROLLUP_TAG_NAME, SqlAggregation::LiquidVersionRollupTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] version_rollup tag registration failed: #{e.message}")
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
    require File.join(lib_root, 'redmine_reporter_dashboards/liquid/custom_field_value_drop')
    require File.join(lib_root, 'redmine_reporter_dashboards/liquid/issue_drop_patch')

    klass = Object.const_get('RedmineReporter::Liquid::Drops::IssueDrop')
    patch = RedmineReporterDashboards::Liquid::IssueDropPatch
    klass.prepend(patch) unless klass.ancestors.include?(patch)
    if klass.instance_variable_defined?(:@invokable_methods)
      klass.remove_instance_variable(:@invokable_methods)
    end
    Rails.logger.info('[reporter_dashboards] issue.target_version exposed on Reporter issue drop')
  rescue LoadError, StandardError => e
    # One branch, and it WARNS. This is only reached when reporter_present? already
    # said yes, so a NameError here does not mean "reporter is not installed" — it
    # means reporter is installed and its drop class is not where we expect, which is
    # a real defect and must not be logged as if it were an absent optional feature.
    # (LoadError is not a StandardError, hence naming both: a require failure here
    # must not propagate and abort after_plugins_loaded.)
    Rails.logger.warn("[reporter_dashboards] target_version registration failed: #{e.class}: #{e.message}")
  end

  # Apply the performance patches to reporter's classes. Only called when
  # reporter_present? is true, so absence is not a case handled here.
  def apply_reporter_patches
    apply_patch('IssueListReportTemplate',
                'redmine_reporter_dashboards/glue/legacy/reporter_list_patch',
                'RedmineReporterDashboards::Glue::Legacy::ReporterListPatch')
    apply_patch('ReportTemplatesController', 'reporter_report_content_patch', 'ReporterReportContentPatch')
  end

  def apply_patch(class_name, require_path, module_name)
    # Asked, not inferred from a rescued NameError. const_defined? sees a constant
    # Zeitwerk has registered for autoload without forcing it; the const_get below
    # then triggers the load, in development as before.
    unless Object.const_defined?(class_name)
      Rails.logger.info("[reporter_dashboards] #{class_name} is not defined — #{module_name} not applied")
      return false
    end

    klass = Object.const_get(class_name)
    require File.join(lib_root, require_path)
    patch = Object.const_get(module_name)
    klass.prepend(patch) unless klass.ancestors.include?(patch)
    Rails.logger.info("[reporter_dashboards] #{module_name} applied to #{class_name}")
    true
  rescue LoadError, StandardError => e
    # Warn, never swallow. Past this point the constant existed, so a failure is a
    # defect in loading it — not the absence of an optional plugin.
    Rails.logger.warn("[reporter_dashboards] #{class_name} patch failed: #{e.class}: #{e.message}")
    false
  end
end
