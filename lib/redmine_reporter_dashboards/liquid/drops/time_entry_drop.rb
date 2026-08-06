# frozen_string_literal: true

require_relative 'record_drop'
require_relative 'user_drop'
require_relative 'project_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # One logged time entry.
      #
      # Reached as `{{ issue.time_entries }}`, which `Batch` resolves through
      # `TimeEntry.visible(actor)` — so an entry a viewer may not see never reaches this
      # class at all. That is the right place for the check: a drop that filtered would
      # be a second visibility rule to keep in step with the first.
      class TimeEntryDrop < RecordDrop
        def spent_on
          record.spent_on
        end

        def hours
          record.hours.to_f
        end

        def comments
          record.comments
        end

        def user
          @user ||= (record.user && UserDrop.new(record.user, context: render_context))
        end

        # The activity is a `TimeEntryActivity` enumeration — a named reference in
        # exactly §3.3's sense, so it is one, and `activity_id` ships beside it. There
        # is no per-enumeration page in Redmine, so the URL is nil rather than invented:
        # a link to a 404 is worse than no link.
        def activity
          @activity ||= named_ref(record.activity, path: nil)
        end

        def activity_id
          record.activity_id
        end

        def project
          @project ||= (record.project && ProjectDrop.new(record.project, context: render_context))
        end

        def project_id
          record.project_id
        end

        def issue_id
          record.issue_id
        end

        def created_on
          in_actor_zone(record.created_on)
        end

        def updated_on
          in_actor_zone(record.updated_on)
        end

        def url
          absolute("/time_entries/#{id}")
        end

        def to_s
          format('%.2f', hours)
        end
      end
    end
  end
end
