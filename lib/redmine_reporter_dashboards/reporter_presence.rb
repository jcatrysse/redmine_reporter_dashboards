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
  #
  # --- WHAT THIS DETECTION IS FOR — DECIDED IN T-27, 2026-08-13 ---------------------
  #
  # The question was put to T-27 because the detection had been shrinking for a
  # generation: nothing is patched on its answer any more, and it looked like a memo with
  # no reader. It has exactly ONE consumer and it is load-bearing:
  # `load_patches` requires `REPORTER_GLUE_FILES` only when this answers true, and
  # `ScopeBinding#legacy_available?` then asks a POSITIVE `const_defined?` rather than
  # rescuing a NameError. That is the whole job. It is not a feature flag and nothing
  # user-facing may branch on it.
  #
  # **AND IT IS EXPLICITLY NOT THE INPUT TO T-27's UPGRADE DIAGNOSTIC**, which is where
  # the brief expected this to grow — it called `init.rb`'s boot line "the upgrade
  # diagnostic in embryo". Measurement says otherwise, and the direction matters:
  #
  #   A permission grant is a string in `roles.permissions`, and NOTHING in Redmine
  #   reconciles that column against the plugin registry. `Role#permissions=` writes what
  #   it is given; no uninstall prunes it. So a role keeps the base plugin's authoring
  #   permission after that plugin is gone — and no surface in Redmine shows it, because
  #   the roles screen renders `setable_permissions` and an unregistered permission is
  #   not setable.
  #
  # What that dangling grant does is narrower than the first version of this comment
  # claimed, and the correction matters because it is the sort of overstatement this repo
  # is contractually against. `Role#allowed_to?` does still answer true for it — its
  # `allowed_permissions` applies no registry filter — but every project-scoped check
  # returns false first, at `Project#allows_to?`. So while the plugin is uninstalled the
  # grant authorizes nothing; it re-arms on reinstall. Stale data an administrator
  # migrating must be able to see, not a live path.
  #
  # Either way a diagnostic gated on this module would report an empty list in precisely
  # the case it exists for. So
  # `Permissions::AuthoringAudit` reads Redmine's own permission tables and asks the
  # registry nothing. Do not wire the two together later "for consistency": they answer
  # different questions, and one of them is answerable when the other is not.
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
