# frozen_string_literal: true

require_relative 'record_drop'
require_relative 'string_substitutable'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A target version — and the class that makes `{% geo_version_map %}` unnecessary.
      #
      # --- WHY IT IS STRING-SUBSTITUTABLE ---
      #
      # The gem's `IssueDrop#version` returned `fixed_version.name`, a String
      # (`drops/issues_drop.rb:79-97`). So `{% if issue.version == "2026.1" %}` is in
      # templates today, and returning an object here would break every one of them at
      # once. `StringSubstitutable` is the same five-method contract §3.3 specifies for
      # `NamedRefDrop`, and it is shared rather than copied because a contract that is
      # only correct because a spec proves it must not have a second, unproven copy.
      #
      # --- WHAT THE 295 LINES WERE FOR ---
      #
      # `{% geo_version_map %}` (144 lines) plus the addon's own `VersionDrop` (108) plus
      # `issue_drop_patch.rb` (43) exist because the gem's version accessor was a bare
      # name: a template that needed `{id, effective_date, status, project}` per version
      # had to be handed a map built by a tag. Every one of those four is an accessor
      # here, so the tag has nothing left to do. T-20 deletes it; this class is the
      # reason it can.
      #
      # The absolute URLs come with it. The addon reimplemented the gem's VersionDrop
      # mostly to add them, because a relative href in a PDF resolves against nothing —
      # see `AbsoluteUrl`, which is now where that decision lives for the whole layer.
      class VersionDrop < RecordDrop
        include StringSubstitutable

        def name
          record.name.to_s
        end

        def description
          record.description
        end

        # A Date or nil. Redmine's column is `effective_date`; the UI calls it the due
        # date. The column name wins — a template author reading the API docs finds
        # `effective_date`, and inventing a friendlier synonym is how a vocabulary ends
        # up with two of everything.
        def effective_date
          record.effective_date
        end

        # 'open' | 'locked' | 'closed'
        def status
          record.status
        end

        def sharing
          record.sharing
        end

        def completed_percent
          record.completed_percent
        end

        def project
          @project ||= (record.project && ProjectDrop.new(record.project, context: render_context))
        end

        def project_id
          record.project_id
        end

        # `project_identifier` and `project_name` are kept, and the reason is different
        # from the one that DROPPED `IssueDrop#project_name`.
        #
        # There, §3.2 folded a gem accessor into `project.name` because two spellings of
        # one fact is how a template prints them inconsistently, and the gem's spelling
        # had no other claim. Here both names are THIS PLUGIN'S OWN shipped surface: the
        # addon's `VersionDrop` published them, `{% version_rollup %}` hands its rows to
        # templates that read them, and T-20 moves the implementation, not the
        # vocabulary. Deleting a name a plugin shipped, in the release that moves the
        # class behind it, is a migration cost with nothing bought by it.
        #
        # They stay aliases in spirit — one fact, resolved through `project` — so there
        # is no second code path to keep in step.
        def project_identifier
          record.project&.identifier
        end

        def project_name
          record.project&.name
        end

        def url
          absolute("/versions/#{id}")
        end

        # The roadmap and the three issue lists. Kept from the addon's VersionDrop
        # because they are what its templates link to, and a report whose version
        # heading is not clickable is a report somebody has to search Redmine for.
        #
        # The query-parameter names are Redmine's own IssueQuery filter names, and the
        # status operators are its own: `o` open, `c` closed, `*` any.
        def roadmap_url
          absolute("/projects/#{project_identifier}/roadmap")
        end

        def issues_url
          issues_url_for('*')
        end

        def open_issues_url
          issues_url_for('o')
        end

        def closed_issues_url
          issues_url_for('c')
        end

        # Time entries whose ISSUE targets this version — `issue.fixed_version_id` is a
        # TimeEntryQuery filter, and the bracket and `=` characters are percent-encoded
        # so the href is valid rather than merely usually valid.
        def time_url
          absolute("/projects/#{project_identifier}/time_entries?set_filter=1" \
                   '&f%5B%5D=issue.fixed_version_id' \
                   '&op%5Bissue.fixed_version_id%5D=%3D' \
                   "&v%5Bissue.fixed_version_id%5D%5B%5D=#{id}")
        end

        private

        def issues_url_for(status_id)
          absolute("/projects/#{project_identifier}/issues?set_filter=1" \
                   "&fixed_version_id=#{id}&status_id=#{status_id}")
        end
      end
    end
  end
end
