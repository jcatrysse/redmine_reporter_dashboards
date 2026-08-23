# frozen_string_literal: true

# See `execution_policy_spec.rb`'s header: the real gem, its own rspec invocation.
require 'liquid'

require_relative '../lib/redmine_reporter_dashboards/liquid/template_renderer'

module RedmineReporterDashboards
  module Liquid
    RSpec.describe TemplateRenderer do
      before do
        skip 'run with the real gem: rspec -r liquid spec_liquid' unless
          defined?(::Liquid::VERSION)
      end

      subject(:renderer) { described_class.new(policy: ExecutionPolicy.widget) }

      # `render_context:` IS A REQUIRED KEYWORD SINCE CURATOR DECISION #1, so every example
      # names an actor. It used to default to nil, and that default existed only for this file
      # — nothing in `app/` or `lib/` ever rendered without a context.
      #
      # A `let` rather than one shared constant: `RenderContext` is frozen and the renderer
      # derives a budget-carrying copy per render, so sharing one is harmless — but a `let`
      # keeps each example's actor its own, which is what the multi-actor examples elsewhere in
      # the suite depend on and is one less thing to think about here.
      let(:actor) { Object.new }
      let(:render_context) { RenderContext.new(actor: actor) }

      # Every call in this file goes through here, so the required keyword is spelled once. A
      # literal `render_context: render_context` on twelve lines would have made the diff for
      # decision #1 look like twelve decisions.
      def render(source, **options)
        renderer.render(source, render_context: render_context, **options)
      end

      describe 'an ordinary render' do
        it 'returns a document carrying the body and how long it took' do
          result = render('Hello {{ name }}', assigns: { 'name' => 'world' })

          expect(result).to be_success
          expect(result.body).to eq('Hello world')
          expect(result.duration_ms).to be >= 0
          expect(result.output_class).to eq(:widget)
        end

        # Liquid looks assigns up by STRING key. A symbol-keyed hash renders blank
        # everywhere and raises nothing, which is the quietest way for a report to come
        # out empty — so the renderer converts rather than letting the caller find out.
        it 'accepts symbol-keyed assigns rather than rendering them as blank' do
          result = render('Hello {{ name }}', assigns: { name: 'world' })

          expect(result.body).to eq('Hello world')
        end

        it 'does not mark its output html_safe' do
          result = render('{{ x }}', assigns: { 'x' => '<b>' })

          expect(result.body).to respond_to(:html_safe?).or satisfy { |b| !b.respond_to?(:html_safe?) }
          expect(result.body.respond_to?(:html_safe?) ? result.body.html_safe? : false).to be(false)
        end
      end

      # --- THE PROPERTY THIS CLASS EXISTS FOR ---------------------------------
      #
      # Liquid's DEFAULT is to catch a render error and append its message to the
      # output. That is where "errors returned as the document" actually comes from —
      # not from anyone writing `rescue => e; return e.message`, but from nobody passing
      # `rethrow_errors`. A recipient then gets a report with `Liquid error:` in the
      # middle of it and nothing anywhere records a failure.
      describe 'errors never enter the document (INV-5, one layer up)' do
        it 'proves the default it is protecting against, so this is not folklore' do
          template = ::Liquid::Template.parse('{{ 1 | divided_by: 0 }}', error_mode: :strict)

          # No rethrow_errors: Liquid writes the error INTO the output and returns
          # happily. This is the behaviour the plugin ships today.
          default_output = template.render({})

          expect(default_output).to include('Liquid error')
        end

        it 'turns that same template into a typed failure with no body at all' do
          result = render('{{ 1 | divided_by: 0 }}')

          expect(result).to be_failure
          expect(result.code).to eq(:runtime_error)
          expect { result.body }.to raise_error(NoMethodError, /has no body/)
        end

        it 'refuses to hand back output that contains a Liquid error marker' do
          # The post-condition, driven directly: even if `rethrow_errors` were somehow
          # bypassed, a body carrying the marker is a failure rather than a document.
          expect { renderer.send(:assert_clean!, 'fine ... Liquid error: nope') }
            .to raise_error(::Liquid::Error, /despite rethrow_errors/)
        end

        it 'says nothing about the exception in the message a user sees' do
          result = render('{{ 1 | divided_by: 0 }}')

          expect(result.message).not_to include('divided_by')
          expect(result.message).not_to include('ZeroDivision')
          # …while the diagnostics channel keeps everything.
          expect(result.detail).to include('Liquid::')
        end
      end

      describe 'a syntax error' do
        # Its own code, because it is fixed by a different person than a runtime error:
        # the author editing the template, not the operator reading the log.
        it 'is reported as a syntax error rather than a render failure' do
          result = render('{% if %}never closed')

          expect(result).to be_failure
          expect(result.code).to eq(:syntax_error)
        end

        it 'carries the detail an author needs without leaking it to the reader' do
          result = render('{% if %}never closed')

          expect(result.message).to match(/syntax error/i)
          expect(result.detail).not_to be_nil
        end
      end

      describe 'the resource limits' do
        it 'refuses a template that produces more output than its class allows' do
          renderer = described_class.new(policy: ExecutionPolicy.widget)
          # 2 000 000 characters of output from a template that is three lines long,
          # which is exactly the shape of the accident the limits exist for.
          result = render('{% for i in (1..40000) %}{{ pad }}{% endfor %}',
                                   assigns: { 'pad' => 'x' * 200 })

          expect(result).to be_failure
          expect(result.code).to eq(:resource_limit)
          expect(result.message).to match(/more output than the limit/)
        end

        it 'renders the same template happily under the report class' do
          result = described_class.new(policy: ExecutionPolicy.report)
                                  .render('{% for i in (1..40000) %}{{ pad }}{% endfor %}',
                                          render_context: render_context,
                                          assigns: { 'pad' => 'x' * 200 })

          expect(result).to be_success
        end
      end

      describe 'the cooperative deadline' do
        # A tag that has run out of time raises `DeadlineExceeded`, and the renderer
        # turns it into its own code — DIFFERENT from a resource limit, because the
        # person who fixes "too slow" does something different from the person who fixes
        # "too big".
        it 'is a different failure from a resource limit' do
          slow_tag = Class.new(::Liquid::Tag) do
            def render(context)
              Budget.from(context).check!('slow_tag')
              'never reached'
            end
          end
          ::Liquid::Template.register_tag('rrd_spec_slow', slow_tag)

          policy = ExecutionPolicy.widget(deadline_ms: 0)
          result = described_class.new(policy: policy)
                                  .render('{% rrd_spec_slow %}', render_context: render_context)

          expect(result).to be_failure
          expect(result.code).to eq(:deadline_exceeded)
          expect(result.message).to match(/too long/)
        end

        it 'binds a budget the tags can find' do
          seen = nil
          probe_tag = Class.new(::Liquid::Tag) do
            define_method(:render) do |context|
              seen = Budget.from(context)
              ''
            end
          end
          ::Liquid::Template.register_tag('rrd_spec_probe', probe_tag)

          described_class.new(policy: ExecutionPolicy.report)
                        .render('{% rrd_spec_probe %}', render_context: render_context)

          expect(seen).to be_a(Budget)
          expect(seen.deadline_ms).to eq(30_000)
        end
      end

      # --- CURATOR DECISION #1 — A RENDER WITHOUT A CONTEXT IS NOT REPRESENTABLE ---------
      #
      # These are the mechanical half of decision #1's proof obligation. The obligation was to
      # ESTABLISH BY MEASUREMENT that no context-less render remains before deleting the
      # ambient-actor fallback that served one; three greps established it for today
      # (one `Liquid::Context.new`, one `Template.parse` — already gated by
      # `script/gates/single_parse.sh` — and one caller of `#render`). A required keyword is
      # what keeps it true tomorrow, and unlike a source-level spec it cannot be defeated by
      # a path glob (`HANDOVER.md` §1 has the `/redmine/` story).
      #
      # RUN AGAINST THE REAL GEM, deliberately. `spec/spec_helper.rb` installs a Liquid STUB
      # whose `Context` is not the gem's, so a keyword contract asserted there would be
      # asserting the stub's. This file is where the real `Liquid::Context` is built.
      describe 'the required render context' do
        it 'refuses a render with no context at all' do
          expect { renderer.render('static markup') }
            .to raise_error(ArgumentError, /missing keyword: :?render_context/)
        end

        # BOTH SPELLINGS, because Ruby only closes one of them. `render_context:` being
        # required stops a caller OMITTING it; an explicit `nil` satisfies the keyword and
        # would have sailed straight through to `build_context`, putting no register in the
        # context and reproducing exactly the state the fallback used to paper over.
        it 'refuses an explicit nil, which the keyword alone would have allowed' do
          expect { renderer.render('static markup', render_context: nil) }
            .to raise_error(ArgumentError, /must be a RenderContext/)
        end

        # And it refuses something merely context-SHAPED. `RenderContext.from` type-checks its
        # register with `is_a?`, so a double reaching the registers reads as no context at all
        # — a silent zero-reading render rather than a loud refusal.
        it 'refuses an object that only looks like one' do
          lookalike = Struct.new(:actor, :scope, :query).new(Object.new, nil, nil)

          expect { renderer.render('static markup', render_context: lookalike) }
            .to raise_error(ArgumentError, /must be a RenderContext/)
        end

        # THE POSITIVE HALF, so the three refusals above cannot be satisfied by a renderer
        # that refuses everything. An actor-only context — no scope, no query — is the case the
        # old `nil` default was justified by ("a covering page, a preview of static markup"),
        # and it still renders.
        it 'renders a scope-less, query-less context, which is what the nil default was for' do
          result = renderer.render('static markup',
                                   render_context: RenderContext.new(actor: Object.new))

          expect(result).to be_success
          expect(result.body).to eq('static markup')
        end
      end

      describe 'what reaches the tags' do
        it 'passes the render context through the register the owned path uses' do
          seen = nil
          probe = Class.new(::Liquid::Tag) do
            define_method(:render) do |context|
              seen = RenderContext.from(context)
              ''
            end
          end
          ::Liquid::Template.register_tag('rrd_spec_ctx', probe)

          actor = Struct.new(:login).new('jsmith')
          context = RenderContext.new(actor: actor)
          renderer.render('{% rrd_spec_ctx %}', render_context: context)

          expect(seen).to be_a(RenderContext)
          expect(seen.actor).to equal(actor)
          expect(seen.diagnostics).to equal(context.diagnostics)
        end

        # NOT THE SAME OBJECT, and this example is why the one above no longer says so.
        #
        # T-18 gave the drop layer two of §4's three deadline checkpoints — every
        # collection batch boundary and every prefetch — and a drop is handed a
        # RenderContext, not a Liquid::Context, so `Budget::REGISTER_KEY` cannot reach
        # it. A context whose budget was `Budget::NULL` would make both checks no-ops
        # that LOOK live, which is worse than not having them.
        #
        # `RenderContext` is frozen on purpose, so binding the budget derives a new one.
        # What must be SHARED across that derivation is the diagnostics collector —
        # a degradation recorded through the derived context has to reach the caller's
        # list — and the example above asserts exactly that.
        it 'binds the render budget into the context so the drop checkpoints are live' do
          seen = nil
          probe = Class.new(::Liquid::Tag) do
            define_method(:render) do |context|
              seen = RenderContext.from(context)
              ''
            end
          end
          ::Liquid::Template.register_tag('rrd_spec_budget_ctx', probe)

          context = RenderContext.new(actor: Struct.new(:login).new('jsmith'))
          expect(context.budget).to equal(Budget::NULL)

          described_class.new(policy: ExecutionPolicy.report)
                         .render('{% rrd_spec_budget_ctx %}', render_context: context)

          expect(seen.budget).to be_a(Budget)
          expect(seen.budget.deadline_ms).to eq(30_000)
          expect(seen.batch.send(:instance_variable_get, :@budget)).to equal(seen.budget)
        end

        it 'scopes filters to the render rather than registering them globally' do
          filters = Module.new do
            def rrd_spec_shout(input)
              "#{input}!"
            end
          end

          result = render('{{ "hi" | rrd_spec_shout }}', filters: [filters])
          expect(result.body).to eq('hi!')

          # A SECOND renderer without the filter must not see it. `Template.register_filter`
          # would have made it global and this would pass by accident.
          plain = described_class.new(policy: ExecutionPolicy.widget)
                                 .render('{{ "hi" | rrd_spec_shout }}',
                                         render_context: render_context)
          expect(plain).to be_failure, 'the filter leaked out of the render that declared it'
        end
      end

      describe 'strictness' do
        # An unknown FILTER is an authoring mistake and must be loud.
        it 'refuses an unknown filter instead of rendering nothing' do
          expect(render('{{ x | no_such_filter }}', assigns: { 'x' => 1 })).to be_failure
        end

        # An unknown VARIABLE is not: `{{ issue.due_date }}` on an issue without one is
        # ordinary, and a template that guards every optional field is unmaintainable.
        it 'renders an unknown variable as blank rather than failing' do
          result = render('[{{ nothing_here }}]')

          expect(result).to be_success
          expect(result.body).to eq('[]')
        end
      end
    end
  end
end
