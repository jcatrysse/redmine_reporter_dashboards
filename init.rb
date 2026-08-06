# frozen_string_literal: true

require 'redmine'

# ---------------------------------------------------------------------------
# redmine_reporter is OPTIONAL
#
# It used to be a hard dependency enforced here with a `raise`, which made this
# plugin uninstallable without a paid third-party plugin. Project dashboards, the
# SQL aggregation tags and the statistics endpoint need none of it.
#
# Detection is therefore deferred rather than done here: it belongs at
# after_plugins_loaded, below, where every plugin's init.rb has run and the
# registry is actually complete. Asking at this point would answer for whatever
# subset of plugins happened to load first.
#
# See RedmineReporterDashboards.reporter_present?.
# ---------------------------------------------------------------------------

if Rails.configuration.respond_to?(:autoloader) && Rails.configuration.autoloader == :zeitwerk
  Rails.autoloaders.each { |loader| loader.ignore(File.dirname(__FILE__) + '/lib') }
end
require File.dirname(__FILE__) + '/lib/redmine_reporter_dashboards'

Redmine::Plugin.register :redmine_reporter_dashboards do
  name 'Redmine Reporter Dashboards plugin'
  author 'Jan Catrysse'
  description 'Dashboard extension for the Redmine Reporter plugin, adding project dashboards, ' \
              'SQL-based issue statistics and Liquid aggregation tags.'
  version '0.5.0'
  url 'https://github.com/jcatrysse/redmine_reporter_dashboards'
  author_url 'https://github.com/jcatrysse'

  # No requires_redmine_plugin: reporter is optional, and declaring it here would
  # make Redmine refuse to load this plugin without it.
  requires_redmine version_or_higher: '5.1'

  # --- Asset policy (T-33; technical-spec.md §5.1, FR-64) ---
  #
  # `:bundled` is the default and it is the whole security posture: no egress, third-party
  # URLs refused with the URL named. The two upgraded modes are PER INSTALL and never per
  # template — there is deliberately no project setting and no template field for them,
  # because template authoring is already a code-execution privilege (INV-9) and must not
  # additionally become a network privilege.
  #
  # Redmine performs NO validation on plugin settings, so every value here is coerced and
  # bounded on the way OUT, in `Assets::Policy.from_settings`, which drops an out-of-range
  # value with a log line rather than storing it (FR-15). The defaults below are therefore
  # the documented ones and not the enforcement.
  settings default: {
             'asset_policy' => 'bundled',
             'asset_allowlist' => '',
             'inline_max_bytes' => RedmineReporterDashboards::Assets::Policy::DEFAULT_INLINE_MAX_BYTES.to_s,
             'asset_max_bytes' => RedmineReporterDashboards::Assets::Policy::DEFAULT_ASSET_MAX_BYTES.to_s
           },
           partial: 'settings/reporter_dashboards'

  project_module :reporter_project_dashboards do
    permission :view_reporter_project_page, { reporter_project_pages: [:show, :report_pdf] }, read: true
    permission :manage_reporter_project_page, {
      reporter_project_pages: [:update_page, :add_block, :remove_block, :move_block]
    }
    permission :manage_reporter_project_tabs, {
      reporter_project_tabs: [:create, :update, :destroy, :order]
    }
  end

  # T-14. No icon class: the admin menu's icon mechanism changed between Redmine 5.1
  # and 6.x (`icon icon-*` versus `sprite_icon`), and a one-item diagnostic link is not
  # worth a `compat/` entry or a divergence the LOC budget has to carry. A plain link
  # renders correctly on all four supported branches.
  menu :admin_menu, :reporter_dashboards_preflight,
       { controller: 'reporter_preflight', action: 'show' },
       caption: :label_reporter_preflight

  menu :project_menu, :reporter_project_page,
       { controller: 'reporter_project_pages', action: 'show' },
       caption: :label_reporter_project_page,
       after: :overview,
       param: :project_id,
       if: proc { |project|
         project.module_enabled?(:reporter_project_dashboards) &&
           (User.current.admin? || User.current.allowed_to?(:view_reporter_project_page, project))
       }
end

# ---------------------------------------------------------------------------
# Patch + Liquid tag loading
#
# Everything that prepends/includes into core or reporter classes is deferred
# to after_plugins_loaded so that:
#   * Project / ProjectsHelper / Report are fully defined, and
#   * reporter classes (IssueListReportTemplate, ReportTemplatesController) have
#     been registered by redmine_reporter's own init.rb.
#
# after_plugins_loaded fires at the end of the same to_prepare cycle, after
# every plugin's init.rb has run. (Nesting a to_prepare here would defer to the
# next cycle, which never arrives in production.)
# ---------------------------------------------------------------------------
class RedmineReporterDashboardsLoader < Redmine::Hook::Listener
  def after_plugins_loaded(_context = {})
    # Asked exactly once, here, and memoised from now on. This is the first moment
    # the answer is trustworthy and the last moment it can still change.
    reporter = RedmineReporterDashboards.reporter_present?

    # Logged either way, at info. "Running standalone" is a normal state, not a
    # degradation — but an operator who expected the report widgets to be there
    # needs one line telling them why they are not, rather than an empty picker.
    Rails.logger.info(
      if reporter
        '[reporter_dashboards] redmine_reporter detected — report widgets and drop patches enabled'
      else
        '[reporter_dashboards] redmine_reporter not installed — running standalone; ' \
        'dashboards, SQL aggregation and statistics are unaffected'
      end
    )

    # Register the Liquid tags FIRST and independently. Report templates depend on
    # {% sql_aggregate %} / {% geo_aggregate %}, so their registration must never be
    # skipped because an unrelated later step raised. Each register_* method rescues
    # its own errors. None of the four needs reporter.
    RedmineReporterDashboards.register_sql_aggregate_tag
    RedmineReporterDashboards.register_version_rollup_tag
    RedmineReporterDashboards.register_geo_version_map_tag
    RedmineReporterDashboards.register_chart_tag
    RedmineReporterDashboards.load_patches

    return unless reporter

    # T-20 removed a fourth step here — the prepend that added `issue.target_version`
    # and `issue.custom_field_value[…]` to the HOST plugin's issue drop. Both accessors
    # are now on this plugin's own drops. See RedmineReporterDashboards for the note.
    RedmineReporterDashboards.apply_reporter_patches
  end
end
