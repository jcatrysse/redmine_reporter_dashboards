# frozen_string_literal: true

module ReporterDashboards
  # T-23 — the plugin's FIRST OWNED HTTP ENTRY POINT.
  #
  # Everything before this task built a layer that nothing called. `RenderContext` had no
  # producer, the drops had no constructor, `render/` had no caller and `BatchGuard` had
  # no batch. This controller is where all four acquire one, which is why finding E-6
  # said T-15's two owed assertions had to wait for it: *"a cap with no caller is a cap
  # nobody has seen refuse anything"*.
  #
  # --- AUTHORIZATION IS PER ACTION, AND THE `authorize` LINE IS ONLY THE FIRST HALF ---
  #
  # `before_action :authorize` is UNSCOPED here on purpose — no `only:`, no `except:`, no
  # `skip_before_action` — because the review of T-40 defeated a per-controller check with
  # exactly those two lines, and `spec/permissions/permission_map_spec.rb` now reads them
  # out of the AST.
  #
  # But `authorize` alone is not the guard this surface needs, and that is the second
  # half. Redmine's `authorize` passes when the actor holds **any** permission mapping the
  # action, so with `manage_public_…` mapped to `#create` — which it must be, because that
  # is where the visibility decision is made and it is core's own shape for
  # `manage_public_queries` — a role holding only that one permission would otherwise
  # reach a code-execution endpoint. And *"import requires `add_…` **and** `edit_…`"* is a
  # conjunction Redmine's permission model cannot express at all.
  #
  # So each group of actions carries an explicit second guard naming the permission it
  # really needs, and the functional suite holds each permission ALONE and asserts 403 on
  # everything it must not reach:
  #
  #   authorize                  the action is mapped and this role holds one of them
  #   require_create_permission  new/create really need the create permission
  #   require_edit_permission    edit/update/destroy/export need an edit permission FOR
  #                              THIS TEMPLATE — which is where edit_own_ differs
  #   require_import_permissions import needs BOTH authoring permissions
  #   require_preview_permission preview RUNS the template, so it needs an authoring one
  class TemplatesController < ApplicationController
    # The plugin's `lib/` is not on Redmine's autoload paths; these are shorter names for
    # constants `lib/redmine_reporter_dashboards.rb` has already required at boot. The
    # same pattern as `ReporterPreflightController`.
    Reporting = RedmineReporterDashboards::Reporting
    Render = RedmineReporterDashboards::Render
    Template = RedmineReporterDashboards::Template

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
      return render_show(outcome_status) if @diagnostic

      send_document
    end

    # ------------------------------------------------------------------ authoring

    def new
      @template = Template.new(project_id: @project.id,
                               author_id: User.current.id,
                               visibility: Template::VISIBILITY_PRIVATE)
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
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      @template.attributes = template_params
      apply_visibility(@template)

      if @template.save
        flash[:notice] = l(:notice_successful_update)
        redirect_to project_reporter_template_path(@project, @template)
      else
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
                                              scope: issue_scope,
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

    def export
      send_data Reporting::Exchange.dump(@template),
                filename: download_filename(@template, 'json'),
                type: 'application/json',
                disposition: 'attachment'
    end

    def import
      file = params[:file]
      return refuse_import(l(:error_reporter_template_import_no_file)) if file.blank?
      return refuse_import(l(:error_reporter_template_import_no_file)) unless file.respond_to?(:read)

      @template = Template.new(Reporting::Exchange.parse(file.read))
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
    rescue Reporting::Exchange::InvalidBundle => e
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
    # `update_query_from_params` does it. Neither is `source`: see below.
    def template_params
      params.require(:template).permit(:name, :description, :content, :output,
                                       :orientation, :page_size, :margins, :enabled)
    end

    # Core's rule (`queries_controller.rb:139`) applied to templates: without
    # `manage_public_…` the visibility is forced to PRIVATE rather than the request being
    # rejected. Rejecting would be worse for the common case — a member without the
    # permission simply cannot publish — and forcing is the behaviour an administrator
    # already knows from saved queries.
    #
    # `source` is deliberately absent from the form and from the permitted params:
    # `time_entries` has no scope builder until T-31, and a picker offering a value that
    # cannot render is a promise the plugin does not keep. The COLUMN still accepts it, so
    # an imported template keeps its value and the run refuses it with a message naming
    # the task rather than quietly reporting on the wrong table.
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
    # the view needs it for the link back to the editor, which the copy cannot provide.
    def preview_subject
      subject = (@preview_base || Template.new).dup
      subject.project_id = @project.id
      subject.author_id = @preview_base&.author_id || User.current.id
      subject.attributes = template_params if params[:template].present?
      subject
    end

    # ------------------------------------------------------------------ running

    def run(pdf: false)
      # `issue_scope` FIRST, ON ITS OWN LINE. It assigns `@query` as a side effect, and
      # reading both in one argument list made the binding depend on keyword evaluation
      # order — reorder the two keywords and the report silently loses its query, with
      # nothing raising anywhere.
      scope = issue_scope

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
    def outcome_status
      return :ok unless @diagnostic
      return :unprocessable_entity if @diagnostic.origin == :batch

      :internal_server_error
    end

    # THE SCOPE THE PICKER OFFERS IS THE SCOPE THE TEMPLATE RESOLVES THROUGH — T-23's
    # `Accept:` in one sentence.
    #
    # The picker lists `IssueQuery.visible(User.current)`, so a query chosen there is one
    # this actor may already use, and its `base_scope` starts from `Issue.visible`. With no
    # query chosen it is the project's visible issues. Either way the relation handed to
    # the render is visibility-scoped BEFORE it leaves this method, which is what
    # INV-1/INV-3 ask of the application layer: the render path never makes a visibility
    # decision because it never gets the chance.
    def issue_scope
      @query = nil
      if params[:query_id].present?
        @query = IssueQuery.visible(User.current).find_by(id: params[:query_id])
        # A query id that does not resolve is IGNORED and the project scope used instead.
        # It resolves to nothing for two different reasons — the query was deleted, or this
        # actor may not see it — and answering differently would turn the picker into a
        # probe for other people's private queries.
        return @query.base_scope if @query
      end

      Issue.visible(User.current).where(project_id: @project.id)
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
          origin: :batch, code: :no_documents,
          message: l(:text_reporter_template_no_issues), correlation_id: '-'
        )
        return render_show(:unprocessable_entity)
      end

      # ONE document is served as itself. More than one would be an archive, and building
      # one is explicitly still owed — finding E-6's third bullet, *"streamed archives with
      # no Content-Length"*. Until that exists a multi-document export is REFUSED rather
      # than silently serving the first one, which is the shape of answer this project
      # keeps deleting. The view does not offer the button in that case either; this is
      # what answers a hand-written URL.
      if documents.length > 1
        @diagnostic = Reporting::Diagnostic.new(
          origin: :batch,
          code: :archive_not_available,
          message: l(:error_reporter_template_archive_not_available, count: documents.length),
          # THE SECTION'S id, not the document's: `Render::Success` carries bytes, an
          # engine and a version and has NO `correlation_id` — the id is minted per JOB in
          # `ReportRun`. Reading it off the wrong object was a NoMethodError on the one
          # branch nothing had reached, and the strengthened archive test found it the
          # moment it stopped being shadowed by "no engine registered".
          correlation_id: @outcome.sections.first&.job&.correlation_id.to_s
        )
        return render_show(:not_implemented)
      end

      document = documents.first
      send_data document.bytes,
                filename: download_filename(@template, 'pdf'),
                type: 'application/pdf',
                disposition: 'attachment'
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
