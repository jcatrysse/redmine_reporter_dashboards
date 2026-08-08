# frozen_string_literal: true

require 'securerandom'

require_relative 'diagnostic'
require_relative '../liquid/render_context'
require_relative '../liquid/template_renderer'
require_relative '../liquid/execution_policy'
require_relative '../liquid/drops'
require_relative '../render/batch_guard'
require_relative '../render/document_request'
require_relative '../render/registry'
require_relative '../render/renderer'

module RedmineReporterDashboards
  module Reporting
    # T-23 — the thing that turns a stored template into documents.
    #
    # This is the **producer** every earlier task deliberately did not write. T-07's
    # `RenderContext` says "Nobody yet, and that is correct rather than an omission";
    # T-18's drop layer says "nothing constructs a drop yet"; T-10's `render/` says
    # "Nothing renders yet". All three named T-23. This file is where they meet, and it
    # is the first place in the plugin where an owned `RenderContext` is built from a
    # real actor and handed real drops.
    #
    # --- TWO PHASES, AND THE CAP HAS TO SIT IN FRONT OF BOTH ---
    #
    #   phase A  Liquid  template + scope           -> HTML bodies
    #   phase B  render  HTML + page geometry       -> PDF bytes
    #
    # `Render::BatchGuard` owns phase B by construction. It cannot own phase A, because
    # phase A is what PRODUCES the `DocumentRequest`s it would be handed — so a
    # per-record report over 4 000 issues would render 4 000 Liquid templates and only
    # then be refused. That is the same defect as drawing 200 PDFs before refusing, so
    # the guard is asked up front (`#cap_refusal`) and phase A does not start.
    #
    # --- WHY A TEMPLATE FAILURE ABORTS THE WHOLE PER-RECORD RUN ---
    #
    # One template produces every document in a per-record run, so a syntax error in it
    # is not "document 7 is missing", it is "this template does not work". Rendering 6 of
    # 200 and reporting a partial success would hand somebody an export with holes in it
    # and no way to tell which rows are missing. The DEADLINE is the opposite case and is
    # treated the opposite way — `BatchGuard` keeps what is finished, because there the
    # documents that exist are correct.
    class ReportRun
      # `preview` gets the widget's resource limits deliberately (see `ExecutionPolicy`):
      # an author should feel the limit at the keyboard, not at 06:00 in a scheduled run.
      OUTPUT_CLASSES = %i[report preview].freeze

      # T-31. What each source is called in a template, and what one record of it is
      # called — the two assign names, so the branch below is a lookup rather than an `if`.
      # A Hash and not two constants because adding a third source should be one line here
      # plus a scope in the controller, which is §7b.4's whole argument for a field.
      SOURCES = {
        'issues' => { collection: 'issues', record: 'issue', drop: :IssuesDrop,
                      record_drop: :IssueDrop },
        'time_entries' => { collection: 'time_entries', record: 'time_entry',
                            drop: :TimeEntriesDrop, record_drop: :TimeEntryDrop }
      }.freeze

      # §9b.2's `preview_max_issues`. A CONSTANT and not a plugin setting: FR-21b makes
      # every capability of the reporting surface a role permission, and the only two
      # settings this plugin has are installation policy about egress and delivery. A cap
      # on how much of a report an author sees while typing is neither — and a setting
      # nobody can justify changing is a setting somebody will change.
      #
      # It is shown in the UI next to the total ("Preview of 50 of 1 284 issues") rather
      # than applied silently, which is INV-4's spirit and §9b.2's requirement.
      PREVIEW_MAX_ISSUES = 50

      # AND A PREVIEW DRAWS ONE DOCUMENT, not fifty.
      #
      # `PREVIEW_MAX_ISSUES` bounds how many ISSUES a preview reads, which is the number
      # §9b.2 asks to be shown. It says nothing about how many DOCUMENTS get drawn, and
      # for a per-record template those are the same number: a preview would have started
      # fifty PDF renders in one synchronous request, bounded only by `BatchGuard`'s
      # five-minute deadline. Any member holding one authoring permission could hold a
      # worker for five minutes, repeatedly, by pressing Preview.
      #
      # One document is also the better preview: what an author is checking is whether
      # THE TEMPLATE works, and the second document tells them nothing the first did not.
      PREVIEW_MAX_DOCUMENTS = 1

      # One document to produce. `record` is nil for a combined report and the one row for
      # a per-record one — an Issue or a TimeEntry, which is why T-31 renamed it from
      # `issue`: a field whose name says issue while holding a time entry is how the next
      # reader concludes the wrong thing about a branch. The correlation id is minted HERE,
      # per document, because FR-58's whole point is that the id in the diagnostics panel
      # is the id in the log line.
      Job = Struct.new(:record, :correlation_id, :label, keyword_init: true)

      # A rendered HTML body, before any engine has seen it.
      Section = Struct.new(:job, :body, :duration_ms, keyword_init: true)

      # What a run answers. One shape whether it succeeded, failed or was refused, so a
      # view never has to ask "which of these three objects am I holding".
      Outcome = Struct.new(:sections, :documents, :diagnostic, :total_count,
                           :shown_count, :truncated, :duration_ms, :degradations,
                           :engine_id, :engine_version, :pdf_attempted,
                           keyword_init: true) do
        def ok?
          diagnostic.nil?
        end

        def truncated?
          truncated ? true : false
        end

        def pdf_attempted?
          pdf_attempted ? true : false
        end
      end

      attr_reader :template, :actor, :scope, :query, :output_class, :guard

      # A per-record PREVIEW is bounded by documents rather than by issues — see
      # `PREVIEW_MAX_DOCUMENTS`. Read through a method rather than fixed in the
      # constructor because `per_record?` raises without a scope and the constructor has
      # no business asking.
      def limit
        return @limit unless output_class == :preview
        return @limit unless template.output == 'per_record'

        PREVIEW_MAX_DOCUMENTS
      end

      # scope   an issue relation ALREADY visibility-scoped by the caller. Required for a
      #         run that has issues to show; INV-1/INV-3 make constructing it the
      #         application layer's job, and re-deriving it here would be the archaeology
      #         T-07 deleted.
      # engine  a render adapter CLASS, or nil for "resolve the configured one". Injected
      #         so a test can drive the whole pipeline without a browser.
      # template_renderer
      #         the Liquid renderer, or nil for "build the one this output class needs".
      #         A constructor port for the same reason `logger` is one (mechanism E5): the
      #         branches this class actually owns — the cap, the truncation arithmetic, an
      #         engine that is absent, a template that failed — are decisions ABOUT a
      #         render rather than a render, and a test that has to boot Liquid to reach
      #         them is a test that will not be written for all of them. The full
      #         application suite drives the real renderer end to end.
      def initialize(template:, actor:, scope:, guard:, query: nil, output_class: :report,
                     limit: nil, engine: nil, logger: nil, template_renderer: nil)
        unless OUTPUT_CLASSES.include?(output_class)
          raise ArgumentError, "#{output_class.inspect} is not a report output class"
        end
        raise ArgumentError, 'a report run needs an actor (INV-1)' if actor.nil?

        @template = template
        @actor = actor
        @scope = scope
        @query = query
        @output_class = output_class
        @limit = limit
        @guard = guard
        @engine = engine
        @logger = logger
        @template_renderer = template_renderer
      end

      # The preview: bounded, both bindings, and honest about the second one.
      def self.preview(template:, actor:, scope:, guard:, query: nil, engine: nil,
                       logger: nil, template_renderer: nil)
        new(template: template, actor: actor, scope: scope, guard: guard, query: query,
            output_class: :preview, limit: PREVIEW_MAX_ISSUES, engine: engine,
            logger: logger, template_renderer: template_renderer)
      end

      # `pdf: false` renders HTML only — the report view, and the fast half of a preview.
      def call(pdf: false)
        started = monotonic_ms

        # T-31: BOTH sources render now. What used to be here was a refusal, because
        # `source` was a column before it was a feature — see the deleted
        # `unsupported_source_diagnostic`. A value outside the closed set is still refused,
        # below, because a stored string that selects behaviour must never fall through to a
        # default branch (the shape T-25's review found reporting success while mailing one
        # person's view of the data to a list chosen for somebody else's).
        return failed(unknown_source_diagnostic, 0, started) unless known_source?

        total = count_scope

        # THE CAP IS ASKED BEFORE ANYTHING IS LOADED, let alone rendered. `document_count`
        # is arithmetic over a `COUNT(*)`, so a refused export of 40 000 per-record
        # documents costs one query and touches no ActiveRecord object at all.
        # A CORRELATION ID FOR THE REFUSAL TOO. It is minted here rather than left to
        # `BatchGuard`'s `'batch'` default, because FR-58 tells the reader to quote the id
        # from the panel and a literal word shared by every refusal in the installation
        # correlates with nothing.
        refusal = guard.cap_refusal_for_count(document_count(total),
                                              correlation_id: mint_id)
        return refused(refusal, total, started) if refusal

        jobs = build_jobs
        sections = []

        jobs.each do |job|
          section = render_section(job)
          if section.respond_to?(:failure?) && section.failure?
            return failed(Diagnostic.from_template_failure(section,
                                                           correlation_id: job.correlation_id,
                                                           template_name: template.name),
                          total, started)
          end

          sections << section
        end

        return html_only(sections, total, started) unless pdf

        with_pdf(sections, total, started)
      end

      private

      attr_reader :logger

      def count_scope
        return 0 if scope.nil?

        scope.count
      end

      # How many DOCUMENTS this run produces — which is not how many issues it reads. A
      # combined report is one document over any number of rows; a per-record report is
      # one per row, bounded by `limit` when there is one (a preview).
      def document_count(total)
        return 1 unless per_record?

        limit ? [total, limit].min : total
      end

      # How many ISSUES the reader is being shown, which is what §9b.2's
      # "preview of 50 of 1 284" counts. For a combined report that is the collection
      # drop's bound, and for a per-record one it is the number of documents.
      def shown_issue_count(total)
        return total if limit.nil?

        [total, limit].min
      end

      # THE JOB LIST IS BOUNDED BEFORE IT IS BUILT, and `limit` is applied to the SQL and
      # not to a loaded Array. A preview that loads 40 000 issues and then keeps 50 has
      # already spent the memory the bound exists to save.
      def build_jobs
        unless per_record?
          return [Job.new(record: nil, correlation_id: mint_id, label: template.name)]
        end

        bounded = limit ? scope.limit(limit) : scope
        bounded.to_a.map do |record|
          Job.new(record: record, correlation_id: mint_id, label: "##{record.id}")
        end
      end

      # A per-record template with no scope is a CALLER BUG, not a combined report.
      # Answering "combined" for it would silently produce one document where the author
      # asked for one per issue — a wrong answer that looks like a right one, which is
      # the failure mode this repository keeps deleting.
      def per_record?
        return false unless template.output == 'per_record'

        if scope.nil?
          raise ArgumentError,
                'a per-record report needs a record scope; the caller passed none'
        end

        true
      end

      def render_section(job)
        context = render_context(job)

        result = template_renderer.render(template.content.to_s,
                                          assigns: assigns_for(job, context),
                                          render_context: context,
                                          correlation_id: job.correlation_id)
        return result if result.failure?

        Section.new(job: job, body: result.body, duration_ms: result.duration_ms)
      end

      # ONE renderer for the whole run, not one per document. `TemplateRenderer` holds an
      # `ExecutionPolicy` and nothing per-render — the budget is minted inside `#render` —
      # so building 4 000 of them for a 4 000-document export would allocate 4 000
      # identical policies to no purpose.
      def template_renderer
        @template_renderer ||= ::RedmineReporterDashboards::Liquid::TemplateRenderer.new(
          policy: ::RedmineReporterDashboards::Liquid::ExecutionPolicy.new(output_class),
          logger: logger
        )
      end

      # The owned `RenderContext`, built from an explicit actor. `output:` is what decides
      # whether `{% chart %}` becomes a `<canvas>` or an `<svg>` (§6), and it follows the
      # BINDING rather than the template: the same template previewed as HTML draws a
      # canvas and rendered to PDF draws an SVG, which is FR-34's "no engine-specific
      # workaround in a template".
      def render_context(job, output: :html)
        ::RedmineReporterDashboards::Liquid::RenderContext.new(
          actor: actor,
          scope: job.record ? nil : scope_for_render,
          query: query,
          correlation_id: job.correlation_id,
          output: output,
          # SAID, NOT SNIFFED — §Findings S-13. This is what stops `{% sql_aggregate %}`
          # handing a time-entry relation to the issue kernel and getting plausible,
          # wrong numbers back.
          source: template.source.to_sym
        )
      end

      # A per-record document is about ONE issue, so the collection the template sees is
      # not the whole scope. Returning the full scope there would let `{{ issues.size }}`
      # print 4 000 on every one of 4 000 documents, each of which is about one row.
      def scope_for_render
        return scope if limit.nil? || scope.nil?

        scope.limit(limit)
      end

      def assigns_for(job, context)
        drops = ::RedmineReporterDashboards::Liquid::Drops
        assigns = {
          'template' => template.name,
          'project' => project_drop(context),
          'user' => drops::UserDrop.new(actor, context: context)
        }

        names = SOURCES.fetch(template.source.to_s)

        # `issue` / `issues` for an issue template, `time_entry` / `time_entries` for a
        # time one. The per-record variable is the RECORD and the combined one is the
        # COLLECTION, exactly as before — only the names and the drop classes move.
        if job.record
          assigns[names[:record]] = drops.const_get(names[:record_drop])
                                         .new(job.record, context: context)
        elsif scope
          assigns[names[:collection]] = drops.const_get(names[:drop])
                                             .new(scope_for_render, context: context)
        end

        assigns
      end

      def project_drop(context)
        project = template.project
        return nil if project.nil?

        ::RedmineReporterDashboards::Liquid::Drops::ProjectDrop.new(project, context: context)
      end

      # --- phase B ---------------------------------------------------------------------

      def with_pdf(sections, total, started)
        adapter = resolve_engine
        if adapter.nil?
          # NOT SILENT, and not a success either. §9b.2: a preview that only proves the
          # easy path is a false signal, so "there is no engine" is reported in the same
          # panel a crash would be, with the remedy an operator can act on.
          return failed(no_engine_diagnostic(sections), total, started,
                        sections: sections, pdf_attempted: true)
        end

        renderer = ::RedmineReporterDashboards::Render::Renderer.new(engine: adapter.new,
                                                                     logger: logger)
        batch = guard.render_all(sections.map { |section| document_request(section) },
                                 renderer: renderer)

        if batch.refused?
          return refused(batch.refusal, total, started, sections: sections)
        end

        first_failure = batch.failures.first
        if first_failure
          return failed(Diagnostic.from_render_failure(first_failure,
                                                      template_name: template.name),
                        total, started, sections: sections, pdf_attempted: true)
        end

        Outcome.new(sections: sections, documents: batch.successes, diagnostic: nil,
                    total_count: total, shown_count: shown_issue_count(total),
                    truncated: truncated?(total), duration_ms: elapsed(started),
                    degradations: batch.successes.flat_map(&:degradations),
                    engine_id: batch.successes.first&.engine,
                    engine_version: batch.successes.first&.engine_version,
                    pdf_attempted: true)
      end

      def document_request(section)
        ::RedmineReporterDashboards::Render::DocumentRequest.new(
          body: section.body,
          correlation_id: section.job.correlation_id,
          page_size: template.page_size,
          orientation: template.orientation.to_sym,
          margins_mm: margins
        )
      end

      # `margins` is "top,right,bottom,left" in millimetres, validated by the model's
      # `MARGINS_FORMAT`. Blank means "the request's own default", which is where the
      # documented default lives — duplicating it here would give the plugin two.
      def margins
        # `to_s.strip.empty?` and not `blank?`: nothing else in this file needs
        # ActiveSupport, and not needing it is what lets the whole decision surface be
        # driven in the DB-less suite rather than only inside a booted Redmine.
        if template.margins.to_s.strip.empty?
          return ::RedmineReporterDashboards::Render::DocumentRequest::DEFAULT_MARGINS_MM
        end


        top, right, bottom, left = template.margins.split(',').map { |part| Integer(part) }
        { top: top, right: right, bottom: bottom, left: left }
      end

      # `engine_hint` is READ THROUGH THE MODEL'S DEGRADING READER, not off the column.
      # §7 rule 5: an install whose schema is one minor behind must not 500 here, and
      # `engine_hint_or_nil` answers nil rather than raising when the column is absent.
      #
      # A hint naming an engine that is not registered is IGNORED with a log line rather
      # than being an error: the template was authored somewhere that had the engine, and
      # refusing to render it here would make a portable template unportable. The
      # configured default draws it instead, and the degradation is visible in the run.
      def resolve_engine
        return @engine if @engine

        registry = ::RedmineReporterDashboards::Render::Registry
        hint = template.engine_hint_or_nil
        named = !hint.to_s.strip.empty?
        return registry.fetch(hint) if named && registry.registered?(hint)

        if named
          warn_line("[reporting] template #{template.id} asks for engine #{hint.inspect}, " \
                    "which is not registered; using the configured default")
        end

        id = registry.ids.first
        id && registry.fetch(id)
      end

      # A CLOSED SET, AND `else` IS NOT A BRANCH. `Template` validates `source` on save, and
      # that is not enough on its own: `update_columns` and `update_all` bypass validation
      # and this plugin uses both, and §7 rule 5 makes "an install one minor behind reading
      # a newer row" routine. So the set is closed HERE too, where the behaviour is chosen.
      def known_source?
        SOURCES.key?(template.source.to_s)
      end

      def unknown_source_diagnostic
        Diagnostic.new(
          origin: :template,
          code: :unsupported_source,
          template_name: template.name,
          message: "this template reports on #{template.source.inspect}, which is not a " \
                   'data source this version of the plugin knows',
          correlation_id: mint_id,
          detail: "template=#{template.id} source=#{template.source}"
        )
      end

      def no_engine_diagnostic(sections)
        Diagnostic.new(
          origin: :engine,
          code: :engine_unavailable,
          template_name: template.name,
          message: 'no render engine is registered, so no PDF could be produced',
          correlation_id: sections.first&.job&.correlation_id || mint_id,
          detail: 'Render::Registry.ids is empty'
        )
      end

      # --- outcome constructors ----------------------------------------------------------

      def refused(refusal, total, started, sections: [])
        Outcome.new(sections: sections, documents: [],
                    diagnostic: Diagnostic.from_batch_refusal(refusal,
                                                              template_name: template.name),
                    total_count: total, shown_count: 0, truncated: false,
                    duration_ms: elapsed(started), degradations: [], pdf_attempted: false)
      end

      def failed(diagnostic, total, started, sections: [], pdf_attempted: false)
        Outcome.new(sections: sections, documents: [], diagnostic: diagnostic,
                    total_count: total, shown_count: shown_issue_count(total),
                    truncated: truncated?(total), duration_ms: elapsed(started),
                    degradations: [], pdf_attempted: pdf_attempted)
      end

      def html_only(sections, total, started)
        Outcome.new(sections: sections, documents: [], diagnostic: nil,
                    total_count: total, shown_count: shown_issue_count(total),
                    truncated: truncated?(total), duration_ms: elapsed(started),
                    degradations: [], pdf_attempted: false)
      end

      # §9b.2's "never silently truncated". True whenever the reader is seeing fewer
      # issues than exist — which is a question about the ISSUE bound and not about the
      # document count, so it is answered the same way for a combined report (whose
      # collection drop is bounded) as for a per-record one (whose document list is).
      def truncated?(total)
        total > shown_issue_count(total)
      end

      def mint_id
        SecureRandom.uuid
      end

      def elapsed(started)
        (monotonic_ms - started).round
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      end

      def warn_line(line)
        logger.warn(line) if logger.respond_to?(:warn)
      end
    end
  end
end
