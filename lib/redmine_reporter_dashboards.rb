# frozen_string_literal: true

require File.dirname(__FILE__) + '/redmine_reporter_dashboards/compat'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/block_settings'
# T-40. Required BEFORE anything else that could fail, because `init.rb`'s
# `Redmine::Plugin.register` block reads it to declare the permissions: a plugin whose
# permission set failed to load would boot with an authorize call that permits nobody,
# which looks exactly like a misconfigured role.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/permissions'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/positioned'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/report_frame'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporter_presence'
# Called from a my-page partial, which core renders through its OWN helper set
# (`include_all_helpers = false`), so neither of these can live in one of this plugin's
# helpers — `TemplatesHelper` delegates to both instead. `reporter_report_templates` used to
# be required here for the same reason and is gone with the base-plugin widget it guarded.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/degradation_text'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/row_layout'

# The render layer (T-10). Loaded here rather than autoloaded because a plugin's lib/
# is not on Redmine's autoload paths, and required at boot rather than lazily so a
# syntax or load error surfaces on the branch that broke it instead of on the first
# render. Nothing calls it yet — T-11 onward do.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/capabilities'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/page_furniture'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/failure'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/result'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/document_request'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/registry'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/renderer'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/readiness'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/process_pool'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/engine_catalogue'
# The diagnostic (T-14). Required at boot for the same reason as the rest: the admin
# controller and the rake task both reach it, and a load error should surface on the
# branch that broke it rather than the first time an administrator asks whether their
# render path works.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/minimal_pdf'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/pdf_inspector'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/preflight'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/preflight_suite'
# FR-50 — the install-wide engine choice. Required at boot with the rest of render/ for
# the same reason: a LoadError has to surface on the branch that broke it rather than on
# the first settings page an administrator opens.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/engine_preference'
# The adapters. Requiring them REGISTERS them; it does not start a browser or run a
# binary, so a host without either boots exactly as before and finds out at preflight.
#
# EVERY ADAPTER IS REQUIRED HERE, and T-34 is why the list must not have a hole in it.
# `:gotenberg` was added to the tree and left off this list, so it registered NOWHERE at
# boot — and two other places load that directory by SCANNING it: the `preflight` rake
# task and `spec/conformance`. Two consequences, and both were measured rather than
# reasoned about.
#
# In production, a template asking for `engine_hint: gotenberg` in a web request would
# have raised `Registry::UnknownEngine` — the engine ships, is documented, and is
# unreachable by the one mechanism that selects it.
#
# In the suite it was worse than a missing feature, because it made an UNRELATED test
# fail: `test_it_exits_2_when_no_engine_is_registered` wraps the rake task in
# `Registry.isolated`, the task's directory scan then `require`d gotenberg.rb FOR THE
# FIRST TIME inside that block, and an engine appeared inside the one test whose subject
# is that none is registered. `require` is idempotent, so the two adapters listed here
# were no-ops there and only the unlisted one misbehaved. 47 failures and 66 errors, none
# of them in the adapter.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/engines/chromium_cdp'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/engines/gotenberg'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/engines/wkhtmltopdf'
# The asset layer (T-33) and the seam that binds it to the render layer. It sits UPSTREAM
# of render/ — see `assets.rb` for why it cannot live inside it (F-13b) — and like the
# render layer, nothing calls it yet: T-23 onward build the producer that does.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/assets'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/render/asset_binding'

# T-23 — the composition root, required at boot for the same reason `render/` is: a
# LoadError has to surface on the branch that broke it rather than on the first request
# that happens to reach a controller. Zeitwerk would resolve these lazily (Redmine puts a
# plugin's lib on the main loader), and lazily is precisely when nobody is watching.
# T-25 — the scheduler's date arithmetic. Required at boot because `Schedule` re-exports
# its repeat vocabulary at class-definition time, and a model that loaded before it would
# raise on a NameError that reads as a missing constant rather than a missing require.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/scheduling/occurrences'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/scheduling/runner'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/diagnostic'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/exchange'
# T-29 — the exchange BUNDLE and the streamed archive. `bundle` is required at boot
# because `TemplatesController#export` writes one on an ordinary request; `bundle_import`
# and `bundle_report` deliberately are NOT, because only the rake tasks use them and they
# reach the autoloaded Template model (see the note in `bundle_import.rb`).
#
# `archive/zip_stream` names NEITHER the Liquid layer nor the render layer, which is why
# it is a sibling of `render/` rather than inside it — §Findings E-6 says a zip built in
# `render/` is the layer violation `layer_purity.sh` exists to catch, and the gate has an
# arm for this directory saying the same thing mechanically.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/archive/zip_stream'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/bundle'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/report_scope'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/time_entry_visibility'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/report_run'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/failure_document'
# T-26a — the owned report widget, required AFTER the reporting layer it composes
# (ReportScope, ReportRun) rather than with the other top-level modules, because it names
# them at load time through this file's own ordering rather than through require_relative.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/widget_report'
# T-32 — the ad-hoc mail policy and its delivery. `mail_policy` is required first because
# `adhoc_delivery` reads it at load time through `require_relative`; listing both here keeps
# the boot order explicit rather than depending on which file happens to be loaded first.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/mail_policy'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/adhoc_delivery'
# T-25's delivery. It is required AFTER report_run and the scheduler because it names both,
# and it lives in reporting/ rather than scheduling/ so that `layer_purity`'s scheduling arm
# — which forbids that directory from naming Render or Liquid — stays true and enforced.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/scheduled_delivery'
# T-28 — the snapshot store, which is the write path `reporter_dashboards_documents` has
# lacked since T-22 created it. Required after `report_run` and `report_scope` because it
# names both, and before the controllers, which name it.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/reporting/snapshot'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/project_page'

module RedmineReporterDashboards
  # Patches that include/prepend into Redmine core (Project, ProjectsHelper).
  # Loaded from after_plugins_loaded so the target classes are present.
  PATCH_FILES = %w[
    redmine_reporter_dashboards/patches/project_patch
    redmine_reporter_dashboards/patches/role_patch
  ].freeze

  # Patches that touch redmine_reporter's own classes. Split out from PATCH_FILES
  # because they are loaded only when reporter is actually installed: loading
  # report_patch standalone would warn on every boot about a Report class that is
  # not missing so much as irrelevant.
  REPORTER_PATCH_FILES = %w[
    redmine_reporter_dashboards/patches/report_patch
  ].freeze

  # Glue that is not a patch: code loaded only because reporter is installed, which
  # something else then uses. Loaded with the reporter patches and for the same
  # reason, but listed separately because it prepends into nothing.
  #
  # `glue/legacy/scope_resolution` is here rather than left to
  # `reporter_list_patch`'s own require: `Liquid::ScopeBinding` falls back to it when
  # no RenderContext is present, so on a reporter install it has to be loaded whether
  # or not the prepend into IssueListReportTemplate succeeded. Tying it to that would
  # mean one failed patch silently costing a reporter install its scope resolution.
  REPORTER_GLUE_FILES = %w[
    redmine_reporter_dashboards/glue/legacy/scope_resolution
    redmine_reporter_dashboards/glue/legacy/wk_legacy_shims
  ].freeze

  # The plugin id, spelled once. `Setting.plugin_<id>` and the settings partial both need
  # it, and two spellings of one identifier is how a settings read silently answers `{}`.
  PLUGIN_ID = :redmine_reporter_dashboards

  module_function

  def lib_root
    File.dirname(__FILE__)
  end

  # --- The Redmine-facing half of the asset layer (T-33) ---
  #
  # `Assets::Policy` and `Assets::Origin` are pure value objects that read no settings
  # and know nothing about Redmine (mechanism E5: config arrives as a port). These two
  # methods are the ONLY place the two Redmine reads happen, and they are here rather
  # than in `assets/` for that reason.
  #
  # NOT MEMOISED, deliberately. `Setting` is already cached by Redmine, and a memo here
  # would hold a stale asset policy for the lifetime of the process — so an administrator
  # who turns egress OFF would keep the old policy until a restart, which is the wrong
  # direction for a security setting to be slow in.
  def asset_policy(logger: nil)
    Assets::Policy.from_settings(plugin_settings, logger: logger || safe_logger)
  end

  # --- FR-50: which engine this installation renders with -----------------------------
  #
  # The ONE Redmine read for the engine choice, here rather than in `render/` for exactly the
  # reason `asset_policy` is here: `EnginePreference` takes a Hash and must not know that a
  # `Setting` table exists (mechanism E5, and `layer_purity.sh` enforces it for `render/**`).
  #
  # NOT MEMOISED, deliberately and for the same reason as `asset_policy`: `Setting` is already
  # cached by Redmine, and a memo here would keep rendering through the old engine until a
  # restart — so an administrator who switches away from a container they are about to shut
  # down would keep POSTing to it.
  def render_engine_preference(logger: nil)
    Render::EnginePreference.from_settings(plugin_settings, logger: logger || safe_logger)
  end

  # The id alone, which is what the render path and the preflight surfaces want. Nil means
  # "this installation has selected nothing", which is a different answer from "it selected
  # something unusable" — that one is nil AND a `dropped` entry on the object above.
  def render_engine_id(logger: nil)
    render_engine_preference(logger: logger).selected_id
  end

  # `Setting.protocol` + `Setting.host_name` — Redmine's own answer to "what is our base
  # URL" wherever there is no request to ask, which is every scheduled or queued render.
  # `Liquid::Drops::AbsoluteUrl` wraps the same pair for the drop layer; this parses it,
  # because the asset layer has to COMPARE hosts rather than concatenate them (F-15).
  def asset_origin
    Assets::Origin.from_settings(::Setting.protocol, ::Setting.host_name)
  rescue StandardError => e
    # An unconfigured or half-booted install. The fail-closed answer is an origin that
    # matches nothing, which makes every absolute URL third-party — refused under the
    # default policy rather than fetched by accident.
    safe_logger&.warn("[reporter_dashboards] asset origin unavailable (#{e.class}); " \
                      'no URL will be treated as same-origin')
    Assets::Origin.new
  end

  # The store a production resolver reads from. `mappers` is the port through which the
  # caller supplies anything Redmine owns — an attachment's `diskfile`, which needs a
  # visibility decision this layer must not make (INV-1).
  def asset_store(mappers: [])
    Assets::LocalStore.new(roots: Assets::BundledAssets.roots, mappers: mappers)
  end

  # THE PRODUCTION RESOLVER (F-16). Four collaborators, three of which are the two reads
  # above plus the plugin's own asset root — and the fourth is the one object in this
  # plugin that holds the network.
  #
  # --- WHY IT IS ASSEMBLED HERE AND NOT IN `reporting/` ---
  #
  # `Assets::Fetcher` is the plugin's only egress. `script/gates/layer_purity.sh`'s
  # `reporting` arm exists to stop the composition root becoming "a second place that
  # knows about HTTP", and while constructing a fetcher would pass the gate's literal
  # patterns, it would defeat the sentence the gate was written to enforce. So the one
  # place that already owns the Redmine-facing half of the asset layer owns this too, and
  # `ReportRun` names a factory rather than a transport.
  #
  # --- THE FETCHER IS NOT BUILT UNLESS THE POLICY COULD USE ONE ---
  #
  # Not an optimisation, and not belt-and-braces either — it is the fail-closed direction
  # made structural. Under the default `:bundled` mode no classification may fetch, so the
  # object that opens sockets is never CONSTRUCTED, and `Resolver#fetched` then refuses
  # with "would need a fetch and no fetcher was supplied" if anything ever reached it.
  # Two independent reasons for the same refusal, which is what INV-8 is worth.
  #
  # The question is asked through `Policy#may_fetch?` over the two classifications that
  # can reach the network at all, rather than through `bundled?`: they agree today, and
  # `may_fetch?` is the policy's own vocabulary, so a fourth mode added later cannot
  # silently acquire a fetcher by not being `:bundled`. Note it reads `effective_mode`,
  # so an `:external` policy whose allowlist is empty — the collapse T-33 calls the
  # fail-closed clause most likely to be got wrong — gets no fetcher either.
  def asset_resolver(engine_capabilities:, mappers: [], logger: nil)
    log = logger || safe_logger
    policy = asset_policy(logger: log)

    Assets::Resolver.new(
      policy: policy,
      local_store: asset_store(mappers: mappers),
      engine_capabilities: engine_capabilities,
      fetcher: (Assets::Fetcher.new(policy: policy, logger: log) if asset_fetch_possible?(policy)),
      origin: asset_origin,
      logger: log
    )
  end

  # PUBLIC because it is the predicate the settings page will want to state, and because a
  # private method reached with `send` from a spec is the "resolve a name past its
  # visibility" shape §3.6 deletes `call_method` for.
  def asset_fetch_possible?(policy)
    policy.may_fetch?(:same_origin) || policy.may_fetch?(:third_party)
  end

  def plugin_settings
    ::Setting.send(:"plugin_#{PLUGIN_ID}") || {}
  rescue StandardError
    {}
  end

  def safe_logger
    defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
  end

  # T-40. Asked at after_plugins_loaded, which is the first moment the answer is complete,
  # and for the same reason `reporter_present?` is asked there.
  #
  # `technical-spec.md` §7 makes simultaneous installation of both plugins a DESIGN GOAL —
  # it is the whole A/B argument — and `Redmine::AccessControl` keeps permissions in a flat
  # array with no uniqueness check. Two plugins registering one name give an administrator
  # two identical rows on the roles screen and an action map that is the union of both,
  # which is a real authorization bug wearing a cosmetic disguise.
  #
  # Logged at ERROR and not raised: refusing to boot over another plugin's registration
  # would take the dashboards down for a problem the operator cannot fix from here. Loud,
  # not silent, and not fatal (INV-4).
  #
  # The message itself is built by `Permissions.collision_message`, which is where its tests
  # are; this is the wiring. `Array()` guards the case where `AccessControl.permissions`
  # answers `nil` — it returns a bare `@permissions`, unset until something registers — so a
  # half-initialised registry reads as "no collision" instead of raising inside a boot hook.
  #
  # `safe_logger` is DELIBERATELY NOT used with `&.` here. Its whole purpose is to tolerate a
  # missing `Rails.logger`, and a `&.` on both branches would have made a real collision and
  # a failed check equally silent in that case — which is `rescue nil` wearing a safer name
  # (INV-4). With no logger the message goes to stderr, where an operator can still see it.
  def check_permission_collisions
    message = Permissions.collision_message(
      Array(::Redmine::AccessControl.permissions).map(&:name)
    )
    return if message.nil?

    log_or_warn(:error, message)
  rescue StandardError => e
    # A diagnostic must never be the reason a boot step fails. Same discipline as the tag
    # registrations below: its own rescue, and it says what it could not check.
    log_or_warn(:warn, '[reporter_dashboards] permission collision check skipped ' \
                       "(#{e.class}: #{e.message})")
  end

  def log_or_warn(level, message)
    logger = safe_logger
    logger ? logger.public_send(level, message) : warn(message)
  end

  # Whether the optional redmine_reporter plugin is installed. One memo, owned by
  # ReporterPresence; see that file for why detection is a positive question asked
  # once at after_plugins_loaded rather than a rescued NameError.
  def reporter_present?
    ReporterPresence.present?
  end

  # ONE memoised answer about the optional dependency now.
  #
  # This used to clear two, because `ReporterReportTemplates` cached whether the base
  # plugin's report-template classes RESOLVE — the question the my-page widget had to ask
  # before naming one. T-26a increment 3 made that widget this plugin's own, so nothing
  # asks it, and the module went rather than being left memoising an answer with no reader.
  def reset_reporter_presence!
    ReporterPresence.reset!
  end

  def load_patches
    files = PATCH_FILES + (reporter_present? ? REPORTER_GLUE_FILES + REPORTER_PATCH_FILES : [])
    files.each { |file| require File.join(lib_root, file) }
  rescue LoadError, StandardError => e
    # A patch failing to load must never abort the after_plugins_loaded chain
    # (which would take the Liquid tag registration down with it).
    Rails.logger.warn("[reporter_dashboards] load_patches failed: #{e.message}")
  end

  # Primary Liquid tag name; the legacy name is kept as a backward-compatible
  # alias so report templates written against the old plugin keep working.
  TAG_NAME = 'sql_aggregate'
  TAG_ALIAS = 'geo_aggregate'

  # Register the sql_aggregate Liquid tag (and its geo_aggregate alias).
  # QueryAggregator is required unconditionally because SqlStatsController
  # depends on it; the tag itself is only registered when Liquid is available
  # (it always is under Redmine, but we stay defensive so a missing dependency
  # degrades gracefully).
  def register_sql_aggregate_tag
    require File.join(lib_root, 'redmine_reporter_dashboards/aggregation')

    # NOTE: use the top-level ::Liquid explicitly. This plugin also defines a
    # RedmineReporterDashboards::Liquid namespace (the owned drop layer), which
    # would otherwise shadow a bare `Liquid` constant here and make this
    # guard/register silently target the wrong (nonexistent) constant.
    return unless defined?(::Liquid::Tag)

    require File.join(lib_root, 'sql_aggregation/liquid_aggregate_tag')
    ::Liquid::Template.register_tag(TAG_NAME, SqlAggregation::LiquidAggregateTag)
    ::Liquid::Template.register_tag(TAG_ALIAS, SqlAggregation::LiquidAggregateTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] sql_aggregate tag registration failed: #{e.message}")
  end

  # Liquid tag that aggregates a report's issues per target version entirely in
  # SQL, so version dashboards avoid an O(versions x issues) Liquid loop.
  VERSION_ROLLUP_TAG_NAME = 'version_rollup'

  # Register the version_rollup Liquid tag. Mirrors register_sql_aggregate_tag:
  # only registers when Liquid is available and degrades gracefully otherwise.
  def register_version_rollup_tag
    require File.join(lib_root, 'redmine_reporter_dashboards/aggregation')

    return unless defined?(::Liquid::Tag)

    require File.join(lib_root, 'sql_aggregation/liquid_version_rollup_tag')
    ::Liquid::Template.register_tag(VERSION_ROLLUP_TAG_NAME, SqlAggregation::LiquidVersionRollupTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] version_rollup tag registration failed: #{e.message}")
  end

  # DEPRECATED (T-20). The tag NAME is registered for one more minor version so
  # templates in somebody else's database do not become parse errors overnight; the
  # owned drop layer's `issue.version` replaces what it did. See
  # VersionMapping::LiquidVersionMapTag for the removal condition.
  VERSION_MAP_TAG_NAME = 'geo_version_map'

  # Register the geo_version_map Liquid tag. Mirrors register_sql_aggregate_tag:
  # only registers when Liquid is available and degrades gracefully otherwise.
  def register_geo_version_map_tag
    return unless defined?(::Liquid::Tag)

    require File.join(lib_root, 'version_mapping/liquid_version_map_tag')
    ::Liquid::Template.register_tag(VERSION_MAP_TAG_NAME, VersionMapping::LiquidVersionMapTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] geo_version_map tag registration failed: #{e.message}")
  end

  # `{% chart %}` (T-16). One authoring act; the output binding decides whether it
  # becomes a `<canvas>` or an inline `<svg>`. The tag emits NO markup — see
  # `Liquid::Tags::ChartTag` for why that is the whole design rather than a detail.
  CHART_TAG_NAME = 'chart'
  MERMAID_TAG_NAME = 'mermaid'

  def register_chart_tag
    return unless defined?(::Liquid::Tag)

    require File.join(lib_root, 'redmine_reporter_dashboards/liquid/tags/chart_tag')
    ::Liquid::Template.register_tag(CHART_TAG_NAME,
                                    RedmineReporterDashboards::Liquid::Tags::ChartTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] chart tag registration failed: #{e.message}")
  end

  # T-35. A BLOCK tag, so registration is the same call — Liquid does not distinguish.
  def register_mermaid_tag
    return unless defined?(::Liquid::Tag)

    require File.join(lib_root, 'redmine_reporter_dashboards/liquid/tags/mermaid_tag')
    ::Liquid::Template.register_tag(MERMAID_TAG_NAME,
                                    RedmineReporterDashboards::Liquid::Tags::MermaidTag)
  rescue => e
    Rails.logger.warn("[reporter_dashboards] mermaid tag registration failed: #{e.message}")
  end

  # RETIRED IN T-20: `register_issue_target_version_drop`.
  #
  # It prepended a module into `RedmineReporter::Liquid::Drops::IssueDrop` to add
  # `issue.target_version` and `issue.custom_field_value[…]` to the HOST plugin's drop.
  # Both accessors now live on this plugin's own `Drops::IssueDrop` — `target_version`
  # as an alias of `version`, `custom_field_value` as `CustomFieldValuesDrop` — so the
  # template vocabulary is unchanged and the monkey-patch into another plugin's class
  # is gone. That patch was two of the entries in `zero_reporter.allowlist`; both went
  # with it.
  #
  # There is a WINDOW, and it is stated rather than hidden: until the owned renderer
  # constructs these drops (T-23), a report rendered by the host plugin gets the gem's
  # drop, which has neither accessor. `spec/liquid/retired_surface_spec.rb` pins the
  # deletion; `implementation-plan.md` §Findings F-11 records the window.

  # Apply the performance patches to reporter's classes. Only called when
  # reporter_present? is true, so absence is not a case handled here.
  def apply_reporter_patches
    apply_patch('IssueListReportTemplate',
                'redmine_reporter_dashboards/glue/legacy/reporter_list_patch',
                'RedmineReporterDashboards::Glue::Legacy::ReporterListPatch')
    apply_patch('ReportTemplatesController', 'reporter_report_content_patch', 'ReporterReportContentPatch')
  end

  def apply_patch(class_name, require_path, module_name)
    # Asked, not inferred from a rescued NameError. const_defined? sees a constant
    # Zeitwerk has registered for autoload without forcing it; the const_get below
    # then triggers the load, in development as before.
    unless Object.const_defined?(class_name)
      Rails.logger.info("[reporter_dashboards] #{class_name} is not defined — #{module_name} not applied")
      return false
    end

    klass = Object.const_get(class_name)
    require File.join(lib_root, require_path)
    patch = Object.const_get(module_name)
    klass.prepend(patch) unless klass.ancestors.include?(patch)
    Rails.logger.info("[reporter_dashboards] #{module_name} applied to #{class_name}")
    true
  rescue LoadError, StandardError => e
    # Warn, never swallow. Past this point the constant existed, so a failure is a
    # defect in loading it — not the absence of an optional plugin.
    Rails.logger.warn("[reporter_dashboards] #{class_name} patch failed: #{e.class}: #{e.message}")
    false
  end
end
