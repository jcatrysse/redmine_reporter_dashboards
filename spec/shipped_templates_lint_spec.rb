# frozen_string_literal: true

# T-19's acceptance list: the FR-19 lint *"runs over the shipped examples AND the README's
# own snippets — the examples are the spec, and today the copy-paste surface carries the
# defective idiom."*
#
# It did. `examples/version_status_dashboard.liquid` carried ten unescaped interpolations
# inside `<script>`, `examples/sample_report_template.liquid` two, and the README's
# snippets three — every one of them a `{{ … }}` in a hand-built JavaScript array literal
# with quotes stripped from the value. `reference/verification-liquid-js-escaping.md`
# measured what that costs: a value ending in a BACKSLASH breaks the token, the whole
# `<script>` block dies with a SyntaxError, and the chart, the drill-through URLs and the
# readiness handshake go with it.
#
# --- WHY A SPEC AND NOT JUST A FIX ---
#
# Because the examples are the surface an author copies. Fixing them once leaves nothing
# stopping the next edit from reintroducing the idiom, and the idiom is the one the README
# used to TEACH. This file is what makes the fix permanent: an example that regains an
# unescaped interpolation fails the build.
#
# --- WHY ONLY THE FR-19 RULE, AND NOT EVERY RULE ---
#
# Both examples still carry Chart.js 2 idioms and the old `window.status` handshake, and
# those are deliberately NOT fixed here. They belong to T-16 (the chart layer) and T-11
# (readiness), which rewrite that code rather than patching it — fixing it now would be
# work thrown away, and worse, it would be a chart rewrite hidden inside a filter task
# (CLAUDE.md §11.5). So this file pins the escaping rule to ZERO and pins the others to a
# RATCHET, which is the honest way to hold a debt: it cannot grow, it is visible, and the
# number goes down when its owner arrives.

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/template_linter'

RSpec.describe 'the shipped templates and the README (FR-19)' do
  ROOT = File.expand_path('..', __dir__)

  # The templates an install actually gets.
  EXAMPLES = %w[
    examples/sample_report_template.liquid
    examples/version_status_dashboard.liquid
    examples/chart_tag_showcase.liquid
  ].freeze

  # The `{% chart %}` example is held at ZERO, not at a ratchet, and it is the only one
  # that can be. The other two draw their charts by hand — a `<canvas>`, a Chart.js 2
  # config and a `window.status` handshake — and every finding they carry is owned by a
  # task that rewrites that code. This one writes no markup at all, so there is nothing
  # for a rule to find, and that is the point of it rather than a happy accident.
  CHART_TAG_EXAMPLE = 'examples/chart_tag_showcase.liquid'

  # NOT LINTED, DELIBERATELY. `docs/plan/reference/example-template-*.liquid` are frozen
  # EVIDENCE: they are the templates as they were when the escaping experiment was run,
  # and `verification-liquid-js-escaping.md` cites line numbers into them. Fixing them
  # would destroy the record the finding rests on. If they ever appear in EXAMPLES,
  # somebody has confused an artefact with a deliverable.
  FROZEN_EVIDENCE = %w[
    docs/plan/reference/example-template-sample-report.liquid
    docs/plan/reference/example-template-version-status.liquid
  ].freeze

  FR19 = 'script.unfiltered_interpolation'

  # The ratchet, per file, for the rules whose owner is another task. Down is fine, up is
  # a failure. Reduce these numbers as T-16 and T-11 land; never raise one.
  OTHER_RULES_RATCHET = {
    'examples/sample_report_template.liquid' => 12,
    'examples/version_status_dashboard.liquid' => 44,
    CHART_TAG_EXAMPLE => 0
  }.freeze

  def read(path)
    File.read(File.join(ROOT, path), encoding: 'UTF-8')
  end

  def findings(body)
    RedmineReporterDashboards::TemplateLinter.lint(body)
  end

  def fr19_count(body)
    findings(body).select { |f| f.rule == FR19 }.sum(&:count)
  end

  describe 'the shipped examples' do
    EXAMPLES.each do |path|
      it "#{path} has no unescaped interpolation inside <script>" do
        body = read(path)
        offenders = findings(body).select { |f| f.rule == FR19 }

        expect(offenders).to be_empty,
                             lambda {
                               lines = body.lines
                               offenders.map { |f| "  line #{f.line}: #{lines[f.line - 1].to_s.strip}" }
                                        .unshift("#{path} carries the defective idiom again:").join("\n")
                             }
      end

      it "#{path} does not regain a finding owned by another task" do
        total = findings(read(path)).sum(&:count)
        allowed = OTHER_RULES_RATCHET.fetch(path)

        expect(total).to be <= allowed,
                         "#{path} now has #{total} findings, up from #{allowed}. The Chart.js and " \
                         'readiness findings belong to T-16 and T-11; this number may go DOWN when ' \
                         'they land, never up.'
      end

      # `| json` is not merely present — it is what the chart data goes through. Asserted
      # positively as well as negatively, because "no findings" is also true of a template
      # that no longer draws a chart at all.
      #
      # THE `{% chart %}` EXAMPLE IS EXEMPT, and the exemption is the whole finding: it
      # has no `| json` and no `new Chart` because it has no JavaScript. The data block
      # and the escaping still happen — in `ChartjsEmitter`, where no author can get them
      # wrong. Asserting the opposite property for that file keeps this from reading as a
      # gap.
      it "#{path} still emits chart data, and does it through `| json`" do
        body = read(path)

        if path == CHART_TAG_EXAMPLE
          # COMMENTS STRIPPED FIRST. This file's header EXPLAINS what the tag emits, so
          # it names `<canvas>` and `<script type="application/json">` in prose — and an
          # assertion that punished it would teach the next author to delete the
          # explanation. Same lesson `layer_purity.sh` records about its own first run,
          # and the same treatment the quote-appending assertion below already gives.
          code = body.gsub(/\{%-?\s*comment\s*-?%\}.*?\{%-?\s*endcomment\s*-?%\}/m, '')

          expect(code).to include('{% chart ')
          expect(code).not_to include('<script')
          expect(code).not_to include('<canvas')
          next
        end

        expect(body).to include('| json }}')
        expect(body).to include('new Chart')
      end

      # The construct CLAUDE.md §5 names: "a JS array literal built by string
      # concatenation". The old idiom's signature is appending a quote character, which is
      # what a value then breaks out of.
      #
      # COMMENTS ARE STRIPPED FIRST, and that is not a loophole — it is the same lesson
      # `script/gates/layer_purity.sh` records about itself: its first run failed on the
      # two comments EXPLAINING why the boundary exists, and "a gate that punishes writing
      # down its own rationale teaches people to delete the rationale". This assertion hit
      # exactly that, on the `{% comment %}` in each example that quotes the old idiom so
      # the next author understands what changed. The check is about code; the comment is
      # the documentation the check exists to protect.
      it "#{path} builds no JS string literal by appending a quote" do
        code = read(path).gsub(/\{%-?\s*comment\s*-?%\}.*?\{%-?\s*endcomment\s*-?%\}/m, '')

        expect(code).not_to match(/append:\s*(["'])'\1/)
      end
    end
  end

  describe "the README's own snippets" do
    # PER FENCED BLOCK, not over the whole file. A README is prose, and its prose talks
    # ABOUT tags: the sentence describing this very rule contains a backticked
    # `<script>`, which the HTML scanner correctly reads as an element — opening a region
    # that swallowed 350 lines of Markdown and produced 23 findings in text that is not a
    # template. The unit T-19 means by "the README's own snippets" is the snippet.
    let(:snippets) { read('README.md').scan(/^```liquid\n(.*?)^```/m).flatten }

    it 'has snippets to check, so this file cannot pass by finding nothing' do
      expect(snippets.length).to be >= 20
    end

    it 'has none with an unescaped interpolation inside <script>' do
      offenders = snippets.each_with_index.filter_map do |snippet, index|
        found = findings(snippet).select { |f| f.rule == FR19 }
        next if found.empty?

        lines = snippet.lines
        "  snippet #{index + 1}, line #{found.first.line}: #{lines[found.first.line - 1].to_s.strip}"
      end

      expect(offenders).to be_empty,
                           (['the README teaches the defective idiom again:'] + offenders).join("\n")
    end

    # The idiom the README used to document, asserted GONE by name. A README that stopped
    # showing charts would also have no findings.
    it 'no longer documents `| escape` as the way into a JS string' do
      expect(read('README.md')).not_to match(/"\{\{[^}]*\|\s*escape\s*\}\}"/)
    end

    it 'documents `| json` instead' do
      expect(read('README.md')).to include('| json }}')
    end
  end

  describe 'the frozen evidence' do
    # These are the artefacts the finding is written against. Asserted STILL DEFECTIVE, so
    # that a well-meaning sweep of "the last unescaped interpolations" cannot quietly
    # delete the evidence and leave the verification document citing lines that no longer
    # say what it claims.
    FROZEN_EVIDENCE.each do |path|
      it "#{path} still carries the idiom, because it is evidence rather than a deliverable" do
        expect(fr19_count(read(path))).to be > 0,
                                          "#{path} has been 'fixed'. It is the frozen record " \
                                          'verification-liquid-js-escaping.md cites; restore it from ' \
                                          'git and fix the shipped copy in examples/ instead.'
      end
    end

    it 'is not confused with the shipped examples' do
      expect(EXAMPLES & FROZEN_EVIDENCE).to be_empty
    end
  end
end
