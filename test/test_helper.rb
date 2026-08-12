require File.expand_path(File.dirname(__FILE__) + '/../../../test/test_helper')

def redmine_reporter_dashboards_fixtures_directory
  Redmine::Plugin.find(:redmine_reporter_dashboards).directory + '/test/fixtures/'
end

def compatible_request(type, action, parameters = {})
  send(type, action, params: parameters)
end

def compatible_xhr_request(type, action, parameters = {})
  send(type, action, params: parameters, xhr: true)
end

# ---------------------------------------------------------------------------
# NOTHING IN THIS SUITE ASKS ABOUT redmine_reporter'S CLASSES ANY MORE (T-26a).
#
# `skip_unless_reporter_report_templates_load` and `reporter_report_template_load_error`
# lived here. They guarded the tests whose subject was a report widget, back when those
# resolved the base plugin's `IssueListReportTemplate` — undefined on a standalone install
# and unloadable on Redmine 7.0 even where the plugin IS installed, because its `enum` uses
# the keyword form Rails 8.0 removed.
#
# Both surfaces are this plugin's own now, so those tests run on every branch of the matrix
# instead of skipping on exactly the standalone configuration FR-01 is about, and the skip
# inventory (G10) shrank rather than being rewritten. `ReporterReportTemplates` — the module
# they read their class list from — went with them.
