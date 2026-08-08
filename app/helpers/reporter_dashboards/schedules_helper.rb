# frozen_string_literal: true

module ReporterDashboards
  # T-25's view vocabulary.
  #
  # Every method here exists because the same question is asked from more than one view and
  # a schedule has more nil-able parts than anything else in this plugin: its template can
  # be gone, its repeat rule can be unset, it may never have run. A view that answered each
  # of those inline would answer them slightly differently on each page — which is how a
  # list and a detail page come to disagree about whether a schedule is called anything.
  module SchedulesHelper
    # WHAT TO CALL A SCHEDULE, which has no name column of its own on purpose: a schedule
    # is "this template, on this rhythm", and a second name to keep in step with the
    # template's is a second thing to go stale.
    def reporter_schedule_name(schedule)
      name = schedule.template&.name.to_s.strip
      name.empty? ? l(:label_reporter_schedule) : name
    end

    def reporter_schedule_template_link(schedule)
      template = schedule.template
      # A DANGLING TEMPLATE SAYS SO rather than rendering a link to nothing. It is reachable
      # — `delete_all` and a DB-level delete bypass `dependent: :destroy` — and it is
      # exactly the state an operator is on this page to diagnose.
      return content_tag(:em, l(:text_reporter_schedule_template_missing)) if template.nil?
      return template.name unless template.visible?(User.current)

      link_to template.name, project_reporter_template_path(schedule.project, template)
    end

    def reporter_schedule_repeat_label(schedule)
      repeat = schedule.repeat.to_s
      return content_tag(:em, l(:label_reporter_schedule_repeat_unset)) if repeat.empty?

      # `default:` so a value from a newer plugin version prints itself instead of raising
      # a translation-missing span in the middle of a list.
      l(:"label_reporter_schedule_repeat_#{repeat}", default: repeat)
    end

    # FR-45 / FR-47 in a phrase. The recipient is usually NOT the person whose visibility
    # produced the numbers, and on a page listing several schedules that difference is the
    # only thing explaining why two reports over one template disagree.
    def reporter_schedule_identity_label(schedule)
      if schedule.render_as == RedmineReporterDashboards::Schedule::RENDER_AS_USER
        return link_to_user(schedule.render_as_user) if schedule.render_as_user

        return content_tag(:em, l(:text_reporter_schedule_identity_missing))
      end

      link_to_user(schedule.author) || content_tag(:em, l(:text_reporter_schedule_identity_missing))
    end

    # The one line `view_reporter_dashboards_schedules` exists for: did it run, and what
    # happened. Status and date together, because either alone is half an answer — "success"
    # with no date could be from last year.
    def reporter_schedule_last_run(schedule)
      return content_tag(:em, l(:text_reporter_schedule_never_run)) if schedule.last_run_on.nil? &&
                                                                      schedule.last_attempted_at.nil?

      date = format_date(schedule.last_run_on) || format_time(schedule.last_attempted_at)
      status = schedule.last_status.to_s
      return date if status.empty?

      "#{date} (#{l(:"label_reporter_schedule_status_#{status}", default: status)})"
    end

    def reporter_schedule_recipients_label(schedule)
      users = schedule.recipient_users.to_a
      return content_tag(:em, l(:text_reporter_schedule_no_recipients)) if users.empty?

      safe_join(users.map { |user| link_to_user(user) }, ', ')
    end
  end
end
