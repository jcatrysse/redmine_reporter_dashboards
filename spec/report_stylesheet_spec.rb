# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/report_stylesheet'

# T-38 — "one print-first stylesheet and one type scale used by the HTML view and the PDF
# body; the palette is READ from the chart layer, not duplicated in CSS — a test asserts a
# single source".
#
# --- THE SINGLE-SOURCE CLAUSE IS ASSERTED TWICE, AND IT HAS TO BE ---
#
# Two different questions, and only one of them can be answered by looking at the output:
#
#   does the CSS use only the chart layer's colours?   -> read the CSS, compare the sets.
#   are those colours READ or COPIED?                  -> read the SOURCE. A file that
#                                                         restated `#333333` would satisfy
#                                                         the first check perfectly.
#
# The second is a grep over `report_stylesheet.rb` for a colour literal, and it is the one
# that actually holds the clause: "not duplicated in CSS" is a statement about where the
# value LIVES, which no amount of inspecting the generated text can see.

# HOISTED AND NAMESPACED, because a constant assigned inside `RSpec.describe` is assigned
# at the FILE's top level — the block is a closure whose lexical scope is the file. A bare
# `SOURCE_PATH` here would be `Object::SOURCE_PATH` for the whole process, which passes in
# isolation and fails only in the randomised full run. `spec/reporting/report_run_spec.rb`
# records that costing this project two examples already.
module ReportStylesheetSpecSupport
  Pal = RedmineReporterDashboards::Charts::Palette
  CL = RedmineReporterDashboards::Charts::ChartLayout
  SVG = RedmineReporterDashboards::Charts::SvgRenderer

  SOURCE_PATH = File.expand_path(
    '../lib/redmine_reporter_dashboards/report_stylesheet.rb', __dir__
  )
end

RSpec.describe RedmineReporterDashboards::ReportStylesheet do
  # METHODS AND NOT LOCAL CONSTANTS, for the reason the module above exists: `Pal = …`
  # inside this block would still be `Object::Pal`. A method is scoped to the example
  # group and leaks nothing.
  #
  # NOT `def pal = …`: an endless method is a syntax error on Ruby 2.7, which Redmine 5.1
  # still runs, and `.codex/check_ruby_floor.sh` is the gate that says so.
  def pal
    ReportStylesheetSpecSupport::Pal
  end

  def chart_layout
    ReportStylesheetSpecSupport::CL
  end

  def svg_renderer
    ReportStylesheetSpecSupport::SVG
  end

  # UTF-8 NAMED. HANDOVER §3: a bare container has no `LANG`, so
  # `Encoding.default_external` is US-ASCII and reading this file's own em dashes raises
  # `invalid byte sequence` — which reads as a defect in the subject and is the container.
  def source
    @source ||= File.read(ReportStylesheetSpecSupport::SOURCE_PATH, encoding: 'UTF-8')
  end

  # The comments in this file name the constructs it forbids — `#333333` appears in the
  # sentence explaining why it must not appear. Same lesson `layer_purity.sh` records
  # about its own first run: a check that punishes writing down its rationale teaches
  # people to delete the rationale.
  def source_code_only
    source.gsub(/^\s*#.*$/, '')
  end

  # COMMENTS STRIPPED. Every content assertion below runs over the RULES, because this
  # stylesheet's own comments name the constructs it deliberately does not contain — "@page
  # geometry is NOT set here" is the sentence that explains the rule, and an assertion that
  # failed on it would teach the next author to delete the explanation. Same strip, same
  # reason, as `script/gates/chrome_no_design_tokens.sh`. The two examples that are about
  # the artefact rather than the rules use `described_class.css` directly.
  let(:css) { described_class.css.gsub(%r{/\*.*?\*/}m, '') }

  describe 'the palette, read rather than duplicated (the single-source clause)' do
    # Every colour the chart layer owns. `PROGRESS_TRACK` and the series ramps are in the
    # set even though the body chrome does not use them: the assertion is "the CSS may use
    # nothing this module did not read from Palette", not "the CSS uses all of them".
    def palette_colours
      ([pal::AXIS, pal::GRID, pal::TEXT, pal::MUTED_TEXT, pal::BACKGROUND, pal::LINK,
        pal::PROGRESS_FILL, pal::PROGRESS_TRACK] + pal::SERIES + pal::DIVERGING)
        .map(&:downcase).uniq
    end

    it 'declares no colour literal of its own, anywhere in its code' do
      offenders = source_code_only.scan(/#\h{3,8}\b/)

      expect(offenders).to be_empty,
                           "report_stylesheet.rb contains the colour literal(s) " \
                           "#{offenders.uniq.join(', ')}. Every colour in the report body " \
                           'must be READ from Charts::Palette — a copy here is the second ' \
                           "source T-38's acceptance list forbids, and \"the axis is a " \
                           'slightly different grey in the PDF" is the difference nobody ' \
                           'finds later.'
    end

    it 'emits only colours the chart layer owns' do
      used = css.scan(/#\h{3,8}\b/).map(&:downcase).uniq
      stray = used - palette_colours

      expect(stray).to be_empty,
                       "the stylesheet emits #{stray.join(', ')}, which Charts::Palette " \
                       'does not define. An HTML chart and its SVG twin are the same ' \
                       'colours only while there is one source for them.'
    end

    # A positive assertion as well as the two negatives: a stylesheet that had stopped
    # emitting colours at all would satisfy both of the above.
    it 'really does emit the chart layer\'s greys, so the checks above have a subject' do
      expect(css.downcase).to include(pal::TEXT.downcase)
      expect(css.downcase).to include(pal::GRID.downcase)
      expect(css.downcase).to include(pal::MUTED_TEXT.downcase)
    end
  end

  describe 'the type scale, shared with the chart layer' do
    # THE THREE SHARED STEPS ARE READ, and this is asserted on the SOURCE for the same
    # reason the palette is: `FONT_H3 == 14` is true of a copy too. Ruby cannot tell a
    # reference to an Integer constant from a literal of the same value at runtime, so the
    # reference is asserted where it is written.
    it 'reads its three chart-adjacent steps from ChartLayout rather than restating them' do
      # The SIZE steps only. `FONT_FAMILY` is a step of nothing — it is the face, asserted
      # by identity two examples down — and a pattern wide enough to catch it made this
      # example fail on its first run for a reason that had nothing to do with the scale.
      declarations = source_code_only.scan(/^\s*(FONT_(?:SMALL|BODY|H\d))\s*=\s*(.+?)\s*$/)
                                     .to_h

      expect(declarations.keys)
        .to contain_exactly('FONT_SMALL', 'FONT_BODY', 'FONT_H3', 'FONT_H2', 'FONT_H1')

      expect(declarations['FONT_SMALL']).to eq('Layout::TICK_FONT')
      expect(declarations['FONT_BODY']).to eq('Layout::AXIS_TITLE_FONT')
      expect(declarations['FONT_H3']).to eq('Layout::TITLE_FONT')

      # The two steps a chart has no equivalent for. Literals, legitimately — and
      # asserted to BE literals so a later edit cannot quietly point them at an unrelated
      # chart constant and call that sharing.
      expect(declarations['FONT_H2']).to match(/\A\d+\z/)
      expect(declarations['FONT_H1']).to match(/\A\d+\z/)
    end

    it 'resolves those steps to the chart layer\'s actual sizes' do
      expect(described_class::FONT_SMALL).to eq(chart_layout::TICK_FONT)
      expect(described_class::FONT_BODY).to eq(chart_layout::AXIS_TITLE_FONT)
      expect(described_class::FONT_H3).to eq(chart_layout::TITLE_FONT)
    end

    it 'emits no font size that is not a step of that scale' do
      used = css.scan(/font-size:\s*([\d.]+)px/).flatten.map(&:to_i).uniq
      stray = used - described_class::SCALE

      expect(stray).to be_empty,
                       "the stylesheet emits font-size #{stray.join('px, ')}px, which is " \
                       'not a step of the scale. "One type scale" is a property of the ' \
                       'file, not an aspiration in its header.'
    end

    it 'is ordered, so a heading is never smaller than the body text' do
      expect(described_class::SCALE).to eq(described_class::SCALE.sort)
    end

    # IDENTITY, not equality, and here it is available: a frozen String constant assigned
    # from another is the SAME OBJECT, so this fails the moment somebody types the stack
    # out again.
    it 'sets the body in the same face SvgRenderer draws with' do
      expect(described_class::FONT_FAMILY).to be(svg_renderer::FONT_FAMILY)
      expect(css).to include(svg_renderer::FONT_FAMILY)
    end

    it 'takes its line height from the chart layer too' do
      expect(described_class::LINE_HEIGHT).to eq(chart_layout::LINE_HEIGHT_RATIO)
      expect(css).to include("line-height: #{chart_layout::LINE_HEIGHT_RATIO}")
    end
  end

  describe 'print behaviour' do
    it 'repeats a table header across pages' do
      expect(css).to match(/thead\s*\{[^}]*display:\s*table-header-group/m)
    end

    it 'repeats a table footer too, so a total is not stranded on page one' do
      expect(css).to match(/tfoot\s*\{[^}]*display:\s*table-footer-group/m)
    end

    it 'sets orphans and widows to 3, per §9b.4' do
      expect(css).to match(/orphans:\s*3/)
      expect(css).to match(/widows:\s*3/)
    end

    # EVERY BREAK RULE IN BOTH SPELLINGS. `spec/conformance/F-05-page-breaks` carries both
    # because wkhtmltopdf's 2011 WebKit knows only the legacy one, and a rule in the
    # modern spelling alone is a rule that silently does nothing on one of the three
    # engines in the support matrix. Enumerated per selector rather than counted, so a
    # NEW block that forgets the legacy spelling is a failure rather than a smaller
    # majority.
    {
      'a card' => '.rrd-card',
      "the HTML binding's chart frame" => '.rrd-chart-frame',
      'a refused chart\'s placeholder' => '.rrd-chart-placeholder',
      'a mermaid diagram' => '.rrd-mermaid',
      "the PDF binding's inline SVG" => 'svg.rrd-chart',
      'a table row' => 'tr'
    }.each do |what, selector|
      it "keeps #{what} on one page, in both spellings" do
        block = rule_block_for(css, selector)

        expect(block).not_to be_nil, "no rule in the stylesheet selects #{selector}"
        expect(block).to include('break-inside: avoid'),
                         "#{selector} has no modern break-inside rule"
        expect(block).to include('page-break-inside: avoid'),
                         "#{selector} has no legacy page-break-inside rule, so it does " \
                         'nothing at all on wkhtmltopdf'
      end
    end

    it 'keeps a heading with the section it introduces, in both spellings' do
      block = rule_block_for(css, 'h1, h2, h3, h4')

      expect(block).to include('break-after: avoid')
      expect(block).to include('page-break-after: avoid')
    end

    # §9b.4 gives the geometry to `DocumentRequest`, and every adapter applies it through
    # its own API. An `@page` rule here would be a second answer to the same question, and
    # the engines do not agree about which one wins.
    it 'declares no @page geometry, which the document request owns' do
      expect(css).not_to include('@page')
    end
  end

  describe 'what a report body may not contain' do
    # The CSS vectors §Findings F-17 enumerated when it measured Mermaid's own `<style>`
    # element. None of them is in our output either, and unlike Mermaid's this one is ours
    # to keep that way.
    %w[@import url( expression( javascript: behavior: -moz-binding].each do |vector|
      it "contains no #{vector}" do
        expect(css).not_to include(vector)
      end
    end

    # `url(` in particular is what makes "wrapped before asset resolution" free: the
    # document scanner walks the stylesheet along with the body, and a stylesheet with a
    # reference in it would be a reference the run has to resolve or refuse.
    it 'therefore adds no asset reference to any document it goes into' do
      expect(css).not_to match(/url\s*\(/)
    end
  end

  describe 'the element that carries it' do
    it 'is a single <style>' do
      expect(described_class.style_element.scan('<style>').length).to eq(1)
      expect(described_class.style_element).to end_with('</style>')
    end

    # A `</style>` inside the CSS would close the element early and put the rest of the
    # stylesheet into the document as text. Nothing author-supplied reaches here, so this
    # is a construction check rather than an escaping one — and it is the check that would
    # notice if that ever stopped being true.
    it 'cannot be closed early by its own content' do
      expect(described_class.css).not_to include('</style')
    end

    it 'is built once, so both bindings get the same bytes rather than equal ones' do
      expect(described_class.css).to be(described_class.css)
      expect(described_class.style_element).to be(described_class.style_element)
      expect(described_class.css).to be_frozen
    end

    # A REAL BOUND, not a comfortable one. It was `< 16 KiB` against a 5.3 KiB artefact, which
    # noticed nothing — and a review pointed out what those bytes were: half of them were the
    # stylesheet's own comments, travelling into the `srcdoc` attribute of every frame on the
    # page. The comments are stripped on the way out now, and the bound is set where it will
    # notice the next thing that grows: 4 KiB is comfortably above today's ~2.5 KiB and far
    # below what half a page of prose costs.
    it 'is bounded — it is inlined into every document of every render' do
      expect(described_class.style_element.bytesize).to be < 4 * 1024
    end

    it 'ships its rules and not its rationale, which lives in the Ruby' do
      expect(described_class.css.scan(%r{/\*}).length).to eq(1),
                                                          'exactly one comment survives: the ' \
                                                          'banner naming the source file'
      expect(described_class.css).to include('report_stylesheet.rb')
    end
  end

  describe 'the mermaid states (FR-68), which used to be styled where they could not apply' do
    # Moved here from the chrome stylesheet by T-38. Redmine loads that file into its own
    # page head; a diagram only ever exists inside the report body, which is inside an
    # opaque-origin `srcdoc` iframe or inside the document an engine draws. Neither parses
    # Redmine's stylesheet, so these rules matched nothing at all.
    #
    # `pending` is deliberately NOT in this list. It is the transient state between "the
    # library loaded" and "the diagram is drawn", and during it the source the author
    # wrote is legitimately what a reader should see — the same reason the fallback is "do
    # nothing".
    %w[drawn unsupported failed refused].each do |state|
      it "styles the #{state} state" do
        expect(css).to include(%([data-rd-mermaid-state="#{state}"]))
      end
    end

    it 'gives a refused diagram a minimum height, because its body is empty (INV-4)' do
      expect(css).to match(/refused"\]\s*\{[^}]*min-height/m)
    end

    # NO TEXT IN THE CSS. `content:` cannot be localised and this plugin ships nine
    # locales (CLAUDE.md §10), so a hardcoded English sentence here would read as a bug to
    # a Russian or Dutch reader and be invisible to review in English.
    it 'says nothing in words, in any state' do
      expect(css).not_to match(/content:\s*["']/)
    end
  end

  describe 'the screen block, which may not contradict a print rule' do
    it 'exists, and adds the gutter the frame has no page margin for' do
      expect(css).to match(/@media screen\s*\{/)
      expect(css).to include("padding: #{described_class::SCREEN_PADDING_PX}px")
    end

    # The usual phone trick for a wide table is `table { display: block; overflow-x: auto }`,
    # and it takes `thead` out of the table box — which disables
    # `display: table-header-group`, the one rule a three-page table depends on. A screen
    # convenience that silently switches off a print guarantee is the defect §9b.4 is
    # written against, so it is asserted absent rather than merely not written.
    it 'does not re-display a table as a block, which would disable the repeating header' do
      screen = css[/@media screen\s*\{.*?\n\s*\}/m].to_s

      # NOT ANCHORED ON `\z`, and not allowed to be empty. The first version matched to the
      # END of the stylesheet, so the day anything is appended after the screen block the match
      # is nil, `.to_s` makes it `''`, and this example passes having examined nothing —
      # exactly the "a check that did not run looks like a check that passed" shape this
      # repository keeps meeting. Found in review.
      expect(screen).not_to be_empty, 'the screen block was not found, so nothing was checked'
      expect(screen).not_to match(/(^|[^-])table[^{]*\{[^}]*display:\s*block/m)
    end

    it 'is the only media block, so the print rules are the base rules' do
      expect(css.scan(/@media/).length).to eq(1)
    end
  end

  describe 'the CSS itself' do
    it 'has balanced braces' do
      expect(css.count('{')).to eq(css.count('}'))
    end

    it 'closes every declaration block it opens before the next selector' do
      # A missing `}` makes every later rule a child of the unclosed block and silently
      # dead. Counting is not enough — `{{` and `}}` balance too — so the depth is walked.
      depth = 0
      css.each_char do |char|
        depth += 1 if char == '{'
        depth -= 1 if char == '}'
        break if depth.negative?
      end

      expect(depth).to eq(0)
    end
  end

  # A `{ … }` block for one selector, matched on the selector standing alone in front of
  # the brace — so `tr` does not also match `.rrd-chart-frame,\n tr`, and `svg.rrd-chart`
  # is told apart from `.rrd-chart`.
  def rule_block_for(text, selector)
    pattern = /(?:^|,\s*|\n\s*)#{Regexp.escape(selector)}\s*(?:,[^{]*)?\{([^}]*)\}/m
    match = text.match(pattern)
    match && match[1]
  end
end
