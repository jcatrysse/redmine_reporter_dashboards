# frozen_string_literal: true

require 'securerandom'

require_relative 'report_run'
require_relative 'diagnostic'
require_relative '../render/batch_guard'
require_relative '../scheduling/runner'

module RedmineReporterDashboards
  module Reporting
    # T-25 — THE THING BEHIND `Runner`'s `delivery:` PORT.
    #
    # `Scheduling::Runner` owns bookkeeping and deliberately knows nothing about reports.
    # This owns the report: it resolves the scope, renders once, and mails the result to
    # the schedule's recipients. It is `Runner`'s only collaborator that touches either the
    # Liquid layer or the render layer.
    #
    # --- WHY IT LIVES IN `reporting/` AND NOT IN `scheduling/` ---
    #
    # `layer_purity.sh`'s `scheduling` arm forbids that directory from naming `Render` or
    # `Liquid`, and `occurrences.rb` states the property in as many words: the scheduler
    # names neither layer. That claim is only true because rendering happens HERE, in the
    # composition root — the one place whose whole job is to name both. Moving this file
    # into `scheduling/` would fail the gate, and the gate would be right.
    #
    # --- THREE THINGS THIS FILE EXISTS TO GET RIGHT ---
    #
    #   FR-42  ONE RENDER, N RECIPIENTS. The documents are produced once, before any
    #          recipient is looked at, and the same bytes are attached to every mail.
    #   FR-43  A FAILURE NEVER REACHES A RECIPIENT. The owner gets a notice with the
    #          correlation id and NO attachment; recipients get nothing at all. INV-5's
    #          "an error is never the document" applied to the mail path.
    #   FR-45  THE RENDER IDENTITY IS THE ONE THE SCHEDULE STORES, and it is the identity
    #          the SCOPE is built from as well — see `#as` for the part that is easy to
    #          get subtly wrong.
    class ScheduledDelivery
      Delivered = ::RedmineReporterDashboards::Scheduling::Runner::Delivered

      # WHY A TOTAL-BYTES CAP EXISTS ON TOP OF `BatchGuard`'s DOCUMENT CAP.
      #
      # They bound different things and only one of them is about mail. Fifty documents
      # inside the cap can still be a 40 MB message, and what an MTA does with that is
      # reject it — after the run row already said `success`, which is the green-looking
      # result for a report nobody received that this whole task exists to delete.
      #
      # 10 MB is the common default limit (Postfix's `message_size_limit` is 10 MB, Gmail
      # accepts 25 MB). A refusal here is a failure notice to the owner naming the size,
      # which is something an operator can act on; a bounce in a log they do not read is
      # not.
      MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024

      attr_reader :mailer, :logger

      # mailer  injected so a test can drive the whole path without ActionMailer, and so
      #         the class under test is this one rather than Redmine's delivery stack.
      def initialize(mailer: ::ReporterDashboardsMailer, logger: nil)
        @mailer = mailer
        @logger = logger
      end

      # The port's contract, verbatim: `#call(schedule:, occurrence_date:, actor:, run:)`
      # answering a `Delivered`. It may also raise — `Runner` handles both identically —
      # but it prefers to answer, because a `Delivered` carries the counts a raise cannot.
      def call(schedule:, occurrence_date:, actor:, run:)
        correlation_id = run.correlation_id

        recipients = active_recipients(schedule)
        if recipients.empty?
          # THE OWNER IS TOLD, and this goes through the same notice as a render failure
          # rather than only into `last_error`. A schedule whose last recipient was locked
          # last month otherwise fails silently every day: nothing is mailed, so nobody
          # notices, and the only trace is a column somebody has to go and look at.
          return notify_failure(schedule, occurrence_date,
                                no_recipients_diagnostic(correlation_id), [])
        end

        outcome = render(schedule, actor)
        return notify_failure(schedule, occurrence_date, outcome.diagnostic, recipients) if
          outcome.diagnostic

        deliver(schedule, occurrence_date, outcome, recipients, actor, correlation_id)
      end

      private

      # --- the scope ---------------------------------------------------------------------

      # THE RENDER RUNS AS THE SCHEDULE'S IDENTITY, AND `User.current` HAS TO AGREE WITH IT.
      #
      # This looks like the ambient-actor defect INV-1 exists to forbid, and it is the
      # opposite. `RenderContext` takes an explicit actor and `Issue.visible(actor)` takes
      # an explicit user — but Redmine's own `Query` does not: `IssueQuery#statement` reads
      # `User.current` for `me` filters, for role-restricted custom fields and for project
      # visibility, and there is no argument to pass instead. A scheduled run happens in a
      # rake task where `User.current` is Anonymous, so a saved query bound to a schedule
      # would resolve against the wrong person — usually to nothing, which is a report that
      # is empty rather than wrong and therefore looks fine.
      #
      # So the ambient actor is SET, narrowly, around the whole render, and restored. Both
      # halves are then the same person by construction rather than by hope.
      #
      # It also has to be set for the RENDER and not only for the scope: a drop that reaches
      # `Issue#visible?` or a custom field's visibility does so lazily, while the template
      # is being evaluated.
      def as(actor)
        previous = ::User.current
        ::User.current = actor
        yield
      ensure
        ::User.current = previous
      end

      def render(schedule, actor)
        as(actor) do
          scope, query = issue_scope(schedule, actor)

          ReportRun.new(template: schedule.template,
                        actor: actor,
                        scope: scope,
                        query: query,
                        guard: ::RedmineReporterDashboards::Render::BatchGuard.new(logger: logger),
                        output_class: :report,
                        logger: logger).call(pdf: true)
        end
      rescue ScopeUnavailable => e
        failed_outcome(e.message)
      end

      # A saved query the render identity may not (or may no longer) use.
      class ScopeUnavailable < StandardError; end

      # A SCHEDULE THAT CANNOT RESOLVE ITS QUERY FAILS, and this is a DELIBERATE difference
      # from the interactive path.
      #
      # `TemplatesController#issue_scope` ignores an unresolvable query id and falls back to
      # the project scope, with a stated reason: answering differently for "deleted" and
      # "you may not see it" would turn the picker into a probe for other people's private
      # queries. Nobody is probing here — there is no requester — and the fallback would be
      # much worse: a schedule configured to report on "Blocked, high priority" would
      # quietly start mailing every issue in the project instead. Same numbers, wrong report,
      # no warning.
      def issue_scope(schedule, actor)
        return [project_scope(schedule, actor), nil] if schedule.query_id.blank?

        query = ::IssueQuery.visible(actor).find_by(id: schedule.query_id)
        if query.nil?
          raise ScopeUnavailable,
                "this schedule reports through saved query #{schedule.query_id}, which " \
                "#{actor.login} cannot see — it was deleted, made private, or the " \
                'permissions changed. Nothing was sent, because the alternative is ' \
                'mailing a different report under the same name'
        end

        [query.base_scope, query]
      end

      def project_scope(schedule, actor)
        scope = ::Issue.visible(actor)
        schedule.project_id ? scope.where(project_id: schedule.project_id) : scope
      end

      # --- delivery -----------------------------------------------------------------------

      # `recipient_users` filtered to accounts that can actually receive. A locked user is
      # dropped rather than mailed: they are the same departed employee `Runner`'s identity
      # check refuses to render AS, and mailing them their old team's numbers is the same
      # leak from the other end.
      def active_recipients(schedule)
        schedule.recipient_users.select { |user| user.active? && user.mail.present? }
      end

      def deliver(schedule, occurrence_date, outcome, recipients, actor, correlation_id)
        attachments = attachments_for(schedule, occurrence_date, outcome)
        bytes = attachments.sum { |_name, data| data.bytesize }

        if bytes > MAX_ATTACHMENT_BYTES
          return notify_failure(schedule, occurrence_date,
                                oversize_diagnostic(bytes, correlation_id), recipients)
        end

        # RAISE ON A DELIVERY ERROR, which Redmine deliberately does not do by default.
        #
        # `Mailer.deliver_mail` rescues and logs unless `raise_delivery_errors` is set, so
        # an SMTP server that is down produces a log line nobody reads and a run row that
        # says `success`. `Mailer.deliver_test_email` sets the same flag for the same
        # reason, and this is Redmine's own pattern rather than an invention.
        #
        # It is a class attribute, so this is process-global for the duration. Acceptable
        # here and stated rather than hidden: the scheduler is a rake-task component, and
        # the window is one occurrence's sends. It is restored in an `ensure`.
        with_delivery_errors_raised do
          recipients.each do |recipient|
            mailer.deliver_scheduled_report(recipient, schedule, occurrence_date,
                                            attachments, actor, correlation_id)
          end
        end

        Delivered.new(recipients_count: recipients.length,
                      document_count: outcome.documents.length,
                      bytes_total: bytes,
                      correlation_id: correlation_id)
      end

      def with_delivery_errors_raised
        previous = ::ActionMailer::Base.raise_delivery_errors
        ::ActionMailer::Base.raise_delivery_errors = true
        yield
      ensure
        ::ActionMailer::Base.raise_delivery_errors = previous
      end

      # FR-43. The OWNER is told, with the correlation id; the recipients are told nothing.
      #
      # The recipient half is the requirement and it is a silence on purpose: a "your report
      # is unavailable" notice to twenty people is twenty people who can do nothing about it, and
      # §7b.3 makes it "configurable" rather than default. The schedule owner is the one
      # person who can act, so they are the one person mailed.
      #
      # `recipients` is passed only so the count can be recorded — nothing is sent to them.
      def notify_failure(schedule, occurrence_date, diagnostic, recipients)
        owner = schedule.author
        if owner&.active? && owner.mail.present?
          begin
            with_delivery_errors_raised do
              mailer.deliver_scheduled_report_failure(owner, schedule, occurrence_date,
                                                      diagnostic)
            end
          rescue StandardError => e
            # The report failed AND the notice could not be sent. Both facts belong in the
            # recorded error, because "we told the owner" and "we could not tell anybody"
            # are different operational situations.
            warn_line("[scheduler] schedule #{schedule.id} failed and its owner could " \
                      "not be notified: #{e.class}: #{e.message}")
          end
        end

        Delivered.new(recipients_count: 0,
                      document_count: 0,
                      bytes_total: 0,
                      correlation_id: diagnostic.correlation_id,
                      error: "#{diagnostic.code}: #{diagnostic.message}")
      end

      def no_recipients_diagnostic(correlation_id)
        Diagnostic.new(
          origin: :template,
          code: :no_recipients,
          message: 'this schedule has no active recipient, so rendering it would produce ' \
                   'a report nobody receives. Add a recipient, or disable the schedule',
          correlation_id: correlation_id
        )
      end

      # --- attachments ----------------------------------------------------------------------

      # `[[filename, bytes], …]` rather than a Hash, because a per-record run can produce
      # two documents whose names collide and a Hash would silently keep one of them.
      def attachments_for(schedule, occurrence_date, outcome)
        base = attachment_base_name(schedule, occurrence_date)
        single = outcome.documents.length == 1

        outcome.documents.each_with_index.map do |document, index|
          name = single ? "#{base}.pdf" : format('%s-%03d.pdf', base, index + 1)
          [name, document.bytes]
        end
      end

      # A FILENAME AN MTA AND A FILESYSTEM WILL BOTH ACCEPT.
      #
      # `template.name` is free text an author typed: it can hold slashes, quotes, newlines
      # and non-Latin scripts. `parameterize` reduces it to `[a-z0-9-]`, which loses a
      # Cyrillic or Chinese name entirely — hence the fallback, so the attachment is never
      # called `.pdf` with nothing in front of it.
      def attachment_base_name(schedule, occurrence_date)
        slug = schedule.template&.name.to_s.parameterize
        slug = "report-#{schedule.id}" if slug.empty?

        "#{slug}-#{occurrence_date.strftime('%Y-%m-%d')}"
      end

      # --- diagnostics ------------------------------------------------------------------------

      def oversize_diagnostic(bytes, correlation_id)
        Diagnostic.new(
          origin: :batch,
          code: :attachments_too_large,
          message: "this report produced #{(bytes / 1024.0 / 1024.0).round(1)} MB of " \
                   "attachments, over the #{MAX_ATTACHMENT_BYTES / 1024 / 1024} MB limit " \
                   'for a scheduled mail. Narrow the issue selection, or use a template ' \
                   'that produces one document instead of one per issue',
          correlation_id: correlation_id
        )
      end

      # A `ScopeUnavailable` wearing the same shape everything else answers, so `#call` has
      # one path rather than two.
      def failed_outcome(message)
        ReportRun::Outcome.new(
          sections: [], documents: [],
          diagnostic: Diagnostic.new(origin: :template, code: :scope_unavailable,
                                     message: message, correlation_id: SecureRandom.uuid),
          total_count: 0, shown_count: 0, truncated: false, duration_ms: 0,
          degradations: [], pdf_attempted: false
        )
      end

      def warn_line(line)
        logger.warn(line) if logger.respond_to?(:warn)
      rescue StandardError
        nil
      end
    end
  end
end
