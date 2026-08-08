# frozen_string_literal: true

# T-25's mail path.
#
# --- WHY THIS SUBCLASSES REDMINE'S `Mailer` INSTEAD OF `ActionMailer::Base` ---
#
# Not for convenience. Four behaviours a plugin must not reimplement live in that class,
# and each of them is a defect if it is missing:
#
#   * `#process` sets `User.current` to the RECIPIENT and switches `I18n.locale` to their
#     language for the duration. That is why every action here takes a `User` first — the
#     override raises `ArgumentError` otherwise — and it is what makes nine locale files
#     mean anything on the mail path.
#   * `#mail` builds `From` from `Setting.mail_from` with a display name, and the `List-Id`
#     header. §7b.5's finding is that the base plugin let a schedule specify `from` as free
#     text: "a report over any issue in the instance, mailed anywhere, with a forged
#     sender". THE SENDER IS SERVER-CONTROLLED HERE BECAUSE THERE IS NO CODE PATH THAT
#     COULD SET IT — not because a validation rejects one.
#   * It honours `Setting.plain_text_mail?`. It does NOT honour `no_self_notified`, and
#     that is deliberate rather than inherited: Redmine gates that branch on `@author`,
#     which this mailer never sets, because a scheduled report has no author-of-the-action
#     — the schedule's owner is a legitimate recipient of their own schedule and should not
#     be silently dropped from a list they put themselves on.
#   * `.deliver_mail` refuses a message with no recipient rather than raising deep inside
#     the delivery stack.
#
# --- THE ONE THING TO BE CAREFUL OF, WHICH IS `User.current` ---
#
# `#process` makes `User.current` the recipient while the mail VIEW renders. The report is
# already bytes by then — `ScheduledDelivery` renders once, as the schedule's identity,
# before any recipient is looked at (FR-42) — so nothing here can make a visibility
# decision. That ordering is the guarantee, and a view that started resolving issues would
# quietly break it, which is why these views are given strings and a byte array and no
# scope at all.
#
# FR-47 asks that shared output be "labelled with the identity it was rendered as", and
# that is exactly why: the recipient is NOT the person whose visibility produced the
# numbers, so the mail says whose it is.
class ReporterDashboardsMailer < Mailer
  # A DELIVERED REPORT.
  #
  # `attachments` is `[[filename, bytes], …]` and not a Hash — a per-record run can produce
  # two documents whose names collide, and a Hash would silently keep one of them.
  def scheduled_report(user, schedule, occurrence_date, attachments, rendered_as,
                       correlation_id)
    redmine_headers 'Project' => schedule.project&.identifier,
                    'Schedule-Id' => schedule.id,
                    'Correlation-Id' => correlation_id

    @user = user
    @schedule = schedule
    # `report_name`, not the bare association: with a dangling `template_id` the subject
    # fell back to "Scheduled report" while the body read "Here is the  report for …".
    # Two fallbacks for one value is one too many.
    @template_name = report_name(schedule)
    @occurrence_date = occurrence_date
    @rendered_as = rendered_as
    @correlation_id = correlation_id
    @project = schedule.project

    attachments.each { |name, bytes| self.attachments[name] = bytes }

    mail to: user, subject: subject_for(schedule, occurrence_date)
  end

  # FR-43. NO ATTACHMENT ON THIS PATH, and that is the requirement rather than an oversight:
  # "a failed scheduled render notifies the owner with no attachment; recipients never
  # receive a green-looking e-mail containing a failure."
  #
  # `diagnostic.to_h` deliberately omits `detail` (§7b.3's leak prevention), so what reaches
  # the owner is a code, a safe message and a correlation id — never a raw exception, never
  # SQL. The id is the one in the log line and in the run row, which is FR-58's whole point.
  def scheduled_report_failure(user, schedule, occurrence_date, diagnostic)
    redmine_headers 'Project' => schedule.project&.identifier,
                    'Schedule-Id' => schedule.id,
                    'Correlation-Id' => diagnostic.correlation_id

    @user = user
    @schedule = schedule
    @template_name = report_name(schedule)
    @occurrence_date = occurrence_date
    @diagnostic = diagnostic
    @project = schedule.project

    mail to: user,
         subject: l(:mail_subject_reporter_schedule_failed,
                    name: report_name(schedule), date: format_date(occurrence_date))
  end

  # T-32 / FR-61 — AN AD-HOC REPORT, TO A REDMINE USER.
  #
  # --- `From` IS SERVER-CONTROLLED, AND THE MECHANISM IS THE ABSENCE OF A PARAMETER ---
  #
  # §7b.5's finding about the base plugin is that `to`/`cc`/`bcc`/**`from`** are free text:
  # "a report over any issue in the instance, mailed anywhere, with a forged sender".
  #
  # Redmine's `Mailer#mail` builds `From` from `Setting.mail_from` and merges it with
  # `reverse_merge!`, so a caller passing its own `'From'` header would WIN. Nothing here
  # passes one, and nothing can: neither of these two methods takes a sender, an address to
  # put in one, or a Hash that could carry one. `spec/reporting/adhoc_mailer_spec.rb`
  # asserts that against the parameter list rather than against this comment, which is the
  # same shape `DocumentRequest`'s "no field a credential could travel in" assertion takes.
  #
  # --- `Reply-To` IS THE REQUESTER, WHICH IS WHAT THE `from` FIELD WAS BEING USED FOR ---
  #
  # §7b.5: "The requester's address goes in `Reply-To`, which is what people actually wanted
  # from the field." A recipient who answers the report reaches the colleague who sent it
  # rather than a no-reply mailbox, and the envelope still says which server sent it.
  #
  # `@author` IS DELIBERATELY NOT SET. Redmine uses it to put a person's name in the `From`
  # display name, and this mail is sent by the installation on somebody's behalf, not by
  # them — a display name reading like the requester's own account is exactly the ambiguity
  # "server-controlled sender" is supposed to remove. It also keeps `no_self_notified` out
  # of the path: a requester who mails a report to themselves gets it.
  def adhoc_report(user, template, requester, attachments, subject, correlation_id)
    redmine_headers 'Project' => template&.project&.identifier,
                    'Template-Id' => template&.id,
                    'Correlation-Id' => correlation_id

    @user = user
    @template_name = adhoc_report_name(template)
    @requester = requester
    @correlation_id = correlation_id
    @project = template&.project

    attachments.each { |name, bytes| self.attachments[name] = bytes }

    mail to: user, reply_to: requester&.mail.presence,
         subject: adhoc_subject(template, subject)
  end

  # THE SAME MAIL, TO AN ADDRESS THAT IS NOT A REDMINE ACCOUNT (FR-61's allowlisted case).
  #
  # --- WHY THE FIRST ARGUMENT IS STILL A USER ---
  #
  # `Mailer#process` raises `ArgumentError` unless `args.first.is_a?(User)`, because it uses
  # it to set `User.current` and the recipient's language for the duration of the render.
  # An external recipient has no account, so `User.anonymous` is passed — which is honest
  # rather than a workaround: `logged?` is false, so the mail is composed in
  # `Setting.default_language`, which is the only language the installation knows for
  # somebody it has never met.
  #
  # It is also the safe value for `User.current`. The report is already BYTES by the time
  # this runs — `AdhocDelivery` renders once, as the requester, before any recipient is
  # looked at — so nothing in the view can make a visibility decision, and if a later edit
  # tried, it would be making it as Anonymous rather than as somebody with access.
  def adhoc_report_to_address(anonymous, address, template, requester, attachments, subject,
                              correlation_id)
    redmine_headers 'Project' => template&.project&.identifier,
                    'Template-Id' => template&.id,
                    'Correlation-Id' => correlation_id

    @user = anonymous
    @template_name = adhoc_report_name(template)
    @requester = requester
    @correlation_id = correlation_id
    @project = template&.project
    # The view says "somebody at this Redmine sent you this" rather than addressing a name
    # it does not have.
    @external = true

    attachments.each { |name, bytes| self.attachments[name] = bytes }

    mail to: address, reply_to: requester&.mail.presence,
         subject: adhoc_subject(template, subject)
  end

  class << self
    # `deliver_now`, NOT `deliver_later`, and the difference is what the run row means.
    #
    # An enqueued mail is a promise; the scheduler records a fact. With `deliver_later` the
    # run row would say `success` the instant the job was queued, and a queue that is not
    # being worked — which is the default on an install with no background worker — turns
    # every scheduled report into a green row and an empty inbox. `ScheduledDelivery` wraps
    # these calls in `raise_delivery_errors` so an SMTP failure reaches the run row too.
    def deliver_scheduled_report(user, schedule, occurrence_date, attachments, rendered_as,
                                 correlation_id)
      scheduled_report(user, schedule, occurrence_date, attachments, rendered_as,
                       correlation_id).deliver_now
    end

    def deliver_scheduled_report_failure(user, schedule, occurrence_date, diagnostic)
      scheduled_report_failure(user, schedule, occurrence_date, diagnostic).deliver_now
    end

    # T-32. `deliver_now` for the same reason as above: the audit row records a fact, and
    # an enqueued mail on an install with no worker would make it record a promise.
    def deliver_adhoc_report(user, template, requester, attachments, subject, correlation_id)
      adhoc_report(user, template, requester, attachments, subject,
                   correlation_id).deliver_now
    end

    def deliver_adhoc_report_to_address(address, template, requester, attachments, subject,
                                        correlation_id)
      adhoc_report_to_address(::User.anonymous, address, template, requester, attachments,
                              subject, correlation_id).deliver_now
    end
  end

  private

  # T-32. The author's own subject wins when they typed one, exactly as it does for a
  # schedule — and for the same reason: a report called "Monday numbers" should not arrive
  # as "[Report] Monday numbers".
  def adhoc_subject(template, subject)
    custom = subject.to_s.strip
    return custom unless custom.empty?

    l(:mail_subject_reporter_adhoc_report, name: adhoc_report_name(template))
  end

  def adhoc_report_name(template)
    name = template&.name.to_s.strip
    name.empty? ? l(:label_reporter_adhoc_mail) : name
  end

  # The author's own subject wins when they set one — that is what the column is for — and
  # the generated one is the fallback rather than a prefix on theirs. A schedule called
  # "Monday numbers" should not arrive as "[Report] Monday numbers".
  def subject_for(schedule, occurrence_date)
    custom = schedule.email_subject.to_s.strip
    return custom unless custom.empty?

    l(:mail_subject_reporter_schedule_report,
      name: report_name(schedule), date: format_date(occurrence_date))
  end

  def report_name(schedule)
    name = schedule.template&.name.to_s.strip
    name.empty? ? l(:label_reporter_schedule) : name
  end
end
