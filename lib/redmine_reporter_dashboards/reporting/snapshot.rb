# frozen_string_literal: true

require 'digest'
require 'stringio'

require_relative 'report_run'
require_relative 'report_scope'
require_relative '../render/batch_guard'

module RedmineReporterDashboards
  module Reporting
    # T-28 — THE WRITE PATH FOR `reporter_dashboards_documents`, which until now had none.
    #
    # --- WHY THIS CLASS IS THE WHOLE POINT OF FR-52 ---
    #
    # `functional-spec.md` FR-52: *"A share link authorises **one pre-computed document**
    # (snapshot), not a live query, so **no visibility decision is made at request time**."*
    # That sentence is only true if something computes the document BEFORE the link exists.
    # Migration 007 created the table for it and said so in as many words — *"nothing in
    # T-22 creates a row"* — and every task since has left it empty. This is that something.
    #
    # The consequence is worth stating plainly, because it is what makes the security claim
    # hold: by the time a visitor presents a token, the numbers in the PDF were decided by a
    # render that ran as a NAMED user (`render_as`), inside their own visible scope, at a
    # moment that is recorded. The share endpoint then does no query, resolves no
    # permission and reads no issue — it sends bytes. There is no visibility decision to get
    # wrong because there is no visibility decision.
    #
    # --- WHY THE BYTES GO IN A CONTAINED `Attachment`, AND THE TRAP THAT DECIDED IT ---
    #
    # Migration 007 keeps the blob in Redmine's own `Attachment` rather than in a plugin
    # table, *"whose storage, permissions and cleanup are already solved"*. True — but the
    # obvious way to write one is `Attachment.create(file:, author:, filename:)` with no
    # container, and MEASURED against the core source that is a snapshot with a one-day
    # fuse: `Attachment.prune` is
    #
    #     Attachment.where("created_on < ? AND (container_type IS NULL OR
    #                       container_type = '')", Time.now - age).destroy_all
    #
    # (`app/models/attachment.rb:375`), and `rake redmine:attachments:prune`
    # (`lib/tasks/redmine.rake:22`) is a task Redmine's own installation guide tells
    # administrators to cron. A share link with a 30-day expiry would have served a 404 from
    # day two on every installation that followed the documentation — and the plugin's own
    # tests, which never run that task, could not have seen it.
    #
    # So the attachment is CONTAINED BY THE DOCUMENT (`container_type =
    # 'RedmineReporterDashboards::Document'`), which takes it out of the prune's WHERE clause
    # entirely and makes its lifetime the document's. `Document` answers core's three
    # `attachments_*?` questions with `false` for the other half of that decision: a
    # contained attachment is reachable at `/attachments/:id`, and this one must be reachable
    # only through a share link.
    #
    # --- WHAT IT REFUSES, AND WHY EACH REFUSAL IS NAMED ---
    #
    # A snapshot is ONE artefact. A per-record template over 40 issues produces forty
    # documents, which is a zip and not a snapshot — and silently taking the first would
    # share one issue's report under a name describing forty. Every refusal below answers
    # with a code the caller can turn into a sentence, never with nil.
    module Snapshot
      # WHAT A CAPTURE ANSWERS. One shape for success and for each refusal, the same
      # discipline `AdhocDelivery::Result` follows, so a caller cannot invent a fourth
      # outcome and the locale keys are enumerable.
      Result = Struct.new(:ok, :document, :code, :message, :diagnostic, keyword_init: true) do
        def ok?
          ok ? true : false
        end
      end

      CONTENT_TYPE = 'application/pdf'

      # The reasons a capture can come back empty-handed. Closed, and each is a key in
      # `en.yml` under `error_reporter_snapshot_*`.
      CODES = %i[invalid_expiry wrong_project scope_unavailable render_failed no_documents
                 many_documents attachment_failed].freeze

      # THE FILENAME'S BUDGET, and it is a measured number rather than a round one.
      # `attachments.filename` is bounded at 255 by every engine this plugin runs on, and
      # `Template#name` is valid up to 255 too — so `report-<name>-<id>.pdf` was unbounded
      # while everything it is built from was not. An independent review measured the
      # boundary: a 240-character template name captured, a 245-character one answered
      # `attachment_failed: File is too long (maximum is 255 characters)`, which is a
      # nonsense message for "your report has a long title".
      #
      # 255 minus the longest possible fixed part: `report-` (7) + `-` (1) + `.pdf` (4) + a
      # generous 12 for the document id. Names are truncated rather than refused — a long
      # title is not a reason to refuse to make somebody's report.
      MAX_FILENAME_BASE = 255 - 24

      module_function

      # Renders `template` as `render_as` and stores the result. Answers a `Result`.
      #
      # `expires_at` is MANDATORY and has no default here on purpose: the document's TTL is
      # the share link's, and a default in this module would be a second place that decides
      # how long shared data lives.
      def capture(template:, render_as:, expires_at:, project: nil, query_id: nil,
                  created_by: nil, logger: nil)
        logger ||= Rails.logger
        # REFUSED, NOT RAISED, AND THIS WAS A REVIEW FINDING. The module's own comment
        # promises that "every refusal answers with a code the caller can turn into a
        # sentence, never with nil" — and a bad `expires_at` broke that promise loudly:
        # `nil` and an out-of-bound date both reached `Document.create!` and came back as
        # `ActiveRecord::RecordInvalid`, past every caller written against `Result`,
        # including the README's own console recipe.
        #
        # A PAST EXPIRY IS REFUSED TOO, and it used to be accepted: it stored a document
        # that was born collectable and unservable, which is a successful-looking capture
        # producing a snapshot no link could ever serve.
        refusal = expiry_refusal(expires_at)
        return refusal if refusal

        # THE PROJECT MUST BE THE TEMPLATE'S. Measured by an independent review: capturing a
        # project-1 template while passing `project: Project.find(2)` succeeded and stored
        # `document.project_id = 2`, so the snapshot was filed under a project whose members
        # had nothing to do with it — and `project` is also what bounds the render's scope,
        # so the bytes were a different report from the one the row claims.
        if project && template.project_id && project.id != template.project_id
          return refuse(:wrong_project,
                        "the template belongs to project #{template.project_id}, not #{project.id}")
        end

        outcome = render(template: template, actor: render_as, project: project,
                         query_id: query_id, logger: logger)
        return outcome if outcome.is_a?(Result)

        refusal = refusal_for(outcome)
        return refusal if refusal

        store(template: template, project: project, outcome: outcome,
              render_as: render_as, created_by: created_by, expires_at: expires_at)
      end

      # --- rendering -------------------------------------------------------------------

      # THE RENDER RUNS AS `actor`, AND `User.current` IS SET FOR ITS DURATION.
      #
      # --- WHAT EACH HALF OF THAT SENTENCE ACTUALLY CARRIES, MEASURED ---
      #
      # An independent review called INV-1 untested here and picked `as(::User.current)` as
      # the mutation. It SURVIVES, and the reason is worth writing down rather than fixing:
      # **`as` is not what holds INV-1 on this path.** Every visibility decision the plugin
      # makes is threaded EXPLICITLY — `ReportScope.build(actor:)` starts from
      # `Issue.visible(actor)`, and the drops refuse to resolve without a `RenderContext`
      # rather than reaching for `User.current` (`record_drop.rb:14-17` says so in as many
      # words). So swapping the ambient user changes nothing the render reads, and a
      # mutation that only swaps it cannot fail a test that only reads the render's output.
      #
      # THE MUTATION THAT DOES DISCRIMINATE is the argument itself — `actor: render_as` →
      # `actor: created_by` — and it is now killed loudly by
      # `test_the_bytes_are_rendered_as_the_named_identity_and_not_the_ambient_user`, which
      # drives a capture whose two candidate identities see a different number of issues:
      # `"COUNT=[7]" not found in … COUNT=[6]`. That is INV-1's real guard and it has a test.
      #
      # `as` STAYS, as defence in depth for the code this module does NOT own: core reads
      # `User.current` ambiently all over (`Issue#visible_custom_field_values(user = nil)`,
      # `Attachment#visible?`, `Setting`), and a capture triggered from a request would
      # otherwise run any such call as the requester. It is belt to the explicit threading's
      # braces — and the honest claim for it is "no observable difference today", not "INV-1
      # depends on it".
      #
      # `ScheduledDelivery#as` exists for exactly this and this is the same method, restated
      # rather than shared because the two classes have no other reason to know about each
      # other.
      def render(template:, actor:, project:, query_id:, logger:)
        as(actor) do
          # `on_missing_query: :raise`, and the reasoning is `AdhocDelivery`'s rather than
          # the interactive picker's: a snapshot is made once and served for weeks, so
          # silently dropping an unresolvable query would freeze a report over the WHOLE
          # project scope under a name describing a filtered one — and nobody would ever
          # see the moment it happened.
          scope, query = ReportScope.build(template: template, actor: actor,
                                           project: project, query_id: query_id,
                                           on_missing_query: :raise)

          ReportRun.new(template: template, actor: actor, scope: scope, query: query,
                        guard: ::RedmineReporterDashboards::Render::BatchGuard.new(logger: logger),
                        output_class: :report, logger: logger).call(pdf: true)
        end
      rescue ReportScope::UnresolvableQuery => e
        refuse(:scope_unavailable, e.message)
      end

      def as(actor)
        previous = ::User.current
        ::User.current = actor
        yield
      ensure
        ::User.current = previous
      end

      def refusal_for(outcome)
        if outcome.diagnostic
          return Result.new(ok: false, code: :render_failed, diagnostic: outcome.diagnostic,
                            message: outcome.diagnostic.message.to_s)
        end
        return refuse(:no_documents, 'the scope is empty, so there was nothing to freeze') if outcome.documents.empty?

        # ONE ARTEFACT OR NONE. See the class comment: a per-record batch is a zip, and a
        # zip is not what FR-52 authorises.
        if outcome.documents.length > 1
          return refuse(:many_documents,
                        "#{outcome.documents.length} documents; a snapshot is one document")
        end

        nil
      end

      # --- storing ---------------------------------------------------------------------

      # ONE TRANSACTION, AND THE ORDER INSIDE IT IS FORCED. The attachment needs a container
      # that exists, so the document row is written first; the document's own
      # `attachment_id` pointer (migration 007's column) is then filled in. Half of that
      # would be a document row with no bytes — which is exactly what a share link would
      # later serve as an empty response.
      def store(template:, project:, outcome:, render_as:, created_by:, expires_at:)
        rendered = outcome.documents.first
        bytes = rendered.bytes.to_s
        document = nil
        stored = false
        why = nil

        ::RedmineReporterDashboards::Document.transaction do
          document = ::RedmineReporterDashboards::Document.create!(
            template: template,
            project_id: project&.id || template.project_id,
            created_by_id: created_by&.id,
            rendered_as_user_id: render_as&.id,
            correlation_id: correlation_id_for(outcome),
            engine: rendered.engine.to_s.presence,
            engine_version: rendered.engine_version.to_s.presence,
            render_duration_ms: rendered.duration_ms,
            content_type: CONTENT_TYPE,
            byte_size: bytes.bytesize,
            page_count: rendered.page_count,
            # SHA-256 OF THE BYTES, which is what migration 007 says the column is for:
            # *"lets any 'is this the same document' question be answered without reading
            # the blob"*. It is also what makes the snapshot test in this task meaningful —
            # "identical bytes regardless of who opens it" is asserted against this.
            digest: Digest::SHA256.hexdigest(bytes),
            expires_at: expires_at
          )

          attachment = build_attachment(document: document, bytes: bytes,
                                        author: created_by || render_as,
                                        filename: filename_for(template, document))
          # `save` AND NOT `save!`: `Attachment` writes to disk, and a storage path that is
          # not writable is an operational fault rather than a bug — the caller gets a named
          # refusal and the rollback takes the document row back out with it, so there is
          # never a document row whose bytes do not exist.
          unless attachment.save
            why = attachment.errors.full_messages.join(', ')
            raise ActiveRecord::Rollback
          end

          document.update!(attachment_id: attachment.id)
          stored = true
        end

        # `ActiveRecord::Rollback` IS SWALLOWED BY `transaction`, which is why the answer is
        # a flag set inside the block rather than the block's value: execution simply
        # continues here, and a method that read `document` alone would report success for a
        # capture that stored nothing.
        return refuse(:attachment_failed, why || 'the rendered bytes could not be stored') unless stored

        Result.new(ok: true, document: document.reload)
      end

      def build_attachment(document:, bytes:, author:, filename:)
        ::Attachment.new(
          # A `StringIO` AND NOT THE STRING. `Attachment#file=` expects something answering
          # `#read`; handed a String it stores an empty file, which is the defect
          # `patches/report_patch.rb` was written to fix in the base plugin and is not worth
          # rediscovering here.
          file: StringIO.new(bytes),
          author: author,
          filename: filename,
          content_type: CONTENT_TYPE,
          container: document
        )
      end

      # `report-<template>-<id>.pdf`. The id is the DOCUMENT's, not the template's, so two
      # snapshots of one template are distinguishable in a downloads folder — which is the
      # only place this name is ever seen. BOUNDED: see `MAX_FILENAME_BASE`.
      #
      # `parameterize` COLLAPSES A NON-LATIN NAME TO NOTHING, which is why the fallback is
      # not decoration: `Отчёт`, `季度报告` and a name of only spaces all parameterize to the
      # empty string, so eight of this plugin's nine locales can produce a template whose
      # snapshot is called `report-report-<id>.pdf`. That is ugly and it is deliberate — the
      # alternative is a non-ASCII filename in a `Content-Disposition` header, which is
      # exactly the interoperability problem `parameterize` is here to avoid, and the
      # document id still makes every name unique.
      def filename_for(template, document)
        base = template.name.to_s.parameterize.presence || 'report'
        "report-#{base[0, MAX_FILENAME_BASE]}-#{document.id}.pdf"
      end

      # `expires_at` IS THE ONE ARGUMENT THIS MODULE CANNOT DEFAULT (the document's TTL is
      # the share link's, and a default here would be a second place deciding how long shared
      # data lives), so it is also the one it has to check.
      def expiry_refusal(expires_at)
        return refuse(:invalid_expiry, 'a snapshot needs an expiry') if expires_at.blank?
        # `in_time_zone` AND NOT `to_time`: it accepts a Time, a DateTime, a Date and a
        # String alike, and `to_time` on a `TimeWithZone` emits Rails 8.0's
        # `to_time_preserves_timezone` deprecation — a warning in every capture, which is how
        # a suite learns to ignore its own output.
        return refuse(:invalid_expiry, 'expires_at must be a time') unless expires_at.respond_to?(:in_time_zone)

        at = expires_at.in_time_zone
        now = Time.zone.now
        return refuse(:invalid_expiry, "#{at} is in the past") if at <= now

        bound = now + ::RedmineReporterDashboards::Document::MAX_RETENTION
        return refuse(:invalid_expiry, "#{at} is beyond the retention bound of #{bound}") if at > bound

        nil
      end

      # FR-58's id, taken from the section that produced the document rather than minted
      # here — so the id stored on the row is the id in the log line for that render.
      def correlation_id_for(outcome)
        outcome.sections&.first&.job&.correlation_id
      end

      def refuse(code, message)
        Result.new(ok: false, code: code, message: message)
      end
    end
  end
end
