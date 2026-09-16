# frozen_string_literal: true

require_relative 'failure'

module RedmineReporterDashboards
  module Render
    # `Result = Success | Failure`, the sum type INV-5 is enforced through.
    #
    # Type-driven rather than nil-driven, and that is the whole point: today the render
    # path signals trouble by returning nil, and every caller has to remember to check.
    # `create_attachment` accepts only a Success, so forgetting is a NoMethodError at
    # the seam rather than an empty PDF in someone's inbox.
    # The sum type itself, as a named thing rather than only as a comment.
    #
    # It also has to exist for a MECHANICAL reason worth writing down: Zeitwerk requires
    # `render/result.rb` to define `Render::Result`, and this file first defined only
    # `Success` and `Degradation`. The full application then refused to boot with
    # `expected file .../render/result.rb to define constant
    # RedmineReporterDashboards::Render::Result, but didn't`. So a plugin's lib/ IS
    # scanned here, whatever HANDOVER §1's correction says about autoload paths — see
    # the entry it replaces.
    module Result
      class << self
        def success?(value)
          value.is_a?(Success)
        end

        def failure?(value)
          value.is_a?(Failure)
        end

        # Neither arm of the sum type. A caller that gets this back has an adapter which
        # broke the contract, and Renderer turns it into Failure(:internal).
        def result?(value)
          success?(value) || failure?(value)
        end
      end
    end

    class Success
      attr_reader :bytes, :page_count, :duration_ms, :engine, :engine_version, :degradations

      def initialize(bytes:, engine:, engine_version:, page_count: nil, duration_ms: nil,
                     degradations: [])
        @bytes = bytes
        @page_count = page_count
        @duration_ms = duration_ms
        @engine = engine
        @engine_version = engine_version
        # Frozen list of Degradation, never nil: a caller that reports "what was lost"
        # should not have to nil-check before saying "nothing".
        @degradations = Array(degradations).freeze
        freeze
      end

      def success?
        true
      end

      def failure?
        false
      end

      def degraded?
        !degradations.empty?
      end

      def to_h
        { 'page_count' => page_count, 'duration_ms' => duration_ms, 'engine' => engine,
          'engine_version' => engine_version, 'byte_size' => bytes.to_s.bytesize,
          'degradations' => degradations.map(&:to_h) }.freeze
      end
    end

    # One thing the engine could not do, recorded rather than swallowed. §5 requires it
    # logged, surfaced in diagnostics AND stamped into the PDF metadata — a degradation
    # nobody can see afterwards is indistinguishable from a render that went fine.
    class Degradation
      attr_reader :capability, :detail

      def initialize(capability:, detail: nil)
        @capability = capability
        @detail = detail.to_s.freeze
        freeze
      end

      def to_h
        { 'capability' => capability.to_s, 'detail' => detail }.freeze
      end

      def to_s
        detail.empty? ? capability.to_s : "#{capability}: #{detail}"
      end
    end
  end
end
