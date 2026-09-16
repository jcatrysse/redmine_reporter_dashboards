# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-28 — the snapshot store, against a real database and a real `Attachment`. FR-52.
#
# --- WHY NOT A DOUBLE ---
#
# Every claim this module makes is about what is on disk and in the schema afterwards: that
# a document row exists, that the bytes are reachable, that the attachment has a CONTAINER
# (which is what saves it from `Attachment.prune`), and that a failure leaves neither
# behind. A double can fail none of those.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. There is none here.
class ReporterDashboardsSnapshotTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  Snapshot = RedmineReporterDashboards::Reporting::Snapshot
  Document = RedmineReporterDashboards::Document
  Template = RedmineReporterDashboards::Template

  # A fixed body of bytes, so `digest` and `byte_size` are checkable against a number this
  # file computes rather than against whatever the engine happened to produce.
  PDF_BYTES = "%PDF-1.4\n#{'0' * 2_000}\n%%EOF"

  class FakeEngine
    def capabilities
      []
    end

    def id
      'fake'
    end

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: PDF_BYTES, engine: 'fake', engine_version: '1.0', page_count: 3,
        duration_ms: 12
      )
    end
  end

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @jsmith = User.find_by!(login: 'jsmith')
    Role.find(1).tap do |role|
      role.permissions = %w[view_issues view_reporter_dashboards_reports]
      role.save!
    end
    @template = Template.create!(project: @project, author: @jsmith, name: 'Frozen',
                                 content: '<p>hello</p>', source: 'issues',
                                 output: 'combined')
    @expires = 30.days.from_now
  end

  def teardown
    User.current = nil
  end

  # ------------------------------------------------------------------ helpers

  def with_engine
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, FakeEngine)
      yield
    end
  end

  def capture(overrides = {})
    with_engine do
      # `**` AND NOT A BARE HASH. `capture` takes keywords, and Ruby 3 does not convert a
      # positional Hash into them — it answers `ArgumentError: given 1, expected 0`, which
      # is a real error every one of these tests would otherwise report identically.
      Snapshot.capture(**{ template: @template, render_as: @jsmith, project: @project,
                           created_by: @jsmith, expires_at: @expires }.merge(overrides))
    end
  end

  # ------------------------------------------------------------------ the happy path

  def test_a_capture_writes_one_document_row_and_answers_it
    result = nil

    assert_difference 'RedmineReporterDashboards::Document.count', 1 do
      result = capture
    end

    assert result.ok?, "capture refused: #{result.code} #{result.message}"
    assert_equal @template.id, result.document.template_id
    assert_equal @project.id, result.document.project_id
  end

  # THE IDENTITY IS STORED, WHICH IS §7b.1's own words — *"the identity the content was
  # rendered as, stored explicitly"* — and FR-45's point that the requester and the render
  # identity are two different questions. The capture below is REQUESTED by dlopper and
  # RENDERED as jsmith, so a single column holding both would fail.
  def test_the_render_identity_and_the_requester_are_stored_separately
    dlopper = User.find_by!(login: 'dlopper')

    result = capture(render_as: @jsmith, created_by: dlopper)

    assert result.ok?, result.message
    assert_equal @jsmith.id, result.document.rendered_as_user_id
    assert_equal dlopper.id, result.document.created_by_id
  end

  def test_the_stored_metadata_describes_the_render_that_produced_it
    result = capture

    document = result.document
    assert_equal 'fake', document.engine
    assert_equal '1.0', document.engine_version
    assert_equal 12, document.render_duration_ms
    assert_equal 3, document.page_count
    assert_equal Snapshot::CONTENT_TYPE, document.content_type
    assert_equal PDF_BYTES.bytesize, document.byte_size
    assert_equal Digest::SHA256.hexdigest(PDF_BYTES), document.digest
    assert_not_nil document.correlation_id, 'FR-58: the id in the panel is the id on the row'
  end

  def test_the_bytes_come_back_exactly
    result = capture

    assert_equal PDF_BYTES, result.document.bytes
    assert_equal PDF_BYTES.bytesize, result.document.bytes.bytesize
  end

  # ------------------------------------------------------------------ the prune trap

  # THE MEASURED ONE, AND IT IS THE REASON THE CONTAINER EXISTS AT ALL.
  #
  # `Attachment.prune` is `where("created_on < ? AND (container_type IS NULL OR
  # container_type = '')").destroy_all` (core `app/models/attachment.rb:375`), run by
  # `rake redmine:attachments:prune` — a task Redmine's installation guide tells
  # administrators to cron. A snapshot stored as an UNCONTAINED attachment is therefore
  # deleted the next day on a correctly-administered instance, and every share link with a
  # 30-day expiry would answer "no longer stored" from day two.
  #
  # This calls the real core method rather than asserting the column, so a future change
  # that alters the prune's WHERE clause fails here rather than shipping.
  def test_the_stored_attachment_survives_redmines_own_attachment_prune
    result = capture
    attachment_id = result.document.attachment_id
    assert_not_nil attachment_id

    # Aged past the prune's window, which is what a cron would find tomorrow.
    ::Attachment.where(id: attachment_id).update_all(created_on: 3.days.ago)
    ::Attachment.prune

    assert ::Attachment.exists?(attachment_id),
           'the snapshot was deleted by redmine:attachments:prune'
    assert_equal PDF_BYTES, result.document.reload.bytes
  end

  # ...AND THE CONTROL FOR IT. Without this the test above proves only that `prune` did
  # nothing at all — which would also be true if it were broken, or if the row were too new.
  def test_the_control_an_uncontained_attachment_is_pruned
    orphan = ::Attachment.create!(file: StringIO.new('x'), author: @jsmith,
                                  filename: 'orphan.txt', content_type: 'text/plain')
    ::Attachment.where(id: orphan.id).update_all(created_on: 3.days.ago)

    ::Attachment.prune

    assert_not ::Attachment.exists?(orphan.id),
               'prune deleted nothing, so the test above asserts nothing'
  end

  # THE OTHER HALF OF CONTAINING IT. A contained attachment is reachable at
  # `/attachments/:id`, and core decides that by asking the container. All three answers
  # are no, for everybody, because the share link is the only door.
  def test_core_may_not_serve_the_snapshot_through_its_own_attachment_route
    result = capture
    attachment = ::Attachment.find(result.document.attachment_id)

    [User.find(1), @jsmith, User.anonymous].each do |user|
      assert_not attachment.visible?(user), "#{user.login} could download it through core"
      assert_not attachment.editable?(user)
      assert_not attachment.deletable?(user)
    end
  end

  # ------------------------------------------------------------------ lifecycle

  def test_destroying_the_document_takes_the_bytes_with_it
    result = capture
    attachment_id = result.document.attachment_id

    assert_difference '::Attachment.count', -1 do
      result.document.destroy
    end
    assert_not ::Attachment.exists?(attachment_id)
  end

  # DELETING THE REPORT TAKES THE BYTES WITH IT AND KEEPS THE RECORD. Every share link to a
  # template is destroyed with it, so its snapshots are unreachable the moment it goes;
  # leaving the files on disk would be bytes nobody can read and nobody remembers, waiting
  # out a TTL for no reason.
  def test_destroying_the_template_purges_its_snapshots_and_keeps_the_audit_rows
    result = capture
    document = result.document
    attachment_id = document.attachment_id

    assert_difference '::Attachment.count', -1 do
      @template.destroy
    end

    assert_not ::Attachment.exists?(attachment_id), 'the bytes outlived the report'
    assert Document.exists?(document.id), 'the audit row went with them'
    document.reload
    assert document.purged?
    assert_nil document.template_id, 'the row should forget its template, not vanish'
  end

  def test_the_document_expires_when_it_was_told_to
    result = capture(expires_at: 1.hour.from_now)

    assert_not result.document.expired?
    assert result.document.expired?(2.hours.from_now)
  end

  # ------------------------------------------------------------------ refusals

  # A REFUSAL WRITES NOTHING. Each of the three below is checked with `assert_no_difference`
  # rather than only on the returned code, because a document row with no bytes behind it is
  # what a share link would later serve as an empty response.
  # `per_record` AND NOT `combined`, AND THE FIRST VERSION OF THIS TEST HAD IT WRONG in a
  # way worth keeping the correction for: a COMBINED template over an empty scope still
  # produces one document — a report saying "nothing matched" is a report — so the capture
  # succeeded and the assertion failed. `no_documents` is reachable only where the number of
  # documents follows the number of records, which is the per-record output.
  def test_an_empty_scope_is_refused_and_stores_nothing
    @template.update!(output: 'per_record')
    Issue.delete_all

    result = nil
    assert_no_difference 'RedmineReporterDashboards::Document.count' do
      result = capture
    end

    assert_not result.ok?
    assert_equal :no_documents, result.code
  end

  # A SNAPSHOT IS ONE ARTEFACT. A per-record template over the fixture's issues produces
  # several documents, which is a zip — and silently freezing the first would share one
  # issue's report under a name describing all of them.
  def test_a_per_record_template_is_refused_rather_than_truncated
    @template.update!(output: 'per_record')

    result = nil
    assert_no_difference 'RedmineReporterDashboards::Document.count' do
      result = capture
    end

    assert_not result.ok?
    assert_equal :many_documents, result.code
    assert_include 'a snapshot is one document', result.message
  end

  def test_an_unresolvable_query_is_refused_rather_than_silently_widened
    result = nil
    assert_no_difference 'RedmineReporterDashboards::Document.count' do
      result = capture(query_id: 999_999)
    end

    assert_not result.ok?
    assert_equal :scope_unavailable, result.code
  end

  def test_a_render_failure_is_refused_and_carries_the_diagnostic
    result = nil
    assert_no_difference 'RedmineReporterDashboards::Document.count' do
      # No engine registered at all, so the run fails at the PDF step rather than at a
      # step this test would have to fake.
      result = RedmineReporterDashboards::Render::Registry.isolated do
        Snapshot.capture(template: @template, render_as: @jsmith, project: @project,
                         created_by: @jsmith, expires_at: @expires)
      end
    end

    assert_not result.ok?
    assert_equal :render_failed, result.code
    assert_not_nil result.diagnostic
  end

  # ------------------------------------------------------------------ half-written state

  # THE ONE BRANCH A MUTATION SURVIVED, AND IT IS THE WORST FAILURE THIS MODULE CAN HAVE.
  #
  # `Attachment#save` answers FALSE rather than raising when the row is invalid — a storage
  # path that is not writable, an author that no longer exists. `store` rolls back and
  # refuses; ignoring the flag would leave a DOCUMENT ROW WITH NO BYTES BEHIND IT, which a
  # share link then serves as an empty response with a 200 beside it. Deleting the `unless
  # stored` line left all 61 tests green until this one existed.
  #
  # DRIVEN THROUGH `store` DIRECTLY rather than through `capture`, because the trigger has
  # to be deterministic: `Attachment` validates `author` present, so a capture with neither
  # a requester nor a render identity is an invalid attachment every time, on every engine
  # and every database.
  def test_an_attachment_that_will_not_save_leaves_no_document_row_behind
    outcome = RedmineReporterDashboards::Reporting::ReportRun::Outcome.new(
      sections: [], documents: [
        RedmineReporterDashboards::Render::Success.new(bytes: PDF_BYTES, engine: 'fake',
                                                       engine_version: '1.0')
      ]
    )

    result = nil
    assert_no_difference 'RedmineReporterDashboards::Document.count' do
      result = Snapshot.store(template: @template, project: @project, outcome: outcome,
                              render_as: nil, created_by: nil, expires_at: @expires)
    end

    assert_not result.ok?
    assert_equal :attachment_failed, result.code
    assert_not_nil result.message
  end

  # AND THE SAME BRANCH FROM THE OTHER SIDE: the row is fine and the FILE is gone, which is
  # what a restored database without its `files/` directory looks like. `nil` rather than
  # `Errno::ENOENT` from a controller — the share endpoint turns nil into a sentence and an
  # exception into a 500.
  def test_a_document_whose_file_is_missing_answers_no_bytes_rather_than_raising
    result = capture
    ::File.delete(::Attachment.find(result.document.attachment_id).diskfile)

    assert_nil result.document.reload.bytes
  end

  # A PURGED DOCUMENT IS GONE EVEN IF ITS FILE IS NOT. `purged_at` is the record that the
  # bytes were collected; reading them anyway would make the purge a lie an auditor could
  # not detect.
  def test_a_purged_document_answers_no_bytes
    result = capture
    result.document.update_columns(purged_at: Time.zone.now)

    assert_nil result.document.reload.bytes
  end

  # ------------------------------------------------------------------ INV-1

  # AN ENGINE WHOSE OUTPUT DEPENDS ON THE RENDER, which `FakeEngine` deliberately is not.
  #
  # This is the whole reason the test below exists. Every other test in this file registers
  # an engine returning a CONSTANT byte string, so the stored bytes are independent of the
  # scope by construction — and an independent review proved what that costs: replacing
  # `as(actor)` with `as(::User.current)`, so the render runs as whatever the caller left
  # ambient while the row still records `render_as`, left all 64 tests green. That is INV-1
  # and FR-52's central claim, and nothing could see it break.
  # PADDED PAST `Renderer::MIN_PDF_BYTES` (1 024), which rejects a short document as
  # `output_empty`. The echoed body is what varies; the padding only gets it past a
  # guard that exists to catch an engine that drew nothing.
  PAD = '0' * 2_000

  class EchoEngine
    def capabilities
      []
    end

    def id
      'echo'
    end

    def render(request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: "%PDF-1.4\n#{request.body}\n#{PAD}\n%%EOF", engine: 'echo', engine_version: '1.0'
      )
    end
  end

  def capture_echoing(overrides = {})
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:echo, EchoEngine)
      Snapshot.capture(**{ template: @template, render_as: @jsmith, project: @project,
                           created_by: @jsmith, expires_at: @expires }.merge(overrides))
    end
  end

  # THE CLAIM FR-52 RESTS ON: the bytes were computed inside the NAMED identity's own
  # visible scope, and the identity stored on the row is the one that produced them. A
  # violation is worse than no label — it is a document ATTRIBUTED to somebody who did not
  # produce it, served afterwards with no request-time check of any kind.
  #
  # Driven with the ambient `User.current` set to the WRONG person each time, because that
  # is the only arrangement in which `as(actor)` and `as(User.current)` differ.
  def test_the_bytes_are_rendered_as_the_named_identity_and_not_the_ambient_user
    dlopper = User.find_by!(login: 'dlopper')
    @template.update!(content: 'COUNT=[{{ issues.size }}]')
    make_the_two_actors_see_different_issues(dlopper)

    jsmith_expected = "COUNT=[#{visible_count(@jsmith)}]"
    dlopper_expected = "COUNT=[#{visible_count(dlopper)}]"
    # THE PRECONDITION, ASSERTED. If the two actors happen to see the same issues, both
    # branches below produce the same bytes and this test passes against anything.
    assert_not_equal jsmith_expected, dlopper_expected,
                     'the two actors see the same issues, so this test cannot discriminate'

    User.current = dlopper
    as_jsmith = capture_echoing(render_as: @jsmith, created_by: dlopper)
    User.current = @jsmith
    as_dlopper = capture_echoing(render_as: dlopper, created_by: @jsmith)

    assert as_jsmith.ok?, as_jsmith.message
    assert as_dlopper.ok?, as_dlopper.message
    # EACH DOCUMENT MATCHES ITS OWN `render_as`, which is the assertion that fails when the
    # render takes the ambient user: the two would come back swapped, each still labelled
    # with the identity it was asked for.
    assert_include jsmith_expected, as_jsmith.document.bytes,
                 'the document recorded as rendered by jsmith does not hold jsmith’s numbers'
    assert_include dlopper_expected, as_dlopper.document.bytes,
                 'the document recorded as rendered by dlopper does not hold dlopper’s numbers'
    assert_not_equal as_jsmith.document.bytes, as_dlopper.document.bytes
  end

  # AND THE SAME CLAIM AT THE COLUMN: the identity stored is the identity that rendered.
  def test_the_stored_identity_is_the_one_whose_scope_produced_the_bytes
    dlopper = User.find_by!(login: 'dlopper')
    @template.update!(content: 'COUNT=[{{ issues.size }}]')
    make_the_two_actors_see_different_issues(dlopper)

    User.current = dlopper
    result = capture_echoing(render_as: @jsmith, created_by: dlopper)

    assert_equal @jsmith.id, result.document.rendered_as_user_id
    assert_include "COUNT=[#{visible_count(@jsmith)}]", result.document.bytes
  end

  def visible_count(actor)
    Issue.visible(actor).where(project_id: @project.id).count
  end

  # ONE PRIVATE ISSUE AND TWO ROLES THAT DIFFER ABOUT IT. Built rather than assumed from the
  # fixtures, because "these two users happen to see different things" is exactly the kind of
  # precondition that quietly stops being true when a fixture changes.
  def make_the_two_actors_see_different_issues(dlopper)
    seer = Role.find(1)
    seer.permissions = %w[view_issues view_private_issues]
    seer.save!
    blind = Role.find(2)
    blind.permissions = %w[view_issues]
    blind.save!

    Member.where(project_id: @project.id, user_id: @jsmith.id).destroy_all
    Member.where(project_id: @project.id, user_id: dlopper.id).destroy_all
    Member.create!(project: @project, principal: @jsmith, roles: [seer])
    Member.create!(project: @project, principal: dlopper, roles: [blind])

    issue = Issue.where(project_id: @project.id).order(:id).first
    issue.update_columns(is_private: true, author_id: @jsmith.id, assigned_to_id: @jsmith.id)
  end

  # ------------------------------------------------------------------ the TTL, which had no effect

  # AN EXPIRED SNAPSHOT STOPS BEING SERVABLE THE MOMENT IT EXPIRES, not when a purge task
  # next runs. FOUND BY AN INDEPENDENT REVIEW, which measured a link outliving its document
  # by 300 days and getting `200` with the bytes: `expires_at` was read by a validation and
  # by nothing else, so the "mandatory, bounded TTL" the spec insists on was decorative in
  # the very commit that first created rows.
  def test_an_expired_snapshot_is_no_longer_servable_even_though_the_file_is_still_there
    result = capture(expires_at: 1.hour.from_now)
    document = result.document

    assert document.servable?
    assert_not_nil document.bytes

    document.update_columns(expires_at: 1.hour.ago)

    assert_not document.reload.servable?
    assert_nil document.bytes
    # THE FILE IS STILL THERE, which is the point: expiry is not the same event as purging,
    # and serving must stop at the first of them rather than at the second.
    assert ::Attachment.exists?(document.attachment_id)
  end

  # ------------------------------------------------------------------ purging

  def test_purging_deletes_the_bytes_and_keeps_the_row
    result = capture(expires_at: 1.hour.from_now)
    document = result.document
    attachment_id = document.attachment_id
    document.update_columns(expires_at: 1.hour.ago)

    assert_difference '::Attachment.count', -1 do
      assert document.purge!
    end

    # THE ROW SURVIVES. `purged_at` is the difference between "a document existed here and
    # was collected on this date" and "no document ever existed".
    assert Document.exists?(document.id)
    document.reload
    assert document.purged?
    assert_nil document.attachment_id
    assert_not ::Attachment.exists?(attachment_id)
    assert_nil document.bytes
  end

  def test_purging_twice_does_not_move_the_moment_it_happened
    result = capture(expires_at: 1.hour.from_now)
    document = result.document
    document.update_columns(expires_at: 1.hour.ago)
    document.purge!
    first = document.reload.purged_at

    assert_not document.purge!
    assert_equal first, document.reload.purged_at
  end

  # THE SCOPE THE TASK READS, asserted here so the task and any diagnostic cannot disagree
  # about what "expired" means — and so an unexpired document is never collected.
  def test_the_expired_scope_finds_only_what_is_past_its_ttl_and_not_yet_purged
    live = capture(expires_at: 30.days.from_now).document
    dead = capture(expires_at: 1.hour.from_now).document
    dead.update_columns(expires_at: 1.hour.ago)

    expired_ids = Document.expired.pluck(:id)
    assert_includes expired_ids, dead.id
    assert_not_includes expired_ids, live.id

    dead.purge!
    assert_not_includes Document.expired.pluck(:id), dead.id,
                        'a purged document is still being offered to the purge task'
  end

  # ------------------------------------------------------------------ refusals that used to raise

  # `capture` PROMISES A `Result` AND USED TO RAISE. An independent review measured
  # `ActiveRecord::RecordInvalid` escaping past every caller written against `Result`,
  # including the README's own console recipe. AT THE BOUND AND ONE PAST IT.
  def test_a_bad_expiry_is_a_refusal_and_never_an_exception
    [nil, '', 1.hour.ago, Document::MAX_RETENTION.seconds.from_now + 2.days].each do |bad|
      result = nil
      assert_no_difference 'RedmineReporterDashboards::Document.count' do
        result = capture(expires_at: bad)
      end

      assert_not result.ok?, "#{bad.inspect} was accepted"
      assert_equal :invalid_expiry, result.code
      assert_not_nil result.message
    end
  end

  def test_an_expiry_just_inside_the_retention_bound_is_accepted
    result = capture(expires_at: Document::MAX_RETENTION.seconds.from_now - 1.day)

    assert result.ok?, result.message
  end

  # THE PROJECT MUST BE THE TEMPLATE'S. Measured by an independent review: passing another
  # project succeeded and filed the snapshot under it, so the row claimed a project whose
  # members had nothing to do with the report — and `project` also bounds the render's
  # scope, so the bytes were a different report from the one the row described.
  def test_capturing_a_template_under_somebody_elses_project_is_refused
    other = Project.find(2)

    result = nil
    assert_no_difference 'RedmineReporterDashboards::Document.count' do
      result = capture(project: other)
    end

    assert_not result.ok?
    assert_equal :wrong_project, result.code
  end

  # ------------------------------------------------------------------ the filename

  # BOUNDED, AND TESTED AT THE BOUNDARY THE REVIEW MEASURED. A 245-character template name —
  # legal, since `Template#name` allows 255 — produced a filename over `attachments.filename`'s
  # own 255 and answered `attachment_failed: File is too long`, which is a nonsense message
  # for "your report has a long title".
  def test_a_template_with_a_very_long_name_still_captures
    @template.update!(name: 'A' * 255)

    result = capture

    assert result.ok?, "#{result.code}: #{result.message}"
    filename = ::Attachment.find(result.document.attachment_id).filename
    assert_operator filename.length, :<=, 255
    assert filename.start_with?('report-a'), filename
    assert filename.end_with?(".pdf"), filename
  end

  # THE NAME IS IN THE FILENAME, which is the only reason `filename_for` does any work at
  # all — without this, replacing it with a constant is invisible.
  def test_the_filename_carries_the_template_name_and_the_document_id
    @template.update!(name: 'Quarterly Rollup')

    result = capture

    assert_equal "report-quarterly-rollup-#{result.document.id}.pdf",
                 ::Attachment.find(result.document.attachment_id).filename
  end

  # A NON-LATIN NAME COLLAPSES TO THE FALLBACK, and that is deliberate rather than a bug —
  # `parameterize` strips it entirely, and a non-ASCII `Content-Disposition` filename is the
  # interoperability problem it exists to avoid. Pinned so the behaviour is a decision
  # somebody made rather than one nobody noticed: eight of this plugin's nine locales can
  # produce such a name.
  def test_a_non_latin_template_name_falls_back_and_stays_unique
    @template.update!(name: 'Отчёт')
    first = capture
    second = capture

    a = ::Attachment.find(first.document.attachment_id).filename
    b = ::Attachment.find(second.document.attachment_id).filename
    assert_equal "report-report-#{first.document.id}.pdf", a
    assert_not_equal a, b, 'two snapshots of one template share a filename'
  end

  # ------------------------------------------------------------------ the identity

  # `User.current` IS SET FOR THE RENDER AND RESTORED AFTERWARDS. Core reads it ambiently —
  # `Issue.visible` with no argument, `Setting`, every `l()` — so a capture that did not set
  # it would render half as whoever happened to be current. And a capture that did not
  # restore it would leave a request running as somebody else, which is the worse of the
  # two bugs.
  def test_the_current_user_is_set_for_the_render_and_put_back_afterwards
    dlopper = User.find_by!(login: 'dlopper')
    User.current = dlopper
    seen = nil
    @template.update!(content: '{% assign x = 1 %}<p>hi</p>')

    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, FakeEngine)
      Snapshot.as(@jsmith) { seen = User.current }
      Snapshot.capture(template: @template, render_as: @jsmith, project: @project,
                       created_by: dlopper, expires_at: @expires)
    end

    assert_equal @jsmith.id, seen.id
    assert_equal dlopper.id, User.current.id, 'the capture left User.current changed'
  end

  # AND IT IS PUT BACK EVEN WHEN THE RENDER RAISES — an `ensure` that is only exercised on
  # the happy path is an `ensure` nobody has tested.
  def test_the_current_user_is_put_back_when_the_render_raises
    dlopper = User.find_by!(login: 'dlopper')
    User.current = dlopper

    assert_raises(RuntimeError) { Snapshot.as(@jsmith) { raise 'boom' } }

    assert_equal dlopper.id, User.current.id
  end
end
