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
      #   `:engine_unavailable`    the engine is not THERE, and this side cannot tell why.
      #                            Not installed, not answering, the pool refused, the
      #                            socket died. The diagnosis stops at "it did not answer" —
      #                            the remedy might be a retry, an install or an address, so
      #                            the MESSAGE has to name more than one of them and the
      #                            CODE must not pretend to have chosen.
      #   `:engine_misconfigured`  the engine IS there and refuses to be used as
      #                            configured — or is configured in a way this plugin will
      #                            not use. The remedy is an operator's, it is NAMED in the
      #                            message, and no retry will ever produce a different
      #                            answer.
      #
      # The discriminator is NOT "can an operator act on it" — installing a missing binary
      # is an action, and that one is `:engine_unavailable`. It is "do we KNOW what to tell
      # them". "The render service could not be reached" sends an operator to `docker ps`;
      # "the service answered the conversion route without the configured credential" sends
      # them to `--api-enable-basic-auth`.
      #
      # WHAT DOES NOT GET THIS CODE, deliberately, because the same row is what made the
      # old collapse defensible in the first place:
      #
      #   * reachability and transport — "nothing answered", "answered 502 and does not
      #     look like a Gotenberg", a dead socket, a name that does not resolve. Identity
      #     before verdict (HANDOVER §1): a service that is down, one behind a wrong
      #     `--api-root-path` and one that is something else entirely are not distinguishable
      #     from here, so the message names more than one remedy and the code does not pretend
      #     to have chosen. `technical-spec.md` §5 states this ONCE and normatively, and this
      #     paragraph is the same words rather than a second statement of them.
      #
      #     A SENTENCE MAY SPLIT WHERE THE CODE MAY NOT, and §Findings E-29 is the worked
      #     example. `SocketError` gets its own ARM and its own sentence in `gotenberg.rb`,
      #     because "nothing answered, confirm the container is running" sends an operator to
      #     `docker ps` for a fault no restart can fix. It does NOT get its own code: a
      #     review measured EAI_AGAIN — an unreachable resolver, spelling and network both
      #     correct — arriving as the same `SocketError`, and a retry is what fixes that one,
      #     which is precisely what `:engine_misconfigured` promises can never help. So the
      #     arm's sentence names both remedies and its code stays the one that has not chosen.
      #     `Errno::ECONNREFUSED` is not a `SocketError`, which is what keeps the refused
      #     socket on the generic arm.
      #   * a probe that could not be COMPLETED. "The JavaScript check answered 503" is
      #     not a verdict about JavaScript, and it must not read as one.
      #   * a MISSING binary. `wkhtmltopdf.rb` reads `RRD_WKHTMLTOPDF_BINARY`, an
      #     operator-typed path, so `Errno::ENOENT` might be a package nobody installed or a
      #     path somebody mistyped — two remedies, and this side cannot tell, so it stays
      #     `:engine_unavailable`. `Errno::EACCES` is the twin that DOES get the new code: the
      #     file is there and is not executable, which is one fault with one remedy.
      #
      # WHO PRODUCES IT. Six arms in the Gotenberg adapter, and the wkhtmltopdf adapter's
      # `EACCES` arm — a binary that is there and is not executable, one fault with one
      # remedy. Both are `Render::Failure`s, which is what this file's `CODES` governs.
      #
      # ONE MORE PRODUCER LIVES OUTSIDE THIS TYPE, and saying so is the point of naming it
      # here: `Reporting::ReportRun#no_engine_diagnostic` mints a `Reporting::Diagnostic`,
      # legal only through `Diagnostic.codes`' union with this set, for an installation where
      # every registered engine needs a service and so none can be selected automatically.
      # That call site ALSO answers `:engine_unavailable`, for the neighbouring state where no
      # engine is registered at all — one method, two states, two codes, because a review
      # measured the single sentence they used to share as false in the second. (This bullet
      # said "and which has selected none" until a further review measured a third state where
      # a selection HAS been made and names an engine that is no longer registered. Neither
      # the sentence nor this comment claims anything about the selection now; `detail` carries
      # it.) A code with three producers is healthy; a code with none is dead vocabulary, and
      # this file has a precedent for deleting those.
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
