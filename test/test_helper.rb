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
# redmine_reporter's report template classes may not be loadable
#
# On Redmine 7.0 (Rails 8.1) merely REFERENCING IssueListReportTemplate raises,
# because redmine_reporter's ReportTemplate class body uses the keyword form of
# `enum`, which Rails deprecated in 7.2 and removed in 8.0:
#
#   ArgumentError: wrong number of arguments (given 0, expected 1..2)
#     plugins/redmine_reporter/app/models/report_template.rb:26:in '<class:ReportTemplate>'
#
# Rails 7.2:  def enum(name = nil, values = nil, **options)   # keyword form tolerated
# Rails 8.1:  def enum(name, values = nil, **options)         # name is required
#
# That is a dependency problem, not one of this plugin's, and it is not something a
# test here can work around: the class cannot be loaded at all, so the report widgets
# do not work on that Redmine either. What the tests CAN do is say so once, clearly,
# instead of reporting the same ArgumentError from every test that happens to touch a
# report widget.
#
# Deliberately narrow: it only asks whether the constant resolves. If it does, the
# test runs as normal, so this can never hide a failure in our own code. And a skip
# is a skip — it is reported as such, not as a pass.
#
# The class list comes from `ReporterReportTemplates::CLASS_NAMES` rather than being
# spelled again here: two hardcoded lists of the same two classes are two things that
# must agree, and this one would go stale silently.
def reporter_report_template_load_error
  RedmineReporterDashboards::ReporterReportTemplates::CLASS_NAMES.each do |name|
    Object.const_get(name)
  end
  nil
rescue StandardError, ScriptError => e
  e
end

def skip_unless_reporter_report_templates_load
  error = reporter_report_template_load_error
  return if error.nil?

  # Two different reasons land here, and conflating them made the message wrong the
  # moment redmine_reporter became optional. Absence is now a NORMAL, supported
  # configuration; a load failure while it IS installed is a defect in reporter.
  unless RedmineReporterDashboards.reporter_present?
    skip 'redmine_reporter is not installed — the two report widgets are the only ' \
         'part of this plugin that needs it, so they are out of scope for this run. ' \
         'This is the standalone configuration, not a failure.'
  end

  skip "redmine_reporter is installed but its report template classes do not load on " \
       "Redmine #{Redmine::VERSION}: #{error.class}: #{error.message}. Reporter's " \
       'ReportTemplate uses the keyword form of `enum`, removed in Rails 8.0 — ' \
       'it needs `enum :name, values` instead. The report widgets are unavailable ' \
       'on this Redmine until that is fixed in reporter.'
end
