# frozen_string_literal: true

module RedmineReporterDashboards
  module Render
    # A typed failure — INV-5's other half.
    #
    # The base plugin returns `e.message` AS THE DOCUMENT CONTENT. A recipient gets a
    # green-looking mail with a broken report in it, and nothing anywhere reports a
    # failure. That is the defect this class exists to make unrepresentable: a Failure
    # is not bytes, cannot be attached, and carries a correlation id so the diagnostics
    # view and the log line can be joined up (FR-58).
    #
    # `message` is SAFE by contract: it is shown to a user, so it must never carry a
    # raw exception or SQL. `detail` is for the diagnostics view and the log, and the
    # caller is responsible for what it puts there.
    class Failure
      # The CLOSED code set (technical-spec.md §5). Closed so a caller can exhaustively
      # branch on it, and so "some new string" cannot appear in a mail template.
      CODES = %i[
        engine_unavailable engine_version_unsupported timeout readiness_timeout
        resource_limit asset_unresolved capability_unsupported engine_crashed
        output_not_pdf output_empty internal
      ].freeze

      class UnknownCode < ArgumentError; end

      attr_reader :code, :message, :engine, :engine_version, :duration_ms, :detail,
                  :correlation_id

      def initialize(code:, message:, correlation_id:, engine: nil, engine_version: nil,
                     duration_ms: nil, detail: nil)
        unless CODES.include?(code)
          raise UnknownCode, "#{code.inspect} is not a Failure code. Known: #{CODES.inspect}"
        end

        @code = code
        @message = message.to_s.freeze
        @engine = engine
        @engine_version = engine_version
        @duration_ms = duration_ms
        @detail = detail
        @correlation_id = correlation_id.to_s.freeze
        freeze
      end

      def success?
        false
      end

      def failure?
        true
      end

      # There are no bytes. Asking for them is a bug in the caller, and answering nil
      # would let `attachment.write(result.bytes)` produce a zero-byte PDF — which is
      # the same failure mode in a new costume.
      def bytes
        raise NoMethodError, "a Failure has no bytes (#{code}: #{message})"
      end

      def to_h
        { 'code' => code.to_s, 'message' => message, 'engine' => engine,
          'engine_version' => engine_version, 'duration_ms' => duration_ms,
          'correlation_id' => correlation_id }.freeze
      end
    end
  end
end
