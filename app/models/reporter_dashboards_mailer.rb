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
#   * It honours `no_self_notified` and `Setting.plain_text_mail?`.
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
    @template_name = schedule.template&.name
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
    @template_name = schedule.template&.name
    @occurrence_date = occurrence_date
    @diagnostic = diagnostic
    @project = schedule.project

    mail to: user,
         subject: l(:mail_subject_reporter_schedule_failed,
                    name: report_name(schedule), date: format_date(occurrence_date))
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
  end

  private

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
