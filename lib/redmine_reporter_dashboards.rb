# frozen_string_literal: true

require File.dirname(__FILE__) + '/redmine_reporter_dashboards/compat'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/block_settings'
# Required BEFORE anything that could fail: `init.rb` reads it to declare the permissions,
# and a plugin whose permission set failed to load would boot with an authorize call that
# permits nobody — which looks exactly like a misconfigured role.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/permissions'
# The upgrade diagnostic, next to the permission model it reads. A `manage_report_templates`
# grant outlives the plugin that registered it, so this has to work with that plugin gone.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/permissions/authoring_audit'
# The project settings tab: which sections an actor may see, and the bounded counts the
# partial prints. Next to the permission model because it is one — the tab is registered
# under whichever of four permissions the actor holds.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/settings_tab'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/positioned'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/report_frame'
# Called from a my-page partial, which core renders through its OWN helper set
# (`include_all_helpers = false`), so neither can live in one of this plugin's helpers.
# `TemplatesHelper` delegates to both instead.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/degradation_text'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/row_layout'

# The render layer. Loaded here rather than autoloaded because a plugin's lib/ is not on
# Redmine's autoload paths, and at boot rather than lazily so a load error surfaces on the
# branch that broke it instead of on the first render.
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
# FR-27 — the install-wide engine choice. Required at boot with the rest of render/ for
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
# T-37 — the linter, required at boot because `TemplatesController` runs it on every
# editor request (FR-71's findings panel). It was only ever loaded by the two rake tasks
# before, through `require_relative` from `import/survey`, so a controller naming it would
# have depended on a task having run first.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/template_linter'
# T-37 / FR-72 — the drop reference, required at boot because the editor's sidebar renders it
# on every request. It reads the drop classes' own `invokable_methods`, so it must be loaded
# AFTER them; `liquid/drop_reference` requires `liquid/drops` itself rather than relying on
# this file's ordering, because a reference that loaded first would describe an empty surface.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/liquid/drop_reference'
# T-37 / FR-73 — the starter gallery's manifest. Required at boot because the New template
# page renders it and `#new` prefills from it; it reads files under `starters/` and names no
# model, so it is a plain lib module rather than anything in `reporting/`.
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/starter_gallery'
require File.dirname(__FILE__) + '/redmine_reporter_dashboards/project_page'

module RedmineReporterDashboards
  # Patches into Redmine core. The list is the list, and each entry's kind matters:
  #
  #   * Project, Role         — an association each, no method override
  #   * ProjectsHelper        — ONE method, `project_settings_tabs`, and the only overridden
  #                             core method in this plugin. NOT patched into ProjectsHelper:
  #                             the module goes into `ProjectsController._helpers` via
  #                             `ProjectsController.helper`, above the core helper, so
  #                             `super` reaches it and no `alias_method` on ProjectsHelper
  #                             can see us. Eight other plugins alias-chain that method;
  #                             read that file's header for what it costs to be inside it.
  #
  # Loaded from after_plugins_loaded so the target classes are present, and so the helper
  # module goes back into `_helpers` after each `to_prepare` throws the controllers away.
  PATCH_FILES = %w[
    redmine_reporter_dashboards/patches/project_patch
    redmine_reporter_dashboards/patches/role_patch
    redmine_reporter_dashboards/patches/projects_helper_patch
  ].freeze

  # THE REPORTER PDF PATCH IS GONE (T-26a, 2026-08-12), and `REPORTER_PATCH_FILES` with it.
  #
  # It improved the BASE PLUGIN'S own PDF output — a binary fallback plus ES5 polyfills for
  # its wkhtmltopdf call — and its only consumer was that plugin. Its only caller of
  # `Glue::Legacy::WkLegacyShims` was itself, so the shims went too: this plugin's OWN
  # wkhtmltopdf adapter needs none of them, because `{% chart %}` emits inline SVG on the
  # PDF binding and runs no JavaScript at all. That is condition (3) of the adapter's own
  # removal condition satisfied for the SHIMS, not for the adapter.
  #
  # AND `REPORTER_GLUE_FILES` IS GONE TOO (S-30, 2026-08-13), with `glue/` entirely.
  #
  # It held `glue/legacy/scope_resolution` — six ambient sources a tag could get a scope
  # from before T-07 — and `glue/legacy/reporter_list_patch`, which parked the host
  # plugin's `IssueQuery` in a thread-local because its `liquidize()` took no registers
  # argument to extend. The two were a producer/consumer pair and died together.
  #
  # The first attempt at this deletion was reverted on a measurement (166 of 249 DB-less
  # examples red) because the tag suite used that path as its HARNESS. It no longer does:
  # `spec/sql_aggregation` builds every context from an owned `RenderContext` and passes
  # identically with the module present or absent, which is what made the deletion a
  # deletion rather than a rewrite.
  #
  # `ScopeBinding#bind` now answers `NONE` where it used to fall back. Nothing in
  # production reaches that branch — every render has constructed a context from an
  # explicit actor since T-26a — and answering NONE is the INV-1 position anyway.
  #
  # AND `REPORTER_PATCH_FILES`' LAST DESCENDANT IS GONE TOO (curator decision #1,
  # 2026-08-14): `apply_reporter_patches`, the `apply_patch` helper it was the only caller
  # of, `lib/reporter_report_content_patch.rb`, and the `reporter_present?` /
  # `ReporterPresence` detection that gated the three. THIS MODULE NOW PATCHES NOTHING
  # OUTSIDE REDMINE CORE AND ASKS NOTHING ABOUT ANY OTHER PLUGIN. `PATCH_FILES` is the whole
  # of it, and it is unconditional.
  #
  # The patch that went was a performance fix on the HOST plugin's `report_content` action
  # (a lazy `base_scope` instead of a materialised Array of Issues). Keeping it would have
  # meant optimising the one render path this plugin had just stopped supporting, which
  # `DECISIONS-PENDING.md` names as the clearest signal that #1 needed an answer.

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

  # --- FR-27: which engine this installation renders with -----------------------------
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

  # T-40. Asked at after_plugins_loaded, which is the first moment the answer is complete —
  # the same reason the (now deleted) reporter detection was asked there.
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

  # THERE IS NO `reporter_present?` ANY MORE, and this paragraph is here so the next reader
  # does not go looking for it. It answered "is the optional base plugin
  # installed", memoised once at `after_plugins_loaded`, and by 2026-08-14 it had exactly one
  # consumer left: `apply_reporter_patches`. Curator decision #1 deleted that patch, so the
  # detection became a memo with no reader and went with it — along with
  # `reset_reporter_presence!` and `ReporterPresence` itself.
  #
  # DO NOT REINTRODUCE IT "FOR A DIAGNOSTIC". T-27 measured that question and the answer is
  # in `Permissions::AuthoringAudit`'s own header: a permission grant outlives the plugin
  # that registered it, so a diagnostic gated on the registry prints an empty list in exactly
  # the case it exists for. The audit reads Redmine's permission tables and asks the plugin
  # registry nothing, on purpose.

  # `PATCH_FILES` and nothing else, unconditionally. Both patches here are this plugin's own
  # (`project_patch`, `role_patch`), so what gets required depends on nothing external. It
  # used to append `REPORTER_GLUE_FILES` on a true `reporter_present?` (deleted by S-30) and
  # the detection itself is gone now too.
  def load_patches
    PATCH_FILES.each { |file| require File.join(lib_root, file) }
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

  # RETIRED BY CURATOR DECISION #1, 2026-08-14: `apply_reporter_patches` and `apply_patch`.
  #
  # `apply_reporter_patches` prepended ONE module into another plugin's class —
  # `ReporterReportContentPatch` into `ReportTemplatesController#report_content` — handing
  # the host plugin's own `generate_reports` a lazy `IssueQuery#base_scope` instead of a
  # materialised Array of Issues. `apply_patch` was the const_defined?-then-const_get helper
  # it was the only caller of, written so absence was ASKED about rather than inferred from a
  # rescued NameError.
  #
  # Both went with the render path they served. `DECISIONS-PENDING.md` §1 makes the argument
  # in one sentence: with host renders withdrawn, "we speed up a path we just stopped
  # supporting", which is incoherent whichever way the decision goes. It went by withdrawal.
  #
  # WHAT THAT COSTS AN INSTALL RUNNING BOTH PLUGINS, said plainly rather than left for
  # somebody to discover: that plugin's own reports still work, and its `report_content`
  # action goes back to materialising its Issue objects — its behaviour before this plugin
  # was ever installed. What does NOT work any more is one of ITS templates using
  # `{% sql_aggregate %}` / `{% version_rollup %}` / `{% geo_version_map %}`: those tags are
  # registered process-wide by Liquid and cannot be un-registered per renderer, so they still
  # PARSE there, and they now resolve nothing and log a warn line naming this decision. The
  # README says so in its section on the base plugin being optional. Fails closed, never a
  # leak.
  #
  # S-30 had already removed the OTHER patch (`Glue::Legacy::ReporterListPatch`, a
  # thread-local parking `IssueQuery` for a tag to find), so this leaves zero prepends into
  # any plugin but Redmine core.
end
