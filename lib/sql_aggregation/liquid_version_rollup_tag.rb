# frozen_string_literal: true

require_relative 'scope_resolution'
require_relative '../redmine_reporter_dashboards/liquid/version_drop'

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
  #     <a href="{{ v.version.url }}">roadmap</a>          {# v.version is a VersionDrop, nil for 'None' #}
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
  #   name, version (VersionDrop or nil), version_id, total, open, closed,
  #   open_done_sum, overdue_open, unassigned_open, no_estimate, est_hours,
  #   spent_hours, start_date (Date/nil), due_date (Date/nil), cost ({id=>Float}).
  # Rows are sorted by version name (case-insensitive) for deterministic output.
  #
  # On any error the tag assigns an empty Array and logs to Rails.logger so the
  # rest of the template still renders. render returns '' (side-effect tag).
  class LiquidVersionRollupTag < Liquid::Tag
    include SqlAggregation::ScopeResolution

    # Matches: key: "quoted" | key: 'quoted' | key: bare_value
    PARAM_RE = /(\w+)\s*:\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))/

    def initialize(tag_name, markup, tokens)
      super
      @raw_params = parse_markup(markup)
    end

    def render(context)
      assign_to = str_param(@raw_params['assign_to'], context, default: 'versions')
      t0        = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      scope     = resolve_scope(context)

      if scope.nil?
        Rails.logger.warn('[version_rollup] could not resolve an AR scope — assigning empty list')
        context.scopes.last[assign_to] = []
        return ''
      end

      statuses = str_param(@raw_params['closed_statuses'], context).split(/[;,]/).map(&:strip).reject(&:empty?)
      cost_ids = str_param(@raw_params['cost_fields'], context).split(/[;,]/).map(&:to_i).reject(&:zero?)

      rows = SqlAggregation::QueryAggregator.version_rollup(
        scope, closed_statuses: statuses, cost_field_ids: cost_ids
      )
      rows = decorate_with_versions(rows)

      Rails.logger.info("[version_rollup] #{rows.size} versions aggregated in #{elapsed_ms(t0)}ms")
      context.scopes.last[assign_to] = rows
      ''
    rescue => e
      Rails.logger.error("[version_rollup] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      context.scopes.last[assign_to] = []
      ''
    end

    private

    # Attach the version NAME and a VersionDrop (absolute URLs, PDF-safe) to each
    # row via one batched query (no N+1). A nil version_id (issues without a target
    # version) becomes name 'None' with a nil drop.
    def decorate_with_versions(rows)
      ids      = rows.map { |r| r['version_id'] }.compact.uniq
      versions = ids.any? ? Version.where(id: ids).includes(:project).index_by(&:id) : {}

      rows.each do |row|
        version        = versions[row['version_id']]
        row['name']    = version ? version.name : 'None'
        row['version'] = version ? RedmineReporterDashboards::Liquid::VersionDrop.new(version) : nil
      end

      rows.sort_by { |r| r['name'].to_s.downcase }
    end

    # ------------------------------------------------------------------
    # Parameter helpers (mirrors SqlAggregation::LiquidAggregateTag)
    # ------------------------------------------------------------------

    def parse_markup(markup)
      params = {}
      markup.to_s.scan(PARAM_RE) do |key, dq, sq, bare|
        params[key.strip] = dq || sq || bare || ''
      end
      params
    end

    def str_param(value, context, default: '')
      return default if value.nil? || value.empty?

      resolved = context[value]
      resolved.nil? ? value : resolved.to_s
    end

    def elapsed_ms(t0)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
    end
  end
end
