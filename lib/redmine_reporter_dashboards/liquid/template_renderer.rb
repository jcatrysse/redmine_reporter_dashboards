# frozen_string_literal: true

require_relative 'execution_policy'
require_relative 'filters'
require_relative 'render_context'

module RedmineReporterDashboards
  module Liquid
    # THE ONLY PLACE THIS PLUGIN PARSES A TEMPLATE.
    #
    # `script/gates/single_parse.sh` enforces that, and the reason it is a gate rather
    # than a convention is that every property below is a property of the CALL SITE.
    # A second `Liquid::Template.parse` somewhere convenient has no resource limits, no
    # deadline, lax error mode, and writes its errors into the document — not because
    # anyone decided that, but because those are Liquid's defaults and the second call
    # site did not know it was supposed to argue with them.
    #
    # --- "ERRORS NEVER ENTER THE DOCUMENT" IS ONE FLAG, AND IT IS THIS ONE ---
    #
    # Liquid's default behaviour is to CATCH a render error and APPEND ITS MESSAGE TO
    # THE OUTPUT. That is where `issue_list_report_template.rb:25-27`'s "errors returned
    # as the document" actually comes from — not from anyone writing `rescue => e;
    # return e.message`, but from nobody passing `rethrow_errors`. A recipient then gets
    # a report with `Liquid error: undefined method` in the middle of it, and nothing
    # anywhere records a failure.
    #
    # So the Context is built with `rethrow_errors: true` and every error becomes a
    # typed `Outcome::Failure`. And because that is the single most important property
    # here, it is ALSO checked after the fact: `assert_clean!` scans the rendered output
    # for Liquid's own error prefix. That is the same shape as `Render::Renderer`'s
    # `%PDF-` post-condition — a mechanical check above a thing that could otherwise be
    # got wrong quietly, placed where forgetting it is impossible rather than unlikely.
    #
    # --- WHY THIS RETURNS ITS OWN RESULT TYPE AND NOT `Render::Result` ---
    #
    # `script/gates/layer_purity.sh` forbids `liquid/**` from naming the render layer,
    # and the reason behind the gate is better than the gate: these are different
    # failure vocabularies. A template syntax error and a browser that crashed are not
    # the same kind of event, they are fixed by different people, and a caller that
    # cannot tell them apart will report "the PDF engine failed" to an author whose
    # template has a typo in it.
    class TemplateRenderer
      # Liquid's own prefix for an error it has decided to render instead of raise.
      # Matching on it is deliberate belt-and-braces: `rethrow_errors` should mean this
      # never appears, and if it ever does the render is a failure rather than a
      # document that happens to contain an apology.
      LIQUID_ERROR_MARKER = 'Liquid error'

      # What a render can produce. A closed set, so a caller can branch exhaustively
      # and so no new string can appear in a mailer six months from now.
      FAILURE_CODES = %i[
        syntax_error runtime_error resource_limit deadline_exceeded internal
      ].freeze

      # A rendered document. Note what is NOT here: nothing is marked `html_safe`.
      # Escaping is the template layer's job (FR-19, INV-9) and marking the whole body
      # safe at this seam would undo it for everything downstream.
      class Document
        attr_reader :body, :duration_ms, :output_class

        def initialize(body:, duration_ms:, output_class:)
          @body = body
          @duration_ms = duration_ms
          @output_class = output_class
          freeze
        end

        def success?
          true
        end

        def failure?
          false
        end
      end

      class Failure
        attr_reader :code, :message, :detail, :correlation_id, :duration_ms, :line

        def initialize(code:, message:, correlation_id: nil, detail: nil, duration_ms: nil,
                       line: nil)
          unless FAILURE_CODES.include?(code)
            raise ArgumentError, "#{code.inspect} is not a template failure code"
          end

          @code = code
          @message = message.to_s.freeze
          @detail = detail
          @correlation_id = correlation_id
          @duration_ms = duration_ms
          @line = line
          freeze
        end

        def success?
          false
        end

        def failure?
          true
        end

        # There is no document. Answering `''` would let a caller write an empty report
        # and never notice, which is the nil-driven failure this project keeps deleting.
        def body
          raise NoMethodError, "a failed template render has no body (#{code}: #{message})"
        end

        def to_h
          { 'code' => code.to_s, 'message' => message, 'line' => line,
            'correlation_id' => correlation_id, 'duration_ms' => duration_ms }.freeze
        end
      end

      attr_reader :policy

      # `logger` is a constructor port, not `Rails.logger` — mechanism E5, the same
      # reason `Render::Renderer` takes one. A layer that reaches for a global is a
      # layer that cannot be tested without booting the thing it should not know about.
      def initialize(policy:, logger: nil)
        @policy = policy
        @logger = logger
      end

      # `render_context` is a `RenderContext`, it is what carries the actor, and IT IS NOW
      # REQUIRED. That keyword's default used to be `nil`.
      #
      # --- WHY REQUIRED, AND WHY THAT IS THE POINT OF CURATOR DECISION #1 ---
      #
      # Decision #1 withdraws renders performed by another plugin, and its proof obligation
      # was "establish that NO CONTEXT-LESS RENDER REMAINS — by measurement, before deleting
      # anything". The measurement is three facts:
      #
      #   1. `Liquid::Context` is constructed in exactly ONE place in this repository:
      #      `build_context` below.
      #   2. `Liquid::Template.parse` likewise, in `parse` below — and that one is already
      #      MECHANICAL, enforced by `script/gates/single_parse.sh` over `app/` and `lib/`.
      #   3. `#render` has exactly ONE caller in `app/` + `lib/`:
      #      `Reporting::ReportRun#render_section`, which always passes a context.
      #
      # Fact 3 was a grep, and a grep is a measurement of today. This keyword being required
      # makes it a property Ruby enforces: a future caller that forgets a context gets an
      # `ArgumentError` at the call site instead of a document that renders complete, reads
      # zero and logs a warn line nobody sees. That is the same trade decision #3 took when it
      # made `TagParams::Value` refuse to leave its layer mechanically rather than by tracing
      # its call sites.
      #
      # WHAT THE `nil` DEFAULT WAS FOR, since removing it deserves an answer rather than a
      # shrug: the comment here said "a template with no issue SCOPE is a real case (a covering
      # page, a preview of static markup)". True, and unaffected — a scope-less render is
      # `RenderContext.new(actor: …, scope: nil)`, which is exactly what `ReportRun` passes for
      # a per-record job. Nothing needed an ACTOR-less render; the default only ever served
      # test convenience, and `spec_liquid/template_renderer_spec.rb` now names an actor.
      #
      # INV-1 itself is still enforced by `RenderContext`'s own constructor, which refuses a
      # nil actor. This keyword is what makes that constructor unavoidable.
      #
      # `filters:` DEFAULTS TO THE OWNED SET, and defaults rather than registers globally.
      #
      # The vendor gem registers four filter modules at require time and monkey-patches
      # `Liquid::StandardFilters`; the base plugin does the same. Every Liquid template in
      # the process then gains 55 filters nobody asked for, one of which invokes an
      # arbitrary named method on an arbitrary object. `Context#add_filters` is the
      # per-render channel, this is the only place it is called, and
      # `script/gates/single_parse.sh` fails on a global `register_filter` anywhere in the
      # repository — so "per-render" is a property of the code rather than of a promise.
      #
      # A caller wanting extra filters passes `Filters.modules + [mine]`. A caller wanting
      # NONE passes `[]`, which is what the spec proving the scoping does.
      def render(source, render_context:, assigns: {}, registers: {},
                 filters: Filters.modules, correlation_id: nil)
        # THE TYPE CHECK IS HERE AND THE RENDER IS ONE METHOD DOWN, AND THAT SPLIT IS NOT
        # TIDINESS — IT IS THE BUG THE FIRST DRAFT HAD.
        #
        # The keyword being required stops a caller OMITTING it. It does not stop
        # `render_context: nil`, which satisfies Ruby and would then reach `build_context`,
        # put no register in the Liquid context, and reproduce precisely the context-less
        # render this whole change deletes — silently. Hence the `is_a?`.
        #
        # But a method-level `rescue` covers the WHOLE body, so with the check inside
        # `#render_document`'s body its `rescue StandardError` swallowed this ArgumentError and
        # turned it into `Failure(:internal)` — and then died in `failure` on `monotonic_ms -
        # started` with `started` still nil, reporting `TypeError: nil can't be coerced into
        # Float` from a line that does arithmetic. A caller bug, wearing a render failure's
        # clothes, wearing the wrong exception. FOUND BY THE TWO NEW EXAMPLES IN
        # `spec_liquid/template_renderer_spec.rb` on their first run, which is the argument for
        # writing the negative cases rather than the positive one.
        #
        # So the guard sits OUTSIDE the rescued body. A caller bug raises at the call site,
        # loudly, where a developer sees it; a TEMPLATE's own ArgumentError still becomes a
        # typed `Failure(:internal)` exactly as before, which is why this is a split rather than
        # a `rescue ArgumentError; raise` clause added to the chain.
        unless render_context.is_a?(RenderContext)
          raise ArgumentError,
                'render_context: must be a RenderContext (INV-1: the actor is explicit, and ' \
                'since curator decision #1 there is no context-less render path). Got ' \
                "#{render_context.class}"
        end

        render_document(source, render_context, assigns, registers, filters, correlation_id)
      end

      private

      # Positional rather than keyword, deliberately: this is not an entry point. `#render`
      # above is, and a second keyword-taking method would read as a second way in.
      def render_document(source, render_context, assigns, registers, filters, correlation_id)
        budget = policy.budget
        started = monotonic_ms

        template = parse(source)
        return template if template.is_a?(Failure)

        # THE DEADLINE HAS TO REACH THE DROPS, not only the tags.
        #
        # `Budget::REGISTER_KEY` is how an own TAG finds it, and that was enough while
        # tags were the only thing that could be slow. The drop layer added two more
        # checkpoints §4 names — every collection batch boundary and every prefetch —
        # and a drop is handed a `RenderContext`, not a `Liquid::Context`. A context
        # carrying `Budget::NULL` would make both of those checks no-ops that LOOK live,
        # which is worse than not having them.
        #
        # `with_budget` rather than a setter: the context is frozen on purpose.
        # NO `if render_context` GUARD ANY MORE: the keyword is required and type-checked
        # above, so the conditional could not be false. Left as a bare call rather than kept
        # "for safety" — a guard whose negative branch is unreachable survives every mutation
        # and teaches the next reader that nil is a case here. It is not.
        render_context = render_context.with_budget(budget)

        context = build_context(assigns, registers, budget, render_context)
        context.add_filters(Array(filters)) unless Array(filters).empty?

        body = template.render(context)
        assert_clean!(body)
        Document.new(body: body, duration_ms: (monotonic_ms - started).round,
                     output_class: policy.output_class)
      rescue ::Liquid::MemoryError => e
        # The resource limits tripping. A DIFFERENT event from running out of time, and
        # the person who fixes it does something different: this one is a template
        # producing too much, not a template waiting on something slow.
        failure(:resource_limit, 'this template produced more output than the limit allows',
                e, started, correlation_id)
      rescue Budget::DeadlineExceeded => e
        failure(:deadline_exceeded, 'this template took too long to render', e, started,
                correlation_id)
      rescue ::Liquid::Error => e
        failure(:runtime_error, 'this template could not be rendered', e, started,
                correlation_id, line: e.respond_to?(:line_number) ? e.line_number : nil)
      rescue StandardError => e
        # NOT `rescue Exception` (CLAUDE.md §5): a SignalException or NoMemoryError must
        # still end the process rather than be packaged as a template failure.
        failure(:internal, 'this template could not be rendered', e, started, correlation_id)
      end

      # THE PARSE. Strict error mode per parse rather than globally, because global
      # error mode is process-wide state and this plugin shares a process with whatever
      # else parses Liquid on the host.
      def parse(source)
        ::Liquid::Template.parse(source.to_s, error_mode: policy.error_mode)
      rescue ::Liquid::SyntaxError => e
        # An authoring mistake, and it is worth its own code: a syntax error is fixed by
        # the person editing the template, and telling them "the render failed" when the
        # answer is "line 12 has an unclosed tag" wastes everybody's afternoon.
        Failure.new(code: :syntax_error,
                    message: 'this template has a syntax error and was not rendered',
                    detail: e.message,
                    line: e.respond_to?(:line_number) ? e.line_number : nil)
      end

      # Positional, because that is the signature Liquid 4 and Liquid 5 share. The
      # fourth argument is `rethrow_errors` and it is the whole of "errors never enter
      # the document"; the fifth is the per-render resource limits, which is the only
      # non-global channel either version offers.
      def build_context(assigns, registers, budget, render_context)
        all_registers = registers.dup
        all_registers[Budget::REGISTER_KEY] = budget
        # Unconditional, for the same reason: `render` refuses anything that is not a
        # RenderContext before this is reached.
        all_registers[RenderContext::REGISTER_KEY] = render_context

        ::Liquid::Context.new(
          [stringify(assigns)],
          {},
          all_registers,
          true,
          policy.resource_limits
        ).tap do |context|
          context.strict_filters = policy.strict_filters? if context.respond_to?(:strict_filters=)
          context.strict_variables = policy.strict_variables? if context.respond_to?(:strict_variables=)
        end
      end

      # Liquid looks assigns up by STRING key. A symbol-keyed hash renders as blank
      # everywhere and raises nothing, which is the quietest possible way for a report
      # to come out empty.
      def stringify(assigns)
        assigns.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      # The post-condition. See the class comment: `rethrow_errors` should make this
      # unreachable, and it is checked anyway because the cost of being wrong is a
      # document that reaches a reader with an exception in it.
      def assert_clean!(body)
        return body unless body.to_s.include?(LIQUID_ERROR_MARKER)

        raise ::Liquid::Error, "the rendered output contains #{LIQUID_ERROR_MARKER.inspect}, " \
                               'which means an error reached the document despite rethrow_errors'
      end

      # `message` is SAFE by contract — it is shown to a user. The exception text goes
      # in `detail`, which is for the diagnostics channel and the log (FR-58).
      def failure(code, message, error, started, correlation_id, line: nil)
        duration = (monotonic_ms - started).round
        warn_line("[liquid] #{code} after #{duration}ms: #{error.class}: #{error.message} " \
                  "(correlation_id=#{correlation_id})")
        Failure.new(code: code, message: message, detail: "#{error.class}: #{error.message}",
                    correlation_id: correlation_id, duration_ms: duration, line: line)
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
