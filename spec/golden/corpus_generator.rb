# frozen_string_literal: true

require_relative 'corpus'
require_relative 'corpus_cases'
require_relative 'corpus_canonicaliser'

module RrdGolden
  # Runs the declared case matrix against a real database and turns each answer into
  # one canonical corpus record.
  #
  # Generation and verification go through THIS ONE method. A generator that wrote the
  # file and a verifier that rebuilt the expected value its own way would be two
  # implementations of the contract, and the day they disagreed the corpus would fail
  # on the difference between them rather than on a change in the numbers.
  #
  # Requires the adapter harness: it needs real ActiveRecord, the seeded fixture, the
  # frozen clock and the four actors. See spec/adapter/adapter_helper.rb.
  module CorpusGenerator
    class << self
      def records
        CorpusCases.all.map { |kase| record(kase) }
      end

      def record(kase)
        result = RrdAdapterHarness.as_actor(kase.actor) { invoke(kase) }

        CorpusCases.declaration(kase).merge('result' => normalise(kase, result))
      end

      # The aggregator is called exactly as a caller would, with keyword arguments —
      # not through a private helper. What is frozen has to be the public surface,
      # because that is what T-07 and T-08 re-seam.
      def invoke(kase)
        scope = scope_for(kase.scope)
        args  = kase.args.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }

        # UnsupportedAdapterError is deliberately NOT rescued: on an engine the kernel
        # has no branch for, every number in the corpus would be meaningless, so it has
        # to reach the runner rather than becoming a recorded nil.
        SqlAggregation::QueryAggregator.public_send(kase.entry, scope, **args)
      end

      def scope_for(name)
        h = RrdAdapterHarness

        case name
        when 'main'        then h.base_scope.where(project_id: h::PROJECT_MAIN)
        when 'reported'    then h.base_scope.where(project_id: [h::PROJECT_MAIN, h::PROJECT_ARCHIVED])
        when 'sweep'       then h.base_scope.where(project_id: h::PROJECT_SWEEP)
        when 'wide'        then h.base_scope.where(project_id: h::PROJECT_WIDE)
        when 'wide_at_cap'
          # Exactly MAX_DIMENSION_KEYS distinct values of CF_WIDE, by id range rather
          # than by LIMIT: a LIMIT would need an ORDER BY to be deterministic and the
          # entry points unscope order.
          h.base_scope.where(project_id: h::PROJECT_WIDE)
           .where('issues.id < ?', h::WIDE_ID_BASE + h::WIDE_AT_CAP)
        when 'closed_only'
          h.base_scope.where(project_id: h::PROJECT_MAIN, status_id: h::STATUS_CLOSED)
        when 'empty'
          # A scope that is empty by CONDITION, not by pointing at an empty project:
          # an empty project would also have no versions, no custom values and no time
          # entries, so half the empty-state answers would be empty for the wrong
          # reason.
          h.base_scope.where(project_id: h::PROJECT_MAIN).where('issues.id < 0')
        else
          raise ArgumentError, "no fixture scope named #{name.inspect}"
        end
      end

      # The two orderings the kernel does not define. Both are documented findings on
      # the case that uses them; see CorpusCases.
      def normalise(kase, result)
        case kase.normalise
        when :none then result
        when :sort_buckets then sort_buckets(result)
        when :sort_version_rows then sort_version_rows(result)
        else
          raise ArgumentError, "#{kase.id}: unknown normalisation #{kase.normalise.inspect}"
        end
      end

      # [-count, label]: a total order that still fails if the COUNT ordering
      # regresses, which is the part of .breakdown's contract that is real.
      def sort_buckets(result)
        return result unless result.is_a?(Hash) && result['buckets'].is_a?(Array)

        sorted = result['buckets'].sort_by { |bucket| [-bucket['count'].to_f, bucket['label'].to_s] }
        result.merge('buckets' => sorted)
      end

      # version_id ascending, nil last — nil is a real row (the issues with no target
      # version), so it is ordered rather than dropped.
      def sort_version_rows(result)
        return result unless result.is_a?(Array)

        result.sort_by { |row| [row['version_id'].nil? ? 1 : 0, row['version_id'].to_i] }
      end
    end
  end
end
