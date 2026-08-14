# frozen_string_literal: true

require 'redmine'

# ---------------------------------------------------------------------------
# redmine_reporter is OPTIONAL
#
# It used to be a hard dependency enforced here with a `raise`, which made this
# plugin uninstallable without a paid third-party plugin. Project dashboards, the
# SQL aggregation tags and the statistics endpoint need none of it.
#
# Detection is therefore deferred rather than done here: it belongs at
# after_plugins_loaded, below, where every plugin's init.rb has run and the
# registry is actually complete. Asking at this point would answer for whatever
# subset of plugins happened to load first.
#
# See RedmineReporterDashboards.reporter_present?.
# ---------------------------------------------------------------------------

if Rails.configuration.respond_to?(:autoloader) && Rails.configuration.autoloader == :zeitwerk
  Rails.autoloaders.each { |loader| loader.ignore(File.dirname(__FILE__) + '/lib') }
end
require File.dirname(__FILE__) + '/lib/redmine_reporter_dashboards'

Redmine::Plugin.register :redmine_reporter_dashboards do
  name 'Redmine Reporter Dashboards plugin'
  author 'Jan Catrysse'
  description 'Dashboard extension for the Redmine Reporter plugin, adding project dashboards, ' \
              'SQL-based issue statistics and Liquid aggregation tags.'
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

  # T-23. A SECOND project menu item, because the reports module is a second module: a
  # project can have dashboards without the reporting surface, which is the question
  # `:reporter_dashboards_reports` exists to ask. Both conditions are checked — the module
  # AND the permission — because `module_enabled?` alone would show the link to somebody
  # the controller then refuses, and `allowed_to?` alone would show it in a project that
  # has the feature switched off.
  menu :project_menu, :reporter_dashboards_templates,
       { controller: 'reporter_dashboards/templates', action: 'index' },
       caption: :label_reporter_template_plural,
       after: :reporter_project_page,
       param: :project_id,
       if: proc { |project|
         project.module_enabled?(:reporter_dashboards_reports) &&
           (User.current.admin? ||
             User.current.allowed_to?(:view_reporter_dashboards_reports, project))
       }

  # T-25. A THIRD project menu item, gated on the READ permission rather than on the
  # authoring one: `view_reporter_dashboards_schedules` exists so an operator can answer
  # "did it run" without being able to change who receives it, and a link they cannot see
  # is a question they cannot answer.
  menu :project_menu, :reporter_dashboards_schedules,
       { controller: 'reporter_dashboards/schedules', action: 'index' },
       caption: :label_reporter_schedule_plural,
       after: :reporter_dashboards_templates,
       param: :project_id,
       if: proc { |project|
         project.module_enabled?(:reporter_dashboards_reports) &&
           (User.current.admin? ||
             User.current.allowed_to?(:view_reporter_dashboards_schedules, project))
       }

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
# Everything that prepends/includes into core or reporter classes is deferred
# to after_plugins_loaded so that:
#   * Project / ProjectsHelper / Report are fully defined, and
#   * reporter classes (IssueListReportTemplate, ReportTemplatesController) have
#     been registered by redmine_reporter's own init.rb.
#
# after_plugins_loaded fires at the end of the same to_prepare cycle, after
# every plugin's init.rb has run. (Nesting a to_prepare here would defer to the
# next cycle, which never arrives in production.)
# ---------------------------------------------------------------------------
class RedmineReporterDashboardsLoader < Redmine::Hook::Listener
  def after_plugins_loaded(_context = {})
    # Asked exactly once, here, and memoised from now on. This is the first moment
    # the answer is trustworthy and the last moment it can still change.
    reporter = RedmineReporterDashboards.reporter_present?

    # Logged either way, at info. "Running standalone" is a normal state, not a
    # degradation — but an operator who expected the report widgets to be there
    # needs one line telling them why they are not, rather than an empty picker.
    Rails.logger.info(
      if reporter
        '[reporter_dashboards] redmine_reporter detected — report widgets and drop patches enabled'
      else
        '[reporter_dashboards] redmine_reporter not installed — running standalone; ' \
        'dashboards, SQL aggregation and statistics are unaffected'
      end
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
    RedmineReporterDashboards.load_patches

    return unless reporter

    # T-20 removed a fourth step here — the prepend that added `issue.target_version`
    # and `issue.custom_field_value[…]` to the HOST plugin's issue drop. Both accessors
    # are now on this plugin's own drops. See RedmineReporterDashboards for the note.
    RedmineReporterDashboards.apply_reporter_patches
  end
end
