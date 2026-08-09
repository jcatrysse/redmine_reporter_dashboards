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
