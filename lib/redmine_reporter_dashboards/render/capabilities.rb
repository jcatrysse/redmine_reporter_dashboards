# frozen_string_literal: true

module RedmineReporterDashboards
  module Render
    # The CLOSED capability vocabulary (technical-spec.md §5).
    #
    # Closed on purpose. An open vocabulary lets an adapter declare `:whatever` and lets
    # a request require it, and the two never meet — the negotiation below would then
    # always succeed, which is the same as not having one. Anything outside this set is
    # a programming error and says so.
    #
    # G12, the three-state rule, is the reason ESSENTIAL and DEGRADABLE are separate
    # ideas rather than a boolean on the request: an UNDECLARED capability skips with a
    # reason, a DECLARED one that fails is a hard failure, and a degradable one that is
    # absent proceeds and is recorded. Those are three outcomes, not two.
    module Capabilities
      ALL = %i[
        javascript readiness_expression print_backgrounds header footer
        page_furniture_tokens custom_page_size landscape margins scale
        page_break_css media_print outline tagged_pdf pdf_metadata
        asset_inline asset_upload asset_http timeout
      ].freeze

      # Absent → the render is REFUSED, naming the capability. The set is deliberately
      # small: everything else degrades, because a report that loses its outline is
      # still a report and a report that loses its charts is not.
      #
      # `:javascript` and `:readiness_expression` are essential IFF the document
      # actually contains a JS-drawn chart — the caller decides that per request and
      # passes them in `required`, which is why they are not listed here as always
      # essential. §5: "essential iff ChartCollector recorded a JS-path chart".
      DEFAULT_ESSENTIAL = %i[].freeze

      class UnknownCapability < ArgumentError; end

      class << self
        def known?(capability)
          ALL.include?(capability)
        end

        # Raises rather than filtering. A typo'd capability that is silently dropped
        # produces a request that requires nothing and an engine that satisfies it.
        def validate!(capabilities, what)
          list = Array(capabilities)
          unknown = list.reject { |capability| known?(capability) }
          return list.map(&:to_sym).uniq.freeze if unknown.empty?

          raise UnknownCapability,
                "#{what}: #{unknown.inspect} is not in the closed capability vocabulary. " \
                "Known: #{ALL.inspect}"
        end

        # The negotiation, as data rather than as control flow, so it can be asserted
        # without running an engine.
        #
        #   missing = required - engine.capabilities
        #   essential missing -> refuse, naming it
        #   degradable missing -> proceed, and RECORD it
        def negotiate(required:, essential:, available:)
          missing = (Array(required).map(&:to_sym) - Array(available).map(&:to_sym)).uniq
          blocking = missing & Array(essential).map(&:to_sym)

          { missing: missing.freeze,
            blocking: blocking.freeze,
            degradations: (missing - blocking).freeze }
        end
      end
    end
  end
end
