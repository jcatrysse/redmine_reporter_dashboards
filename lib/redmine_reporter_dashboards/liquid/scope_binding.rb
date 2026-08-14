# frozen_string_literal: true

require_relative 'render_context'
# S-30: `query_id:` resolves on a context-less render too, and TagContext is where the one
# ambient-actor read lives. Required here so that path cannot depend on load order.
require_relative 'tag_context'
require_relative 'tag_params'

module RedmineReporterDashboards
  module Liquid
    # What a Liquid aggregation tag counts, and which query it drills through — from
    # **two sources and no others**.
    #
    #   1. `query_id:`   -> IssueQuery.visible(actor).find_by(id:) -> #base_scope
    #   2. RenderContext -> #scope / #query
    #
    # That is T-07's whole point. `Glue::Legacy::ScopeResolution` — which this replaces
    # in the owned path — has six sources, and five of them are archaeology: a walk over
    # a drop's instance variables, `@query` dug out of a `:container` or a
    # `:controller`, `Issue.where(id: ids)` rebuilt from a loaded Array, and a
    # thread-local. Each is a place the viewer can go missing, which is why
    # `enforce_visibility` exists to put it back — and why that method has to fail OPEN,
    # because it is defending paths whose provenance it cannot vouch for.
    #
    # **Both sources here start from `Issue.visible`, so there is nothing left to
    # defend.** `enforce_visibility` and its fail-open rescue are not ported. That is
    # the difference between an invariant held by a patch and an invariant held by
    # construction, and it is also this task's answer to finding F-2 (the registers
    # relation path was never visibility-scoped): the owned path has no registers
    # source, so the leak is not fixed here — it is unrepresentable.
    #
    # --- Fail closed, and say so ---
    #
    # Nothing in here rescues. A query that does not exist, or that the actor may not
    # see, produces `nil` and a log line; anything genuinely broken raises into the
    # tag's own `rescue`, which assigns the empty result and logs. Both outcomes are
    # an empty widget, never a widget showing somebody else's issues (INV-3).
    #
    # --- No memoisation, deliberately ---
    #
    # Liquid parses a template once and renders it many times, so a tag instance
    # outlives a render. Memoising a binding on the tag would serve the first viewer's
    # scope to the second — the same class of bug the thread-local's `ensure` exists to
    # prevent, and considerably harder to notice.
    module ScopeBinding
      # `source` is carried for the log line, so "which of the two answered" is visible
      # in production rather than inferred from timing.
      Binding = Struct.new(:scope, :query, :source, keyword_init: true)

      NONE = Binding.new(scope: nil, query: nil, source: :none).freeze

      # ------------------------------------------------------------------
      # The mixin the tags include. Two methods, matching what they called before, so
      # the re-seam is one line per tag.
      # ------------------------------------------------------------------

      def resolve_scope(context)
        ScopeBinding.bind(@raw_params, context).scope
      end

      def resolve_query(context)
        ScopeBinding.bind(@raw_params, context).query
      end

      class << self
        # --- THE ISSUE-KERNEL GUARD. ONE CALLER TODAY, AND THAT IS DELIBERATE ---
        #
        # It was written for both tags. T-31 increment 2 gave `{% sql_aggregate %}` an owned
        # time-entry aggregator, so that tag now DISPATCHES where it used to refuse and this
        # method's only caller is `{% version_rollup %}` — which still refuses, because a
        # per-target-version rollup over spent time is a different report nobody has
        # specified. The guard stays here rather than moving into that tag: it is the answer
        # to "may this scope reach the issue kernel", and the next tag to reach for the kernel
        # should find it already written.
        #
        # `SqlAggregation::QueryAggregator` counts `DISTINCT issues.id` and reads issue
        # columns throughout. Handed a TIME-ENTRY relation it does not raise —
        # `TimeEntryQuery#base_scope` calls `.left_join_issue`, so the issue columns resolve
        # and it answers issue counts under time-entry labels (§Findings **S-13**: four
        # entries over two issues came back as `2` in every bucket).
        #
        # IT LIVES HERE BECAUSE THE FIRST VERSION LIVED IN ONE TAG AND THERE ARE TWO. An
        # independent review measured `{% version_rollup %}` still handing a time-entry
        # relation straight to the kernel, where the only thing saving it was an accident of
        # which expressions ActiveRecord qualifies: `group(:fixed_version_id).count`
        # SUCCEEDS (binding to `issues.fixed_version_id`), and the raise came one line later
        # from a `where.not(status_id:)` that AR does qualify — landing in the tag's rescue
        # as a log line and an empty list, with no degradation and nothing said to the
        # author. `ScopeBinding` is what both tags already include, so it is where the one
        # copy goes.
        #
        # `RenderContext.from` and NOT `TagContext.for`: the latter never answers nil and
        # building its fallback reads `User.current`, and an ambient actor read on a path
        # that needs no actor is what INV-1 is about. Nil is the answer this wants.
        #
        # S-30 CHANGED WHAT NIL MEANS HERE. It used to mean "the legacy path produced this
        # render, and that path resolves issue scopes and nothing else", so defaulting to
        # `:issues` described a real producer. There is no such producer now: `bind`
        # answers NONE for a context-less render, so a nil context reaches the kernel with
        # no scope at all and the default is a formality rather than a claim about
        # anybody's data.
        #
        # Asking the RELATION instead was considered and is worse than useless: the tag
        # specs' scope doubles answer no `model`, `klass` or `table_name` at all, so a
        # sniffing check would raise on the doubles and fail OPEN on exactly the object it
        # could not identify. The producer knows, because `template.source` is a column.
        def report_source(liquid_context)
          RenderContext.from(liquid_context)&.source || :issues
        end

        # True when this scope may go to the issue kernel. False records the degradation on
        # the way out, so a caller cannot refuse silently by forgetting to (INV-4).
        def issue_kernel_permitted?(liquid_context, tag_name)
          source = report_source(liquid_context)
          return true if source == :issues

          log("#{tag_name}: refusing a #{source} scope — this aggregation kernel counts " \
              'issues, and answering would report issue counts under other labels ' \
              '(finding S-13)')
          RenderContext.from(liquid_context)
            &.diagnostics
            &.degrade(:aggregation_source_unsupported, source: source.to_s, tag: tag_name)
          false
        end

        def bind(raw_params, liquid_context)
          raw_params ||= {}
          render_context = RenderContext.from(liquid_context)

          # S-30: THERE IS NO LEGACY FALLBACK ANY MORE.
          #
          # This used to dispatch to `Glue::Legacy::ScopeResolution`, which resolved a
          # scope from six ambient sources — an `issues` drop, three registers, an ivar
          # on somebody else's drop, and a thread-local. Each is a place the viewer can
          # go missing, which is why that module needed a fail-open `enforce_visibility`
          # to put one back.
          #
          # What replaces it is not "nothing": it is the ONE source that names what it
          # wants, `query_id:`, resolved below through `IssueQuery.visible(actor)`. A
          # render with neither an owned context nor a `query_id:` has nothing nameable
          # in it, and answering NONE is the INV-1 position — a scope taken from whatever
          # happened to be lying in the Liquid context has no named viewer behind it.
          # `query_id:` IS RESOLVED FIRST, AND BEFORE THE NIL-CONTEXT CHECK.
          #
          # An explicit query_id: names ONE query. If it cannot be resolved there is
          # deliberately no fallback: a template that asked for query 7 and silently got
          # the ambient scope would report the wrong numbers under the right heading,
          # which is worse than reporting none.
          #
          # THE ORDER MATTERS AND THE FIRST VERSION OF S-30 GOT IT WRONG. `query_id:` was
          # never one of the legacy module's ambient sources in the sense the deletion is
          # about — it names a query explicitly and resolves it through
          # `IssueQuery.visible(actor)`, so the only thing it needs from a render context
          # is the ACTOR. Putting the nil-context return above it withdrew a documented,
          # working feature (README: "When the Reporter plugin exposes `query_id` in the
          # template context") from every render this plugin does not produce, silently,
          # as collateral of a deletion that never claimed it. Found by an independent
          # review.
          #
          # `TagContext.actor` and not `render_context.actor`: it answers the owned
          # context's actor when there is one and `User.current` when there is not — the
          # single, named, logged place this plugin reads an ambient actor, which is what
          # INV-1 asks for. The visibility scoping is identical either way, because
          # `visible_query` applies `IssueQuery.visible(actor)` to whichever it gets.
          if raw_params.key?('query_id')
            return from_query_id(raw_params['query_id'], liquid_context,
                                 TagContext.actor(liquid_context))
          end

          # No render context and no `query_id:` — nothing nameable to resolve.
          #
          # LOGGED, NOT SILENT (INV-4). Every other refusal in this file announces itself,
          # and this is the branch that turns a previously-resolving render into an empty
          # one, so it is the last place that should be quiet. A degradation cannot be
          # recorded — there is no context to record it on — which is precisely why the
          # log line is mandatory rather than optional.
          if render_context.nil?
            log('no render context and no query_id: — this render was not produced by ' \
                "TemplateRenderer, so there is no named viewer to resolve a scope for (INV-1). " \
                'A host-plugin template can name one explicitly with query_id:.')
            return NONE
          end

          Binding.new(scope: render_context.scope, query: render_context.query,
                      source: :render_context)
        end

        # `IssueQuery.visible(actor)`, not `find_by`. `base_scope` already starts from
        # `Issue.visible`, so issue data cannot leak either way — but an arbitrary id
        # would still let a template learn that somebody else's private query exists,
        # and confirm its filters through the shape of the result. Redmine's own query
        # lookups are visibility-scoped; so is this one.
        def from_query_id(param, liquid_context, actor)
          query = visible_query(param, liquid_context, actor)
          Binding.new(scope: query&.base_scope, query: query, source: :query_id)
        end

        def visible_query(param, liquid_context, actor)
          id = query_id_of(param, liquid_context)
          return nil if id.zero?

          query = ::IssueQuery.visible(actor).find_by(id: id)
          if query.nil?
            # One message for "gone" and "not yours", on purpose: telling them apart
            # is the disclosure the visible() scope is there to prevent.
            log("query ##{id} does not exist or is not visible to this actor — skipping")
          end
          query
        end

        # A template may write either `query_id: 7` or `query_id: some_variable`, so the
        # literal is tried as a context lookup first — the same two-step the legacy
        # module does, kept because it is template-facing behaviour and templates exist.
        # THE SAME QUOTING RULE AS EVERY OTHER TAG PARAMETER (curator decision #3).
        # `query_id: 7` and `query_id: some_var` are unchanged; `query_id: "7"` is the
        # literal seven rather than a lookup of a variable named `7`. Routed through
        # `TagParams` rather than repeated, because a second copy of the rule is how the
        # four copies of `str_param` drifted apart.
        def query_id_of(param, liquid_context)
          TagParams.resolve(param, liquid_context).to_i
        end

        def log(message)
          return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

          ::Rails.logger.warn("[scope_binding] #{message}")
        end
      end

    end
  end
end
