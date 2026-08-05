# frozen_string_literal: true

# T-02. Deliberately four lines of logic: the survey and the formatter are ordinary
# classes under lib/, so both are unit-testable, and a rake file that grew a method
# would be a place tests cannot reach.
#
# `import:plan` writes NOTHING. That is not a comment — spec/adapter/import_survey_spec.rb
# subscribes to sql.active_record and fails on any statement that is not a SELECT.
namespace :reporter_dashboards do
  namespace :import do
    desc 'Read-only survey of the redmine_reporter data this plugin would import (writes nothing)'
    task plan: :environment do
      # Absolute paths, the idiom lib/redmine_reporter_dashboards.rb already uses.
      # Required here rather than at boot: nothing in a page request needs them.
      require File.expand_path('../redmine_reporter_dashboards/import/survey', __dir__)
      require File.expand_path('../redmine_reporter_dashboards/import/plan_report', __dir__)

      result = RedmineReporterDashboards::Import::Survey.run
      puts RedmineReporterDashboards::Import::PlanReport.render(result)
    end
  end
end
