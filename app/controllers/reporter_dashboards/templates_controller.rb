# frozen_string_literal: true

module ReporterDashboards
  # AUTHORIZATION IS PER ACTION, AND `authorize` IS ONLY THE FIRST HALF.
  #
  # `before_action :authorize` is unscoped on purpose — no `only:`, no `except:`, no
  # `skip_before_action`. `spec/permissions/permission_map_spec.rb` reads that out of the AST.
  #
  # But Redmine's `authorize` passes when the actor holds ANY permission mapping the action.
  # With `manage_public_…` mapped to `#create` — which it must be, because that is where the
  # visibility decision is made — a role holding only that one permission would otherwise
  # reach a code-execution endpoint. And "import requires `add_…` AND `edit_…`" is a
  # conjunction Redmine's permission model cannot express at all.
  #
  # So each group of actions carries an explicit second guard, and the functional suite holds
  # each permission ALONE and asserts 403 on everything it must not reach:
  #
  #   authorize                  the action is mapped and this role holds one of them
  #   require_create_permission  new/create really need the create permission
  #   require_edit_permission    edit/update/destroy/export need an edit permission FOR THIS
  #                              TEMPLATE — which is where edit_own_ differs
  #   require_import_permissions import needs BOTH authoring permissions
  #   require_preview_permission preview RUNS the template, so it needs an authoring one
  class TemplatesController < ApplicationController
    # Shorter names for constants `lib/redmine_reporter_dashboards.rb` required at boot.
    Reporting = RedmineReporterDashboards::Reporting
    Render = RedmineReporterDashboards::Render
    Archive = RedmineReporterDashboards::Archive
    Template = RedmineReporterDashboards::Template
    TemplateLinter = RedmineReporterDashboards::TemplateLinter
    StarterGallery = RedmineReporterDashboards::StarterGallery

    # DECLARED, because Redmine sets `include_all_helpers = false`
    # (`config/application.rb:73`) — a controller sees its OWN helper and nothing else,
    # which is why every core controller lists what it needs. `reporter_dashboard_icon`
    # is this plugin's D-3 shim (`sprite_icon` exists on Redmine 6+ and raises on 5.1) and
    # it lives in the dashboard's helper; without this line the views 500 on it, and they
    # did.
    helper :reporter_project_pages

    before_action :find_project_by_project_id
    before_action :require_reports_module
    before_action :authorize
    before_action :find_template, only: [:show, :document, :edit, :update, :destroy,
                                         :export]
    before_action :require_create_permission, only: [:new, :create]
    before_action :require_edit_permission, only: [:edit, :update, :destroy, :export]
    before_action :require_import_permissions, only: [:import]
    before_action :find_preview_base, only: [:preview]
    before_action :require_preview_permission, only: [:preview]

    # ------------------------------------------------------------------ consuming

    def index
      @templates = Template.visible(User.current)
                           .where(project_id: @project.id)
                           .order(:name, :id)
    end

    def show
      run
      render :show, status: outcome_status
    end

    # The PDF. This is the entry point `Render::BatchGuard` was written for, and the 422
    # below is T-15's first owed acceptance item: a refusal that names the cap and the
    # count, from a controller, before anything is rendered.
    def document
      run(pdf: true)
      return respond_to_failure(outcome_status) if @diagnostic

      send_document
    end

    # ------------------------------------------------------------------ authoring

    def new
      @template = Template.new(project_id: @project.id,
                               author_id: User.current.id,
                               visibility: Template::VISIBILITY_PRIVATE)
      apply_starter
      lint_editor
    end

    def create
      @template = Template.new(template_params)
      # NEVER FROM PARAMS, EITHER OF THEM. `author_id` decides who `edit_own_…` lets
      # through and `project_id` decides which project's permissions are checked, so a
      # request able to set them could grant itself both.
      @template.project_id = @project.id
      @template.author_id = User.current.id
      apply_visibility(@template)

      if @template.save
        flash[:notice] = l(:notice_successful_create)
        redirect_to project_reporter_template_path(@project, @template)
      else
        # THE PANEL IS ON THE 422 TOO. A rejected save re-renders the editor, and the
        # findings are about the body the author is looking at — leaving `@lint` nil here
        # would raise in the partial, which is the failure mode a view-level `if` would
        # hide instead of fixing.
        lint_editor
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      lint_editor
    end

    def update
      @template.attributes = template_params
      apply_visibility(@template)

      if @template.save
        flash[:notice] = l(:notice_successful_update)
        redirect_to project_reporter_template_path(@project, @template)
      else
        lint_editor
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @template.destroy
      flash[:notice] = l(:notice_successful_delete)
      redirect_to project_reporter_templates_path(@project)
    end

    # THE PREVIEW RENDERS WHAT IS IN THE EDITOR, not what is in the database, which is the
    # only thing that makes it a preview. The content arrives in the request body and is
    # applied to an unsaved copy — so nothing is written, and an author who has not saved
    # still sees their own work.
    def preview
      @template = preview_subject
      # THE LINT IS OF WHAT WAS SUBMITTED, and it happens BEFORE the blocking-error return
      # below: a template refused for a bad page size still shows its findings, because the
      # page it lands on is the editor and an author fixing one problem should not have the
      # other list disappear.
      lint_editor
      # VALIDATED BEFORE IT IS RUN, and `#create`/`#update` are why this was not already
      # covered: they validate on save, and preview is the one action whose subject goes
      # from the request body straight into a render. Without this,
      # `template[margins]=a,b,c,d` reaches `Integer('a')` and `template[page_size]=A9`
      # reaches `DocumentRequest`'s closed list — an unhandled 500 from any holder of one
      # authoring permission.
      #
      # ONLY the attributes the render actually reads block it. A draft with no name yet
      # is exactly what somebody previews first, and refusing that would make the feature
      # useless at the moment §9b.2 says it is worth most.
      return render(:preview, status: :unprocessable_entity) if preview_blocking_errors?

      @outcome = Reporting::ReportRun.preview(template: @template,
                                              actor: User.current,
                                              scope: report_scope,
                                              query: @query,
                                              guard: batch_guard,
                                              logger: Rails.logger).call(pdf: true)
      @diagnostic = @outcome.diagnostic
      # A FAILED PREVIEW IS STILL A 200. It is the editor answering "here is what your
      # template does", and what it does is fail — that is the answer, not an error in
      # serving the page. §9b.2 puts the diagnostics view "in the editor, next to the
      # code", and a 5xx would let a proxy or a fetch() wrapper replace it with its own.
      render :preview
    end

    # ------------------------------------------------------------------ exchange

    # T-29 — THE EXPORT IS NOW A BUNDLE, which is the format FR-55 names.
    #
    # It used to be `Exchange.dump`'s `{format_version, template}`, a T-23 stopgap whose
    # own comment said T-29 would wrap it. One template is exported as a bundle CARRYING
    # ONE TEMPLATE rather than as a second file format: two shapes for one thing is
    # CLAUDE.md §6's "second way of doing something that already has a way", and the one
    # that drifts is always the one without a caller.
    #
    # Nothing stops reading the old shape — `Bundle.parse` accepts `{'template' => …}`,
    # the base plugin's two spellings, and a bare attribute Hash — so a file exported by
    # this button last month still imports today. That asymmetry is the same one §7b.2
    # takes about YAML: read what exists, write one thing.
    def export
      send_data Reporting::Bundle.dump([@template],
                                       exported_at: Time.now.utc.iso8601,
                                       plugin_version: reporter_plugin_version),
                filename: download_filename(@template, 'json'),
                type: 'application/json',
                disposition: 'attachment'
    end

    def import
      file = params[:file]
      return refuse_import(l(:error_reporter_template_import_no_file)) if file.blank?
      return refuse_import(l(:error_reporter_template_import_no_file)) unless file.respond_to?(:read)

      # `Bundle.parse`, NOT `Exchange.parse`, AND THE DIFFERENCE WAS A SILENT DROP.
      #
      # `Exchange.parse` answers the FIRST template in a document. T-29 made
      # `rake exchange:export` write multi-template bundles and left this action on the
      # single-template reader — so uploading a bundle of twelve templates imported one and
      # answered "created", which is the failure mode `Bundle.parse`'s own comment names:
      # *"it would look exactly like a successful import of a smaller file."* Found by an
      # independent review.
      #
      # A MULTI-TEMPLATE BUNDLE IS REFUSED HERE RATHER THAN IMPORTED. This form creates one
      # template and redirects to its editor; importing twelve needs a conflict policy and a
      # per-template report, which is what `import:plan` / `import:run` are. The
      # refusal NAMES THE COUNT and points at the tasks, which is the shape T-15's cap
      # refusal established — a refusal that says what you asked for and what to do instead.
      # BOUNDED BEFORE IT IS PARSED, and before `#read` pulls the whole upload into this
      # process. `Bundle::MAX_BYTES` bounds the parser, which is one `read` too late on a
      # path where the size is knowable in advance — an uploaded file answers `#size`.
      # T-29 introduced that bound and applied it only to the rake path; this is the same
      # bound on the path an anonymous-ish request can reach.
      if file.respond_to?(:size) && file.size.to_i > Reporting::Bundle::MAX_BYTES
        return refuse_import(l(:error_reporter_template_import_too_large,
                               limit: Reporting::Bundle::MAX_BYTES))
      end

      parsed = Reporting::Bundle.parse(file.read)
      if parsed.entries.length > 1
        return refuse_import(l(:error_reporter_template_import_many,
                               count: parsed.entries.length))
      end

      @template = Template.new(importable_attributes(parsed.entries.first))
      @template.project_id = @project.id
      @template.author_id = User.current.id
      # AN IMPORTED TEMPLATE IS PRIVATE TO ITS IMPORTER whatever the file said. A bundle is
      # a file somebody was handed; letting it choose its own visibility would let the
      # sender decide who in the receiving organisation can see it, and
      # `manage_public_…` exists precisely so that decision is a role grant made here.
      @template.visibility = Template::VISIBILITY_PRIVATE

      if @template.save
        flash[:notice] = l(:notice_successful_create)
        redirect_to edit_project_reporter_template_path(@project, @template)
      else
        refuse_import(@template.errors.full_messages.join(', '))
      end
    rescue Reporting::Bundle::InvalidBundle => e
      # NOT `rescue Exception`, and not a bare rescue either: the only thing caught here is
      # "this file is not a template bundle", which is a message for the person who chose
      # the file. Anything else is a defect and must reach the log as one.
      refuse_import(e.message)
    end

    private

    # ------------------------------------------------------------------ guards

    def require_reports_module
      render_404 unless @project.module_enabled?(:reporter_dashboards_reports)
    end

    # NAMED `require_create_permission`, and the obvious name for it is deliberately not
    # used. `permission_map_spec.rb` asserts that no file under `app/`, `lib/`, `db/` or
    # `init.rb` mentions Redmine's role-granting API — the mechanical form of "this plugin
    # grants nothing to any role" — and the obvious name for this guard contains that API's
    # name as a substring, so it trips the check. Renaming the method was the option that
    # did not involve loosening a security check to fit a method name. Do not rename it
    # back; the spec will tell you, but this says why.
    def require_create_permission
      deny_access unless User.current.allowed_to?(:add_reporter_dashboards_templates,
                                                  @project)
    end

    # PER TEMPLATE, not per project, and this is the guard `edit_own_…` lives or dies by.
    # `Template#editable_by?` is where "own" means `author_id` — a holder of `edit_own_…`
    # looking at somebody else's template is refused here, and the functional suite tests
    # exactly that case because it is the one that looks right until it is tried.
    def require_edit_permission
      deny_access unless @template.editable_by?(User.current)
    end

    # THE CONJUNCTION REDMINE CANNOT EXPRESS. §4.1: *"Import **is** authoring… a weaker
    # permission of its own would be a way around the authoring one"*, so it needs both
    # halves — the one that creates a template and the one that writes its content.
    def require_import_permissions
      missing = %i[add_reporter_dashboards_templates
                   edit_reporter_dashboards_templates]
                .reject { |permission| User.current.allowed_to?(permission, @project) }

      deny_access unless missing.empty?
    end

    # The template a preview is BASED on, when the editor is previewing a saved one.
    # Resolved in its own filter so the permission check below has a record to ask about
    # — and 404s for a template this actor cannot see, exactly as `#show` does.
    def find_preview_base
      return if params[:id].blank?

      @preview_base = Template.where(project_id: @project.id).find_by(id: params[:id])
      render_404 if @preview_base.nil? || !@preview_base.visible?(User.current)
    end

    # A preview EXECUTES the content of the request body, so `view_…_reports` must never
    # reach it or the consuming permission would carry a code-execution path.
    #
    # TWO CASES, AND THE FIRST VERSION OF THIS METHOD HAD ONLY THE SECOND — which was a
    # disclosure hole rather than a missing nicety. `#preview` accepts an `id`, and with
    # only "does this actor hold any authoring permission" to satisfy, a holder of
    # `add_…` (who may create templates and edit none) could POST the id of somebody
    # else's PRIVATE template with no content of their own, and the preview would render
    # and display that template's output. Found by walking the parameters rather than the
    # permissions.
    #
    #   with an id     this is an EDIT of that template, so it needs `#editable_by?` —
    #                  the same per-record question `edit_own_…` turns on
    #   without an id  this is a draft that exists only in the request, so any one of the
    #                  three authoring permissions is enough: all three are the
    #                  code-execution class, and nothing is being read that the actor
    #                  did not send
    def require_preview_permission
      deny_access unless preview_permitted?
    end

    def preview_permitted?
      return @preview_base.editable_by?(User.current) if @preview_base

      %i[add_reporter_dashboards_templates
         edit_reporter_dashboards_templates
         edit_own_reporter_dashboards_templates]
        .any? { |permission| User.current.allowed_to?(permission, @project) }
    end

    def find_template
      @template = Template.where(project_id: @project.id).find(params[:id])
      # 404 AND NOT 403 FOR AN INVISIBLE TEMPLATE, because 403 confirms it exists.
      # Redmine's own `find_query` renders 403 for an unviewable query and this
      # deliberately differs: a saved query's existence is not the thing being protected,
      # and a private template's is.
      render_404 unless @template.visible?(User.current)
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    # ------------------------------------------------------------------ params

    # Strong params. `visibility` and `role_ids` are NOT in the list — they are applied by
    # `apply_visibility` after a permission check, the way core's
    # `update_query_from_params` does it. `source` IS in the list from T-31 on — it names a
    # TABLE rather than an identity, and both tables are read through their own `visible`
    # scope, so the `render_as_user_id` reasoning in HANDOVER §1 does not transfer. An
    # independent review confirmed it: a non-owner PATCHing `source` onto somebody else's
    # public template gets 403 and the column does not move.
    def template_params
      # `failure_document` IS SAFE TO PERMIT, and it is worth saying why rather than
      # assuming it. HANDOVER §1's rule is that a field NAMING A USER is a privilege field
      # and `permit` is not a filter; this one names no identity, widens no visibility and
      # selects no engine — it decides whether a refusal answers with a page or with a PDF
      # saying the same three facts. The action already requires an authoring permission on
      # this template.
      # `source` IS PERMITTED FROM T-31 ON, and it was not before because there was only
      # one. It names a TABLE, not an identity: both sources resolve through their model's
      # own `visible` scope, so an author choosing `time_entries` gets exactly the hours
      # they may already read in the time-entry list. The model's `inclusion:` validation
      # and `ReportRun`'s closed-set check are what stop a third value.
      permitted = %i[name description content source output orientation page_size margins
                     enabled]
      permitted << :failure_document if Template.failure_document_supported?
      params.require(:template).permit(*permitted)
    end

    # Core's rule (`queries_controller.rb:139`) applied to templates: without
    # `manage_public_…` the visibility is forced to PRIVATE rather than the request being
    # rejected. Rejecting would be worse for the common case — a member without the
    # permission simply cannot publish — and forcing is the behaviour an administrator
    # already knows from saved queries.
    def apply_visibility(template)
      unless template.visibility_editable_by?(User.current)
        template.visibility = Template::VISIBILITY_PRIVATE
        template.role_ids = []
        return
      end

      attributes = params[:template] || {}
      template.visibility = attributes[:visibility].to_i if attributes.key?(:visibility)
      template.role_ids = Array(attributes[:role_ids]).reject(&:blank?)
    end

    # A saved template is previewed as a COPY carrying the editor's content, so the stored
    # row cannot be modified by a preview even by accident — `dup` drops the id, so
    # nothing downstream can save it either. `@preview_base` is kept separately because
    # the view needs it to address the record the copy no longer identifies.
    #
    # --- THE ROLE LIST IS CARRIED OVER, AND WITHOUT THIS IT WAS A DATA LOSS (T-37) ---
    #
    # `dup` drops the id, and a HABTM reads through the id, so `subject.roles` on the copy
    # is EMPTY however many roles the stored template has. That cost nothing while the
    # preview page had no form on it. T-37 put the editor there, so the visibility
    # fieldset would have rendered every role UNTICKED — and pressing Save from the preview
    # page would then have cleared the role list of a `visibility: roles` template, quietly,
    # on a page whose entire purpose is that it changes nothing until you save.
    #
    # Assigning `role_ids` on an unsaved record builds the association in memory only;
    # nothing here writes, which `assert_no_difference` on the join table asserts.
    def preview_subject
      subject = (@preview_base || Template.new).dup
      subject.project_id = @project.id
      subject.author_id = @preview_base&.author_id || User.current.id
      subject.role_ids = @preview_base.role_ids if @preview_base
      subject.attributes = template_params if params[:template].present?
      subject
    end

    # ------------------------------------------------------------------ T-37, the gallery

    # FR-73 — *"New template offers a starter gallery"*, and the mechanism is one GET.
    #
    # `?starter=chart-report` prefills the form from a file this plugin ships. It is a plain
    # link, so it works with no JavaScript, it is bookmarkable, and the prefilled body goes
    # through the ordinary editor — which means the lint panel below it immediately shows
    # zero findings on a starter, which is the first thing an author should see a clean
    # template look like.
    #
    # THE ID NEVER TOUCHES A PATH. `StarterGallery.find` is a lookup in a frozen Hash and
    # answers nil for anything else; the file name is a constant on the entry it returns. A
    # path assembled from a parameter is the traversal FR-55 refuses for the same reason one
    # layer up, and "the value is validated" is what every such loader has said.
    #
    # AN UNKNOWN ID IS SAID OUT LOUD. Ignoring it silently would leave an author looking at a
    # blank form having asked for an example, wondering which of the two of them is broken.
    def apply_starter
      requested = params[:starter].to_s
      return if requested.empty?

      @starter = StarterGallery.find(requested)
      if @starter.nil?
        flash.now[:warning] = l(:text_reporter_starter_unknown)
        return
      end

      # The NAME is prefilled too, from the starter's own translated label, so the form is
      # valid the moment it loads: a first save that fails on a blank name teaches an author
      # that this is fiddly rather than that it works.
      @template.name = l(@starter.name_key)
      @template.source = @starter.source
      @template.output = @starter.output
      @template.content = StarterGallery.body(@starter)
    end

    # ------------------------------------------------------------------ T-37, the lint

    # FR-71 — THE FINDINGS THE EDITOR SHOWS, FROM THE LINTER THE RAKE TASK RUNS.
    #
    # One call, in one place, so `new`, `edit`, the two 422s and `preview` cannot come to
    # lint different things. `TemplateLinter.analyse` is the whole of it: the panel adds no
    # rule, suppresses none, and re-orders nothing —
    # `test/functional/reporter_dashboards_lint_parity_test.rb` runs this path and
    # `rake reporter_dashboards:lint_templates` over one fixture and compares the finding
    # lists, which is the assertion T-37's `Accept:` line asks for.
    #
    # `@template.content.to_s` because a brand-new template's content is nil and a body of
    # nil is a template with no findings rather than a missing panel.
    def lint_editor
      @lint = TemplateLinter.analyse(@template.content.to_s)
    end

    # ------------------------------------------------------------------ running

    def run(pdf: false)
      # `issue_scope` FIRST, ON ITS OWN LINE. It assigns `@query` as a side effect, and
      # reading both in one argument list made the binding depend on keyword evaluation
      # order — reorder the two keywords and the report silently loses its query, with
      # nothing raising anywhere.
      scope = report_scope

      @outcome = Reporting::ReportRun.new(template: @template,
                                          actor: User.current,
                                          scope: scope,
                                          query: @query,
                                          guard: batch_guard,
                                          output_class: :report,
                                          logger: Rails.logger).call(pdf: pdf)
      @diagnostic = @outcome.diagnostic
    end

    # 422 FOR A REFUSAL, 500 FOR A FAILURE, 200 FOR NEITHER — in ONE place, because the
    # first version answered this question twice and `#show` got it wrong: a per-record
    # template over the cap returned 500 Internal Server Error for "you asked for too
    # many documents", which is the opposite of T-15's point and pages an operator.
    # A CLOSED SET READ THROUGH AN `else` IS NOT CLOSED, and this method was the second
    # instance of that in F-16's own change — the first was
    # `TemplatesHelper#reporter_diagnostic_headline`, which the change fixed while leaving
    # this one, so a new origin was labelled correctly and given the wrong status code.
    #
    # `:assets` belongs with `:batch`, not with `:engine`. Both are refusals of a
    # well-formed request decided BEFORE any engine started: a member pastes a CDN image
    # URL into a template, and a 500 pages an operator for something no server fault
    # caused. The comment below this method already argues exactly that for the cap
    # refusal — *"which is the opposite of T-15's point and pages an operator"* — and the
    # argument did not become weaker for having a second instance.
    #
    # `REFUSAL_ORIGINS` rather than a second `||`: the next origin added must be a
    # decision somebody takes here, and `Diagnostic::ORIGINS` minus this set is the list
    # of origins that really are server faults.
    REFUSAL_ORIGINS = %i[batch assets].freeze

    def outcome_status
      return :ok unless @diagnostic
      return :unprocessable_entity if REFUSAL_ORIGINS.include?(@diagnostic.origin)

      :internal_server_error
    end

    # T-31: WHICH TABLE, DECIDED BY THE TEMPLATE'S OWN `source` COLUMN — and decided in
    # `Reporting::ReportScope`, not here.
    #
    # It used to be decided here, and `ScheduledDelivery` decided it separately and got it
    # wrong: a `source: time_entries` schedule rendered `Issue.visible` and mailed the issue
    # count as a success. Two callers answering the same question is what produced that, so
    # there is one answer now and this method is the thin half of it — the side effect on
    # `@query`, which the view needs for its picker.
    #
    # THE SCOPE THE PICKER OFFERS IS STILL THE SCOPE THE TEMPLATE RESOLVES THROUGH (T-23's
    # `Accept:`): the picker lists queries this actor may already open, and `ReportScope`
    # starts from the model's own `visible` scope either way, so the relation handed to the
    # render is visibility-scoped before it leaves that module — which is what INV-1/INV-3
    # ask of the application layer.
    def report_scope
      scope, @query = Reporting::ReportScope.build(template: @template,
                                                   actor: User.current,
                                                   project: @project,
                                                   query_id: params[:query_id])
      scope
    end

    # The attributes `Reporting::ReportRun` reads on its way to a `DocumentRequest`. An
    # invalid value in any of them raises rather than degrading, so these are the ones a
    # preview has to refuse; everything else is the author's business until they save.
    PREVIEW_BLOCKING_ATTRIBUTES = %i[margins page_size orientation output source].freeze

    def preview_blocking_errors?
      @template.validate

      (@template.errors.attribute_names & PREVIEW_BLOCKING_ATTRIBUTES).any?
    end

    def batch_guard
      Render::BatchGuard.new(logger: Rails.logger)
    end

    def render_show(status)
      render :show, status: status
    end

    def send_document
      documents = @outcome.documents

      # ZERO DOCUMENTS IS NOT A FILE. A per-record template over a scope that matched
      # nothing produces an empty batch, and `documents.first.bytes` on that is a
      # NoMethodError — a 500 for a request that is merely empty. Refused with a sentence
      # instead, and the page it renders says the same thing.
      if documents.empty?
        @diagnostic = Reporting::Diagnostic.new(
          origin: :batch, code: :no_documents, template_name: @template.name,
          # A MINTED ID, not the literal '-' this used to carry. Both refusals tell the
          # reader to quote the correlation id, and `-` identifies nothing while an empty
          # one drew the label with nothing beside it. `ReportRun` already mints one for
          # its own refusal (`cap_refusal_for_count`) for exactly this reason.
          message: l(helpers.reporter_source_key(:text_reporter_template_no_issues,
                                                @template.source)),
          correlation_id: SecureRandom.uuid
        )
        return respond_to_failure(:unprocessable_entity)
      end

      # T-29 — MORE THAN ONE DOCUMENT IS AN ARCHIVE, and the 501 that used to be here is
      # gone. §Findings E-6's third bullet and ~~S-12~~ (curator, 2026-08-08) made this
      # T-29's alone.
      return stream_archive(documents) if documents.length > 1

      document = documents.first
      send_data document.bytes,
                filename: download_filename(@template, 'pdf'),
                type: 'application/pdf',
                disposition: 'attachment'
    end

    # T-29 / §Findings E-6 — the archive. **BUFFERED, by curator decision (S-23,
    # 2026-08-09), and this comment is the argument for it rather than an apology.**
    #
    # --- WHAT WAS TRIED FIRST, AND WHY IT WAS ABANDONED ---
    #
    # E-6's bullet asks for a "streamed archive with no `Content-Length`", and T-29 shipped
    # one: `ZipStream` yields the zip in pieces and this action handed that object to Rack.
    # Measured through Redmine's REAL middleware stack, that did not do what it says.
    # `Rack::ContentLength` and `Rack::ETag` both gate on `body.respond_to?(:to_ary)`, and
    # `ActionDispatch::Response::Buffer#to_ary` is defined UNCONDITIONALLY — so a controller
    # cannot opt out of either, `Rack::ETag` digested the whole archive before the first
    # byte could leave, and the body was then re-enumerated for the wire. Two full
    # generations, measured by counting pulls from the entry source: 0 -> 22 -> 44.
    #
    # So the choice was never "streamed or buffered". It was "buffered once, honestly" or
    # "generated twice while calling itself streamed". The curator took the first.
    #
    # --- WHAT THIS COSTS AND WHY IT IS ACCEPTABLE ---
    #
    # The archive is held in memory once. `Render::BatchGuard`'s cap bounds it at 50
    # documents, and those 50 PDFs are ALREADY in memory by the time this method runs —
    # `ReportRun` rendered them all before any failure decision was made, deliberately, so
    # that a failure at document 7 of 50 is still a proper error page rather than a
    # truncated archive behind a `200 OK`. The zip adds roughly the same bytes again, which
    # is the whole of the regression, and it buys a `Content-Length` — so a browser shows a
    # percentage instead of a growing file, and a proxy can no longer mistake a half-written
    # response for a complete one.
    #
    # `ZipStream` is unchanged and still lazy. Nothing here depends on it being eager; this
    # method simply drains it, and `spec/archive/zip_stream_spec.rb` still asserts the
    # writer yields before its source is exhausted. That is deliberate: if a future task
    # moves this onto `ActionController::Live`, the writer is already the right shape and
    # only this method changes.
    def stream_archive(documents)
      sections = @outcome.sections

      # THE TWO LISTS ARE PAIRED BY POSITION, so a length mismatch would mean silently
      # labelling one issue's report with another issue's number — a wrong answer that
      # looks like a right one. It cannot happen today (a batch with any failure never
      # reaches here), which is exactly why it is checked rather than assumed: the
      # invariant is somebody else's to maintain.
      if sections.length != documents.length
        raise "the archive has #{documents.length} documents for #{sections.length} " \
              'sections; they are paired by position and must be the same length'
      end

      entries = sections.each_with_index.map do |section, index|
        Archive::ZipStream::Entry.new(name: archive_entry_name(section, index),
                                      bytes: documents[index].bytes)
      end

      send_data archive_bytes(entries),
                filename: download_filename(@template, 'zip'),
                type: 'application/zip',
                disposition: 'attachment'
    end

    # DRAINED HERE, IN ONE PLACE. `send_data` needs a String; the writer produces chunks.
    # Joining them is the whole of the buffering decision, and keeping it in its own method
    # is what makes reverting it a one-line change if S-23 is ever revisited.
    def archive_bytes(entries)
      out = +''.b
      Archive::ZipStream.new(entries: entries, mtime: Time.now.utc).each { |chunk| out << chunk }
      out
    end

    # `<template>-<record id>.pdf`, and the id rather than the label because `Job#label`
    # is `"#123"` — a `#` in a zip member name is legal and awful, and the name is also a
    # FILENAME the moment somebody unpacks it. `download_filename`'s closed character set
    # is reused for the stem for exactly the reasons its own comment gives, and
    # `ZipStream` resolves any collision that survives, so two records whose sanitised
    # names agree cannot silently become one member.
    def archive_entry_name(section, index)
      record_id = section.job.record&.id || (index + 1)
      stem = download_filename(@template, 'pdf').sub(/\.pdf\z/, '')

      "#{stem}-#{record_id}.pdf"
    end

    # The version an export stamps itself with, and `nil` rather than a raise when the
    # plugin is not registered — which is every controller spec that does not boot the
    # registry. A bundle whose provenance is unknown is still a bundle.
    def reporter_plugin_version
      Redmine::Plugin.find(:redmine_reporter_dashboards)&.version
    rescue Redmine::PluginNotFound
      nil
    end

    # §7 rule 5 on the import side — see `Reporting::Exchange.assignable`. Without it a
    # bundle written by a current install and uploaded to one whose schema is a minor
    # behind raised `ActiveModel::UnknownAttributeError` from `Template.new`.
    def importable_attributes(attributes)
      kept, dropped = Reporting::Exchange.assignable(attributes, Template.column_names)

      unless dropped.empty?
        # VISIBLE, NOT SILENT (INV-4). The template that arrived is not the template that
        # was sent, and the person who chose the file is standing right here.
        Rails.logger.warn("[exchange] this installation's schema has no " \
                          "#{dropped.join(', ')} column, so the uploaded template was " \
                          'imported without it')
        flash[:warning] = l(:warning_reporter_template_import_fields_dropped,
                            fields: dropped.join(', '))
      end

      kept
    end

    # T-30 / FR-59 — the failure document, and the ONE place that decides whether there
    # is one.
    #
    # --- WHY ONLY `#document`, AND NOT `#show` OR `#preview` ---
    #
    # A failure document exists because somebody asked for a FILE and there is no report to
    # give them. `#show` and `#preview` are pages; §9b.2 puts the diagnostics panel there
    # and a page that downloads a PDF instead of answering is a worse page. So the panel is
    # what those two render, always, and this action is the only one that can produce a
    # document — which also means the feature adds no second render path and no second
    # place a failure is decided.
    #
    # --- THE STATUS IS THE FAILURE'S STATUS, NOT 200 ---
    #
    # A 200 carrying a document that says "this is not your report" is the shape INV-5
    # exists to forbid, one layer up: every automated consumer of this endpoint — a script,
    # a monitor, a `curl` in a cron entry — would record a success. The bytes are honest and
    # so is the status line, and a browser still offers the file.
    def respond_to_failure(status)
      return render_show(status) unless @template.failure_document?

      failure = Reporting::FailureDocument.new(
        diagnostic: @diagnostic,
        generated_at: format_time(Time.current),
        # `I18n.t` and not `l`: the helper resolves against the CURRENT locale and this
        # needs to be able to ask for a second one (see `FailureDocument#text`).
        translate: ->(key, locale) { ::I18n.t(key, locale: locale) },
        locale: ::I18n.locale
      )

      if failure.locale_degraded?
        # VISIBLE RATHER THAN SILENT (INV-4). The document is still correct and still
        # readable; what it is not is written in the locale it was asked for, and an
        # operator wondering why their Russian install mailed them English prose has one
        # line to find.
        Rails.logger.warn("[reporting] failure document for correlation_id=" \
                          "#{@diagnostic.correlation_id} fell back to English: locale " \
                          "#{::I18n.locale} is outside the base-14 font encoding")
      end

      send_data failure.bytes,
                filename: failure.filename,
                type: failure.content_type,
                disposition: 'attachment',
                status: status
    end

    def refuse_import(message)
      flash.now[:error] = message
      index
      render :index, status: :unprocessable_entity
    end

    # A CLOSED CHARACTER SET, not a blocklist. Redmine's own `sanitize_filename` is
    # private on `Attachment` and not reachable from a controller, and a filename reaches
    # a `Content-Disposition` header and somebody's filesystem: a name carrying `/`, `\`,
    # a quote or a newline is a path or a header injection depending on where it lands.
    # Anything outside the set becomes `_`, and an empty result falls back to a fixed word
    # rather than to an extension with nothing in front of it.
    def download_filename(template, extension)
      # TRUNCATE, THEN STRIP. The other order lets the cut reintroduce the trailing
      # underscore the strip just removed.
      stem = template.name.to_s.gsub(/[^0-9A-Za-z._-]+/, '_')[0, 100]
                              .gsub(/\A[_.]+|[_.]+\z/, '')
      stem = 'report' if stem.blank?

      "#{stem}.#{extension}"
    end
  end
end
