# frozen_string_literal: true

require_relative 'capabilities'
require_relative 'failure'
require_relative 'result'

module RedmineReporterDashboards
  module Render
    # THE WRAPPER ABOVE EVERY ADAPTER. This is where INV-5 stops being a rule people
    # follow and becomes a thing that cannot be got wrong.
    #
    # Two post-conditions, applied to whatever any adapter returns:
    #
    #   * the bytes must start `%PDF-` and contain `%%EOF`, else Failure(:output_not_pdf)
    #   * the bytes must exceed MIN_PDF_BYTES,               else Failure(:output_empty)
    #
    # An adapter cannot opt out, because it never speaks to the caller — this does.
    #
    # --- FALSIFICATION, stated up front (technical-spec.md §5) ---
    #
    # "The byte check kills 'exception as document' and does nothing about a VALID PDF
    # whose content is wrong — a blank canvas, a lost background. That class is
    # addressed only by the preflight pixel/text probes and the degradation list. Never
    # let the byte check stand in for the whole invariant."
    #
    # It is written here, next to the check, because the place a limit gets forgotten is
    # the place the check looks convincing.
    #
    # --- Never raises ---
    #
    # An adapter that raises is a Failure(:engine_crashed), not an exception reaching a
    # mailer. That is the same rule as "never returns HTML": the caller gets a value it
    # can branch on, always. `rescue StandardError` and not `rescue Exception` —
    # CLAUDE.md §5 — so a SignalException or NoMemoryError still terminates the process
    # rather than being packaged as a render failure.
    class Renderer
      # Smaller than any real single-page PDF and larger than the empty-ish artefacts a
      # crashed engine produces. A constant rather than a guess at the call site.
      MIN_PDF_BYTES = 1_024

      PDF_MAGIC = '%PDF-'
      PDF_TRAILER = '%%EOF'

      # `logger` is a constructor PORT, not `Rails.logger` — mechanism E5, and the
      # reason layer_purity.sh forbids `Rails.` under render/**. An L3 that reaches for
      # a global is an L3 that cannot be tested without booting the thing it should not
      # know about.
      def initialize(engine:, logger: nil)
        @engine = engine
        @logger = logger
      end

      attr_reader :engine, :logger

      def render(request)
        negotiation = Capabilities.negotiate(
          required: request.required_capabilities,
          essential: request.essential_capabilities,
          available: engine.capabilities
        )

        return capability_failure(request, negotiation) unless negotiation[:blocking].empty?

        degradations = record_degradations(request, negotiation)
        result = invoke(request)
        return result if result.is_a?(Failure)

        verify(request, result, degradations)
      rescue StandardError => e
        internal_failure(request, e)
      end

      private

      def invoke(request)
        result = engine.render(request)
        return result if result.is_a?(Success) || result.is_a?(Failure)

        # An adapter that answers something else has broken the contract. Answering a
        # Failure rather than raising keeps the promise this class makes to its caller.
        failure(request, :internal,
                'the render engine returned neither a Success nor a Failure',
                detail: "got #{result.class}")
      rescue StandardError => e
        failure(request, :engine_crashed, 'the render engine failed',
                detail: "#{e.class}: #{e.message}")
      end

      # THE POST-CONDITIONS. Order matters: a truncated file can carry the magic bytes
      # and nothing else, so the emptiness check must be able to fire on something that
      # already looked like a PDF.
      def verify(request, success, extra_degradations)
        bytes = success.bytes.to_s

        unless bytes.start_with?(PDF_MAGIC) && bytes.include?(PDF_TRAILER)
          return failure(request, :output_not_pdf,
                         'the render engine produced something that is not a PDF',
                         detail: "#{bytes.bytesize} bytes, starts #{bytes[0, 16].inspect}")
        end

        if bytes.bytesize <= MIN_PDF_BYTES
          return failure(request, :output_empty,
                         'the render engine produced an empty document',
                         detail: "#{bytes.bytesize} bytes, minimum #{MIN_PDF_BYTES}")
        end

        return success if extra_degradations.empty?

        Success.new(bytes: success.bytes, page_count: success.page_count,
                    duration_ms: success.duration_ms, engine: success.engine,
                    engine_version: success.engine_version,
                    degradations: success.degradations + extra_degradations)
      end

      def record_degradations(request, negotiation)
        negotiation[:degradations].map do |capability|
          warn_line("[render] #{engine_id} cannot #{capability}; continuing without it " \
                    "(correlation_id=#{request.correlation_id})")
          Degradation.new(capability: capability,
                          detail: "#{engine_id} does not support #{capability}")
        end
      end

      def capability_failure(request, negotiation)
        missing = negotiation[:blocking]
        warn_line("[render] #{engine_id} lacks #{missing.inspect}, which this document " \
                  "requires (correlation_id=#{request.correlation_id})")
        failure(request, :capability_unsupported,
                "this document needs #{missing.map(&:to_s).join(', ')}, which the " \
                "#{engine_id} engine cannot do",
                detail: "missing=#{missing.inspect} available=#{safe_capabilities.inspect}")
      end

      def internal_failure(request, error)
        warn_line("[render] the render wrapper itself failed: #{error.class}: " \
                  "#{error.message} (correlation_id=#{request.correlation_id})")
        failure(request, :internal, 'the report could not be produced',
                detail: "#{error.class}: #{error.message}")
      end

      # `message` is SAFE by contract — it reaches a user. The exception text goes in
      # `detail`, which is for diagnostics and the log.
      def failure(request, code, message, detail: nil)
        Failure.new(code: code, message: message, detail: detail,
                    engine: engine_id, engine_version: safe_engine_version,
                    correlation_id: request.correlation_id)
      end

      # Every one of these is asked of a possibly-broken adapter, so none of them may
      # be the thing that raises on the way to reporting that it is broken.
      def engine_id
        engine.respond_to?(:id) ? engine.id : engine.class.to_s
      rescue StandardError
        'unknown'
      end

      def safe_engine_version
        engine.respond_to?(:version) ? engine.version : nil
      rescue StandardError
        nil
      end

      def safe_capabilities
        Array(engine.capabilities)
      rescue StandardError
        []
      end

      def warn_line(line)
        logger.warn(line) if logger.respond_to?(:warn)
      end
    end
  end
end
