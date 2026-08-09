# frozen_string_literal: true

require_relative '../redmine_reporter_dashboards/liquid/execution_policy'
require_relative '../redmine_reporter_dashboards/liquid/tag_context'

module VersionMapping
  # DEPRECATED — `{% geo_version_map %}`, kept for ONE minor version (T-20).
  #
  # It existed because the vendor gem's `issue.version` was a bare NAME: a template
  # linking to a roadmap or a filtered issue list needed the version's id, date, status
  # and project identifier and could reach none of them, so this tag built a
  # `name -> {id, effective_date, status, project}` map and assigned it. The owned drop
  # layer (T-18) answers all four directly — `{{ issue.version.id }}`,
  # `.effective_date`, `.status`, `.project`, plus `.url`, `.roadmap_url`,
  # `.open_issues_url`, `.closed_issues_url` and `.time_url` — and `Drops::VersionDrop`
  # still substitutes for the string it replaced, so `{% if issue.version == "2026.1" %}`
  # keeps working. There is nothing left for a lookup table to add.
  #
  # --- WHY A SHIM AND NOT A DELETION ---
  #
  # Templates live in a database on somebody else's Redmine. Removing a registered tag
  # name turns every one of them into a Liquid parse error at the top of the document,
  # which is a broken report rather than a migrated one. So the NAME survives one minor
  # version, behaving exactly as it did, and says so once per process in the log.
  # `TemplateLinter`'s `deprecated.geo_version_map` rule is the other half: the log line
  # is for the operator, the finding is for the author. Removal condition: the minor
  # version after the one this notice first shipped in.
  #
  # The map's SHAPE is untouched — a Hash with the same four STRING keys, and
  # `'project'` still the project IDENTIFIER rather than a drop or a name. A shim that
  # quietly changes its own contract is worse than a deletion, because the failure is
  # silent and lands in the middle of a report.
  class LiquidVersionMapTag < ::Liquid::Tag
    # Matches: key: "quoted" | key: 'quoted' | key: bare_value
    PARAM_RE = /(\w+)\s*:\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))/

    DEPRECATION_MESSAGE =
      '[geo_version_map] this tag is DEPRECATED and will be removed in the next minor ' \
      'version. The owned drop layer answers the same four facts directly — ' \
      'issue.version.id / .effective_date / .status / .project — and adds the roadmap, ' \
      'issue-list and time-entry URLs. Run `rake reporter_dashboards:migrate_from_reporter:plan` to ' \
      'list the templates that still use it.'

    # ONCE PER PROCESS, and once means once even with two threads in the tag at the
    # same instant. A Puma worker renders concurrently, and a deprecation that prints
    # per render is a deprecation an operator filters out of their log within a day.
    DEPRECATION_LOCK = Mutex.new

    class << self
      # Test seam, and named so it reads as one. Nothing in the plugin calls it.
      def reset_deprecation_notice!
        DEPRECATION_LOCK.synchronize { @deprecation_logged = false }
      end

      def deprecation_notice_logged?
        DEPRECATION_LOCK.synchronize { @deprecation_logged ? true : false }
      end

      def notice_deprecation
        already = DEPRECATION_LOCK.synchronize do
          was = @deprecation_logged
          @deprecation_logged = true
          was
        end
        return if already
        return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

        ::Rails.logger.warn(DEPRECATION_MESSAGE)
      end
    end

    def initialize(tag_name, markup, tokens)
      super
      @raw_params = parse_markup(markup)
    end

    def render(context)
      # The cooperative deadline (T-17). One line at the top of `render`, because a
      # resource limit bounds WORK UNITS and this tag's cost is TIME.
      RedmineReporterDashboards::Liquid::Budget.from(context).check!('version_map')

      # Resolve assign_to FIRST so the rescue block always has the correct name — and
      # note the ordering against the notice below, which is not cosmetic. Emitting the
      # deprecation first meant a raising logger reached the rescue with `assign_to`
      # still nil, and the rescue then wrote its empty map under the key `nil`: the
      # template's own variable stayed undefined and the tag reported success. Caught by
      # the "still assigns the map when the notice cannot be logged" example.
      assign_to = str_param(@raw_params['assign_to'], context, default: 'geo_versions')
      self.class.notice_deprecation

      map = {}
      resolve_versions(context).each do |version|
        map[version.name] = {
          'id' => version.id,
          'effective_date' => version.effective_date,
          'status' => version.status,
          'project' => version.project&.identifier
        }
      end

      context.scopes.last[assign_to] = map
      ''
    rescue StandardError => e
      Rails.logger.error("[geo_version_map] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      context.scopes.last[assign_to] = {}
      ''
    end

    private

    # THE ACTOR IS ASKED FOR, NOT ASSUMED (INV-1). `TagContext` is the one place that
    # decision is made — the owned renderer's actor when there is one, the ambient one
    # when a host-plugin render produced this. Delegated rather than repeated: a second
    # copy of "who is this render for" is a second place for the answer to drift, and
    # this tag and `{% version_rollup %}` must not disagree about it inside one document.
    def actor(context)
      RedmineReporterDashboards::Liquid::TagContext.actor(context)
    end

    # `project:` narrows to that project's shared versions; otherwise every version the
    # actor may see. `Version.visible`, never `Version.all` — the map carries version
    # names, dates and project identifiers, and a report template must not become a way
    # to read them out of projects the viewer cannot see (one of the five 0.5.0 leaks).
    # A `project:` that is given but does not resolve yields an EMPTY scope rather than
    # silently widening: the template asked to narrow to one project. `includes(:project)`
    # because the per-version identifier lookup is otherwise an N+1.
    def resolve_versions(context)
      viewer = actor(context)
      scope =
        if @raw_params.key?('project')
          project = resolve_project(viewer)
          if project.nil?
            Rails.logger.warn("[geo_version_map] project '#{@raw_params['project']}' not found or not " \
                              'visible to this actor — assigning empty map')
            return []
          end
          only_visible(project.shared_versions, viewer)
        else
          Version.visible(viewer)
        end

      scope.respond_to?(:includes) ? scope.includes(:project) : scope
    end

    # shared_versions reaches into other projects that share their versions, so it is
    # narrowed too. Guarded: older Redmine hands back a plain Array here.
    def only_visible(versions, viewer)
      return versions unless versions.respond_to?(:visible)

      versions.visible(viewer)
    end

    # `project:` is a LITERAL identifier, matching the tag's contract. Identifier first,
    # then a numeric id. Both go through `Project.visible`, so an unknown project and an
    # invisible one are indistinguishable from the template's point of view.
    def resolve_project(viewer)
      identifier = @raw_params['project']
      return nil if identifier.nil? || identifier.empty?

      visible = Project.visible(viewer)
      visible.find_by(identifier: identifier) || visible.find_by(id: identifier)
    end

    # Parameter helpers — mirrors SqlAggregation::LiquidAggregateTag.
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
