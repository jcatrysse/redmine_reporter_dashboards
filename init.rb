# frozen_string_literal: true

require 'redmine'

# ---------------------------------------------------------------------------
# THE BASE PLUGIN IS NOT INVOLVED AT ALL — and there is no longer a detection.
#
# It used to be a hard dependency enforced here with a `raise`, which made this
# plugin uninstallable without a paid third-party plugin. Then it was OPTIONAL,
# detected once at after_plugins_loaded, with one thing hanging off the answer.
#
# Curator decision #1 (2026-08-13, `docs/plan/DECISIONS-PENDING.md`) withdrew the
# last of it: renders performed BY that plugin are no longer supported, so the
# performance patch on its controller is gone, and with its only consumer gone so
# is `ReporterPresence`. Nothing in this plugin now asks whether that plugin is
# installed, patches it, or behaves differently when it is present.
#
# What survives, deliberately, is the IMPORTER — `rake
# reporter_dashboards:migrate_from_reporter:*` reads that plugin's TABLES by name,
# which is the one place naming it is the point rather than a coupling. It works on
# a database from which the plugin has already been removed, so it needs no
# detection either.
# ---------------------------------------------------------------------------

if Rails.configuration.respond_to?(:autoloader) && Rails.configuration.autoloader == :zeitwerk
  Rails.autoloaders.each { |loader| loader.ignore(File.dirname(__FILE__) + '/lib') }
end
require File.dirname(__FILE__) + '/lib/redmine_reporter_dashboards'

Redmine::Plugin.register :redmine_reporter_dashboards do
  name 'Redmine Reporter Dashboards plugin'
  author 'Jan Catrysse'
  # THE ADMINISTRATION PAGE IS WHERE SOMEBODY DECIDES WHETHER THIS PLUGIN NEEDS ANOTHER ONE.
  # This said "Dashboard extension for the Redmine Reporter plugin" long after reporter
  # became optional (`requires_redmine_plugin` is absent below for that reason, and the boot
  # log two lines further down says so), which made a standalone install look like it was
  # missing a dependency. The migration relationship is real and is documented in the README,
  # which is where a reader can be told that it is an import path and not a requirement.
  description 'Project dashboards, report templates and scheduled reporting for Redmine: ' \
              'SQL-based issue and time-entry statistics, Liquid aggregation tags, charts, ' \
              'HTML/PDF rendering, mail delivery and expiring share links.'
  version '0.5.0'
  url 'https://github.com/jcatrysse/redmine_reporter_dashboards'
  author_url 'https://github.com/jcatrysse'

  # No requires_redmine_plugin: reporter is optional, and declaring it here would
  # make Redmine refuse to load this plugin without it.
  requires_redmine version_or_higher: '5.1'

  # --- Asset policy (T-33; technical-spec.md §5.1, FR-64) ---
  #
  # `:bundled` is the default and it is the whole security posture: no egress, third-party
  # URLs refused with the URL named. The two upgraded modes are PER INSTALL and never per
  # template — there is deliberately no project setting and no template field for them,
  # because template authoring is already a code-execution privilege (INV-9) and must not
  # additionally become a network privilege.
  #
  # Redmine performs NO validation on plugin settings, so every value here is coerced and
  # bounded on the way OUT, in `Assets::Policy.from_settings`, which drops an out-of-range
  # value with a log line rather than storing it (FR-15). The defaults below are therefore
  # the documented ones and not the enforcement.
  settings default: {
             'asset_policy' => 'bundled',
             'asset_allowlist' => '',
             'inline_max_bytes' => RedmineReporterDashboards::Assets::Policy::DEFAULT_INLINE_MAX_BYTES.to_s,
             'asset_max_bytes' => RedmineReporterDashboards::Assets::Policy::DEFAULT_ASSET_MAX_BYTES.to_s,
             # T-32 / FR-61 — ad-hoc report mail. `false` and an empty allowlist are the
             # defaults for the same reason `:bundled` is above: recipients are Redmine
             # users until an administrator says otherwise, and §4.1 puts external
             # addresses here rather than in a role permission because it is a policy about
             # the installation ("a report … mailed anywhere" is an egress question, not a
             # capability of a role in a project).
             #
             # The two together FAIL CLOSED: `MailPolicy` collapses "external enabled" to
             # off whenever the allowlist is empty, so ticking the box and saving nothing
             # is not "any domain". The settings page says so rather than leaving the
             # administrator to infer it.
             'mail_external_addresses' => false,
             'mail_external_domains' => '',
             'mail_rate_limit' => RedmineReporterDashboards::Reporting::MailPolicy::DEFAULT_RATE_LIMIT.to_s,
             'mail_rate_window_minutes' => RedmineReporterDashboards::Reporting::MailPolicy::DEFAULT_RATE_WINDOW_MINUTES.to_s,
             # --- FR-27 / technical-spec.md §5.2 clause 4: the engine this install uses ---
             #
             # EMPTY IS THE DEFAULT, and it means "the engine `config/capabilities.yml`
             # declares as the default" rather than "no engine". A fresh install and an
             # install that deliberately chose the default are therefore ONE state, which is
             # what lets the dropdown's blank option be honest.
             #
             # As with the asset settings above, nothing here is enforcement: the value is
             # coerced on the way OUT, in `Render::EnginePreference.from_settings`, which
             # drops an id no engine is registered under with a log line rather than letting
             # it select anything (FR-15). An engine that needs a service IS selectable here
             # — T-34's rule is that auto-detection never picks one FOR an install, and
             # choosing one deliberately is the decision that rule was waiting for.
             'render_engine' => RedmineReporterDashboards::Render::EnginePreference::NO_PREFERENCE
           },
           partial: 'settings/reporter_dashboards'

  # --- Permissions (T-40; technical-spec.md §4.1, FR-21/FR-21b) ---
  #
  # The permission SET is data, in `lib/redmine_reporter_dashboards/permissions.rb`, and
  # this loop is the only place it becomes a registration. That is not indirection for its
  # own sake: `spec/permissions/permission_map_spec.rb` reads the same data to assert that
  # every action here exists, that its controller really calls `authorize`, that every
  # permission is labelled in all nine locales, and that no public controller action is
  # left unaccounted for. None of that can be asked of a literal list inside this block
  # without booting Redmine.
  #
  # Registration order is REGISTERED's order, because the roles screen renders a module's
  # permissions in declaration order and that ordering is what an administrator reads. It
  # sorts the MODULES alphabetically, so no order here decides which fieldset comes first.
  #
  # `PLANNED` — the reporting permissions T-23/T-25/T-28/T-32 will add — is deliberately
  # NOT registered. A permission an administrator can tick, that guards nothing, is a lie
  # in the interface. See that file for the whole model and for why `[OQ-F]`'s
  # `template_authoring` setting is gone.
  RedmineReporterDashboards::Permissions.registrations_by_module
                                        .each do |project_module_name, registrations|
    project_module project_module_name do
      registrations.each { |name, actions, options| permission name, actions, options }
    end
  end

  # T-14. No icon class: the admin menu's icon mechanism changed between Redmine 5.1
  # and 6.x (`icon icon-*` versus `sprite_icon`), and a one-item diagnostic link is not
  # worth a `compat/` entry or a divergence the LOC budget has to carry. A plain link
  # renders correctly on all four supported branches.
  menu :admin_menu, :reporter_dashboards_preflight,
       { controller: 'reporter_preflight', action: 'show' },
       caption: :label_reporter_preflight

  # ONE PROJECT MENU ITEM, AND THE OTHER TWO WERE DELETED RATHER THAN HIDDEN.
  #
  # T-23 and T-25 each added one — `reporter_dashboards_templates` and
  # `reporter_dashboards_schedules`, both gated on the reports module and a read permission.
  # Curator decision 2026-08-21 moved both under **Project → Settings → Reports and
  # dashboards**, which is where a Redmine administrator looks for configuration, logs and
  # management. The pages, their routes, their controllers and their permissions are all
  # unchanged; only the way in moved.
  #
  # WHAT SURVIVES IS THE DASHBOARD, and the distinction is Redmine's own: the project menu
  # holds things you READ — Issues, Activity, Roadmap, Documents — and Project settings holds
  # things you CONFIGURE. A dashboard is the first kind. A template list and a schedule's run
  # history are the second.
  #
  # Two entry points to one page is not a courtesy either: the settings tab and a menu item
  # would drift on the permission they check the first time one of them is edited, and a user
  # who found the page in the menu would never discover the tab that is supposed to own it.
  menu :project_menu, :reporter_project_page,
       { controller: 'reporter_project_pages', action: 'show' },
       caption: :label_reporter_project_page,
       after: :overview,
       param: :project_id,
       if: proc { |project|
         project.module_enabled?(:reporter_project_dashboards) &&
           (User.current.admin? || User.current.allowed_to?(:view_reporter_project_page, project))
       }
end

# ---------------------------------------------------------------------------
# Patch + Liquid tag loading
#
# Everything that patches a core class is deferred to after_plugins_loaded. Project and
# Role gain an association each and override nothing. ProjectsHelper is the one exception
# and the one overridden core method in this plugin: `project_settings_tabs`, by `prepend`,
# adding a single project settings tab (curator decision 2026-08-21).
#
# For the helper the timing is load-bearing rather than merely convenient. Nine plugins in a
# real installation alias-chain that same method, and a prepend installed BEFORE such a
# chain makes the next chain capture our method as its `_without_` — measured to be a
# `NoMethodError` on `super`, i.e. a 500 on the project settings page, in their code.
# after_plugins_loaded is the one hook that runs after every plugin's init.rb, in every
# to_prepare cycle. See patches/projects_helper_patch.rb for the measurement.
#
# IT USED TO BE DEFERRED FOR A SECOND REASON THAT IS GONE: the reporter classes
# (IssueListReportTemplate, ReportTemplatesController) had to have been registered
# by the base plugin's own init.rb before this plugin could prepend into them.
# Nothing prepends into that plugin any more — the last such patch went with
# curator decision #1 — but the core reason stands on its own, and the permission
# collision check below genuinely needs the complete registry.
#
# after_plugins_loaded fires at the end of the same to_prepare cycle, after
# every plugin's init.rb has run. (Nesting a to_prepare here would defer to the
# next cycle, which never arrives in production.)
# ---------------------------------------------------------------------------
class RedmineReporterDashboardsLoader < Redmine::Hook::Listener
  def after_plugins_loaded(_context = {})
    # ONE LINE, UNCONDITIONALLY, AND THE SCOPE NOTE FOR DECISION #1 ASKED FOR THIS
    # EXPLICITLY: "keep the 'running standalone' log line or replace it deliberately —
    # an operator who expected the widgets reads it, and deleting it silently is the kind
    # of thing this project writes handover entries about."
    #
    # It used to branch on whether the base plugin was installed. There is no detection
    # left to branch on, and inventing one just to keep two log lines would be a memo with
    # no reader — the thing `ReporterPresence` was deleted for being. So the line says what
    # is now unconditionally true instead of which of two modes booted.
    #
    # Note what it deliberately does NOT say: nothing about the base plugin being absent.
    # On an install that HAS both plugins the old line said "detected", which now reads as a
    # promise this plugin no longer keeps. Saying only what this plugin does is accurate in
    # both installs, and the README's own section is where the operator learns that
    # host-rendered templates are withdrawn.
    Rails.logger.info(
      '[reporter_dashboards] ready — dashboards, SQL aggregation, report templates and ' \
      'statistics; no other plugin and no vendor gem required'
    )

    # T-40. Every plugin's init.rb has run, so the permission registry is complete and the
    # question "did someone else register one of our names" finally has a trustworthy
    # answer. Log-only; see the method for why it does not raise.
    RedmineReporterDashboards.check_permission_collisions

    # Register the Liquid tags FIRST and independently. Report templates depend on
    # {% sql_aggregate %} / {% geo_aggregate %}, so their registration must never be
    # skipped because an unrelated later step raised. Each register_* method rescues
    # its own errors. None of the four needs reporter.
    RedmineReporterDashboards.register_sql_aggregate_tag
    RedmineReporterDashboards.register_version_rollup_tag
    RedmineReporterDashboards.register_geo_version_map_tag
    RedmineReporterDashboards.register_chart_tag
    RedmineReporterDashboards.register_mermaid_tag

    # THE LAST STEP, AND NOTHING FOLLOWS IT ANY MORE. There used to be a
    # `return unless reporter` here and an `apply_reporter_patches` after it, prepending
    # `ReporterReportContentPatch` into the host plugin's `ReportTemplatesController`.
    # Curator decision #1 withdrew renders by that plugin, which made speeding that path up
    # incoherent — `DECISIONS-PENDING.md` says so in as many words — so the patch, the
    # `apply_patch` helper and the detection that gated them are all deleted.
    #
    # `load_patches` stays and is unconditional: both files it requires (`project_patch`,
    # `role_patch`) are this plugin's own patches into Redmine core.
    RedmineReporterDashboards.load_patches
  end
end
