# frozen_string_literal: true

require_relative 'render_context'

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
        def bind(raw_params, liquid_context)
          raw_params ||= {}
          render_context = RenderContext.from(liquid_context)

          # No render context means no owned renderer produced this render, so this is
          # a host-plugin install and the legacy glue is what knows how to read it.
          return legacy_bind(raw_params, liquid_context) if render_context.nil?

          if raw_params.key?('query_id')
            # An explicit query_id: names ONE query. If it cannot be resolved there is
            # deliberately no fallback: a template that asked for query 7 and silently
            # got the ambient scope would report the wrong numbers under the right
            # heading, which is worse than reporting none.
            return from_query_id(raw_params['query_id'], liquid_context, render_context.actor)
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
        def query_id_of(param, liquid_context)
          resolved = liquid_context.respond_to?(:[]) ? liquid_context[param] : nil
          (resolved || param).to_i
        end

        # ----------------------------------------------------------------
        # The legacy path
        # ----------------------------------------------------------------

        # One dispatch, and nothing else about the host plugin in the owned layer. The
        # legacy module is a mixin expecting `@raw_params` (that is how the tags used it), so a
        # throwaway host carries them rather than the module being rewritten — its
        # behaviour is frozen by the scope fixture in
        # test/unit/golden_scope_fixture_test.rb and a change to it would move an oracle
        # that cannot be regenerated.
        def legacy_bind(raw_params, liquid_context)
          host = legacy_host(raw_params)
          return NONE if host.nil?

          Binding.new(scope: host.resolve_scope(liquid_context),
                      query: host.resolve_query(liquid_context),
                      source: :legacy)
        end

        def legacy_host(raw_params)
          return nil unless legacy_available?

          LegacyHost.new(raw_params)
        end

        # Asked, not rescued. `Glue::Legacy::ScopeResolution` is required only where
        # the host plugin is present, and a swallowed NameError around a lookup like
        # this is precisely how the vendor-gem coupling stayed invisible for a whole
        # release (CLAUDE.md §5 lists it by name; this layer does not).
        #
        # `inherit: false` at every step. With the default, a module's const_defined?
        # also searches Object, so an unrelated top-level `Glue` in some other plugin
        # would answer yes here and the next line would raise.
        def legacy_available?
          RedmineReporterDashboards.const_defined?(:Glue, false) &&
            RedmineReporterDashboards::Glue.const_defined?(:Legacy, false) &&
            RedmineReporterDashboards::Glue::Legacy.const_defined?(:ScopeResolution, false)
        end

        def log(message)
          return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

          ::Rails.logger.warn("[scope_binding] #{message}")
        end
      end

      # Defined lazily so this file can be loaded on an installation that has no legacy
      # module at all — including the DB-less spec run, where neither reporter nor the
      # glue exists.
      class LegacyHost
        def initialize(raw_params)
          @raw_params = raw_params || {}
          extend(RedmineReporterDashboards::Glue::Legacy::ScopeResolution)
        end
      end
    end
  end
end
