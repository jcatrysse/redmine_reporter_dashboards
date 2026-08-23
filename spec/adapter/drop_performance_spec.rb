# frozen_string_literal: true
#
# T-18's GATING criteria, against a real database engine.
#
# The task's Accept list ends with them and calls them absolute:
#
#   * **zero `Issue` instantiations** for an aggregate-only template
#   * **identical query count** at 10 vs 10 000 issues
#
# and §3.4 adds the claim the batch registry exists to make true: *"the first
# `{{ issue.custom_field_value[20] }}` inside a 500-issue loop triggers ONE query for
# all 500 and memoises; the other 499 are hash lookups."* All three are yes-or-no
# questions about SQL, so they are asserted hard, on every engine, on every adapter run.
#
# --- WHY THIS DRIVES THE DROPS DIRECTLY AND RENDERS NO TEMPLATE ---
#
# Because it cannot render one. `spec/spec_helper.rb` defines a minimal `Liquid` stub so
# the DB-less specs load without the gem, `adapter_helper.rb` requires it, and the stub
# and the real gem cannot share a process — that is §Findings E-7 and the whole reason
# `spec_liquid/` exists as a separate directory with its own invocation. Requiring the
# real gem here would pull it into `rspec spec` as well, where 200+ tag examples are
# written against the stub.
#
# It costs nothing, because the questions are disjoint. What a TEMPLATE sees — which
# accessors exist, what they are called, how Liquid prints and compares them — is
# `spec_liquid/drops_spec.rb`, under both Liquid majors. What the DATABASE sees is here.
# Neither pretends to answer the other's question.
#
# --- AND WHY THE VISIBILITY CASES ARE IN THIS FILE RATHER THAN A THIRD ---
#
# Because they are the same kind of question — what SQL did the batch emit — and because
# a batch is precisely where visibility gets lost: the ids came from a scope that was
# already the viewer's, so it feels as though everything reachable from them is too. The
# four-actor fixture already here is what makes "the same call, different actor, a
# different answer" measurable at value level.

require_relative 'adapter_helper'
require_relative '../golden/performance'
require_relative '../golden/performance_cases'
require_relative '../../lib/redmine_reporter_dashboards/liquid/drops'

module RrdDropPerf
  DROPS = RedmineReporterDashboards::Liquid::Drops
  # Not `Liquid`: inside this module that name would shadow the top-level gem constant,
  # and a later reader would have to know which one a bare `Liquid::` meant.
  LAYER = RedmineReporterDashboards::Liquid

  # The two sizes T-18 names. The aggregate-only criteria are asserted across the full
  # two-orders-of-magnitude span; the ITERATION criteria are asserted at two sizes
  # inside ONE `find_each` batch, and the comment on that example says why.
  SMALL = 10
  LARGE = 10_000

  # Both under `CollectionDrop::BATCH_SIZE`, deliberately. See the example.
  LOOP_SMALL = 50
  LOOP_LARGE = 400

  class << self
    def queries(&block)
      RrdAdapterHarness.count_queries(&block)
    end

    def instantiations(class_name, &block)
      RrdAdapterHarness.count_instantiations(class_name, &block)
    end

    # MEMOISED, and it has to be: `RrdAdapterHarness.actor` is a `User.find`, and a
    # fixture lookup inside a measured block is a query the workload did not issue. It
    # cost two examples a phantom `+1` before it was moved out.
    def actor(name)
      (@actors ||= {})[name] ||= RrdAdapterHarness.actor(name)
    end

    def context_for(scope, actor: :manager, limit: nil)
      user = actor(actor)
      batch = LAYER::Batch.new(actor: user, scope: scope,
                               limit: limit || LAYER::Batch::MAX_MATERIALISED_RECORDS)
      LAYER::RenderContext.new(actor: user, scope: scope, batch: batch)
    end

    def collection(scope, **options)
      DROPS::IssuesDrop.new(scope, context: context_for(scope, **options))
    end

    def bench(count)
      RrdAdapterHarness.bench_scope(count)
    end

    # Everything a template can print off a preloaded row, touched once per issue. If
    # any of these resolved per record instead of per batch, the query count would move
    # with the loop length and the examples below would fail.
    # Collect what a loop yields. `CollectionDrop` deliberately does not include
    # `Enumerable` — that would put `sort`, `min` and `max` on the template surface, each
    # of which materialises the whole collection, which is the thing §3.2 refuses `all`
    # for. So the spec does its own folding.
    def collect(drop)
      out = []
      drop.each { |item| out << yield(item) }
      out
    end

    def touch_every_reference(drop)
      drop.each do |issue|
        [issue.status.to_s, issue.tracker.to_s, issue.priority.to_s,
         issue.category.to_s, issue.version.to_s, issue.author.to_s,
         issue.assignee.to_s, issue.project.to_s]
      end
    end

    def walk(drop)
      drop.each { |issue| issue.subject }
    end

    # `{{ issue.custom_field_value[20] }}` reaches `Drop#[]`, which real Liquid aliases
    # to `invoke_drop` — and the STUB in `spec/spec_helper.rb` does not carry that alias.
    # So the by-id path is exercised at the method it actually resolves to. The template
    # spelling is proven where a template can be parsed: `spec_liquid/drops_spec.rb`.
    def custom_field(issue, field_id)
      issue.custom_field_value.liquid_method_missing(field_id)
    end
  end
end

if !RrdAdapterHarness.configured?
  RSpec.describe 'T-18 drop-layer performance criteria' do
    it 'is skipped without a database URL' do
      skip RrdAdapterHarness.skip_reason
    end
  end
else
  RSpec.describe 'T-18 drop-layer performance criteria' do
    run = RrdDropPerf
    drops = RrdDropPerf::DROPS
    liquid = RrdDropPerf::LAYER

    # `Setting` is Redmine's, and this process has no Redmine. Two keys, stubbed per
    # example rather than defined globally: this file is LOADED (and skipped) by the
    # DB-less `rspec spec` run too, and other specs there define the same constant —
    # `spec/sql_aggregation/liquid_version_rollup_tag_spec.rb` is the current one. A
    # permanent definition here would silently change what those specs test against.
    before do
      # Plain defs, not endless ones: the floor is Ruby 2.7 (Redmine 5.1) and
      # `.codex/check_ruby_floor.sh` scans the specs too.
      settings = Class.new do
        def self.protocol
          'https'
        end

        def self.host_name
          'redmine.example'
        end
      end
      stub_const('Setting', settings)
    end

    before(:context) do
      RrdAdapterHarness.seed_bench!(RrdDropPerf::LARGE, seed: RrdGolden::Performance.seed)
      # Warm: the first query of a process pays for the connection's schema reflection
      # and the adapter's prepared statements. Counting a cold run against a warm one
      # reports a difference in warmth as a difference in the workload.
      run.collection(run.bench(RrdDropPerf::SMALL)).size
      run.walk(run.collection(run.bench(RrdDropPerf::SMALL)))
    end

    # ----------------------------------------------------------------
    # 1. Zero Issue instantiations for an aggregate-only template
    # ----------------------------------------------------------------

    describe 'an aggregate-only template' do
      [RrdDropPerf::SMALL, RrdDropPerf::LARGE].each do |count|
        it "instantiates ZERO Issue objects at #{count} issues" do
          drop = run.collection(run.bench(count))
          instantiated = run.instantiations('Issue') { drop.size }
          expect(instantiated).to eq(0),
                                  "#{instantiated} Issue objects for a template that only counted. " \
                                  '`size` must be a COUNT, never a load.'
        end
      end

      it 'issues an IDENTICAL number of queries at 10 and at 10 000 issues' do
        small = run.collection(run.bench(RrdDropPerf::SMALL))
        large = run.collection(run.bench(RrdDropPerf::LARGE))
        at_small = run.queries { small.size }
        at_large = run.queries { large.size }

        expect(at_large.length).to eq(at_small.length),
                                   lambda {
                                     "#{at_small.length} queries at #{RrdDropPerf::SMALL} issues, " \
                                       "#{at_large.length} at #{RrdDropPerf::LARGE}. Query count must " \
                                       "not scale with issue count (FR-48).\n\nat small:\n" \
                                       "#{at_small.join("\n")}\n\nat large:\n#{at_large.join("\n")}"
                                   }
        expect(at_small.length).to eq(1)
      end

      # The id set is a `pluck`, not a load. A `Batch` that resolved its ids by
      # instantiating would breach the criterion above through the back door — the
      # template never asked for an issue object and would have got 10 000 of them.
      it 'resolves the batch id set without instantiating an Issue' do
        batch = liquid::Batch.new(actor: run.actor(:manager),
                                  scope: run.bench(RrdDropPerf::LARGE))
        instantiated = run.instantiations('Issue') { batch.ids }
        expect(instantiated).to eq(0)
        expect(batch.ids.length).to eq(liquid::Batch::MAX_MATERIALISED_RECORDS)
      end
    end

    # ----------------------------------------------------------------
    # 2. §3.4 M1 — the preload, i.e. no N+1 on the named references
    # ----------------------------------------------------------------

    describe 'iterating a collection' do
      # 50 AND 400, both inside ONE `find_each` batch, so IDENTICAL is the honest
      # assertion. Across a batch boundary it would not be: `find_each(batch_size: 500)`
      # issues one query per batch plus one preload per association per batch, by
      # design — that is what bounds the result set. Asserting identity across the
      # boundary would therefore be asserting that the batching does not happen.
      # The unbounded case is covered separately below.
      it 'costs the SAME number of queries at 50 and at 400 issues' do
        small = run.collection(run.bench(RrdDropPerf::LOOP_SMALL))
        large = run.collection(run.bench(RrdDropPerf::LOOP_LARGE))
        at_small = run.queries { run.touch_every_reference(small) }
        at_large = run.queries { run.touch_every_reference(large) }

        expect(at_large.length).to eq(at_small.length),
                                   lambda {
                                     "#{at_small.length} queries for 50 issues, #{at_large.length} for " \
                                       "400. A reference resolved per record is an N+1.\n\nat 400:\n" \
                                       "#{at_large.join("\n")}"
                                   }
      end

      # The absolute figure, pinned. Without it the example above passes an
      # implementation that issues 500 queries at both sizes.
      it 'costs one query for the rows plus one per preloaded association' do
        drop = run.collection(run.bench(RrdDropPerf::LOOP_LARGE))
        issued = run.queries { run.touch_every_reference(drop) }
        # 8 PRELOADS entries, but `fixed_version: :project` is two loads, and `project`
        # is already loaded by then — Rails issues one query per distinct association
        # reached. The ceiling is what matters: it is a small constant, not 400.
        expect(issued.length).to be <= 12, issued.join("\n")
      end

      it 'still costs a constant per batch when the loop crosses the batch boundary' do
        small = run.collection(run.bench(400))
        large = run.collection(run.bench(1200))
        one_batch = run.queries { run.walk(small) }
        three_batches = run.queries { run.walk(large) }

        # Bounded by ⌈n/500⌉ × (one row query + one per preloaded association), never by
        # n. Three times the issues buys three times the batches — and nothing like the
        # 1 200 an N+1 would cost.
        expect(three_batches.length).to eq(one_batch.length * 3), three_batches.join("\n")
        expect(three_batches.length).to be < 40
      end
    end

    # ----------------------------------------------------------------
    # 3. §3.4 M2 — first-touch batch resolution
    # ----------------------------------------------------------------

    describe 'the batch registry' do
      # A plain `def` cannot see the `run` local the describe block closed over, so the
      # module is named outright. Worth the noise: the alternative is a `let` returning a
      # lambda, which reads worse at every call site.
      def cost_of(count, &block)
        plain = RrdDropPerf.collection(RrdDropPerf.bench(count))
        touching = RrdDropPerf.collection(RrdDropPerf.bench(count))
        base = RrdDropPerf.queries { RrdDropPerf.walk(plain) }.length
        with = RrdDropPerf.queries { touching.each { |issue| block.call(issue) } }.length
        with - base
      end

      # THE CLAIM §3.4 MAKES, and each of the four is named: the id set, the actor's
      # role lookup, the visible field list, and the values. Not one per issue, and not
      # one per `find_each` batch.
      it 'reads a custom field for 400 issues in a fixed number of queries' do
        delta = cost_of(RrdDropPerf::LOOP_LARGE) do |issue|
          RrdDropPerf.custom_field(issue, RrdAdapterHarness::CF_DEPARTMENT)
        end
        expect(delta).to eq(4), "reading one custom field across 400 issues cost #{delta} extra queries"
      end

      it 'costs the SAME whether the loop is 50 issues or 400' do
        small = cost_of(RrdDropPerf::LOOP_SMALL) { |issue| RrdDropPerf.custom_field(issue, RrdAdapterHarness::CF_DEPARTMENT) }
        large = cost_of(RrdDropPerf::LOOP_LARGE) { |issue| RrdDropPerf.custom_field(issue, RrdAdapterHarness::CF_DEPARTMENT) }
        expect(large).to eq(small)
      end

      it 'reads a SECOND custom field for free — the other 499 are hash lookups' do
        one = cost_of(RrdDropPerf::LOOP_LARGE) { |issue| RrdDropPerf.custom_field(issue, RrdAdapterHarness::CF_DEPARTMENT) }
        two = cost_of(RrdDropPerf::LOOP_LARGE) do |issue|
          RrdDropPerf.custom_field(issue, RrdAdapterHarness::CF_DEPARTMENT)
          RrdDropPerf.custom_field(issue, RrdAdapterHarness::CF_POINTS)
        end
        expect(two).to eq(one)
      end

      # Three, and each one is named: the id set, the entitlement lookup
      # `TimeEntry.visible_condition` performs, and the grouped SUM. Not one per issue.
      it 'reads spent_hours for 400 issues in a fixed number of queries' do
        delta = cost_of(RrdDropPerf::LOOP_LARGE, &:spent_hours)
        expect(delta).to eq(3), "spent_hours across 400 issues cost #{delta} extra queries"
      end

      it 'costs the same for spent_hours at 50 issues as at 400' do
        expect(cost_of(RrdDropPerf::LOOP_LARGE, &:spent_hours))
          .to eq(cost_of(RrdDropPerf::LOOP_SMALL, &:spent_hours))
      end

      it 'answers the same values it would have answered one query at a time' do
        scope = run.bench(20)
        drop = run.collection(scope)
        from_drop = run.collect(drop) { |issue| [issue.id, issue.spent_hours] }.to_h

        expected = ::TimeEntry.where(issue_id: from_drop.keys).group(:issue_id).sum(:hours)
        from_drop.each do |issue_id, hours|
          expect(hours).to be_within(0.001).of(expected[issue_id].to_f)
        end
        expect(from_drop.values.sum).to be > 0, 'the fixture has no spent time; the assertion is vacuous'
      end

      it 'resolves each key at most once per render' do
        drop = run.collection(run.bench(RrdDropPerf::LOOP_SMALL))
        batch = drop.send(:batch)
        drop.each do |issue|
          issue.spent_hours
          run.custom_field(issue, RrdAdapterHarness::CF_POINTS)
        end
        expect(batch.resolved_keys.sort).to eq(%i[custom_field_values spent_hours])
      end
    end

    # ----------------------------------------------------------------
    # 3b. The scopeless Batch — the silent zero this used to return
    # ----------------------------------------------------------------

    describe 'a Batch with no scope' do
      # A RenderContext can legitimately have no scope: a covering page, a preview, a
      # single issue handed to a template directly. The first version of `resolve`
      # returned `{}` there, so every batched accessor answered 0.0 / empty for an issue
      # that demonstrably had rows — a wrong number that looks like a real number, with
      # no error and no degradation. Regression test, one per key.
      let(:actor) { RrdDropPerf.actor(:manager) }
      let(:context) { liquid::RenderContext.new(actor: actor) }
      let(:issue) { drops::IssueDrop.new(::Issue.find(1), context: context) }

      it 'still sums the issue\'s own spent time' do
        expect(context.scope).to be_nil
        expect(issue.spent_hours).to be_within(0.001).of(5.0)
      end

      it 'still reads the issue\'s custom fields' do
        expect(run.custom_field(issue, RrdAdapterHarness::CF_SALARY)).to eq('1000.5')
      end

      it 'still applies the actor\'s visibility with no scope to lean on' do
        auditor_context = liquid::RenderContext.new(actor: RrdDropPerf.actor(:auditor))
        auditor_issue = drops::IssueDrop.new(::Issue.find(1), context: auditor_context)
        expect(run.custom_field(auditor_issue, RrdAdapterHarness::CF_SALARY)).to be_nil
      end

      # A `multiple` field arrives as several rows for one field. The first version
      # folded them with `existing.nil?`, which cannot tell "no row yet" from "a row
      # holding an empty string" — so a field whose FIRST stored value is blank lost it
      # and came back as a scalar. Issue 3's Salary row is blank in the fixture, which
      # is exactly the shape that breaks it.
      it 'folds several rows for one field into an Array, blank first row included' do
        ::CustomValue.insert_all!([{ customized_type: 'Issue', customized_id: 3,
                                     custom_field_id: RrdAdapterHarness::CF_SALARY,
                                     value: 'second' }])
        value = run.custom_field(drops::IssueDrop.new(::Issue.find(3), context: context),
                                 RrdAdapterHarness::CF_SALARY)
        expect(value).to eq(['', 'second'])
      ensure
        ::CustomValue.where(customized_type: 'Issue', customized_id: 3,
                            custom_field_id: RrdAdapterHarness::CF_SALARY,
                            value: 'second').delete_all
      end

      it 'memoises per id, so two issues do not answer with each other\'s rows' do
        one = drops::IssueDrop.new(::Issue.find(1), context: context)
        two = drops::IssueDrop.new(::Issue.find(2), context: context)
        expect(one.spent_hours).to be_within(0.001).of(5.0)
        expect(two.spent_hours).to be_within(0.001).of(2.0)
      end
    end

    # ----------------------------------------------------------------
    # 4. §3.4 — the cap, AT it and ONE PAST it (CLAUDE.md §3)
    # ----------------------------------------------------------------

    describe 'MAX_MATERIALISED_RECORDS' do
      it 'renders everything and degrades nothing when the scope is exactly at the cap' do
        context = run.context_for(run.bench(20), limit: 20)
        drop = drops::IssuesDrop.new(run.bench(20), context: context)
        expect(run.collect(drop, &:id).length).to eq(20)
        expect(context.diagnostics).not_to be_any
      end

      # The two `bench(21)` calls are DELIBERATELY separate objects. `IssueQuery#base_scope`
      # builds a fresh relation every call, so this is the production shape — and it is
      # what caught `RenderContext#batch_for` comparing scopes with `equal?`: the drop
      # got a second Batch under the default cap and rendered all 21.
      it 'stops at the cap and records a visible degradation one past it (INV-4)' do
        context = run.context_for(run.bench(21), limit: 20)
        drop = drops::IssuesDrop.new(run.bench(21), context: context)
        expect(run.collect(drop, &:id).length).to eq(20)
        expect(context.diagnostics).to be_include(:collection_truncated)
      end

      it 'caps the batch id set as well, so the two cannot disagree' do
        batch = liquid::Batch.new(actor: run.actor(:manager),
                                  scope: run.bench(21), limit: 20)
        expect(batch.ids.length).to eq(20)
        expect(batch).to be_truncated
      end
    end

    # ----------------------------------------------------------------
    # 5. Visibility — the same call, a different actor, a different answer
    # ----------------------------------------------------------------

    describe 'visibility (INV-1, INV-3, G5)' do
      # Issues 1-3 on PROJECT_MAIN. Issue 1 carries CF_SALARY, which is visible: false
      # and restricted to ROLE_MANAGER.
      let(:main_scope) { RrdAdapterHarness.base_scope.where(id: [1, 2, 3]) }

      def issue_one(actor)
        context = RrdDropPerf.context_for(main_scope, actor: actor)
        collection = RrdDropPerf::DROPS::IssuesDrop.new(main_scope, context: context)
        RrdDropPerf.collect(collection) { |i| [i.id, i] }.to_h.fetch(1)
      end

      it 'shows a role-restricted custom field to an actor holding the role HERE' do
        expect(run.custom_field(issue_one(:manager), RrdAdapterHarness::CF_SALARY)).to eq('1000.5')
      end

      # THE LEAK THIS EXISTS TO CATCH. The auditor holds ROLE_MANAGER — in a DIFFERENT
      # project — so `CustomField.visible` resolves the field for them. Only the
      # per-project `visible_by?` refuses it, and without that call this passes for
      # everybody who holds the role anywhere. `test/unit/multi_actor_visibility_test.rb`
      # exists for the same reason at the application level.
      it 'hides it from an actor who holds the role SOMEWHERE ELSE' do
        expect(run.custom_field(issue_one(:auditor), RrdAdapterHarness::CF_SALARY)).to be_nil
      end

      it 'hides it from an actor without the role at all' do
        expect(run.custom_field(issue_one(:developer), RrdAdapterHarness::CF_SALARY)).to be_nil
      end

      # A values-only assertion passes a leaky implementation: a report that prints the
      # field's NAME with an empty cell has still disclosed that the field exists.
      it 'omits the field ENTIRELY, name included, for an unentitled viewer' do
        names = issue_one(:auditor).custom_field_values.map(&:name)
        expect(names).not_to include('Salary')
        expect(issue_one(:manager).custom_field_values.map(&:name)).to include('Salary')
      end

      it 'refuses a field that is in nobody\'s visible set, for every actor' do
        %i[manager developer auditor].each do |who|
          expect(run.custom_field(issue_one(who), RrdAdapterHarness::CF_HIDDEN)).to be_nil
        end
      end

      # Redmine does NOT filter `Issue#spent_hours` — the application guards the display
      # with a permission check instead. A template is not a view, so the filter has to
      # be in the query or it is nowhere.
      it 'sums only the time entries the actor may see' do
        expect(issue_one(:manager).spent_hours).to be_within(0.001).of(5.0)
        expect(issue_one(:reporter).spent_hours).to eq(0.0)
      end

      it 'lists only the time entries the actor may see' do
        expect(issue_one(:manager).time_entries.length).to eq(2)
        expect(issue_one(:reporter).time_entries).to be_empty
      end
    end

    # ----------------------------------------------------------------
    # 6. Attachments — one query for the set, and the author with it
    # ----------------------------------------------------------------

    describe 'attachments' do
      before(:context) do
        ::Attachment.insert_all!([
                                   { id: 9_001, container_type: 'Issue', container_id: 1,
                                     filename: 'plan.pdf', filesize: 10, content_type: 'application/pdf',
                                     description: 'the plan', author_id: 1,
                                     created_on: Time.zone.now },
                                   { id: 9_002, container_type: 'Issue', container_id: 1,
                                     filename: 'notes.txt', filesize: 3, content_type: 'text/plain',
                                     description: nil, author_id: 1, created_on: Time.zone.now },
                                   { id: 9_003, container_type: 'Issue', container_id: 2,
                                     filename: 'chart.png', filesize: 7, content_type: 'image/png',
                                     description: nil, author_id: 2, created_on: Time.zone.now }
                                 ])
      end

      after(:context) { ::Attachment.where(id: [9_001, 9_002, 9_003]).delete_all }

      let(:main_scope) { RrdAdapterHarness.base_scope.where(id: [1, 2, 3]) }

      it 'groups them by issue in one pass' do
        context = run.context_for(main_scope)
        by_issue = run.collect(drops::IssuesDrop.new(main_scope, context: context)) do |i|
          [i.id, i.attachments.map(&:filename)]
        end.to_h
        expect(by_issue[1]).to eq(%w[plan.pdf notes.txt])
        expect(by_issue[2]).to eq(['chart.png'])
        expect(by_issue[3]).to eq([])
      end

      it 'costs a fixed number of queries, author included' do
        context = run.context_for(main_scope)
        drop = drops::IssuesDrop.new(main_scope, context: context)
        issued = run.queries { drop.each { |issue| issue.attachments.map { |a| a.author.to_s } } }
        # ids, attachments, authors — plus the row query and its preloads, which the
        # baseline examples above already pin.
        expect(issued.count { |sql| sql.include?('attachments') }).to eq(1), issued.join("\n")
      end
    end
  end
end
