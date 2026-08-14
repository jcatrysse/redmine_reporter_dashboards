# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-25 — the delivery, end to end, against a real Redmine and a real ActionMailer.
#
# `reporter_dashboards_schedule_runner_test.rb` drives the tick with a FAKE delivery, so
# nothing there ever renders or mails. This is the other half, and it has to be a
# full-application test for two reasons that no double reproduces: `Mailer#process` sets
# `User.current` and `I18n.locale` per recipient (which is what makes nine locale files
# mean anything), and `IssueQuery#statement` reads `User.current` — so whether the scope is
# built as the right person is a fact about a booted Redmine, not about this class.
#
# Rendering to PDF needs a browser this container may not have, so the engine is injected
# where a document is needed. Which documents come out is `ReportRun`'s subject and is
# covered there; what this file is about is who gets them, who does not, and what the
# owner is told when nothing can be produced.
class ReporterDashboardsScheduledDeliveryTest < ActiveSupport::TestCase
  fixtures :projects, :users, :members, :member_roles, :roles, :issues, :issue_statuses,
           :trackers, :enabled_modules, :projects_trackers, :enumerations, :queries,
           :time_entries

  Template = RedmineReporterDashboards::Template
  Schedule = RedmineReporterDashboards::Schedule
  ScheduleRun = RedmineReporterDashboards::ScheduleRun
  ScheduleRecipient = RedmineReporterDashboards::ScheduleRecipient
  Delivery = RedmineReporterDashboards::Reporting::ScheduledDelivery
  Diagnostic = RedmineReporterDashboards::Reporting::Diagnostic

  OCCURRENCE = Date.new(2026, 3, 10)

  # A mailer double that records rather than sends, for the examples that are about WHO is
  # mailed and WHAT they are handed. The examples about the message itself use the real one.
  class RecordingMailer
    attr_reader :reports, :failures

    def initialize(raising: false)
      @reports = []
      @failures = []
      @raising = raising
    end

    def deliver_scheduled_report(user, schedule, date, attachments, rendered_as, cid)
      raise Net::SMTPFatalError, 'the relay refused it' if @raising

      @reports << { user: user, schedule: schedule, date: date, attachments: attachments,
                    rendered_as: rendered_as, correlation_id: cid }
    end

    def deliver_scheduled_report_failure(user, schedule, date, diagnostic)
      @failures << { user: user, schedule: schedule, date: date, diagnostic: diagnostic }
    end
  end

  # A render engine that answers bytes without a browser.
  #
  # `Renderer` VERIFIES what an adapter hands back — `%PDF-` magic, a `%%EOF` trailer, and
  # more than 1 KiB — so a fake that answers `"pdf"` gets a `Failure(:output_not_pdf)` and
  # every example downstream of it fails for a reason that has nothing to do with its
  # subject. `.pdf_of` builds bytes that clear all three post-conditions, which is what
  # makes the size-cap examples below say what they claim to.
  class FakeEngine
    CAPABILITIES = RedmineReporterDashboards::Render::Capabilities::ALL

    class << self
      attr_writer :bytes

      def bytes
        @bytes ||= pdf_of(2_048)
      end

      # A byte string a Renderer will accept, of exactly `size` bytes.
      def pdf_of(size)
        head = "%PDF-1.4\n"
        tail = "\n%%EOF\n"
        filler = size - head.bytesize - tail.bytesize
        raise ArgumentError, 'too small to be a PDF' if filler.negative?

        "#{head}#{'x' * filler}#{tail}"
      end
    end

    def id
      :fake
    end

    def version
      '1.0'
    end

    def capabilities
      CAPABILITIES
    end

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: self.class.bytes, engine: :fake, engine_version: '1.0', page_count: 1,
        duration_ms: 1
      )
    end
  end

  # THE SAME ENGINE, BUT IT KEEPS WHAT IT WAS HANDED. `FakeEngine` answers canned bytes, so
  # the attachment cannot show what the template actually rendered — the first version of the
  # T-31 examples below asserted against the attachment and read half a kilobyte of `xxxx`.
  # The claim those examples make is about the HTML that reached the engine, so that is what
  # is recorded.
  class BodyRecordingEngine < FakeEngine
    class << self
      def bodies
        @bodies ||= []
      end

      def reset!
        @bodies = []
      end
    end

    def render(request)
      self.class.bodies << request.body
      super
    end
  end

  def setup
    @project = Project.find(1)
    @author = User.find(2)
    @recipient = User.find(3)
    @template = Template.create!(project: @project, author_id: @author.id,
                                 name: 'Weekly numbers',
                                 content: '<p>{{ issues.size }} issues</p>')
    @schedule = Schedule.create!(project: @project, template_id: @template.id,
                                 author_id: @author.id, repeat: 'daily',
                                 start_date: Date.new(2026, 1, 1))
    @run = ScheduleRun.claim(@schedule, OCCURRENCE, correlation_id: 'cid-1',
                                                    status: ScheduleRun::STATUS_RUNNING)
    @mailer = RecordingMailer.new
    FakeEngine.bytes = FakeEngine.pdf_of(2_048)
    ActionMailer::Base.deliveries.clear
  end

  # The TEXT AND HTML parts, and not `parts.map(&:body)`. Once there is an attachment the
  # message is multipart/mixed, so `parts` is [multipart/alternative, application/pdf] and
  # joining their bodies gives you half a megabyte of PDF and none of the prose. The first
  # version of these examples asserted against that and failed for a reason that looked
  # like a missing translation.
  def mail_body(mail)
    [mail.text_part, mail.html_part].compact.map { |part| part.body.decoded }.join("\n")
  end

  def add_recipient(user)
    ScheduleRecipient.create!(schedule_id: @schedule.id, user_id: user.id)
  end

  def deliver(mailer: @mailer, actor: @author, schedule: @schedule, engine: FakeEngine)
    delivery = Delivery.new(mailer: mailer)
    with_engine(engine) do
      delivery.call(schedule: schedule, occurrence_date: OCCURRENCE, actor: actor, run: @run)
    end
  end

  # `ReportRun` resolves the engine through `Render::Registry` unless one is injected, and
  # `ScheduledDelivery` deliberately does not expose that seam — a schedule renders with the
  # configured engine or it does not render. So the REGISTRY is what a test replaces.
  def with_engine(engine)
    registry = RedmineReporterDashboards::Render::Registry
    registry.stubs(:ids).returns([:fake])
    registry.stubs(:registered?).returns(true)
    registry.stubs(:fetch).returns(engine)
    yield
  end

  # --- T-31 / §Findings S-13: the source the SCHEDULER renders ---------------------------
  #
  # THIS WAS A BLOCKER, and it is worth stating what it looked like rather than only that it
  # is fixed. `ScheduledDelivery` built `Issue.visible(actor)` for every schedule while
  # `TemplatesController` had learned to branch on `template.source`. An independent review
  # measured a `source: time_entries` schedule mailing `COUNT=[7]` — the issue count — where
  # the actor's visible entry count was 3, with `ok=true` and nobody told. Two callers
  # deciding one thing separately is what produced it; `Reporting::ReportScope` is the one
  # decision now, and these are the examples that would notice it splitting again.

  def test_a_scheduled_time_entry_report_counts_time_entries_and_not_issues
    add_recipient(@recipient)
    Role.find(1).update_columns(time_entries_visibility: 'all')
    @template.update_columns(source: 'time_entries',
                             content: 'COUNT=[{{ time_entries.size }}]')

    issues = Issue.visible(@author).where(project_id: @project.id).count
    entries = TimeEntry.visible(@author).where(project_id: @project.id).count
    assert issues != entries,
           "the fixture cannot tell the two apart (#{issues} vs #{entries}), so this proves nothing"

    BodyRecordingEngine.reset!
    result = deliver(engine: BodyRecordingEngine)

    assert result.ok?, "the render failed: #{result.error}"
    body = BodyRecordingEngine.bodies.join
    assert_include "COUNT=[#{entries}]", body
    assert_not_include "COUNT=[#{issues}]", body
  end

  # AND THE ISSUE PATH IS UNCHANGED. Without this the fix could be routing everything to
  # time entries and the example above would still pass.
  def test_a_scheduled_issue_report_still_counts_issues
    add_recipient(@recipient)
    @template.update_columns(content: 'COUNT=[{{ issues.size }}]')

    issues = Issue.visible(@author).where(project_id: @project.id).count
    BodyRecordingEngine.reset!
    result = deliver(engine: BodyRecordingEngine)

    assert result.ok?
    assert_include "COUNT=[#{issues}]", BodyRecordingEngine.bodies.join
  end

  # A SCHEDULE OVER A SOURCE THIS VERSION DOES NOT KNOW FAILS rather than mailing a report
  # about whichever table the code happened to reach for.
  def test_a_scheduled_unknown_source_fails_rather_than_mailing_anything
    add_recipient(@recipient)
    @template.update_columns(source: 'invoices')

    result = deliver

    assert_not result.ok?
    assert_empty @mailer.reports, 'a report went out for a source nothing can render'
  end

  # --- FR-42: one render, N recipients --------------------------------------------------

  def test_three_recipients_receive_the_same_bytes_from_one_render
    [@recipient, User.find(4), User.find(8)].each { |u| add_recipient(u) }

    result = deliver

    assert result.ok?, result.error
    assert_equal 3, @mailer.reports.length
    assert_equal 3, result.recipients_count
    assert_equal 1, result.document_count

    payloads = @mailer.reports.map { |r| r[:attachments].map(&:last) }.uniq
    assert_equal 1, payloads.length, 'FR-42: every recipient gets the bytes of one render'
  end

  def test_the_attachment_is_named_after_the_template_and_the_occurrence
    add_recipient(@recipient)

    deliver

    names = @mailer.reports.first[:attachments].map(&:first)
    assert_equal ['weekly-numbers-2026-03-10.pdf'], names
  end

  def test_a_template_name_with_no_latin_characters_still_produces_a_usable_filename
    # `parameterize` reduces to [a-z0-9-], which empties a Cyrillic or Chinese name — and
    # an attachment called ".pdf" is one an operator cannot tell apart from any other.
    @template.update_columns(name: 'Еженедельный отчёт')
    add_recipient(@recipient)

    deliver

    name = @mailer.reports.first[:attachments].first.first
    assert_equal "report-#{@schedule.id}-2026-03-10.pdf", name
  end

  # --- FR-43: a failure never reaches a recipient ----------------------------------------

  def test_a_render_failure_notifies_the_owner_only_and_attaches_nothing
    add_recipient(@recipient)
    @template.update_columns(content: '{% this is not a tag %}')

    result = deliver

    assert_not result.ok?
    assert_empty @mailer.reports, 'INV-5: recipients never receive a failure'
    assert_equal 1, @mailer.failures.length
    notice = @mailer.failures.first
    assert_equal @author, notice[:user], 'the owner is the one person who can act'
    assert_not_nil notice[:diagnostic].correlation_id
    assert_equal 0, result.recipients_count
  end

  def test_a_failure_notice_carries_no_attachment_argument_at_all
    # Not "an empty attachment list" — the method has nowhere to put one. The strongest
    # form of FR-43 available: a failure cannot carry a document because the signature
    # cannot express one.
    parameters = ReporterDashboardsMailer.instance_method(:scheduled_report_failure)
                                         .parameters.map(&:last)

    assert_equal %i[user schedule occurrence_date diagnostic], parameters
  end

  def test_a_schedule_with_no_recipients_does_not_render_at_all
    # Rendering a PDF nobody receives is waste, and a silent one. The operator is told.
    result = deliver

    assert_not result.ok?
    assert_includes result.error, 'no active recipient'
    assert_empty @mailer.reports
    assert_equal 1, @mailer.failures.length
  end

  def test_a_locked_recipient_is_dropped_rather_than_mailed
    # The same departed employee the runner refuses to render AS. Mailing them their old
    # team's numbers is the same leak from the other end. Fixture user 5 is locked.
    locked = User.find(5)
    assert_not locked.active?, 'fixture precondition'
    add_recipient(locked)
    add_recipient(@recipient)

    result = deliver

    assert_equal 1, result.recipients_count
    assert_equal [@recipient], @mailer.reports.map { |r| r[:user] }
  end

  def test_a_schedule_whose_only_recipient_is_locked_refuses_rather_than_mailing_nobody
    add_recipient(User.find(5))

    result = deliver

    assert_not result.ok?
    assert_includes result.error, 'no active recipient'
  end

  def test_the_owner_notice_quotes_the_id_the_run_row_and_the_log_carry
    # FR-58: the id in the notice is the id an operator searches for. Every diagnostic out
    # of `ReportRun` mints its OWN uuid, so the first version told the owner something that
    # matched nothing — run row `3a8cd94c…`, owner mail `23688ef7…`. The previous assertion
    # here was `assert_not_nil`, which `SecureRandom.uuid` can never fail.
    add_recipient(@recipient)
    @template.update_columns(content: '{% this is not a tag %}')

    result = deliver

    assert_equal @run.correlation_id, @mailer.failures.first[:diagnostic].correlation_id
    assert_equal @run.correlation_id, result.correlation_id
  end

  def test_a_per_record_report_over_no_issues_sends_nothing_rather_than_an_empty_envelope
    # `documents: []` with no diagnostic is a SUCCESSFUL outcome — the template is fine and
    # the scope is empty. The first version mailed it: "Here is the Weekly report for 10
    # March", nothing attached, run recorded success. §7b.3's "an e-mail that looks
    # successful", with the attachment removed instead of broken.
    add_recipient(@recipient)
    @template.update_columns(output: 'per_record')
    empty = IssueQuery.create!(name: 'Nothing', project: @project, user: @author,
                               visibility: Query::VISIBILITY_PUBLIC,
                               filters: { 'issue_id' => { operator: '=', values: ['0'] } })
    @schedule.update_columns(query_id: empty.id, query_type: 'IssueQuery')

    result = deliver

    assert result.ok?, "not a failure either: #{result.error}"
    assert_empty @mailer.reports, 'nobody receives an envelope with nothing in it'
    assert_empty @mailer.failures, 'and nobody is paged about an empty week'
    assert_equal 0, result.document_count
    assert_equal 0, result.recipients_count
  end

  def test_a_combined_report_over_no_issues_is_still_sent
    # The boundary on the other side: a combined template renders one document whatever the
    # scope holds — "0 issues" is a report — so the rule above must not swallow it.
    add_recipient(@recipient)
    empty = IssueQuery.create!(name: 'Nothing at all', project: @project, user: @author,
                               visibility: Query::VISIBILITY_PUBLIC,
                               filters: { 'issue_id' => { operator: '=', values: ['0'] } })
    @schedule.update_columns(query_id: empty.id, query_type: 'IssueQuery')

    result = deliver

    assert result.ok?, result.error
    assert_equal 1, result.document_count
    assert_equal 1, @mailer.reports.length
  end

  def test_a_per_record_run_names_its_documents_distinctly
    # The `[[name, bytes]]`-rather-than-a-Hash comment exists to stop a filename collision
    # silently dropping a document. Collapsing the numbering left the suite green.
    add_recipient(@recipient)
    @template.update_columns(output: 'per_record')

    deliver

    names = @mailer.reports.first[:attachments].map(&:first)
    assert_operator names.length, :>, 1, 'precondition: this really is a per-record run'
    assert_equal names.length, names.uniq.length
    assert_match(/weekly-numbers-2026-03-10-001\.pdf/, names.first)
  end

  def test_a_recipient_with_no_address_is_dropped
    # Redmine allows a user with no e-mail address. Mailing one raises deep inside the
    # delivery stack; counting one as a recipient is a lie in the run row.
    silent = User.find(4)
    EmailAddress.where(user_id: silent.id).delete_all
    silent.reload
    add_recipient(silent)
    add_recipient(@recipient)

    result = deliver

    assert_equal 1, result.recipients_count
    assert_equal [@recipient], @mailer.reports.map { |r| r[:user] }
  end

  def test_a_delivery_that_breaks_halfway_records_who_already_received_it
    # Re-running would mail those people twice, so the run row has to be able to say how
    # many already have it. The first version let the exception escape with no counts, and
    # `finish_run` wrote nulls.
    [@recipient, User.find(4), User.find(8)].each { |u| add_recipient(u) }
    sent = 0
    mailer = Object.new
    mailer.define_singleton_method(:deliver_scheduled_report) do |*|
      sent += 1
      raise Net::SMTPFatalError, 'the relay refused it' if sent > 2
    end
    mailer.define_singleton_method(:deliver_scheduled_report_failure) { |*| nil }

    result = deliver(mailer: mailer)

    assert_not result.ok?
    assert_equal 2, result.recipients_count, 'two people already have it'
    assert_includes result.error, 'partial_delivery'
  end

  def test_the_ambient_actor_is_restored_even_when_the_render_raises
    # `#as`'s `ensure`. The file calls this "the part that is easy to get subtly wrong" and
    # the only example on it covered the happy path — deleting the `ensure` left the whole
    # suite green. `ScopeUnavailable` is rescued OUTSIDE the block, so this is a live path.
    add_recipient(@recipient)
    @schedule.update_columns(query_id: 999_999, query_type: 'IssueQuery')
    User.current = @recipient

    deliver(actor: @author)

    assert_equal @recipient, User.current
  ensure
    User.current = User.anonymous
  end

  # --- FR-45 / INV-1: whose visibility produced the numbers -------------------------------

  def test_the_scope_is_built_as_the_render_identity_and_not_as_the_process_user
    # THE ONE THAT NEEDS A REAL REDMINE. A rake task runs with `User.current` = Anonymous,
    # and `Issue.visible` defaults to it — so without `#as` the report would be built from
    # Anonymous's visibility and come out empty, which reads as "no issues this week"
    # rather than as a bug.
    add_recipient(@recipient)
    User.current = User.anonymous
    seen = nil
    RedmineReporterDashboards::Reporting::ReportRun.any_instance
                                                   .stubs(:count_scope)
                                                   .with { seen = User.current; true }
                                                   .returns(0)

    deliver(actor: @author)

    assert_equal @author, seen, 'the scope must be built as the schedule identity'
  ensure
    User.current = User.anonymous
  end

  def test_the_process_user_is_restored_afterwards
    add_recipient(@recipient)
    User.current = @recipient

    deliver(actor: @author)

    assert_equal @recipient, User.current, 'the ambient actor is borrowed, not taken'
  ensure
    User.current = User.anonymous
  end

  def test_the_mail_is_told_which_identity_produced_the_numbers
    # FR-47: "shared output is labelled with the identity it was rendered as." On this path
    # the recipient and the render identity are usually DIFFERENT people — that is what
    # `render_as` is for — so the mail has to say so.
    add_recipient(@recipient)

    deliver(actor: @author)

    assert_equal @author, @mailer.reports.first[:rendered_as]
  end

  # --- the saved query, which fails rather than silently widening --------------------------

  def test_a_query_the_render_identity_cannot_see_fails_instead_of_falling_back
    # DELIBERATELY DIFFERENT FROM THE INTERACTIVE PATH. `TemplatesController` ignores an
    # unresolvable query id and uses the project scope, because answering differently for
    # "deleted" and "you may not see it" would make the picker a probe. Nobody is probing
    # here, and the fallback would mail every issue in the project under the name of a
    # schedule configured for a narrow one.
    add_recipient(@recipient)
    @schedule.update_columns(query_id: 999_999, query_type: 'IssueQuery')

    result = deliver

    assert_not result.ok?
    assert_includes result.error, 'saved query 999999'
    assert_empty @mailer.reports
    assert_equal 1, @mailer.failures.length
  end

  def test_a_query_the_render_identity_can_see_is_used
    add_recipient(@recipient)
    query = IssueQuery.create!(name: 'Mine', project: @project, user: @author,
                               visibility: Query::VISIBILITY_PUBLIC)
    @schedule.update_columns(query_id: query.id, query_type: 'IssueQuery')

    result = deliver

    assert result.ok?, result.error
    assert_equal 1, @mailer.reports.length
  end

  # --- the mail-size cap ---------------------------------------------------------------------

  def test_attachments_over_the_cap_are_refused_before_anything_is_sent
    # `BatchGuard` bounds the DOCUMENT count; this bounds the BYTES, and only one of those
    # is about mail. Fifty documents inside the cap can still be a message the MTA rejects
    # — after the run row already said success.
    add_recipient(@recipient)
    FakeEngine.bytes = FakeEngine.pdf_of(Delivery::MAX_ATTACHMENT_BYTES + 1)

    result = deliver

    assert_not result.ok?
    assert_empty @mailer.reports, 'nothing is sent, rather than sent and bounced'
    assert_equal 1, @mailer.failures.length
    assert_includes result.error, 'attachments_too_large'
    assert_includes @mailer.failures.first[:diagnostic].message, 'MB'
  end

  def test_an_attachment_at_the_cap_is_sent
    # At the limit and one past it, which is what CLAUDE.md §3 asks for.
    add_recipient(@recipient)
    FakeEngine.bytes = FakeEngine.pdf_of(Delivery::MAX_ATTACHMENT_BYTES)

    result = deliver

    assert result.ok?, result.error
    assert_equal 1, @mailer.reports.length
  end

  # --- an SMTP failure is a failure -----------------------------------------------------------

  def test_a_delivery_error_becomes_a_recorded_failure_rather_than_a_log_line
    # Redmine's `Mailer.deliver_mail` swallows delivery errors unless `raise_delivery_errors`
    # is set, so an SMTP server that is down produces a log line nobody reads and a run row
    # that says success. `ReporterDashboardsMailer.deliver_mail` is what makes the exception
    # arrive; `ScheduledDelivery` turns it into a `Delivered` carrying the partial count — an
    # escaping raise would lose the one number an operator needs before re-running.
    add_recipient(@recipient)

    result = deliver(mailer: RecordingMailer.new(raising: true))

    assert_not result.ok?
    assert_includes result.error, 'partial_delivery'
    assert_includes result.error, 'Net::SMTPFatalError'
    assert_equal 0, result.recipients_count, 'nobody got it'
  end

  # THESE TWO USED TO ASSERT THAT A GLOBAL WAS RESTORED. It is no longer written, so they
  # assert that it is never written — which is a stronger statement and the one an independent
  # review's finding actually asks for. `reporter_dashboards_mail_delivery_errors_test.rb`
  # holds the rest of it, including the two threaded cases this file cannot express.
  def test_delivery_never_writes_the_global_delivery_errors_flag
    add_recipient(@recipient)
    before = ActionMailer::Base.raise_delivery_errors
    seen_inside = nil

    mailer = Object.new
    mailer.define_singleton_method(:deliver_scheduled_report) do |*|
      seen_inside = ActionMailer::Base.raise_delivery_errors
      raise Net::SMTPFatalError, 'relay refused'
    end
    mailer.define_singleton_method(:deliver_scheduled_report_failure) { |*| nil }

    deliver(mailer: mailer)

    assert_equal before, seen_inside, 'the flag was changed for the duration of the send'
    assert_equal before, ActionMailer::Base.raise_delivery_errors
  end

  def test_the_global_flag_is_untouched_when_the_send_raises_past_the_rescue
    # Something the recipient loop's `rescue StandardError` does not catch. There is no
    # `ensure` left to get wrong, and this proves there is nothing that needs one.
    add_recipient(@recipient)
    before = ActionMailer::Base.raise_delivery_errors
    exploding = Object.new
    exploding.define_singleton_method(:deliver_scheduled_report) { |*| raise NotImplementedError }
    exploding.define_singleton_method(:deliver_scheduled_report_failure) { |*| nil }

    assert_raises(NotImplementedError) { deliver(mailer: exploding) }

    assert_equal before, ActionMailer::Base.raise_delivery_errors
  end

  # --- the real mailer, the real message ---------------------------------------------------

  def test_the_real_mailer_sends_one_message_per_recipient_with_the_attachment
    add_recipient(@recipient)

    with_engine(FakeEngine) do
      Delivery.new.call(schedule: @schedule, occurrence_date: OCCURRENCE,
                        actor: @author, run: @run)
    end

    assert_equal 1, ActionMailer::Base.deliveries.length
    mail = ActionMailer::Base.deliveries.last
    assert_equal [@recipient.mail], mail.to
    assert_equal 1, mail.attachments.length
    assert_equal 'weekly-numbers-2026-03-10.pdf', mail.attachments.first.filename
    # CRLF-normalised on both sides: Mail canonicalises line endings in a base64 part on
    # the way out, so the bytes that come back are not byte-identical to the ones that went
    # in. What matters here is that the attachment IS the render's output rather than a
    # placeholder, so the comparison is made on the normalised form and says so.
    assert_equal FakeEngine.bytes.gsub(/\r\n/, "\n"),
                 mail.attachments.first.body.decoded.gsub(/\r\n/, "\n")
  end

  # T-30's third acceptance clause, against the REAL mailer rather than the double.
  # `test_a_failure_notice_carries_no_attachment_argument_at_all` proves the signature
  # cannot express an attachment; this proves the message that actually goes out has none
  # and carries the id, which is what an owner is asked to quote. A double cannot fail
  # either way, and neither can a signature: only a delivered `Mail::Message` can.
  def test_the_real_failure_notice_carries_the_correlation_id_and_no_attachment
    add_recipient(@recipient)
    @template.update_columns(content: '{% this is not a tag %}')

    result = Delivery.new.call(schedule: @schedule, occurrence_date: OCCURRENCE,
                               actor: @author, run: @run)

    assert_not result.ok?
    assert_equal 1, ActionMailer::Base.deliveries.length,
                 'the owner is told, and nobody else is'
    mail = ActionMailer::Base.deliveries.last
    assert_equal [@author.mail], mail.to
    assert_equal 0, mail.attachments.length, 'FR-43: a failure notice has no attachment'

    body = mail.parts.map { |part| part.body.decoded }.join("\n")
    # The id the owner is asked to quote is the id the RUN ROW carries — asserted against
    # the row rather than against a shape, because a well-formed id that belongs to
    # nothing is the defect T-25's review found (`ReportRun` minting its own per document).
    assert_include @run.correlation_id, body
    assert_not_include '%PDF-', body
  end

  def test_the_sender_is_the_server_and_there_is_no_way_to_set_it
    # §7b.5's finding: the base plugin let a schedule specify `from` as free text — "a
    # report over any issue in the instance, mailed anywhere, with a forged sender". The
    # schema has no such column and the mailer takes no such argument, so this is asserted
    # rather than hoped for.
    add_recipient(@recipient)

    with_engine(FakeEngine) do
      Delivery.new.call(schedule: @schedule, occurrence_date: OCCURRENCE,
                        actor: @author, run: @run)
    end

    assert_equal [Mail::Address.new(Setting.mail_from).address],
                 ActionMailer::Base.deliveries.last.from
    assert_not_includes Schedule.column_names, 'from'
    assert_not_includes ScheduleRecipient.column_names, 'to'
  end

  def test_the_authors_own_subject_wins_and_is_not_prefixed
    add_recipient(@recipient)
    @schedule.update_columns(email_subject: 'Monday numbers')

    with_engine(FakeEngine) do
      Delivery.new.call(schedule: @schedule, occurrence_date: OCCURRENCE,
                        actor: @author, run: @run)
    end

    assert_equal 'Monday numbers', ActionMailer::Base.deliveries.last.subject
  end

  def test_the_generated_subject_names_the_report_and_the_day
    add_recipient(@recipient)

    with_engine(FakeEngine) do
      Delivery.new.call(schedule: @schedule, occurrence_date: OCCURRENCE,
                        actor: @author, run: @run)
    end

    subject = ActionMailer::Base.deliveries.last.subject
    assert_includes subject, 'Weekly numbers'
    assert_includes subject, '2026'
  end

  def test_the_body_names_the_identity_the_numbers_were_produced_with
    add_recipient(@recipient)

    with_engine(FakeEngine) do
      Delivery.new.call(schedule: @schedule, occurrence_date: OCCURRENCE,
                        actor: @author, run: @run)
    end

    assert_includes mail_body(ActionMailer::Base.deliveries.last), @author.name
  end

  def test_a_schedule_whose_template_is_gone_fails_in_a_sentence_rather_than_crashing
    # WRITTEN FOR THE MAILER'S FALLBACK NAME, AND IT FOUND SOMETHING ELSE. `ReportRun#call`
    # opens with `template.source`, so a dangling `template_id` was a `NoMethodError` on nil
    # rather than a failure — the owner would have been told "undefined method `source' for
    # nil", a stack-trace fragment where a sentence belongs. `dependent: :destroy` normally
    # prevents the state; `delete_all` and a DB-level delete bypass callbacks.
    add_recipient(@recipient)
    @schedule.update_columns(template_id: 999_999)

    result = nil
    assert_nothing_raised do
      with_engine(FakeEngine) do
        result = Delivery.new.call(schedule: @schedule.reload, occurrence_date: OCCURRENCE,
                                   actor: @author, run: @run)
      end
    end

    assert_not result.ok?
    assert_includes result.error, 'template_missing'
    assert_empty ActionMailer::Base.deliveries.select { |m| m.to == [@recipient.mail] }

    # And the fallback name is used consistently: the subject fell back to "Scheduled
    # report" while the body read "Here is the  report for …" — two fallbacks for one value,
    # one of them empty.
    mail = ActionMailer::Base.deliveries.last
    fallback = I18n.t(:label_reporter_schedule)
    assert_equal [@author.mail], mail.to
    assert_includes mail.subject, fallback
    assert_includes mail_body(mail), fallback
  end

  def test_a_failure_notice_is_addressed_to_the_owner_and_carries_no_attachment
    add_recipient(@recipient)
    @template.update_columns(content: '{% this is not a tag %}')

    with_engine(FakeEngine) do
      Delivery.new.call(schedule: @schedule, occurrence_date: OCCURRENCE,
                        actor: @author, run: @run)
    end

    assert_equal 1, ActionMailer::Base.deliveries.length
    mail = ActionMailer::Base.deliveries.last
    assert_equal [@author.mail], mail.to, 'the owner, not the recipients'
    assert_empty mail.attachments
  end

  def test_the_failure_notice_never_carries_the_diagnostics_detail
    # §7b.3's leak prevention. `detail` holds the raw exception and can hold SQL, role ids
    # and project ids; `Diagnostic#to_h` omits it and so must the mail.
    add_recipient(@recipient)
    # A REAL CODE. This said `:boom` until T-30 closed the code set — `FailureDocument`'s
    # safety argument is that `code` is a vocabulary rather than text, so the constructor
    # now refuses one no vocabulary contains, and this example's subject was never the
    # code anyway.
    diagnostic = Diagnostic.new(origin: :template, code: :syntax_error,
                                message: 'the safe summary',
                                correlation_id: 'cid-9',
                                detail: 'SELECT secret FROM issues WHERE role_id = 4')

    ReporterDashboardsMailer.deliver_scheduled_report_failure(@author, @schedule,
                                                              OCCURRENCE, diagnostic)

    body = mail_body(ActionMailer::Base.deliveries.last)
    assert_includes body, 'the safe summary'
    assert_includes body, 'cid-9'
    assert_not_includes body, 'SELECT secret'
  end

  def test_the_mail_is_written_in_the_recipients_language
    # `Mailer#process` switches `I18n.locale` to the recipient's, which is the whole reason
    # this mailer subclasses Redmine's rather than ActionMailer::Base — and the reason nine
    # locale files are worth maintaining on this path.
    @recipient.update_columns(language: 'de')
    add_recipient(@recipient)

    with_engine(FakeEngine) do
      Delivery.new.call(schedule: @schedule, occurrence_date: OCCURRENCE,
                        actor: @author, run: @run)
    end

    assert_includes mail_body(ActionMailer::Base.deliveries.last), 'Hier ist der Bericht'
  end
end
