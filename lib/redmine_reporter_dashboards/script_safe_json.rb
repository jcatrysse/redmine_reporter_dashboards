# frozen_string_literal: true

require 'json'

module RedmineReporterDashboards
  # JSON that is safe to put inside a `<script>` element — the primitive, with no layer
  # attached to it.
  #
  # --- WHY IT MOVED HERE ---
  #
  # T-19 put this in `Liquid::Filters::Escaping`, which was right while `| json` was its
  # only caller. T-16 added a second one: `Charts::ChartjsEmitter` writes the chart data
  # into `<script type="application/json">`, and it is on the path a PDF engine takes.
  # `script/gates/layer_purity.sh` forbids the render path from naming the Liquid layer,
  # and the reason behind the gate applies whether or not the grep would fire — a
  # renderer that loads the template engine to escape a string has the dependency
  # backwards.
  #
  # The alternative was a second copy of the five substitutions. That is the worst
  # available option for a security-bearing escaper: two definitions drift, and the one
  # that drifts is the one nobody has a test for. So there is one definition, here,
  # named after what it does and belonging to no layer. `Escaping` keeps its constants
  # as aliases so nothing that referenced them had to move.
  module ScriptSafeJson
    module_function

    # The five characters JSON permits raw but a `<script>` element does not treat as
    # data. The reasoning is T-19's and is worth keeping next to the table:
    #
    # `<` and `>` because `</script>` inside a JS string ends the ELEMENT — the HTML
    # tokenizer never looks inside the string, so no amount of JS-level correctness
    # helps. `&` because a document served as XHTML decodes entities inside script
    # content where an HTML document does not, and a report that behaves differently
    # under two content types has a bug in exactly one of them. U+2028/U+2029 because
    # they are valid JSON and, before ES2019, terminated a JavaScript line — modern V8
    # permits them in strings, wkhtmltopdf's 2011 JavaScriptCore does not, and this
    # plugin supports both.
    #
    # `\uXXXX` and not `\x3c`: the output has to stay valid JSON, because
    # `JSON.parse` rejects the `\x` form and §6 puts chart data through it.
    SCRIPT_ESCAPES = {
      '<' => '\\u003c',
      '>' => '\\u003e',
      '&' => '\\u0026',
      "\u2028" => '\\u2028',
      "\u2029" => '\\u2029'
    }.freeze

    SCRIPT_PATTERN = Regexp.union(SCRIPT_ESCAPES.keys).freeze

    # JSON first, then the script-context escapes. In that order: escaping first would
    # have `JSON.generate` escape our backslashes again.
    def generate(value)
      escape(JSON.generate(value))
    end

    def escape(text)
      text.to_s.gsub(SCRIPT_PATTERN, SCRIPT_ESCAPES)
    end
  end
end
