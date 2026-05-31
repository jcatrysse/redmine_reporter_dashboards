# frozen_string_literal: true

module RedmineReporterDashboards
  module Patches
    module ProjectPatch
      def self.included(base)
        base.class_eval do
          has_many :reporter_project_tabs, class_name: 'ReporterProjectTab', dependent: :destroy
        end
      end
    end
  end
end

unless Project.included_modules.include?(RedmineReporterDashboards::Patches::ProjectPatch)
  Project.include RedmineReporterDashboards::Patches::ProjectPatch
end
