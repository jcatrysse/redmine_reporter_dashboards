# frozen_string_literal: true

require_relative '../starter_gallery'

module RedmineReporterDashboards
  module Reporting
    # T-37 / FR-73 — *"a starter gallery whose every entry lints clean and renders on every
    # engine in the matrix, thumbnails generated in CI"*.
    #
    # THE LINT HALF IS A SPEC (`spec/starter_gallery_spec.rb`, DB-less, zero findings per
    # entry). THIS IS THE RENDER HALF, and it cannot be a spec: rendering a starter needs a
    # booted Redmine, a project with issues and time entries in it, and a real engine — three
    # things `spec/` deliberately does not have. So it is a module the rake task drives, and
    # the rake task is what CI and a developer both run.
    #
    # --- WHAT "RENDERS" MEANS HERE, AND WHY IT IS NOT "DID NOT RAISE" ---
    #
    # Four things are asserted per starter per engine, and each of them has been the failure
    # this project actually shipped at some point:
    #
    #   the run has NO DIAGNOSTIC          a failed render answers `Failure`, not an
    #                                      exception. "It did not raise" is true of every
    #                                      failure this design produces (INV-5).
    #   a document came back               a template can succeed and produce nothing — a
    #                                      per-record template over an empty scope does
    #                                      exactly that, which is why the fixture project has
    #                                      to have issues in it.
    #   the bytes are a PDF                `Render::Renderer` already enforces `%PDF-` and
    #                                      `%%EOF` above every adapter, and this asserts the
    #                                      post-condition survived the composition root.
    #   NO DEGRADATION THIS ENTRY DID NOT  a starter that silently renders without its chart
    #   DECLARE                            is not a starter that works. wkhtmltopdf stamps
    #                                      `legacy_engine` on every render by design, so that
    #                                      one is expected everywhere; anything else is a
    #                                      finding with its code named.
    #
    # --- IT NEVER WRITES A TEMPLATE ROW ---
    #
    # `ReportRun.preview` takes an unsaved `Template`, exactly as the editor's Preview button
    # does. Nothing here saves one, so running this against a production database adds no rows
    # and leaves no `Document` behind.
    module GalleryCheck
      Result = Struct.new(:entry, :engine_id, :ok, :detail, :pdf_bytes, keyword_init: true) do
        def label
          "#{entry.id} / #{engine_id}"
        end
      end

      # wkhtmltopdf stamps this on every render it performs — it is a statement about the
      # engine, not about the template — so it is expected on that engine and only there.
      EXPECTED_DEGRADATIONS = { 'wkhtmltopdf' => %w[legacy_engine] }.freeze

      class << self
        # `engines` is the list of registered engine ids; `actor` and `project` come from the
        # task, which resolves them explicitly rather than reading `User.current` (INV-1 —
        # a rake task has no ambient actor and must not invent one).
        def run(actor:, project:, engines:, logger: nil)
          StarterGallery.entries.flat_map do |entry|
            engines.map { |engine_id| check(entry, actor, project, engine_id, logger) }
          end
        end

        private

        # `engine:` AND NOT A HINT ON THE TEMPLATE. `ReportRun#resolve_engine` returns an
        # injected engine before it consults anything else, so passing the instance is the
        # only way to say "render this on THAT engine" without depending on the schema having
        # migration 011's `engine_hint` column or on what this installation happens to have
        # selected. This module's whole subject is every engine, one at a time.
        def check(entry, actor, project, engine_id, logger)
          template = template_for(entry, project, actor)
          scope, query = ReportScope.build(template: template, actor: actor, project: project,
                                           query_id: nil)
          engine = ::RedmineReporterDashboards::Render::Registry.fetch(engine_id)
          outcome = ReportRun.preview(template: template, actor: actor, scope: scope,
                                      query: query, logger: logger,
                                      guard: ::RedmineReporterDashboards::Render::BatchGuard.new(logger: logger),
                                      engine: engine).call(pdf: true)

          verdict(entry, engine_id, outcome)
        rescue StandardError => e
          # A raise is a defect in this module or in the composition root rather than a
          # failed render — `ReportRun` answers a typed failure — so it is reported with the
          # class name rather than turned into a plain "false".
          Result.new(entry: entry, engine_id: engine_id, ok: false,
                     detail: "raised #{e.class}: #{e.message}")
        end

        def verdict(entry, engine_id, outcome)
          problem = first_problem(entry, engine_id, outcome)
          bytes = outcome.documents&.first&.bytes

          Result.new(entry: entry, engine_id: engine_id, ok: problem.nil?,
                     detail: problem || "#{bytes.to_s.bytesize} bytes",
                     pdf_bytes: problem.nil? ? bytes : nil)
        end

        def first_problem(entry, engine_id, outcome)
          if outcome.diagnostic
            diagnostic = outcome.diagnostic
            return "#{diagnostic.origin}/#{diagnostic.code}: #{diagnostic.message}"
          end

          document = outcome.documents&.first
          return 'the render succeeded and produced no document' if document.nil?

          bytes = document.bytes.to_s
          return "the bytes are not a PDF (#{bytes[0, 8].inspect})" unless bytes.start_with?('%PDF-')

          unexpected = unexpected_degradations(engine_id, outcome)
          return "degraded: #{unexpected.join(', ')}" if unexpected.any?

          nil
        end

        def unexpected_degradations(engine_id, outcome)
          expected = EXPECTED_DEGRADATIONS.fetch(engine_id.to_s, [])

          Array(outcome.degradations).map { |degradation| DegradationText.code_of(degradation).to_s }
                                    .reject { |code| expected.include?(code) }
        end

        # The starter as a template, with the two axes the gallery declares for it. Not saved
        # — see the header.
        def template_for(entry, project, actor)
          ::RedmineReporterDashboards::Template.new(
            project_id: project.id, author_id: actor.id,
            name: entry.id, source: entry.source, output: entry.output,
            content: StarterGallery.body(entry),
            visibility: ::RedmineReporterDashboards::Template::VISIBILITY_PRIVATE
          )
        end
      end
    end
  end
end
