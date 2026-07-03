# frozen_string_literal: true

module VersionMapping
  # Liquid tag: {% geo_version_map ... %}
  #
  # Builds a lookup from version NAME to its id and metadata and assigns it to a
  # Liquid variable, so report templates can construct version-filtered URLs
  # (roadmap, issues list, time entries). The Reporter issue drop only exposes
  # issue.version as a scalar (name only), with no id — this tag closes that gap.
  #
  # Usage (all versions):
  #   {% geo_version_map assign_to: geo_versions %}
  #
  # Usage (single project's shared versions):
  #   {% geo_version_map project: my-project, assign_to: geo_versions %}
  #
  # Then, per issue in a template:
  #   {% assign v = geo_versions[issue.version] %}
  #   Roadmap: /projects/{{ v.project }}/roadmap
  #   Issues:  /projects/{{ v.project }}/issues?fixed_version_id={{ v.id }}
  #
  # Markup params:
  #   project    — optional project identifier LITERAL. When given, the map is
  #                built from that project's shared_versions; otherwise from
  #                every version (Version.all). Resolved via
  #                Project.find_by(identifier:) then Project.find_by(id:).
  #   assign_to  — name of the Liquid variable that holds the map
  #                (default: geo_versions)
  #
  # Result: a Ruby Hash keyed by version NAME. Each value is a Hash with STRING
  # keys so Liquid dot-access works:
  #   'id'             — version id (integer)
  #   'effective_date' — Date or nil
  #   'status'         — 'open' | 'locked' | 'closed'
  #   'project'        — identifier of the project the version belongs to
  #
  # On any error the tag assigns an empty Hash and logs to Rails.logger so the
  # rest of the template renders without crashing. render returns an empty
  # string (side-effect tag).

  class LiquidVersionMapTag < Liquid::Tag
    # Matches: key: "quoted" | key: 'quoted' | key: bare_value
    PARAM_RE = /(\w+)\s*:\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))/

    def initialize(tag_name, markup, tokens)
      super
      @raw_params = parse_markup(markup)
    end

    def render(context)
      # Resolve assign_to first so the rescue block always has the correct name.
      assign_to = str_param(@raw_params['assign_to'], context, default: 'geo_versions')

      map = {}
      resolve_versions.each do |version|
        map[version.name] = {
          'id'             => version.id,
          'effective_date' => version.effective_date,
          'status'         => version.status,
          'project'        => version.project&.identifier
        }
      end

      context.scopes.last[assign_to] = map
      ''
    rescue => e
      Rails.logger.error("[geo_version_map] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      context.scopes.last[assign_to] = {}
      ''
    end

    private

    # ------------------------------------------------------------------
    # Version scope resolution
    # ------------------------------------------------------------------

    # When project: is given, use that project's shared_versions; otherwise use
    # every version. Eager-load :project so the per-version identifier lookup
    # does not trigger an N+1 (Version.all does not preload; shared_versions
    # already does, where the extra includes is a harmless no-op).
    #
    # A project: that is given but does not resolve yields an empty scope rather
    # than silently widening to every version — the template asked to narrow to
    # one project, so returning unrelated projects' versions would be wrong.
    def resolve_versions
      scope =
        if @raw_params.key?('project')
          project = resolve_project
          if project.nil?
            Rails.logger.warn("[geo_version_map] project '#{@raw_params['project']}' not found — assigning empty map")
            return []
          end
          project.shared_versions
        else
          Version.all
        end

      scope.respond_to?(:includes) ? scope.includes(:project) : scope
    end

    # project: is a LITERAL identifier (not a Liquid variable), matching the tag
    # contract. Try identifier first, then fall back to a numeric id.
    def resolve_project
      identifier = @raw_params['project']
      return nil if identifier.nil? || identifier.empty?

      Project.find_by(identifier: identifier) || Project.find_by(id: identifier)
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
  end
end
