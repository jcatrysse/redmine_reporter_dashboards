# frozen_string_literal: true

require_relative 'batch'
require_relative 'diagnostics'
require_relative 'execution_policy'
require_relative '../charts/collector'

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

      # The output binding. Closed, for the reason every closed set in this plugin is
      # closed: an open one lets a caller pass `:print` and an emitter test for `:pdf`,
      # and the two never meet.
      OUTPUTS = %i[html pdf].freeze

      # WHAT TABLE `scope` IS OVER, said rather than sniffed — T-31, and the reason it is
      # here rather than derived is §Findings **S-13**.
      #
      # A `{% sql_aggregate %}` handed a TIME-ENTRY relation does not raise: the frozen
      # kernel counts `DISTINCT issues.id`, and `TimeEntryQuery#base_scope` calls
      # `.left_join_issue`, so the issue columns resolve and the tag reports issue counts
      # under time-entry labels. Four entries over two issues came back as `2`.
      #
      # The obvious guard — ask the relation what model it is over — is worse than useless
      # here. Every legacy-path scope is an issue scope and correctly needs no annotation,
      # and the specs' scope doubles answer no `model`/`klass`/`table_name` at all, so a
      # sniffing check would either raise on them or fail open on exactly the object it
      # cannot identify. The producer KNOWS (`template.source` is a column), so it says so,
      # and a consumer that cannot find a render context gets `:issues` — which is what the
      # legacy path is, always.
      SOURCES = %i[issues time_entries].freeze

      attr_reader :actor, :scope, :query, :correlation_id, :diagnostics, :budget, :batch,
                  :charts, :output, :source

      # actor          the user the render is FOR. Required (INV-1).
      # scope          an ActiveRecord issue relation, already visibility-scoped by
      #                whoever built it, or nil for "this render has no issue scope".
      # query          the IssueQuery the render was built from, or nil for "no
      #                drill-through". nil is a supported answer, never an error.
      # correlation_id carried so a log line in the aggregation layer can be tied to
      #                the render that produced it.
      # diagnostics    where a degradation becomes visible (INV-4). Built here when the
      #                caller does not supply one, because a context whose diagnostics
      #                are nil is a context where every degradation is silent — which
      #                is the failure mode, not the safe default.
      # budget         the cooperative deadline. `Budget::NULL` by default so a context
      #                built outside `TemplateRenderer` — a preview, a spec — is not a
      #                render with no time limit but a render whose limit is nothing to
      #                check. `TemplateRenderer` binds the real one per render.
      # batch          the first-touch registry (§3.4). Derived from `scope` unless a
      #                caller passes one, which is what `with_batch` does.
      # charts         what `{% chart %}` recorded, in document order (§6). Built here
      #                rather than defaulted to nil for the same reason as diagnostics:
      #                a nil collector is a render where every chart is silently
      #                dropped, and a tag would have to branch on it at the one moment
      #                it must not.
      # output         `:html` or `:pdf` — WHICH DOCUMENT this render is producing, and
      #                the only thing that differs between the two emitters. The author
      #                writes one `{% chart %}`; this is what decides whether it becomes
      #                a `<canvas>` or an `<svg>` (§6, and FR-34's "no engine-specific
      #                workaround in a template"). Defaults to `:html` because that is
      #                the preview an author sees while writing.
      # source         `:issues` or `:time_entries` — which TABLE `scope` is over. Defaults
      #                to `:issues` because that is what every caller predating T-31 holds
      #                and what the legacy glue always produces. An unknown value is
      #                REFUSED rather than coerced: a stored string selecting behaviour is
      #                the shape T-25's review found reporting success while mailing the
      #                wrong person's numbers, and the same argument applies to a scope
      #                whose table nobody can name.
      def initialize(actor:, scope: nil, query: nil, correlation_id: nil,
                     diagnostics: nil, budget: nil, batch: nil, charts: nil,
                     output: :html, source: :issues)
        if actor.nil?
          raise ArgumentError,
                'a RenderContext needs an actor (INV-1: never ambient User.current)'
        end

        unless SOURCES.include?(source.to_sym)
          raise ArgumentError,
                "#{source.inspect} is not a report source. Known: #{SOURCES.inspect}"
        end

        @actor = actor
        @source = source.to_sym
        @scope = scope
        @query = query
        @correlation_id = correlation_id
        @diagnostics = diagnostics || Diagnostics.new(correlation_id: correlation_id)
        @budget = budget || Budget::NULL
        @batch = batch || Batch.new(actor: actor, scope: scope, diagnostics: @diagnostics,
                                    budget: @budget)
        @charts = charts || Charts::Collector.new
        @output = OUTPUTS.include?(output.to_sym) ? output.to_sym : :html
        freeze
      end

      # NOT FROZEN, and it is the one mutable thing this object holds. A `RenderContext`
      # is a frozen value because an actor that can be reassigned mid-render is INV-1
      # lost; the chart collector is an APPEND LOG that a tag writes to as the document
      # is produced, which is a different kind of thing and cannot be a value.
      #
      # `freeze` here is shallow, so the collector stays writable — deliberately, and
      # said out loud because "the context is frozen" would otherwise read as a promise
      # this field does not keep. `Diagnostics` is the same shape for the same reason.

      # The registry for some OTHER scope — a collection drop built over a relation that
      # is not the context's own, which is every named scope a `from:` argument reaches.
      #
      # A fresh Batch rather than a shared one, because a Batch answers "the ids in my
      # scope" and two scopes have two answers. Handing one Batch two scopes would let
      # it answer the first scope's questions with the second's rows, and every value
      # would look plausible.
      def batch_for(other_scope)
        return @batch if other_scope.nil? || same_scope?(other_scope)

        Batch.new(actor: @actor, scope: other_scope, diagnostics: @diagnostics,
                  budget: @budget)
      end

      # NOT `equal?`, and the difference is not academic — it was caught by a test.
      #
      # `IssueQuery#base_scope` builds a NEW relation object every time it is called, so
      # a caller that passed one to the context and another to the collection drop got
      # two Batches for one issue set: two id plucks, two custom-value queries, and — the
      # part that actually bit — the collection silently running under the DEFAULT cap
      # instead of the one the caller configured. Everything still worked, twice, with
      # the wrong limit.
      #
      # Two relations are the same scope when they generate the same SQL. That is what a
      # Batch's answers depend on, and nothing else about the object matters.
      def same_scope?(other)
        return true if other.equal?(@scope)
        return false if @scope.nil?
        return false unless @scope.respond_to?(:to_sql) && other.respond_to?(:to_sql)

        @scope.to_sql == other.to_sql
      end
      private :same_scope?

      # Derivations. The object is frozen — that is the point of it — so "the same
      # context with one thing changed" is a new object, and the things that must be
      # SHARED across the derivation (the diagnostics collector above all: a degradation
      # recorded through a derived context has to reach the same list) are passed
      # through explicitly rather than rebuilt.
      def with_batch(other_batch)
        self.class.new(actor: @actor, scope: @scope, query: @query,
                       correlation_id: @correlation_id, diagnostics: @diagnostics,
                       budget: @budget, batch: other_batch, charts: @charts,
                       output: @output, source: @source)
      end

      # The output binding is chosen by whoever is producing the document, and it is a
      # derivation rather than a constructor argument at the call site for the same
      # reason `with_budget` is: one render context, one render, two documents from it
      # only if somebody says so explicitly.
      #
      # The CHARTS COLLECTOR IS SHARED across the derivation, not rebuilt. That is the
      # whole point — `{% chart %}` recorded once, and the HTML and PDF bindings draw
      # the same recordings.
      def with_output(other_output)
        self.class.new(actor: @actor, scope: @scope, query: @query,
                       correlation_id: @correlation_id, diagnostics: @diagnostics,
                       budget: @budget, batch: @batch, charts: @charts,
                       output: other_output, source: @source)
      end

      def with_budget(other_budget)
        self.class.new(actor: @actor, scope: @scope, query: @query,
                       correlation_id: @correlation_id, diagnostics: @diagnostics,
                       budget: other_budget,
                       batch: Batch.new(actor: @actor, scope: @scope,
                                        diagnostics: @diagnostics, budget: other_budget),
                       charts: @charts, output: @output, source: @source)
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
        "#<RenderContext actor=#{actor_label} output=#{@output} " \
          "scope=#{@scope ? 'yes' : 'nil'} source=#{@source} " \
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
