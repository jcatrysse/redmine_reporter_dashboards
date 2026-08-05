# frozen_string_literal: true

module RedmineReporterDashboards
  # Everything that exists only because `redmine_reporter` is installed. Loaded on no
  # other path, and deleted at 1.0 (technical-spec.md §1.1).
  module Glue
    # MOVED HERE BY T-07, otherwise unchanged.
    #
    # Its behaviour is frozen by the 46-triple oracle in
    # test/unit/golden_scope_fixture_test.rb, and `spec/golden/scope/scope.jsonl` is the
    # one artefact in this repository that CANNOT be regenerated — once this file is
    # deleted there is nothing left to ask. So the move renames the constant and touches
    # nothing else: not the nine `rescue nil`, not the fail-open `enforce_visibility`,
    # not a comment. A "while we are here" cleanup would move the oracle.
    #
    # The owned replacement is `Liquid::ScopeBinding`, which has two sources where this
    # has six. What is still here, and stays here until 1.0, is what a reporter install
    # needs in order to keep working — including drill-through, which reporter's own
    # renderer cannot pass any other way.
    #
    # **Finding F-2 lives in `#scope_from_registers`**: an AR relation arriving in
    # `registers[:container]` is returned as-is, so it is NOT intersected with
    # `Issue.visible` — only the drop path is. T-07's decision (implementation-plan.md
    # §Findings) is to leave that exactly as it is and close it by construction in the
    # owned path, which has no registers source at all. The silence here is a recorded
    # decision, not an oversight.
    module Legacy
      # Resolves an ActiveRecord issue scope — and, for drill-through URLs, the
      # IssueQuery behind it — from a Liquid render context. Shared by every
      # SQL-aggregation tag ({% sql_aggregate %}, {% version_rollup %}).
      #
      # The host tag must expose @raw_params (a Hash parsed from its markup). The
      # resolution order deliberately avoids materialising the (possibly large,
      # already-loaded) issues Array when Reporter has handed us the IssueQuery/scope
      # through context.registers.
      #
      #   1. explicit  query_id: param        -> IssueQuery#base_scope
      #   2. context.registers                -> :sql_issue_query / :container / :controller
      #   3. the `from:` drop (default issues) -> ivar / @issues / scope method
      #
      # Returns an AR::Relation-like object (responds to where/group/count) or nil.
      #
      # 1 and 2 are IssueQuery#base_scope, which starts from Issue.visible. 3 is whatever
      # the render context happens to hold, so it is intersected with Issue.visible before
      # being returned — see #enforce_visibility.
      #
      # --- resolve_query ---
      #
      # #resolve_scope answers "what do I count?"; #resolve_query answers "which
      # IssueQuery was this report built from?", which is what a drill-through URL
      # needs in order to inherit the report's filters, columns, grouping, totals and
      # sort order. Same order as above, plus the thread-local ReporterListPatch
      # fills for the duration of one liquidize() call:
      #
      #   1. query_id: param              (visibility-scoped, like scope_from_query_id)
      #   2. registers[:sql_issue_query]
      #   3. registers[:container]        (itself an IssueQuery, or its @query)
      #   4. registers[:controller]       (its @query)
      #   5. Thread.current[:rrd_issue_query]
      #   6. nil
      #
      # Whatever the source, the result passes one #visible? gate, so "a query only
      # becomes a drill-through source if the viewer may see it" holds everywhere and
      # not just on the query_id: path.
      #
      # nil is a fully supported outcome: it means "no drill-down URLs", never an
      # error. The register lookups deliberately outrank the thread-local so that a
      # future Reporter release passing the query properly wins over our fallback.
      module ScopeResolution
        # Set by ReporterListPatch around liquidize(), always cleared in an ensure.
        QUERY_THREAD_KEY = :rrd_issue_query

        def resolve_scope(context)
          if @raw_params.key?('query_id')
            return scope_from_query_id(@raw_params['query_id'], context)
          end

          # Registers-based resolution avoids building a massive WHERE IN from a
          # loaded Array when Reporter has passed the IssueQuery (or controller)
          # via context.registers.
          scope = scope_from_registers(context)
          return scope if scope

          # The drop path is the one whose provenance we cannot vouch for: it returns
          # whatever ivar of whatever context object quacks like a scope. Everything else
          # comes from IssueQuery#base_scope, which is Issue.visible already.
          from_key = @raw_params['from'] || 'issues'
          enforce_visibility(scope_from_drop(context[from_key]))
        end

        # Intersects a scope of unknown provenance with what the current user may see.
        #
        # base_scope is `Issue.visible.joins(:status, :project).where(statement)`, so the
        # register and query_id paths are visibility-scoped by construction. A drop is
        # not: #scope_from_drop hands back the first ivar of the named context object that
        # responds to where/group/count, and rebuilds `Issue.where(id: ids)` from a loaded
        # Array. Merging Issue.visible makes the guarantee hold whatever a template names
        # in `from:`. Issue.visible carries its own joins(:project), and ActiveRecord
        # de-duplicates that against the one a base_scope already has.
        #
        # Fails OPEN, deliberately: the paths that matter are already scoped, and turning
        # an unexpected merge error into an empty dashboard would trade a hypothetical
        # disclosure for a real outage.
        def enforce_visibility(scope)
          return nil if scope.nil?
          return scope unless defined?(Issue) && Issue.respond_to?(:visible)
          return scope unless scope.respond_to?(:merge)

          scope.merge(Issue.visible(User.current))
        rescue StandardError => e
          Rails.logger.warn("[sql_aggregation] could not intersect the resolved scope with " \
                            "Issue.visible: #{e.class}: #{e.message} — using it as resolved")
          scope
        end

        # Try to obtain an AR::Relation from context.registers without touching
        # the issues drop (which may hold a loaded Array in production).
        #
        # Priority:
        #   1. :sql_issue_query — set by reporter_render_patch.rb once activated
        #   2. :container       — Reporter stores the source object here; when it IS
        #                         an IssueQuery, base_scope is available directly
        #   3. :controller      — standard Redmine pattern; controller has @query
        def scope_from_registers(context)
          registers = context.registers rescue {}
          return nil if registers.nil? || registers.empty?

          if (query = registers[:sql_issue_query])
            scope = query.base_scope rescue nil
            return scope if ar_scope?(scope)
          end

          # :container — Reporter stores the liquidize argument here.
          # ReporterListPatch replaces the loaded Array with query.base_scope,
          # so after patching the container IS the AR scope.
          if (container = registers[:container])
            return container if ar_scope?(container)
            if container.respond_to?(:base_scope)
              scope = container.base_scope rescue nil
              return scope if ar_scope?(scope)
            end
            query = container.instance_variable_get(:@query) rescue nil
            if query&.respond_to?(:base_scope)
              scope = query.base_scope rescue nil
              return scope if ar_scope?(scope)
            end
          end

          if (controller = registers[:controller])
            query = controller.instance_variable_get(:@query) rescue nil
            if query&.respond_to?(:base_scope)
              scope = query.base_scope rescue nil
              return scope if ar_scope?(scope)
            end
          end

          nil
        end

        def scope_from_query_id(param, context)
          query_from_query_id(param, context)&.base_scope
        rescue => e
          Rails.logger.warn("[sql_aggregation] query_id lookup failed: #{e.message}")
          nil
        end

        # IssueQuery.visible, not IssueQuery.find_by: base_scope starts from
        # Issue.visible, so issue data never leaks — but an arbitrary id would still
        # let a template aggregate through someone else's private query and learn
        # that it exists. Redmine's own query lookups are visibility-scoped; so is
        # this one.
        def query_from_query_id(param, context)
          qid = (context[param] || param).to_i
          return nil if qid.zero?

          query = IssueQuery.visible(User.current).find_by(id: qid)
          if query.nil?
            Rails.logger.warn("[sql_aggregation] query ##{qid} does not exist or is not visible " \
                              'to the current user — skipping aggregation')
            return nil
          end

          query
        rescue => e
          Rails.logger.warn("[sql_aggregation] query_id lookup failed: #{e.message}")
          nil
        end

        # ------------------------------------------------------------------
        # IssueQuery resolution (drill-through)
        # ------------------------------------------------------------------

        # Returns the IssueQuery this render is based on, or nil. See the module
        # comment for the priority order. Never raises.
        def resolve_query(context)
          # An explicit query_id: names one query; if it cannot be resolved (gone, or
          # invisible to the viewer) there is deliberately no fallback, exactly as in
          # resolve_scope.
          query = if @raw_params.key?('query_id')
            query_from_query_id(@raw_params['query_id'], context)
          else
            query_from_registers(context) || query_from_thread
          end

          visible_query(query)
        rescue => e
          Rails.logger.warn("[sql_aggregation] query resolution failed: #{e.class}: #{e.message}")
          nil
        end

        # ONE visibility gate for all five sources, so the rule holds wherever the
        # query came from. query_from_query_id is already scoped by
        # IssueQuery.visible; the thread-local is NOT — ReporterListPatch resolves it
        # with a bare find_by, because that lookup also feeds base_scope and must keep
        # its existing behaviour. Without this gate the guarantee would depend on the
        # source, and it would quietly lapse the first time a report renders under a
        # different user (a scheduled report, a shared PDF).
        #
        # Query#visible? is one permission check per render, not per element.
        def visible_query(query)
          return nil if query.nil?
          return query unless query.respond_to?(:visible?)
          return query if query.visible?

          Rails.logger.warn("[sql_aggregation] query ##{query.id rescue nil} is not visible to the " \
                            'current user — no drill-through URLs')
          nil
        rescue => e
          Rails.logger.warn("[sql_aggregation] query visibility check failed: #{e.class}: #{e.message}")
          nil
        end

        def query_from_registers(context)
          registers = context.registers rescue {}
          return nil if registers.nil? || registers.empty?

          return registers[:sql_issue_query] if issue_query?(registers[:sql_issue_query])

          # :container — Reporter stores the liquidize argument here. It is normally
          # the AR scope (ReporterListPatch), but a future Reporter release may pass
          # the query itself, or an object wrapping it.
          if (container = registers[:container])
            return container if issue_query?(container)

            query = ivar(container, :@query)
            return query if issue_query?(query)
          end

          if (controller = registers[:controller])
            query = ivar(controller, :@query)
            return query if issue_query?(query)
          end

          nil
        end

        # Pragmatic fallback: Reporter's liquidize() takes no registers argument we
        # can extend from the outside, so ReporterListPatch parks the query in a
        # thread-local for the duration of the render (and clears it in an ensure).
        def query_from_thread
          query = Thread.current[QUERY_THREAD_KEY]
          issue_query?(query) ? query : nil
        end

        # Strict, not duck-typed: the resolved object decides which filters a
        # drill-through URL inherits, so anything that is not an IssueQuery (a
        # TimeEntryQuery on the controller, an AR::Relation in :container) is refused.
        def issue_query?(obj)
          return false if obj.nil?

          defined?(IssueQuery) ? obj.is_a?(IssueQuery) : false
        end

        def ivar(obj, name)
          obj.instance_variable_get(name)
        rescue StandardError
          nil
        end

        def scope_from_drop(drop)
          return nil unless drop

          # Check all ivars for an IssueQuery or scope stored alongside @issues.
          # reporter_render_patch.rb sets @sql_base_scope on the drop when
          # Reporter is patched at the IssuesDrop level.
          drop.instance_variables.each do |ivar|
            next if ivar == :@issues
            val = drop.instance_variable_get(ivar) rescue nil
            return val if ar_scope?(val)
            if val.respond_to?(:base_scope)
              scope = val.base_scope rescue nil
              return scope if ar_scope?(scope)
            end
          end

          # Primary: IssuesDrop stores the collection in @issues.
          # Reporter passes a loaded Array (not an AR::Relation), so reconstruct
          # a scope from the issue IDs when the value is not already an AR scope.
          if drop.instance_variable_defined?(:@issues)
            candidate = drop.instance_variable_get(:@issues)
            return candidate if ar_scope?(candidate)

            if candidate.is_a?(Array)
              ids = candidate.filter_map { |obj| obj.id if obj.respond_to?(:id) }
              return ids.any? ? Issue.where(id: ids) : Issue.none
            end
          end

          # Fallback: some drops expose the scope via a public method
          %i[scope issues_scope base_scope].each do |m|
            next unless drop.respond_to?(m)

            candidate = drop.public_send(m)
            return candidate if ar_scope?(candidate)
          end

          # Last resort: drop is itself an AR scope (unlikely but safe to check)
          return drop if ar_scope?(drop)

          nil
        end

        def ar_scope?(obj)
          obj.respond_to?(:where) && obj.respond_to?(:group) && obj.respond_to?(:count)
        end
      end
    end
  end
end
