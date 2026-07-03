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

# Minimal Liquid stub shared by every liquid-related spec, so drops/tags load and
# render without the real gem. Defined here (before any spec body) so the older
# per-spec `unless defined?(Liquid)` blocks become harmless no-ops, and the load
# order between specs no longer matters. Superset of everything the specs need.
unless defined?(Liquid)
  module Liquid
    class Tag
      def initialize(tag_name, markup, tokens)
        @tag_name = tag_name
        @markup   = markup
      end
    end

    class Template
      def self.register_tag(*); end
    end

    class Drop
      def to_liquid
        self
      end
    end

    class Context
      def initialize(env = {}, assigns = {}, registers = {})
        @scopes    = [assigns.dup]
        @env       = env
        @registers = registers
      end

      attr_reader :scopes, :registers

      def [](key)
        @scopes.reverse_each { |s| return s[key] if s.key?(key) }
        nil
      end
    end
  end
end

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
