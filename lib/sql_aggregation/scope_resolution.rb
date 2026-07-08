# frozen_string_literal: true

module SqlAggregation
  # Resolves an ActiveRecord issue scope from a Liquid render context, shared by
  # every SQL-aggregation tag ({% sql_aggregate %}, {% version_rollup %}).
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
  module ScopeResolution
    def resolve_scope(context)
      if @raw_params.key?('query_id')
        return scope_from_query_id(@raw_params['query_id'], context)
      end

      # Registers-based resolution avoids building a massive WHERE IN from a
      # loaded Array when Reporter has passed the IssueQuery (or controller)
      # via context.registers.
      scope = scope_from_registers(context)
      return scope if scope

      from_key = @raw_params['from'] || 'issues'
      scope_from_drop(context[from_key])
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
      qid = (context[param] || param).to_i
      return nil if qid.zero?

      query = IssueQuery.find_by(id: qid)
      return nil unless query

      query.base_scope
    rescue => e
      Rails.logger.warn("[sql_aggregation] query_id lookup failed: #{e.message}")
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
