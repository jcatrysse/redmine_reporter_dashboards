# frozen_string_literal: true

begin
  require 'bundler/setup'
rescue Bundler::GemNotFound, Bundler::SolveFailure, LoadError
  # Running outside Bundler context (e.g. standalone CI with system gems).
end
require 'rspec/core'
require 'rspec/expectations'
require 'rspec/mocks'

# NOTE: the plugin's main lib (lib/redmine_reporter_dashboards.rb) is intentionally
# NOT required here. It loads project_page.rb, which references Redmine::I18n at
# load time — unavailable in a bare RSpec run. The SQL aggregation specs are pure unit
# specs that require their own lib files and stub their collaborators, so they run
# without booting Redmine.

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.order = :random
  config.disable_monkey_patching!
end
