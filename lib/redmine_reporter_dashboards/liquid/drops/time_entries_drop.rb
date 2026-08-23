# frozen_string_literal: true

require_relative 'collection_drop'
require_relative 'time_entry_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A scope of time entries — the top-level `{{ time_entries }}` form, as opposed to
      # `{{ issue.time_entries }}`, which `Batch` serves.
      #
      # THE SCOPE MUST ALREADY BE THE VIEWER'S. Nothing here filters, deliberately:
      # §3.5 makes "every scope comes from a visibility-scoped source" a construction
      # rather than a check, and a second filter in the drop would be a second rule to
      # keep in step. The batched sibling is filtered in `Batch` for the same reason —
      # one place, and it is the place that builds the query.
      class TimeEntriesDrop < CollectionDrop
        PRELOADS = %i[activity user project].freeze

        private

        def drop_class
          TimeEntryDrop
        end
      end
    end
  end
end
