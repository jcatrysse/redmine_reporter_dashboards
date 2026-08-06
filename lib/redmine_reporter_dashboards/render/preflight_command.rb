# frozen_string_literal: true

require_relative 'preflight'
require_relative 'registry'

module RedmineReporterDashboards
  module Render
    # `rake reporter_dashboards:render:preflight`, minus rake.
    #
    # --- WHY THIS IS A CLASS AND NOT A RAKE TASK ---
    #
    # `lib/tasks/reporter_dashboards.rake` already sets the pattern and states the
    # reason: a rake file that grew a method is a place tests cannot reach. Everything
    # with a decision in it — which engines to run, what the exit code means, what
    # happens when there are none — lives here, and the task is four lines of glue.
    #
    # --- THE EXIT CODE IS THE PRODUCT ---
    #
    # An operator's real use for this is a deploy step, and a deploy step reads one
    # number. So the exit codes are few and each means one thing:
    #
    #   0  every check that ran passed (skips are reported, and forgiven — see Preflight)
    #   1  at least one check failed
    #   2  there was nothing to run, so nothing was verified
    #
    # 2 is separate from 1 on purpose. "No engine is registered" is not a render defect,
    # and it must not be reported as one — but it absolutely must not be a 0 either,
    # because a green preflight that verified nothing is the failure mode this
    # repository keeps rediscovering.
    #
    # --- `redmine_base_url` IS A PORT ---
    #
    # This layer must not know how to ask Redmine for its own URL. That is
    # `Setting.protocol`/`host_name`, which lives in the application and would drag
    # `Rails.` under `render/**` — mechanism E5, and the boundary `layer_purity.sh`
    # enforces. The rake task computes it and passes it in.
    class PreflightCommand
      OK = 0
      FAILURES = 1
      NOTHING_TO_RUN = 2

      FORMATS = %i[text json].freeze

      def initialize(engine_ids: nil, redmine_base_url: nil, format: :text,
                     out: $stdout, logger: nil)
        @engine_ids = normalise_ids(engine_ids)
        @redmine_base_url = redmine_base_url
        @format = format.to_sym
        @out = out
        @logger = logger
        return if FORMATS.include?(@format)

        raise ArgumentError, "unknown format #{format.inspect}; one of #{FORMATS.inspect}"
      end

      attr_reader :engine_ids, :redmine_base_url, :format, :out

      def call
        ids = resolve_ids
        return nothing_to_run(ids) if ids.empty?

        reports = ids.map { |id| report_for(id) }
        emit(reports)
        reports.all?(&:ok?) ? OK : FAILURES
      end

      private

      # A report per engine, and a CONSTRUCTION failure is one of them rather than an
      # exception out of a diagnostic. "Chromium is not installed" is the single most
      # likely thing this command finds, and it is an answer, not a crash.
      # The engine is shut down before the next one starts. Running two engines in one
      # invocation is the default (no `RRD_ENGINE`), and leaving the first one's browser
      # alive while the second launches doubles the memory a diagnostic costs — on a box
      # whose render path is already suspect. `ensure`, so it happens on the failure path
      # too, which is the one where a half-started engine is most likely to be holding
      # something.
      def report_for(id)
        adapter = Registry.fetch(id)
        engine = adapter.new
        begin
          Preflight.new(engine: engine, redmine_base_url: redmine_base_url, logger: @logger).run
        ensure
          shutdown(engine, id)
        end
      rescue StandardError => e
        Preflight::Report.new(
          engine_id: id, engine_version: 'unavailable', duration_ms: 0,
          checks: [Preflight::Check.new(
            id: :engine, title: 'the render engine could be started', state: :fail,
            detail: "#{e.class}: #{e.message}", duration_ms: 0
          )]
        )
      end

      # A cleanup error must not destroy a completed report. Reported on the command's
      # own output rather than swallowed — `rescue nil` is a forbidden construct here,
      # and a browser that would not shut down is something an operator wants to know.
      def shutdown(engine, id)
        engine.shutdown if engine.respond_to?(:shutdown)
      rescue StandardError => e
        out.puts("render preflight: #{id} did not shut down cleanly (#{e.class}: #{e.message})")
      end

      # An id the caller named and the registry does not have is an ERROR, not a quiet
      # omission — `RRD_ENGINE=chromium_cpd` (sic) must not report a clean run of the
      # zero engines that matched.
      def resolve_ids
        return Registry.ids if engine_ids.empty?

        unknown = engine_ids.reject { |id| Registry.registered?(id) }
        unless unknown.empty?
          raise Registry::UnknownEngine,
                "no render engine registered as #{unknown.map(&:to_s).join(', ')}. " \
                "Known: #{Registry.ids.map(&:to_s).join(', ')}."
        end

        engine_ids
      end

      def nothing_to_run(_ids)
        out.puts('render preflight: NO ENGINE REGISTERED — nothing was verified. ' \
                 'Load an engine adapter (lib/redmine_reporter_dashboards/render/engines) ' \
                 'before running this.')
        NOTHING_TO_RUN
      end

      def emit(reports)
        if format == :json
          out.puts(JSON.pretty_generate(reports.map(&:to_h)))
        else
          out.puts(reports.map(&:to_text).join("\n\n"))
        end
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
