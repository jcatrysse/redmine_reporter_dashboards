# frozen_string_literal: true

require_relative 'collection_drop'
require_relative 'user_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A scope of users. Nothing to preload: `UserDrop` reads columns off the row it
      # was handed and follows no association — which is a consequence of `mail` not
      # being exposed (see `UserDrop`), not an oversight.
      class UsersDrop < CollectionDrop
        private

        def drop_class
          UserDrop
        end
      end
    end
  end
end
