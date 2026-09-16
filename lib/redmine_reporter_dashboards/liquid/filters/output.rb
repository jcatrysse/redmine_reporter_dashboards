# frozen_string_literal: true

require_relative 'escaping'

module RedmineReporterDashboards
  module Liquid
    module Filters
      # `| json` and `| js` — the two filters FR-19 makes mandatory, and the only two in
      # this layer whose absence is a security finding rather than a missing convenience.
      #
      # The escaping rules and the measurement behind them are in `Escaping`; this module
      # is the registered surface, deliberately two methods wide so that everything
      # reachable from a template here is something FR-19 named.
      #
      # --- WHICH ONE TO USE, AND WHY `json` IS THE ANSWER ---
      #
      #   GOOD   var labels = {{ rows | map: "label" | json }};
      #   OK     var label  = '{{ row.label | js }}';
      #   BAD    var label  = '{{ row.label | escape }}';
      #
      # `| json` emits its own quotes, so an author cannot forget them, and it emits the
      # whole structure in one go — which removes the entire class of defect rather than
      # one instance of it. `| js` exists because `'{{ x | ... }}'` is the shape already
      # in every template in the wild, and making that shape safe is worth more than
      # insisting nobody uses it. `| escape` is what was there before: HTML escaping,
      # applied to JavaScript, which does not escape a backslash.
      #
      # §6 puts chart data in `<script type="application/json">`. `| json` is correct
      # there too — its escapes are `\uXXXX`, which `JSON.parse` accepts.
      module Output
        # A whole value as a JSON literal: quoted if it is a string, bracketed if it is
        # an array, and safe inside a `<script>` either way.
        def json(input)
          Escaping.json(Escaping.to_data(input))
        end

        # A scalar as the CONTENTS of a JavaScript string literal — no quotes, because
        # the template's own quotes surround it.
        def js(input)
          Escaping.js(input)
        end
      end
    end
  end
end
