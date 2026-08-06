# frozen_string_literal: true

require_relative 'render_context'

module RedmineReporterDashboards
  module Liquid
    # The `RenderContext` a TAG renders under — and the one place `User.current` is read.
    #
    # --- WHY THIS EXISTS AT ALL ---
    #
    # T-20 deletes the addon's own `VersionDrop`, and `{% version_rollup %}` was building
    # one per row. The replacement is `Drops::VersionDrop`, which — like every drop in
    # the owned layer — refuses to be constructed without a `RenderContext`, because
    # INV-1 says the actor is explicit and a drop that can be built without one will
    # reach for `User.current` the first time it converts a timestamp.
    #
    # On an install with the host plugin there IS no `RenderContext`: nothing constructs
    # one until T-23 wires the owned renderer, and every render today goes through the
    # host's. So a tag that needs a drop has exactly two options, and only one of them
    # is honest.
    #
    #   * Refuse, and render no version links at all. That is 100% of live installs
    #     losing a working feature to a rule about a path that does not run yet.
    #   * Read `User.current` ONCE, here, name it, log which branch answered, and hand
    #     the tag an explicit actor.
    #
    # This is the second. INV-1 is not "never touch `User.current`" — Redmine has no
    # other answer to "who is this request for" — it is "never touch it AMBIENTLY, three
    # frames deep, where nobody can see it happened". One named method that says so is
    # the invariant being kept, not bent.
    #
    # --- WHAT THIS IS NOT ---
    #
    # It does NOT synthesise a scope or a query. `HANDOVER.md` §6 warns against having
    # the glue rebuild a `RenderContext` from the host's Liquid registers — "it would run
    # the same archaeology behind a new name and make the owned path look tested" — and
    # that warning is about SCOPE. Scope still comes from `ScopeBinding`, which still
    # dispatches to `Glue::Legacy::ScopeResolution` on this path. The context built here
    # carries an actor and nothing else: `scope` and `query` are deliberately nil, so a
    # drop that tried to read one gets nothing rather than something plausible.
    #
    # `owned?` is how a reader (and a spec) can tell the two apart without inferring it.
    module TagContext
      module_function

      # The owned context when the owned renderer produced this render; otherwise an
      # actor-only one. Never nil, so no caller needs a branch.
      def for(liquid_context)
        RenderContext.from(liquid_context) || fallback
      end

      def actor(liquid_context)
        RenderContext.from(liquid_context)&.actor || current_user
      end

      # True when the render came from `TemplateRenderer` rather than the host plugin.
      # Exists so the distinction is ASSERTABLE: a spec that only checked "a context came
      # back" would pass whichever branch answered.
      def owned?(liquid_context)
        !RenderContext.from(liquid_context).nil?
      end

      def fallback
        RenderContext.new(actor: current_user)
      end

      # THE ONE READ. `User.current` is Redmine's per-thread actor and it is never nil
      # (an unauthenticated request gets `AnonymousUser`), so there is no nil branch to
      # write — and if some caller ever manages it, `RenderContext` raises rather than
      # rendering somebody else's data, which is the direction to fail in.
      def current_user
        ::User.current
      end
    end
  end
end
