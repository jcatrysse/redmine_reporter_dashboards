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
      #
      # --- `:engine_misconfigured` VERSUS `:engine_unavailable` (§Findings E-27 row 3) ---
      #
      # Added 2026-08-11 by curator decision. The two are one question apart, and the
      # question is *whose* problem it is:
      #
      #   `:engine_unavailable`    the engine is not THERE. Not installed, not answering,
      #                            the pool refused, the socket died. A retry can succeed
      #                            and nothing an operator TYPES changes the diagnosis.
      #   `:engine_misconfigured`  the engine IS there and refuses to be used as
      #                            configured — or is configured in a way this plugin will
      #                            not use. The remedy is an operator's, and no retry will
      #                            ever produce a different answer.
      #
      # E-27 row 3 recorded the old behaviour as *defensible*: the adapter refuses to use
      # an unauthenticated Gotenberg, so it IS unavailable to it. What that collapses is
      # the only thing a reader of a failed report can act on. "The render service could
      # not be reached" sends an operator to `docker ps`; "the service answered the
      # conversion route without the configured credential" sends them to
      # `--api-enable-basic-auth`. Both were the same code, and the second sentence was
      # already being written — the code was throwing the distinction away after the
      # message had made it.
      #
      # WHAT DOES NOT GET THIS CODE, deliberately, because the same row is what made the
      # old collapse defensible in the first place:
      #
      #   * reachability and transport — "nothing answered", "answered 502 and does not
      #     look like a Gotenberg", a dead socket. Identity before verdict (HANDOVER §1):
      #     a wrong address and a service that is down are indistinguishable from here,
      #     and guessing between them is how this project shipped three confident wrong
      #     remediations in one afternoon.
      #   * a probe that could not be COMPLETED. "The JavaScript check answered 503" is
      #     not a verdict about JavaScript, and it must not read as one.
      #   * the binary-backed engines. There is nothing to misconfigure about a Chromium
      #     you launched yourself, which is why the only producer today is the Gotenberg
      #     adapter. A code with one producer is fine; a code with none is dead
      #     vocabulary and this file has a precedent for deleting those.
      CODES = %i[
        engine_unavailable engine_misconfigured engine_version_unsupported timeout
        readiness_timeout resource_limit asset_unresolved capability_unsupported
        engine_crashed output_not_pdf output_empty internal
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
