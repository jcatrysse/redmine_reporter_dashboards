# frozen_string_literal: true

require_relative 'record_drop'
require_relative '../batch'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A scope, iterated safely. The base for `IssuesDrop`, `UsersDrop`,
      # `ProjectsDrop` and `TimeEntriesDrop`.
      #
      # --- WHAT `all` IS, AND WHY IT IS NOT HERE ---
      #
      # The gem's `IssuesDrop#all` maps every record in the scope into a drop object.
      # That is the O(n) materialisation this plugin used to work around ON THE HOST
      # PLUGIN'S OWN PATH, with a prepend called `reporter_report_content_patch.rb` —
      # deleted by curator decision #1 with the rest of the host-render support. At 10 000
      # issues it is 10 000 `Issue` objects and 10 000 drops, built so a template can ask for
      # `.size`. §3.2 says plainly: **`all` is not implemented**.
      #
      # It is still REACHABLE, and that is deliberate. A template that calls it must get
      # a visible answer rather than a blank — so `all` records
      # `Degradation(:unbounded_collection)` and returns nil, and T-19's lint flags it at
      # parse time. Deleting the method entirely would make `{{ issues.all }}` render
      # empty with `strict_variables: false`, which is the silent failure INV-4 forbids.
      #
      # --- WHY `visible` RETURNS SELF ---
      #
      # Because the scope is ALREADY the viewer's. §3.5 makes that a construction: every
      # scope in a RenderContext comes from `IssueQuery#base_scope`, built for the actor.
      # A `visible` that re-filtered would imply the unfiltered case exists, and the
      # whole point of T-07's seam is that it does not. The method survives because
      # templates in the wild call it, and it answers honestly.
      class CollectionDrop < ::Liquid::Drop
        # Bounded memory AND bounded queries (§3.4, M1). 500 is the spec's number.
        BATCH_SIZE = 500

        # Associations to preload per iteration batch. Subclasses declare their own;
        # the base declares none rather than guessing, because a preload of an
        # association the template never touches is a query nobody asked for.
        PRELOADS = [].freeze

        def initialize(scope, context:)
          unless context.is_a?(RenderContext)
            raise ArgumentError,
                  'a collection drop needs a RenderContext (INV-1: the actor is ' \
                  "explicit, never ambient User.current). Got #{context.class}"
          end

          @scope = scope
          # See `RecordDrop`: `@context` belongs to `Liquid::Drop`, which assigns it on
          # every touch. Storing the RenderContext there breaks Liquid's own internals.
          @render_context = context
          @batch = context.batch_for(scope)
          super()
        end

        # THE ITERATION. Three things happen here that do not happen in the gem:
        # the associations are preloaded, the deadline is checked at every batch
        # boundary, and the cap is enforced with a visible degradation.
        def each
          return to_enum(:each) unless block_given?

          seen = 0
          limit = @batch.limit
          truncated = false

          each_record do |record|
            # §4's third checkpoint. Cooperative: it bounds the loop where we cooperate,
            # which for a collection is once per record — cheap, because `check!` is a
            # monotonic clock read and a comparison.
            @render_context.budget.check!(:collection_batch)

            if seen >= limit
              truncated = true
              break
            end

            seen += 1
            yield build(record)
          end

          # INV-4. The reader of the report is told the list is short, rather than being
          # handed a short list. Raised after the loop rather than inside it so the
          # `break` is the last thing the iteration does.
          if truncated
            @render_context.diagnostics&.degrade(
              :collection_truncated, seen: limit,
              detail: "this collection has more than #{limit} records; only the first " \
                      "#{limit} were rendered"
            )
          end

          self
        end

        # One COUNT, no instantiation. This is the accessor an aggregate-only template
        # uses, and the reason it must not go anywhere near `each`: `{{ issues.size }}`
        # over 10 000 issues is one query and zero `Issue` objects.
        def size
          @size ||= @scope.count
        end

        # See the class comment. Already the viewer's scope, by construction.
        def visible
          self
        end

        # `{{ issues.first }}`. Liquid invokes a drop method with no arguments, so the
        # count is optional and the no-argument form answers with one record, which is
        # what `first` means everywhere else in Ruby.
        def first(count = nil)
          records = preloaded_scope.limit(count || 1).to_a
          return build(records.first) if count.nil?

          records.map { |record| build(record) }
        end

        # Reachable, refused, and VISIBLE. See the class comment.
        def all
          @render_context.diagnostics&.degrade(
            :unbounded_collection,
            detail: 'this template called `all` on a collection. It is not implemented: ' \
                    'it materialises one object per record regardless of how many there ' \
                    'are. Use the collection directly in a {% for %}, or an aggregate.'
          )
          nil
        end

        # `{{ issues[42] }}` — lookup by id, which is what the gem's `before_method`
        # did. Anything that is not an id renders nil rather than raising: a template
        # indexing a collection with a variable that turned out to be blank is an
        # authoring mistake, and `strict_variables` is the switch for how loud those
        # are, not this method.
        def liquid_method_missing(key)
          id = Integer(key.to_s, 10)
          record = @scope.find_by(id: id)
          record && build(record)
        rescue ArgumentError, TypeError
          super
        end

        def to_s
          "#{self.class.name.split('::').last}(#{size})"
        end

        def inspect
          to_s
        end

        private

        attr_reader :scope, :render_context, :batch

        # The drop each record is wrapped in. Abstract on purpose: a collection that
        # does not say what it yields is a collection whose template contract nobody
        # can read.
        def drop_class
          raise NotImplementedError, "#{self.class} must declare its drop_class"
        end

        def build(record)
          record && drop_class.new(record, context: item_context)
        end

        # Built ONCE per collection, not once per record. Every drop this collection
        # yields shares one Batch — which is the whole of M2: the first
        # `{{ issue.custom_field_value[20] }}` loads all of them, and the other 499 are
        # hash lookups because they are looking in the same hash.
        def item_context
          @item_context ||= @render_context.with_batch(@batch)
        end

        def preloaded_scope
          associations = self.class::PRELOADS
          associations.empty? ? @scope : @scope.preload(*associations)
        end

        # TWO WALKS, AND THE SECOND ONE IS NOT AN OPTIMISATION — IT IS THE ORDER.
        #
        # §3.4 asks for `find_each(batch_size: 500)`, and it is right for the scope this
        # layer normally gets: `IssueQuery#base_scope` carries no ORDER BY, sorting is
        # applied later by `IssueQuery#issues`, and `find_each` then buys a bounded
        # result set and a bounded preload working set. That matters more than it looks:
        # `{% for issue in issues limit: 10 %}` stops after the first batch, so ten rows
        # are loaded rather than five thousand.
        #
        # But `find_each` FORCES primary-key order and logs a warning when it discards
        # one. On a scope that does carry an order — a template handed a sorted
        # relation — that silently renders the report in the wrong sequence, and a
        # report sorted by the wrong column is wrong in a way no test of ours would
        # notice. So an ordered scope is walked in one capped query instead: the author's
        # order survives, and the cap is what bounds it.
        #
        # `+ 1` so the caller can tell "exactly at the cap" from "over it" — the same
        # trick `Batch#ids` uses, and for the same reason.
        def each_record(&block)
          if ordered?
            preloaded_scope.limit(@batch.limit + 1).each(&block)
          else
            preloaded_scope.find_each(batch_size: self.class::BATCH_SIZE, &block)
          end
        end

        def ordered?
          @scope.respond_to?(:order_values) && !@scope.order_values.empty?
        end
      end
    end
  end
end
