# frozen_string_literal: true

require_relative '../redmine_reporter_dashboards/liquid/execution_policy'
require_relative '../redmine_reporter_dashboards/liquid/scope_binding'
require_relative '../redmine_reporter_dashboards/liquid/render_context'
require_relative '../redmine_reporter_dashboards/liquid/tag_params'
require_relative '../redmine_reporter_dashboards/liquid/drops'

module SqlAggregation
  # Liquid tag: {% version_rollup ... %}
  #
  # Aggregates the issues of a report PER TARGET VERSION entirely in SQL and
  # assigns a ready-to-render Array to a Liquid variable, so a report template no
  # longer needs an O(versions x issues) Liquid loop (see version dashboards).
  #
  # Usage:
  #   {% version_rollup from: issues, closed_statuses: "Closed;Rejected",
  #      cost_fields: "20,21", assign_to: versions %}
  #   {% for v in versions %}
  #     {{ v.name }} — {{ v.open }} open / {{ v.closed }} closed
  #     <a href="{{ v.version.url }}">roadmap</a>          {# v.version is a version drop, nil for 'None' #}
  #     est {{ v.est_hours }}h / spent {{ v.spent_hours }}h
  #     budget {{ v.cost['20'] }} / {{ v.cost['21'] }}
  #   {% endfor %}
  #
  # Params:
  #   from            — Liquid var holding the issues drop (default: issues)
  #   closed_statuses — semicolon/comma-separated status names (else is_closed flag)
  #   cost_fields     — semicolon/comma-separated numeric custom field ids to sum
  #   assign_to       — result variable name (default: versions)
  #
  # Each result row is a Hash with STRING keys (Liquid dot-access):
  #   name, version (Drops::VersionDrop or nil), version_id, total, open, closed,
  #   open_done_sum, overdue_open, unassigned_open, no_estimate, est_hours,
  #   spent_hours, start_date (Date/nil), due_date (Date/nil), cost ({id=>Float}).
  # Rows are sorted by version name (case-insensitive) for deterministic output.
  #
  # On any error the tag assigns an empty Array and logs to Rails.logger so the
  # rest of the template still renders. render returns '' (side-effect tag).
  class LiquidVersionRollupTag < Liquid::Tag
    # T-07: two resolution sources, both starting from Issue.visible. The six-source
    # archaeology this replaced lived in Glue::Legacy::ScopeResolution and was DELETED by
    # S-30 (2026-08-13). Since curator decision #1 (2026-08-14) a render arriving with no
    # RenderContext resolves NOTHING AT ALL — `query_id:` included — because renders by the
    # base plugin are withdrawn and there is no ambient actor left to resolve
    # one for. The tag assigns the empty list and logs.
    include RedmineReporterDashboards::Liquid::ScopeBinding

    # Markup parsing and the quoted-means-literal rule live in one place for all five
    # tags — see `RedmineReporterDashboards::Liquid::TagParams`.
    TagParams = RedmineReporterDashboards::Liquid::TagParams

    def initialize(tag_name, markup, tokens)
      super
      @raw_params = TagParams.parse(markup)
    end

    def render(context)
      # THE COOPERATIVE DEADLINE (T-17). One line, at the top of `render`, because a
      # resource limit bounds WORK UNITS and this tag's cost is TIME: a
      # sql_aggregate tag running a ninety-second query costs exactly one render-score
      # point, and no resource limit will ever notice it.
      #
      # STALE UNTIL S-30 CORRECTED IT: this used to say "a no-op today on every existing
      # install: these tags still run inside the host plugin's renderer". `TemplateRenderer`
      # has been the renderer for every report this plugin produces since T-23, and it
      # binds a budget. The sentence survives as a note on the OTHER case — a template
      # rendered by the host plugin binds no budget, and `Budget.from` answers a null
      # object rather than nil precisely so this call site is safe there. When
      # `TemplateRenderer` is the one rendering, this same
      # line is what stops a slow template.
      RedmineReporterDashboards::Liquid::Budget.from(context).check!('version_rollup')

      assign_to = str_param(@raw_params['assign_to'], context, default: 'versions')
      t0        = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      scope     = resolve_scope(context)

      if scope.nil?
        Rails.logger.warn('[version_rollup] could not resolve an AR scope — assigning empty list')
        context.scopes.last[assign_to] = []
        return ''
      end

      # THE SAME GUARD THE OTHER KERNEL ENTRY POINT HAS, and this one went without it for a
      # commit. `QueryAggregator.version_rollup` reads `issues.fixed_version_id` and
      # `issues.status_id`; over a time-entry relation the first binds by accident and the
      # second raises, which landed here as a log line and an empty version list with
      # nothing said to the author. See `ScopeBinding.issue_kernel_permitted?`.
      unless RedmineReporterDashboards::Liquid::ScopeBinding
             .issue_kernel_permitted?(context, 'version_rollup')
        context.scopes.last[assign_to] = []
        return ''
      end

      statuses = str_param(@raw_params['closed_statuses'], context).split(/[;,]/).map(&:strip).reject(&:empty?)
      cost_ids = str_param(@raw_params['cost_fields'], context).split(/[;,]/).map(&:to_i).reject(&:zero?)

      rows = SqlAggregation::QueryAggregator.version_rollup(
        scope, closed_statuses: statuses, cost_field_ids: cost_ids
      )
      rows = decorate_with_versions(rows, context)

      Rails.logger.info("[version_rollup] #{rows.size} versions aggregated in #{elapsed_ms(t0)}ms")
      context.scopes.last[assign_to] = rows
      ''
    rescue => e
      Rails.logger.error("[version_rollup] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      context.scopes.last[assign_to] = []
      ''
    end

    private

    # Attach the version NAME and a version drop (absolute URLs, PDF-safe) to each
    # row via one batched query (no N+1). A nil version_id (issues without a target
    # version) becomes name 'None' with a nil drop.
    #
    # T-20 swapped the drop CLASS, not the template surface. It used to be the addon's
    # own `RedmineReporterDashboards::Liquid::VersionDrop` — 108 lines that existed
    # because the vendor gem had no version object worth the name. It is now
    # `Drops::VersionDrop`, which answers every accessor the old one did (`url`,
    # `roadmap_url`, the three issue lists, `time_url`, `effective_date`, `status`,
    # `project_identifier`, `project_name`) plus `project` as a drop of its own, and
    # substitutes for a String on top. Nothing in a template has to change.
    #
    # ONE context for the whole decoration, resolved once. Building it per row would
    # mean one `Batch` per version, and the rows all belong to the same render.
    #
    # `RenderContext.from` DIRECTLY, since decision #1 deleted `TagContext` — and this call
    # site cannot see a nil: `resolve_scope` above returns nil for a context-less render and
    # `render` has already assigned `[]` and returned by then. It is not defended with a
    # `&.` for that reason; if the invariant ever breaks, `Drops::VersionDrop`'s constructor
    # refuses a nil context by name (INV-1) and the tag's own rescue turns it into an empty
    # list and an error line, rather than a version drop with no viewer behind it.
    #
    # A drop and not a Hash, deliberately: a drop is LAZY. `completed_percent` runs a
    # query, and a Hash would run it for every version whether or not the template ever
    # asks — turning a bounded render into one that pays per version for a field most
    # dashboards do not print.
    def decorate_with_versions(rows, context)
      ids      = rows.map { |r| r['version_id'] }.compact.uniq
      versions = ids.any? ? Version.where(id: ids).includes(:project).index_by(&:id) : {}
      drop_context = RedmineReporterDashboards::Liquid::RenderContext.from(context)

      rows.each do |row|
        version        = versions[row['version_id']]
        row['name']    = version ? version.name : 'None'
        row['version'] = version &&
                         RedmineReporterDashboards::Liquid::Drops::VersionDrop
                           .new(version, context: drop_context)
      end

      rows.sort_by { |r| r['name'].to_s.downcase }
    end

    # ------------------------------------------------------------------
    # Parameter helpers (mirrors SqlAggregation::LiquidAggregateTag)
    # ------------------------------------------------------------------

    # QUOTED MEANS LITERAL, BARE MEANS A VARIABLE — decided once, in `TagParams`.
    def str_param(value, context, default: '')
      TagParams.resolve(value, context, default: default)
    end

    def elapsed_ms(t0)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
    end
  end
end
