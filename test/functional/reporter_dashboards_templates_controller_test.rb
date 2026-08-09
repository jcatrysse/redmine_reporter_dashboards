# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-23 — the permission surface, the visibility rules, and T-15's two owed acceptance
# items, against a booted Redmine.
#
# --- WHY THE BULK OF THIS FILE IS NEGATIVE ---
#
# `spec/permissions/permission_map_spec.rb` proves the map is complete and that
# `authorize` is wired to every mapped action. What it cannot prove is what a real role
# holding a real permission actually reaches, and that is where every authorization bug
# in this project has been: T-40's review got past a per-controller check four times with
# ordinary controller code. So each authoring permission is granted ALONE here and the
# actions it must not reach are asserted 403 — including
# `manage_public_reporter_dashboards_templates`, which Redmine's `authorize` lets through
# to `#create` because the permission maps it.
#
# The single most important test in the file is
# `test_edit_own_cannot_edit_a_template_somebody_else_authored`. T-23's `Accept:` calls it
# *"the case that looks right until it is tried"*, because "own" is a property of the
# RECORD and no permission can see one.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods defined after a `private` section are silently not run. This file has no
# `private`; every helper is defined ABOVE the tests and the run count is checked against
# `grep -c '^  def test_'`.
class ReporterDashboardsTemplatesControllerTest < ActionController::TestCase
  # NAMED EXPLICITLY. Rails infers the controller from the test class name, and this
  # controller is namespaced while the test class is not — inference would look for
  # `ReporterDashboardsTemplatesController`, which does not exist.
  tests ReporterDashboards::TemplatesController

  # `Redmine::I18n` because this class calls `l(...)`. §Findings E-21: two of T-33's tests
  # had been ERRORING since they were written for exactly this omission, and the assertion
  # they were supposed to make had never run.
  include Redmine::I18n

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers,
           :queries, :time_entries

  Template = RedmineReporterDashboards::Template

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @jsmith = User.find_by!(login: 'jsmith')
    @dlopper = User.find_by!(login: 'dlopper')
    @role = Role.find(1)
    login_as(@jsmith)
  end

  # ------------------------------------------------------------------ helpers
  #
  # All of them above the tests, deliberately: see the Minitest trap in the class comment.

  def login_as(user)
    @request.session[:user_id] = user.id
  end

  # EXACTLY these permissions and no others. `add_permission!` accumulates, and a test
  # that adds to whatever the fixture role already holds is a test whose subject is the
  # fixture. `:view_issues` is always included because every one of these actions reads
  # `Issue.visible`, and a scope that resolves to nothing would make a 403 and a 200 look
  # the same for the wrong reason.
  def grant(*permissions)
    @role.permissions = ([:view_issues] + permissions).map(&:to_s)
    @role.save!
    User.current = nil
  end

  # `roles:` is assigned BEFORE the save, not after: `Template` copies core's rule that a
  # ROLES-visible record with no roles named is invalid (`app/models/query.rb:276`), so
  # create-then-assign raises on the create.
  def create_template(attributes = {})
    attributes = attributes.dup
    roles = attributes.delete(:roles)
    record = Template.new({ project: @project, author: @jsmith, name: 'Report',
                            content: '<h1>Report</h1>', source: 'issues',
                            output: 'combined' }.merge(attributes))
    record.roles = Array(roles)
    record.save!
    record
  end

  def template_params(overrides = {})
    { name: 'New report', content: '<p>x</p>', output: 'combined',
      orientation: 'portrait', page_size: 'A4', enabled: '1' }.merge(overrides)
  end

  # Drive one action with whatever parameters it needs, so a test can loop over actions
  # rather than repeating twelve near-identical requests.
  def request_action(action, template = nil, extra = {})
    base = { project_id: @project.identifier }.merge(extra)
    base[:id] = template.id if template

    case action
    when :index then get(:index, params: base)
    when :show then get(:show, params: base)
    when :document then get(:document, params: base)
    when :new then get(:new, params: base)
    when :create then post(:create, params: base.merge(template: template_params))
    when :edit then get(:edit, params: base)
    when :update then patch(:update, params: base.merge(template: template_params))
    when :destroy then delete(:destroy, params: base)
    when :export then get(:export, params: base)
    when :preview then post(:preview, params: base.merge(template: template_params))
    when :import then post(:import, params: base.merge(file: uploaded_bundle))
    else raise ArgumentError, "unknown action #{action}"
    end
  end

  def uploaded_bundle(json = nil)
    json ||= { 'format_version' => 1,
               'template' => { 'name' => 'Imported', 'content' => '<p>i</p>' } }.to_json
    Rack::Test::UploadedFile.new(StringIO.new(json), 'application/json',
                                 original_filename: 'bundle.json')
  end

  # T-29 — read the member names out of a streamed archive.
  #
  # Deliberately a reader rather than a call into `ZipStream`: asking the writer what it
  # wrote would compare a value with itself. This walks the central directory the way an
  # unpacker does, which is also what proves the response really is an archive and not a
  # PDF with a `.zip` name on it.
  # RAILS 8.1 DOES NOT MATERIALISE A STREAMING BODY INTO `response.body`, and Rails 7.2
  # does. Found by CI on Redmine 7.0-stable — the only branch in this matrix on Rails 8.1,
  # and therefore the only place this could be found (INV-7, and the reason that job
  # exists). 7.2 hands back a String; 8.1 hands back the body OBJECT, so `.b` was a
  # `NoMethodError` on the two archive tests there while both passed locally.
  #
  # Reading it through `#each` works on both, and it is also the honest way to read a
  # streamed response: it is a sequence of chunks, and only one of the two Rails versions
  # was pretending otherwise.
  def archive_bytes(body)
    return body.b if body.is_a?(String)

    out = +''.b
    body.each { |chunk| out << chunk }
    out
  end

  def zip_members(body)
    bytes = archive_bytes(body)
    eocd = bytes.rindex("PK\x05\x06".b)
    assert_not_nil eocd, 'the response carries no end-of-central-directory record'
    count, _size, offset = bytes[eocd + 10, 10].unpack('vVV')

    cursor = offset
    Array.new(count) do
      assert_equal "PK\x01\x02".b, bytes[cursor, 4], 'not a central directory header'
      name_len, extra_len, comment_len = bytes[cursor + 28, 6].unpack('vvv')
      name = bytes[cursor + 46, name_len]
      cursor += 46 + name_len + extra_len + comment_len
      name.force_encoding(Encoding::UTF_8)
    end
  end

  # 51 issues, so a per-record export is one past `BatchGuard::DEFAULT_MAX_DOCUMENTS`.
  # Built rather than stubbed: the number under test IS the shipped default, and a test
  # that lowers the cap to two proves the mechanism while saying nothing about the cap an
  # installation actually has.
  def create_issues_past_the_cap
    # EXPLICIT ORDER (CLAUDE.md §6): PostgreSQL, MySQL and MariaDB do not agree on
    # unordered row order, and this project runs all three.
    tracker = @project.trackers.order(:id).first
    status = IssueStatus.order(:id).first
    priority = IssuePriority.order(:id).first
    existing = Issue.visible(@jsmith).where(project_id: @project.id).count
    wanted = RedmineReporterDashboards::Render::BatchGuard::DEFAULT_MAX_DOCUMENTS + 1

    ((wanted - existing).clamp(0, wanted)).times do |i|
      Issue.create!(project: @project, tracker: tracker, status: status,
                    priority: priority, author: @jsmith, subject: "capped #{i}")
    end
  end

  # A render adapter that answers a valid-looking PDF. There is no browser in the test
  # environment, so without this the SUCCESS path of `#document` — the one that actually
  # sends bytes — would never be executed by any test, and every `#document` assertion
  # would be about a failure. Over `Renderer::MIN_PDF_BYTES`, and carrying the magic bytes
  # and the trailer, because the real `Render::Renderer` wraps this and enforces both.
  class FakeEngine
    def capabilities
      []
    end

    def id
      'fake'
    end

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: "%PDF-1.4\n#{'0' * 2_000}\n%%EOF", engine: 'fake', engine_version: '1.0'
      )
    end
  end

  # Reads a response body back as text with poppler, or nil when poppler is absent. The
  # ONE assertion in this file that needs it is T-30's safety clause, and it skips naming
  # the package rather than passing vacuously (CLAUDE.md §6): a test that cannot read the
  # document cannot tell a safe one from a leaking one.
  def pdf_text(bytes)
    inspector = RedmineReporterDashboards::Render::PdfInspector
    return nil unless inspector.available?

    inspector.text(bytes)
  end

  # An adapter that always fails, so the `:engine` origin can be driven DETERMINISTICALLY.
  # The obvious way to get an engine failure — register nothing and let the run report
  # "no engine" — is not deterministic: this container has a real Chromium on PATH, so the
  # run reached `engine_crashed` instead of `engine_unavailable` and the first version of
  # `test_an_engine_that_is_not_there_answers_with_a_failure_document_too` failed for a
  # reason that was about the container rather than about the code. CLAUDE.md §6: set it in
  # the test, do not inherit it.
  class FailingEngine
    def capabilities
      []
    end

    def id
      'fake'
    end

    def render(request)
      RedmineReporterDashboards::Render::Failure.new(
        code: :engine_crashed, message: 'the engine stopped before it drew anything',
        engine: 'fake', engine_version: '1.0', duration_ms: 7,
        correlation_id: request.correlation_id,
        detail: 'RuntimeError: PG::UndefinedColumn on members.role_id for project_id 17'
      )
    end
  end

  def with_failing_engine(&block)
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, FailingEngine)
      block.call
    end
  end

  def with_engine(&block)
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, FakeEngine)
      block.call
    end
  end

  # ------------------------------------------------------------------ the module gate

  def test_a_project_without_the_reports_module_404s_rather_than_403s
    grant(:view_reporter_dashboards_reports)
    @project.disable_module!(:reporter_dashboards_reports)

    get :index, params: { project_id: @project.identifier }

    assert_response :not_found
  end

  def test_anonymous_is_refused
    grant(:view_reporter_dashboards_reports)
    @request.session[:user_id] = nil

    get :index, params: { project_id: @project.identifier }

    assert_response :redirect
  end

  # ------------------------------------------------------------------ consuming

  def test_view_permission_reaches_index_and_show
    template = create_template
    grant(:view_reporter_dashboards_reports)

    get :index, params: { project_id: @project.identifier }
    assert_response :success

    get :show, params: { project_id: @project.identifier, id: template.id }
    assert_response :success
  end

  # A SENTINEL, because the project's own name is in the page title, the breadcrumb and
  # the project menu of every page in the project — asserting on it would pass against an
  # empty template body and prove nothing about the Liquid path. Found by the independent
  # review of T-23.
  def test_show_renders_the_template_through_the_owned_liquid_path
    template = create_template(content: '<h1>NAME=[{{ project.name }}]</h1>')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    # Inside the frame's srcdoc attribute, so entity-escaped in the parent document.
    assert_include ERB::Util.html_escape("NAME=[#{@project.name}]"), response.body
  end

  # ------------------------------------------------------------------ INV-9's sandbox
  #
  # `technical-spec.md` §4: the report body is served into a frame carrying
  # `sandbox="allow-scripts"` **without** `allow-same-origin`, so template JavaScript runs
  # in an opaque origin and never in the viewer's session. The independent review of T-23
  # refused the first version of this surface for inlining the body instead, with the
  # escalation written out: an ordinary member holding `edit_own_…` writes a `<script>`
  # that posts to `/users/1/memberships`, makes the template public, and the next
  # administrator to open it runs it.

  def test_the_report_body_is_served_into_a_sandboxed_frame
    template = create_template(content: '<p>hello</p>')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_select 'iframe[sandbox=?]', 'allow-scripts'
  end

  # THE ONE TOKEN THAT MATTERS. `allow-same-origin` turns the sandbox back into the
  # viewer's origin and the whole mechanism into a decoration, so it is asserted by name
  # rather than by asserting the attribute's exact value somewhere else.
  def test_the_frame_never_carries_allow_same_origin
    template = create_template
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_not_include 'allow-same-origin', response.body
  end

  def test_the_sandboxed_document_carries_the_content_security_policy
    template = create_template
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    # Inside the srcdoc attribute, so it arrives entity-escaped in the parent document.
    assert_include ERB::Util.html_escape(
      ReporterDashboards::TemplatesHelper::CONTENT_SECURITY_POLICY
    ), response.body
  end

  # THE ESCALATION ITSELF, driven. A `<script>` in a template body must not appear as
  # executable markup in the viewer's document — it appears as attribute TEXT, escaped,
  # which is what makes the frame a separate document rather than part of this one.
  def test_a_script_in_a_template_never_becomes_markup_in_the_viewers_page
    template = create_template(content: "<script>fetch('/users/1/memberships')</script>")
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_not_include "<script>fetch('/users/1/memberships')</script>", response.body
    assert_include '&lt;script&gt;', response.body
  end

  def test_the_preview_sandboxes_the_body_too
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    post :preview, params: { project_id: @project.identifier,
                             template: template_params(content: '<script>alert(1)</script>') }

    assert_response :success
    assert_select 'iframe[sandbox=?]', 'allow-scripts'
    assert_not_include '<script>alert(1)</script>', response.body
  end

  def test_view_permission_reaches_no_authoring_action
    template = create_template
    grant(:view_reporter_dashboards_reports)

    %i[new create edit update destroy export preview import].each do |action|
      request_action(action, %i[edit update destroy export].include?(action) ? template : nil)
      assert_response :forbidden, "#{action} was reachable with only the view permission"
    end
  end

  # ------------------------------------------------------------------ authoring

  def test_add_permission_creates_a_template
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      post :create, params: { project_id: @project.identifier, template: template_params }
    end
    assert_redirected_to project_reporter_template_path(@project, Template.order(:id).last)
  end

  # THE VIEWS ARE RENDERED BY A TEST OR THEY ARE NOT TESTED. A bare `ERB.new(...).src`
  # syntax check reports a FALSE failure on any view with a block helper (HANDOVER §11),
  # so the only thing that proves `new.html.erb` and `_form.html.erb` compile and render
  # is a request that renders them. These four cover the four branches: the form without
  # the visibility picker, the form with it, and the two failure paths that re-render.
  def test_the_new_form_renders
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    get :new, params: { project_id: @project.identifier }

    assert_response :success
    assert_select 'form#reporter-template-form'
    # Without manage_public the picker is not drawn at all: a disabled control would be
    # showing a decision the reader cannot make.
    assert_select 'input[name=?]', 'template[visibility]', count: 0
    assert_include ERB::Util.html_escape(l(:text_reporter_template_visibility_private_only)), response.body
  end

  def test_the_new_form_draws_the_visibility_picker_for_a_holder_of_manage_public
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :manage_public_reporter_dashboards_templates)

    get :new, params: { project_id: @project.identifier }

    assert_response :success
    assert_select 'input[name=?][value=?]', 'template[visibility]',
                  Template::VISIBILITY_PUBLIC.to_s
    assert_select 'input[name=?]', 'template[role_ids][]'
  end

  def test_an_invalid_create_re_renders_the_form_with_the_errors
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      post :create, params: { project_id: @project.identifier,
                              template: template_params(name: '') }
    end

    assert_response :unprocessable_entity
    assert_select '#errorExplanation'
  end

  def test_an_invalid_update_re_renders_the_editor_with_the_errors
    template = create_template
    grant(:view_reporter_dashboards_reports, :edit_own_reporter_dashboards_templates)

    patch :update, params: { project_id: @project.identifier, id: template.id,
                             template: template_params(name: '') }

    assert_response :unprocessable_entity
    assert_select '#errorExplanation'
    assert_equal 'Report', template.reload.name
  end

  def test_a_created_template_is_authored_by_the_creator_whatever_the_request_says
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    post :create, params: { project_id: @project.identifier,
                            template: template_params.merge(author_id: @dlopper.id,
                                                            project_id: 2) }

    created = Template.order(:id).last
    assert_equal @jsmith.id, created.author_id
    assert_equal @project.id, created.project_id
  end

  # THE HOLE REDMINE'S `authorize` LEAVES OPEN, closed and asserted.
  #
  # `manage_public_…` maps `#new`, `#create`, `#edit` and `#update` — it has to, because
  # that is where the visibility decision is made, and it is core's own shape for
  # `manage_public_queries`. `authorize` is satisfied by ANY mapped permission, so without
  # the controller's second guard this role would reach a code-execution endpoint.
  def test_manage_public_alone_reaches_no_authoring_action
    template = create_template
    grant(:view_reporter_dashboards_reports,
          :manage_public_reporter_dashboards_templates)

    %i[new create].each do |action|
      request_action(action)
      assert_response :forbidden, "#{action} was reachable with only manage_public"
    end

    %i[edit update].each do |action|
      request_action(action, template)
      assert_response :forbidden, "#{action} was reachable with only manage_public"
    end
  end

  def test_edit_own_edits_a_template_you_authored
    template = create_template(author: @jsmith)
    grant(:view_reporter_dashboards_reports,
          :edit_own_reporter_dashboards_templates)

    get :edit, params: { project_id: @project.identifier, id: template.id }
    assert_response :success

    patch :update, params: { project_id: @project.identifier, id: template.id,
                             template: template_params(name: 'Renamed') }
    assert_redirected_to project_reporter_template_path(@project, template)
    assert_equal 'Renamed', template.reload.name
  end

  # THE CASE THAT LOOKS RIGHT UNTIL IT IS TRIED — T-23's `Accept:` says so in as many
  # words. "Own" is `author_id`, and no permission grant can see a record.
  def test_edit_own_cannot_edit_a_template_somebody_else_authored
    template = create_template(author: @dlopper, visibility: Template::VISIBILITY_PUBLIC)
    grant(:view_reporter_dashboards_reports,
          :edit_own_reporter_dashboards_templates)

    get :edit, params: { project_id: @project.identifier, id: template.id }
    assert_response :forbidden

    patch :update, params: { project_id: @project.identifier, id: template.id,
                             template: template_params(name: 'Hijacked') }
    assert_response :forbidden
    assert_equal 'Report', template.reload.name
  end

  def test_edit_own_cannot_delete_or_export_a_template_somebody_else_authored
    template = create_template(author: @dlopper, visibility: Template::VISIBILITY_PUBLIC)
    grant(:view_reporter_dashboards_reports,
          :edit_own_reporter_dashboards_templates)

    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      delete :destroy, params: { project_id: @project.identifier, id: template.id }
    end
    assert_response :forbidden

    get :export, params: { project_id: @project.identifier, id: template.id }
    assert_response :forbidden
  end

  def test_edit_any_edits_a_template_somebody_else_authored
    template = create_template(author: @dlopper, visibility: Template::VISIBILITY_PUBLIC)
    grant(:view_reporter_dashboards_reports, :edit_reporter_dashboards_templates)

    patch :update, params: { project_id: @project.identifier, id: template.id,
                             template: template_params(name: 'Edited by a colleague') }

    assert_redirected_to project_reporter_template_path(@project, template)
    assert_equal 'Edited by a colleague', template.reload.name
  end

  def test_edit_permission_does_not_grant_creating
    grant(:view_reporter_dashboards_reports, :edit_reporter_dashboards_templates)

    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      post :create, params: { project_id: @project.identifier, template: template_params }
    end
    assert_response :forbidden
  end

  # ------------------------------------------------------------------ preview

  def test_preview_needs_an_authoring_permission_because_it_executes_the_request_body
    grant(:view_reporter_dashboards_reports)

    post :preview, params: { project_id: @project.identifier, template: template_params }

    assert_response :forbidden
  end

  def test_preview_renders_the_content_in_the_request_and_writes_nothing
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      post :preview, params: { project_id: @project.identifier,
                               template: template_params(content: '<p>UNSAVED DRAFT</p>') }
    end

    assert_response :success
    assert_include 'UNSAVED DRAFT', response.body
  end

  def test_preview_of_a_saved_template_does_not_modify_it
    template = create_template(content: '<p>stored</p>')
    grant(:view_reporter_dashboards_reports, :edit_own_reporter_dashboards_templates)

    post :preview, params: { project_id: @project.identifier, id: template.id,
                             template: template_params(content: '<p>editor</p>') }

    assert_response :success
    assert_include 'editor', response.body
    assert_equal '<p>stored</p>', template.reload.content
  end

  # §9b.2: the PDF half is REPORTED even when it cannot run. There is no engine in the
  # test environment, so this is the "no engine" branch — and the thing being asserted is
  # that the page says so rather than quietly showing the HTML and implying both worked.
  def test_preview_reports_the_pdf_half_even_when_no_engine_is_registered
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    RedmineReporterDashboards::Render::Registry.isolated do
      post :preview, params: { project_id: @project.identifier, template: template_params }
    end

    assert_response :success
    assert_include l(:label_reporter_report_failed_engine), response.body
  end

  # A FAILED PREVIEW IS A 200 WITH A DIAGNOSTIC, not a 500. It is the editor answering
  # "here is what your template does".
  def test_preview_of_a_broken_template_shows_the_diagnostics_panel
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    post :preview, params: { project_id: @project.identifier,
                             template: template_params(content: '{% for %}') }

    assert_response :success
    assert_include l(:label_reporter_report_failed_template), response.body
    assert_include l(:label_reporter_report_diagnostic_correlation_id), response.body
  end

  # THE DISCLOSURE HOLE THE FIRST VERSION OF `require_preview_permission` HAD, pinned.
  #
  # `#preview` accepts an `id`, and a check that only asked "does this actor hold any
  # authoring permission" let a holder of `add_…` — who may create templates and edit
  # none — POST the id of somebody else's PRIVATE template with no content of their own
  # and read its rendered output. Preview of a SAVED template is an edit of it, so it
  # needs `#editable_by?`.
  def test_preview_of_a_template_you_may_not_edit_is_refused
    template = create_template(author: @dlopper, visibility: Template::VISIBILITY_PUBLIC,
                               content: '<p>SOMEBODY ELSES CONTENT</p>')
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    post :preview, params: { project_id: @project.identifier, id: template.id }

    assert_response :forbidden
    assert_not_include 'SOMEBODY ELSES CONTENT', response.body
  end

  def test_preview_of_a_private_template_you_cannot_see_is_a_404_and_leaks_nothing
    template = create_template(author: @dlopper, visibility: Template::VISIBILITY_PRIVATE,
                               content: '<p>PRIVATE DRAFT</p>')
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :edit_reporter_dashboards_templates)

    post :preview, params: { project_id: @project.identifier, id: template.id }

    assert_response :not_found
    assert_not_include 'PRIVATE DRAFT', response.body
  end

  def test_preview_of_a_template_you_may_edit_is_allowed
    template = create_template(author: @jsmith, content: '<p>MY DRAFT</p>')
    grant(:view_reporter_dashboards_reports, :edit_own_reporter_dashboards_templates)

    post :preview, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include 'MY DRAFT', response.body
  end

  # A per-record template over a scope that matched nothing produced an empty batch, and
  # `documents.first.bytes` on that is a NoMethodError — a 500 for a request that is
  # merely empty.
  def test_a_report_covering_no_issues_is_refused_rather_than_500ing
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)
    Issue.where(project_id: @project.id).destroy_all

    get :document, params: { project_id: @project.identifier, id: template.id }

    assert_response :unprocessable_entity
    assert_include l(:text_reporter_template_no_issues), response.body
  end

  def test_a_report_covering_no_issues_says_so_on_the_page_too
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)
    Issue.where(project_id: @project.id).destroy_all

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include l(:text_reporter_template_no_issues), response.body
  end

  # ------------------------------------------------------------------ import / export

  def test_import_needs_BOTH_authoring_permissions
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)
    post :import, params: { project_id: @project.identifier, file: uploaded_bundle }
    assert_response :forbidden

    grant(:view_reporter_dashboards_reports, :edit_reporter_dashboards_templates)
    post :import, params: { project_id: @project.identifier, file: uploaded_bundle }
    assert_response :forbidden
  end

  def test_import_with_both_permissions_creates_a_private_template
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :edit_reporter_dashboards_templates)

    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      post :import, params: { project_id: @project.identifier, file: uploaded_bundle }
    end

    imported = Template.order(:id).last
    assert_equal 'Imported', imported.name
    assert_equal @jsmith.id, imported.author_id
    assert_equal Template::VISIBILITY_PRIVATE, imported.visibility
  end

  # A bundle is a file somebody was handed. Letting it choose its own visibility would let
  # the sender decide who in the receiving organisation can read it.
  def test_import_ignores_a_visibility_the_file_asks_for
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :edit_reporter_dashboards_templates,
          :manage_public_reporter_dashboards_templates)
    json = { 'template' => { 'name' => 'Sneaky', 'content' => 'x', 'visibility' => 2 } }.to_json

    post :import, params: { project_id: @project.identifier, file: uploaded_bundle(json) }

    assert_equal Template::VISIBILITY_PRIVATE, Template.order(:id).last.visibility
  end

  def test_import_refuses_a_file_naming_a_ruby_class_and_says_why
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :edit_reporter_dashboards_templates)
    yaml = "---\nname: A\ncontent: !ruby/object:Struct {}\n"

    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      post :import, params: { project_id: @project.identifier,
                              file: uploaded_bundle(yaml) }
    end

    assert_response :unprocessable_entity
    assert_not_nil flash[:error]
  end

  def test_import_with_no_file_says_so_rather_than_500ing
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :edit_reporter_dashboards_templates)

    post :import, params: { project_id: @project.identifier }

    assert_response :unprocessable_entity
    assert_equal l(:error_reporter_template_import_no_file), flash[:error]
  end

  def test_export_serves_a_json_bundle_named_after_the_template
    template = create_template(name: 'Quarterly report')
    grant(:view_reporter_dashboards_reports, :edit_own_reporter_dashboards_templates)

    get :export, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_equal 'application/json', response.media_type
    assert_include 'Quarterly_report.json', response.headers['Content-Disposition']
    # T-29: THE EXPORT IS A BUNDLE NOW (FR-55), so one template comes out as a bundle
    # carrying one template rather than as a second file format.
    parsed = JSON.parse(response.body)
    assert_equal %w[format_version exported_at plugin_version templates], parsed.keys
    assert_equal 'Quarterly report', parsed['templates'].first['name']
  end

  # T-29 / §7 RULE 5 ON THE UPLOAD PATH. A bundle written by a current install, uploaded to
  # one whose schema is a minor version behind, used to reach `Template.new` with a column
  # this database does not have and raise `ActiveModel::UnknownAttributeError` — a 500 where
  # rule 5 asks for a degraded feature.
  #
  # THE COLUMN IS TAKEN AWAY RATHER THAN AN UNKNOWN FIELD ADDED, and that distinction is
  # the test: an unknown field never arrives, because `Exchange.attributes_from` slices the
  # node to `EXPORTED_FIELDS` first. Mutation testing found the first version of this
  # assertion exercising nothing for exactly that reason. Stubbing `column_names` expresses
  # an older schema without running DDL inside a test, which PostgreSQL rolls back and
  # MySQL COMMITS (HANDOVER §1).
  def test_an_upload_naming_a_column_this_schema_lacks_is_imported_without_it
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :edit_reporter_dashboards_templates)
    # THE VALUE IS COMPUTED BEFORE THE STUB IS INSTALLED. Written the other way round,
    # `Template.stubs(:column_names).returns(Template.column_names - [...])` replaces the
    # method before Ruby evaluates the argument, so the argument reads the stub and answers
    # nil — `undefined method '-' for nil`, from a line that looks obviously correct.
    older_schema = Template.column_names - ['failure_document']
    Template.stubs(:column_names).returns(older_schema)
    json = { 'format_version' => 1,
             'templates' => [{ 'name' => 'From the future', 'content' => '<p>f</p>',
                               'failure_document' => true }] }.to_json

    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      post :import, params: { project_id: @project.identifier, file: uploaded_bundle(json) }
    end

    assert_response :redirect
    # AND THE OPERATOR IS TOLD (INV-4). The template that arrived is not the template that
    # was sent, and the person who chose the file is standing right here.
    assert_match(/failure_document/, flash[:warning].to_s)
  end

  # A MULTI-TEMPLATE BUNDLE IS REFUSED, NOT SILENTLY REDUCED TO ITS FIRST TEMPLATE.
  # `#import` used `Exchange.parse`, which answers the FIRST template of a document — while
  # the same release taught `rake exchange:export` to write bundles of many. Uploading one
  # imported a single template and said "created". Found by an independent review.
  def test_uploading_a_multi_template_bundle_is_refused_naming_the_count
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :edit_reporter_dashboards_templates)
    json = { 'format_version' => 1,
             'templates' => [{ 'name' => 'Alpha', 'content' => '<p>a</p>' },
                             { 'name' => 'Beta', 'content' => '<p>b</p>' },
                             { 'name' => 'Gamma', 'content' => '<p>c</p>' }] }.to_json

    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      post :import, params: { project_id: @project.identifier, file: uploaded_bundle(json) }
    end

    assert_response :unprocessable_entity
    assert_include '3', flash[:error].to_s
  end

  # AND A ONE-TEMPLATE BUNDLE — the shape the Export button now writes — still imports.
  # Without this the refusal above could be refusing everything.
  def test_uploading_a_single_template_bundle_still_imports_it
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :edit_reporter_dashboards_templates)
    json = { 'format_version' => 1, 'exported_at' => '2025-12-29T10:30:20Z',
             'plugin_version' => '0.5.0',
             'templates' => [{ 'name' => 'Only one', 'content' => '<p>a</p>' }] }.to_json

    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      post :import, params: { project_id: @project.identifier, file: uploaded_bundle(json) }
    end

    assert_response :redirect
    assert_equal 'Only one', RedmineReporterDashboards::Template.order(:id).last.name
  end

  def test_export_sanitises_a_filename_that_would_be_a_path
    template = create_template(name: '../../etc/passwd')
    grant(:view_reporter_dashboards_reports, :edit_own_reporter_dashboards_templates)

    get :export, params: { project_id: @project.identifier, id: template.id }

    disposition = response.headers['Content-Disposition']
    assert_not_include '../', disposition
    assert_include 'etc_passwd.json', disposition
  end

  # ------------------------------------------------------------------ visibility

  def test_a_private_template_of_another_author_is_not_visible
    template = create_template(author: @dlopper, visibility: Template::VISIBILITY_PRIVATE)
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }
    assert_response :not_found

    get :index, params: { project_id: @project.identifier }
    assert_not_include template, assigns(:templates)
  end

  def test_a_public_template_of_another_author_is_visible
    template = create_template(author: @dlopper, visibility: Template::VISIBILITY_PUBLIC)
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
  end

  def test_a_roles_template_is_visible_only_to_a_holder_of_one_of_its_roles
    other_role = Role.create!(name: 'Auditors', permissions: [:view_issues])
    template = create_template(author: @dlopper, visibility: Template::VISIBILITY_ROLES,
                               roles: [other_role])
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }
    assert_response :not_found

    template.roles = [@role]
    template.save!
    get :show, params: { project_id: @project.identifier, id: template.id }
    assert_response :success
  end

  def test_visibility_wider_than_private_needs_manage_public
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    post :create, params: { project_id: @project.identifier,
                            template: template_params.merge(visibility: Template::VISIBILITY_PUBLIC) }

    assert_equal Template::VISIBILITY_PRIVATE, Template.order(:id).last.visibility
  end

  def test_manage_public_honours_the_visibility_that_was_asked_for
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :manage_public_reporter_dashboards_templates)

    post :create, params: { project_id: @project.identifier,
                            template: template_params.merge(visibility: Template::VISIBILITY_PUBLIC) }

    assert_equal Template::VISIBILITY_PUBLIC, Template.order(:id).last.visibility
  end

  def test_a_template_of_another_project_is_not_reachable_through_this_one
    other = Project.find(2)
    other.enable_module!(:reporter_dashboards_reports)
    foreign = Template.create!(project: other, author: @jsmith, name: 'Foreign',
                               content: 'x', visibility: Template::VISIBILITY_PUBLIC)
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: foreign.id }

    assert_response :not_found
  end

  # ------------------------------------------------------------------ T-15's owed items

  # T-15 ACCEPTANCE ITEM 1, owed since the cap was built with no caller (§Findings E-6).
  # A 422 whose message names the cap AND the count, from a controller, with the shipped
  # default cap rather than a lowered one.
  def test_a_per_record_export_over_the_cap_is_refused_with_a_422_naming_both_numbers
    create_issues_past_the_cap
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)
    documents = Issue.visible(@jsmith).where(project_id: @project.id).count
    cap = RedmineReporterDashboards::Render::BatchGuard::DEFAULT_MAX_DOCUMENTS

    get :document, params: { project_id: @project.identifier, id: template.id }

    assert_response :unprocessable_entity
    assert documents > cap, 'the fixture did not produce a batch over the cap'
    assert_include "#{documents} documents", response.body
    assert_include "the limit is #{cap}", response.body
  end

  # And it refused BEFORE rendering. A refusal that first renders fifty PDFs is not a
  # refusal (`technical-spec.md` §7), and the only way to see the difference from outside
  # is that the template layer was never entered.
  def test_a_refused_export_renders_nothing_at_all
    create_issues_past_the_cap
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)
    RedmineReporterDashboards::Liquid::TemplateRenderer.any_instance.expects(:render).never

    get :document, params: { project_id: @project.identifier, id: template.id }

    assert_response :unprocessable_entity
  end

  # T-15 ACCEPTANCE ITEM 2. A failed render must leave no trace: §7b.3's complaint about
  # the base plugin is that it PERSISTED the exception message as an attachment, so the
  # recipient got a file named `.pdf` that was not one. Both counts, across both failure
  # paths.
  #
  # HONEST ABOUT WHAT THESE TWO PROVE. Nothing in this change writes an `Attachment` or a
  # `Journal`, so the counts cannot move today and the assertions are REGRESSION GUARDS
  # rather than discoveries — which is exactly what T-15's acceptance list asks for, and
  # why the guard is worth having: the base plugin's failure path called
  # `create_attachment` on the exception message, and this is what goes red the day
  # somebody wires that up again. The `never` expectation below is the stronger half: it
  # fails on the CALL rather than on its effect, so a create that was rolled back would
  # still be caught.
  def test_a_failed_render_creates_no_attachment_and_no_journal
    template = create_template(content: '{% for %}')
    grant(:view_reporter_dashboards_reports)
    Attachment.expects(:create).never
    Attachment.expects(:create!).never

    assert_no_difference ['Attachment.count', 'Journal.count'] do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_response :internal_server_error
  end

  def test_a_refused_batch_creates_no_attachment_and_no_journal_either
    create_issues_past_the_cap
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)

    assert_no_difference ['Attachment.count', 'Journal.count'] do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_response :unprocessable_entity
  end

  # INV-5, at the entry point. A failure is a PAGE with a status code, never bytes with a
  # `.pdf` name on them.
  def test_a_failed_render_sends_no_document_bytes
    template = create_template(content: '{% for %}')
    grant(:view_reporter_dashboards_reports)

    get :document, params: { project_id: @project.identifier, id: template.id }

    assert_response :internal_server_error
    assert_equal 'text/html', response.media_type
    assert_not_include '%PDF-', response.body
  end

  # T-29 — THE ARCHIVE. This test asserted a 501 until T-29 built it (§Findings E-6's
  # third bullet, ~~S-12~~); the refusal it used to pin is gone, so the test now pins the
  # feature that replaced it.
  #
  # WITH AN ENGINE, AND THE REASON IS THE ONE THE INDEPENDENT REVIEW OF T-23 FOUND: without
  # it this request reaches the "no engine registered" branch and answers 500, so an
  # assertion about archives would pass for a reason that has nothing to do with archives
  # and `send_document`'s archive arm would never execute.
  def test_a_multi_document_export_streams_a_zip_archive
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)
    documents = Issue.visible(@jsmith).where(project_id: @project.id).count
    assert documents > 1, 'the fixture must produce more than one document to be an archive'

    with_engine do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_response :success
    assert_equal 'application/zip', response.media_type
    assert_include '.zip', response.headers['Content-Disposition']
    assert_equal documents, zip_members(response.body).length
  end

  # THE ARCHIVE IS BUFFERED AND SAYS ITS LENGTH — curator decision S-23, 2026-08-09, and
  # this test replaces one that asserted the exact opposite.
  #
  # T-29 first shipped a streamed archive with no `Content-Length`, per §Findings E-6. It
  # was measured NOT to stream through Redmine's real middleware: `Rack::ETag` gates on
  # `body.respond_to?(:to_ary)`, which `ActionDispatch::Response::Buffer` answers
  # unconditionally, so it digested the whole archive before the first byte left and the
  # body was generated a second time for the wire. The curator chose to buffer once and be
  # honest about it rather than generate twice and call it streaming.
  #
  # So the contract this pins is the NEW one, and it is pinned positively: a length is
  # present and it is the real length of the bytes that arrived. Asserting only "it
  # downloads" would pass under either design.
  def test_the_archive_is_sent_whole_with_its_length
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)

    with_engine do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_response :success
    assert_equal 'application/zip', response.media_type

    # MATERIALISED, WHICH IS WHAT "BUFFERED" MEANS AND IS WHAT THIS LEVEL CAN SEE.
    #
    # The `Content-Length` HEADER is set by `Rack::ContentLength`, and
    # `ActionController::TestCase` does not run middleware — asserting it here would be the
    # very mistake this file already records twice (the streamed-body assertion that tested
    # the harness, and the Rails 8.1 helper). Measured: the header is empty at this level
    # under both the streamed and the buffered design, so it discriminates nothing.
    #
    # What IS observable, and what actually changed, is the body the controller assigns:
    # `send_data` hands Rack a String, so `response_body` is an Array of one. Under the
    # streamed design it was a lazy `ZipStream`. This assertion fails if anyone puts that
    # back, which is the property S-23 decided.
    body = @controller.response_body
    assert_kind_of Array, body
    assert_kind_of String, body.first
    assert_not_kind_of RedmineReporterDashboards::Archive::ZipStream, body
    assert_equal archive_bytes(response.body).bytesize, body.first.bytesize
  end

  # AND THE CAP IS WHAT BOUNDS THE MEMORY, which is the whole reason buffering is
  # acceptable here. The documents are already in memory when the archive is built — the
  # zip roughly doubles that, once, for at most `DEFAULT_MAX_DOCUMENTS` of them. A test
  # that did not tie the two together would leave "how much can this hold" unanswered.
  def test_the_document_cap_still_bounds_what_the_archive_can_hold
    assert_equal 50, RedmineReporterDashboards::Render::BatchGuard::DEFAULT_MAX_DOCUMENTS,
                 'the archive is buffered, so this cap is also its memory bound'
  end

  # EVERY DOCUMENT IS IN THERE, UNDER ITS OWN RECORD'S NAME. A per-record export whose
  # members were all called the same thing, or which quietly held one member, is the
  # "serving the first document" behaviour the old 501 existed to avoid — reached by a
  # different route.
  def test_each_record_gets_its_own_member_named_after_it
    template = create_template(name: 'Per issue', output: 'per_record')
    grant(:view_reporter_dashboards_reports)
    ids = Issue.visible(@jsmith).where(project_id: @project.id).order(:id).pluck(:id)

    with_engine do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    names = zip_members(response.body)
    assert_equal names.uniq.length, names.length, 'two members share a name'
    ids.each { |id| assert_include "Per_issue-#{id}.pdf", names }
  end

  # THE CAP IS STILL ASKED BEFORE ANYTHING IS RENDERED, and building the archive must not
  # have moved that. T-29's `Accept:` says so in as many words: "the cap (BatchGuard) is
  # still asked BEFORE anything is rendered, so a refused 40 000-document export still
  # costs one COUNT(*)". Asserted the way T-23 asserted it — the renderer is never called.
  def test_an_export_over_the_cap_is_refused_before_any_document_is_rendered
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)
    create_issues_past_the_cap
    RedmineReporterDashboards::Liquid::TemplateRenderer.any_instance.expects(:render).never

    with_engine do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_response :unprocessable_entity
    assert_not_equal 'application/zip', response.media_type
  end

  # ------------------------------------------------------------------ a document that works

  def test_a_combined_report_downloads_as_a_pdf
    template = create_template(name: 'Quarterly report')
    grant(:view_reporter_dashboards_reports)

    with_engine do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert response.body.start_with?('%PDF-'), 'the response is not a PDF'
    assert_include 'Quarterly_report.pdf', response.headers['Content-Disposition']
    assert_include 'attachment', response.headers['Content-Disposition']
  end

  # Serving a document must not write one. T-30 owns stored documents and T-28 owns share
  # links; until then a download is a read, and a read that creates rows is how the base
  # plugin ended up persisting broken PDFs as attachments (§7b.3).
  def test_downloading_a_document_persists_nothing
    template = create_template
    grant(:view_reporter_dashboards_reports)

    assert_no_difference ['Attachment.count', 'Journal.count',
                          'RedmineReporterDashboards::Document.count'] do
      with_engine do
        get :document, params: { project_id: @project.identifier, id: template.id }
      end
    end

    assert_response :success
  end

  def test_the_preview_reports_the_engine_and_the_duration_when_the_pdf_worked
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    with_engine do
      post :preview, params: { project_id: @project.identifier, template: template_params }
    end

    assert_response :success
    assert_include 'fake 1.0', response.body
    assert_not_include l(:label_reporter_report_failed_engine), response.body
  end

  # The per-record path's SUCCESS case. `#document` for a per-record template is refused
  # over the cap and refused above one document, so without this the only per-record
  # assertions in the file would be about refusals — and "always refuses" would pass all
  # of them.
  def test_a_per_record_report_over_exactly_one_issue_downloads_as_a_pdf
    only = Issue.visible(@jsmith).where(project_id: @project.id).first
    Issue.where(project_id: @project.id).where.not(id: only.id).destroy_all
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)

    with_engine do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_response :success
    assert_equal 'application/pdf', response.media_type
  end

  # CLAUDE.md §6: every collection assertion has an explicit order, because PostgreSQL,
  # MySQL and MariaDB do not agree on unordered row order and this project runs all three.
  # The controller orders by name then id; this is what says so.
  def test_the_index_is_ordered_by_name
    create_template(name: 'Zebra')
    create_template(name: 'Alpha')
    create_template(name: 'Middle')
    grant(:view_reporter_dashboards_reports)

    get :index, params: { project_id: @project.identifier }

    assert_response :success
    assert_equal %w[Alpha Middle Zebra], assigns(:templates).map(&:name)
  end

  # ------------------------------------------------------------------ the scope

  # A SENTINEL AND A CONTROL. `assert_include '1', response.body` cannot fail — the digit
  # appears somewhere in every Redmine page — so T-23's headline `Accept:` item was
  # asserted by a tautology. The count is now wrapped in a marker, and the SAME request
  # without the query is asserted to answer differently, which is the half that shows the
  # query is what changed the scope.
  def test_the_scope_follows_the_query_the_picker_offers
    one = Issue.visible(@jsmith).where(project_id: @project.id).order(:id).first
    total = Issue.visible(@jsmith).where(project_id: @project.id).count
    assert total > 1, 'the fixture cannot tell a query scope from the project scope'

    query = IssueQuery.create!(project: @project, name: 'Only one', user: @jsmith,
                               visibility: Query::VISIBILITY_PUBLIC,
                               filters: { 'issue_id' => { operator: '=',
                                                          values: [one.id.to_s] } })
    template = create_template(content: 'COUNT=[{{ issues.size }}]')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id,
                         query_id: query.id }
    assert_response :success
    assert_include ERB::Util.html_escape('COUNT=[1]'), response.body

    get :show, params: { project_id: @project.identifier, id: template.id }
    assert_response :success
    assert_include ERB::Util.html_escape("COUNT=[#{total}]"), response.body
  end

  # A query id that does not resolve — deleted, or belonging to somebody else — falls back
  # to the project scope rather than erroring, because answering differently would turn
  # the picker into a probe for other people's private queries.
  def test_an_unresolvable_query_id_falls_back_rather_than_erroring
    template = create_template
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id,
                         query_id: 999_999 }

    assert_response :success
  end
  # ------------------------------------------------------------------ T-30 / FR-59
  #
  # The failure document. Every one of these drives `#document`, because that is the only
  # action that can produce one — a page that downloads a PDF instead of answering is a
  # worse page, and `#show`/`#preview` are asserted to stay pages further down.

  def test_the_failure_document_is_off_by_default
    template = create_template(content: '{% for %}')
    grant(:view_reporter_dashboards_reports)

    assert_equal false, template.failure_document?, 'FR-59 says default off'

    get :document, params: { project_id: @project.identifier, id: template.id }

    assert_response :internal_server_error
    assert_equal 'text/html', response.media_type
  end

  def test_a_failed_render_produces_a_failure_document_when_the_template_asks_for_one
    template = create_template(content: '{% for %}', failure_document: true)
    grant(:view_reporter_dashboards_reports)

    get :document, params: { project_id: @project.identifier, id: template.id }

    assert_equal 'application/pdf', response.media_type
    assert response.body.start_with?('%PDF-'), 'the failure document is not a PDF'
    assert_include '%%EOF', response.body
  end

  # §7b.3: "named so it can never be mistaken for the report".
  def test_the_failure_document_is_named_so_it_cannot_be_mistaken_for_the_report
    template = create_template(name: 'Quarterly report', content: '{% for %}',
                               failure_document: true)
    grant(:view_reporter_dashboards_reports)

    get :document, params: { project_id: @project.identifier, id: template.id }

    disposition = response.headers['Content-Disposition']
    assert_include 'report-FAILED-', disposition
    assert_include '.pdf', disposition
    assert_include 'attachment', disposition
    assert_not_include 'Quarterly_report.pdf', disposition
  end

  # A 200 carrying a document that says "this is not your report" is INV-5 one layer up:
  # every automated consumer of this endpoint would record a success.
  def test_the_failure_document_answers_with_the_failures_own_status
    template = create_template(content: '{% for %}', failure_document: true)
    grant(:view_reporter_dashboards_reports)

    get :document, params: { project_id: @project.identifier, id: template.id }

    assert_response :internal_server_error
  end

  # T-29 REMOVED A TEST HERE, and the removal is recorded rather than silent.
  #
  # `test_a_refusal_answers_with_a_failure_document_at_the_refusals_own_status` drove the
  # multi-document 501 and asserted that a refusal answers with a failure document at its
  # OWN status rather than at 200. T-29 built the archive, so that request now succeeds
  # and there is no 501 anywhere in the controller to drive.
  #
  # The property it protected is NOT lost, and that was checked rather than assumed before
  # deleting it: `test_a_batch_over_the_cap_answers_with_a_failure_document_at_422` and
  # `test_an_empty_report_answers_with_a_failure_document_whose_name_is_still_usable` each
  # assert the same thing on a refusal that still exists: both assert a 422 and a PDF, and
  # the second also asserts the `report-FAILED-<uuid>` filename. (An earlier version of
  # this note claimed both assert the filename; the cap test does not. Corrected rather
  # than left, because an overstated citation is what the next reader checks INSTEAD of
  # the test.) Rewriting this one would have been a third copy of an assertion two tests
  # already make.

  # THE SAFETY CLAUSE, AGAINST A REAL RENDER RATHER THAN A CONSTRUCTED DIAGNOSTIC. The
  # DB-less spec proves `FailureDocument` cannot carry `detail`; this proves the thing an
  # actual Liquid failure produces does not either, which is the claim T-30's `Accept:`
  # makes and the one the base plugin broke.
  def test_the_failure_document_carries_the_correlation_id_and_no_exception_text
    template = create_template(content: '{% for %}', failure_document: true)
    grant(:view_reporter_dashboards_reports)

    get :document, params: { project_id: @project.identifier, id: template.id }

    text = pdf_text(response.body)
    skip 'poppler-utils is not installed' if text.nil?

    assert_match(/[0-9a-f]{8}-[0-9a-f]{4}-/, text, 'no correlation id on the page')
    assert_include 'syntax_error', text
    assert_not_include 'Liquid::SyntaxError', text
    refute_match(/[A-Za-z]+::[A-Za-z]+Error/, text)
    assert_not_include 'SELECT', text
  end

  # Serving a failure document must not write one either. §7b.3: "never persisted as an
  # attachment unless requested", and nothing here requests persistence.
  def test_producing_a_failure_document_persists_nothing
    template = create_template(content: '{% for %}', failure_document: true)
    grant(:view_reporter_dashboards_reports)

    assert_no_difference ['Attachment.count', 'Journal.count',
                          'RedmineReporterDashboards::Document.count'] do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_equal 'application/pdf', response.media_type
  end

  def test_show_stays_a_page_even_when_the_template_asks_for_a_failure_document
    template = create_template(content: '{% for %}', failure_document: true)
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :internal_server_error
    assert_equal 'text/html', response.media_type
    assert_not_include '%PDF-', response.body
  end

  def test_preview_stays_a_page_even_when_the_template_asks_for_a_failure_document
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    post :preview, params: { project_id: @project.identifier,
                             template: { name: 'Draft', content: '{% for %}',
                                         source: 'issues', output: 'combined',
                                         failure_document: '1' } }

    assert_response :success
    assert_equal 'text/html', response.media_type
    assert_not_include '%PDF-', response.body
  end

  # A SUCCESSFUL RENDER IS UNAFFECTED. The flag changes what a FAILURE answers with and
  # nothing else; without this, a bug that always drew the failure document would still
  # pass every example above.
  def test_a_template_asking_for_a_failure_document_still_downloads_a_working_report
    template = create_template(name: 'Quarterly report', failure_document: true)
    grant(:view_reporter_dashboards_reports)

    with_engine do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_response :success
    assert_include 'Quarterly_report.pdf', response.headers['Content-Disposition']
    assert_not_include 'report-FAILED-', response.headers['Content-Disposition']
  end

  # QA: EVERY ORIGIN A DIAGNOSTIC CAN HAVE, THROUGH A REAL RUN. The DB-less spec drives
  # `FailureDocument` with CONSTRUCTED diagnostics, which proves the policy and says
  # nothing about whether the three real paths reach it. `:template` is covered above; the
  # other two are here.

  # `:engine` — an adapter that fails, and one carrying a `detail` full of exactly what
  # §7b.3 says must never reach a reader. This is the safety clause driven through the
  # ENGINE path rather than the template one.
  def test_an_engine_failure_answers_with_a_failure_document_carrying_none_of_its_detail
    # A DISTINCTIVE NAME, because FR-58's first noun reaches the panel and the document
    # from `ReportRun` on THIS origin by a different call than the template one — and the
    # independent review deleted `template_name:` from both `from_render_failure` and
    # `from_batch_refusal` with the whole suite staying green.
    template = create_template(name: 'Engine origin subject', failure_document: true)
    grant(:view_reporter_dashboards_reports)

    with_failing_engine do
      get :document, params: { project_id: @project.identifier, id: template.id }
    end

    assert_response :internal_server_error
    assert_equal 'application/pdf', response.media_type

    text = pdf_text(response.body)
    skip 'poppler-utils is not installed' if text.nil?
    assert_include 'engine_crashed', text
    assert_include 'Engine origin subject', text, 'FR-58: the document must name the template'
    assert_include l(:label_reporter_report_failed_engine), text
    assert_not_include 'RuntimeError', text
    assert_not_include 'PG::UndefinedColumn', text
    assert_not_include 'role_id', text
    assert_not_include 'project_id', text
  end

  # `:batch` — the cap, which is a REFUSAL and must not read as a crash. 422, and the
  # headline is the refusal's rather than the engine's.
  def test_a_batch_over_the_cap_answers_with_a_failure_document_at_422
    create_issues_past_the_cap
    # Distinctive for the same reason as the engine case above: this is the `:batch`
    # origin, and its `template_name` came from a call nothing asserted.
    template = create_template(name: 'Batch origin subject', output: 'per_record',
                               failure_document: true)
    grant(:view_reporter_dashboards_reports)

    get :document, params: { project_id: @project.identifier, id: template.id }

    assert_response :unprocessable_entity
    assert_equal 'application/pdf', response.media_type

    text = pdf_text(response.body)
    skip 'poppler-utils is not installed' if text.nil?
    assert_include l(:label_reporter_report_refused), text
    assert_include 'Batch origin subject', text, 'FR-58: the document must name the template'
    assert_not_include l(:label_reporter_report_failed_engine), text
  end

  # An EMPTY report is not a failure of the engine either, and its correlation id is the
  # literal `-` rather than a UUID — which the filename filter has to survive rather than
  # reduce to nothing.
  def test_an_empty_report_answers_with_a_failure_document_whose_name_is_still_usable
    template = create_template(output: 'per_record', failure_document: true)
    grant(:view_reporter_dashboards_reports)
    Issue.where(project_id: @project.id).destroy_all

    get :document, params: { project_id: @project.identifier, id: template.id }

    assert_response :unprocessable_entity
    assert_equal 'application/pdf', response.media_type
    # A REAL ID, not merely a non-empty one. This used to assert the filename was not
    # `report-FAILED-.pdf`, which the literal `-` this path used to carry satisfied — it
    # produced `report-FAILED--.pdf` and told the reader to quote an id that identifies
    # nothing. Asserted as a UUID shape, and asserted on the page as well as in the name.
    assert_match(/report-FAILED-[0-9a-f]{8}-[0-9a-f]{4}-/,
                 response.headers['Content-Disposition'])

    text = pdf_text(response.body)
    skip 'poppler-utils is not installed' if text.nil?
    assert_match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-/, text,
                 'the page tells the reader to quote an id it does not carry')
  end

  # The flag has to SURVIVE a round trip. It was missing from `Exchange::EXPORTED_FIELDS`
  # at first, so export -> import silently turned it off — and FR-57's byte-identity still
  # held, because both ends agreed about a field neither carried. Found by the independent
  # review; asserted here through the two real HTTP actions rather than at the seam.
  def test_export_round_trips_the_failure_document_flag
    template = create_template(name: 'Round trip', failure_document: true)
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :edit_reporter_dashboards_templates)

    get :export, params: { project_id: @project.identifier, id: template.id }
    assert_response :success
    bundle = response.body
    assert_equal true, JSON.parse(bundle)['templates'].first['failure_document']

    file = Rack::Test::UploadedFile.new(StringIO.new(bundle), 'application/json',
                                        original_filename: 'round-trip.json')
    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      post :import, params: { project_id: @project.identifier, file: file }
    end

    imported = RedmineReporterDashboards::Template.order(:id).last
    assert_equal true, imported.failure_document?, 'the flag did not survive the round trip'
  end

  # THE UX PASS'S FINDING, as a test. Without this branch the failure document exists and
  # nothing on the page reaches it: the download button is drawn only for a run that
  # SUCCEEDED, which is never the run that has a failure document.
  def test_a_failed_show_offers_the_failure_document_when_the_template_asks_for_one
    template = create_template(content: '{% for %}', failure_document: true)
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :internal_server_error
    assert_select 'div.contextual a', text: /#{Regexp.escape(l(:label_reporter_failure_document_download))}/
    assert_not_include l(:label_reporter_template_download_pdf), response.body
  end

  def test_a_failed_show_offers_nothing_to_download_when_the_flag_is_off
    template = create_template(content: '{% for %}')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :internal_server_error
    assert_select 'div.contextual a.icon-download', count: 0
  end

  # A SUCCESSFUL RUN STILL OFFERS THE REPORT, not the failure document. Without this, a
  # branch that drew the failure link unconditionally would pass both examples above.
  def test_a_successful_show_still_offers_the_report_itself
    template = create_template(failure_document: true)
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include l(:label_reporter_template_download_pdf), response.body
    assert_not_include l(:label_reporter_failure_document_download), response.body
  end

  # FR-58's first noun, in the panel rather than only in the page heading.
  def test_the_diagnostics_panel_names_the_template
    template = create_template(name: 'Named in the panel', content: '{% for %}')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :internal_server_error
    assert_select 'table.list th', text: l(:label_reporter_template)
    assert_include 'Named in the panel', response.body
  end
  # ------------------------------------------------------------------ T-31 / source
  #
  # One controller, one CRUD, one preview — `[OQ-H]` closed that — and the separation is at
  # the QUERY: `source: issues` resolves through `IssueQuery`, `source: time_entries`
  # through `TimeEntryQuery`. These drive both through the same actions.

  def grant_time(*permissions)
    grant(:view_time_entries, *permissions)
    Role.find(1).update_columns(time_entries_visibility: 'all')
  end

  # SOMEBODY ELSE'S HOURS, IN THIS PROJECT — and the fixture needs them, because MEASURED:
  # project 1 has three time entries and jsmith authored all three, so `TimeEntry` and
  # `TimeEntry.visible(jsmith)` return the same 3 rows and `time_entries_visibility: 'own'`
  # narrows nothing. Without this row, a test asserting "the report sees exactly the visible
  # entries" passes with `.visible` deleted, and the S-14 narrowing cannot be demonstrated
  # at all. It is the difference between `all` (4) and `own` (3).
  def another_users_hours
    TimeEntry.create!(project: @project, user: @dlopper, author: @dlopper,
                      issue: Issue.where(project_id: @project.id).first,
                      hours: 7.5, spent_on: Date.new(2026, 3, 10),
                      activity: TimeEntryActivity.where(active: true).first)
  end

  def test_a_time_entry_template_renders_through_the_same_show_action
    # `{{ time_entries.size }}` and NOT `total_hours`: the first version of this example used
    # the latter, which `TimeEntriesDrop` does not define — `CollectionDrop`'s
    # `liquid_method_missing` swallowed it and the example passed on a blank while advertising
    # surface nobody built. Totalling hours needs T-31's second increment.
    template = create_template(source: 'time_entries',
                               content: 'COUNT=[{{ time_entries.size }}]')
    grant_time(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
  end

  # THE SCOPE IS THE VIEWER'S, AND IT IS `TimeEntry.visible` RATHER THAN `Issue.visible`.
  # Asserted by counting, with a row somebody else booked so that the two answers DIFFER —
  # see `another_users_hours` for the measurement that made this necessary.
  def test_a_time_entry_template_sees_every_visible_entry_including_other_peoples
    another_users_hours
    template = create_template(source: 'time_entries',
                               content: 'COUNT=[{{ time_entries.size }}]')
    grant_time(:view_reporter_dashboards_reports)
    expected = TimeEntry.visible(@jsmith).where(project_id: @project.id).count
    assert_equal 4, expected, 'the fixture is not what this test assumes'

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include ERB::Util.html_escape('COUNT=[4]'), response.body
  end

  # THE ONE THAT CATCHES A DELETED `.visible`. With `time_entries_visibility: 'own'` the
  # actor may read three of the four rows in the project, so an unfiltered scope answers 4
  # and the correct one answers 3. Both numbers are real and both are plausible, which is
  # exactly why the count has to be asserted rather than eyeballed.
  def test_an_own_only_actor_sees_fewer_entries_than_the_project_has
    another_users_hours
    template = create_template(source: 'time_entries',
                               content: 'COUNT=[{{ time_entries.size }}]')
    grant(:view_time_entries, :view_reporter_dashboards_reports)
    Role.find(1).update_columns(time_entries_visibility: 'own')

    # COMPUTED AND SELF-GUARDING rather than hard-coded. The first version asserted 3 and
    # measured 1: `visible_condition`'s `own` branch filters on `time_entries.user_id`, and
    # only one of the fixture's three rows in this project has jsmith as its USER — the
    # others merely have him as author. The exact figures are the fixture's business; what
    # this test needs is that the two answers DIFFER, and it says so if they stop.
    unscoped = TimeEntry.where(project_id: @project.id).count
    visible = TimeEntry.visible(@jsmith).where(project_id: @project.id).count
    assert unscoped > visible,
           "the fixture does not discriminate (#{unscoped} vs #{visible}), so this proves nothing"

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_include ERB::Util.html_escape("COUNT=[#{visible}]"), response.body
    assert_not_include ERB::Util.html_escape("COUNT=[#{unscoped}]"), response.body
  end

  # AND WITH NO `:view_time_entries` AT ALL, nothing — `TimeEntry.visible` answers `1=0`.
  def test_an_actor_without_the_permission_sees_no_entries
    another_users_hours
    template = create_template(source: 'time_entries',
                               content: 'COUNT=[{{ time_entries.size }}]')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_include ERB::Util.html_escape('COUNT=[0]'), response.body
  end

  # AND IT DOES NOT SEE ANOTHER PROJECT'S HOURS. Without this, a scope that forgot its
  # project filter would pass the examples above whenever the fixture's other projects
  # happened to be invisible.
  def test_a_time_entry_template_does_not_reach_another_projects_hours
    template = create_template(source: 'time_entries',
                               content: 'COUNT=[{{ time_entries.size }}]')
    grant_time(:view_reporter_dashboards_reports)
    everywhere = TimeEntry.visible(@jsmith).count
    here = TimeEntry.visible(@jsmith).where(project_id: @project.id).count
    assert everywhere > here, 'the fixture has no out-of-project entries, so this proves nothing'

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_include ERB::Util.html_escape("COUNT=[#{here}]"), response.body
    assert_not_include ERB::Util.html_escape("COUNT=[#{everywhere}]"), response.body
  end

  # §Findings S-13 — the guard, at the entry point rather than only in the unit spec.
  #
  # ASSERTED POSITIVELY, AND IN THE SHAPE THAT PRODUCED THE DEFECT. The first version only
  # asserted the issue count was ABSENT, over a scope with no issues join — so with the guard
  # neutered it still passed, and an independent review measured exactly that: `PROBE3 GUARD
  # OFF: issue_count=7 body=TOTAL=[2]`, at HTTP 200, with the shipped assertion vacuous. S-13
  # was measured against a `TimeEntryQuery#base_scope`, which carries `left_join_issue`, and
  # that is the ONLY shape that answers plausibly rather than erroring.
  def test_sql_aggregate_in_a_time_entry_template_reports_nothing_rather_than_issue_counts
    template = create_template(
      source: 'time_entries',
      content: '{% sql_aggregate assign_to: stats %}TOTAL=[{{ stats.total }}]'
    )
    grant_time(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include ERB::Util.html_escape('TOTAL=[0]'), response.body,
                   'the refusal must assign the EMPTY result, not merely a different number'
  end

  # THE DANGEROUS SHAPE, NOW ANSWERED CORRECTLY RATHER THAN REFUSED. A saved TimeEntryQuery
  # whose `base_scope` joins issues, grouped by an ISSUE column. This is the exact shape that
  # produced §Findings S-13 — the issue kernel answered `COUNT(DISTINCT issues.id)` here, so
  # four entries over two issues came back as `2`. The owned aggregator answers HOURS.
  def test_a_time_entry_query_grouped_by_an_issue_column_reports_hours_not_issue_counts
    another_users_hours
    query = TimeEntryQuery.create!(name: 'hours here', project: @project,
                                   user: @jsmith, visibility: 2)
    template = create_template(
      source: 'time_entries',
      content: '{% sql_aggregate group_by: tracker, assign_to: stats %}' \
               'TOTAL=[{{ stats.total }}] MEASURE=[{{ stats.measure }}]'
    )
    grant_time(:view_reporter_dashboards_reports)

    # THE ORACLE IS OVER THE SCOPE THE REPORT IS ACTUALLY OVER, and the first version was not:
    # it summed `project_id: @project.id` and read 162.75 while the page said 170.4. Both were
    # right. A saved query is bounded to the project's SUBTREE and not to the single id — see
    # `ReportScope#resolve`, where that asymmetry is argued — so a one-project sum is simply a
    # different question. The scope is therefore built by the same production code, whose own
    # bounds are asserted in `ReporterDashboardsReportScopeTest` and in
    # `test_a_time_entry_template_does_not_reach_another_projects_hours`; what THIS example is
    # paid to check is the aggregation over it, and that is still computed twice — once by the
    # database with `GROUP BY`/`SUM` and once by loading the rows and adding them up in Ruby.
    #
    # `uniq(&:id)` deliberately: `SUM(time_entries.hours)` over a row-duplicating join would
    # over-count, so the Ruby side computes the CORRECT figure rather than the same mistake.
    # `left_join_issue` is a `belongs_to` and duplicates nothing today; if a future filter
    # changes that, this goes red instead of agreeing.
    scope, = RedmineReporterDashboards::Reporting::ReportScope.build(
      template: template, actor: @jsmith, project: @project, query_id: query.id
    )
    hours = scope.to_a.uniq(&:id).sum(&:hours).to_f.round(2)
    issues = scope.distinct.count(:issue_id)
    assert hours != issues, "hours #{hours} and issue count #{issues} coincide, so this proves nothing"

    get :show, params: { project_id: @project.identifier, id: template.id,
                         query_id: query.id }

    assert_response :success
    assert_include ERB::Util.html_escape("TOTAL=[#{hours}]"), response.body
    assert_include ERB::Util.html_escape('MEASURE=[hours]'), response.body
    assert_not_include ERB::Util.html_escape("TOTAL=[#{issues}]"), response.body
  end

  # AND THE BUCKETS ARE HOURS PER ACTIVITY — the dimension the issue kernel does not have at
  # all, computed here against a second, independent Ruby sum.
  def test_hours_by_activity_agree_with_a_ruby_sum
    another_users_hours
    template = create_template(
      source: 'time_entries',
      content: '{% sql_aggregate group_by: activity, assign_to: stats %}' \
               '{% for b in stats.buckets %}B=[{{ b.label }}:{{ b.count }}]{% endfor %}'
    )
    grant_time(:view_reporter_dashboards_reports)

    expected = TimeEntry.visible(@jsmith).where(project_id: @project.id)
                        .to_a.group_by(&:activity_id)
                        .transform_values { |rows| rows.sum(&:hours).to_f.round(2) }
    assert expected.any?, 'no hours to aggregate, so this proves nothing'

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    expected.each do |activity_id, hours|
      label = TimeEntryActivity.find(activity_id).name
      assert_include ERB::Util.html_escape("B=[#{label}:#{hours}]"), response.body
    end
  end

  # AND THE REFUSAL IS VISIBLE TO THE AUTHOR — INV-4, which the first version claimed and did
  # not deliver. An independent review measured it: the degradation went into a per-job
  # `Diagnostics` object that `ReportRun` threw away, `Outcome#degradations` was filled only
  # from render-ENGINE degradations, and the preview's degradation block sat inside the branch
  # that only runs when the PDF succeeded. The author saw `TOTAL=[0]` and nothing else.
  # A TIME-ENTRY AGGREGATION WITH NO `group_by` IS STILL A REFUSAL, and it is still visible.
  # There is no time-entry equivalent of the issue path's created/closed flow — a time entry
  # is not opened and closed — so a tag with no dimension has nothing to ask for. Increment 1
  # recorded `aggregation_source_unsupported` here because the whole source was refused;
  # increment 2 gives the source an aggregator, and what is left to refuse is the argument.
  def test_a_time_entry_aggregation_with_no_dimension_says_so_on_the_page
    template = create_template(
      source: 'time_entries',
      content: '{% sql_aggregate assign_to: stats %}TOTAL=[{{ stats.total }}]'
    )
    grant_time(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_select 'div.reporter-degradations'
    # THE SENTENCE, NOT THE SYMBOL. Asserting `aggregation_group_by_required` pinned the raw
    # identifier as a tested contract, which is what an independent review objected to: the
    # panel printed `Degradation#to_s` and nine locale files had no key for any code. The key
    # exists now, so what the reader sees is what is asserted.
    assert_include ERB::Util.html_escape(l(:text_reporter_degradation_aggregation_group_by_required)),
                   response.body
    assert_not_include 'aggregation_group_by_required', response.body
    assert_include ERB::Util.html_escape('TOTAL=[0]'), response.body
  end

  def test_a_refused_aggregation_argument_is_reported_in_the_preview_too
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates,
          :view_time_entries)

    post :preview, params: {
      project_id: @project.identifier,
      template: { name: 'Draft', source: 'time_entries', output: 'combined',
                  content: '{% sql_aggregate assign_to: stats %}TOTAL=[{{ stats.total }}]' }
    }

    assert_response :success
    assert_include ERB::Util.html_escape(l(:text_reporter_degradation_aggregation_group_by_required)),
                   response.body
  end

  # AN ARGUMENT THE TIME-ENTRY PATH CANNOT HONOUR IS NAMED ON THE PAGE. An independent review
  # measured `drill: true` and `split_by:` being dropped in SILENCE — no `bucket.url`, no
  # crosstab, nothing said — while the README promised drill-through. HANDOVER §1's rule is
  # that every aggregator entry point LOGS AND DEGRADES on an argument it cannot use.
  def test_an_argument_the_time_entry_path_cannot_use_is_named_on_the_page
    template = create_template(
      source: 'time_entries',
      content: '{% sql_aggregate group_by: activity, drill: true, split_by: user, ' \
               'assign_to: stats %}TOTAL=[{{ stats.total }}]'
    )
    grant_time(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_select 'div.reporter-degradations'
    # The sentence interpolates the parameter names, so the author is told WHICH arguments —
    # a degradation that only said "unsupported parameters" would not be actionable.
    assert_include ERB::Util.html_escape('split_by'), response.body
    assert_include ERB::Util.html_escape('drill'), response.body
    # ...and the aggregation still ran, because the dimension it CAN use was given.
    assert_not_include ERB::Util.html_escape('TOTAL=[0]'), response.body
  end

  # AND A MISTYPED DIMENSION IS NAMED TOO, in the reader's language, from a code the
  # aggregator raised rather than the tag — two layers, one panel (INV-4).
  def test_a_mistyped_dimension_is_named_on_the_page
    template = create_template(
      source: 'time_entries',
      content: '{% sql_aggregate group_by: activty, assign_to: stats %}TOTAL=[{{ stats.total }}]'
    )
    grant_time(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include ERB::Util.html_escape(
      l(:text_reporter_degradation_aggregation_dimension_unknown, group_by: 'activty')
    ), response.body
    assert_include ERB::Util.html_escape('TOTAL=[0]'), response.body
  end

  # AND A CLEAN ISSUE RENDER SAYS NOTHING, so the block is not simply always drawn.
  def test_a_clean_render_reports_no_degradations
    template = create_template(content: 'x')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_select 'div.reporter-degradations', count: 0
  end

  # THE SECOND KERNEL ENTRY POINT. `{% version_rollup %}` reads `issues.fixed_version_id` and
  # `issues.status_id`; over a time-entry relation the first binds by accident and the second
  # raises into the tag's rescue, so the author got an empty table and no explanation. It now
  # refuses through the same shared guard.
  def test_version_rollup_in_a_time_entry_template_reports_nothing_rather_than_raising
    template = create_template(
      source: 'time_entries',
      content: '{% version_rollup assign_to: rows %}N=[{{ rows.size }}]'
    )
    grant_time(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include ERB::Util.html_escape('N=[0]'), response.body
  end

  # ...AND IT STILL ROLLS UP ON AN ISSUE TEMPLATE.
  def test_version_rollup_still_works_in_an_issue_template
    template = create_template(content: '{% version_rollup assign_to: rows %}OK=[{{ rows.size }}]')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    # A POSITIVE COUNT. `OK=[` alone is present for an empty rollup too — the mutation that
    # made the guard refuse everything left this example green until it asserted a number.
    assert_match(/OK=\[[1-9]/, response.body,
                 'the rollup produced no rows, so this says nothing about it working')
  end

  # ...AND THE SAME TAG STILL WORKS ON AN ISSUE TEMPLATE. Without this the guard could be
  # refusing everything and the example above would still pass.
  def test_sql_aggregate_still_aggregates_in_an_issue_template
    template = create_template(
      content: '{% sql_aggregate assign_to: stats %}TOTAL=[{{ stats.total }}]'
    )
    grant(:view_reporter_dashboards_reports)
    total = Issue.visible(@jsmith).where(project_id: @project.id).count

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_include ERB::Util.html_escape("TOTAL=[#{total}]"), response.body
  end

  # ------------------------------------------------------------------ T-31 / S-14
  #
  # `TimeEntry.visible` branches on `Role#time_entries_visibility`. All three states, and
  # the middle one is the whole reason the finding exists.

  def test_an_actor_who_sees_every_hour_is_told_nothing
    template = create_template(source: 'time_entries', content: 'x')
    grant_time(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_select '#reporter-time-entry-visibility', count: 0
  end

  def test_an_actor_who_sees_only_their_own_hours_is_told_so
    template = create_template(source: 'time_entries', content: 'x')
    grant(:view_time_entries, :view_reporter_dashboards_reports)
    Role.find(1).update_columns(time_entries_visibility: 'own')

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_select '#reporter-time-entry-visibility'
    assert_include l(:text_reporter_time_entries_own_only), response.body
  end

  def test_an_actor_who_may_see_no_hours_at_all_is_told_so
    template = create_template(source: 'time_entries', content: 'x')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include l(:text_reporter_time_entries_not_visible), response.body
  end

  # AN ISSUE TEMPLATE NEVER CARRIES THE NOTICE, whatever the actor's time-entry role is.
  # Without this, a notice rendered unconditionally would pass all three examples above.
  def test_an_issue_template_never_carries_the_time_entry_notice
    template = create_template(content: 'x')
    grant(:view_reporter_dashboards_reports)
    Role.find(1).update_columns(time_entries_visibility: 'own')

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_select '#reporter-time-entry-visibility', count: 0
  end

  # A SAVED QUERY DOES NOT WIDEN THE REPORT PAST THE PROJECT SUBTREE YOU OPENED. Measured by
  # an independent review before this bound existed: a GLOBAL TimeEntryQuery viewed at
  # /projects/ecookbook returned rows from projects 1 AND 3.
  #
  # THE HOURS HAVE TO BE OUTSIDE THE SUBTREE, and the first version of this example put them
  # in project 3 — which MEASURED as a DESCENDANT of project 1 (`p1.descendants.ids` is
  # `[5, 6, 3, 4]`), so the bound was a no-op and the example passed with it deleted. Project
  # 2 is a sibling, so it is the only place an out-of-bounds row can go.
  def test_a_global_query_does_not_pull_hours_from_outside_this_project_subtree
    outsider = Project.find(2)
    outsider.enable_module!(:time_tracking)
    # `find_or_create` — jsmith is ALREADY a member of project 2 in the fixture, and
    # `Member.create!` raised "User has already been taken" on it.
    unless Member.exists?(project_id: outsider.id, user_id: @jsmith.id)
      Member.create!(project: outsider, principal: @jsmith, role_ids: [@role.id])
    end
    TimeEntry.create!(project: outsider, user: @jsmith, author: @jsmith,
                      hours: 9.5, spent_on: Date.new(2026, 3, 11),
                      activity: TimeEntryActivity.where(active: true).first)

    query = TimeEntryQuery.create!(name: 'everywhere', project: nil,
                                   user: @jsmith, visibility: 2)
    template = create_template(source: 'time_entries',
                               content: 'COUNT=[{{ time_entries.size }}]')
    grant_time(:view_reporter_dashboards_reports)

    subtree = [@project.id] + @project.descendants.ids
    inside = TimeEntry.visible(@jsmith).where(project_id: subtree).count
    everywhere = TimeEntry.visible(@jsmith).count
    assert everywhere > inside,
           "no hours outside the subtree (#{everywhere} vs #{inside}), so this proves nothing"

    get :show, params: { project_id: @project.identifier, id: template.id,
                         query_id: query.id }

    assert_include ERB::Util.html_escape("COUNT=[#{inside}]"), response.body
    assert_not_include ERB::Util.html_escape("COUNT=[#{everywhere}]"), response.body
  end

  # `source` IS IN `PREVIEW_BLOCKING_ATTRIBUTES`, and half the argument for deleting
  # `report_scope`'s defensive `else` rests on it. Mutation showed nothing named the
  # constant: dropping `source` from the list left the whole suite green.
  def test_preview_refuses_an_unknown_source_before_rendering
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    post :preview, params: { project_id: @project.identifier,
                             template: { name: 'Draft', content: 'x',
                                         source: 'invoices', output: 'combined' } }

    assert_response :unprocessable_entity
  end

  # THE COPY FOLLOWS THE SOURCE. Measured by an independent review: an hours report told its
  # reader "This template produces one document per issue", and the empty state — which is
  # exactly where an actor with no `:view_time_entries` lands — said "This report covers no
  # issues … Widen the issue selection".
  def test_an_empty_time_entry_report_does_not_talk_about_issues
    # `per_record`, because the "no rows" sentence is on the branch that draws one document
    # per record — a combined template always produces one section and never reaches it.
    template = create_template(source: 'time_entries', output: 'per_record', content: 'x')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include l(:text_reporter_template_no_time_entries), response.body
    assert_not_include l(:text_reporter_template_no_issues), response.body
  end

  def test_an_empty_issue_report_still_talks_about_issues
    template = create_template(output: 'per_record')
    grant(:view_reporter_dashboards_reports)
    Issue.where(project_id: @project.id).destroy_all

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_include l(:text_reporter_template_no_issues), response.body
  end

  def test_a_per_record_time_entry_page_does_not_talk_about_issues
    template = create_template(source: 'time_entries', output: 'per_record', content: 'x')
    grant_time(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_include l(:text_reporter_template_per_record_html_time_entries,
                     count: TimeEntry.visible(@jsmith).where(project_id: @project.id).count),
                   response.body
  end

  # ------------------------------------------------------------------ T-31 / authoring

  def test_the_form_offers_both_sources
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    get :new, params: { project_id: @project.identifier }

    assert_response :success
    assert_select 'select[name=?] option[value=?]', 'template[source]', 'issues'
    assert_select 'select[name=?] option[value=?]', 'template[source]', 'time_entries'
  end

  def test_source_is_settable_on_create
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    post :create, params: { project_id: @project.identifier,
                            template: { name: 'Hours', content: 'x',
                                        source: 'time_entries', output: 'combined' } }

    assert_equal 'time_entries', Template.order(:id).last.source
  end

  # A THIRD VALUE IS REFUSED BY THE MODEL, not silently stored and rendered against the
  # wrong table.
  def test_a_source_outside_the_closed_set_is_refused
    grant(:view_reporter_dashboards_reports, :add_reporter_dashboards_templates)

    assert_no_difference 'Template.count' do
      post :create, params: { project_id: @project.identifier,
                              template: { name: 'Bad', content: 'x',
                                          source: 'invoices', output: 'combined' } }
    end

    assert_response :unprocessable_entity
  end

  # ...AND IF ONE IS ALREADY STORED — an import, an `update_columns`, a rollback across a
  # minor — the render REFUSES rather than falling through to the issue scope.
  def test_a_stored_unknown_source_is_refused_at_render_time
    template = create_template
    template.update_columns(source: 'invoices')
    grant(:view_reporter_dashboards_reports)

    get :show, params: { project_id: @project.identifier, id: template.id }

    assert_response :internal_server_error
    assert_include 'invoices', response.body
  end
end
