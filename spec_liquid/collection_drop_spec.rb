# frozen_string_literal: true

# The collection half of T-18 (`technical-spec.md` §3.2's `IssuesDrop` paragraph and
# §3.4's cap), and the diagnostics channel a truncation becomes visible through.
#
# Two properties here are the ones a reviewer should be hardest on, because both are
# the kind that pass by accident:
#
#   `all` IS REACHABLE AND REFUSED. Deleting the method would make `{{ issues.all }}`
#   render blank under `strict_variables: false`, which is a silent wrong answer — the
#   exact thing INV-4 exists to prevent. So it must be present, return nil, AND leave a
#   degradation behind. A test that only asserted "renders nothing" would pass the
#   deleted version too.
#
#   THE CAP MUST FIRE AT THE CAP AND ONE PAST IT. CLAUDE.md §3: for anything with a
#   limit, test AT the limit and ONE past it. A cap tested only far past its boundary
#   passes an off-by-one in either direction.

require 'liquid'

require_relative 'support/drop_fakes'
require_relative '../lib/redmine_reporter_dashboards/liquid/drops'

module RedmineReporterDashboards
  module Liquid
    module Drops
      RSpec.describe CollectionDrop do
        before do
          skip 'run with the real gem: rspec -r liquid spec_liquid' unless defined?(::Liquid::VERSION)
        end

        let(:actor) { DropFakes::User.new(id: 1, login: 'jane', name: 'Jane') }

        def issue(id)
          DropFakes::Record.new({ id: id, subject: "issue #{id}" }, loaded_associations: [])
        end

        let(:records) { (1..5).map { |n| issue(n) } }
        let(:relation) { DropFakes::Relation.new(records) }
        let(:batch) { DropFakes::Batch.new(limit: 3) }
        let(:context) { RenderContext.new(actor: actor, scope: relation, batch: batch) }
        let(:collection) { IssuesDrop.new(relation, context: context) }

        def render(source)
          ::Liquid::Template.parse(source, error_mode: :strict).render!('issues' => collection)
        end

        describe 'iteration' do
          let(:batch) { DropFakes::Batch.new(limit: 100) }

          it 'yields a drop per record, in order' do
            expect(render('{% for i in issues %}{{ i.id }},{% endfor %}')).to eq('1,2,3,4,5,')
          end

          it 'preloads §3.4 M1s associations before iterating' do
            render('{% for i in issues %}{% endfor %}')
            expect(IssuesDrop::PRELOADS).to include(:status, :tracker, :priority, :category,
                                                    :assigned_to, :author, :project)
          end

          # `fixed_version: :project` and not a bare `:fixed_version`: VersionDrop's
          # roadmap and issue-list URLs are keyed on the project IDENTIFIER, so a version
          # whose project is unloaded puts the N+1 back one level down.
          it 'preloads the version WITH its project' do
            expect(IssuesDrop::PRELOADS).to include(fixed_version: :project)
          end

          it 'shares ONE batch across every drop it yields — which is all of M2' do
            batches = []
            collection.each { |drop| batches << drop.send(:batch) }
            expect(batches.uniq.length).to eq(1)
            expect(batches.first).to equal(batch)
          end
        end

        describe 'the cap (§3.4)' do
          context 'UNDER the cap' do
            let(:batch) { DropFakes::Batch.new(limit: 100) }

            it 'renders every record and degrades nothing' do
              expect(render('{% for i in issues %}{{ i.id }}{% endfor %}')).to eq('12345')
              expect(context.diagnostics).not_to be_any
            end
          end

          context 'exactly AT the cap' do
            let(:records) { (1..3).map { |n| issue(n) } }

            it 'renders all three and degrades nothing' do
              expect(render('{% for i in issues %}{{ i.id }}{% endfor %}')).to eq('123')
              expect(context.diagnostics).not_to be_any
            end
          end

          context 'ONE past the cap' do
            let(:records) { (1..4).map { |n| issue(n) } }

            it 'renders three and records a visible degradation (INV-4)' do
              expect(render('{% for i in issues %}{{ i.id }}{% endfor %}')).to eq('123')
              expect(context.diagnostics).to be_include(:collection_truncated)
            end

            it 'says how many it used, so the reader can tell short from truncated' do
              collection.each { |_| nil }
              degradation = context.diagnostics.degradations.first
              expect(degradation.data).to eq('seen' => 3)
              expect(degradation.detail).to include('only the first 3')
            end
          end
        end

        describe '`all` — reachable, refused, visible' do
          it 'renders nothing' do
            expect(render('[{{ issues.all }}]')).to eq('[]')
          end

          # The half that tells this apart from having deleted the method.
          it 'leaves a Degradation(:unbounded_collection) behind' do
            render('{{ issues.all }}')
            expect(context.diagnostics).to be_include(:unbounded_collection)
            expect(context.diagnostics.degradations.first.detail).to include('not implemented')
          end

          it 'is still a method, so a lint can find it and a template cannot silently win' do
            expect(described_class.public_instance_methods).to include(:all)
          end
        end

        describe 'size, visible, first, and lookup by id' do
          it 'counts without instantiating anything' do
            expect(render('{{ issues.size }}')).to eq('5')
          end

          it 'answers `visible` with itself — the scope is already the viewer\'s (§3.5)' do
            expect(collection.visible).to equal(collection)
            expect(render('{{ issues.visible.size }}')).to eq('5')
          end

          it 'answers `first` with one drop' do
            expect(render('{{ issues.first.id }}')).to eq('1')
          end

          it 'looks a record up by id' do
            expect(render('{{ issues[3].subject }}')).to eq('issue 3')
          end

          it 'renders a lookup that matches nothing as empty rather than raising' do
            expect(render('[{{ issues[999] }}]')).to eq('[]')
          end

          it 'renders a non-numeric lookup as empty' do
            expect(render('[{{ issues["nope"] }}]')).to eq('[]')
          end
        end

        describe 'the two walks' do
          # An UNORDERED scope is walked with `find_each`, which is §3.4's M1: a bounded
          # result set and a bounded preload working set, so `{% for … limit: 2 %}` loads
          # a batch rather than the whole cap.
          it 'uses find_each when the scope carries no order' do
            collection.each { |_| nil }
            expect(relation.calls).to eq([[:find_each, CollectionDrop::BATCH_SIZE]])
          end

          # An ORDERED scope must NOT be walked with `find_each`: it forces primary-key
          # order and discards the author's, which renders the report in the wrong
          # sequence with nothing to say so.
          it 'keeps the author\'s order on an ordered scope, and never calls find_each' do
            ordered = DropFakes::Relation.new(records.reverse, order_values: ['subject DESC'])
            ordered_context = RenderContext.new(actor: actor, scope: ordered,
                                                batch: DropFakes::Batch.new(limit: 100))

            drop = IssuesDrop.new(ordered, context: ordered_context)
            rendered = ::Liquid::Template.parse('{% for i in issues %}{{ i.id }}{% endfor %}')
                                         .render!('issues' => drop)
            expect(rendered).to eq('54321')
            expect(ordered.calls.map(&:first)).not_to include(:find_each)
            # Capped in ONE query, `limit + 1` so "at the cap" is distinguishable from
            # "over it" — the same trick `Batch#ids` uses.
            expect(ordered.calls).to eq([[:each, 101]])
          end
        end

        describe 'the deadline reaches the loop (§4)' do
          it 'stops on an exceeded budget rather than running to the cap' do
            elapsed = 0
            budget = Budget.new(deadline_ms: 10, clock: -> { elapsed += 8 })
            timed = RenderContext.new(actor: actor, scope: relation,
                                      batch: DropFakes::Batch.new(limit: 100), budget: budget)
            drop = IssuesDrop.new(relation, context: timed)

            expect { drop.each { |_| nil } }.to raise_error(Budget::DeadlineExceeded, /collection_batch/)
          end
        end

        describe Diagnostics do
          let(:diagnostics) { Diagnostics.new }

          it 'records a degradation once and counts the repeats' do
            5.times { diagnostics.degrade(:collection_truncated, seen: 3) }
            expect(diagnostics.degradations.length).to eq(1)
            expect(diagnostics.degradations.first.count).to eq(5)
          end

          it 'keeps two degradations with different data apart' do
            diagnostics.degrade(:custom_field_hidden, field: 20)
            diagnostics.degrade(:custom_field_hidden, field: 21)
            expect(diagnostics.degradations.length).to eq(2)
          end

          it 'does not let `detail` split a bucket — prose must not affect identity' do
            diagnostics.degrade(:x, detail: 'first wording')
            diagnostics.degrade(:x, detail: 'second wording')
            expect(diagnostics.degradations.length).to eq(1)
          end

          it 'is bounded, and says so rather than growing without limit' do
            (Diagnostics::MAX_DISTINCT + 10).times { |n| diagnostics.degrade(:x, n: n) }
            expect(diagnostics).to be_include(:diagnostics_truncated)
            expect(diagnostics.degradations.length).to eq(Diagnostics::MAX_DISTINCT + 1)
          end

          it 'logs through the port it was given, never through a global' do
            lines = []
            logger = Object.new
            logger.define_singleton_method(:warn) { |line| lines << line }
            Diagnostics.new(logger: logger, correlation_id: 'abc').degrade(:x, detail: 'why')
            expect(lines.first).to include('x: why').and include('abc')
          end
        end
      end
    end
  end
end
