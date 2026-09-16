# frozen_string_literal: true

require_relative 'execution_policy'

module RedmineReporterDashboards
  module Liquid
    # The N+1 killer, and it is a CONSTRUCTION rather than a discipline.
    #
    # `technical-spec.md` §3.4 asks for two mechanisms and says both are required:
    #
    #   M1 — ASSOCIATION PRELOAD. `CollectionDrop#each` preloads the eight associations
    #        every issue template touches. That one lives in `Drops::CollectionDrop`,
    #        because it is a property of iterating a scope.
    #
    #   M2 — FIRST-TOUCH BATCH RESOLUTION, which is this file. The first
    #        `{{ issue.custom_field_value[20] }}` inside a 500-issue loop issues ONE
    #        query for all 500 and memoises it; the other 499 are hash lookups.
    #
    # Neither covers the other. A preload cannot reach `custom_values` — the shape we
    # need is not an association Redmine declares, and the visibility filter below is
    # not one an association could carry — and a batch registry cannot replace a preload
    # without reimplementing association loading. The plan says both; this is why.
    #
    # --- WHY A REGISTRY AND NOT `includes(...)` EVERYWHERE ---
    #
    # Because the template decides what it touches, and it decides at render time. A
    # template that never mentions a custom field must not pay for `custom_values`, and
    # `includes` is chosen when the scope is built — before anybody knows. So: nothing
    # is loaded until a drop asks, and the first ask loads everything.
    #
    # --- EVERY BATCH QUERY IS THE ACTOR'S, NOT THE ISSUE SET'S ---
    #
    # This is the part a reviewer should check first, because a batch is exactly where
    # visibility gets lost: the ids came from a scope that was already the viewer's, so
    # it FEELS as though everything reachable from them is too. It is not. Three of the
    # five value keys read tables with their own visibility rules —
    #
    #   custom_field_values   a role-restricted field is invisible to a viewer without
    #                         the role IN THE ISSUE'S PROJECT (INV-3, and the exact leak
    #                         `test/unit/multi_actor_visibility_test.rb` exists to catch)
    #   spent_hours           spent time needs :view_time_entries in that project
    #   time_entries          same
    #   subtasks              a child issue can be private when its parent is not
    #
    # — so the actor is a REQUIRED constructor argument here, not an optional one, and
    # every one of those four queries is filtered through Redmine's own scope rather
    # than through a condition invented here.
    #
    # --- THE CAP IS THE MEMORY BOUND, AND `find_each` IS NOT ---
    #
    # Worth stating plainly because it is easy to believe otherwise. Liquid's `{% for %}`
    # calls `Utils.slice_collection_using_each`, which collects the WHOLE segment into
    # an Array before rendering a single iteration. Streaming the scope in batches of
    # 500 therefore bounds the size of each database result set, not the peak memory of
    # the render. `MAX_MATERIALISED_RECORDS` is what bounds the render, and it is the
    # reason a truncation is a visible degradation rather than a comment.
    class Batch
      # From §3.4. Deliberately the same shape of decision as the aggregator's caps:
      # a number that can be argued with, in one place, with a degradation when it bites.
      MAX_MATERIALISED_RECORDS = 5_000

      # The keys §3.4 enumerates. Held as a constant so a spec can assert the table was
      # implemented rather than paraphrased, and so adding a seventh is a decision
      # somebody makes on purpose.
      KEYS = %i[custom_field_values spent_hours attachments time_entries subtasks
                named_refs].freeze

      attr_reader :limit, :diagnostics, :actor

      # `scope`       the issue relation this render is about, or nil. Registered
      #               rather than required, because a RenderContext is built before
      #               anybody knows whether the template iterates anything.
      # `actor`       required. See the class comment: four of the six keys are
      #               visibility-bearing, and a batch with no actor is a batch that
      #               would have to guess (INV-1).
      # `diagnostics` where a truncation becomes visible (INV-4).
      # `budget`      the cooperative deadline. A prefetch is one of the three
      #               checkpoints §4 names, and it is the one most likely to be slow.
      def initialize(actor:, scope: nil, diagnostics: nil, budget: nil,
                     limit: MAX_MATERIALISED_RECORDS)
        if actor.nil?
          raise ArgumentError,
                'a Batch needs an actor: four of its six keys read tables with their ' \
                'own visibility rules (INV-1, INV-3)'
        end

        @actor = actor
        @scope = scope
        @diagnostics = diagnostics
        @budget = budget || Budget::NULL
        @limit = Integer(limit)
        @cache = {}
        @named_refs = {}
        @field_visibility = {}
        @truncated = false
      end

      def scope?
        !@scope.nil?
      end

      # The id set, capped, resolved once. `limit + 1` on purpose: the extra row is how
      # "exactly at the cap" is told apart from "over it" without a second COUNT.
      def ids
        return @ids if defined?(@ids)

        @budget.check!(:batch_ids)
        rows = @scope.nil? ? [] : @scope.reorder(nil).limit(@limit + 1).pluck(:id)
        if rows.length > @limit
          @truncated = true
          rows = rows.first(@limit)
          degrade(:collection_truncated, seen: @limit,
                                         detail: "this scope has more than #{@limit} issues; " \
                                                 "only the first #{@limit} were used")
        end
        @ids = rows.freeze
      end

      def truncated?
        ids # resolving is what decides it
        @truncated
      end

      # ------------------------------------------------------------------
      # The five value keys
      # ------------------------------------------------------------------

      # `{ custom_field_id => value }` for ONE issue, restricted to the fields this
      # actor may see. Multi-value fields arrive as several rows for one field, so the
      # value is an Array exactly when the database holds more than one row — matching
      # what Redmine's own `custom_field_value` returns for a `multiple` field.
      #
      # `project` is the issue's project, and it is required rather than derived,
      # because the role check is PER PROJECT: holding the role somewhere is what
      # `CustomField.visible` already answered, and holding it HERE is the question
      # this argument asks. Passing the wrong project would widen the answer, so it is
      # `IssueDrop`'s preloaded association that supplies it and nothing else.
      def custom_field_values(issue_id, project)
        raw = resolve(:custom_field_values, issue_id) do |id_set|
          fields = visible_custom_fields
          rows = ::CustomValue.where(customized_type: 'Issue', customized_id: id_set,
                                     custom_field_id: fields.keys)
                              .pluck(:customized_id, :custom_field_id, :value)
          rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |(cid, fid, value), out|
            bucket = out[cid]
            # `key?` and not `bucket[fid].nil?`. A `multiple` field whose FIRST stored
            # row is empty would otherwise be treated as "no row yet" and its second
            # value would arrive as a scalar, silently dropping the first.
            bucket[fid] = bucket.key?(fid) ? Array(bucket[fid]) + [value] : value
          end
        end

        (raw[issue_id] || {}).select { |field_id, _| visible_field?(field_id, project) }
      end

      # The visible field records, `{ id => IssueCustomField }`, so a caller can put a
      # NAME next to a value without a second query. One query, memoised.
      def visible_custom_fields
        @visible_custom_fields ||= begin
          @budget.check!(:batch_custom_fields)
          ::IssueCustomField.visible(@actor).each_with_object({}) do |field, out|
            out[field.id] = field
          end
        end
      end

      # `{ issue_id => Float }`, and ZERO rather than nil for an issue with no visible
      # time entries: `{{ issue.spent_hours | plus: 1 }}` on nil is a different number
      # from the same expression on 0.0, and the second one is the true one.
      #
      # `TimeEntry.visible(actor)` rather than a bare `where(issue_id:)`. Redmine's own
      # `Issue#spent_hours` does NOT filter — the application guards the DISPLAY with a
      # permission check instead — and a template is not a view, so the filter has to be
      # in the query or it is nowhere.
      def spent_hours(issue_id)
        resolve(:spent_hours, issue_id) do |id_set|
          ::TimeEntry.visible(@actor).where(issue_id: id_set).group(:issue_id).sum(:hours)
        end[issue_id].to_f
      end

      def attachments(issue_id)
        resolve(:attachments, issue_id) do |id_set|
          group(::Attachment.where(container_type: 'Issue', container_id: id_set)
                            .preload(:author).order(:created_on, :id), :container_id)
        end[issue_id] || []
      end

      def time_entries(issue_id)
        resolve(:time_entries, issue_id) do |id_set|
          # `:activity` and `:user` because `TimeEntryDrop` reads both, and an entry
          # list that resolved them per row would put the N+1 back one level down.
          group(::TimeEntry.visible(@actor).where(issue_id: id_set)
                           .preload(:activity, :user).order(:spent_on, :id),
                :issue_id)
        end[issue_id] || []
      end

      # Direct children only, which is what `issue.subtasks` has always meant in these
      # templates. Descendants would be a different accessor and a different query.
      #
      # `Issue.visible(actor)`, because a private child of a public parent is exactly
      # the row this must not hand back.
      def subtasks(issue_id)
        resolve(:subtasks, issue_id) do |id_set|
          group(::Issue.visible(@actor).where(parent_id: id_set).order(:id), :parent_id)
        end[issue_id] || []
      end

      # ------------------------------------------------------------------
      # The sixth key: named references
      # ------------------------------------------------------------------

      # One query per referenced CLASS, not per issue — §3.4's `:named_refs` row.
      #
      # `column` is the foreign key on `issues` that points at `klass`. Given it, the
      # whole column is resolved at once: one `SELECT DISTINCT status_id FROM issues
      # WHERE id IN (...)` and one `SELECT … WHERE id IN (…)`. Two queries, constant in
      # the number of issues, and the second is bounded by the number of DISTINCT
      # statuses rather than by the loop length.
      #
      # Without a scope — a lone `IssueDrop` built outside any collection — there is no
      # column to sweep, so it falls back to resolving the one id asked for. One query
      # for one record, which is the correct cost of a single lookup.
      #
      # NOTE ON WHY THIS IS NOT THE HOT PATH. Inside a collection, M1's preload has
      # already loaded `status`/`tracker`/`priority`/`category`/`fixed_version`, so
      # `IssueDrop` reads them off the record and never arrives here. This key serves
      # the case the preload cannot: `{{ issues[42].status }}`, where each issue is
      # fetched by id and no preload ever ran.
      def named_ref(klass, id, column: nil)
        return nil if id.nil?

        cache = (@named_refs[klass.name] ||= {})
        return cache[id] if cache.key?(id)

        @budget.check!(:batch_named_refs)
        sweep(klass, cache, column)
        cache[id] = klass.where(id: id).first unless cache.key?(id)
        cache[id]
      end

      # ------------------------------------------------------------------

      # What has actually been loaded. Not for templates — for the specs and the
      # diagnostics channel, which is how "the first touch loaded it and the other 499
      # did not" stops being a claim and becomes an assertion.
      def resolved_keys
        @cache.keys.map { |key| key.is_a?(Array) ? key.first : key }.uniq
      end

      private

      # One resolution per key per render. `fetch`-with-block would re-run on a stored
      # `nil`; `key?` is the only form that memoises a falsy answer, and the whole point
      # of this object is that the second ask costs nothing.
      #
      # --- THE SCOPELESS CASE, AND THE SILENT ZERO IT USED TO PRODUCE ---
      #
      # A Batch is normally built over a scope, and then the id set is that scope's. But
      # a `RenderContext` can legitimately have NO scope — a covering page, a preview, a
      # single issue handed to a template directly — and the first version of this
      # method resolved `ids` to `[]` there and returned `{}`. Every batched accessor
      # then answered **0.0, empty, nothing**, for an issue that had time entries and
      # custom fields, with no error and no degradation. A wrong number that looks like
      # a real number is the worst answer this layer can give.
      #
      # So with no scope the id set is the ONE id being asked about, and the memo is
      # keyed per id rather than globally: correct, and exactly as expensive as a single
      # lookup should be. With a scope, nothing changes — one query for the whole set.
      def resolve(key, issue_id)
        cache_key = scope? ? key : [key, issue_id]
        return @cache[cache_key] if @cache.key?(cache_key)

        @budget.check!(:"batch_#{key}")
        id_set = scope? ? ids : [issue_id].compact
        @cache[cache_key] = id_set.empty? ? {} : yield(id_set)
      end

      # `CustomField.visible` answers "may this actor see this field ANYWHERE"; this
      # answers "…in THIS project", which is the question INV-3 actually asks. Redmine's
      # own `IssueCustomField#visible_by?` is the implementation — copied conditions
      # drift, and this one has drifted across four Redmine branches already.
      #
      # Memoised per (field, project) because `visible_by?` reaches
      # `User#roles_for_project`, and a 5 000-issue loop over ten projects should ask
      # ten times rather than five thousand.
      #
      # FAIL CLOSED: a field id that is not in the visible set at all is refused here
      # too, so a value that slipped past the query filter still cannot be printed.
      def visible_field?(field_id, project)
        field = visible_custom_fields[field_id]
        return false if field.nil?

        key = [field_id, project&.id]
        return @field_visibility[key] if @field_visibility.key?(key)

        @field_visibility[key] = field.visible_by?(project, @actor)
      end

      def sweep(klass, cache, column)
        return if column.nil? || @scope.nil? || ids.empty?

        referenced = @scope.where(id: ids).reorder(nil).distinct.pluck(column).compact
        return if referenced.empty?

        klass.where(id: referenced).each { |record| cache[record.id] = record }
        referenced.each { |ref_id| cache[ref_id] = nil unless cache.key?(ref_id) }
      end

      def group(relation, column)
        relation.group_by { |record| record.public_send(column) }
      end

      def degrade(code, detail: nil, **data)
        @diagnostics&.degrade(code, detail: detail, **data)
      end
    end
  end
end
