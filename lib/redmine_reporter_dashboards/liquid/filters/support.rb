# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    module Filters
      # Helpers the registered filter modules share.
      #
      # NOT A FILTER MODULE, and the reason is mechanical rather than stylistic: Liquid
      # registers a module's PUBLIC INSTANCE methods as filters. A helper defined beside
      # `avg` would be `{{ x | numeric_values }}` — template surface nobody designed,
      # nobody documents and nobody can remove later without breaking a template. So the
      # helpers live here and are called explicitly.
      #
      # --- THE ONE RULE THAT IS A SECURITY RULE ---
      #
      # `read` below reaches a value through `[]` and through nothing else. Never
      # `send`, never `public_send`, never `respond_to?` followed by a call. §3.6 removes
      # the gem's `call_method(input, method_name)` because it invokes an arbitrary named
      # method on an arbitrary object from inside a template — "the sharpest single
      # instance of INV-9". A filter that resolved a property with `public_send` would
      # reintroduce exactly that, one property name at a time, and it would look
      # innocent: `{{ issues | avg: "estimated_hours" }}` and
      # `{{ issues | avg: "destroy" }}` are the same call.
      #
      # `Drop#[]` is `invoke_drop`, which consults the drop's DECLARED surface and
      # otherwise falls to `liquid_method_missing`. That is the boundary `Liquid::Drop`
      # exists to draw, and using it means these filters inherit it rather than needing
      # their own copy.
      module Support
        module_function

        # A property off a Liquid value. `nil` for anything that cannot answer, never an
        # exception: a template naming a property some rows do not have is ordinary
        # (an issue without an estimate), and `strict_variables` is the switch for how
        # loud that is — not this method.
        def read(value, property)
          return nil if value.nil? || property.nil?
          return value[property] if value.respond_to?(:[])

          nil
        end

        # The values a property takes across a collection. Used by every aggregate.
        def values_of(input, property)
          each(input).map { |item| property.nil? ? item : read(item, property) }
        end

        # Liquid hands a filter whatever the template had: an Array, a Drop that answers
        # `each`, a single value. All three have to iterate, and a bare `Array(drop)`
        # would call `to_a` on a collection drop and materialise it twice.
        def each(input)
          return [] if input.nil?
          return input.to_a if input.is_a?(::Array)
          return input.each_with_object([]) { |item, out| out << item } if input.respond_to?(:each)

          [input]
        end

        # Numbers only, non-numbers dropped rather than coerced to zero.
        #
        # THIS IS A CORRECTNESS DECISION, not a convenience. An average over
        # `[2.0, nil, 4.0]` is 3.0 if the nil is absent and 2.0 if it counts as zero, and
        # the second answer is a lie about a field somebody did not fill in. Redmine's
        # own `estimated_hours` is nil far more often than it is zero. `sum` is the one
        # exception and says so where it is defined — it matches Liquid 5's semantics
        # deliberately.
        def numbers(values)
          values.filter_map { |value| number(value) }
        end

        def number(value)
          case value
          when Numeric then value
          when String then numeric_string(value)
          # Deliberately NOT `value.to_f`. A Drop, a Date or an Array is not a number,
          # and coercing one produces 0.0 — a figure that looks measured and is not.
          end
        end

        # `'12'` and `'12.5'` are numbers; `'12 hours'` is not. `String#to_f` would make
        # it 12.0 and quietly invent a measurement — the same class of error as counting
        # a nil as zero.
        def numeric_string(value)
          text = value.strip
          return nil if text.empty?
          return Integer(text, 10) if text.match?(/\A[+-]?\d+\z/)
          return Float(text) if text.match?(/\A[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?\z/)

          nil
        end

        # The plugin's own RenderContext, or nil. Filters that need the actor — the
        # custom-field ones — go through here, so INV-1 holds in the filter layer too:
        # no filter reads `User.current`.
        def render_context(liquid_context)
          RenderContext.from(liquid_context)
        end

        # Integers stay integers. `2 + 3` should not print `5.0` because a filter
        # decided everything is a Float — a report full of `5.0` where the source data
        # is a count reads as a rounding bug.
        def tidy(number)
          return number unless number.is_a?(Float)
          return number unless number.finite?

          number == number.truncate ? number.truncate : number
        end
      end
    end
  end
end
