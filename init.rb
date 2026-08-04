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

  project_module :reporter_project_dashboards do
    permission :view_reporter_project_page, { reporter_project_pages: [:show, :report_pdf] }, read: true
    permission :manage_reporter_project_page, {
      reporter_project_pages: [:update_page, :add_block, :remove_block, :move_block]
    }
    permission :manage_reporter_project_tabs, {
      reporter_project_tabs: [:create, :update, :destroy, :order]
    }
  end

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
    # its own errors. None of the three needs reporter.
    RedmineReporterDashboards.register_sql_aggregate_tag
    RedmineReporterDashboards.register_version_rollup_tag
    RedmineReporterDashboards.register_geo_version_map_tag
    RedmineReporterDashboards.load_patches

    return unless reporter

    RedmineReporterDashboards.register_issue_target_version_drop
    RedmineReporterDashboards.apply_reporter_patches
  end
end
