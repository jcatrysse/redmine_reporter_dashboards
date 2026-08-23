# frozen_string_literal: true

require_relative 'result'

module RedmineReporterDashboards
  module Render
    # The Ruby half of the readiness contract — what to wait for, how long, and what to
    # do when the wait runs out. The DOM half is `assets/javascripts/chart_shell.js`.
    #
    # WHAT THIS REPLACES: a flat `javascript_delay: 3000` with the engine's runaway-script
    # guard switched OFF, plus a `window.status` handshake that nothing reads. A guessed
    # delay is wrong in both directions at once — a chart-free document waits three
    # seconds for nothing, and three slow charts are cut off at three.
    #
    # THREE SIGNALS, ONE CONTRACT. The engines cannot agree on how to be asked:
    #
    #   EXPRESSION  `window.__rd && window.__rd.ready === true`   Chromium, Gotenberg
    #   ATTRIBUTE   `data-rd-ready="1"` on <html>                 any DOM-only engine
    #   STATUS      `window.status === 'rd-ready'`                wkhtmltopdf
    #
    # All three are set at the same instant by the shell, so no engine needs a different
    # document — which is the property that makes the engine swappable at all.
    class Readiness
      EXPRESSION = 'window.__rd && window.__rd.ready === true'
      ATTRIBUTE = 'data-rd-ready'
      ATTRIBUTE_VALUE = '1'
      STATUS = 'rd-ready'

      # 10 s to give up, and the IN-PAGE watchdog fires at 8 s — deliberately sooner.
      # If the page declares itself ready the engine gets a clean signal and a recorded
      # reason; if only the engine times out, all anyone knows is that nothing answered.
      # A page that can say why it gave up is worth more than one that was cut off.
      DEFAULT_TIMEOUT_MS = 10_000
      DEFAULT_CLIENT_TIMEOUT_MS = 8_000
      DEFAULT_POLL_INTERVAL_MS = 50

      # wkhtmltopdf's --window-status races: it can miss a status set before it starts
      # watching. A floor is not a fudge here, it is the documented shape of that
      # engine's signal, and it is per-engine rather than global for that reason.
      WINDOW_STATUS_FLOOR_MS = 250

      attr_reader :timeout_ms, :client_timeout_ms, :poll_interval_ms, :strict

      def initialize(timeout_ms: DEFAULT_TIMEOUT_MS,
                     client_timeout_ms: DEFAULT_CLIENT_TIMEOUT_MS,
                     poll_interval_ms: DEFAULT_POLL_INTERVAL_MS,
                     strict: false)
        @timeout_ms = Integer(timeout_ms)
        @client_timeout_ms = Integer(client_timeout_ms)
        @poll_interval_ms = Integer(poll_interval_ms)
        @strict = strict ? true : false
        validate!
        freeze
      end

      def strict?
        strict
      end

      # What to hand a given engine, chosen from what it says it can do rather than from
      # its name — an engine that gains a JS evaluator should get the better signal
      # without this file learning about it.
      def signal_for(capabilities)
        available = Array(capabilities).map(&:to_sym)
        return { kind: :expression, value: EXPRESSION } if available.include?(:readiness_expression)

        { kind: :attribute, value: ATTRIBUTE, expected: ATTRIBUTE_VALUE }
      end

      # ON TIMEOUT THE ENGINE STILL RENDERS. A chart-less-but-otherwise-correct document
      # beats no document: the tables, the totals and the narrative are all there, and
      # the reader is told what is missing. `strict` inverts that for the caller who
      # would rather have nothing than something incomplete.
      #
      # Returns the Degradation to attach, or nil when strict — in which case the caller
      # raises the failure instead. Two returns rather than a boolean so the pending
      # count travels with the decision.
      def on_timeout(pending:)
        return nil if strict?

        Degradation.new(capability: :readiness_timeout,
                        detail: "#{pending} chart(s) had not finished after #{timeout_ms}ms")
      end

      def to_h
        { 'timeout_ms' => timeout_ms, 'client_timeout_ms' => client_timeout_ms,
          'poll_interval_ms' => poll_interval_ms, 'strict' => strict }.freeze
      end

      private

      # The client watchdog must fire FIRST or it can never fire at all, and the whole
      # point of having one is that the page gets to explain itself.
      def validate!
        return if client_timeout_ms < timeout_ms

        raise ArgumentError,
              "client_timeout_ms (#{client_timeout_ms}) must be less than timeout_ms " \
              "(#{timeout_ms}); a watchdog that fires after the engine has already given " \
              'up never runs, and the degradation it would have recorded is lost.'
      end
    end
  end
end
