# frozen_string_literal: true

module RedmineReporterDashboards
  module Permissions
    # T-27 — the UPGRADE DIAGNOSTIC. Which roles hold a code-execution privilege over
    # report templates: the base plugin's, ours, or both.
    #
    # --- WHY THIS EXISTS AT ALL, AND WHAT IT REPLACED ---
    #
    # `technical-spec.md` §4 answered INV-9 — *template authoring IS code execution* — with a
    # `template_authoring` plugin setting. T-40 deleted that shape (see `permissions.rb` for
    # the argument) and replaced it with role permissions, which left `[OQ-F]`'s second worry
    # unanswered by anything mechanical: *an upgraded install must not widen code execution
    # silently.* This module is that answer. It does not decide anything and it grants
    # nothing; it makes the existing grants READABLE, on a page an administrator already has.
    #
    # Two grants it has to surface, and they are found the same way for opposite reasons:
    #
    #   * **The base plugin's.** An install upgrading from it has roles
    #     holding `:manage_report_templates`. Those roles keep authoring there, and an
    #     administrator deciding who should author HERE needs to see that list rather than
    #     reconstruct it.
    #   * **Ours.** Core's `DefaultData::Loader` grants Manager every setable permission of
    #     ours on a fresh install (`lib/redmine/default_data/loader.rb:51`, identical on 5.1
    #     through 7.0), `require: :member` included. On that path nobody CHOSE to hand out
    #     code execution, and this diagnostic is the only thing that says it happened.
    #
    # --- THE MEASUREMENT THIS FILE RESTS ON ---
    #
    # `BASE_AUTHORING` is not inferred from this plugin's overrides, which is how several
    # earlier rounds of this project got the base plugin wrong (HANDOVER §1). It was read
    # from that plugin's own repository at `b1d1736`, `init.rb:19-32`, where it registers
    # six permissions. Exactly ONE of them is a code-execution privilege:
    #
    #     permission :manage_report_templates, {
    #       report_templates: [:new, :create, :edit, :update, :destroy, :preview, ...],
    #       report_schedules: [...] }
    #
    # because `ReportTemplatesController#create` is
    # `params[:report_template][:type].constantize.new` followed by `safe_attributes =
    # params[:report_template]` — the template BODY arrives in the request and is executed
    # server-side. The other five (`generate_issue_reports`, `view_issue_reports`,
    # `send_issue_reports`, `generate_time_entries_reports`, `view_time_entries_reports`)
    # render templates that are already STORED: `IssuesReportTemplatesController` resolves
    # `@report_templates` by id and calls `generate_reports` on them. Consuming, not
    # authoring. Listing those here would cry wolf on every role that may read a report,
    # which is the fastest way to make a diagnostic ignored.
    #
    # --- AND WHY IT IS NOT ASKED OF `ReporterPresence` ---
    #
    # This is the decision T-27 owed, and the answer inverts the brief's guess that the boot
    # log line is "the diagnostic in embryo". A permission grant is a STRING in
    # `roles.permissions`, and Redmine never prunes one when the plugin that registered it
    # goes away: `Role#permissions=` writes what it is given, and nothing anywhere reconciles
    # the column against the registry. So a role can hold `:manage_report_templates` on an
    # install where the base plugin is **no longer installed at all**, and gating this module
    # on `ReporterPresence.present?` would print an empty list in exactly that case.
    #
    # --- WHAT THE DANGLING GRANT DOES AND DOES NOT DO, MEASURED --------------------
    #
    # The first version of this comment said the grant is invisible on the roles screen
    # "while `Role#allowed_to?` keeps honouring it", which overstated the consequence. An
    # independent review measured it against core and the precise picture is:
    #
    #   * INVISIBLE on the roles screen: `app/views/roles/_form.html.erb` renders
    #     `setable_permissions`, built from `Redmine::AccessControl` — an unregistered
    #     permission is not setable, so nothing shows the grant. TRUE as stated.
    #   * `Role#allowed_to?(:manage_report_templates)` still answers **true**:
    #     `Role#allowed_permissions` (`role.rb:304-311`) is `permissions +
    #     public_permissions` with no registry filter at all.
    #   * But every REAL check is project-scoped, and there it answers **false**:
    #     `User#allowed_to?(action, project)` returns early on
    #     `Project#allows_to?` (`user.rb:777`), which is built from
    #     `AccessControl.modules_permissions` (`project.rb:1311-1319`). The base plugin
    #     declares this permission inside `project_module :issue_tracking`, so while that
    #     plugin is uninstalled nothing is authorized by the grant.
    #
    # So it is STALE DATA that re-arms the moment the plugin is reinstalled — not a live
    # code-execution path while it is gone. That is still exactly what this page is for: an
    # administrator migrating needs the list, and needs it after the old plugin has been
    # removed, which is when no other surface in Redmine will show it to them.
    #
    # Therefore: the audit reads Redmine's own permission tables and asks the plugin registry
    # NOTHING. `ReporterPresence` keeps its one real consumer — deciding whether
    # `REPORTER_GLUE_FILES` is required — and is not this diagnostic's input.
    #
    # --- PURE, LIKE `Permissions.collisions` AND FOR THE SAME REASON ---
    #
    # The caller passes the roles. Anything answering `id`, `name`, `builtin` and
    # `permissions` will do, which `Role` does and so does a Struct, so every rule below is
    # asserted in a DB-less spec instead of only in a suite that needs Redmine booted.
    module AuthoringAudit
      # The base plugin's authoring permission — see the measurement above. An Array
      # because "how many are there" is a question the reader should not have to re-derive
      # if a later version of that plugin splits it.
      BASE_AUTHORING = %i[manage_report_templates].freeze

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

        private

        def row_for(role)
          held = permission_names(role)
          base = BASE_AUTHORING & held
          own = Permissions.authoring_names & held
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
