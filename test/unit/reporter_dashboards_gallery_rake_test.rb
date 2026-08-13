# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'rake'
require 'stringio'

# T-37 / FR-73 — `rake reporter_dashboards:gallery:verify`, THE WIRING AND THE REFUSALS.
#
# --- WHAT THIS FILE DELIBERATELY DOES NOT DO ---
#
# It does not render. A render needs a real engine, and the minitest job has none — no
# browser, no Gotenberg container, no wkhtmltopdf. A test that tried would be a test that
# passes on one developer's machine and skips on CI, which is worse than no test because the
# skip is invisible in a green run.
#
# The RENDER half is measured by running the task in an environment that HAS all three
# engines, and its result is recorded in the T-37 status row: **15 of 15 — five starters on
# chromium_cdp, gotenberg 8.35.0 and wkhtmltopdf 0.12.6.1 (patched qt)**. What is left for a
# test is everything that decides whether the task can be trusted to say that: the name, the
# description, and the four refusals it must make BEFORE any engine is asked.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. The `private` here is at the
# bottom and holds only `capture_task`.
class ReporterDashboardsGalleryRakeTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  TASK = 'reporter_dashboards:gallery:verify'
  RAKE_FILE = File.expand_path('../../lib/tasks/reporter_dashboards.rake', __dir__)

  def setup
    @previous = Rake.application
    @previous_metadata = Rake::TaskManager.record_task_metadata
    Rake.application = Rake::Application.new
    Rake::TaskManager.record_task_metadata = true
    Rake::Task.define_task(:environment)
    load RAKE_FILE

    ENV['RRD_PROJECT'] = Project.find(1).identifier
    ENV['RRD_ACTOR'] = User.find_by!(admin: true).login
    ENV.delete('RRD_THUMBNAILS')
  end

  def teardown
    Rake.application = @previous
    Rake::TaskManager.record_task_metadata = @previous_metadata
    %w[RRD_PROJECT RRD_ACTOR RRD_THUMBNAILS].each { |key| ENV.delete(key) }
  end

  def test_the_task_is_defined_and_describes_itself
    assert Rake::Task.task_defined?(TASK), "#{TASK} is not defined by #{RAKE_FILE}"

    description = Rake::Task[TASK].comment
    assert_not_nil description, 'the task has no desc, so it is invisible in `rake -T`'
    assert_match(/every registered engine/i, description)
    assert_match(/writes no template/i, description)
    assert_match(/exit 1/i, description)
  end

  # EXIT 2 AND NOT 0. The same decision `render:preflight` takes and for the same reason:
  # nothing was registered, so nothing was verified, and a zero here would be a green run
  # claiming five starters work on engines that were never asked.
  def test_no_registered_engine_exits_two_rather_than_reporting_success
    error = nil
    RedmineReporterDashboards::Render::Registry.isolated do
      error = assert_raises(SystemExit) { capture_task }
    end

    assert_equal 2, error.status
    assert_match(/no render engine is registered/, @err)
  end

  # A GALLERY VERIFIED OVER AN EMPTY SCOPE PROVES NOTHING, so the project is required rather
  # than defaulted: `ReportScope` over every project would be a different claim, and over
  # none would render five empty documents and call them a pass.
  def test_a_missing_project_exits_two
    ENV.delete('RRD_PROJECT')

    error = assert_raises(SystemExit) { capture_task }

    assert_equal 2, error.status
    assert_match(/RRD_PROJECT is required/, @err)
  end

  def test_an_unknown_project_exits_two
    ENV['RRD_PROJECT'] = 'no-such-project'

    error = assert_raises(SystemExit) { capture_task }

    assert_equal 2, error.status
    assert_match(/no project matches/, @err)
  end

  # INV-1 — a rake task has no ambient actor. Rendering as Anonymous would read Anonymous's
  # visible scope, which on a private project is nothing at all: five empty documents,
  # reported as five passes.
  def test_an_unknown_actor_exits_two
    ENV['RRD_ACTOR'] = 'nobody-with-this-login'

    error = assert_raises(SystemExit) { capture_task }

    assert_equal 2, error.status
  end

  # ------------------------------------------------------------------ INV-6, no writes
  #
  # `GalleryCheck`'s header claims it writes nothing, and a claim in a comment is not a
  # control. The check is over the STATEMENTS rather than the row counts, because a row that
  # still looks right proves the run did not happen to change it and not that it could not —
  # the same reason `import:plan`'s no-write assertion is written this way.
  #
  # THE HTML BINDING, because that is the half that touches the database: the Liquid render,
  # the aggregations and every drop read. The PDF half hands bytes to an engine and touches no
  # model at all — and it is not stubbed here, because a stub adapter is a fourth engine whose
  # only property is that it agrees with this test. The whole path (five starters through a
  # real wkhtmltopdf, statements subscribed) was measured at **0 non-read statements, 0 new
  # Template / Document / Attachment rows** and is recorded in the T-37 status row.
  def test_rendering_every_starter_writes_nothing_to_the_database
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      payload = ActiveSupport::Notifications::Event.new(*args).payload
      next if payload[:cached]
      next if %w[SCHEMA TRANSACTION].include?(payload[:name].to_s)

      statements << payload[:sql].to_s
    end

    actor = User.find_by!(admin: true)
    project = Project.find(1)
    rendered = RedmineReporterDashboards::StarterGallery.entries.map do |entry|
      template = RedmineReporterDashboards::Template.new(
        project_id: project.id, author_id: actor.id, name: entry.id,
        source: entry.source, output: entry.output,
        content: RedmineReporterDashboards::StarterGallery.body(entry),
        visibility: RedmineReporterDashboards::Template::VISIBILITY_PRIVATE
      )
      scope, query = RedmineReporterDashboards::Reporting::ReportScope.build(
        template: template, actor: actor, project: project, query_id: nil
      )
      RedmineReporterDashboards::Reporting::ReportRun.preview(
        template: template, actor: actor, scope: scope, query: query,
        guard: RedmineReporterDashboards::Render::BatchGuard.new
      ).call(pdf: false)
    end

    # THE RENDERS HAVE TO HAVE HAPPENED, or "wrote nothing" is also true of doing nothing —
    # and a Liquid error would be a diagnostic rather than a raise, so it has to be asked for.
    assert_equal 5, rendered.length
    rendered.each_with_index do |outcome, index|
      id = RedmineReporterDashboards::StarterGallery.entries[index].id
      assert_nil outcome.diagnostic, "#{id}: #{outcome.diagnostic&.message}"
      assert outcome.sections.any?, "#{id} produced no HTML at all"
    end

    offenders = statements.reject do |sql|
      sql.match?(/\A\s*(?:SELECT|SHOW|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i)
    end
    assert_equal [], offenders,
                 "rendering the gallery must write nothing. Not a read:\n#{offenders.join("\n")}"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # EVERY STARTER RENDERS ITS LIQUID on this Redmine, which is the part of FR-73's "renders on
  # every engine" that a four-branch CI job can actually answer: a tag that does not exist, a
  # parameter that is refused or a filter that was removed is a diagnostic or a degradation
  # here, on every supported Redmine, without a browser anywhere near it.
  #
  # It is deliberately NOT a second copy of the assertion above: that one is about writes, this
  # one is about degradations, and a starter that renders while quietly losing its chart is the
  # failure this one exists for.
  def test_every_starter_renders_without_a_degradation
    actor = User.find_by!(admin: true)
    project = Project.find(1)

    RedmineReporterDashboards::StarterGallery.entries.each do |entry|
      template = RedmineReporterDashboards::Template.new(
        project_id: project.id, author_id: actor.id, name: entry.id,
        source: entry.source, output: entry.output,
        content: RedmineReporterDashboards::StarterGallery.body(entry),
        visibility: RedmineReporterDashboards::Template::VISIBILITY_PRIVATE
      )
      scope, query = RedmineReporterDashboards::Reporting::ReportScope.build(
        template: template, actor: actor, project: project, query_id: nil
      )
      outcome = RedmineReporterDashboards::Reporting::ReportRun.preview(
        template: template, actor: actor, scope: scope, query: query,
        guard: RedmineReporterDashboards::Render::BatchGuard.new
      ).call(pdf: false)

      codes = outcome.degradations.map { |d| RedmineReporterDashboards::DegradationText.code_of(d) }
      assert_equal [], codes, "#{entry.id} degraded: #{codes.join(', ')}"
    end
  end

  private

  # Rake prints its report to stdout and its refusals to stderr, and the refusals are what
  # this file asserts — so both are captured, and `@err` survives a task that EXITED.
  def capture_task
    previous_out = $stdout
    previous_err = $stderr
    out = StringIO.new
    err = StringIO.new
    $stdout = out
    $stderr = err
    Rake::Task[TASK].reenable
    Rake::Task[TASK].invoke
  ensure
    @out = out.string
    @err = err.string
    $stdout = previous_out
    $stderr = previous_err
  end
end
