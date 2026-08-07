# frozen_string_literal: true

module RedmineReporterDashboards
  module Reporting
    # FR-58's diagnostics view, as data — *"what failed, the template, the Liquid line
    # where applicable, engine and version, duration and a correlation id"*.
    #
    # --- WHY A THIRD TYPE RATHER THAN REUSING EITHER FAILURE CLASS ---
    #
    # There are two failure vocabularies on this path and they are deliberately separate.
    # `Liquid::TemplateRenderer::Failure` knows about syntax errors and Liquid line
    # numbers and nothing about engines; `Render::Failure` knows about engine crashes and
    # readiness timeouts and nothing about templates. `TemplateRenderer`'s own comment
    # says why they must not be merged: *"a caller that cannot tell them apart will
    # report 'the PDF engine failed' to an author whose template has a typo in it"*.
    #
    # But the VIEW has to render one panel, and a view that branches on two classes is a
    # view that renders half of one of them. So the branch happens exactly once, here, and
    # what comes out is the closed set of fields FR-58 enumerates. `origin` is kept —
    # `:template` or `:engine` — because the panel's heading and its "what to do next"
    # line are the one thing that genuinely differs, and losing it would put the
    # confusion back.
    class Diagnostic
      ORIGINS = %i[template engine batch].freeze

      attr_reader :origin, :code, :message, :line, :engine, :engine_version,
                  :duration_ms, :correlation_id, :detail

      def initialize(origin:, code:, message:, correlation_id:, line: nil, engine: nil,
                     engine_version: nil, duration_ms: nil, detail: nil)
        unless ORIGINS.include?(origin)
          raise ArgumentError, "#{origin.inspect} is not a diagnostic origin"
        end

        @origin = origin
        @code = code
        @message = message.to_s.freeze
        @line = line
        @engine = engine
        @engine_version = engine_version
        @duration_ms = duration_ms
        @correlation_id = correlation_id.to_s.freeze
        @detail = detail
        freeze
      end

      # `detail` is DELIBERATELY ABSENT from this Hash and present on the object.
      #
      # §7b.3: the failure the base plugin shipped leaked SQL fragments, role ids and
      # project ids to whoever the report reached, because the exception message *was* the
      # document. `detail` is the raw exception text; it belongs in the log and in an
      # administrator's view, and it must not travel anywhere a report travels. Any caller
      # that serialises a diagnostic — a mail, a failure PDF (T-30), an API — gets this
      # Hash, and this Hash cannot carry it.
      def to_h
        { 'origin' => origin.to_s, 'code' => code.to_s, 'message' => message,
          'line' => line, 'engine' => engine, 'engine_version' => engine_version,
          'duration_ms' => duration_ms, 'correlation_id' => correlation_id }.freeze
      end

      class << self
        def from_template_failure(failure, correlation_id: nil)
          new(origin: :template,
              code: failure.code,
              message: failure.message,
              line: failure.line,
              duration_ms: failure.duration_ms,
              detail: failure.detail,
              correlation_id: failure.correlation_id || correlation_id)
        end

        def from_render_failure(failure)
          new(origin: :engine,
              code: failure.code,
              message: failure.message,
              engine: failure.engine,
              engine_version: failure.engine_version,
              duration_ms: failure.duration_ms,
              detail: failure.detail,
              correlation_id: failure.correlation_id)
        end

        # A batch refusal is a `Render::Failure` too — `BatchGuard#cap_refusal` builds
        # one — but it is not an engine failure and must not be presented as one: nothing
        # was drawn, no engine was started, and the remedy is "select fewer", not "check
        # the engine". Same class, different origin, and the origin is what the panel
        # reads.
        def from_batch_refusal(failure)
          new(origin: :batch,
              code: failure.code,
              message: failure.message,
              duration_ms: failure.duration_ms,
              detail: failure.detail,
              correlation_id: failure.correlation_id)
        end
      end
    end
  end
end
