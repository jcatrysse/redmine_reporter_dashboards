# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # What a render is FOR: who is looking, at which issues, through which query.
    #
    # This is the object T-07 exists to introduce. Today's `ScopeResolution` answers
    # those three questions by archaeology at read time — walking a drop's instance
    # variables, digging `@query` out of a controller, reading a thread-local — and
    # every one of those paths is a place the actor can go missing. INV-1 is the
    # invariant that says the actor is explicit and never ambient `User.current`, and
    # it is the easiest thing in this project to lose silently.
    #
    # So it is made impossible to lose instead of documented: **you cannot construct a
    # RenderContext without an actor.** A nil actor raises here rather than turning
    # into `User.current` three call frames later.
    #
    # --- Who builds one ---
    #
    # Nobody yet, and that is correct rather than an omission. These Liquid tags only
    # ever run inside the optional host plugin's renderer; standalone, T-06 makes the
    # report widgets degrade and `report_pdf` 404. T-10 onward builds the owned render
    # path and is what will fill this in. Until then such an install resolves through
    # `Glue::Legacy::ScopeResolution`, which is exactly what T-07's acceptance list
    # asks for: drill-through keeps working on installs that still have the host
    # plugin. The owned layer names it nowhere — that is what gate G8 measures.
    #
    # Inventing a producer now — having the glue synthesise one from the host's Liquid
    # registers — would make the owned path *look* exercised while the archaeology it
    # replaces still ran. An empty path is honest; a path that launders the old one is
    # not.
    #
    # --- Why a register and not an argument ---
    #
    # Liquid hands a tag one `Liquid::Context`. `context.registers` is the only channel
    # a host can use to pass a tag something out of band, so the owned renderer will
    # put exactly ONE object there under a key this plugin owns. One key, one type: the
    # thing `ScopeResolution` gets wrong is that it treats registers as a place to go
    # looking.
    class RenderContext
      REGISTER_KEY = :rrd_render_context

      attr_reader :actor, :scope, :query, :correlation_id

      # actor          the user the render is FOR. Required (INV-1).
      # scope          an ActiveRecord issue relation, already visibility-scoped by
      #                whoever built it, or nil for "this render has no issue scope".
      # query          the IssueQuery the render was built from, or nil for "no
      #                drill-through". nil is a supported answer, never an error.
      # correlation_id carried so a log line in the aggregation layer can be tied to
      #                the render that produced it.
      def initialize(actor:, scope: nil, query: nil, correlation_id: nil)
        if actor.nil?
          raise ArgumentError,
                'a RenderContext needs an actor (INV-1: never ambient User.current)'
        end

        @actor = actor
        @scope = scope
        @query = query
        @correlation_id = correlation_id
        freeze
      end

      # The one register lookup the owned path performs. Returns nil when there is no
      # render context, which is how ScopeBinding knows to fall back to the legacy
      # glue — so this must not raise on a context that has no registers at all.
      #
      # Type-checked rather than duck-typed: something else answering to `scope` is
      # exactly the accident `ScopeResolution`'s `ar_scope?` duck test institutionalised.
      def self.from(liquid_context)
        registers = registers_of(liquid_context)
        return nil if registers.nil?

        candidate = registers[REGISTER_KEY]
        candidate.is_a?(self) ? candidate : nil
      end

      def self.registers_of(liquid_context)
        return nil unless liquid_context.respond_to?(:registers)

        registers = liquid_context.registers
        registers.respond_to?(:[]) ? registers : nil
      end
      private_class_method :registers_of

      def to_s
        "#<RenderContext actor=#{actor_label} scope=#{@scope ? 'yes' : 'nil'} " \
          "query=#{@query ? "##{@query.id}" : 'nil'}>"
      end

      # A login, never a name: this appears in log lines, and a display name is
      # personal data going somewhere it is not needed.
      def actor_label
        @actor.respond_to?(:login) ? @actor.login.to_s : @actor.class.name
      end
    end
  end
end
