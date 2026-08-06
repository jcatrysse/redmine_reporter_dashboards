# frozen_string_literal: true

require File.dirname(__FILE__) + '/redmine_reporter_dashboards/compat'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/block_settings'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/positioned'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporter_presence'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/row_layout'

# The render layer (T-10). Loaded here rather than autoloaded because a plugin's lib/
# is not on Redmine's autoload paths, and required at boot rather than lazily so a
# syntax or load error surfaces on the branch that broke it instead of on the first
# render. Nothing calls it yet — T-11 onward do.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/capabilities'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/page_furniture'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/failure'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/result'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/document_request'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/registry'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/renderer'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/readiness'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/process_pool'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/engine_catalogue'
# The diagnostic (T-14). Required at boot for the same reason as the rest: the admin
# controller and the rake task both reach it, and a load error should surface on the
# branch that broke it rather than the first time an administrator asks whether their
# render path works.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/pdf_inspector'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/preflight'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/preflight_suite'
# The adapters. Requiring them REGISTERS them; it does not start a browser or run a
# binary, so a host without either boots exactly as before and finds out at preflight.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/engines/chromium_cdp'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/engines/wkhtmltopdf'
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
    redmine_reporter_dashboards/glue/legacy/wk_legacy_shims
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
    require File.join(lib_root, 'redmine_reporter_dashboards/aggregation')

    # NOTE: use the top-level ::Liquid explicitly. This plugin also defines a
    # RedmineReporterDashboards::Liquid namespace (the owned drop layer), which
    # would otherwise shadow a bare `Liquid` constant here and make this
    # guard/register silently target the wrong (nonexistent) constant.
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
    require File.join(lib_root, 'redmine_reporter_dashboards/aggregation')

    return unless defined?(::Liquid::Tag)

    require File.join(lib_root, 'sql_aggregation/liquid_version_rollup_tag')
    ::Liquid::Template.register_tag(VERSION_ROLLUP_TAG_NAME, SqlAggregation::LiquidVersionRollupTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] version_rollup tag registration failed: #{e.message}")
  end

  # DEPRECATED (T-20). The tag NAME is registered for one more minor version so
  # templates in somebody else's database do not become parse errors overnight; the
  # owned drop layer's `issue.version` replaces what it did. See
  # VersionMapping::LiquidVersionMapTag for the removal condition.
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

  # RETIRED IN T-20: `register_issue_target_version_drop`.
  #
  # It prepended a module into `RedmineReporter::Liquid::Drops::IssueDrop` to add
  # `issue.target_version` and `issue.custom_field_value[…]` to the HOST plugin's drop.
  # Both accessors now live on this plugin's own `Drops::IssueDrop` — `target_version`
  # as an alias of `version`, `custom_field_value` as `CustomFieldValuesDrop` — so the
  # template vocabulary is unchanged and the monkey-patch into another plugin's class
  # is gone. That patch was two of the entries in `zero_reporter.allowlist`; both went
  # with it.
  #
  # There is a WINDOW, and it is stated rather than hidden: until the owned renderer
  # constructs these drops (T-23), a report rendered by the host plugin gets the gem's
  # drop, which has neither accessor. `spec/liquid/retired_surface_spec.rb` pins the
  # deletion; `implementation-plan.md` §Findings F-11 records the window.

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
