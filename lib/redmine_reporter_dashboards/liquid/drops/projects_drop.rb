# frozen_string_literal: true

require_relative 'collection_drop'
require_relative 'project_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A scope of projects.
      class ProjectsDrop < CollectionDrop
        private

        def drop_class
          ProjectDrop
        end
      end
    end
  end
end
