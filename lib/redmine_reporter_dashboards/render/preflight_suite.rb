# frozen_string_literal: true

require_relative 'engine_catalogue'
require_relative 'preflight'
require_relative 'registry'

module RedmineReporterDashboards
  module Render
    # Run the preflight against every engine, once, and hand back the reports.
    #
    # --- WHY THIS EXISTS: IT WAS WRITTEN TWICE AND THE COPIES HAD ALREADY DIVERGED ---
    #
    # `PreflightCommand` and `ReporterPreflightController` both needed the same four
    # steps — resolve the engines, construct each adapter, run the preflight, shut the
    # engine down whatever happened — and both had their own copy. They were not
    # identical for long: the shutdown that stops an admin page leaking a browser had to
    # be fixed in two places on the same day, which is the concrete form of CLAUDE.md
    # hard rule 6 ("no second way of doing something that already has a way").
    #
    # What stays with the callers is what genuinely differs: the command owns the exit
    # codes and the output format, the controller owns authorization and a view. This
    # owns the part where a mistake is a leaked browser or a swallowed engine.
    #
    # --- `redmine_base_url` IS A PORT ---
    #
    # This layer must not know how to ask Redmine for its own URL — that is
    # `Setting.protocol`/`host_name`, which would drag `Rails.` under `render/**`
    # (mechanism E5, and the boundary `layer_purity.sh` enforces). Each caller computes
    # it in application code and passes it in.
    class PreflightSuite
      DEFERRED_CHECK_ID = :engine_not_selected

      # EVERY CHECK ID THIS LAYER CAN EMIT, derived rather than listed — the document
      # checks, the fixed ones, this file's deferral, and each registered adapter's own.
      #
      # It exists because `test_every_check_id_the_preflight_can_emit_has_a_label`
      # hand-wrote `DOCUMENT_CHECKS.keys + %i[engine degradations]` under a comment saying
      # "READ OFF THE RENDER LAYER, not typed out here". T-34 added seven emittable ids and
      # the control stayed green, so seven checks reached the admin page — one of them on
      # EVERY install — with no locale key and a silent English fallback.
      def self.emittable_check_ids
        adapter_ids = Registry.ids.flat_map do |id|
          adapter = Registry.fetch(id)
          adapter.const_defined?(:CHECK_TITLES) ? adapter.const_get(:CHECK_TITLES).keys : []
        end
        (Preflight::DOCUMENT_CHECKS.keys + Preflight::FIXED_CHECK_IDS +
          [DEFERRED_CHECK_ID] + adapter_ids).uniq
      end

      # `selected_engine_id` IS A PORT, for the same reason `redmine_base_url` is one: it
      # comes from `Setting.plugin_redmine_reporter_dashboards`, and `render/**` may not read
      # a Setting (mechanism E5). The rake task and the admin controller fill it.
      def initialize(engine_ids: nil, redmine_base_url: nil, logger: nil,
                     selected_engine_id: nil)
        @engine_ids = normalise_ids(engine_ids)
        # A SELECTION THAT WAS GIVEN AND PARSES TO NOTHING IS THE TYPO CASE, NOT THE
        # DEFAULT SET (E-27 row 8). `RRD_ENGINE='  '` and `RRD_ENGINE=','` normalised to
        # an empty list, and an empty list means "run the defaults" — so a mangled
        # selection in a deploy step silently verified engines nobody named, while
        # `RRD_ENGINE=chromium_cpd` correctly exited 2. The rule cuts at NON-EMPTY: `nil`
        # and `''` still mean "nobody selected" (unset and `VAR=` are how an environment
        # says that), and anything carrying a character that then yields no id raises the
        # same `UnknownEngine` a typo does. Recorded here rather than in `resolved_ids`
        # so the raw value is still in hand for the message.
        @unparseable_selection =
          @engine_ids.empty? && Array(engine_ids).any? { |id| !id.to_s.empty? } &&
          engine_ids.inspect
        @redmine_base_url = redmine_base_url
        @logger = logger
        selected = selected_engine_id.to_s.strip
        @selected_engine_id = selected.empty? ? nil : selected
      end

      attr_reader :engine_ids, :redmine_base_url, :logger, :selected_engine_id

      # Raises `Registry::UnknownEngine` when the caller named an id the registry does
      # not have. A TYPO MUST NOT LOOK LIKE A CLEAN RUN — `RRD_ENGINE=chromium_cpd`
      # matching zero engines and reporting success is the same defect as an empty
      # registry reporting success, one level up. What each caller *does* about it is
      # theirs; that it cannot pass silently is decided here.
      # AN ENGINE THAT NEEDS A SERVICE IS NOT IN THE DEFAULT SET, and this is the same
      # rule `Reporting::ReportRun#resolve_engine` applies when it picks an engine to draw
      # with — T-34 added it there and, for one afternoon, not here.
      #
      # The consequence was measured by two independent reviews: registering `:gotenberg`
      # at boot put it into `Registry.ids`, so `rake reporter_dashboards:render:preflight`
      # EXITED 1 on every install that does not run a container the documentation calls
      # optional, and the admin page carried a permanent red row saying "the render service
      # could not be reached — http://localhost:3000". Unlike a missing Chromium, that is
      # not something the operator can fix by installing anything; they have not chosen
      # Gotenberg, they have simply not chosen. And the README's own contract — "exit 0,
      # so the task can be a deploy step" — was broken by an engine nobody asked for.
      #
      # It is EXCLUDED, NOT HIDDEN. A silently shorter list is the failure mode this file's
      # own `resolved_ids` comment is about one paragraph down, so each excluded engine
      # still gets a report, carrying one `:skip` that names it and says how to check it
      # deliberately. A skip does not turn the exit code non-zero (`Preflight::Check#ok?`)
      # and does keep the JSON artefact the same shape on every install, which is a
      # property `Preflight::DOCUMENT_CHECKS` goes to some trouble to preserve.
      #
      # NAMING AN ENGINE OVERRIDES THIS ENTIRELY. `RRD_ENGINE=gotenberg` is how you ask,
      # and asking is a decision — so it runs the real checks, including the credential one.
      #
      # FR-50 — AND THE INSTALL'S OWN CHOICE IS NOT A DEFERRAL CASE. This is the THIRD place
      # the same rule has had to be written, and E-27 said so in as many words: "a rule about
      # 'an install has not chosen this' belongs everywhere an engine is chosen FOR the
      # operator, and there were two such places". FR-50 gives an install a way to choose, so
      # without this the skip's own sentence — "the render engine needs a service, and this
      # install has not chosen it" — would be FALSE on exactly the installs that chose one,
      # and the one diagnostic that exists to check the render path would refuse to check the
      # engine it renders with. Naming an engine explicitly still overrides all of it.
      def default_ids
        Registry.ids.reject { |id| deferred?(id) }
      end

      def deferred_ids
        Registry.ids.select { |id| deferred?(id) }
      end

      def deferred?(id)
        service_engine?(id) && !selected?(id)
      end

      def selected?(id)
        !selected_engine_id.nil? && id.to_s == selected_engine_id
      end

      def service_engine?(id)
        !EngineCatalogue.load.auto_selectable?(id.to_s)
      rescue StandardError
        # A catalogue that will not load must not silence an engine. Running one that
        # cannot be reached is a worse diagnostic than the truth and a better one than
        # nothing.
        false
      end

      def deferred_report(id)
        Preflight::Report.new(
          engine_id: id, engine_version: 'not checked', duration_ms: 0,
          checks: [Preflight::Check.new(
            id: :engine_not_selected, state: :skip,
            title: 'the render engine needs a service, and this install has not chosen it',
            # `RRD_ENGINE=…` COMES FIRST. The text surface truncates a detail at 90
            # characters (`preflight.rb`'s `one_line`), and in the first version the only
            # actionable words started at index 120 — thirty past the cut. The example
            # that "proved" the remediation asserted on the Check object and never on
            # rendered output, which is the same shape as the blocker this commit fixes.
            # `RRD_ENGINE=…` STILL COMES FIRST (the text surface cuts a detail at 90
            # characters), and the last clause had to change when FR-50 landed: "used only
            # by a template that names it" stopped being true the moment an installation
            # could choose one.
            detail: "run with RRD_ENGINE=#{id} to check it deliberately, including its " \
                    'credential. Or pick it in the engine selector on this page, or as ' \
                    "this installation's engine in Administration → Plugins. #{id} needs " \
                    'a service, so nothing selects it for you.',
            duration_ms: 0
          )]
        )
      end

      def resolved_ids
        if @unparseable_selection
          raise Registry::UnknownEngine,
                "an engine selection was given (#{@unparseable_selection}) but names " \
                "no render engine. Known: #{Registry.ids.map(&:to_s).join(', ')}."
        end
        return default_ids if engine_ids.empty?

        unknown = engine_ids.reject { |id| Registry.registered?(id) }
        unless unknown.empty?
          raise Registry::UnknownEngine,
                "no render engine registered as #{unknown.map(&:to_s).join(', ')}. " \
                "Known: #{Registry.ids.map(&:to_s).join(', ')}."
        end

        engine_ids
      end

      def reports
        listed = resolved_ids.map { |id| report_for(id) }
        return listed unless engine_ids.empty?

        listed + deferred_ids.map { |id| deferred_report(id) }
      end

      private

      # A construction failure is a REPORT, not an exception out of a diagnostic.
      # "Chromium is not installed" is the single most likely thing this finds, and it
      # is an answer — a stack trace tells the operator less than the check that says so
      # by name.
      #
      # THE ENGINE IS SHUT DOWN, EVERY TIME. The Chromium adapter owns a process pool
      # that starts a browser on its first render, and running every registered engine
      # is the default. Without the `ensure`, an administrator clicking the button three
      # times leaves three browsers alive for the lifetime of the web worker — a
      # diagnostic whose own side effect is the resource leak it exists to detect.
      def report_for(id)
        engine = Registry.fetch(id).new
        begin
          Preflight.new(engine: engine, redmine_base_url: redmine_base_url,
                        logger: logger).run
        ensure
          shutdown(engine, id)
        end
      rescue StandardError => e
        unstartable_report(id, e)
      end

      def unstartable_report(id, error)
        warn_line("[render] preflight could not start #{id}: #{error.class}: #{error.message}")
        Preflight::Report.new(
          engine_id: id, engine_version: 'unavailable', duration_ms: 0,
          checks: [Preflight::Check.new(
            id: :engine, title: 'the render engine could be started', state: :fail,
            detail: "#{error.class}: #{error.message}", duration_ms: 0
          )]
        )
      end

      # A cleanup error must not destroy a completed report — it is already built by the
      # time this runs, and losing it to a shutdown failure would be the worst possible
      # trade. Logged rather than swallowed: `rescue nil` is a forbidden construct here
      # (CLAUDE.md §5), and a browser that would not stop is something an operator wants
      # to know about.
      def shutdown(engine, id)
        engine.shutdown if engine.respond_to?(:shutdown)
      rescue StandardError => e
        warn_line("[render] preflight could not shut down #{id}: #{e.class}: #{e.message}")
      end

      def warn_line(line)
        logger.warn(line) if logger.respond_to?(:warn)
      end

      def normalise_ids(ids)
        Array(ids).flat_map { |id| id.to_s.split(',') }
                  .map { |id| id.strip.to_sym }
                  .reject { |id| id.to_s.empty? }
                  .uniq
      end
    end
  end
end
