# frozen_string_literal: true

require_relative 'support'

module RedmineReporterDashboards
  module Liquid
    module Filters
      # `avg median min max sum`, in their property forms:
      #
      #   {{ issues | avg: "estimated_hours" }}
      #   {{ issues | sum: "spent_hours" }}
      #   {{ numbers | median }}
      #
      # --- NON-NUMBERS ARE DROPPED, NOT COUNTED AS ZERO ---
      #
      # Four of the five go through `Support.numbers`, which discards anything that is
      # not a number. That is a correctness decision and `Support` argues it where it is
      # implemented: an average over `[2.0, nil, 4.0]` is 3.0 if the nil is absent and
      # 2.0 if it counts as zero, and the second answer is a lie about a field nobody
      # filled in. Redmine's `estimated_hours` is nil far more often than it is zero.
      #
      # --- `sum` IS THE EXCEPTION, AND OQ-C IS WHY ---
      #
      # §3.6 says to subtract whatever Liquid 5's `StandardFilters` already provides.
      # Measured on 4.0.4 and 5.13.0: `where` and `sort_natural` are provided by BOTH and
      # already work on the drops, so they are inherited and are not here. `sum` is
      # provided by **5.x only** — so on Liquid 4 the same template would raise under
      # `strict_filters`, and a plugin that supports both majors cannot leave that
      # difference in place.
      #
      # So `sum` IS owned, and it deliberately reproduces LIQUID 5's semantics rather
      # than this module's: `Utils.to_number`-style coercion, zero for an empty input,
      # non-numbers as zero. An install that upgrades Liquid must see no change in a
      # number a report already printed, which matters more here than consistency with
      # its four neighbours — and the difference is written down rather than left to be
      # discovered.
      module Aggregates
        def avg(input, property = nil)
          numbers = Support.numbers(Support.values_of(input, property))
          return nil if numbers.empty?

          Support.tidy(numbers.sum.to_f / numbers.length)
        end

        # The middle value, or the mean of the two middle values. Not `avg` under another
        # name: a median is what a template wants for an age or a duration, where one
        # eight-year-old issue drags an average nobody recognises.
        def median(input, property = nil)
          numbers = Support.numbers(Support.values_of(input, property)).sort
          return nil if numbers.empty?

          middle = numbers.length / 2
          return Support.tidy(numbers[middle]) if numbers.length.odd?

          Support.tidy((numbers[middle - 1] + numbers[middle]).to_f / 2)
        end

        def min(input, property = nil)
          Support.tidy(Support.numbers(Support.values_of(input, property)).min)
        end

        def max(input, property = nil)
          Support.tidy(Support.numbers(Support.values_of(input, property)).max)
        end

        # LIQUID 5's SEMANTICS, on purpose. See the module comment.
        def sum(input, property = nil)
          values = Support.values_of(input, property)
          return 0 if values.empty?

          total = values.sum { |value| Support.number(value) || 0 }
          Support.tidy(total)
        end
      end
    end
  end
end
