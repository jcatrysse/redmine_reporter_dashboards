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
        @notify_owner = true
      end

      # The port's contract, verbatim: `#call(schedule:, occurrence_date:, actor:, run:)`
      # answering a `Delivered`. It may also raise — `Runner` handles both identically —
      # but it prefers to answer, because a `Delivered` carries the counts a raise cannot.
      # `recipients:` OVERRIDES THE SCHEDULE'S LIST, and exists for exactly one caller:
      # the UI's "Send a test" button, which renders as the schedule's identity — FR-45's
      # "a test send uses the SAME identity as the real run" — but delivers to the person
      # who pressed it and to nobody else. Mailing twenty people every time an author
      # adjusts a template would make the button unusable, and the tester needs to see what
      # recipients WOULD get rather than to send it to them.
      #
      # `Runner` never passes it. There is no configuration in which a scheduled run
      # delivers to a list other than the one stored on the schedule.
      # `notify_owner:` — FALSE FOR A TEST SEND, and the first version had no such flag.
      #
      # The class comment and the confirmation dialog both promised a test "goes only to
      # you", in nine languages. On the FAILURE path it mailed the schedule's owner instead,
      # telling them their SCHEDULED run had failed when no run happened — so ten clicks on
      # a broken template were ten false alarms aimed at a third party. Measured by an
      # independent review.
      #
      # The presser already sees the failure in the flash, so a test send needs no notice at
      # all; a real run has nobody watching and needs one.
      def call(schedule:, occurrence_date:, actor:, run:, recipients: nil,
               notify_owner: true)
        @notify_owner = notify_owner
        correlation_id = run.correlation_id

        recipients = recipients ? Array(recipients) : active_recipients(schedule)
        if recipients.empty?
          # THE OWNER IS TOLD, and this goes through the same notice as a render failure
          # rather than only into `last_error`. A schedule whose last recipient was locked
          # last month otherwise fails silently every day: nothing is mailed, so nobody
          # notices, and the only trace is a column somebody has to go and look at.
          return notify_failure(schedule, occurrence_date,
                                no_recipients_diagnostic(correlation_id), [])
        end

        if schedule.template.nil?
          # A SCHEDULE WHOSE TEMPLATE IS GONE, which crashes rather than failing without
          # this guard: `ReportRun#call` opens with `template.source` and gets a
          # `NoMethodError` on nil. `Runner`'s rescue would catch it and record something
          # accurate but ugly, and the owner would be told "NoMethodError: undefined method
          # `source' for nil" — a stack-trace fragment where a sentence belongs.
          #
          # `dependent: :destroy` normally prevents the state, but `delete_all` and a
          # DB-level delete bypass callbacks, and this plugin uses `delete_all` elsewhere.
          # Found by a test written for the mailer's fallback name, which could never be
          # reached on the success path because the render died first.
          return notify_failure(schedule, occurrence_date,
                                missing_template_diagnostic(correlation_id), recipients)
        end

        outcome = render(schedule, actor)
        if outcome.diagnostic
          # RESTAMPED WITH THE RUN'S ID, and the first version was not. FR-58's whole point
          # is that the id the owner is told to quote is the id in the log line and in the
          # run row — and every diagnostic out of `ReportRun` mints its OWN uuid, so the
          # notice named something no operator could search for. Measured by the
          # independent review: run row `3a8cd94c…`, owner mail `23688ef7…`.
          return notify_failure(schedule, occurrence_date,
                                restamp(outcome.diagnostic, correlation_id), recipients)
        end

        # A PER-RECORD REPORT OVER ZERO ISSUES PRODUCES ZERO DOCUMENTS, and it is neither a
        # failure nor something to mail.
        #
        # `documents: []` with `diagnostic: nil` is a SUCCESSFUL outcome — the template is
        # fine, the scope is simply empty. The first version sent it anyway: every recipient
        # got "Here is the Weekly report for 10 March" with nothing attached, and the run
        # recorded success. That is §7b.3's "an e-mail that looks successful" with the
        # attachment removed instead of broken.
        #
        # It is NOT reported as a failure either, and that is the harder call. For "issues
        # assigned to me that are overdue", zero is the good outcome and a daily failure
        # notice would be noise nobody can act on; for a weekly status report it means
        # something broke. The plugin cannot tell which, so it does the honest, quiet thing:
        # nothing is sent, and the run row records `document_count: 0, recipients_count: 0`,
        # which is exactly what happened and is what an operator sees when they go looking.
        if outcome.documents.empty?
          info_line("[scheduler] schedule #{schedule.id} produced no document for " \
                    "#{occurrence_date} — the scope is empty. Nothing was sent " \
                    "to the #{recipients.length} recipient(s).")
          return Delivered.new(recipients_count: 0, document_count: 0, bytes_total: 0,
                               correlation_id: correlation_id)
        end

        deliver(schedule, occurrence_date, outcome, recipients, actor, correlation_id)
      end

      # THE RUNNER'S SECOND PORT (FR-43). Called for a failure the delivery never saw — a
      # locked render identity, a policy this version cannot honour, a repeat rule it cannot
      # interpret. All three raise inside `Runner` before `#call` is reached, and without
      # this the owner is told nothing while the README says they are told.
      #
      # It is the same notice, so an operator cannot tell from the mail whether the report
      # broke before or during the render — which is right: what they need is the schedule,
      # the day, the reason and an id, and those are the same either way.
      def notify_failure(schedule:, occurrence_date:, correlation_id:, message:)
        notify_owner(schedule, occurrence_date,
                     Diagnostic.new(origin: :template, code: :schedule_unusable,
                                    message: message.to_s,
                                    correlation_id: correlation_id || SecureRandom.uuid))
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
          scope, query = report_scope(schedule, actor)

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

      # A saved query the render identity may not (or may no longer) use. Kept as this
      # class's own name so the rescue in `#render` reads locally; it is raised by
      # `ReportScope` and re-raised under this name.
      class ScopeUnavailable < StandardError; end

      # WHICH ROWS THIS SCHEDULE IS ABOUT — and it goes through `Reporting::ReportScope`,
      # the same module the interactive path uses.
      #
      # THIS METHOD WAS THE BLOCKER. It was `issue_scope`, it built `Issue.visible(actor)`
      # unconditionally, and `TemplatesController` had meanwhile learned to branch on
      # `template.source`. An independent review measured the consequence: a
      # `source: time_entries` schedule rendered over the issue scope and mailed
      # `COUNT=[7]`, the issue count, where the actor's visible entry count was 3 — with
      # `ok=true`, no diagnostic and no notice. §Findings S-13 on the one path with an
      # audience. Two callers deciding one thing separately is the shape that produced it.
      #
      # A SCHEDULE THAT CANNOT RESOLVE ITS QUERY FAILS, and that is a DELIBERATE difference
      # from the interactive path rather than an inconsistency. `ReportScope` takes it as an
      # argument for that reason. The interactive path ignores an unresolvable query id with
      # a stated reason — answering differently for "deleted" and "you may not see it" would
      # turn the picker into a probe for other people's private queries. Nobody is probing
      # here, there is no requester, and the fallback would be much worse: a schedule
      # configured to report on "blocked, high priority" would quietly start mailing every
      # row in the project instead. Same numbers, wrong report, no warning.
      def report_scope(schedule, actor)
        ReportScope.build(template: schedule.template,
                          actor: actor,
                          project: schedule.project,
                          query_id: schedule.query_id,
                          on_missing_query: :raise)
      rescue ReportScope::UnresolvableQuery => e
        raise ScopeUnavailable, e.message
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
        # THE PARTIAL COUNT SURVIVES A FAILURE HALFWAY DOWN THE LIST, and it has to.
        #
        # If the relay refuses recipient 5 of 20, the run row must be able to say that four
        # people already have the report — that is the fact an operator needs before
        # deciding whether to re-run, and re-running would mail those four twice. The first
        # version let the exception escape with no counts at all, so `finish_run` wrote
        # nulls and the row said only "failed".
        sent = 0
        begin
          with_delivery_errors_raised do
            recipients.each do |recipient|
              mailer.deliver_scheduled_report(recipient, schedule, occurrence_date,
                                              attachments, actor, correlation_id)
              sent += 1
            end
          end
        rescue StandardError => e
          notify_failure(schedule, occurrence_date,
                         partial_delivery_diagnostic(sent, recipients.length, e,
                                                     correlation_id),
                         recipients)
          return Delivered.new(recipients_count: sent,
                               document_count: outcome.documents.length,
                               bytes_total: bytes, correlation_id: correlation_id,
                               reported: true,
                               error: "partial_delivery: #{sent} of " \
                                      "#{recipients.length} recipient(s) received it " \
                                      "before #{e.class}: #{e.message}")
        end

        Delivered.new(recipients_count: sent,
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
      # `recipients` is NOT sent anything; it is here so the log line can say how many
      # people did not get a report, which is the number an operator asks for first. The
      # first version took the parameter and never read it, and said in a comment that it
      # recorded the count. Renaming it `_recipients` left the suite green.
      def notify_failure(schedule, occurrence_date, diagnostic, recipients)
        warn_line("[scheduler] schedule #{schedule.id} could not deliver " \
                  "#{occurrence_date} to #{recipients.length} recipient(s) " \
                  "[#{diagnostic.correlation_id}]: #{diagnostic.code}")
        notify_owner(schedule, occurrence_date, diagnostic)

        # `reported: true` — the owner has been told, so `Runner` must not send a second
        # notice for the same failure.
        Delivered.new(recipients_count: 0,
                      document_count: 0,
                      bytes_total: 0,
                      correlation_id: diagnostic.correlation_id,
                      reported: true,
                      error: "#{diagnostic.code}: #{diagnostic.message}")
      end

      def notify_owner(schedule, occurrence_date, diagnostic)
        return unless @notify_owner

        owner = schedule.author
        return unless owner&.active? && owner.mail.present?

        with_delivery_errors_raised do
          mailer.deliver_scheduled_report_failure(owner, schedule, occurrence_date,
                                                  diagnostic)
        end
      rescue StandardError => e
        # The report failed AND the notice could not be sent. Both facts belong in the log,
        # because "we told the owner" and "we could not tell anybody" are different
        # operational situations.
        warn_line("[scheduler] schedule #{schedule.id} failed and its owner could not be " \
                  "notified: #{e.class}: #{e.message}")
      end

      # A diagnostic wearing the run's correlation id instead of its own. `Diagnostic` is
      # frozen, so this is a new one rather than a mutation.
      def restamp(diagnostic, correlation_id)
        Diagnostic.new(origin: diagnostic.origin, code: diagnostic.code,
                       message: diagnostic.message, correlation_id: correlation_id,
                       line: diagnostic.line, engine: diagnostic.engine,
                       engine_version: diagnostic.engine_version, detail: diagnostic.detail)
      end

      def partial_delivery_diagnostic(sent, total, error, correlation_id)
        Diagnostic.new(
          origin: :engine,
          code: :partial_delivery,
          message: "#{sent} of #{total} recipient(s) received this report before " \
                   'delivery failed. Re-running would send it to them a second time, so ' \
                   'the occurrence stays claimed — check the mail log before deciding',
          correlation_id: correlation_id,
          detail: "#{error.class}: #{error.message}"
        )
      end

      def missing_template_diagnostic(correlation_id)
        Diagnostic.new(
          origin: :template,
          code: :template_missing,
          message: 'the report template this schedule points at no longer exists. Point ' \
                   'the schedule at another template, or disable it',
          correlation_id: correlation_id
        )
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

      def info_line(line)
        logger.info(line) if logger.respond_to?(:info)
      rescue StandardError
        nil
      end
    end
  end
end
