# frozen_string_literal: true

require_relative 'record_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A person. Reached as `{{ issue.author }}`, `{{ issue.assignee }}`, and
      # `{{ entry.user }}`.
      #
      # --- `mail` IS NOT HERE, AND THAT IS A DECISION ---
      #
      # Redmine lets a user hide their address (`UserPreference#hide_mail`, on by
      # default for new accounts on many installs). Honouring that per row means reading
      # `user.pref` for every user a report prints, and `preference` is not among the
      # associations `IssuesDrop` preloads — an issue list showing 500 authors' addresses
      # would be 500 queries, and preloading it for every issue list to serve the one
      # template that wants addresses is the opposite trade.
      #
      # Ignoring the preference instead is worse than an N+1: it publishes addresses the
      # owner asked to hide, into a document that gets mailed and archived.
      #
      # So the accessor is absent rather than wrong, and the gap is written down here
      # and in `implementation-plan.md` §Findings (F-8) rather than left for somebody to
      # rediscover. A report that genuinely needs addresses should get them from a
      # purpose-built accessor that preloads `:preference` and honours the flag — which
      # is a decision with a curator in it, not a line to slip into this class.
      class UserDrop < RecordDrop
        def login
          record.login
        end

        def firstname
          record.firstname
        end

        def lastname
          record.lastname
        end

        # Redmine's own `User#name` honours the instance's `user_format` setting, so a
        # report reads the way the rest of the application does rather than the way this
        # plugin would have guessed.
        def name
          record.name.to_s
        end

        def url
          absolute("/users/#{id}")
        end

        def to_s
          name
        end
      end
    end
  end
end
