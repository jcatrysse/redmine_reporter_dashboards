# frozen_string_literal: true

require_relative '../lib/redmine_reporter_dashboards/liquid/tag_params'

# CURATOR DECISION #3, AGAINST THE REAL LIQUID GEM, UNDER BOTH MAJORS.
#
# --- Why this file exists, and it is a finding rather than a flourish ---
#
# The quoting rule was built and mutation-tested entirely against the STUB context in
# `spec/spec_helper.rb`, whose `#[]` is a plain scope lookup. The real `Liquid::Context#[]`
# is not: it parses the key as an EXPRESSION, so it also resolves literals (`"7"`, `true`,
# `nil`), numerics, dotted paths (`a.b`) and bracket paths (`a["b"]`) — and it caches by
# that parsed expression. Every `TagParams` example, every tag-parameter example and all
# fourteen mutations ran against the simpler one; an independent review pointed out that
# `880c783`'s verification line quoted "spec_liquid 346 / 0 on Liquid 4.0.4 AND 5.13.0"
# beside a change that spec_liquid did not touch.
#
# It does not, in fact, differ — that is what these examples establish rather than assume,
# and they establish it on BOTH majors, which is the only place a difference between them
# could show up. The half that matters is the QUOTED one: a quoted value must not reach
# `Context#[]` at all, because the real context WOULD have an answer for several spellings
# the stub returns nil for.
module RedmineReporterDashboards
  module Liquid
    RSpec.describe TagParams do
      # The real thing, built the way a tag receives it.
      def context(assigns = {})
        ::Liquid::Context.new({}, assigns)
      end

      describe 'the quoted half — never looked up' do
        # THE DEFECT ITSELF, on the real context. `user` is assigned in every report.
        it 'answers the text even when the real context has a variable of that name' do
          params = described_class.parse('group_by: "user"')

          expect(described_class.resolve(params['group_by'], context('user' => 'Redmine Admin')))
            .to eq('user')
        end

        # THE SPELLINGS THE STUB CANNOT DISTINGUISH. `Context#[]` parses its key as an
        # expression, so each of these has a real, non-nil answer — and the rule says none
        # of them is consulted. Under the stub these all returned nil and fell back to the
        # literal, so the examples in `spec/` pass for the wrong reason.
        {
          'query_id: "7"' => %w[query_id 7],
          'group_by: "true"' => %w[group_by true],
          'group_by: "nil"' => %w[group_by nil],
          'other_label: "blank"' => %w[other_label blank]
        }.each do |markup, (key, expected)|
          it "does not evaluate #{markup.inspect} as a Liquid expression" do
            params = described_class.parse(markup)

            expect(described_class.resolve(params[key], context)).to eq(expected)
          end
        end
      end

      describe 'the bare half — resolved through the real context' do
        it 'reads a variable' do
          params = described_class.parse('group_by: gb')

          expect(described_class.resolve(params['group_by'], context('gb' => 'tracker')))
            .to eq('tracker')
        end

        it 'falls back to the literal when there is no such variable' do
          params = described_class.parse('group_by: tracker')

          expect(described_class.resolve(params['group_by'], context)).to eq('tracker')
        end

        # A DOTTED PATH RESOLVES ON THE REAL CONTEXT AND NOT ON THE STUB, which is the
        # clearest single difference between the two harnesses. `PARAM_RE`'s bare branch is
        # `[^\s,]+`, so a dot is part of the value and reaches `Context#[]` intact.
        it 'reads a dotted path, which the stub context cannot' do
          params = described_class.parse('group_by: cfg.dimension')

          expect(described_class.resolve(params['group_by'],
                                         context('cfg' => { 'dimension' => 'status' })))
            .to eq('status')
        end

        # ...and QUOTING THE SAME PATH turns it off, which is the rule doing the one thing
        # it exists to do on a spelling that genuinely resolves.
        it 'does not read a QUOTED dotted path' do
          params = described_class.parse('group_by: "cfg.dimension"')

          expect(described_class.resolve(params['group_by'],
                                         context('cfg' => { 'dimension' => 'status' })))
            .to eq('cfg.dimension')
        end

        # `false` AND `0` ARE VALUES, not absences — `resolve` branches on `.nil?`. The real
        # context returns them as real objects, so this is where it is worth pinning.
        it 'treats a resolved false as a value' do
          params = described_class.parse('drill: flag')

          expect(described_class.resolve(params['drill'], context('flag' => false)))
            .to eq('false')
        end
      end

      # `Value` IS A STRING SUBCLASS, and the real `Context#[]` does more with its key than
      # the stub: it parses and CACHES by it. A subclass key must not change what is looked
      # up or what comes back.
      describe 'Value against the real Context' do
        it 'looks up identically to the plain String it equals' do
          ctx = context('gb' => 'tracker')
          value = described_class.parse('group_by: gb').fetch('group_by')

          expect(ctx[value.to_s]).to eq(ctx['gb'])
        end

        it 'never comes back out of resolve' do
          params = described_class.parse('other_label: "Rest"')

          expect(described_class.resolve(params['other_label'], context).class).to be(::String)
        end
      end
    end
  end
end
