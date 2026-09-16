# frozen_string_literal: true

# THE REAL LIQUID GEM, not the stub.
#
# `spec/spec_helper.rb` defines a minimal `Liquid` stub so the DB-less specs can load
# tags without the gem. That stub and the real gem cannot coexist in one process —
# whichever is defined first wins, and the tag specs are written against the stub's
# constructor. So this directory is run as its OWN rspec invocation with the gem
# required first:
#
#     bundle exec rspec -r liquid spec_liquid
#
# and it skips, with that command in the reason, when it finds the stub instead. The
# `rspec` CI job runs both, as two steps. Migrating the tag specs onto the real gem is
# a task of its own (§Findings E-7) and deliberately not this one.
require 'liquid'

require_relative '../lib/redmine_reporter_dashboards/liquid/execution_policy'

module RedmineReporterDashboards
  module Liquid
    RSpec.describe ExecutionPolicy do
      before do
        skip 'run with the real gem: rspec -r liquid spec_liquid' unless
          defined?(::Liquid::VERSION)
      end

      describe 'the output classes' do
        it 'gives a widget the tightest limits and the shortest deadline' do
          policy = described_class.widget

          expect(policy.render_length_limit).to eq(2_000_000)
          expect(policy.render_score_limit).to eq(200_000)
          expect(policy.deadline_ms).to eq(5_000)
        end

        it 'gives a report room a quarterly issue list actually needs' do
          policy = described_class.report

          expect(policy.render_length_limit).to eq(16_000_000)
          expect(policy.deadline_ms).to eq(30_000)
        end

        # The line in the table that looks like a mistake and is not: an author should
        # feel the limit at the keyboard, not at 06:00 in a scheduled run.
        it 'holds a preview to the WIDGET limits, deliberately' do
          expect(described_class.preview.render_length_limit)
            .to eq(described_class.widget.render_length_limit)
          expect(described_class.preview.render_score_limit)
            .to eq(described_class.widget.render_score_limit)
        end

        it 'gives a preview longer than a widget, because a human is waiting on purpose' do
          expect(described_class.preview.deadline_ms).to be > described_class.widget.deadline_ms
        end

        # An unknown class must not quietly select the most generous profile.
        it 'refuses an output class it does not know' do
          expect { described_class.new(:enormous) }
            .to raise_error(described_class::UnknownOutputClass, /not an output class/)
        end

        it 'lets a deployment tighten the deadline but not the resource limits' do
          policy = described_class.report(deadline_ms: 5_000)

          expect(policy.deadline_ms).to eq(5_000)
          expect(policy.render_length_limit).to eq(16_000_000)
          expect(described_class.instance_methods).not_to include(:render_length_limit=)
        end
      end

      describe 'the error mode' do
        it 'parses strictly, so an unknown filter is loud rather than blank' do
          expect(described_class.widget.error_mode).to eq(:strict)
          expect(described_class.widget.strict_filters?).to be(true)
        end

        # `{{ issue.due_date }}` on an issue without one is ordinary, not an error.
        it 'does not require every optional field to be guarded' do
          expect(described_class.widget.strict_variables?).to be(false)
        end
      end

      describe 'the resource limits object' do
        it 'is a real Liquid::ResourceLimits carrying the policy numbers' do
          limits = described_class.widget.resource_limits

          expect(limits).to be_a(::Liquid::ResourceLimits)
        end

        # ACCUMULATION is the reason this is built per render. A shared instance would
        # charge the second render for the first one's work.
        it 'is a fresh object every time it is asked for' do
          policy = described_class.widget

          expect(policy.resource_limits).not_to equal(policy.resource_limits)
        end

        # The property the whole design rests on, asserted against the real gem rather
        # than assumed from its documentation.
        # The limits are handed to the CONTEXT, not to the template, and that is the
        # only per-render channel Liquid 4 or 5 offers — the alternative,
        # `Template.default_resource_limits`, is global and would mean a widget's
        # limits applying to whatever report rendered next on the same process. This
        # asserts the mechanism against the real gem rather than trusting its docs.
        #
        # A tiny limit is built inline rather than by stubbing the policy: the policy is
        # frozen, which is itself a property worth having.
        it 'actually stops an over-long render, through the context' do
          template = ::Liquid::Template.parse('{{ x }}{{ x }}{{ x }}', error_mode: :strict)
          context = ::Liquid::Context.new(
            [{ 'x' => 'a' * 10 }], {}, {}, true,
            ::Liquid::ResourceLimits.new(render_length_limit: 20)
          )

          expect { template.render(context) }.to raise_error(::Liquid::MemoryError)
        end

        it 'is frozen, so nobody raises a limit at a call site' do
          expect(described_class.widget).to be_frozen
        end
      end
    end

    RSpec.describe Budget do
      before do
        skip 'run with the real gem: rspec -r liquid spec_liquid' unless
          defined?(::Liquid::VERSION)
      end

      # A controllable clock, because a deadline spec that sleeps is a deadline spec
      # that is slow and flaky at the same time.
      def budget_at(now, deadline_ms: 1_000)
        time = now
        described_class.new(deadline_ms: deadline_ms, clock: -> { time })
      end

      it 'has time left before the deadline' do
        clock = 0.0
        budget = described_class.new(deadline_ms: 1_000, clock: -> { clock })

        expect(budget.exceeded?).to be(false)
        expect(budget.check!('sql_aggregate')).to be(true)
        expect(budget.remaining_ms).to eq(1_000)
      end

      # The exception names WHERE the time ran out. "at sql_aggregate" and "at
      # collection_batch" send whoever reads it to different places; "timed out" sends
      # them nowhere.
      it 'raises at the checkpoint that ran out, and says which one' do
        clock = 0.0
        budget = described_class.new(deadline_ms: 1_000, clock: -> { clock })
        clock = 1_500.0

        expect { budget.check!('collection_batch') }
          .to raise_error(described_class::DeadlineExceeded, /collection_batch/) do |error|
            expect(error.checkpoint).to eq('collection_batch')
            expect(error.deadline_ms).to eq(1_000)
            expect(error.elapsed_ms).to be >= 1_000
          end
      end

      it 'never reports negative time remaining' do
        clock = 0.0
        budget = described_class.new(deadline_ms: 100, clock: -> { clock })
        clock = 5_000.0

        expect(budget.remaining_ms).to eq(0)
      end

      # THE PROPERTY THAT MAKES IT SAFE TO PUT THE CALL IN A TAG TODAY. These tags still
      # run inside the host plugin's renderer, which binds no budget; a version that
      # raised on a missing one would make adding the call site a behaviour change for
      # every existing install.
      describe 'when no budget is bound' do
        it 'answers a null budget rather than nil, so no call site needs a nil check' do
          context = ::Liquid::Context.new([{}], {}, {}, true)

          budget = described_class.from(context)

          expect(budget.check!('anything')).to be(true)
          expect(budget.exceeded?).to be(false)
        end

        it 'answers a null budget for a context with no registers at all' do
          expect(described_class.from(Object.new).check!('anything')).to be(true)
        end

        # Type-checked, not duck-typed: something else parked under that key must not
        # be mistaken for a budget.
        it 'ignores anything under its key that is not a budget' do
          context = ::Liquid::Context.new([{}], {}, { described_class::REGISTER_KEY => 'nope' }, true)

          expect(described_class.from(context)).to equal(described_class::NULL)
        end
      end

      it 'is found through the register when one is bound' do
        mine = described_class.new(deadline_ms: 1_000)
        context = ::Liquid::Context.new([{}], {}, { described_class::REGISTER_KEY => mine }, true)

        expect(described_class.from(context)).to equal(mine)
      end
    end
  end
end
