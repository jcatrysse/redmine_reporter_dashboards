# frozen_string_literal: true

require 'json'

require_relative 'preflight_suite'
require_relative 'registry'

module RedmineReporterDashboards
  module Render
    # `rake reporter_dashboards:render:preflight`, minus rake.
    #
    # --- WHY THIS IS A CLASS AND NOT A RAKE TASK ---
    #
    # `lib/tasks/reporter_dashboards.rake` already sets the pattern and states the
    # reason: a rake file that grew a method is a place tests cannot reach. Everything
    # with a decision in it — what the exit code means, what happens when there are no
    # engines, what a typo does — lives here, and the task is glue.
    #
    # Running the engines is NOT one of those decisions: that is `PreflightSuite`, which
    # the admin controller shares. See its comment for why it was extracted.
    #
    # --- THE EXIT CODE IS THE PRODUCT ---
    #
    # An operator's real use for this is a deploy step, and a deploy step reads one
    # number. So the exit codes are few and each means one thing:
    #
    #   0  every check that ran passed (skips are reported, and forgiven — see Preflight)
    #   1  at least one check failed
    #   2  nothing was run, so nothing was verified
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

      # Engine adapters register themselves at require time and live in one directory.
      # Every operator surface needs the same sweep before constructing this command —
      # the rake task and `script/render_preflight_standalone.rb` — and two copies of
      # the glob are how those surfaces drift (CLAUDE.md hard rule 6; an independent
      # review flagged the second copy the day it appeared).
      def self.load_engines!
        Dir[File.join(__dir__, 'engines', '*.rb')].sort.each { |path| require path }
      end

      FORMATS = %i[text json].freeze

      def initialize(engine_ids: nil, redmine_base_url: nil, format: :text,
                     out: $stdout, logger: nil)
        @suite = PreflightSuite.new(engine_ids: engine_ids,
                                    redmine_base_url: redmine_base_url, logger: logger)
        @format = format.to_sym
        @out = out
        return if FORMATS.include?(@format)

        raise ArgumentError, "unknown format #{format.inspect}; one of #{FORMATS.inspect}"
      end

      attr_reader :suite, :format, :out

      def call
        reports = suite.reports
        return nothing_registered if reports.empty?

        emit(reports)
        reports.all?(&:ok?) ? OK : FAILURES
      rescue Registry::UnknownEngine => e
        unknown_engine(e)
      end

      private

      # A TYPO IS NOT A RENDER DEFECT, AND IT IS CERTAINLY NOT SUCCESS.
      #
      # `PreflightSuite` raises rather than matching nothing, which is right — but the
      # first version let the exception out of `call`, so rake aborted with a stack trace
      # and exit code **1**, indistinguishable from `FAILURES`. An operator who typed
      # `RRD_ENGINE=chromium_cpd` in a deploy step was told "render is broken". It lands
      # on 2 with the rest of "nothing was verified", where it belongs.
      def unknown_engine(error)
        out.puts("render preflight: #{error.message} Nothing was verified.")
        NOTHING_TO_RUN
      end

      def nothing_registered
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
    end
  end
end
