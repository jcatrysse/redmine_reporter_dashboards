# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/render/process_pool'

module RedmineReporterDashboards
  module Render
    RSpec.describe ProcessPool do
      # A worker that records what happened to it. Nothing here launches anything: the
      # pool's whole job is to be right about counting, waiting and disposing, and a
      # browser in these examples would only add flakiness to arithmetic.
      class CountingWorker
        attr_reader :id
        attr_accessor :stopped

        def initialize(id)
          @id = id
          @stopped = false
        end

        def stop
          @stopped = true
        end
      end

      def build_pool(**options)
        made = 0
        pool = described_class.new(factory: -> { CountingWorker.new(made += 1) }, **options)
        [pool, -> { made }]
      end

      it 'creates at most `size` workers, however many callers there are' do
        pool, made = build_pool(size: 1)

        seen = 4.times.map { pool.with_worker { |w| w.id } }

        expect(seen).to eq([1, 1, 1, 1])
        expect(made.call).to eq(1)
      end

      it 'serialises callers when the pool holds one process' do
        pool, = build_pool(size: 1)
        order = []
        mutex = Mutex.new

        threads = 3.times.map do |i|
          Thread.new do
            pool.with_worker do
              mutex.synchronize { order << [:in, i] }
              sleep 0.05
              mutex.synchronize { order << [:out, i] }
            end
          end
        end
        threads.each(&:join)

        # No caller's :in appears between another's :in and :out. That is what "a pool
        # of one" has to mean; a count of created workers alone would not prove it.
        expect(order.each_slice(2).map { |pair| pair.map(&:first) })
          .to eq([%i[in out], %i[in out], %i[in out]])
      end

      # A REFUSAL IS OPERABLE; A TIMEOUT IS NOT. The caller can tell a user the report
      # service is busy. It can do nothing at all with a request that never returns.
      it 'refuses rather than waiting once the queue limit is reached' do
        pool, = build_pool(size: 1, queue_limit: 1, queue_timeout_ms: 5_000)
        held = Queue.new
        release = Queue.new

        holder = Thread.new { pool.with_worker { held << :held; release.pop } }
        held.pop
        # One waiter fills the queue…
        waiter = Thread.new do
          pool.with_worker { :ok }
        rescue described_class::Busy
          :busy
        end
        sleep 0.05

        # …so the next caller is refused immediately rather than queued behind it.
        expect { pool.with_worker { :never } }.to raise_error(described_class::Busy, /queue is full/)

        release << :go
        holder.join
        waiter.join
      end

      it 'gives up on a slot after the queue timeout, naming the wait' do
        pool, = build_pool(size: 1, queue_timeout_ms: 60)
        release = Queue.new
        held = Queue.new

        holder = Thread.new { pool.with_worker { held << :held; release.pop } }
        held.pop

        expect { pool.with_worker { :never } }
          .to raise_error(described_class::Busy, /no render slot within 60ms/)

        release << :go
        holder.join
      end

      # THE WEDGED-RENDERER CASE. A template with a synchronous infinite loop leaves a
      # browser whose main thread will never answer again. Returning it to the pool
      # means every render behind it inherits the first one's failure — one bad report
      # taking the queue down with it.
      it 'discards a worker whose block raised, and stops it' do
        pool, made = build_pool(size: 1)
        first = nil

        pool.with_worker { |w| first = w }
        expect { pool.with_worker { raise 'wedged' } }.to raise_error('wedged')
        second = pool.with_worker { |w| w }

        expect(first.stopped).to be(true)
        expect(second).not_to equal(first)
        expect(made.call).to eq(2)
      end

      it 'does not leak a slot when the factory itself fails' do
        attempts = 0
        pool = described_class.new(size: 1, queue_timeout_ms: 100, factory: lambda {
          attempts += 1
          raise 'no browser here'
        })

        2.times { expect { pool.with_worker { :never } }.to raise_error('no browser here') }

        # The second attempt got as far as the factory, which it could only do if the
        # first attempt's slot was returned. A pool that leaked it would have answered
        # Busy instead.
        expect(attempts).to eq(2)
      end

      it 'stops every idle worker on shutdown and refuses afterwards' do
        pool, = build_pool(size: 2)
        workers = []
        2.times { pool.with_worker { |w| workers << w } }

        pool.shutdown

        expect(workers.map(&:stopped)).to all(be(true))
        expect { pool.with_worker { :never } }.to raise_error(described_class::Busy, /shut down/)
      end
    end
  end
end
