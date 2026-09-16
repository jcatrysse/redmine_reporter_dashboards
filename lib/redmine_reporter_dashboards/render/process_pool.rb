# frozen_string_literal: true

module RedmineReporterDashboards
  module Render
    # A pool of render processes, SIZE 1 BY DEFAULT, with a bounded queue.
    #
    # --- WHY ONE, AND WHY BOUNDED ---
    #
    # A headless browser costs 150–400 MB resident while it draws. Sizing this pool by
    # CPU count, the way one would size a thread pool, is how a Redmine host with eight
    # cores discovers at month-end that eight simultaneous report renders is the same
    # thing as an out-of-memory kill — and the OOM killer does not pick the browser, it
    # picks the biggest process, which is Puma.
    #
    # So: one browser, a queue with a limit, and a wait with a deadline. Past that
    # deadline the caller gets `Failure(:engine_unavailable)` and can say "the report
    # service is busy, try again" — which is an operable answer. *A refusal is operable;
    # a timeout is not.* A request that hangs holds a Puma thread, and enough of them
    # take the whole application down for something that was only ever a queue.
    #
    # --- WORKERS ARE DISCARDED ON FAILURE, NOT RETURNED ---
    #
    # If the block raises, the process is assumed poisoned and is stopped rather than
    # handed to the next caller. That is the wedged-renderer case: a template with a
    # synchronous infinite loop leaves a browser whose main thread will never answer
    # again, and returning it to the pool means every subsequent render inherits the
    # first one's failure. One bad report would take the queue down behind it.
    class ProcessPool
      DEFAULT_SIZE = 1
      DEFAULT_QUEUE_LIMIT = 8
      DEFAULT_QUEUE_TIMEOUT_MS = 10_000

      class Busy < StandardError; end

      attr_reader :size, :queue_limit, :queue_timeout_ms

      # `factory` builds one worker; `stopper` is how a worker is disposed of. Both are
      # injected so this class knows nothing about browsers — it is a pool, and the one
      # thing it must not grow is knowledge of what it is pooling.
      def initialize(size: DEFAULT_SIZE, queue_limit: DEFAULT_QUEUE_LIMIT,
                     queue_timeout_ms: DEFAULT_QUEUE_TIMEOUT_MS, factory:, stopper: nil)
        @size = Integer(size)
        @queue_limit = Integer(queue_limit)
        @queue_timeout_ms = Integer(queue_timeout_ms)
        @factory = factory
        @stopper = stopper || ->(worker) { worker.stop if worker.respond_to?(:stop) }

        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @idle = []
        @live = 0
        @waiting = 0
        @closed = false
      end

      def with_worker(queue_timeout_ms: nil)
        worker = checkout(queue_timeout_ms || @queue_timeout_ms)
        begin
          result = yield worker
        rescue StandardError
          discard(worker)
          raise
        end
        checkin(worker)
        result
      end

      def stats
        @mutex.synchronize { { live: @live, idle: @idle.length, waiting: @waiting } }
      end

      def shutdown
        workers = @mutex.synchronize do
          @closed = true
          taken = @idle.dup
          @idle.clear
          @live -= taken.length
          @condition.broadcast
          taken
        end
        workers.each { |worker| stop_quietly(worker) }
      end

      private

      def checkout(timeout_ms)
        deadline = monotonic + (timeout_ms / 1000.0)

        slot = @mutex.synchronize do
          raise Busy, 'the render pool has been shut down' if @closed

          # REFUSED BEFORE IT IS QUEUED. A queue that accepts everything and times out
          # later has already spent the caller's patience by the time it says no.
          if @waiting >= @queue_limit
            raise Busy,
                  "the render queue is full (#{@waiting} waiting, limit #{@queue_limit}). " \
                  'Refusing now rather than accepting work there is no capacity for.'
          end

          @waiting += 1
          begin
            acquire(deadline, timeout_ms)
          ensure
            @waiting -= 1
          end
        end

        slot == :new ? build : slot
      end

      # Split out of `checkout` so that `return` means "leave this method" rather than
      # "leave `checkout`, skipping everything after the synchronize block". A `return`
      # inside a block returns from the enclosing METHOD, and the first draft of this
      # file did exactly that — handing back the `:new` sentinel instead of a browser.
      def acquire(deadline, timeout_ms)
        loop do
          return @idle.pop unless @idle.empty?

          if @live < @size
            @live += 1
            return :new
          end

          remaining = deadline - monotonic
          raise Busy, "no render slot within #{timeout_ms}ms" if remaining <= 0

          @condition.wait(@mutex, remaining)
          raise Busy, 'the render pool has been shut down' if @closed
        end
      end

      # Built OUTSIDE the lock. Launching a browser takes a couple of hundred
      # milliseconds, and holding the pool's mutex across it would serialise every
      # caller behind the slowest possible operation the pool ever performs.
      def build
        @factory.call
      rescue StandardError
        @mutex.synchronize do
          @live -= 1
          @condition.signal
        end
        raise
      end

      def checkin(worker)
        @mutex.synchronize do
          if @closed
            @live -= 1
          else
            @idle.push(worker)
          end
          @condition.signal
        end
        stop_quietly(worker) if @closed
      end

      def discard(worker)
        @mutex.synchronize do
          @live -= 1
          @condition.signal
        end
        stop_quietly(worker)
      end

      def stop_quietly(worker)
        @stopper.call(worker)
      rescue StandardError
        # A worker that cannot be stopped cleanly must not mask the error that is
        # already on its way up. The process is killed either way.
        nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
