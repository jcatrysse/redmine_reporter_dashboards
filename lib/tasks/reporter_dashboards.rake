# frozen_string_literal: true

# T-02. Deliberately four lines of logic: the survey and the formatter are ordinary
# classes under lib/, so both are unit-testable, and a rake file that grew a method
# would be a place tests cannot reach.
#
# `import:plan` writes NOTHING. That is not a comment — spec/adapter/import_survey_spec.rb
# subscribes to sql.active_record and fails on any statement that is not a SELECT.
namespace :reporter_dashboards do
  namespace :migrate_from_reporter do
    desc 'Read-only survey of the redmine_reporter data this plugin would import (writes nothing)'
    task plan: :environment do
      # Absolute paths, the idiom lib/redmine_reporter_dashboards.rb already uses.
      # Required here rather than at boot: nothing in a page request needs them.
      require File.expand_path('../redmine_reporter_dashboards/import/survey', __dir__)
      require File.expand_path('../redmine_reporter_dashboards/import/plan_report', __dir__)

      result = RedmineReporterDashboards::Import::Survey.run
      puts RedmineReporterDashboards::Import::PlanReport.render(result)
    end

    # T-24. The write half. COPY-ONLY and FORWARD-ONLY — see `Import::Runner`, and
    # `technical-spec.md` §7's *Adopt vs copy*: adopting the base plugin's rows would mean
    # its own uninstall drops the tables this plugin is live on.
    #
    # `RRD_DRY_RUN=1` decides every outcome and writes nothing, which is what an operator
    # should run first. It is NOT the same thing as `import:plan`: plan surveys the source,
    # this says what a run would do to THIS side, divergence included.
    desc 'Copy redmine_reporter templates into this plugin (RRD_DRY_RUN=1 to decide ' \
         'without writing, RRD_PROJECTS=1,2 to limit, RRD_REWRITE=1 to take the ' \
         "source's version over local edits; exit 1 if any template was skipped)"
    task run: :environment do
      require File.expand_path('../redmine_reporter_dashboards/import/runner', __dir__)
      require File.expand_path('../redmine_reporter_dashboards/import/import_report', __dir__)

      # AN ADMINISTRATOR OWNS THE COPIES, and the task refuses rather than guessing. A rake
      # task runs as Anonymous, so without this every imported template would either fail
      # validation or land owned by nobody — and `author_id` is what `edit_own_…` reads.
      actor = RedmineReporterDashboards::Import::Runner.resolve_actor(ENV['RRD_ACTOR'])
      unless actor
        warn 'No administrator to own the imported templates. Set RRD_ACTOR to a login ' \
             'or user id, or create an administrator first.'
        exit 2
      end

      result = RedmineReporterDashboards::Import::Runner.call(
        actor: actor,
        dry_run: ENV['RRD_DRY_RUN'].to_s == '1',
        project_ids: ENV['RRD_PROJECTS']&.split(','),
        # RRD_REWRITE IS NOT A PLAIN OVERWRITE. The local content is written into the
        # template's version history before the source's is taken, so nothing is lost and
        # the edit can be rolled back to from the editor.
        rewrite: ENV['RRD_REWRITE'].to_s == '1'
      )
      puts RedmineReporterDashboards::Import::ImportReport.render(result)
      exit(result.failed? ? 1 : 0)
    end

    # T-24's "drift is visible rather than silent". Writes nothing, and deliberately reads
    # OUR templates rather than the source's, so it still answers after the base plugin has
    # been uninstalled — which is exactly when somebody asks what state the migration is in.
    desc 'Report which imported templates have drifted from their source (writes nothing)'
    task status: :environment do
      require File.expand_path('../redmine_reporter_dashboards/import/runner', __dir__)
      require File.expand_path('../redmine_reporter_dashboards/import/import_report', __dir__)

      result = RedmineReporterDashboards::Import::Runner.status
      puts RedmineReporterDashboards::Import::ImportReport.render(result, heading: 'Import status')
    end
  end

  # T-29 — the template exchange BUNDLE (FR-55/56/57, `technical-spec.md` §7b.2).
  #
  # --- THE NAMES, AND WHO MOVED (curator decision, 2026-08-09, §Findings S-22) ---
  #
  # §7b.2 specifies `import:plan` and `import:run` for the BUNDLE. Both names were taken
  # by a different feature — T-02/T-24's one-way migration off `redmine_reporter`, which
  # reads that plugin's TABLES rather than a file. Rake does not report such a collision:
  # it ENHANCES the task and runs both bodies in order (measured), so `rake -T` would have
  # listed one task with one description and two behaviours.
  #
  # T-29 first shipped the bundle under `import:`/`export:` and reported the clash. **The curator
  # chose the other resolution: the SPEC keeps its names and the migration importer moved**
  # to `migrate_from_reporter:{plan,run,status}`, which is longer and unmistakable — the
  # thing it reads is in its name. So:
  #
  #   reporter_dashboards:export:bundle              write a bundle from this install
  #   reporter_dashboards:migrate_from_reporter:plan                say what reading one would do
  #   reporter_dashboards:migrate_from_reporter:run                 do it
  #   reporter_dashboards:migrate_from_reporter:*    the one-way migration off the old plugin
  #
  # The export sits under `export:` rather than `import:` because that is what it does, and
  # because the pair then reads the way the operation actually works: you EXPORT on one
  # installation and IMPORT on another. `test/unit/exchange_rake_test.rb` pins all of it,
  # including that `import:*` is the BUNDLE now and `migrate_from_reporter:*` is the
  # migration, so the two cannot silently swap back.
  namespace :export do
    desc 'Write a template bundle to stdout, or to RRD_OUT (RRD_PROJECT=id|identifier ' \
         'limits it to one project; writes nothing to the database)'
    task bundle: :environment do
      require File.expand_path('../redmine_reporter_dashboards/exchange_tasks', __dir__)
      tasks = RedmineReporterDashboards::ExchangeTasks

      begin
        project = tasks.find_project(ENV['RRD_PROJECT'])
        templates = RedmineReporterDashboards::Template.where(project_id: project&.id)
                                                       .order(:name, :id)
        bytes = RedmineReporterDashboards::Reporting::Bundle.dump(
          templates,
          # THE CLOCK IS READ HERE AND NOWHERE ELSE ON THIS PATH. `Bundle.dump` takes the
          # timestamp as a required argument precisely so the only unpinned value in the
          # format is introduced at the edge, where no test runs.
          exported_at: Time.now.utc.iso8601,
          plugin_version: tasks.plugin_version
        )
      rescue RedmineReporterDashboards::ExchangeTasks::Refused => e
        # EXIT 2, NOT 1. "Your arguments were wrong" and "a template failed to import" are
        # different outcomes and a script has to be able to tell them apart; 1 is reserved
        # for the second below. Anything not typed `Refused` is a defect and keeps its
        # backtrace.
        warn e.message
        exit 2
      end

      if ENV['RRD_OUT'].present?
        File.binwrite(ENV['RRD_OUT'], bytes)
        warn "wrote #{bytes.bytesize} bytes to #{ENV['RRD_OUT']}"
      else
        # `$stdout.write`, not `puts`: the bundle already ends in exactly one newline, and
        # this is used as `rake … > bundle.json`, where a second one would change the bytes
        # FR-57 is a claim about.
        $stdout.write(bytes)
      end
    end
  end

  # THE BUNDLE'S IMPORT HALF, under the names §7b.2 specifies. See the note above the
  # `export:` namespace for who moved and why.
  namespace :import do
    desc 'Say what importing RRD_FILE would do, and write NOTHING ' \
         '(RRD_PROJECT=id|identifier, RRD_ON_CONFLICT=skip|rename|overwrite)'
    task plan: :environment do
      require File.expand_path('../redmine_reporter_dashboards/exchange_tasks', __dir__)

      begin
        report = RedmineReporterDashboards::ExchangeTasks.call(plan: true)
      rescue RedmineReporterDashboards::ExchangeTasks::Refused => e
        warn e.message
        exit 2
      end

      puts RedmineReporterDashboards::Reporting::BundleReport.render(
        report, heading: 'Template bundle — plan'
      )
      # A PLAN DOES NOT EXIT NON-ZERO FOR A SKIP, and does for a failure. Deciding that a
      # template will not be imported is the plan's JOB; being unable to decide is not.
      exit(report.failed? ? 1 : 0)
    end

    desc 'Import the template bundle in RRD_FILE, one transaction per template ' \
         '(RRD_PROJECT=id|identifier, RRD_ON_CONFLICT=skip|rename|overwrite, ' \
         'RRD_ACTOR=login|id; exit 1 if any template failed)'
    task run: :environment do
      require File.expand_path('../redmine_reporter_dashboards/exchange_tasks', __dir__)

      begin
        report = RedmineReporterDashboards::ExchangeTasks.call(plan: false)
      rescue RedmineReporterDashboards::ExchangeTasks::Refused => e
        warn e.message
        exit 2
      end

      puts RedmineReporterDashboards::Reporting::BundleReport.render(
        report, heading: 'Template bundle — apply'
      )
      exit(report.failed? ? 1 : 0)
    end
  end

  # T-25. FR-44's first half is that this contract is DOCUMENTED: the scheduler does not
  # run itself. Nothing inside Redmine wakes it — there is no daemon, no background worker
  # this plugin ships and no `after_initialize` timer — so a report is delivered exactly as
  # often as something outside calls `schedules:run`. The README carries the cron line; the
  # second half of FR-44 is `Scheduling::Heartbeat`, which is why a hand-run tick prints a
  # warning when it finds work that should already have happened.
  namespace :schedules do
    desc 'Deliver every scheduled report that is due today (exit 1 if any schedule ' \
         'failed; RRD_SCHEDULE=id, RRD_CATCH_UP=1, RRD_MAX_CATCHUP_DAYS=n)'
    task run: :environment do
      require File.expand_path('../redmine_reporter_dashboards/scheduling/run_command', __dir__)

      # THE ONLY CLOCK READ ON THE WHOLE PATH. `Occurrences`, `Runner`, `Heartbeat` and
      # `RunCommand` all take the answer as an argument; this line is where the question is
      # asked, and it is asked once so a tick that straddles midnight cannot disagree with
      # itself about what day it is.
      exit RedmineReporterDashboards::Scheduling::RunCommand.new(
        now: Time.zone.now,
        schedule_id: ENV['RRD_SCHEDULE'],
        catch_up: ENV['RRD_CATCH_UP'].to_s == '1',
        max_catchup_days: (ENV['RRD_MAX_CATCHUP_DAYS'] ||
          RedmineReporterDashboards::Scheduling::Occurrences::DEFAULT_MAX_CATCHUP_DAYS).to_i,
        logger: Rails.logger
      ).call
    end

    desc 'Report whether the scheduler is actually being invoked, and what is overdue ' \
         '(writes nothing; exit 1 if there is a warning)'
    task status: :environment do
      require File.expand_path('../redmine_reporter_dashboards/scheduling/heartbeat', __dir__)

      heartbeat = RedmineReporterDashboards::Scheduling::Heartbeat
      status = heartbeat.status(today: Time.zone.now.to_date)

      puts "enabled schedules: #{status.enabled_count}"
      puts "last attempt:      #{status.last_attempt_at || 'never'}"
      heartbeat.warnings(status).each { |warning| puts "  * #{warning}" }
      puts '  no warnings' unless status.warning?

      exit(status.warning? ? 1 : 0)
    end
  end

  # T-28 — THE PURGE TASK THE TTL HAS ALWAYS DEPENDED ON, AND UNTIL NOW DID NOT HAVE.
  #
  # `technical-spec.md` is explicit that persistence is *"opt-in with a mandatory
  # TTL **and a purge task**. That converts an unmanaged indefinite store into 'off by
  # default, bounded when on'."* T-22 built the TTL and the table; nothing ever wrote a row,
  # so the missing half cost nothing. T-28's snapshot store is the commit that makes rows
  # exist, so it is the commit that owes the other half — found by an independent review,
  # which measured `Document.expired.count=1` with no task in the tree able to collect it.
  #
  # Without this, `expires_at` was a column consulted by a validation and by nothing else.
  # An expired snapshot is now refused at the endpoint as well (`Document#servable?`), so
  # the two together are what "bounded when on" actually means: expired stops being SERVED
  # immediately, and stops OCCUPYING DISK when this runs.
  #
  # LIKE THE SCHEDULER, IT DOES NOT RUN ITSELF. That is documented rather than assumed —
  # see `schedules:status` for the same problem and the same answer.
  namespace :documents do
    desc 'Delete the stored bytes of every expired report snapshot (RRD_DRY_RUN=1 to see ' \
         'what would go; the rows are kept, stamped purged_at)'
    task purge: :environment do
      dry_run = ENV['RRD_DRY_RUN'].to_s == '1'
      # ONE CLOCK READ, for the same reason `schedules:run` reads it once: a purge that
      # straddled a second must not disagree with itself about which rows were expired.
      now = Time.zone.now
      expired = RedmineReporterDashboards::Document.expired(now).order(:id)

      count = 0
      bytes = 0
      expired.find_each do |document|
        bytes += document.byte_size.to_i
        count += 1
        puts "#{dry_run ? 'would purge' : 'purging'} document #{document.id} " \
             "(template #{document.template_id}, expired #{document.expires_at})"
        # `purge!` AND NOT `destroy`: the ROW IS KEPT. `purged_at` is the difference between
        # "a document existed here and was collected on this date" and "no document ever
        # existed", and an audit that cannot tell those apart is not one.
        document.purge!(now) unless dry_run
      end

      puts "#{dry_run ? 'would purge' : 'purged'} #{count} document(s), " \
           "#{bytes} byte(s) of stored report"
      puts 'nothing expired' if count.zero?
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
      require File.expand_path('../redmine_reporter_dashboards/render/preflight_command', __dir__)
      RedmineReporterDashboards::Render::PreflightCommand.load_engines!

      # The port `render/**` may not reach for itself: this is the one line that knows
      # Redmine has a Setting table. See PreflightCommand's note on mechanism E5.
      base_url = Setting.host_name.present? ? "#{Setting.protocol}://#{Setting.host_name}" : nil

      exit RedmineReporterDashboards::Render::PreflightCommand.new(
        engine_ids: ENV['RRD_ENGINE'],
        redmine_base_url: base_url,
        # FR-50. The engine this installation SELECTED is checked by the default run even
        # when it needs a service — choosing it is the decision the deferral was waiting for.
        selected_engine_id: RedmineReporterDashboards.render_engine_id(logger: Rails.logger),
        format: (ENV['RRD_FORMAT'] || 'text').to_sym,
        logger: Rails.logger
      ).call
    end
  end
end
