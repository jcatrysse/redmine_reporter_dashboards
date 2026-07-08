# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # Liquid drop wrapping a Redmine Version, exposed on the Reporter issue drop
    # as `issue.target_version` (see IssueDropPatch).
    #
    # Every URL is ABSOLUTE — built from the Redmine host settings — so links keep
    # working when a report is exported to PDF by wkhtmltopdf (which has no request
    # context to resolve relative paths against).
    #
    # All attributes are plain public methods, which Liquid exposes for string /
    # dot access in templates:
    #   {{ issue.target_version.name }}
    #   <a href="{{ issue.target_version.roadmap_url }}">Roadmap</a>
    #
    # The query-parameter names are the exact ones Redmine 6.1 uses:
    #   * IssueQuery filters:     fixed_version_id, status_id (operators o/c/*)
    #   * TimeEntryQuery filter:  issue.fixed_version_id
    class VersionDrop < ::Liquid::Drop
      def initialize(version)
        @version = version
      end

      # ---- scalar attributes -------------------------------------------------

      def id
        @version.id
      end

      def name
        @version.name
      end

      def description
        @version.description
      end

      # Date or nil.
      def effective_date
        @version.effective_date
      end

      # 'open' | 'locked' | 'closed'
      def status
        @version.status
      end

      def completed_percent
        @version.completed_percent
      end

      def project_identifier
        @version.project&.identifier
      end

      def project_name
        @version.project&.name
      end

      # ---- absolute URLs -----------------------------------------------------

      def url
        "#{base_url}/versions/#{id}"
      end

      def roadmap_url
        "#{base_url}/projects/#{project_identifier}/roadmap"
      end

      # All issues targeting this version (status_id=* → any status).
      def issues_url
        issues_url_for('*')
      end

      def open_issues_url
        issues_url_for('o')
      end

      def closed_issues_url
        issues_url_for('c')
      end

      # Time entries whose issue targets this version. Uses the explicit
      # f[]/op[]/v[] filter form; the bracket and '=' operator characters are
      # percent-encoded so the href is valid (%5B=[ %5D=] %3D==).
      def time_url
        "#{base_url}/projects/#{project_identifier}/time_entries?set_filter=1" \
          "&f%5B%5D=issue.fixed_version_id" \
          "&op%5Bissue.fixed_version_id%5D=%3D" \
          "&v%5Bissue.fixed_version_id%5D%5B%5D=#{id}"
      end

      private

      # Built once from Redmine settings, e.g. "https://redmine.example.eu"
      # (Setting.host_name may include a path prefix, which is preserved).
      def base_url
        @base_url ||= "#{Setting.protocol}://#{Setting.host_name}"
      end

      def issues_url_for(status_id)
        "#{base_url}/projects/#{project_identifier}/issues" \
          "?set_filter=1&fixed_version_id=#{id}&status_id=#{status_id}"
      end
    end
  end
end
