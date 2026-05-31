# frozen_string_literal: true

require 'redmine'

# ---------------------------------------------------------------------------
# Dependency check
#
# This plugin extends the third-party redmine_reporter (RedmineUP) plugin.
# redmine_reporter loads first (alphabetical plugin load order), so by the time
# this init.rb runs its registration is already available.
# ---------------------------------------------------------------------------
unless Redmine::Plugin.installed?(:redmine_reporter)
  raise "\n\033[31mredmine_reporter_dashboards requires the redmine_reporter plugin.\n" \
        "Please install redmine_reporter (version 2.0.5 or higher) before enabling " \
        "redmine_reporter_dashboards.\033[0m"
end

if Rails.configuration.respond_to?(:autoloader) && Rails.configuration.autoloader == :zeitwerk
  Rails.autoloaders.each { |loader| loader.ignore(File.dirname(__FILE__) + '/lib') }
end
require File.dirname(__FILE__) + '/lib/redmine_reporter_dashboards'

Redmine::Plugin.register :redmine_reporter_dashboards do
  name 'Redmine Reporter Dashboards plugin'
  author 'Jan Catrysse'
  description 'Dashboard extension for the Redmine Reporter plugin, adding project dashboards, ' \
              'SQL-based issue statistics and Liquid aggregation tags.'
  version '0.1.0'
  url 'https://github.com/jcatrysse/redmine_reporter_dashboards'
  author_url 'https://github.com/jcatrysse'

  requires_redmine version_or_higher: '5.0'
  requires_redmine_plugin :redmine_reporter, version_or_higher: '2.0.5'

  project_module :reporter_project_dashboards do
    permission :view_reporter_project_page, { reporter_project_pages: [:show] }, read: true
    permission :manage_reporter_project_page, {
      reporter_project_pages: [:update_page, :add_block, :remove_block, :order_blocks]
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
    RedmineReporterDashboards.load_patches
    RedmineReporterDashboards.register_sql_aggregate_tag
    RedmineReporterDashboards.apply_reporter_patches
  end
end
