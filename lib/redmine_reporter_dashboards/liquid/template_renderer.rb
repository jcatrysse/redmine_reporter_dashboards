# frozen_string_literal: true

require_relative 'execution_policy'
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

      # `render_context` is a `RenderContext`, and it is what carries the actor. It is
      # optional here only because a template with no issue scope is a real case
      # (a covering page, a preview of static markup) — NOT because the actor is
      # optional when there is a scope. INV-1 is enforced by RenderContext's own
      # constructor, which is where it belongs.
      def render(source, assigns: {}, registers: {}, filters: [], render_context: nil,
                 correlation_id: nil)
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
        render_context = render_context.with_budget(budget) if render_context

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

      private

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
        all_registers[RenderContext::REGISTER_KEY] = render_context if render_context

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
