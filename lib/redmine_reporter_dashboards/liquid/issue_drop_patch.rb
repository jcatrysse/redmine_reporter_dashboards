# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # Prepended into RedmineReporter::Liquid::Drops::IssueDrop to add
    # `issue.target_version` without editing any Reporter file (survives Reporter
    # updates).
    #
    # Accessor note: the base Redmineup::Liquid::IssueDrop stores the wrapped
    # ActiveRecord Issue in the @issue instance variable (Reporter's own IssueDrop
    # relies on @issue throughout — e.g. @issue.project, @issue.attachments), and
    # the constructor is IssueDrop.new(issue). We read the target version through
    # that same @issue via Issue#fixed_version, the canonical Redmine accessor for
    # an issue's target version.
    #
    # Trade-off vs a Liquid filter: a prepend gives the requested attribute syntax
    # `issue.target_version` (matching issue.project / issue.version), whereas a
    # filter would force `{{ issue | target_version }}`. The only fragility of the
    # prepend is Liquid's per-class memoisation of invokable methods; the
    # registration (see RedmineReporterDashboards.register_issue_target_version_drop)
    # resets that memo so the method is recognised regardless of load order.
    module IssueDropPatch
      def target_version
        issue = defined?(@issue) ? @issue : nil
        return nil unless issue.respond_to?(:fixed_version)

        version = issue.fixed_version
        version && RedmineReporterDashboards::Liquid::VersionDrop.new(version)
      end
    end
  end
end
