# frozen_string_literal: true

module RedmineReporterDashboards
  # Reads a stored template body and says two different things about it.
  #
  #   findings  what will BREAK when the render path changes — each with a line
  #             number, because FR-71 puts this same linter behind the editor's lint
  #             panel and a finding without a line number is not actionable there.
  #   usage     what the template DEPENDS ON — the counts that decide which of the
  #             vendor gem's accessors the owned drop layer has to reproduce. Not
  #             defects. `reference/redmineup-gem-drop-surface.md` ends with "[GAP]
  #             still open: what GEOxyz's production templates use — a SELECT content
  #             FROM report_templates grep settles it, and nothing in these
  #             repositories can." This is that grep, made repeatable.
  #
  # Keeping them apart is the whole design. A tool that reported "your template uses
  # issue.story_points" as a *finding* would be telling an operator to fix something
  # that is not broken, and the one thing a linter cannot survive is crying wolf.
  #
  # --- Where the rules come from ---
  #
  # Every rule cites the spec line or the verification document that established it.
  # The Chart.js list is the six migrations `technical-spec.md` §6 enumerated **from
  # the shipped examples**, not a general v2->v4 checklist: this list grows on
  # evidence, never on intuition, because one false positive costs more credibility
  # than one miss costs work.
  #
  # --- Two ways this stays honest ---
  #
  # SCOPE. Every rule declares where it may match. `legend:` in a stylesheet is not a
  # Chart.js option and `color:` in CSS is not `issue.color`, so the JS rules search
  # only inside `<script>` bodies and the usage markers search only inside Liquid
  # expressions. Scope removes whole classes of false positive that no amount of
  # regex cleverness would.
  #
  # AMBIGUITY IS DECLARED. Three Chart.js keys exist in BOTH versions and only moved
  # (`legend`, `tooltips`, `beginAtZero`). No pattern can tell `options.legend` from
  # `options.plugins.legend`. Those are :warning and their message says why. Flagging
  # them as errors would make the error count untrustworthy; dropping them would miss
  # the most common v2 idiom there is.
  module TemplateLinter
    # A single result. `excerpt` is bounded (EXCERPT_LIMIT) because a body is
    # operator-supplied and one minified line can be 40 KB.
    # `count` is how many times the rule matched on that line. One finding per
    # (rule, line) with a count, rather than one per match: a line is the unit an
    # author fixes, and `<footer>[page] / [topage]</footer>` printing the same message
    # and the same excerpt twice is noise that teaches the reader to skim.
    Finding = Struct.new(:rule, :severity, :line, :excerpt, :message, :count, keyword_init: true) do
      def error?
        severity == :error
      end

      def count
        self[:count] || 1
      end
    end

    # One `new Chart(` and the type it declares. Not a Finding: a chart is inventory,
    # not a defect, and the summary counts them separately.
    Chart = Struct.new(:line, :type, keyword_init: true)

    # `scope` is :body or :script — see the header.
    #
    # `suppressed_by` is how an ambiguous rule stops crying wolf. `legend:` means
    # Chart.js 2 only if the surrounding script has not been migrated at all; in a v3+
    # config it is `options.plugins.legend`, and no pattern can see the nesting. So the
    # rule asks a question about the REGION instead: if `plugins:` appears anywhere in
    # this script, this config has already been migrated and its `legend:` is nested.
    #
    # A region-wide test rather than a look-behind window on purpose. A window has to
    # pick a number, and both answers are wrong: too small misses
    # `plugins: {\n  title: …,\n  legend: …}`, too large suppresses a genuine v2
    # `legend:` that happens to sit below an unrelated `plugins:`. Nobody
    # half-migrates one chart's options, so "does this script know about plugins at
    # all" is the question that actually discriminates.
    Rule = Struct.new(:id, :severity, :pattern, :message, :scope, :suppressed_by,
                      keyword_init: true)

    SEVERITIES = %i[error warning].freeze
    SCOPES     = %i[body script].freeze

    # One line of context, at most this many characters. A finding is a pointer, not
    # a copy of the template.
    EXCERPT_LIMIT = 120

    # Bodies larger than this are linted up to the limit and the truncation is
    # REPORTED as a finding, never silently. Reporter's largest shipped template is
    # ~750 lines; 512 KiB is far past anything real, and the point of the bound is
    # that one pathological row cannot make the survey unbounded.
    MAX_BODY_BYTES = 512 * 1024

    # How far after `new Chart(` to look for the `type:` it declares. Bounded rather
    # than brace-parsed: a JS parser is not what this tool is, and a window that
    # misses an unusually-formatted config reports "(type not found)" — honest —
    # instead of guessing. On the MODULE, not inside `class << self`, where it would
    # land on the singleton class and `TemplateLinter::CHART_TYPE_WINDOW` would not
    # resolve (the same trap adapter_helper.rb records for CORPUS_TIME_ZONE).
    CHART_TYPE_WINDOW = 400

    # ------------------------------------------------------------------
    # Rules — what breaks
    # ------------------------------------------------------------------

    # `technical-spec.md` §6: "Chart.js 2->4 is a work package, not a free win.
    # Present in the shipped examples: scales.xAxes[]->scales.x;
    # options.legend->options.plugins.legend; type:'horizontalBar'->type:'bar' +
    # indexAxis:'y' (all three charts); getElementAtEvent->getElementsAtEventForMode
    # (the drill-through handler); ticks.fontSize->ticks.font.size; ticks.max /
    # beginAtZero -> the scale object."
    CHARTJS_RULES = [
      Rule.new(id: 'chartjs2.scales_axes', severity: :error, scope: :script,
               pattern: /\b[xy]Axes\b/,
               message: 'Chart.js 2 axis array. v3+ replaced scales.xAxes[]/yAxes[] with ' \
                        'scales.x/scales.y — the axis is silently ignored until it is moved'),
      Rule.new(id: 'chartjs2.horizontal_bar', severity: :error, scope: :script,
               pattern: /horizontalBar/,
               message: "Chart.js 2 chart type. v3+ removed type:'horizontalBar' — it is " \
                        "type:'bar' with indexAxis:'y'"),
      Rule.new(id: 'chartjs2.element_at_event', severity: :error, scope: :script,
               pattern: /getElementAtEvent\b/,
               message: 'Chart.js 2 hit-testing, renamed to getElementsAtEventForMode in v3+. ' \
                        'A drill-through handler using it stops responding to clicks'),
      Rule.new(id: 'chartjs2.font_size', severity: :error, scope: :script,
               pattern: /\bfontSize\s*:/,
               message: 'Chart.js 2 font option. v3+ nests it as font: { size: n }'),
      Rule.new(id: 'chartjs2.scale_label', severity: :error, scope: :script,
               pattern: /\bscaleLabel\b/,
               message: 'Chart.js 2 axis title. v3+ calls it title, on the scale object'),
      # `tooltips` PLURAL only ever existed in v2 — v3+ is `options.plugins.tooltip`,
      # singular — so unlike `legend` this one is unambiguous whatever the nesting.
      # It was drafted as a warning "for symmetry with legend" and the first run of
      # the spec showed the symmetry was imaginary.
      Rule.new(id: 'chartjs2.tooltips_plural', severity: :error, scope: :script,
               pattern: /\btooltips\s*:/,
               message: 'Chart.js 2 spelling. v3+ has options.plugins.tooltip, singular — ' \
                        'the plural key is ignored, so every tooltip option in it is lost'),
      # The two that MOVED rather than disappeared. See Rule#suppressed_by.
      Rule.new(id: 'chartjs2.legend_moved', severity: :warning, scope: :script,
               pattern: /\blegend\s*:/, suppressed_by: /\bplugins\s*:/,
               message: 'Chart.js moved legend under options.plugins in v3. Reported because ' \
                        'this script mentions no plugins: block at all, so the key is very ' \
                        'likely still at the v2 position'),
      Rule.new(id: 'chartjs2.begin_at_zero_moved', severity: :warning, scope: :script,
               pattern: /\bbeginAtZero\b/,
               message: 'beginAtZero still exists in v3+, but on the scale rather than under ' \
                        'ticks. Check which one this is — the nesting cannot be told apart ' \
                        'by pattern, so this may be a false positive')
    ].freeze

    # The readiness handshake `technical-spec.md` §6 deletes outright: nothing reads
    # window.status today (":703 — dead code"), and the replacement protocol belongs
    # to the engine, not to the template.
    HANDSHAKE_RULES = [
      Rule.new(id: 'handshake.window_status', severity: :error, scope: :script,
               pattern: /window\s*\.\s*status\s*=/,
               message: 'Hand-rolled readiness handshake. Nothing reads it today, and the ' \
                        'owned render path sets readiness itself — a template that assigns ' \
                        'window.status will fight the engine that replaces it'),
      Rule.new(id: 'handshake.geo_chart_counter', severity: :error, scope: :script,
               pattern: /geoChartBegin|geoChartEnd|__geoChartsPending/,
               message: "Hand-rolled pending-chart counter, replaced by the render path's " \
                        'own readiness protocol. Left in, it is a counter nothing decrements'),
      # :body rather than :script — it is typically read in a src attribute.
      Rule.new(id: 'handshake.chartjs_src_global', severity: :error, scope: :body,
               pattern: /GEO_CHARTJS_SRC/,
               message: 'Chart.js located through a global set outside the template. The ' \
                        'owned path vendors Chart.js with a recorded digest, so this global ' \
                        'will not exist')
    ].freeze

    ENGINE_RULES = [
      Rule.new(id: 'canvas.set_line_dash', severity: :error, scope: :script,
               pattern: /setLineDash\s*\(/,
               message: "Canvas2D setLineDash is absent from wkhtmltopdf's 2011 WebKit: the " \
                        'dashed line is drawn solid, with no error. Dashes belong to the ' \
                        'chart layer, which decides them per engine capability'),
      Rule.new(id: 'footer.engine_page_token', severity: :error, scope: :body,
               pattern: /\[(?:page|topage|frompage|section|subsection|webpage)\]/,
               message: 'wkhtmltopdf-native footer markup. It renders literally on every ' \
                        'other engine. Page furniture is supplied by the document request, ' \
                        'not written into the body'),
      Rule.new(id: 'assets.cdn_script', severity: :warning, scope: :body,
               pattern: %r{<script[^>]+src\s*=\s*["'][^"']*(?:cdnjs|jsdelivr|unpkg|googleapis)},
               message: 'Library loaded from a CDN, with no integrity attribute. Rendering ' \
                        'then depends on the Redmine host reaching the internet at PDF time; ' \
                        'the owned path vendors its libraries')
    ].freeze

    # FR-19 / INV-9, matched structurally rather than by pattern (see
    # #script_interpolation_findings).
    #
    # The severity is :error and the message deliberately does NOT say "XSS":
    # reference/verification-liquid-js-escaping.md measured 0 of 2 940 payloads
    # executing and reclassified this Medium — availability, not XSS. It fails closed
    # by accident (quote-stripping removes the attacker's re-sync primitive), which
    # is one payload shape away from executable. Overstating it here would be the
    # same kind of inaccuracy in the other direction.
    SCRIPT_INTERPOLATION_RULE =
      Rule.new(id: 'script.unfiltered_interpolation', severity: :error, scope: :script,
               pattern: nil,
               message: 'Liquid interpolation inside <script> that is not passed through ' \
                        '`json` or `js`. A value containing a quote or a backslash breaks the ' \
                        'surrounding JS token: the measured effect is a SyntaxError that kills ' \
                        'the whole block — the chart silently disappears and every later ' \
                        'statement in that block is lost').freeze

    PATTERN_RULES = (CHARTJS_RULES + HANDSHAKE_RULES + ENGINE_RULES).freeze
    RULES         = (PATTERN_RULES + [SCRIPT_INTERPOLATION_RULE]).freeze

    # The filters that make an interpolation safe inside <script>.
    # `jsonify` is the vendor gem's spelling. It escapes correctly, so it is not an
    # escaping finding — but it is gem-coupled, so it is counted under usage instead.
    SAFE_SCRIPT_FILTERS = %w[json js].freeze

    # ------------------------------------------------------------------
    # Usage markers — what the template depends on
    # ------------------------------------------------------------------
    #
    # Counted inside LIQUID EXPRESSIONS ONLY, which is what makes `issue.color`
    # countable at all: a stylesheet has dozens of `color:` declarations and none of
    # them is a drop accessor.
    #
    # Grouped by the question each group answers, because different people read them:
    # the first two decide what the owned drop layer must build (and what it may
    # drop), the third which vendor filters need replacements, the fourth is this
    # plugin's own surface and says what a re-seam may not break.
    USAGE_GROUPS = {
      'gem drop accessors — RedmineUP paid-plugin hooks, dead weight without those plugins' => {
        'tags' => /\.\s*tags\b/,
        'story_points' => /\.\s*story_points\b/,
        'color' => /\.\s*color\b/,
        'day_in_state' => /\.\s*day_in_state\b/,
        'checklists' => /\.\s*checklists\b/,
        'helpdesk_ticket' => /\.\s*helpdesk_ticket\b/
      },
      'gem drop accessors — core, so the owned layer has to reproduce them' => {
        'journals' => /\.\s*journals\b/,
        'relations_from' => /\.\s*relations_from\b/,
        'relations_to' => /\.\s*relations_to\b/,
        'subtasks' => /\.\s*subtasks\b/,
        'custom_field_values' => /\.\s*custom_field_values\b/,
        'issues.all — one object materialised per row' => /\bissues\s*\.\s*all\b/
      },
      'gem filters' => {
        'call_method' => /\|\s*call_method\b/,
        'regex_replace' => /\|\s*regex_replace(?:_once)?\b/,
        'jsonify' => /\|\s*jsonify\b/,
        'textile / textilize' => /\|\s*textiliz?e\b/,
        'where_exp' => /\|\s*where_exp\b/,
        'md5' => /\|\s*md5\b/,
        'group_by_custom_field' => /\|\s*group_by_custom_field\b/,
        'where_custom_field' => /\|\s*where_custom_field\b/
      },
      "this plugin's own surface" => {
        '{% sql_aggregate %}' => /\bsql_aggregate\b/,
        '{% geo_aggregate %} — legacy alias' => /\bgeo_aggregate\b/,
        '{% version_rollup %}' => /\bversion_rollup\b/,
        '{% geo_version_map %}' => /\bgeo_version_map\b/,
        'issue.target_version' => /\.\s*target_version\b/,
        'issue.custom_field_value[…]' => /\.\s*custom_field_value\b/,
        '| json — already safe' => /\|\s*json\b/
      }
    }.freeze

    # ------------------------------------------------------------------
    # Analysis
    # ------------------------------------------------------------------

    Analysis = Struct.new(:findings, :usage, :charts, :lines, :truncated, keyword_init: true) do
      def errors
        findings.select(&:error?)
      end

      def warnings
        findings.reject(&:error?)
      end

      # "Which templates need rework" (T-02's Accept list) is exactly this.
      def rework?
        errors.any?
      end

      def chart_types
        charts.map { |chart| chart.type || '(type not found)' }
      end
    end

    class << self
      def analyse(body)
        text, truncated = bound(body.to_s)

        Analysis.new(
          findings: findings_for(text, truncated),
          usage: usage_for(text),
          charts: charts_for(text),
          lines: text.count("\n") + 1,
          truncated: truncated
        )
      end

      # FR-71's editor panel wants findings alone.
      def lint(body)
        analyse(body).findings
      end

      def rules
        RULES
      end

      # ----------------------------------------------------------------
      # Bounding
      # ----------------------------------------------------------------

      def bound(text)
        return [text, false] if text.bytesize <= MAX_BODY_BYTES

        # byteslice can cut a multi-byte character in half; scrub rather than raise,
        # and report the truncation so no reader mistakes a short finding list for a
        # clean template.
        [text.byteslice(0, MAX_BODY_BYTES).to_s.scrub(''), true]
      end

      # ----------------------------------------------------------------
      # Findings
      # ----------------------------------------------------------------

      def findings_for(text, truncated)
        scripts = script_regions(text)

        found = PATTERN_RULES.flat_map { |rule| pattern_findings(text, scripts, rule) }
        found += script_interpolation_findings(text, scripts)
        found << truncation_finding(text) if truncated
        collapse(found).sort_by { |finding| [finding.line, finding.rule] }
      end

      # One finding per (rule, line), carrying how many times it matched there.
      def collapse(findings)
        findings.group_by { |finding| [finding.rule, finding.line] }.map do |_key, group|
          group.first.dup.tap { |finding| finding.count = group.length }
        end
      end

      def pattern_findings(text, scripts, rule)
        regions = rule.scope == :script ? scripts : [[0, text]]

        regions.flat_map do |region_offset, region|
          next [] if rule.suppressed_by && rule.suppressed_by.match?(region)

          match_offsets(region, rule.pattern).map do |offset|
            finding(rule.id, rule.severity, text, region_offset + offset, rule.message)
          end
        end
      end

      # Every `{{ … }}` inside a <script> body whose filter chain does not end in a
      # safe filter. Only OUTPUT is checked: `{% if %}` inside a script is control
      # flow and emits nothing into the JS.
      def script_interpolation_findings(text, scripts)
        rule = SCRIPT_INTERPOLATION_RULE

        scripts.flat_map do |region_offset, region|
          each_match(region, /\{\{(.*?)\}\}/m).reject { |match| safe_interpolation?(match[1]) }
                                              .map do |match|
            finding(rule.id, rule.severity, text, region_offset + match.begin(0), rule.message)
          end
        end
      end

      # The LAST filter in the chain decides. `{{ x | json | upcase }}` is NOT safe —
      # upcase runs after json and can reintroduce a quote — so this deliberately does
      # not just ask whether `json` appears somewhere in the expression.
      def safe_interpolation?(expression)
        segments = expression.to_s.split('|').map(&:strip)
        return false if segments.length < 2

        SAFE_SCRIPT_FILTERS.include?(segments.last.to_s[/\A[a-z_]+/])
      end

      def truncation_finding(text)
        Finding.new(rule: 'body.truncated', severity: :warning, line: text.count("\n") + 1,
                    excerpt: '',
                    message: "body is larger than #{MAX_BODY_BYTES} bytes and was linted up to " \
                             'that point only — findings past it are not reported')
      end

      def finding(id, severity, text, offset, message)
        Finding.new(rule: id, severity: severity, line: line_at(text, offset),
                    excerpt: excerpt_at(text, offset), message: message)
      end

      # ----------------------------------------------------------------
      # Usage
      # ----------------------------------------------------------------

      def usage_for(text)
        liquid = liquid_regions(text)

        USAGE_GROUPS.each_with_object({}) do |(group, markers), out|
          counts = markers.each_with_object({}) do |(label, pattern), inner|
            hits = liquid.sum { |region| region.scan(pattern).length }
            inner[label] = hits if hits.positive?
          end
          out[group] = counts unless counts.empty?
        end
      end

      # The inside of every `{{ … }}` and `{% … %}`.
      def liquid_regions(text)
        text.scan(/\{\{(.*?)\}\}|\{%(.*?)%\}/m).map { |output, tag| output || tag }
      end

      # ----------------------------------------------------------------
      # Charts
      # ----------------------------------------------------------------

      def charts_for(text)
        each_match(text, /new\s+Chart\s*\(/).map do |match|
          offset = match.begin(0)
          Chart.new(line: line_at(text, offset), type: chart_type_at(text, offset))
        end
      end

      def chart_type_at(text, offset)
        text[offset, CHART_TYPE_WINDOW].to_s[/\btype\s*:\s*["']([a-zA-Z]+)["']/, 1]
      end

      # ----------------------------------------------------------------
      # Scanning
      # ----------------------------------------------------------------

      # [offset, body] per <script> element. Deliberately NOT Regexp.last_match after
      # `to_enum(:scan, …)`: `$~` is frame-local, so reading it from inside an
      # enumerator block is an idiom that works by accident. `Regexp#match(str, pos)`
      # returns the MatchData directly and cannot be confused by a nested scan.
      def script_regions(text)
        each_match(text, %r{<script\b[^>]*>(.*?)</script\s*>}mi).map do |match|
          [match.begin(1), match[1]]
        end
      end

      def each_match(text, pattern)
        return [] if pattern.nil?

        found = []
        position = 0
        while (match = pattern.match(text, position))
          found << match
          # A zero-width match would otherwise loop for ever. None of the patterns
          # here can match empty, but the guard costs one comparison and the failure
          # it prevents is a hang rather than a wrong answer.
          position = match.end(0) > match.begin(0) ? match.end(0) : match.begin(0) + 1
        end
        found
      end

      def match_offsets(text, pattern)
        each_match(text, pattern).map { |match| match.begin(0) }
      end

      def line_at(text, offset)
        text[0, offset].to_s.count("\n") + 1
      end

      def excerpt_at(text, offset)
        start = text.rindex("\n", offset)
        start = start.nil? ? 0 : start + 1
        line = text[start..].to_s[/[^\n]*/].to_s.strip
        line.length > EXCERPT_LIMIT ? "#{line[0, EXCERPT_LIMIT]}…" : line
      end
    end
  end
end
