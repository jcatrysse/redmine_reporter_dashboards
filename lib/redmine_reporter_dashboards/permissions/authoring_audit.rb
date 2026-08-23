# frozen_string_literal: true

module RedmineReporterDashboards
  module Permissions
    # THE UPGRADE DIAGNOSTIC: which roles hold a code-execution privilege over report
    # templates — the base plugin's, ours, or both. It decides nothing and grants nothing; it
    # makes the existing grants READABLE on a page an administrator already has.
    #
    # Two grants to surface, for opposite reasons:
    #
    #   * THE BASE PLUGIN'S. An install upgrading from it has roles holding
    #     `:manage_report_templates`. An administrator deciding who should author HERE needs
    #     that list rather than having to reconstruct it.
    #   * OURS. Core's `DefaultData::Loader` grants Manager every setable permission of ours
    #     on a fresh install (`lib/redmine/default_data/loader.rb`, identical on 5.1 through
    #     7.0), `require: :member` included. On that path nobody CHOSE to hand out code
    #     execution, and this is the only thing that says it happened.
    #
    # `BASE_AUTHORING` NAMES ONE PERMISSION, and it was read from that plugin's own
    # repository rather than inferred. Of the six it registers, only
    # `:manage_report_templates` is code execution: its controller does
    # `params[:report_template][:type].constantize.new` and then assigns the body from the
    # request. The other five render templates that are already STORED — consuming, not
    # authoring — and listing them would cry wolf on every role that may read a report, which
    # is the fastest way to make a diagnostic ignored.
    #
    # IT ASKS THE PLUGIN REGISTRY NOTHING, and that is the decision rather than an omission.
    # A permission grant is a string in `roles.permissions`, and Redmine never prunes one when
    # the plugin that registered it goes away. So a role can hold `:manage_report_templates`
    # on an install where the base plugin is no longer present — which is exactly when an
    # administrator needs the list, and exactly when gating on a presence check would print
    # an empty one.
    #
    # What that dangling grant does, measured: it is invisible on the roles screen (which
    # renders `setable_permissions`, and an unregistered permission is not setable);
    # `Role#allowed_to?` still answers true (`allowed_permissions` has no registry filter);
    # but every real check is project-scoped and answers false, because `Project#allows_to?`
    # is built from `AccessControl.modules_permissions`. So it is STALE DATA that re-arms if
    # the plugin is reinstalled, not a live code-execution path while it is gone.
    #
    # PURE. The caller passes the roles; anything answering `id`, `name`, `builtin` and
    # `permissions` will do, so every rule below is asserted in a DB-less spec rather than
    # only in a suite that needs Redmine booted.
    module AuthoringAudit
      # The base plugin's authoring permission — see the measurement above. An Array
      # because "how many are there" is a question the reader should not have to re-derive
      # if a later version of that plugin splits it.
      BASE_AUTHORING = %i[manage_report_templates].freeze

      # OURS, AND NARROWER THAN `Permissions.authoring_names` — curator decision #4,
      # 2026-08-13.
      #
      # `authoring: true` marks four permissions, and one of them —
      # `manage_public_reporter_dashboards_templates` — cannot actually write a template.
      # Its own entry says so: it maps `#new`/`#create`/`#edit`/`#update` so that Redmine's
      # `authorize` passes, and the controller then additionally requires `add_…` for
      # new/create and an edit permission for edit/update, with a functional test that holds
      # this permission ALONE and asserts 403 on both. So a role holding only it printed
      # *"Check that this was intended"* about somebody who cannot author — the cry-wolf
      # failure this page exists to avoid, found by T-27's independent review.
      #
      # The curator's two options were to change the FLAG or to narrow the DIAGNOSTIC, and
      # they took the second: the flag is T-40's contract and it also derives `require:
      # :member`, so relaxing it would let an administrator grant this to Non-member and
      # Anonymous — a migration and an upgrade note for a cosmetic gain. Narrowing is one
      # constant in one file and touches no permission contract.
      #
      # DERIVED FROM THE FLAG RATHER THAN TYPED OUT, and that is the part that has to keep
      # working: a fifth authoring permission added later must appear here by default, so
      # the subtraction names what it EXCLUDES and a spec pins the excluded set. A hand-typed
      # list of three would silently stop covering a new one.
      NOT_AUTHORING_IN_PRACTICE = %i[manage_public_reporter_dashboards_templates].freeze

      # One role's holdings. `base` and `own` are the permission names actually held, not
      # booleans, because the page prints them: "Manager holds authoring" is not actionable
      # and "Manager holds edit_reporter_dashboards_templates" is.
      Row = Struct.new(:role_id, :role_name, :builtin, :base, :own, keyword_init: true) do
        def initialize(*)
          super
          base&.freeze
          own&.freeze
          freeze
        end

        # Plain `def`, not the endless form. Redmine 5.1's Gemfile is
        # `ruby '>= 2.7.0', '< 3.3.0'`, so this plugin's code has to PARSE under 2.7 and
        # `def foo = expr` is a 3.0 syntax error. `.codex/check_ruby_floor.sh` greps for
        # exactly this and the first draft of this file tripped it.
        def base?
          !base.empty?
        end

        def own?
          !own.empty?
        end

        def both?
          base? && own?
        end

        # The upgrade case: authoring in the old plugin, none here. An administrator
        # deciding what to grant reads this column as "these people author today".
        def only_base?
          base? && !own?
        end

        # The `DefaultData::Loader` case, and the reason this diagnostic reports OUR roles
        # rather than only the base plugin's.
        def only_own?
          own? && !base?
        end

        # A code-execution grant on a role that applies to people who are not members of
        # the project — and, for Anonymous, to people with no account at all.
        #
        # This is reachable for the BASE plugin's permission and not for ours, which is the
        # whole point of deriving `require: :member` from `authoring` (`permissions.rb`):
        # `:manage_report_templates` is registered with no `require:` at all, so
        # `Role#setable_permissions` subtracts nothing for either builtin role and an
        # administrator can tick it on Anonymous. Ours cannot be offered there.
        def builtin?
          !builtin.nil? && builtin.to_i != 0
        end
      end

      class << self
        # Every role holding a code-execution privilege over report templates, ordered so
        # the output is stable on every engine (CLAUDE.md §6: no collection assertion
        # without an explicit order — and this one is printed, so an unstable order would
        # also make the page shuffle between visits).
        #
        # Roles holding NEITHER are left out. This is a diagnostic about code execution,
        # not a second roles screen: an install with forty roles and two authors must show
        # two rows.
        def rows(roles)
          Array(roles).filter_map { |role| row_for(role) }
                      .sort_by { |row| [row.role_name.to_s, row.role_id.to_i] }
        end

        # Is there anything to report? A separate question from `rows.empty?` only in that
        # it names the empty case, which the view has to render as a sentence rather than
        # as a blank table.
        def any?(roles)
          !rows(roles).empty?
        end

        # Ours that genuinely create or edit a template BODY: the `authoring: true` set
        # minus the ones a second guard refuses at the controller. Computed rather than
        # listed — see `NOT_AUTHORING_IN_PRACTICE`.
        #
        # PUBLIC, so a spec can assert the set itself rather than infer it from a row that
        # happens not to appear. "This permission is excluded" is unobservable through
        # `rows` alone: a role holding only it produces no row, and so does a role holding
        # nothing at all.
        def own_authoring
          Permissions.authoring_names - NOT_AUTHORING_IN_PRACTICE
        end

        private

        def row_for(role)
          held = permission_names(role)
          base = BASE_AUTHORING & held
          own = own_authoring & held
          return nil if base.empty? && own.empty?

          Row.new(role_id: role.id, role_name: role.name, builtin: role.builtin,
                  base: base, own: own)
        end

        # DEFENSIVE, AND THE STATED REASONS WERE WRONG — corrected after a review measured
        # them, because a guard whose rationale does not hold is a guard the next reader
        # deletes on the strength of the rationale.
        #
        # What is actually true on 5.1 → 7.0: `Role::PermissionsAttributeCoder.load`
        # returns an Array of Symbols for every input, `nil` included, and `permissions=`
        # normalises to symbols on write. So through a persisted `Role` the column is
        # never nil and never holds Strings, and neither guard below ever fires.
        #
        # They stay because THE CALLER IS NOT REQUIRED TO BE A `Role`: this module is
        # duck-typed on four readers precisely so it can be driven from a Struct in a
        # DB-less spec, and a future importer reading raw rows would bypass the coder
        # entirely. The String case is the one that matters, because comparing
        # `'manage_report_templates'` against a Symbol answers "nobody holds it" — this
        # diagnostic failing OPEN, which is the one direction that is not safe.
        #
        # `to_s.empty?` and not ActiveSupport's `presence`: this module is required by the
        # DB-less spec run, where Redmine's world — ActiveSupport included — is not loaded.
        # One `blank?` here would make the whole file untestable except under Rails, which
        # is the property `Permissions.collisions` was written to keep.
        def permission_names(role)
          Array(role.permissions).filter_map do |name|
            name.to_s.empty? ? nil : name.to_s.to_sym
          end
        end
      end
    end
  end
end
