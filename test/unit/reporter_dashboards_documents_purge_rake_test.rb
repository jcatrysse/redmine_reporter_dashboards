# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'rake'
require 'stringio'

# T-28 — THE PURGE TASK, WHICH THE TTL HAS ALWAYS DEPENDED ON AND DID NOT HAVE.
#
# --- WHY THIS FILE EXISTS ---
#
# `technical-spec.md:1222-1223` requires persistence to be *"opt-in with a mandatory TTL
# **and a purge task**"*, and until T-28 nothing ever wrote a document row, so the missing
# half cost nothing. The snapshot store is the change that makes rows exist, so it is the
# change that owes the other half — found by an independent review, which measured
# `Document.expired.count=1` with no task in the tree able to collect it and `rg purge
# lib/tasks` empty.
#
# --- WHY IT IS TESTED THROUGH RAKE RATHER THAN THROUGH THE MODEL ---
#
# `Document#purge!` is covered by the snapshot test. What no other test can reach is the
# GLUE — a typo in the namespace, a `desc` missing so the task is invisible in `rake -T`,
# an env var read wrongly, or the whole task file failing to load. Every one of those
# produces a green suite and an operator's cron entry that silently does nothing, which is
# precisely the failure mode a purge task has: nobody watches it, and its success and its
# absence look identical from outside.
#
# The same shape and the same reason as `render_preflight_rake_test.rb`.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. There is none here.
class ReporterDashboardsDocumentsPurgeRakeTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  TASK = 'reporter_dashboards:documents:purge'
  RAKE_FILE = File.expand_path('../../lib/tasks/reporter_dashboards.rake', __dir__).freeze

  Snapshot = RedmineReporterDashboards::Reporting::Snapshot
  Document = RedmineReporterDashboards::Document
  Template = RedmineReporterDashboards::Template

  PDF_BYTES = "%PDF-1.4\n#{'0' * 2_000}\n%%EOF"

  class FakeEngine
    def capabilities
      []
    end

    def id
      'fake'
    end

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(bytes: PDF_BYTES, engine: 'fake',
                                                     engine_version: '1.0')
    end
  end

  def setup
    ENV.delete('RRD_DRY_RUN')
    @previous = Rake.application
    @previous_metadata = Rake::TaskManager.record_task_metadata
    Rake.application = Rake::Application.new
    # Descriptions are DISCARDED unless this is on — rake records them only when it is about
    # to show them, so a `desc` assertion reads nil however correct the task file is.
    Rake::TaskManager.record_task_metadata = true
    Rake::Task.define_task(:environment)
    load RAKE_FILE

    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @jsmith = User.find_by!(login: 'jsmith')
    Role.find(1).tap do |role|
      role.permissions = %w[view_issues view_reporter_dashboards_reports]
      role.save!
    end
    @template = Template.create!(project: @project, author: @jsmith, name: 'Purged',
                                 content: '<p>x</p>', source: 'issues', output: 'combined')
  end

  def teardown
    Rake.application = @previous
    Rake::TaskManager.record_task_metadata = @previous_metadata
    ENV.delete('RRD_DRY_RUN')
    User.current = nil
  end

  # ------------------------------------------------------------------ helpers

  def capture_snapshot(expires_at: 30.days.from_now)
    result = RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, FakeEngine)
      Snapshot.capture(template: @template, render_as: @jsmith, project: @project,
                       created_by: @jsmith, expires_at: expires_at)
    end
    raise "could not capture: #{result.code} #{result.message}" unless result.ok?

    result.document
  end

  def expired_snapshot
    document = capture_snapshot(expires_at: 1.hour.from_now)
    document.update_columns(expires_at: 1.hour.ago)
    document.reload
  end

  # `Rake::Task#invoke` runs once per application, so the task is re-enabled each time.
  # Answers the task's stdout.
  def run_task
    out = StringIO.new
    previous = $stdout
    $stdout = out
    Rake::Task[TASK].reenable
    Rake::Task[TASK].invoke
    out.string
  ensure
    $stdout = previous
  end

  # ------------------------------------------------------------------ the wiring

  def test_the_task_is_defined_under_the_documented_name
    assert Rake::Task.task_defined?(TASK), "#{TASK} is not defined by #{RAKE_FILE}"
  end

  def test_the_task_describes_itself_for_rake_dash_t
    description = Rake::Task[TASK].comment

    assert_not_nil description, 'the task has no desc, so it is invisible in `rake -T`'
    assert_match(/purge|expired/i, description)
  end

  # ------------------------------------------------------------------ what it collects

  def test_it_deletes_the_bytes_of_an_expired_snapshot_and_keeps_the_row
    document = expired_snapshot
    attachment_id = document.attachment_id

    assert_difference '::Attachment.count', -1 do
      run_task
    end

    assert Document.exists?(document.id), 'the audit row was destroyed rather than stamped'
    assert document.reload.purged?
    assert_not ::Attachment.exists?(attachment_id)
  end

  # THE CONTROL, and without it the test above passes against a task that deletes
  # everything. A live snapshot must survive its own purge task — that is the whole
  # difference between a TTL and a cleanup.
  def test_it_leaves_a_live_snapshot_completely_alone
    live = capture_snapshot(expires_at: 30.days.from_now)

    assert_no_difference '::Attachment.count' do
      run_task
    end

    assert_not live.reload.purged?
    assert_not_nil live.bytes
  end

  def test_it_says_so_when_there_is_nothing_to_collect
    capture_snapshot(expires_at: 30.days.from_now)

    assert_match(/nothing expired/, run_task)
  end

  # ------------------------------------------------------------------ the dry run

  # A DESTRUCTIVE TASK NEEDS A WAY TO ASK FIRST, and the plugin's other destructive task
  # (`import:run`) uses the same `RRD_DRY_RUN` name. Asserted on the DATA rather than on the
  # wording, because a dry run that prints "would purge" and purges anyway is exactly the
  # failure this guard exists to prevent.
  def test_a_dry_run_reports_what_would_go_and_removes_nothing
    document = expired_snapshot
    ENV['RRD_DRY_RUN'] = '1'

    output = nil
    assert_no_difference '::Attachment.count' do
      output = run_task
    end

    assert_match(/would purge/, output)
    assert_not document.reload.purged?
    # THE ATTACHMENT, NOT `#bytes`. An expired document answers `bytes = nil` whether or not
    # it has been purged — that is the point of `servable?`, and asserting on it here would
    # have made this test pass against a dry run that deleted the file. The row and the file
    # on disk are what "removes nothing" actually means.
    assert_not_nil document.attachment_id
    assert ::Attachment.exists?(document.attachment_id)
    assert ::Attachment.find(document.attachment_id).readable?,
           'the dry run deleted the file from disk'
  end

  def test_the_task_names_each_document_it_touches
    document = expired_snapshot

    output = run_task

    assert_match(/document #{document.id}/, output)
  end

  # ------------------------------------------------------------------ idempotence

  # A CRON ENTRY RUNS FOREVER, so running twice must be as safe as running once — and the
  # second run must not re-stamp `purged_at`, which is the one fact the column carries.
  def test_running_it_twice_collects_nothing_the_second_time
    document = expired_snapshot
    run_task
    first = document.reload.purged_at

    assert_no_difference '::Attachment.count' do
      run_task
    end

    assert_equal first, document.reload.purged_at
  end
end
