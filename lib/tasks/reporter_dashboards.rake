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

  namespace :render do
    # T-14. Same shape as `import:plan` and for the same reason: the decisions —
    # which engines, what the exit code means, what happens when there are none —
    # are in `Render::PreflightCommand`, which has a spec. This is glue.
    #
    # It EXITS NON-ZERO when a check failed, so it can be a deploy step rather than
    # something an operator reads and interprets. `PreflightCommand` documents the
    # three codes; 2 ("nothing was verified") is deliberately not 0.
    desc 'Render a probe document through each engine and report what actually worked ' \
         '(exit 1 on failure, 2 if no engine is registered; RRD_ENGINE=id, RRD_FORMAT=json)'
    task preflight: :environment do
      engines_dir = File.expand_path('../redmine_reporter_dashboards/render/engines', __dir__)
      Dir[File.join(engines_dir, '*.rb')].sort.each { |path| require path }
      require File.expand_path('../redmine_reporter_dashboards/render/preflight_command', __dir__)

      # The port `render/**` may not reach for itself: this is the one line that knows
      # Redmine has a Setting table. See PreflightCommand's note on mechanism E5.
      base_url = Setting.host_name.present? ? "#{Setting.protocol}://#{Setting.host_name}" : nil

      exit RedmineReporterDashboards::Render::PreflightCommand.new(
        engine_ids: ENV['RRD_ENGINE'],
        redmine_base_url: base_url,
        format: (ENV['RRD_FORMAT'] || 'text').to_sym,
        logger: Rails.logger
      ).call
    end
  end
end
