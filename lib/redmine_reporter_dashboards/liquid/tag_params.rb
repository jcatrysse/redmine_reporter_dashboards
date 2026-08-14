# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # TAG MARKUP, PARSED ONCE — and the one place that decides what a QUOTE means.
    #
    # --- The defect this module exists to close (curator decision #3, 2026-08-13) ---
    #
    # Every tag in this plugin parsed its own markup with its own copy of `PARAM_RE`,
    # its own `parse_markup` and its own `str_param`. All four copies did the same
    # thing, and the same wrong thing: `PARAM_RE` captures a double-quoted, a
    # single-quoted and a bare value into three separate groups, and `parse_markup`
    # collapsed them into one String — so by the time `str_param` ran, **the quoting
    # was gone**. It then looked every value up in the Liquid context.
    #
    # The consequence, found by T-37's own gallery harness: `group_by: "user"` does not
    # mean the word *user*. `user` and `project` are assigned in every report this
    # plugin renders, so the lookup succeeds and the tag is asked for
    # `group_by: "Redmine Admin"`. Two of the spent-time source's four dimensions —
    # `user` and `project` — could not be written at all, in any spelling.
    #
    # --- The rule, said once ---
    #
    #   quoted  ->  LITERAL TEXT. Never looked up.
    #   bare    ->  a Liquid variable, falling back to the literal when it resolves
    #               to nothing (unchanged: that fallback is what makes
    #               `group_by: status` mean the *field* rather than an empty string).
    #
    # This is a BREAKING CHANGE and it is deliberate; CHANGELOG.md carries the upgrade
    # note. A template that wrote `group_by: "some_variable"` to get a dimension name
    # out of a variable now gets the literal `some_variable`, which is not a dimension,
    # which degrades VISIBLY (`aggregation_dimension_unknown` on the page and in the
    # diagnostics) rather than quietly reporting a different number. That failure mode
    # is why the curator took the fix in 1.0 rather than deferring it: the alternative
    # spelling — drop the quotes — is one keystroke and is what the README always used.
    #
    # --- Why the quoting travels ON the value ---
    #
    # `Value` is a String subclass carrying one extra bit. The alternative was to key
    # every helper by parameter NAME instead of by value, and that breaks on the one
    # place a tag computes which parameter it is reading:
    #
    #     raw_periods = @raw_params['periods'] || (@raw_params['months'] if period == 'month')
    #
    # There is no single key there, and a helper that took one would have had to guess.
    # Carrying the bit on the value means every existing call site keeps working and
    # keeps its quoting — including that one.
    #
    # --- Keeping `Value` out of the data, and the RETRACTED reason for it ------------
    #
    # This paragraph used to say: "`Value` never leaves this layer: `resolve` returns a
    # plain String, so nothing downstream can ever hold one." The first half is true and
    # the *therefore* is not — `resolve` is not the only exit. `{% chart %}` reads `type:`,
    # `orientation:`, `id:`, `x:`, `y:` and `series_label:` straight off `@raw_params`, and
    # `{% geo_version_map %}` reads `project:`. An independent review pointed at the gap.
    #
    # What actually holds it, in two parts. `resolve` returns a plain String
    # (`String#to_s` converts a subclass) for everything that goes through it; and every
    # direct reader normalises on its own way in — `Series#initialize` does `label.to_s`,
    # `chart_id` does `.to_s`. That second half is a property of five call sites rather
    # than of this module, so it is asserted MECHANICALLY rather than argued: a chart drawn
    # from all-quoted markup is walked in `spec/liquid/chart_tag_spec.rb` and nothing
    # anywhere in `ChartSpec#to_h` may be a `Value`. Negative-tested with two plants.
    module TagParams
      # Matches: key: "quoted" | key: 'quoted' | key: bare_value
      #
      # ONE copy. It used to be four, character-identical, in four files — which is
      # exactly the shape CLAUDE.md §5 names ("when you find the same three-character
      # regexp in three files, the fourth copy is the bug"), and it was: the four
      # `str_param`s had drifted into two different signatures.
      PARAM_RE = /(\w+)\s*:\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))/.freeze

      # A parameter's text plus whether the author wrote it in quotes.
      #
      # A String subclass rather than a Struct so that every existing reader keeps
      # working untouched — `@raw_params.fetch('type', 'bar')`, `Integer(raw)`,
      # `bucket[value_key]` (Hash lookup is content-based and accepts a subclass),
      # `"#{value}"` — and only the two helpers that care ask the extra question.
      class Value < String
        def initialize(text, quoted:)
          super(text)
          @quoted = quoted
        end

        # Deliberately not `def quoted? = @quoted`: the declared Ruby floor is 2.7
        # (Redmine 5.1's Gemfile says `ruby '>= 2.7.0'`) and an endless method is 3.0
        # syntax, so this file would not PARSE there. The reason is the floor itself, not
        # the gate that currently checks it — `.codex/check_ruby_floor.sh` is deleted by
        # the floor decision (CLAUDE.md §8), and this comment must outlive it.
        def quoted?
          @quoted
        end
      end

      class << self
        # markup -> { 'key' => Value }. Unknown keys are the caller's business; this
        # only reads what the author wrote.
        def parse(markup)
          params = {}
          markup.to_s.scan(PARAM_RE) do |key, dq, sq, bare|
            quoted = !(dq || sq).nil?
            params[key.strip] = Value.new(dq || sq || bare || '', quoted: quoted)
          end
          params
        end

        # The one rule, applied. `default` is returned for an absent or empty
        # parameter — including `x: ""`, which has always meant "not given" here and
        # still does.
        #
        # Returns a plain String (or `default`, which a caller may declare as nil).
        # `to_s.empty?` AND NOT `empty?`: `ScopeBinding.bind` is a public module method
        # taking a raw-params Hash, so a caller — an importer, a spec — can hand it an
        # Integer, and the four `str_param`s this replaced tolerated one
        # (`(resolved || param).to_i`). Raising `NoMethodError` on a non-String would be a
        # narrowing nobody asked for.
        def resolve(value, context, default: '')
          return default if value.nil? || value.to_s.empty?
          # A context that cannot be indexed is treated as no context — the literal.
          # `ScopeBinding#query_id_of` has always guarded this and its callers include
          # tests that pass nil.
          return value.to_s if quoted?(value) || !context.respond_to?(:[])

          resolved = context[value.to_s]
          resolved.nil? ? value.to_s : resolved.to_s
        end

        # A value that did not come from `parse` — a String built by a caller or a
        # test — is treated as BARE, which is the pre-decision behaviour. That keeps
        # the change to what the author actually typed.
        def quoted?(value)
          value.is_a?(Value) && value.quoted?
        end
      end
    end
  end
end
