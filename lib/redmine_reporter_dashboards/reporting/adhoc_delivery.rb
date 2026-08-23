# frozen_string_literal: true

require 'securerandom'

require_relative 'report_run'
require_relative 'report_scope'
require_relative 'diagnostic'
require_relative 'mail_policy'
require_relative '../render/batch_guard'

module RedmineReporterDashboards
  module Reporting
    # T-32 / FR-61 — mailing a report to somebody, on demand, under control.
    #
    # --- WHAT THIS REPLACES, STATED SO THE CONTROLS READ AS ANSWERS ---
    #
    # `technical-spec.md` §7b.5: the base plugin's `find_issues` is
    # `Issue.where(id: params[:issue_ids])` with **no visibility check**, and `to`/`cc`/
    # `bcc`/**`from`** are free text. *"That is a report over any issue in the instance,
    # mailed anywhere, with a forged sender."* Each control below closes one clause of that
    # sentence, and each is held by construction rather than by validation:
    #
    #   any issue in the instance  `ReportScope` starts from `Issue.visible(actor)`, and a
    #                              named id outside it REFUSES the send rather than being
    #                              dropped from it — see `#resolve_named_issues`
    #   mailed anywhere            a recipient is a Redmine user, or an address the
    #                              administrator's allowlist names. `MailPolicy` decides,
    #                              once, and the form is not the check
    #   a forged sender            there is no code path that could set one.
    #                              `ReporterDashboardsMailer` inherits Redmine's `Mailer`,
    #                              whose `#mail` builds `From` from `Setting.mail_from`
    #
    # --- WHY THE AUDIT ROW IS CLAIMED BEFORE THE RENDER ---
    #
    # See `MailSend`. In one line: the rate limit counts attempts, and the expensive half of
    # a send is the render, so a limit that only counted completed sends would not bound the
    # cost of a template that fails.
    #
    # --- A FAILURE MAILS NOBODY, INCLUDING THE REQUESTER ---
    #
    # FR-43's scheduled path mails the schedule's owner because nobody is watching a cron
    # entry. Somebody IS watching this one: they pressed the button and are looking at the
    # response, which renders §9b.2's diagnostics panel with the same correlation id that
    # goes into the audit row. Sending them an e-mail as well would be a notice about a
    # failure they are already reading, and INV-5's rule — never a green-looking mail
    # carrying a failure — is satisfied by there being no mail at all.
    class AdhocDelivery
      # THE SAME CAP AS THE SCHEDULED PATH, and it is deliberately not a smaller number.
      # An MTA does not care which button produced the message; 10 MB is Postfix's common
      # default. Sharing the constant would couple two classes that have no other reason to
      # know about each other, so it is restated with its reason rather than reached for.
      MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024

      # WHAT CAME BACK. A closed set of reasons rather than a boolean plus a string, so the
      # controller cannot invent a fourth outcome and the locale keys are enumerable.
      Result = Struct.new(:ok, :code, :message, :diagnostic, :recipients_count,
                          :external_count, :document_count, :bytes_total, :correlation_id,
                          keyword_init: true) do
        def ok?
          ok ? true : false
        end
      end

      attr_reader :mailer, :logger, :policy

      def initialize(mailer: ::ReporterDashboardsMailer, logger: nil, policy: nil)
        @mailer = mailer
        @logger = logger
        @policy = policy || MailPolicy.current(logger: logger)
      end

      # `actor` is the requester and there is no second identity. FR-61 resolves issues
      # through **the requester's** visible scope, so `render_as` — the schedule column that
      # needed a whole permission behind it (`render_reporter_dashboards_reports_as_others`)
      # — has no counterpart here, and adding one would reintroduce exactly the escalation
      # T-25's review found.
      #
      # `recipient_users` and `recipient_addresses` arrive already resolved by the
      # controller from the request, and are re-checked here: a caller is not the check
      # either. `mail_send` is the claimed audit row.
      def call(template:, actor:, project:, mail_send:, recipient_users: [],
               recipient_addresses: [], query_id: nil, issue_ids: nil, subject: nil)
        started = monotonic_now
        correlation_id = mail_send&.correlation_id.presence || SecureRandom.uuid

        recipients = Array(recipient_users).select { |u| u.active? && u.mail.present? }
        addresses = Array(recipient_addresses)

        # RE-CHECKED HERE, not trusted. The controller filters the same list, and a control
        # that exists in one place is a control one refactor away from existing in none.
        # HANDOVER §1's rule about `render_as_user_id` generalises: the picker is not the
        # check, and neither is the caller.
        refused = addresses.reject { |address| policy.external_permitted?(address) }
        unless refused.empty?
          return refuse(mail_send, :external_not_permitted, correlation_id, started,
                        "#{refused.length} address(es) are not permitted by the " \
                        'installation policy')
        end

        if recipients.empty? && addresses.empty?
          return refuse(mail_send, :no_recipients, correlation_id, started,
                        'no active recipient')
        end

        outcome = render(template, actor, project, query_id, issue_ids)
        return refuse_scope(mail_send, outcome, correlation_id, started) if outcome.is_a?(Result)

        if outcome.diagnostic
          return fail_with(mail_send, restamp(outcome.diagnostic, correlation_id),
                           correlation_id, started)
        end

        # ZERO DOCUMENTS IS NOT SOMETHING TO MAIL, and unlike the scheduled path it is not
        # silence either. A schedule runs unattended, so `ScheduledDelivery` records
        # `document_count: 0` and pages nobody. Here a person just asked for a report and is
        # waiting: telling them "that produced nothing, so nothing was sent" is the answer,
        # and mailing an empty envelope to their colleagues is not.
        if outcome.documents.empty?
          return refuse(mail_send, :no_documents, correlation_id, started,
                        'the scope is empty, so there was no report to send')
        end

        deliver(template, actor, outcome, recipients, addresses, subject, correlation_id,
                mail_send, started)
      end

      private

      # --- the scope -----------------------------------------------------------------

      # THE RENDER RUNS AS THE REQUESTER, and `User.current` is already them — this is a
      # request, not a rake task, so unlike `ScheduledDelivery#as` there is nothing to set
      # and nothing to restore. Said explicitly because the absence of that method here is
      # the kind of difference a reader assumes is an omission.
      # `on_missing_query: :raise`, AND THE DEFAULT WAS A BLOCKER.
      #
      # This called `ReportScope.build` without it, so an unresolvable `query_id` took the
      # `:ignore` branch: the saved query was silently dropped, the report was rendered over
      # the WHOLE project scope, mailed, and recorded as `success` under the query id it had
      # ignored. Measured by an independent review against a private `IssueQuery` belonging
      # to somebody else, a nonexistent id and the literal `abc` — all three delivered.
      #
      # `ReportScope#find_query`'s own message is the argument against that default and it
      # was already written: *"Nothing was sent, because the alternative is mailing a
      # different report under the same name."* That is §Findings S-15 exactly — a decision
      # with two callers made twice and differently — on the third caller `ReportScope`'s
      # comment was written to protect.
      #
      # The disclosure reasoning behind the interactive `:ignore` default does NOT transfer
      # here. It exists so a picker cannot be used to probe for other people's private
      # queries by telling "deleted" and "not yours" apart; this path answers ONE refusal
      # for both, so it tells them apart no more than the picker does — and the alternative
      # is mailing a report to other people under a name that does not describe it.
      def render(template, actor, project, query_id, issue_ids)
        scope, query = ReportScope.build(template: template, actor: actor,
                                         project: project, query_id: query_id,
                                         on_missing_query: :raise)

        if scope && issue_ids.present?
          scope = narrow_to_named_issues(scope, issue_ids)
          return scope if scope.is_a?(Result)
        end

        ReportRun.new(template: template, actor: actor, scope: scope, query: query,
                      guard: ::RedmineReporterDashboards::Render::BatchGuard.new(logger: logger),
                      output_class: :report, logger: logger).call(pdf: true)
      rescue ReportScope::UnresolvableQuery => e
        # ONE REFUSAL FOR "gone" AND "not yours" — `ReportScope` raises the same error for
        # both, and this passes its message through rather than composing a second one, so
        # the two cases stay indistinguishable from outside.
        refusal(:query_unavailable, e.message)
      end

      # T-32's `Accept:` clause, and the word in it that decides the design is **refused**:
      # *"a test asserts an issue the requester cannot see is refused, not silently
      # included"*.
      #
      # Silently INCLUDING it is the base plugin's defect. Silently DROPPING it is the
      # plausible-looking fix and is its own defect: the requester asks for a report on
      # twelve issues, receives one covering nine, and nothing anywhere says which three are
      # missing or why. Both readings produce a report that is wrong about what it claims to
      # cover, so the whole send is refused and the count is named.
      #
      # It counts rather than listing the ids. Naming them would confirm which of the twelve
      # exist and which the requester merely cannot see, which is the disclosure
      # `Template#visible?`'s 404 and `ReportScope#find_query`'s single answer both exist to
      # avoid.
      # A MALFORMED ID IS REFUSED, NOT DROPPED, AND SKIPPING THIS WAS THE SECOND BLOCKER.
      #
      # The first version was `filter_map { Integer(id) if id.match?(/\A\d+\z/) }`, which
      # discarded every entry that was not bare digits BEFORE the rule above was applied —
      # so the paragraph explaining why dropping is a defect sat directly over code that
      # dropped. Worse at the boundary: with `issue_ids=abc` the list came out EMPTY, took
      # the "no set was named" branch, and mailed a report over the requester's entire
      # visible scope while the flash said "sent to 1 recipient". Measured by an independent
      # review.
      #
      # `#42` is the shape that makes this likely rather than theoretical: it is Redmine's
      # own issue-reference syntax and the field is labelled "Issue IDs". It is still
      # refused rather than accepted — being liberal about the input is a separate decision
      # from being silent about it, and only the silence is a defect. The refusal names the
      # count, and the message tells the requester what a valid entry looks like.
      def narrow_to_named_issues(scope, issue_ids)
        entries = Array(issue_ids).map { |id| id.to_s.strip }.reject(&:empty?)
        # NOT `return scope`. An empty list here means the caller passed something that
        # cleaned away to nothing; the controller answers `nil` for "no set was named", so
        # reaching this method at all means a set WAS named. Falling back to the whole scope
        # is the boundary case that made `issue_ids=abc` mail everything.
        return refusal(:issue_ids_malformed, 'no issue ID was recognised') if entries.empty?

        malformed = entries.reject { |id| id.match?(/\A\d+\z/) }
        unless malformed.empty?
          return refusal(:issue_ids_malformed,
                         "#{malformed.length} of the #{entries.length} issue ID(s) named " \
                         'are not numbers. Use the bare number, without a # in front of it')
        end

        wanted = entries.map { |id| Integer(id, 10) }.uniq
        narrowed = scope.where(id: wanted)
        # `pluck` and not `count`: the two questions are "how many are visible" and "which",
        # and only the second can be compared with what was asked for. A count would answer
        # equal for a request naming one visible id twice.
        visible = narrowed.pluck(:id).uniq
        missing = wanted - visible

        return narrowed if missing.empty?

        refusal(:issues_not_visible,
                "#{missing.length} of the #{wanted.length} issue(s) named are not in " \
                'your visible scope')
      end

      # A scope-resolution refusal, as a `Result` the caller recognises by class. One
      # constructor rather than four literals, because every one of them has to carry the
      # same four zeroes and a fifth copy is where one of them stops being zero.
      def refusal(code, message)
        Result.new(ok: false, code: code, message: message, recipients_count: 0,
                   external_count: 0, document_count: 0, bytes_total: 0)
      end

      # --- delivery ------------------------------------------------------------------

      def deliver(template, actor, outcome, recipients, addresses, subject, correlation_id,
                  mail_send, started)
        attachments = attachments_for(template, outcome, actor)
        bytes = attachments.sum { |_name, data| data.bytesize }

        if bytes > MAX_ATTACHMENT_BYTES
          return refuse(mail_send, :attachments_too_large, correlation_id, started,
                        "#{(bytes / 1024.0 / 1024.0).round(1)} MB of attachments, over " \
                        "the #{MAX_ATTACHMENT_BYTES / 1024 / 1024} MB limit")
        end

        sent = 0
        external_sent = 0
        begin
          # AN SMTP FAILURE RAISES, and there is no window here in which it does so.
          #
          # Redmine rescues and logs by default, so a relay that is down would produce an
          # audit row saying `success` and an empty mailbox. This path used to buy the
          # exception by flipping `ActionMailer::Base.raise_delivery_errors` — a CLASS
          # ATTRIBUTE, in a web request, where two overlapping sends corrupt each other's
          # restore and can leave the flag set for the whole process. It is now a property
          # of `ReporterDashboardsMailer.deliver_mail`, which is per-class and therefore
          # cannot be raced. See the comment there.
          recipients.each do |recipient|
            mailer.deliver_adhoc_report(recipient, template, actor, attachments, subject,
                                        correlation_id)
            sent += 1
          end
          addresses.each do |address|
            mailer.deliver_adhoc_report_to_address(address, template, actor, attachments,
                                                   subject, correlation_id)
            sent += 1
            external_sent += 1
          end
        rescue StandardError => e
          # THE PARTIAL COUNT SURVIVES, exactly as it must on the scheduled path: if the
          # relay refuses recipient 5 of 20, the audit has to be able to say that four
          # people already hold the report, because that is the fact that decides whether
          # re-sending is safe.
          finish(mail_send, MailSend::STATUS_FAILED, started,
                 error: "partial_delivery: #{sent} of #{recipients.length + addresses.length} " \
                        "recipient(s) received it before #{e.class}: #{e.message}",
                 recipients_count: sent, external_count: external_sent,
                 document_count: outcome.documents.length, bytes_total: bytes,
                 correlation_id: correlation_id)
          return Result.new(ok: false, code: :partial_delivery,
                            message: "#{sent} recipient(s) received it before delivery failed",
                            recipients_count: sent, external_count: external_sent,
                            document_count: outcome.documents.length, bytes_total: bytes,
                            correlation_id: correlation_id)
        end

        finish(mail_send, MailSend::STATUS_SUCCESS, started,
               recipients_count: sent, external_count: external_sent,
               document_count: outcome.documents.length, bytes_total: bytes,
               correlation_id: correlation_id)

        Result.new(ok: true, code: :sent, recipients_count: sent,
                   external_count: external_sent,
                   document_count: outcome.documents.length, bytes_total: bytes,
                   correlation_id: correlation_id)
      end

      # `[[filename, bytes], …]` and not a Hash — a per-record run can produce two documents
      # whose names collide, and a Hash keeps one of them without saying so.
      def attachments_for(template, outcome, actor)
        base = attachment_base_name(template, actor)
        single = outcome.documents.length == 1

        outcome.documents.each_with_index.map do |document, index|
          name = single ? "#{base}.pdf" : format('%s-%03d.pdf', base, index + 1)
          [name, document.bytes]
        end
      end

      # The scheduled path dates its attachment by the occurrence. An ad-hoc send has no
      # occurrence, so it is dated by the day it was made — which is what the recipient
      # needs to tell two of them apart in a mailbox.
      #
      # `actor.today` AND NOT `Date.today`, which is what this was. `Date.today` is the
      # SERVER's day: between 23:00 in Brussels and midnight UTC it names yesterday, so the
      # requester pressed Send on the 15th and received `report-2026-08-14.pdf` — a filename
      # disagreeing with the page they were looking at, and with every other date in this
      # plugin. `User#today` is Redmine's own answer to "what day is it for this person", and
      # it is the one `Occurrences` and the aggregator's `Time.zone.today` already use.
      # `Date.current` is the fallback for an actor with no time zone set, which is what
      # `User#today` itself falls back to.
      def attachment_base_name(template, actor)
        slug = template&.name.to_s.parameterize
        slug = "report-#{template&.id}" if slug.empty?

        today = actor.respond_to?(:today) ? actor.today : ::Date.current

        "#{slug}-#{today.strftime('%Y-%m-%d')}"
      end

      # --- outcomes ------------------------------------------------------------------

      def refuse(mail_send, code, correlation_id, started, message)
        warn_line("[adhoc-mail] refused (#{code}) [#{correlation_id}]: #{message}")
        finish(mail_send, MailSend::STATUS_FAILED, started, error: "#{code}: #{message}",
               recipients_count: 0, external_count: 0, document_count: 0, bytes_total: 0,
               correlation_id: correlation_id)

        Result.new(ok: false, code: code, message: message, recipients_count: 0,
                   external_count: 0, document_count: 0, bytes_total: 0,
                   correlation_id: correlation_id)
      end

      # A refusal raised while resolving the scope already carries its code and message and
      # has not touched the audit row, so it is finished here rather than rebuilt.
      def refuse_scope(mail_send, result, correlation_id, started)
        refuse(mail_send, result.code, correlation_id, started, result.message)
      end

      def fail_with(mail_send, diagnostic, correlation_id, started)
        finish(mail_send, MailSend::STATUS_FAILED, started,
               error: "#{diagnostic.code}: #{diagnostic.message}",
               recipients_count: 0, external_count: 0, document_count: 0, bytes_total: 0,
               correlation_id: correlation_id)

        Result.new(ok: false, code: :render_failed, message: diagnostic.message,
                   diagnostic: diagnostic, recipients_count: 0, external_count: 0,
                   document_count: 0, bytes_total: 0, correlation_id: correlation_id)
      end

      def finish(mail_send, status, started, **attributes)
        return if mail_send.nil?

        mail_send.finish(status: status, finished_at: Time.now,
                         duration_ms: ((monotonic_now - started) * 1000).round,
                         **attributes)
      rescue StandardError => e
        # THE AUDIT FAILING MUST NOT TAKE THE SEND WITH IT. Same rule as FR-41's second
        # rescue: an exception raised while recording an outcome is a worse fact than the
        # outcome, and it must not escape into the caller's own error path. It is LOGGED
        # rather than swallowed, because "it happened and we could not write it down" is
        # something an operator needs to know.
        warn_line("[adhoc-mail] could not record the audit row: #{e.class}: #{e.message}")
      end

      # `CLOCK_MONOTONIC`, per HANDOVER §1: a wall-clock duration measures zero under a
      # frozen clock, which is what every test in this repository runs under.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def restamp(diagnostic, correlation_id)
        Diagnostic.new(origin: diagnostic.origin, code: diagnostic.code,
                       message: diagnostic.message, correlation_id: correlation_id,
                       line: diagnostic.line, engine: diagnostic.engine,
                       engine_version: diagnostic.engine_version,
                       detail: diagnostic.detail)
      end

      # NON-THROWING AT ITS ONE CHOKE POINT. HANDOVER §1: "anything a rescue body calls is
      # part of the rescue's correctness", and a logger whose `warn` raises `Errno::EPIPE`
      # is what made T-25's runner stop delivering.
      def warn_line(line)
        logger.warn(line) if logger.respond_to?(:warn)
      rescue StandardError
        nil
      end
    end
  end
end
