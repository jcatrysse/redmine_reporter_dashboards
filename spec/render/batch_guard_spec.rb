# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/render/batch_guard'
require_relative '../../lib/redmine_reporter_dashboards/render/document_request'

module RedmineReporterDashboards
  module Render
    RSpec.describe BatchGuard do
      # Counts what it was asked to do. The whole point of several examples below is
      # that this number is ZERO — "a refusal that first renders 200 PDFs is not a
      # refusal" is a statement about call counts, and reading the code cannot check it.
      class CountingRenderer
        attr_reader :calls

        def initialize(delay_ms: 0)
          @calls = []
          @delay_ms = delay_ms
        end

        def render(request)
          @calls << request.correlation_id
          sleep(@delay_ms / 1000.0) if @delay_ms.positive?
          Success.new(bytes: "%PDF-1.4\n#{'x' * 2000}\n%%EOF", engine: :fake,
                      engine_version: 'test')
        end
      end

      def requests(count)
        Array.new(count) do |i|
          DocumentRequest.new(body: '<html></html>', correlation_id: "doc-#{i + 1}")
        end
      end

      describe 'the cap' do
        subject(:guard) { described_class.new(max_documents: 5) }

        # THE ASSERTION T-15 IS WRITTEN AROUND.
        it 'refuses a batch over the cap without drawing a single document' do
          renderer = CountingRenderer.new

          result = guard.render_all(requests(6), renderer: renderer)

          expect(result).to be_refused
          expect(renderer.calls).to be_empty, 'the renderer was reached before the refusal'
          expect(result.results).to be_empty
        end

        it 'names the cap AND the actual count, so both parties know what to do' do
          result = guard.render_all(requests(84), renderer: CountingRenderer.new)

          expect(result.refusal.code).to eq(:resource_limit)
          expect(result.refusal.message).to include('84')
          expect(result.refusal.message).to include('5')
          expect(result.refusal.detail).to include('requested=84')
        end

        # AT the cap and ONE PAST it, because an off-by-one here is the difference
        # between a documented cap of 5 and a real cap of 4 — and the person who finds
        # that out is a user whose export of exactly 5 stopped working.
        it 'allows exactly the cap' do
          renderer = CountingRenderer.new

          result = guard.render_all(requests(5), renderer: renderer)

          expect(result).not_to be_refused
          expect(renderer.calls.length).to eq(5)
        end

        it 'refuses exactly one past the cap' do
          renderer = CountingRenderer.new

          expect(guard.render_all(requests(6), renderer: renderer)).to be_refused
          expect(renderer.calls).to be_empty
        end

        it 'lets an empty batch through rather than treating it as a special case' do
          expect(guard.render_all([], renderer: CountingRenderer.new)).not_to be_refused
        end

        it 'refuses to be constructed with a cap of zero, which would refuse everything' do
          expect { described_class.new(max_documents: 0) }.to raise_error(ArgumentError, /positive/)
        end
      end

      # T-23 made the cap check public and added a count-only form. The guarantee this
      # class makes is unchanged — `render_all` still asks before it iterates, and the
      # iteration is still in here — but the first real caller has a pipeline of its own
      # in FRONT of the renderer: a per-record report renders one Liquid template per
      # issue before there is a `DocumentRequest` to hand over. A cap that only guards the
      # second half of a pipeline is not a cap.
      describe 'the cap asked in advance' do
        subject(:guard) { described_class.new(max_documents: 5) }

        it 'answers nil at the cap and a refusal one past it, from a count alone' do
          expect(guard.cap_refusal_for_count(5)).to be_nil
          expect(guard.cap_refusal_for_count(6)).to be_a(RedmineReporterDashboards::Render::Failure)
        end

        it 'names both numbers, exactly as the list form does' do
          from_count = guard.cap_refusal_for_count(84)
          from_list = guard.cap_refusal(Array.new(84))

          expect(from_count.message).to eq(from_list.message)
          expect(from_count.message).to include('84 documents', 'the limit is 5')
        end

        it 'is the SAME check `render_all` makes, so the two cannot drift' do
          # If `render_all` grew its own copy of the comparison, a caller that asked in
          # advance and a caller that did not would disagree about the cap — and the one
          # that asked would look like the broken one.
          refused = guard.render_all(Array.new(6), renderer: CountingRenderer.new)

          expect(refused.refusal.message).to eq(guard.cap_refusal_for_count(6).message)
        end

        it 'answers nil for a count of zero rather than treating it as special' do
          expect(guard.cap_refusal_for_count(0)).to be_nil
        end

        it 'takes a correlation id from the caller, because the caller has one' do
          expect(guard.cap_refusal_for_count(9, correlation_id: 'cid-7').correlation_id)
            .to eq('cid-7')
        end

        it 'refuses a count it cannot read as an integer rather than comparing a string' do
          # `'6' > 5` raises in Ruby and `Integer('six')` says why. Silently coercing
          # would make a cap of 5 pass a batch of "60".
          expect { guard.cap_refusal_for_count('six') }.to raise_error(ArgumentError)
        end
      end

      describe 'the batch deadline' do
        # A DIFFERENT FAILURE FROM THE CAP, and the difference is whether the limit was
        # knowable in advance. The cap refuses the whole batch before any work; the
        # deadline keeps what is finished and refuses the rest.
        it 'stops rendering when the batch deadline passes, and keeps what is done' do
          guard = described_class.new(max_documents: 50, batch_timeout_ms: 120)
          renderer = CountingRenderer.new(delay_ms: 50)

          result = guard.render_all(requests(10), renderer: renderer)

          expect(result).not_to be_refused, 'the deadline is not an up-front refusal'
          expect(renderer.calls.length).to be < 10, 'it kept going past the deadline'
          expect(result.successes.length).to eq(renderer.calls.length)
          expect(result.results.length).to eq(10), 'every request needs an answer of some kind'
        end

        it 'answers the undrawn documents with a typed timeout naming the progress' do
          guard = described_class.new(max_documents: 50, batch_timeout_ms: 120)
          renderer = CountingRenderer.new(delay_ms: 50)

          result = guard.render_all(requests(10), renderer: renderer)
          refused = result.failures

          expect(refused).not_to be_empty
          expect(refused.map(&:code).uniq).to eq([:timeout])
          expect(refused.first.message).to match(/ran out of time after \d+ of 10/)
        end

        # The correlation id has to survive onto the refusal, or a user asking "what
        # happened to report 7" cannot be answered from the log.
        it 'carries each undrawn document its own correlation id' do
          guard = described_class.new(max_documents: 50, batch_timeout_ms: 60)
          result = guard.render_all(requests(6), renderer: CountingRenderer.new(delay_ms: 40))

          ids = result.failures.map(&:correlation_id)
          expect(ids).to all(match(/\Adoc-\d+\z/))
          expect(ids.uniq.length).to eq(ids.length)
        end
      end

      describe 'what a caller gets back' do
        it 'separates successes from failures without the caller inspecting classes' do
          guard = described_class.new(max_documents: 50, batch_timeout_ms: 100)
          result = guard.render_all(requests(2), renderer: CountingRenderer.new)

          expect(result.successes.length).to eq(2)
          expect(result.failures).to be_empty
          expect(result.rendered_count).to eq(2)
        end

        it 'reports a refusal as refused rather than as two failed documents' do
          guard = described_class.new(max_documents: 1)
          result = guard.render_all(requests(2), renderer: CountingRenderer.new)

          expect(result).to be_refused
          expect(result.failures).to be_empty,
                                     'a refused batch has no per-document failures — nothing was attempted'
        end
      end
    end
  end
end
