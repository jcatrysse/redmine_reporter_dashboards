# frozen_string_literal: true

module RedmineReporterDashboards
  # Is the optional redmine_reporter plugin installed?
  #
  # This used to be a hard `raise` in init.rb, which made the whole plugin
  # uninstallable without a paid third-party plugin — even though project
  # dashboards, the SQL aggregation tags and the statistics endpoint need none of it.
  #
  # Two rules govern the answer:
  #
  # 1. **It is a positive question put to the plugin registry**, never a
  #    `rescue NameError` around one of reporter's constants. Inferring absence from
  #    a swallowed error is how the vendor-gem coupling stayed invisible for a whole
  #    release line: the plugin booted, logged nothing, and then failed somewhere
  #    that looked unrelated. Here, absence is a fact that was asked for; a
  #    NameError anywhere downstream is a defect and is logged as one.
  #
  # 2. **It is asked once, at `after_plugins_loaded`, and memoised.** Earlier than
  #    that and the registry only holds whichever plugins happened to load first;
  #    later than that it cannot change, and the dashboard render path asks it.
  #
  # Its own file, with no dependencies at all, because it is the one question that
  # has to be answerable before any of Redmine's world is assumed to exist — which
  # is also what lets it be tested without booting Redmine.
  module ReporterPresence
    PLUGIN_ID = :redmine_reporter

    class << self
      def present?
        return @present unless @present.nil?

        @present = detect
      end

      # Forces the next ask to re-detect: for specs, and for a development reload
      # that rebuilds the plugin registry inside a live process.
      def reset!
        @present = nil
      end

      private

      # `respond_to?` as well as `defined?`: a process that has some other Redmine
      # constant but no plugin registry (a bare spec run, a rake task loading part of
      # the world) must get a clean false rather than a NoMethodError.
      def detect
        return false unless defined?(::Redmine::Plugin)
        return false unless ::Redmine::Plugin.respond_to?(:installed?)

        !!::Redmine::Plugin.installed?(PLUGIN_ID)
      end
    end
  end
end
