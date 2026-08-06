# frozen_string_literal: true

require 'json'

module RedmineReporterDashboards
  module Liquid
    module Filters
      # The escaping rules `| json` and `| js` are built from, in one place, with the
      # measurement behind them.
      #
      # NOT A FILTER MODULE. Nothing here is registered — Liquid turns a module's PUBLIC
      # instance methods into filters, so a helper that lived beside `json` would become
      # `{{ x | escape_script }}`, template surface nobody designed. This is called
      # explicitly by the module that is registered.
      #
      # --- WHAT WAS ACTUALLY WRONG, MEASURED RATHER THAN ASSUMED ---
      #
      # `reference/verification-liquid-js-escaping.md` ran the experiment the security
      # review asked for, and it corrected the review in both directions:
      #
      #   * The injection is REAL. Neither shipped idiom strips a backslash —
      #     `| escape` is `CGI.escapeHTML` and backslash is not in its character set,
      #     and the example template's `replace` chain removes quotes but not `\`. A
      #     value an ordinary project member controls (a version name, a custom field)
      #     changes the TOKEN STRUCTURE of the emitted JavaScript. Confirmed.
      #
      #   * The XSS is NOT. 0 of 2 940 crafted payloads executed. Breaking out of the
      #     string succeeds; RE-SYNCHRONISING the parse needs a quote, and both idioms
      #     make a quote impossible — so the array literal is left unterminated and the
      #     WHOLE `<script>` BLOCK DIES WITH A SyntaxError.
      #
      # So the impact is **denial of rendering**, and that is why the regression test
      # asserts the assembled block PARSES rather than asserting "nothing executed": a
      # test of the second kind passes the buggy code, because nothing executed there
      # either. That distinction is the single most important thing in this file.
      #
      # It also means the defence in the old idiom is ACCIDENTAL — quote-stripping
      # happens to remove the attacker's re-sync primitive. One payload shape away from
      # executable, per the verification's own warning. Nothing below relies on it.
      module Escaping
        # The five characters JSON permits raw but a `<script>` element does not treat
        # as data.
        #
        # `<` and `>` because `</script>` inside a JS string ends the ELEMENT — the HTML
        # tokenizer never looks inside the string, so no amount of JS-level correctness
        # helps. `&` because a document served as XHTML decodes entities inside script
        # content, where an HTML document does not, and a report that behaves differently
        # under two content types is a report with a bug in exactly one of them.
        #
        # U+2028 and U+2029 because they are valid JSON and, before ES2019, terminated a
        # JavaScript line — so a value containing one split a statement in half. Modern
        # V8 permits them in strings; wkhtmltopdf's 2011 JavaScriptCore does not, and
        # this plugin supports both engines.
        #
        # `\uXXXX` and not `\x3c`: the output has to stay valid JSON, because §6 puts
        # chart data in `<script type="application/json">` and `JSON.parse` rejects the
        # `\x` form. One escaping that is correct in both places beats two that each
        # work in one.
        SCRIPT_ESCAPES = {
          '<' => '\\u003c',
          '>' => '\\u003e',
          '&' => '\\u0026',
          "\u2028" => '\\u2028',
          "\u2029" => '\\u2029'
        }.freeze

        SCRIPT_PATTERN = Regexp.union(SCRIPT_ESCAPES.keys).freeze

        # `| js`'s set: everything that can end or re-open a JavaScript string literal,
        # plus the two line separators above.
        #
        # THE BACKSLASH IS FIRST BECAUSE IT IS THE FINDING. It has to be escaped before
        # anything else, or escaping a quote to `\'` would leave a backslash the next
        # rule doubles — and the measured defect is precisely a backslash reaching the
        # output intact.
        #
        # The BACKTICK is here although neither shipped idiom uses a template literal.
        # A template author who writes one is not doing anything unusual, and `${...}`
        # inside a backtick string is code position — a strictly worse hole than the one
        # that was measured. Cheap to close now, invisible to close later.
        JS_ESCAPES = {
          '\\' => '\\\\',
          "'" => "\\'",
          '"' => '\\"',
          '`' => '\\`',
          '$' => '\\$',
          "\r\n" => '\\n',
          "\n" => '\\n',
          "\r" => '\\n',
          "\u2028" => '\\u2028',
          "\u2029" => '\\u2029',
          "\0" => '\\0',
          '<' => '\\u003c',
          '>' => '\\u003e',
          '&' => '\\u0026'
        }.freeze

        # Longest-first so `\r\n` wins over `\r`. `Regexp.union` preserves the order it
        # is given, and Ruby's alternation is first-match — so the order of the hash
        # above is load-bearing and a sorted rewrite of it would be a defect.
        JS_PATTERN = Regexp.union(JS_ESCAPES.keys.sort_by { |key| -key.length }).freeze

        module_function

        # JSON, then the script-context escapes. In that order: escaping first would
        # have `JSON.generate` escape our backslashes again.
        def json(value)
          escape_script(JSON.generate(value))
        end

        def escape_script(text)
          text.to_s.gsub(SCRIPT_PATTERN, SCRIPT_ESCAPES)
        end

        # No surrounding quotes, because the author's template supplies them:
        # `var s = '{{ x | js }}'`. That is the idiom already in the wild, and the point
        # of this filter is to make it safe rather than to replace it — `| json` is the
        # replacement, and it emits its own quotes.
        def js(value)
          value.to_s.gsub(JS_PATTERN, JS_ESCAPES)
        end

        # A cycle, or merely very deep nesting, would otherwise recurse until the stack
        # goes. Depth rather than an identity set: these values come from a template's
        # own literals and from drops, so the realistic failure is depth, and a depth cap
        # needs no bookkeeping.
        MAX_DEPTH = 8

        # Liquid values are not JSON values, and this is where they become them.
        #
        # A Drop passed to `JSON.generate` serialises as its `inspect` string, which is
        # both useless and an internals leak. So the conversion is explicit and total:
        # anything this method does not recognise becomes its `to_s`, never its object
        # graph. That is the same closed-vocabulary decision `Drop` itself makes, for the
        # same reason (INV-9).
        #
        # A reference drop becomes its NAME rather than an object, because that is what
        # `{{ issue.status }}` has always printed and `{{ issue.status | json }}` should
        # not suddenly mean something else. A template wanting the id asks for
        # `issue.status.id | json`.
        def to_data(value, depth: 0)
          return '…' if depth > MAX_DEPTH

          case value
          when nil, true, false, Integer, Float, String then value
          when Symbol then value.to_s
          when Hash then value.each_with_object({}) { |(k, v), out| out[k.to_s] = to_data(v, depth: depth + 1) }
          when Array then value.map { |item| to_data(item, depth: depth + 1) }
          else scalar(value, depth)
          end
        end

        def scalar(value, depth)
          # Dates and times as ISO 8601, which is the one format every JS `Date` and
          # every chart library accepts, and the only one that sorts as a string.
          return value.iso8601 if value.respond_to?(:iso8601)
          # A collection drop, so `{{ issues | json }}` is the rows rather than a label.
          return to_data(value.to_a, depth: depth + 1) if value.is_a?(::Enumerable)

          value.to_s
        end
      end
    end
  end
end
