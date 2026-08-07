# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
# `Object#stub` is Minitest::Mock's, and Redmine's test_helper does not load it.
# Needed by the §7 rule 5 examples, which have to take a column AWAY to prove the
# guard degrades rather than raises.
require 'minitest/mock'

# T-22 — schedules, runs, recipients and documents, against a real database.
#
# The example that matters most in this file is
# `test_a_second_claim_for_the_same_occurrence_is_refused_by_the_database`. FR-39 puts the
# scheduler's at-most-once guarantee on a database constraint "not only by application
# logic", and the only way to know a constraint enforces anything is to violate it.
class ReporterDashboardsScheduleTest < ActiveSupport::TestCase
  fixtures :projects, :users

  Template = RedmineReporterDashboards::Template
  Schedule = RedmineReporterDashboards::Schedule
  ScheduleRun = RedmineReporterDashboards::ScheduleRun
  ScheduleRecipient = RedmineReporterDashboards::ScheduleRecipient
  Document = RedmineReporterDashboards::Document
  TemplateVersion = RedmineReporterDashboards::TemplateVersion

  # A pinned date, never Date.today: CLAUDE.md §6 forbids a fixture relative to the clock,
  # and an occurrence test that straddles midnight in the runner's timezone is exactly the
  # failure that gets a suite switched off.
  OCCURRENCE = Date.new(2026, 3, 17)

  def setup
    @project = Project.find(1)
    @author = User.find(2)
    @recipient = User.find(3)
    @template = Template.create!(project: @project, author_id: @author.id, name: 'Weekly')
    @schedule = Schedule.create!(project: @project, template_id: @template.id,
                                 author_id: @author.id, start_date: Date.new(2026, 1, 1))
  end

  # --- dates -----------------------------------------------------------------

  def test_the_four_schedule_dates_are_dates_and_not_datetimes
    # §7: "Reporter stores these dates as datetime while every comparison is date-based —
    # fixed." Asked of the live column type, so it is a fact about the database rather than
    # about the migration source.
    Schedule::DATE_COLUMNS.each do |name|
      assert_equal :date, Schedule.columns_hash.fetch(name).type, "#{name} should be a date"
    end
  end

  def test_a_date_column_round_trips_as_a_date_object
    @schedule.update!(next_run_on: OCCURRENCE)

    assert_instance_of Date, @schedule.reload.next_run_on
    assert_equal OCCURRENCE, @schedule.next_run_on
  end

  def test_an_end_date_before_the_start_date_is_refused
    @schedule.end_date = @schedule.start_date - 1

    assert_not @schedule.valid?
    assert_includes @schedule.errors.attribute_names, :end_date
  end

  def test_an_end_date_equal_to_the_start_date_is_allowed
    # The boundary, one either side: a single-occurrence schedule is legitimate.
    @schedule.end_date = @schedule.start_date

    assert @schedule.valid?
  end

  # --- the at-most-once claim ------------------------------------------------

  def test_a_first_claim_creates_the_run_row
    run = ScheduleRun.claim(@schedule, OCCURRENCE)

    assert run.persisted?
    assert_equal OCCURRENCE, run.occurrence_date
  end

  def test_a_second_claim_for_the_same_occurrence_is_refused_by_the_database
    ScheduleRun.claim(@schedule, OCCURRENCE)

    assert_no_difference 'RedmineReporterDashboards::ScheduleRun.count' do
      assert_nil ScheduleRun.claim(@schedule, OCCURRENCE)
    end
  end

  def test_a_refused_claim_leaves_the_surrounding_transaction_usable
    # MEASURED as a real defect before the savepoint was added: on PostgreSQL a failed
    # INSERT poisons the whole transaction, so the runner's per-schedule rescue
    # (technical-spec.md:1209) could not actually continue — the next statement raised
    # PG::InFailedSqlTransaction. Without `requires_new: true` this test dies on the line
    # after the duplicate.
    ScheduleRun.transaction do
      ScheduleRun.claim(@schedule, OCCURRENCE)
      assert_nil ScheduleRun.claim(@schedule, OCCURRENCE)

      assert_equal 1, ScheduleRun.where(schedule_id: @schedule.id, occurrence_date: OCCURRENCE).count
      assert ScheduleRun.claim(@schedule, OCCURRENCE + 1).persisted?
    end
  end

  def test_two_schedules_may_claim_the_same_date
    other = Schedule.create!(project: @project, template_id: @template.id, author_id: @author.id)

    assert ScheduleRun.claim(@schedule, OCCURRENCE).persisted?
    assert ScheduleRun.claim(other, OCCURRENCE).persisted?
  end

  def test_claim_accepts_a_bare_id_as_well_as_a_record
    assert ScheduleRun.claim(@schedule.id, OCCURRENCE).persisted?
    assert_nil ScheduleRun.claim(@schedule, OCCURRENCE)
  end

  def test_claim_does_not_swallow_an_error_that_is_not_a_duplicate
    # The rescue is narrow on purpose. A runner that read "the database is broken" as
    # "already claimed" would stop sending every report in the installation and report
    # success — which is the failure mode this whole plan is written against.
    #
    # Two layers, because they raise different classes and only rescuing RecordNotUnique
    # lets BOTH through: the model's own validation, and the database's NOT NULL.
    assert_raises(ActiveRecord::RecordInvalid) { ScheduleRun.claim(@schedule, nil) }

    assert_raises(ActiveRecord::NotNullViolation) do
      ScheduleRun.transaction(requires_new: true) do
        ScheduleRun.new(schedule_id: @schedule.id).save!(validate: false)
      end
    end
  end

  def test_deleting_a_schedule_deletes_its_runs_and_recipients
    ScheduleRun.claim(@schedule, OCCURRENCE)
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @recipient.id)

    assert_difference ['RedmineReporterDashboards::ScheduleRun.count',
                       'RedmineReporterDashboards::ScheduleRecipient.count'], -1 do
      @schedule.destroy
    end
  end

  # --- recipients ------------------------------------------------------------

  def test_a_recipient_is_a_redmine_user_and_the_table_can_hold_nothing_else
    # §7:1202 calls the free-text alternative "the exfiltration-and-spoofing-relay
    # finding". Asserted against the live column list, so adding the column back is a test
    # failure rather than a review comment somebody might not make.
    assert_equal %w[created_at id schedule_id user_id], ScheduleRecipient.column_names.sort
  end

  def test_no_table_this_plugin_owns_can_hold_a_mail_address
    forbidden = %w[to cc bcc from]
    offenders = [Template, TemplateVersion, Schedule, ScheduleRun, ScheduleRecipient, Document]
                .flat_map { |klass| (klass.column_names & forbidden).map { |c| "#{klass.table_name}.#{c}" } }

    assert_equal [], offenders
  end

  def test_the_same_person_cannot_be_added_to_one_schedule_twice
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @recipient.id)
    duplicate = ScheduleRecipient.new(schedule_id: @schedule.id, user_id: @recipient.id)

    assert_not duplicate.valid?
  end

  def test_the_duplicate_recipient_is_refused_by_the_index_as_well_as_the_validation
    # Two concurrent form submissions never both run the validation. The index is what
    # survives that, and the validation is what gives a form a readable message.
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @recipient.id)

    assert_raises(ActiveRecord::RecordNotUnique) do
      ScheduleRecipient.transaction(requires_new: true) do
        # `created_at` is stamped in a before_validation callback, which `validate: false`
        # skips — so it is supplied here. Without it the row trips the NOT NULL before it
        # ever reaches the unique index, and the test would pass for the wrong reason.
        ScheduleRecipient.new(schedule_id: @schedule.id, user_id: @recipient.id,
                              created_at: Time.zone.now).save!(validate: false)
      end
    end
  end

  def test_recipient_users_reads_through_to_the_user
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: @recipient.id)

    assert_equal [@recipient.id], @schedule.reload.recipient_users.map(&:id)
  end

  # --- render identity -------------------------------------------------------

  def test_render_as_user_is_required_when_the_policy_names_one
    @schedule.render_as = Schedule::RENDER_AS_USER

    assert_not @schedule.valid?, 'FR-45 requires the render identity to be stored, not inferred'
  end

  def test_render_as_author_needs_no_separate_identity
    @schedule.render_as = Schedule::RENDER_AS_AUTHOR

    assert @schedule.valid?
  end

  # --- run state -------------------------------------------------------------

  def test_consecutive_failures_starts_at_zero_rather_than_nil
    assert_equal 0, @schedule.consecutive_failures
  end

  def test_an_unknown_status_is_refused
    @schedule.last_status = 'probably fine'

    assert_not @schedule.valid?
  end

  def test_the_two_rule_five_columns_degrade_rather_than_raising_when_absent
    # The reader must DIFFER between the two states, or the example is vacuous: an earlier
    # version only asserted the stubbed-absent side, so deleting the guard from the reader
    # and returning the column directly still passed. Both sides are asserted, against a
    # value that is deliberately not the degraded one.
    @schedule.update!(next_run_on: OCCURRENCE, consecutive_failures: 3)

    assert Schedule.next_run_on_supported?
    assert_equal OCCURRENCE, @schedule.next_run_on_or_nil
    assert_equal 3, @schedule.consecutive_failures_or_zero

    RedmineReporterDashboards::Compat.stub(:column_present?, false) do
      assert_not Schedule.next_run_on_supported?
      assert_not Schedule.consecutive_failures_supported?
      assert_nil @schedule.next_run_on_or_nil, 'the guard is not consulted by the reader'
      assert_equal 0, @schedule.consecutive_failures_or_zero
    end
  end

  # --- template versions -----------------------------------------------------

  def test_a_version_is_stamped_with_a_digest_of_its_content
    version = TemplateVersion.create!(template_id: @template.id, content: 'hello')

    assert_equal Digest::SHA256.hexdigest('hello'), version.content_digest
  end

  def test_a_version_cannot_be_updated_once_written
    version = TemplateVersion.create!(template_id: @template.id, content: 'hello')

    assert_raises(ActiveRecord::ReadOnlyRecord) { version.update!(content: 'tampered') }
    assert_equal 'hello', version.reload.content
  end

  def test_a_version_has_no_updated_at_to_write
    assert_not_includes TemplateVersion.column_names, 'updated_at'
    assert_not_nil TemplateVersion.create!(template_id: @template.id, content: 'x').created_at
  end

  def test_versions_read_newest_first
    # Created in ASCENDING id order with DESCENDING timestamps, so the expected result is
    # the opposite of insertion order. Written the other way round — the obvious way — the
    # example passes whether the scope orders by `created_at` or by `id`, and would go on
    # passing if somebody deleted the `order` clause entirely on a database that happens to
    # return rows by primary key.
    newer = TemplateVersion.create!(template_id: @template.id, content: 'b',
                                    created_at: Time.zone.parse('2026-02-01 10:00'))
    older = TemplateVersion.create!(template_id: @template.id, content: 'a',
                                    created_at: Time.zone.parse('2026-01-01 10:00'))

    assert older.id > newer.id, 'the fixture must have ascending ids and descending times'
    assert_equal [newer.id, older.id], @template.reload.versions.map(&:id)
  end

  def test_the_id_tiebreak_orders_two_versions_written_in_the_same_instant
    # `order(created_at: :desc, id: :desc)`'s second key. Two rows sharing a timestamp is
    # not hypothetical — an import writes a whole history in one transaction — and without
    # the tiebreak the order is whatever the engine returns, which CLAUDE.md §6 forbids
    # relying on because the three engines do not agree.
    stamp = Time.zone.parse('2026-03-01 09:00')
    first = TemplateVersion.create!(template_id: @template.id, content: 'a', created_at: stamp)
    second = TemplateVersion.create!(template_id: @template.id, content: 'b', created_at: stamp)

    assert_equal [second.id, first.id], @template.reload.versions.map(&:id)
  end

  # --- documents -------------------------------------------------------------

  def test_a_document_without_an_expiry_is_refused
    # §7: "Persistence is opt-in with a mandatory TTL". A nullable expiry is the unmanaged
    # indefinite store the mandatory TTL exists to prevent.
    assert_not Document.new(template_id: @template.id).valid?
  end

  def test_the_database_refuses_an_immortal_document_even_without_the_validation
    assert_raises(ActiveRecord::NotNullViolation) do
      Document.new(template_id: @template.id).save!(validate: false)
    end
  end

  def test_expired_and_live_scopes_split_on_the_expiry
    travel_to(Time.zone.parse('2026-06-01 12:00')) do
      expired = Document.create!(template_id: @template.id, expires_at: 1.hour.ago)
      live = Document.create!(template_id: @template.id, expires_at: 1.hour.from_now)

      assert_equal [expired.id], Document.expired.pluck(:id)
      assert_equal [live.id], Document.live.pluck(:id)
    end
  end

  def test_a_document_expiring_exactly_now_is_expired
    # At the limit, and one past it — the boundary a purge task gets wrong.
    travel_to(Time.zone.parse('2026-06-01 12:00')) do
      document = Document.create!(template_id: @template.id, expires_at: Time.zone.now)

      assert document.expired?
      assert_equal [document.id], Document.expired.pluck(:id)
    end
  end

  def test_an_immortal_document_is_refused_and_a_bounded_one_is_not
    # "Persistence is opt-in with a mandatory TTL … bounded when on" (§7). Presence alone
    # gives the first half only: expires_at = 9999-12-31 satisfies a presence check, reports
    # expired? false for ever and is never collected. At the bound and one past it.
    travel_to(Time.zone.parse('2026-06-01 12:00')) do
      at_bound = Document.new(template_id: @template.id,
                              expires_at: Time.zone.now + Document::MAX_RETENTION)
      past = Document.new(template_id: @template.id,
                          expires_at: Time.zone.now + Document::MAX_RETENTION + 1)
      immortal = Document.new(template_id: @template.id, expires_at: Time.zone.parse('9999-12-31'))

      assert at_bound.valid?
      assert_not past.valid?
      assert_not immortal.valid?
    end
  end

  def test_a_version_written_with_validate_false_still_gets_its_created_at
    # created_at is NOT NULL and used to be stamped in a before_validation callback, so
    # save(validate: false) — a Redmine idiom — hit the database constraint instead.
    version = TemplateVersion.new(template_id: @template.id, content: 'x')

    assert version.save(validate: false)
    assert_not_nil version.reload.created_at
  end

  def test_a_recipient_written_with_validate_false_still_gets_its_created_at
    recipient = ScheduleRecipient.new(schedule_id: @schedule.id, user_id: @recipient.id)

    assert recipient.save(validate: false)
    assert_not_nil recipient.reload.created_at
  end

  def test_a_nil_content_and_an_empty_content_get_different_digests
    # Otherwise the audit trail cannot tell "the author saved an empty template" from "no
    # content was recorded", which are two different events.
    empty = TemplateVersion.create!(template_id: @template.id, content: '')
    absent = TemplateVersion.create!(template_id: @template.id, content: nil)

    assert_not_nil empty.content_digest
    assert_nil absent.content_digest
  end

  def test_update_all_is_NOT_blocked_and_the_class_comment_says_so
    # Pinned as it is, rather than claimed away. `readonly?` closes every model-level write
    # path; `update_all` bypasses the model entirely, on every model in every Rails app. A
    # test that asserted the opposite would be a claim of tamper-proofing that a one-line
    # console command defeats.
    version = TemplateVersion.create!(template_id: @template.id, content: 'original')
    TemplateVersion.where(id: version.id).update_all(content: 'rewritten')

    assert_equal 'rewritten', version.reload.content
  end

  def test_destroy_IS_blocked_on_a_persisted_version_and_delete_all_still_works
    version = TemplateVersion.create!(template_id: @template.id, content: 'x')

    assert_raises(ActiveRecord::ReadOnlyRecord) { version.destroy }
    assert_difference 'RedmineReporterDashboards::TemplateVersion.count', -1 do
      @template.versions.delete_all
    end
  end

  def test_schedule_string_columns_are_length_validated
    at_limit = 'x' * Schedule::MAX_STRING

    @schedule.email_subject = at_limit
    assert @schedule.valid?

    @schedule.email_subject = "#{at_limit}x"
    assert_not @schedule.valid?
  end

  def test_a_purged_document_is_in_neither_scope
    travel_to(Time.zone.parse('2026-06-01 12:00')) do
      document = Document.create!(template_id: @template.id, expires_at: 1.hour.ago,
                                  purged_at: Time.zone.now)

      assert_equal [], Document.expired.pluck(:id)
      assert_equal [], Document.live.pluck(:id)
      assert document.purged?
    end
  end
end
