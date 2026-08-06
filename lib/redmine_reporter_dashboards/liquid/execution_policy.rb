# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # What a template is ALLOWED to spend, and how long it has to spend it.
    #
    # Today: `parse(content).render(...)` with no resource limits at all, output marked
    # `html_safe`, and errors returned AS THE DOCUMENT. A template author — who is
    # already privileged, INV-9 — can currently write a loop that allocates until the
    # worker dies, and the first sign of it is an OOM kill in a process that was serving
    # other people's requests.
    #
    # --- TWO MECHANISMS, AND NEITHER ALONE IS ENOUGH ---
    #
    # `technical-spec.md` §4 is unusually blunt about this, and it is worth restating
    # because the temptation is always to pick one:
    #
    #   RESOURCE LIMITS bound WORK UNITS. Liquid counts output length, render score and
    #   assign score. They stop a runaway `{% for %}` and they are the only thing that
    #   can, because that loop never yields to us.
    #
    #   THE DEADLINE bounds TIME. A `{% sql_aggregate %}` running a ninety-second query
    #   costs exactly ONE render-score point. No resource limit will ever notice it.
    #
    # So both. And the honest limitation, stated where the mechanism is rather than in a
    # release note: **the deadline is COOPERATIVE — it bounds only where we cooperate.**
    # An adversarial `{% for %}` using nothing but core filters still burns CPU until a
    # resource limit trips. That is what the resource limits are for. Neither is a
    # substitute for the other, and a future change that drops one because "the other
    # covers it" is reintroducing a defect this file exists to close.
    #
    # --- WHY NOT `Timeout.timeout` ---
    #
    # Because it interrupts wherever the thread happens to be, and where the thread
    # happens to be is usually inside ActiveRecord. Interrupting a query mid-statement
    # leaves the connection in a state the pool cannot reason about, and the pool is
    # shared with every other request on the process. That trades a slow render for a
    # poisoned pool: one report that took too long becomes an application that is down.
    class ExecutionPolicy
      # The closed set. An output class is not a hint — it selects the limits, so an
      # unknown one must be a loud error rather than a silent default to the most
      # generous profile.
      OUTPUT_CLASSES = %i[widget report preview].freeze

      # From `technical-spec.md` §4. `[OQ-J]` there says it plainly and it is repeated
      # here because the numbers look more authoritative than they are: **the MECHANISM
      # is the decision; these constants are a starting calibration**, meant to sit at
      # roughly 10x the reference corpus's measured p95. Move them with a measurement,
      # not with a hunch, and if you move them because something legitimate hit a limit
      # then the measurement is the thing that hit it.
      LIMITS = {
        # A dashboard widget. Small, many per page, and rendered while somebody waits.
        widget: { render_length_limit: 2_000_000,
                  render_score_limit: 200_000,
                  assign_score_limit: 500_000,
                  deadline_ms: 5_000 },

        # A full report, rendered once and often unattended. Eight times the output and
        # ten times the score, because a quarterly issue list legitimately is that big.
        report: { render_length_limit: 16_000_000,
                  render_score_limit: 2_000_000,
                  assign_score_limit: 4_000_000,
                  deadline_ms: 30_000 },

        # PREVIEW GETS THE WIDGET'S LIMITS ON PURPOSE, and this is the one line in the
        # table that looks like a mistake. An author previewing a template should feel
        # the limit AT THE KEYBOARD, where they can do something about it — not at
        # 06:00 in a scheduled run nobody is watching. A generous preview is a preview
        # that lies about what the template will do in production.
        preview: { render_length_limit: 2_000_000,
                   render_score_limit: 200_000,
                   assign_score_limit: 500_000,
                   deadline_ms: 10_000 }
      }.freeze

      # `:strict` per parse. Liquid's default `:lax` silently accepts `{{ foo | bar }}`
      # with a filter that does not exist and renders nothing where the author expected
      # a number — which reaches a reader as a blank cell in a report they trust.
      ERROR_MODE = :strict

      # An unknown FILTER is an authoring mistake and must be loud. An unknown VARIABLE
      # is not: `{{ issue.due_date }}` on an issue without one is ordinary, and a
      # template that has to guard every optional field is a template nobody maintains.
      STRICT_FILTERS = true
      STRICT_VARIABLES = false

      class UnknownOutputClass < ArgumentError; end

      attr_reader :output_class, :render_length_limit, :render_score_limit,
                  :assign_score_limit, :deadline_ms

      def initialize(output_class, deadline_ms: nil)
        @output_class = output_class.to_sym
        limits = LIMITS[@output_class]
        unless limits
          raise UnknownOutputClass,
                "#{output_class.inspect} is not an output class. Known: " \
                "#{OUTPUT_CLASSES.inspect}. The class selects the limits, so guessing " \
                'one would mean rendering under limits nobody chose.'
        end

        @render_length_limit = limits[:render_length_limit]
        @render_score_limit = limits[:render_score_limit]
        @assign_score_limit = limits[:assign_score_limit]
        # Overridable so an install can tighten it. Deliberately the only overridable
        # number here: the resource limits are a calibration this project owns, while
        # how long a request may take is a property of the deployment.
        @deadline_ms = Integer(deadline_ms || limits[:deadline_ms])
        freeze
      end

      # Plain defs, not endless ones: the floor is Ruby 2.7 (Redmine 5.1) and
      # `def foo = expr` arrived in 3.0. `.codex/check_ruby_floor.sh` is the gate.
      def self.widget(**options)
        new(:widget, **options)
      end

      def self.report(**options)
        new(:report, **options)
      end

      def self.preview(**options)
        new(:preview, **options)
      end

      def error_mode
        ERROR_MODE
      end

      def strict_filters?
        STRICT_FILTERS
      end

      def strict_variables?
        STRICT_VARIABLES
      end

      # Built fresh per render, never shared: `Liquid::ResourceLimits` ACCUMULATES as it
      # goes, so a reused instance would charge the second render for the first one's
      # work and refuse a template that is perfectly fine on its own.
      #
      # Constructed here rather than set on the Template because Liquid exposes no
      # per-template setter on either 4 or 5 — the only per-render channel is the
      # `Liquid::Context` constructor. `Template.default_resource_limits` is the
      # alternative and it is GLOBAL, which would mean a widget's limits applying to
      # whatever report rendered next on the same process. Verified identical on
      # Liquid 4.0.4 and 5.13.0.
      def resource_limits
        ::Liquid::ResourceLimits.new(
          render_length_limit: render_length_limit,
          render_score_limit: render_score_limit,
          assign_score_limit: assign_score_limit
        )
      end

      def budget(clock: nil)
        Budget.new(deadline_ms: deadline_ms, clock: clock)
      end

      def to_h
        { 'output_class' => output_class.to_s,
          'render_length_limit' => render_length_limit,
          'render_score_limit' => render_score_limit,
          'assign_score_limit' => assign_score_limit,
          'deadline_ms' => deadline_ms }.freeze
      end
    end

    # The cooperative wall-clock deadline.
    #
    # Cooperative means: it is checked, not enforced. Every one of our own tags asks it
    # whether there is time left, at the top of `render`; so does every collection batch
    # boundary and every prefetch. Between those points nothing stops anything, which is
    # the honest description of the mechanism and the reason resource limits exist
    # beside it.
    #
    # MONOTONIC, always. A deadline measured against the wall clock moves when NTP
    # steps the machine, and the direction it moves is not something a render should
    # depend on.
    class Budget
      class DeadlineExceeded < StandardError
        attr_reader :elapsed_ms, :deadline_ms, :checkpoint

        def initialize(checkpoint:, elapsed_ms:, deadline_ms:)
          @checkpoint = checkpoint
          @elapsed_ms = elapsed_ms
          @deadline_ms = deadline_ms
          super("the template ran out of time at #{checkpoint} " \
                "(#{elapsed_ms.round}ms of #{deadline_ms}ms)")
        end
      end

      attr_reader :deadline_ms, :started_at

      def initialize(deadline_ms:, clock: nil)
        @deadline_ms = Integer(deadline_ms)
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0 }
        @started_at = @clock.call
      end

      def elapsed_ms
        @clock.call - @started_at
      end

      def remaining_ms
        [deadline_ms - elapsed_ms, 0].max
      end

      def exceeded?
        elapsed_ms >= deadline_ms
      end

      # THE ONE LINE EVERY OWN TAG CALLS. Named after the checkpoint so the exception
      # says WHERE the time ran out — "at sql_aggregate" and "at collection_batch" send
      # whoever reads it to different places, and a bare "timed out" sends them nowhere.
      def check!(checkpoint)
        return true unless exceeded?

        raise DeadlineExceeded.new(checkpoint: checkpoint, elapsed_ms: elapsed_ms,
                                   deadline_ms: deadline_ms)
      end

      REGISTER_KEY = :rrd_budget

      # A NO-OP BUDGET WHEN THERE IS NONE, and that is what makes the check safe to put
      # in a tag today. These tags still run inside the host plugin's renderer, which
      # binds no budget; there, `check!` costs a hash lookup and does nothing. A version
      # that raised on a missing budget would make adding the call site a behaviour
      # change for every existing install.
      def self.from(liquid_context)
        registers = liquid_context.registers if liquid_context.respond_to?(:registers)
        candidate = registers[REGISTER_KEY] if registers.respond_to?(:[])
        candidate.is_a?(self) ? candidate : NULL
      end

      # The null object, which is a real object rather than a nil check at every call
      # site — a nil check that has to be repeated is a nil check somebody forgets.
      class Null
        def check!(_checkpoint)
          true
        end

        def exceeded?
          false
        end

        def elapsed_ms
          0
        end

        def remaining_ms
          Float::INFINITY
        end

        def deadline_ms
          nil
        end
      end

      NULL = Null.new
    end
  end
end
