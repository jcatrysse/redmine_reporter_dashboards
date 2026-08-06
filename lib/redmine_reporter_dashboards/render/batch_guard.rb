# frozen_string_literal: true

require_relative 'failure'
require_relative 'result'

module RedmineReporterDashboards
  module Render
    # The caps, made MECHANICAL rather than remembered.
    #
    # --- WHY THIS IS AN OBJECT AND NOT A GUARD CLAUSE ---
    #
    # "Refuse a batch over the cap" is trivially expressible as an `if` at the top of a
    # controller action, and that is exactly how it gets lost: the second caller does
    # not have the `if`, and the second caller is the scheduler at 3 a.m. So the cap
    # does not live beside the render loop, it OWNS the render loop. There is no way to
    # reach the adapter through this class without having passed the check, because the
    # check happens before the iteration starts and the iteration is in here.
    #
    # `technical-spec.md` §7's phrasing is the test: *"a refusal that first renders 200
    # PDFs is not a refusal"*. The spec for that is `#render_all` calling the renderer
    # zero times when the count is over — asserted with a double that counts calls, not
    # by reading the code.
    #
    # --- TWO DIFFERENT LIMITS, AND THEY FAIL DIFFERENTLY ---
    #
    #   the CAP        known before any work starts  -> refuse the whole batch, 422-shaped
    #   the DEADLINE   discovered while working      -> keep what is finished, refuse the rest
    #
    # Collapsing them would mean either refusing a batch that would have finished, or
    # discovering at document 199 that the answer was always no. The first is rude and
    # the second is expensive, and the difference between them is whether the limit was
    # knowable in advance.
    class BatchGuard
      # Fifty A4 reports is already a 20-30 MB archive and a minute of browser time.
      # The number is a default and not a truth — it exists so that an install which
      # never thinks about this still has an answer, and so that the one which does has
      # somewhere to put theirs.
      DEFAULT_MAX_DOCUMENTS = 50

      # Five minutes for a whole batch. Long enough that a legitimate quarterly export
      # finishes; short enough that a wedged one is noticed by a human rather than by a
      # monitoring alert about a saturated worker pool.
      DEFAULT_BATCH_TIMEOUT_MS = 300_000

      attr_reader :max_documents, :batch_timeout_ms

      def initialize(max_documents: DEFAULT_MAX_DOCUMENTS,
                     batch_timeout_ms: DEFAULT_BATCH_TIMEOUT_MS, logger: nil)
        @max_documents = Integer(max_documents)
        @batch_timeout_ms = Integer(batch_timeout_ms)
        @logger = logger
        raise ArgumentError, 'max_documents must be positive' unless @max_documents.positive?

        freeze
      end

      # The result of a whole batch. `refused?` is the up-front arm — nothing was drawn
      # and nothing was spent — and it is deliberately a different question from "did
      # any document fail", because an operator needs to tell "you asked for too much"
      # apart from "one of your reports is broken".
      class BatchResult
        attr_reader :results, :refusal, :rendered_count, :duration_ms

        def initialize(results:, refusal: nil, rendered_count: 0, duration_ms: 0)
          @results = results.freeze
          @refusal = refusal
          @rendered_count = rendered_count
          @duration_ms = duration_ms
          freeze
        end

        def refused?
          !refusal.nil?
        end

        def failures
          results.select { |result| result.is_a?(Failure) }
        end

        def successes
          results.select { |result| result.is_a?(Success) }
        end
      end

      # THE ONLY WAY THROUGH. `renderer` is anything answering `#render(request)` —
      # normally `Render::Renderer`, and in the specs a double that counts its calls.
      def render_all(requests, renderer:)
        list = Array(requests)
        started = monotonic_ms

        if (refusal = cap_refusal(list))
          # ZERO CALLS TO THE RENDERER. The return happens before the loop exists.
          return BatchResult.new(results: [], refusal: refusal)
        end

        deadline = started + batch_timeout_ms
        results = []
        rendered = 0

        list.each_with_index do |request, index|
          if monotonic_ms >= deadline
            # Everything from here on is refused WITHOUT being drawn. The documents
            # already finished are kept: a batch that took too long has still produced
            # real work, and throwing it away helps nobody.
            warn_line("[render] batch deadline of #{batch_timeout_ms}ms reached after " \
                      "#{rendered} of #{list.length} document(s)")
            results.concat(deadline_refusals(list[index..], rendered, list.length))
            break
          end

          results << renderer.render(request)
          rendered += 1
        end

        BatchResult.new(results: results, rendered_count: rendered,
                        duration_ms: (monotonic_ms - started).round)
      end

      private

      # AT the cap is allowed; one past it is not. Written as `>` rather than `>=` on
      # purpose, and tested at both — an off-by-one here is the difference between a
      # documented cap of 50 and a real cap of 49, and the person who finds that out is
      # a user whose export of exactly 50 reports stopped working.
      def cap_refusal(list)
        return nil unless list.length > max_documents

        warn_line("[render] refusing a batch of #{list.length}; the cap is #{max_documents}")
        Failure.new(
          code: :resource_limit,
          # NAMES BOTH NUMBERS. "Too many documents" tells a user nothing they can act
          # on; "you asked for 84 and the limit is 50" tells them to select fewer, and
          # tells their administrator what to raise.
          message: "this export asks for #{list.length} documents and the limit is " \
                   "#{max_documents}; select fewer, or ask an administrator to raise the limit",
          detail: "requested=#{list.length} max_documents=#{max_documents}",
          correlation_id: correlation_id_for(list)
        )
      end

      def deadline_refusals(remaining, rendered, total)
        remaining.map do |request|
          Failure.new(
            code: :timeout,
            message: "the export ran out of time after #{rendered} of #{total} documents",
            detail: "batch_timeout_ms=#{batch_timeout_ms} rendered=#{rendered} total=#{total}",
            correlation_id: request.respond_to?(:correlation_id) ? request.correlation_id : nil
          )
        end
      end

      # A refusal is about the batch, not about one document, so it borrows the first
      # request's id rather than inventing one — that is the id the caller already has
      # in its own log line.
      def correlation_id_for(list)
        first = list.first
        first.respond_to?(:correlation_id) ? first.correlation_id : 'batch'
      end

      def warn_line(line)
        @logger.warn(line) if @logger.respond_to?(:warn)
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      end
    end
  end
end
