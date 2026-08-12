# frozen_string_literal: true

module RedmineReporterDashboards
  # ONE DEGRADATION, AS A SENTENCE A READER CAN ACT ON — and, where a key exists, in their
  # own language.
  #
  # --- WHY THIS IS A MODULE AND NOT (ONLY) A HELPER ---
  #
  # It lived entirely in `ReporterDashboards::TemplatesHelper`, which is correct for the
  # template editor and unreachable from a my-page widget: Redmine sets
  # `include_all_helpers = false` (`config/application.rb:73`), so `MyController` sees its
  # own helper, `ApplicationHelper` and the five it declares — none of them ours. This is
  # the same move `ReportFrame` made in T-26a increment 1 and for the same reason, which is
  # also why it is a MOVE: `TemplatesHelper` delegates here, so there is one copy used by
  # three surfaces rather than two copies that can drift.
  #
  # Declaring our helper onto `MyController` would also have worked and is one line. It was
  # not taken because this task had already answered the same question once, and a second
  # mechanism for "reach our presentation code from a core-controller view" is the "second
  # way of doing something that already has a way" CLAUDE.md §6 forbids.
  #
  # --- WHAT THIS FIXES, AND WHAT IT DELIBERATELY DOES NOT ---
  #
  # `Degradation#to_s` answers `aggregation_dimension_unknown: group_by: "activty" is not a
  # time-entry dimension (2x)` — a symbol and an English sentence built in `lib/`, printed
  # verbatim. The whole gap is §Findings **S-17** and it spans fifteen codes across four
  # layers, which is its own task. What this closes is the codes that have a key; every
  # other code prints exactly as it did, and adding a key later is the only change needed.
  #
  # THE FALLBACK IS NOT DECORATION. `technical-spec.md` §7 rule 5 makes "an install one
  # minor behind reading a newer row" routine, and a code from a newer version of this
  # plugin — or a typo in a key — must still print something the reader can quote into a
  # bug report rather than nothing at all.
  #
  # --- TWO VOCABULARIES REACH THIS LIST, AND ONLY ONE OF THEM ANSWERS `#code` ---
  #
  # `Outcome#degradations` is `diagnostics.degradations + batch.successes.flat_map(...)` —
  # a `Liquid::Diagnostics::Degradation` (`code`/`detail`/`data`/`count`) next to a
  # `Render::Degradation` (`capability`/`detail`), and the two classes are deliberately
  # separate. Reading `#code` off both is §Findings **E-25**: every wkhtmltopdf render 500'd
  # the preview page, because that adapter stamps `Degradation(:legacy_engine)` into every
  # `Success` by design. The normalisation lives here because a view is the one place that
  # must speak both.
  module DegradationText
    class << self
      include ::Redmine::I18n

      def for(degradation)
        body = sentence(degradation) || degradation.to_s
        count = count_of(degradation)
        return body unless count > 1

        "#{body} (#{count}x)"
      end

      def sentence(degradation)
        code = code_of(degradation)
        return nil if code.nil?

        key = :"text_reporter_degradation_#{code}"
        text = l(key, default: '', **data_of(degradation))
        text.to_s.strip.empty? ? nil : text
      rescue ::I18n::MissingInterpolationArgument, ::ArgumentError
        nil
      end

      # `code` on the Liquid side, `capability` on the render side. Both name the same thing
      # — which degradation this is — so both get a `text_reporter_degradation_<name>` key
      # and neither needs one: the raw `to_s` fallback is unchanged for both.
      def code_of(degradation)
        return degradation.code if degradation.respond_to?(:code)
        return degradation.capability if degradation.respond_to?(:capability)

        nil
      end

      # A `Render::Degradation` carries no interpolation data and is not deduplicated, so it
      # is one occurrence with no arguments. Answering that here keeps the two shapes out of
      # `.for`, where a `respond_to?` per field would read as a puzzle.
      def data_of(degradation)
        return {} unless degradation.respond_to?(:data)

        degradation.data.transform_keys(&:to_sym)
      end

      def count_of(degradation)
        return 1 unless degradation.respond_to?(:count)

        degradation.count
      end
    end
  end
end
