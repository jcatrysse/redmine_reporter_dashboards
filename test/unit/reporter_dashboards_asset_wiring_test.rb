# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# F-16 — THE HALF THAT ONLY A BOOTED REDMINE CAN ANSWER.
#
# `spec/reporting/report_run_spec.rb` drives the wiring with the resolver INJECTED through
# `ReportRun`'s port, because the production factory reads `Setting.protocol`,
# `Setting.host_name` and the plugin settings, and because the boot file that defines it
# cannot be loaded in a DB-less process (it needs ActiveSupport). So exactly three things
# are left over, and all three are the kind this project has shipped broken before:
#
#   * `RedmineReporterDashboards.asset_resolver` — the factory itself. A port that is never
#     defaulted is a port whose default is untested, which is how `Assets::Resolver` came to
#     exist for three tasks with NO CALL SITE AT ALL (§Findings S-28).
#   * `AttachmentMapper` — it needs a real `Attachment`, a real container and a real
#     `visible?`. HANDOVER: *"a double cannot fail an index"*, and it cannot fail a
#     visibility rule either.
#   * the whole path, end to end, against a real `Template` and a real `Issue` scope.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run, and the file reports fewer
# runs than it defines while nothing fails. The `private` section here is at the BOTTOM and
# there is nothing below it. If you add a test, add it above.
class ReporterDashboardsAssetWiringTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers,
           :attachments

  Assets = RedmineReporterDashboards::Assets
  Template = RedmineReporterDashboards::Template
  ReportRun = RedmineReporterDashboards::Reporting::ReportRun
  AttachmentMapper = RedmineReporterDashboards::Reporting::AttachmentMapper

  # Over `Renderer::MIN_PDF_BYTES` — the wrapper refuses anything at or under it as
  # `:output_empty`, so a short string would fail every test here for the wrong reason.
  PDF_BYTES = "%PDF-1.4\n#{'0' * 2_000}\n%%EOF"

  # A one-pixel PNG, so a symlink target is a real image rather than bytes `ContentTypes`
  # would refuse for its own reasons — the containment example must fail on CONTAINMENT.
  module ReportRunFixtures
    PNG = [
      '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489',
      '0000000a49444154789c6360000002000100ffff03000006000557bfabd4',
      '0000000049454e44ae426082'
    ].join.scan(/../).map { |pair| pair.to_i(16) }.pack('C*')
  end

  # AN ENGINE THAT DECLARES `:asset_inline`, which is what both shipped adapters declare.
  # It records the request it was handed, because the request's BODY is the whole question:
  # before F-16 it carried `src="/attachments/download/16/testfile.png"` verbatim and the
  # engine — denied a credential by INV-8 — drew nothing there.
  class RecordingEngine
    class << self
      attr_accessor :requests
    end

    def capabilities
      %i[asset_inline]
    end

    def id
      'recording'
    end

    def render(request)
      # `RecordingEngine.requests` and NOT `self.class.requests`: a class-level
      # accessor is per class, so every subclass below would silently record into its
      # own nil and every assertion about the request would fail as `nil.body`.
      RecordingEngine.requests << request
      RedmineReporterDashboards::Render::Success.new(
        bytes: PDF_BYTES, engine: 'recording', engine_version: '1.0'
      )
    end
  end

  # AN ENGINE WHOSE `#capabilities` RAISES. `Render::Registry` is open, so this is an
  # ordinary third-party adapter as far as `ReportRun` is concerned.
  class RaisingEngine < RecordingEngine
    def capabilities
      raise 'engine exploded while being asked'
    end

    def id
      'raising'
    end
  end

  # Counts how many times it is INSTANTIATED, which is the claim — one adapter object per
  # run, shared by the asset binding and the renderer.
  class CountingEngine < RecordingEngine
    class << self
      attr_accessor :instances
    end

    def initialize
      self.class.instances = (self.class.instances || 0) + 1
      super
    end

    def id
      'counting'
    end
  end

  def setup
    # The fixture PNG lives under `test/fixtures/files`, and `Attachment#diskfile` joins
    # `storage_path` with the row's own directory — so pointing storage at the fixtures
    # tree is what makes attachment 16 a real file rather than a row about one.
    set_fixtures_attachments_directory
    RecordingEngine.requests = []
    CountingEngine.instances = 0

    @project = Project.find(3)
    @project.enable_module!(:reporter_dashboards_reports)
    @actor = User.find_by!(login: 'jsmith')
    # `visible?` on an Issue attachment is `container.attachments_visible?`, which reads
    # `:view_issues` — grant it explicitly rather than inheriting whatever the fixture
    # role happens to carry (T-32's review: a `grant` that replaces the set is what makes
    # "holds ONE permission" readable, and it also drops the ones a scope depends on).
    Role.find(1).tap do |role|
      role.permissions = %w[view_issues view_reporter_dashboards_reports]
      # `issues_visibility` IS PINNED, and the first version of this file did not pin it.
      # Fixture role 1 is Manager and ships `issues_visibility: all`, so jsmith could see
      # every private issue in every project he is a member of — and the two examples whose
      # whole subject is an attachment the actor may NOT see were measured VACUOUS because
      # of it (their preconditions failed, which is the only reason it was caught). A
      # permission grant is not a visibility setting; this is the second half.
      role.issues_visibility = 'default'
      role.save!
    end
    Member.create!(project: @project, principal: @actor, roles: [Role.find(1)])

    @template = Template.create!(project: @project, author: @actor, name: 'Assets',
                                 content: '<p>replaced per test</p>', source: 'issues',
                                 output: 'combined')
  end

  # CREATES AN ATTACHMENT, SO IT OWNS THE STORE. `set_fixtures_attachments_directory` is
  # right for READING attachment 16 — a committed fixture — and wrong for writing, because
  # transactional fixtures roll back the ROW and leave the BYTES in the Redmine checkout for
  # ever. An independent QA pass counted 227 orphans there before this was fixed.
  def created_attachment(container:, author:, file: "testfile.txt", type: "text/plain")
    set_tmp_attachments_directory
    Attachment.create!(container: container, author: author,
                       file: uploaded_test_file(file, type))
  end

  # --- the factory ---------------------------------------------------------------------

  def test_the_factory_builds_a_resolver_carrying_the_engine_capabilities_it_was_given
    resolver = RedmineReporterDashboards.asset_resolver(engine_capabilities: %i[asset_inline])

    assert_equal %i[asset_inline], resolver.engine_capabilities
    assert resolver.inline?, 'an engine declaring :asset_inline must resolve as inlining'
    assert_not resolver.upload?
  end

  def test_the_factory_defaults_to_the_bundled_policy_on_an_unconfigured_install
    resolver = RedmineReporterDashboards.asset_resolver(engine_capabilities: [])

    assert_equal :bundled, resolver.policy.effective_mode
  end

  # THE FETCHER IS NOT BUILT UNDER `:bundled`, and it is asserted through the OBSERVABLE
  # rather than by reaching for the ivar: under `:bundled` a third-party URL is refused for
  # a POLICY reason, and the refusal wording differs from the "no fetcher was supplied" one.
  # Both are reachable and only one of them is correct here.
  def test_the_bundled_policy_refuses_a_third_party_url_for_a_policy_reason
    with_settings plugin_redmine_reporter_dashboards: { 'asset_policy' => 'bundled' } do
      resolution = resolve('<img src="https://cdn.example.net/a.png">')

      assert resolution.refused?
      reason = resolution.refusals.first.reason
      assert_includes reason, 'asset_policy'
      assert_not_includes reason, 'no fetcher was supplied',
                          'a fetcher must not be constructed under :bundled, and the ' \
                          'refusal must name the policy rather than a missing collaborator'
    end
  end

  # THE EMPTY-ALLOWLIST COLLAPSE, which T-33 calls the fail-closed clause most likely to be
  # got wrong — and it decides whether a fetcher is built, so it is asserted HERE and not
  # only against `Policy`.
  def test_an_upgraded_mode_with_an_empty_allowlist_still_gets_no_fetcher
    with_settings plugin_redmine_reporter_dashboards: { 'asset_policy' => 'external',
                                                        'asset_allowlist' => '' } do
      # THE ASSERTION THIS TEST'S NAME PROMISES, and the first version did not make it.
      # It checked only the refusal WORDING — which `Resolver#fetched` decides by consulting
      # `policy.fetch_allowed?` BEFORE it looks at `@fetcher`, so the wording is identical
      # whether or not a fetcher was built. An independent review mutated
      # `asset_fetch_possible?` to `policy.mode != :bundled` — under which a collapsed
      # `:external` policy DOES construct the plugin's only egress object while failing
      # closed — and the mutation SURVIVED all three suites. The construction claim needs a
      # construction assertion, exactly as the raw-`:bundled` case above.
      Assets::Fetcher.expects(:new).never

      resolution = resolve('<img src="https://cdn.example.net/a.png">')

      assert resolution.refused?
      assert_not_includes resolution.refusals.first.reason, 'no fetcher was supplied'
      assert_equal :bundled,
                   RedmineReporterDashboards.asset_resolver(engine_capabilities: [])
                                            .policy.effective_mode
    end
  end

  # THE OTHER DIRECTION, and without it `asset_fetch_possible?` could answer `false`
  # always and nothing would notice — the report would still be refused, just for a reason
  # that names a missing collaborator instead of the network.
  #
  # `.invalid` is reserved by RFC 6761 and is guaranteed never to resolve, so this makes NO
  # real network request and cannot become flaky on a host with or without egress: the
  # fetcher refuses at DNS. What is asserted is which of the two refusal WORDINGS comes
  # back, which is the only thing that distinguishes "a fetcher was built" from "one was
  # not" when the fetch is going to fail either way.
  def test_an_allowlisted_host_gets_a_fetcher_rather_than_a_missing_collaborator
    with_settings plugin_redmine_reporter_dashboards: {
      'asset_policy' => 'external', 'asset_allowlist' => 'no-such-host.invalid'
    } do
      resolver = RedmineReporterDashboards.asset_resolver(engine_capabilities: %i[asset_inline])
      resolution = resolver.call('<img src="https://no-such-host.invalid/a.png">')


      # THE MODE THE OPERATOR CONFIGURED REALLY REACHED THE RESOLVER. Asserted directly,
      # and it is not redundant: without it, a factory that ignored the settings entirely
      # and always built `Policy.bundled` passed every other example in this file —
      # measured, as mutation M03, which SURVIVED the first version of this test. An
      # install configured for external assets would have silently had none.
      assert_equal :external, resolver.policy.effective_mode
      assert_equal ['no-such-host.invalid'], resolver.policy.allowlist

      assert resolution.refused?, 'a host that cannot resolve must still be refused'
      reason = resolution.refusals.first.reason
      assert_not_includes reason, 'no fetcher was supplied',
                          'the policy permits this fetch, so a fetcher must have been built'
      # AND IT WAS REFUSED BY THE NETWORK, NOT BY THE POLICY — the other half of the same
      # discrimination. Under `:bundled` this URL is refused before any fetcher is
      # consulted, and the reason says `asset_policy`; here the fetch was attempted and
      # DNS refused it.
      assert_not_includes reason, 'asset_policy',
                          'an allowlisted host under :external must not be refused by policy'
    end
  end

  # THE CLAIM IS ABOUT CONSTRUCTION, SO THE ASSERTION HAS TO BE ABOUT CONSTRUCTION.
  #
  # Mutation M01 — "build a fetcher even when the policy forbids one" — SURVIVED every
  # behavioural test, and it was proved equivalent rather than assumed: the same document
  # carrying all five reference classifications was resolved with a fetcher and without
  # one under `:bundled`, and `Resolution#to_h` was IDENTICAL, because `Resolver#fetched`
  # consults `policy.fetch_allowed?` before it ever looks at `@fetcher`.
  #
  # So there is no behavioural signature, and the property is still worth holding: INV-8 is
  # *the renderer is never the thing holding the network*, and under the default policy the
  # object that opens sockets should not be built at all. HANDOVER's rule for exactly this
  # shape — "a full-row write and a two-column write leave an identical row behind, so the
  # claim has to be made about the STATEMENT" — applies one layer over: the claim has to be
  # made about the CONSTRUCTOR. Without these two, the guard would be a comment.
  def test_no_fetcher_is_constructed_under_the_default_bundled_policy
    with_settings plugin_redmine_reporter_dashboards: { 'asset_policy' => 'bundled' } do
      Assets::Fetcher.expects(:new).never

      RedmineReporterDashboards.asset_resolver(engine_capabilities: %i[asset_inline])
    end
  end

  # AND THE POSITIVE HALF, or `expects(:new).never` would also pass against a factory that
  # never builds one at all — which is mutation M02, and it must not be killed twice by
  # accident while this one goes untested.
  def test_a_fetcher_is_constructed_once_the_policy_permits_a_fetch
    with_settings plugin_redmine_reporter_dashboards: {
      'asset_policy' => 'external', 'asset_allowlist' => 'assets.example.com'
    } do
      Assets::Fetcher.expects(:new).once.returns(nil)

      RedmineReporterDashboards.asset_resolver(engine_capabilities: %i[asset_inline])
    end
  end

  # --- the attachment mapper -----------------------------------------------------------

  def test_the_mapper_answers_the_diskfile_for_an_attachment_the_actor_may_see
    attachment = Attachment.find(16)
    assert attachment.visible?(@actor), 'precondition: the actor must be able to see it'

    mapped = AttachmentMapper.new(actor: @actor).call('/attachments/download/16/testfile.png')

    assert_equal attachment.diskfile, mapped
    assert File.file?(mapped), 'the fixture file must really be on disk'
  end

  def test_the_mapper_accepts_the_download_route_without_a_filename
    mapped = AttachmentMapper.new(actor: @actor).call('/attachments/download/16')

    assert_equal Attachment.find(16).diskfile, mapped
  end

  # THE INVISIBLE ROW IS BUILT, NOT BORROWED. HANDOVER §1: the first version of a test like
  # this took a fixture issue from another project, and fixture project 5 is PUBLIC, so the
  # negative half was vacuous. The rule that hides this one is a rule this test sets, and
  # the precondition is asserted anyway.
  def test_the_mapper_refuses_an_attachment_the_actor_may_not_see
    hidden = Issue.create!(project: Project.find(1), tracker: Tracker.find(1),
                           author: User.find_by!(login: 'dlopper'), subject: 'private',
                           is_private: true, status: IssueStatus.first,
                           priority: IssuePriority.first)
    attachment = created_attachment(container: hidden, author: User.find_by!(login: 'dlopper'))
    assert_not attachment.visible?(@actor),
               'precondition: this attachment must really be invisible to the actor'

    assert_nil AttachmentMapper.new(actor: @actor).call("/attachments/download/#{attachment.id}")
  end

  # THE SAME ATTACHMENT, TWO ACTORS. Without this the example above passes if the mapper
  # answered nil for everybody — which is exactly what a mapper with a typo in its regexp
  # does, and it would look like a working security control.
  def test_the_same_attachment_resolves_for_an_actor_who_may_see_it
    hidden = Issue.create!(project: Project.find(1), tracker: Tracker.find(1),
                           author: User.find_by!(login: 'dlopper'), subject: 'private',
                           is_private: true, status: IssueStatus.first,
                           priority: IssuePriority.first)
    attachment = created_attachment(container: hidden, author: User.find_by!(login: 'dlopper'))

    assert_nil AttachmentMapper.new(actor: @actor).call("/attachments/download/#{attachment.id}")
    assert_equal attachment.diskfile,
                 AttachmentMapper.new(actor: User.find(1)).call(
                   "/attachments/download/#{attachment.id}"
                 )
  end

  def test_the_mapper_answers_nil_for_an_id_that_does_not_exist
    assert_nil AttachmentMapper.new(actor: @actor).call('/attachments/download/999999')
  end

  # THE ROUTES THAT ARE NOT THE FILE. `/attachments/:id/:filename` is `attachments#show`, an
  # HTML page ABOUT the file, and `/attachments/thumbnail/:id` names a DERIVED image.
  # Answering the original's bytes for either would put something other than what the URL
  # asked for into the document, silently. They become named refusals instead.
  def test_the_mapper_declines_the_show_and_thumbnail_routes
    mapper = AttachmentMapper.new(actor: @actor)

    assert_nil mapper.call('/attachments/16/testfile.png')
    assert_nil mapper.call('/attachments/thumbnail/16')
    assert_nil mapper.call('/attachments/thumbnail/16/200')
  end

  def test_the_mapper_declines_anything_that_is_not_an_attachment_path
    mapper = AttachmentMapper.new(actor: @actor)

    assert_nil mapper.call('/plugin_assets/redmine_reporter_dashboards/stylesheets/x.css')
    assert_nil mapper.call('/attachments/download/16/evil/../../../etc/passwd')
    assert_nil mapper.call('/attachments/download/abc')
    assert_nil mapper.call('')
  end

  # A LOCKED ACCOUNT IS HOW REDMINE OFFBOARDS SOMEBODY, and `Attachment#visible?` cannot
  # see it — `AttachmentsController#download` is unreachable for a locked user only because
  # authentication rejects the request first, and a render has no such gate.
  def test_the_mapper_refuses_a_locked_actor
    locked = User.find_by!(login: 'dlopper')
    hidden = Issue.create!(project: Project.find(1), tracker: Tracker.find(1),
                           author: locked, subject: 'own', is_private: true,
                           status: IssueStatus.first, priority: IssuePriority.first)
    attachment = created_attachment(container: hidden, author: locked)
    # The precondition IS the discriminator: while active, this actor resolves it. Without
    # this half the example passes against a mapper that refuses dlopper for any reason.
    assert_equal attachment.diskfile,
                 AttachmentMapper.new(actor: locked).call(
                   "/attachments/download/#{attachment.id}"
                 )

    locked.lock!
    assert locked.reload.locked?, 'precondition: the account must really be locked'

    assert_nil AttachmentMapper.new(actor: locked).call(
      "/attachments/download/#{attachment.id}"
    )
  end

  # ANONYMOUS IS NOT LOCKED, and refusing it would be a regression dressed as a rule: a
  # public report must still embed a public project's attachments. This is why the guard
  # asks `locked?` rather than `!active?` — `AnonymousUser` fails the second.
  def test_the_mapper_does_not_refuse_anonymous_along_with_locked_accounts
    # THIS EXAMPLE USED TO ASSERT `assert_nothing_raised`, WHICH IS TRUE OF BOTH ANSWERS.
    # Mutating the guard from `locked?` to `!active?` — which refuses Anonymous, because
    # `AnonymousUser` is not active — SURVIVED it. So the example now requires Anonymous to
    # really RESOLVE something, which is the only observation that separates the two.
    public_project = Project.find(1)
    public_project.update!(is_public: true)
    Role.anonymous.tap do |role|
      role.permissions = %w[view_issues]
      role.save!
    end
    issue = Issue.create!(project: public_project, tracker: Tracker.find(1), author: @actor,
                          subject: 'public', status: IssueStatus.first,
                          priority: IssuePriority.first)
    set_tmp_attachments_directory
    attachment = created_attachment(container: issue, author: @actor)
    assert attachment.visible?(User.anonymous),
           'precondition: Anonymous must genuinely be allowed to see this attachment'

    assert_equal attachment.diskfile,
                 AttachmentMapper.new(actor: User.anonymous).call(
                   "/attachments/download/#{attachment.id}"
                 )
  end

  # CONTAINMENT FOR A MAPPER RESULT. `LocalStore` skips its `realpath` check for mapper
  # answers by design, so a symlink inside the attachment store pointing out of it was read
  # and inlined — measured, with only "must have a typeable extension" standing in the way
  # of `/etc/passwd`.
  #
  # A TEMPORARY STORE, AND NOT THE FIXTURES DIRECTORY. The first version of this example
  # symlinked over attachment 16's real diskfile — a file that is COMMITTED TO THE REDMINE
  # CHECKOUT and used by other tests, which its own `ensure` would then have deleted. Any
  # test that mutates the attachment store has to own the store.
  def test_the_mapper_refuses_a_diskfile_that_resolves_outside_the_attachment_store
    set_tmp_attachments_directory
    Dir.mktmpdir do |outside|
      target = File.join(outside, 'secret.png')
      File.binwrite(target, ReportRunFixtures::PNG)

      attachment = created_attachment(container: Issue.find(1), author: @actor)
      FileUtils.rm_f(attachment.diskfile)
      FileUtils.ln_s(target, attachment.diskfile)
      assert File.exist?(attachment.diskfile), 'precondition: the symlink must resolve'
      assert_equal File.realpath(target), File.realpath(attachment.diskfile),
                   'precondition: the diskfile really points outside the store'

      assert_nil AttachmentMapper.new(actor: @actor).call(
        "/attachments/download/#{attachment.id}"
      )
    end
  end

  def test_the_mapper_refuses_to_be_built_without_an_actor
    error = assert_raises(ArgumentError) { AttachmentMapper.new(actor: nil) }

    assert_includes error.message, 'INV-1'
  end

  # --- end to end ----------------------------------------------------------------------

  # THE ACCEPTANCE CRITERION, against a real Redmine: an image referenced by a same-origin
  # URL is IN the document. Both halves are asserted, because either alone passes for the
  # wrong reason — bytes present would pass if the resolver appended rather than replaced,
  # and the URL being gone would pass if it had deleted the element.
  def test_an_attachment_image_reaches_the_engine_as_bytes_rather_than_a_url
    request = render_body('<p><img src="/attachments/download/16/testfile.png"></p>')

    assert_includes request.body, 'data:image/png;base64,'
    assert_not_includes request.body, '/attachments/download/16'
  end

  def test_a_plugin_asset_url_reaches_the_engine_as_bytes_rather_than_a_url
    path = '/plugin_assets/redmine_reporter_dashboards/stylesheets/' \
           'redmine_reporter_dashboards.css'
    request = render_body(%(<p><link rel="stylesheet" href="#{path}"></p>))

    assert_not_includes request.body, path
    # A stylesheet is inlined STRUCTURALLY — the element is replaced by a `<style>` block —
    # which is §5.1's own wording and the form every engine accepts.
    assert_includes request.body, '<style'
  end

  # THE ABSOLUTE FORM OF THE SAME URL. `Setting.host_name` is what makes it same-origin, and
  # `Origin` is the only thing that knows — this is the assertion that would fail if the
  # factory stopped reading it, which it would otherwise do silently by treating every
  # absolute URL as third-party and refusing the report.
  def test_an_absolute_same_origin_url_is_recognised_as_this_install
    with_settings host_name: 'redmine.example', protocol: 'https' do
      request = render_body(
        '<p><img src="https://redmine.example/attachments/download/16/testfile.png"></p>'
      )

      assert_includes request.body, 'data:image/png;base64,'
    end
  end

  # A THIRD-PARTY URL UNDER `:bundled` IS A TYPED FAILURE NAMING THE URL, and NOT a blank
  # image — T-33's words, finally on the path that reaches a reader.
  def test_a_third_party_url_is_a_named_failure_and_no_document_is_drawn
    outcome = render('<p><img src="https://cdn.example.net/tracker.png"></p>')

    assert_not outcome.ok?
    assert_equal :asset_unresolved, outcome.diagnostic.code
    assert_equal :assets, outcome.diagnostic.origin
    assert_includes outcome.diagnostic.message, 'https://cdn.example.net/tracker.png'
    assert_empty RecordingEngine.requests, 'no engine may run for a document that was refused'
  end

  # AN ATTACHMENT THE VIEWER MAY NOT SEE IS REFUSED, NOT EMBEDDED — the mapper's visibility
  # decision, observed through the whole pipeline rather than at the mapper. This is the one
  # that would matter if `visible?` were ever dropped: the bytes would travel into a PDF
  # that a person without the permission is holding.
  def test_an_invisible_attachment_is_refused_by_the_whole_pipeline
    hidden = Issue.create!(project: Project.find(1), tracker: Tracker.find(1),
                           author: User.find_by!(login: 'dlopper'), subject: 'private',
                           is_private: true, status: IssueStatus.first,
                           priority: IssuePriority.first)
    attachment = created_attachment(container: hidden, author: User.find_by!(login: 'dlopper'))
    assert_not attachment.visible?(@actor), 'precondition: really invisible'

    outcome = render(%(<p><img src="/attachments/download/#{attachment.id}"></p>))

    assert_not outcome.ok?
    assert_equal :asset_unresolved, outcome.diagnostic.code
  end

  # THE HTML PATH — the surface an author looks at FIRST, and the one F-16's first version
  # left showing blank images. `#show` runs `call(pdf: false)`, and the body goes into an
  # `srcdoc` iframe whose CSP is `img-src data:`, so a URL of any kind is blocked by the
  # sandbox and draws nothing. Both halves asserted: the bytes are there AND the URL is
  # gone, because either alone passes for the wrong reason.
  def test_the_html_path_inlines_images_too_because_the_sandbox_blocks_every_url
    outcome = render_html('<p><img src="/attachments/download/16/testfile.png"></p>')

    assert outcome.ok?, "expected a rendered report, got #{outcome.diagnostic&.message.inspect}"
    assert_includes outcome.sections.first.body, 'data:image/png;base64,'
    assert_not_includes outcome.sections.first.body, '/attachments/download/16'
  end

  # AND THE HTML PATH REFUSES WHAT THE PDF PATH REFUSES. One surface silently dropping an
  # image while the other refuses the report would be two answers to one question.
  def test_the_html_path_refuses_a_third_party_url_as_the_pdf_path_does
    outcome = render_html('<p><img src="https://cdn.example.net/tracker.png"></p>')

    assert_not outcome.ok?
    assert_equal :asset_unresolved, outcome.diagnostic.code
    assert_equal :assets, outcome.diagnostic.origin
  end

  # AN HTML RUN STILL DRAWS NO PDF. Resolving on this path must not have quietly started an
  # engine — `pdf_attempted?` is what the diagnostics panel reads to decide what to say.
  def test_the_html_path_starts_no_engine
    outcome = render_html('<p><img src="/attachments/download/16/testfile.png"></p>')

    assert_not outcome.pdf_attempted?
    assert_empty RecordingEngine.requests
  end

  # THE RUN-LEVEL BYTE BUDGET (G6). `Resolver`'s 32 MiB is PER DOCUMENT, and every request
  # is built before the first is drawn — so 50 documents could hold 1.6 GiB resident, on a
  # request any member can make. Driven by lowering the constant rather than by building a
  # gigabyte: the branch is the claim, and a test that really allocated 128 MB would be one
  # nobody runs.
  def test_a_run_whose_embedded_files_exceed_the_budget_is_refused
    with_run_budget(200) do
      outcome = render('<p><img src="/attachments/download/16/testfile.png"></p>')

      assert_not outcome.ok?
      assert_equal :resource_limit, outcome.diagnostic.code
      assert_empty RecordingEngine.requests, 'nothing may be drawn once the budget is spent'
    end
  end

  # AND IT NAMES BOTH NUMBERS, the same rule the cap refusal follows: a limit message that
  # does not say what the limit is leaves a reader unable to tell "slightly too big" from
  # "absurd".
  def test_the_budget_refusal_names_the_size_and_the_limit
    # TWO DISTINCT NUMBERS, and the first version could not tell them apart. It drove a
    # 200-byte budget, where the spent size and the limit both round to `0 MB` — so a
    # mutation that deleted the SIZE from the message and kept the LIMIT survived both
    # assertions. A body big enough to separate them is the only fixture that discriminates.
    body = "<p>#{'x' * 3_000_000}</p>"
    with_run_budget(1024 * 1024) do
      outcome = render(body)

      assert_not outcome.ok?
      assert_includes outcome.diagnostic.message, '2 MB', 'the SIZE must be named'
      assert_includes outcome.diagnostic.message, '1 MB', 'the LIMIT must be named'
    end
  end

  # AT the budget is allowed and one past it is not — the AT-and-one-past pair CLAUDE.md
  # §3 asks for on anything with a limit. Driven at the byte.
  #
  # THE BUDGET IS MEASURED ON THE DOCUMENT, NOT ON THE TEMPLATE'S OUTPUT, and T-38 is why
  # this example changed. `ReportRun#pdf_document` wraps each rendered body in the
  # standalone document the engine actually receives — a doctype, a head and the report
  # stylesheet — and `MAX_RUN_ASSET_BYTES` counts what the engine receives, which is the
  # number the limit exists to bound. So the size this example has to be exact about is
  # `ReportDocument.wrap(body).bytesize`, and computing it that way keeps the pair exact
  # instead of leaving a few kilobytes of slack that would make "one past" untestable.
  #
  # It is derived rather than hard-coded for the reason every number in this file is: a
  # literal would need editing whenever the stylesheet grows a rule, and somebody would
  # eventually "fix" it by widening the budget, which is exactly the assertion this
  # example is.
  def test_the_budget_admits_a_run_exactly_at_the_limit
    body = '<p>no assets at all</p>'
    document_bytes = RedmineReporterDashboards::ReportDocument.wrap(body).bytesize
    assert document_bytes > body.bytesize,
           'precondition: the engine receives a whole document, not the raw body'

    with_run_budget(document_bytes) do
      assert render(body).ok?, 'a run exactly at the budget must be allowed'
    end
    with_run_budget(document_bytes - 1) do
      outcome = render(body)

      assert_not outcome.ok?
      assert_equal :resource_limit, outcome.diagnostic.code
    end
  end

  # E-26 #4, curator decision 2026-08-10: A DOCUMENT PAST THE REFERENCE CAP IS TOLD IT IS
  # TOO BIG, not that its URLs could not be resolved. The old message was true of the
  # mechanism and false as an explanation — nothing is wrong with those URLs, each would
  # resolve alone, and the remedy is to reference fewer rather than to fix any of them.
  def test_a_document_past_the_reference_cap_is_told_it_is_too_big
    over = RedmineReporterDashboards::Assets::Resolver::MAX_REFERENCES + 5
    body = "<p>#{'<img src="/plugin_assets/redmine_reporter_dashboards/x.png">' * over}</p>"

    outcome = render(body)

    assert_not outcome.ok?
    assert_equal :resource_limit, outcome.diagnostic.code
    assert_includes outcome.diagnostic.message, 'too big'
    # NOT the old sentence, and NOT a list of URLs: past the cap there are hundreds, and
    # naming five with "and 900 more" tells a reader nothing they can act on.
    assert_not_includes outcome.diagnostic.message, 'could not be resolved'
    assert_not_includes outcome.diagnostic.message, 'asset policy'
  end

  # AND A DOCUMENT UNDER THE CAP WITH ONE BAD URL STILL GETS THE RESOLUTION MESSAGE. Without
  # this the example above passes against an implementation that says "too big" always.
  def test_a_document_under_the_cap_still_names_the_url_it_could_not_resolve
    outcome = render('<p><img src="https://cdn.example.net/tracker.png"></p>')

    assert_equal :asset_unresolved, outcome.diagnostic.code
    assert_includes outcome.diagnostic.message, 'https://cdn.example.net/tracker.png'
    assert_not_includes outcome.diagnostic.message, 'too big'
  end

  # E-26 #9: A FAILURE STILL HAS DEGRADATIONS TO REPORT, and they used to be dropped.
  # `_degradations.html.erb` renders on the failure page too, deliberately, so this was a
  # panel with nothing in it — a run that collapsed an `srcset` before hitting a CDN lost
  # the first fact entirely.
  def test_a_failed_run_still_carries_the_degradations_it_collected
    @template.update!(output: 'per_record')
    bodies = ['<p><img srcset="/attachments/download/16/testfile.png 1x, ' \
              '/attachments/download/16/testfile.png 2x"></p>',
              '<p><img src="https://cdn.example.net/tracker.png"></p>']

    outcome = render_per_record(bodies)

    assert_not outcome.ok?
    assert_includes outcome.degradations.map(&:capability), :asset_srcset_collapsed
  end

  # A REPORT WITH NO ASSETS IS UNCHANGED, which is what stops this being a change to every
  # report in the installation. The body reaches the engine byte for byte.
  def test_a_document_with_no_references_reaches_the_engine_untouched
    request = render_body('<p>nothing to resolve here</p>')

    assert_includes request.body, '<p>nothing to resolve here</p>'
    assert_empty request.assets
  end

  # AN ADAPTER THAT RAISES WHEN ASKED A QUESTION MUST NOT TAKE THE REQUEST OUT (INV-5).
  # `Render::Registry` is open, and F-16 introduced the first call to `#capabilities` that
  # is NOT wrapped by `Renderer` — so before this guard a third-party engine turned an
  # asset-free report, which used to render perfectly, into a 500. Found by an independent
  # QA pass.
  def test_an_engine_that_raises_when_asked_for_capabilities_does_not_escape_the_run
    outcome = nil
    assert_nothing_raised do
      outcome = render('<p>plain, not one asset reference</p>', engine: RaisingEngine)
    end

    # A TYPED DIAGNOSTIC, NOT A RAISE — which is the whole claim (INV-5). It is not `ok?`,
    # and the first version of this example asserted that it would be: `Renderer` asks the
    # same broken adapter for its capabilities when it negotiates, so the run legitimately
    # fails one stage later. That is the right outcome and it arrives through
    # `safe_capabilities`, which has rescued this since T-10 — the hole F-16 opened was the
    # ONE call outside `Renderer`, and this asserts it is closed rather than asserting a
    # broken engine somehow works.
    assert_not outcome.ok?
    assert_not_nil outcome.diagnostic
    assert_includes RedmineReporterDashboards::Reporting::Diagnostic::ORIGINS,
                    outcome.diagnostic.origin
  end

  # AND THE FAIL-CLOSED HALF: the same broken adapter must refuse a reference by NAME
  # rather than passing the URL through to an engine that cannot embed it. Without this,
  # `rescue => []` would look identical to "declare everything".
  def test_a_raising_engine_refuses_references_by_name_rather_than_passing_them_through
    outcome = render('<p><img src="/attachments/download/16/testfile.png"></p>',
                     engine: RaisingEngine)

    assert_not outcome.ok?
    assert_equal :asset_unresolved, outcome.diagnostic.code
    assert_equal :assets, outcome.diagnostic.origin
  end

  # FR-58: the id in the panel is the id in the log line. A mutation nulling
  # `correlation_id` in `bind_assets` survived an independent review's harness, because
  # nothing downstream of the binding asserted it.
  def test_the_request_carries_the_section_correlation_id
    request = render_body('<p>no assets</p>')

    assert request.correlation_id.to_s.length > 8,
           "expected a minted correlation id, got #{request.correlation_id.inspect}"
    assert_not_equal 'batch', request.correlation_id
  end

  # ONE ENGINE INSTANCE, shared by the asset binding and the renderer. Two would mean two
  # `ProcessPool`s for `:chromium_cdp` and a capability answer from a different object than
  # the one that draws — which the source comment claims and nothing asserted, so a
  # mutation putting `adapter.new` back inline survived.
  def test_the_engine_that_answers_capabilities_is_the_engine_that_draws
    render_body('<p>no assets</p>', engine: CountingEngine)

    assert_equal 1, CountingEngine.instances,
                 'the adapter must be instantiated once per run, not once per collaborator'
  end

  # A PER-RECORD RUN WHERE A LATER DOCUMENT REFUSES. The only multi-document asset example
  # used a body with no references at all, so the loop's failure branch was never taken
  # past the first section — and a mutation that aborted only on the FIRST section's
  # refusal survived, pushing a `Render::Failure` into the request list where
  # `Renderer#render` met it as a `NoMethodError`.
  def test_a_refusal_in_a_later_document_refuses_the_whole_run
    @template.update!(output: 'per_record')
    bodies = ['<p><img src="/attachments/download/16/testfile.png"></p>',
              '<p><img src="https://cdn.example.net/tracker.png"></p>']
    outcome = render_per_record(bodies)

    assert_not outcome.ok?
    assert_equal :asset_unresolved, outcome.diagnostic.code
    assert_includes outcome.diagnostic.message, 'https://cdn.example.net/tracker.png'
    assert_empty RecordingEngine.requests,
                 'nothing may be drawn when any document in the run was refused'
  end

  private

  def resolve(html)
    RedmineReporterDashboards.asset_resolver(engine_capabilities: %i[asset_inline]).call(html)
  end

  def render_body(html, engine: RecordingEngine)
    outcome = render(html, engine: engine)
    assert outcome.ok?, "expected a successful run, got #{outcome.diagnostic&.message.inspect}"
    RecordingEngine.requests.first
  end

  # `pdf: false` — what `TemplatesController#show` calls. No engine is registered at all,
  # deliberately: this path must not need one, and if it ever starts one the run would fail
  # here rather than quietly acquiring a dependency.
  def render_html(html)
    @template.update!(content: html)
    ReportRun.new(template: @template, actor: @actor,
                  scope: Issue.visible(@actor).where(project_id: @project.id),
                  guard: RedmineReporterDashboards::Render::BatchGuard.new(max_documents: 5))
             .call(pdf: false)
  end

  def render(html, engine: RecordingEngine)
    @template.update!(content: html)
    run_with(engine) do
      ReportRun.new(template: @template, actor: @actor,
                    scope: Issue.visible(@actor).where(project_id: @project.id),
                    guard: RedmineReporterDashboards::Render::BatchGuard.new(max_documents: 5))
               .call(pdf: true)
    end
  end

  # A PER-RECORD RUN WHOSE SECTIONS HAVE DIFFERENT BODIES. The Liquid renderer is injected
  # rather than driven through a template, because what is under test is `bind_assets`'
  # loop over several sections — one template cannot produce two different bodies without
  # writing Liquid that would then be the thing being tested.
  def render_per_record(bodies)
    renderer = Class.new do
      def initialize(bodies)
        @bodies = bodies
        @calls = 0
      end

      def render(_source, **_kwargs)
        body = @bodies[@calls] || @bodies.last
        @calls += 1
        RedmineReporterDashboards::Liquid::TemplateRenderer::Document.new(
          body: body, duration_ms: 1, output_class: :report
        )
      end
    end.new(bodies)

    run_with(RecordingEngine) do
      ReportRun.new(template: @template, actor: @actor,
                    scope: Issue.visible(@actor).where(project_id: @project.id),
                    template_renderer: renderer,
                    guard: RedmineReporterDashboards::Render::BatchGuard.new(max_documents: 5))
               .call(pdf: true)
    end
  end

  # DERIVED FROM THE CLASS, never from an instance: `CountingEngine` counts how many
  # times it is built, so constructing one here to ask its id would make the number
  # under test always wrong by one.
  # Lowers `MAX_RUN_ASSET_BYTES` for one example and puts it back. `remove_const` first,
  # because redefining a constant warns and the warning is the kind of noise that trains a
  # reader to ignore warnings.
  def with_run_budget(bytes)
    previous = ReportRun::MAX_RUN_ASSET_BYTES
    ReportRun.send(:remove_const, :MAX_RUN_ASSET_BYTES)
    ReportRun.const_set(:MAX_RUN_ASSET_BYTES, bytes)
    yield
  ensure
    ReportRun.send(:remove_const, :MAX_RUN_ASSET_BYTES)
    ReportRun.const_set(:MAX_RUN_ASSET_BYTES, previous)
  end

  def registry_id(engine)
    engine.name.split("::").last.gsub(/Engine\z/, "").downcase.to_sym
  end

  def run_with(engine)
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(registry_id(engine), engine)
      yield
    end
  end
end
