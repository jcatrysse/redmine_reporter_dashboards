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
        javascript modern_javascript readiness_expression print_backgrounds header footer
        page_furniture_tokens custom_page_size landscape margins scale
        page_break_css media_print outline tagged_pdf pdf_metadata
        asset_inline asset_upload asset_http timeout
      ].freeze

      # --- `:modern_javascript`, and why it is NOT `:mermaid` (T-35, FR-68b) ---
      #
      # `:javascript` means "the engine has a script engine". It says nothing about WHICH
      # JavaScript, and that turned out to be the only question a report author actually
      # has. MEASURED 2026-08-06: wkhtmltopdf declares `:javascript` and cannot **parse**
      # `x.a ||= 1` — a whole `<script>` block dies at parse time, the statement before the
      # assignment never runs, and `globalThis` is undefined as well
      # (technical-spec.md §6.1). So it cannot run Mermaid 11, and it cannot run Chart.js 4
      # either, or anything else published in the last several years.
      #
      # The first draft of T-35 proposed `:mermaid`. That would answer one question and lie
      # by omission about every other library — and this plugin's purpose is a report that
      # can use ANY modern library, with Chart.js and Mermaid as examples rather than as the
      # feature (§Findings F-17). One capability that means *post-ES5 JavaScript runs here*
      # tells an author the truth once and needs no new entry when the next library arrives.
      #
      # It passes the test F-14 applied to `:responsive_canvas` and failed it on: an engine
      # either does or does not, the answer is a property of the ENGINE rather than of the
      # output binding, and absence is a real degradation with something to record.
      MODERN_JAVASCRIPT_FLOOR = 'ES2015 (arrow functions, classes, template literals) ' \
                                'through ES2021 (logical assignment, optional chaining)'

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
