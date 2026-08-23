# frozen_string_literal: true

require_relative 'charts/chart_layout'
require_relative 'charts/palette'
require_relative 'charts/svg_renderer'

module RedmineReporterDashboards
  # T-38 — ONE print-first stylesheet for the report BODY, used by both bindings.
  #
  # --- WHY THIS IS RUBY AND NOT A `.css` FILE ---
  #
  # Because of one clause in T-38's acceptance list: *"the palette is read from
  # `ChartLayout`, not duplicated in CSS — a test asserts a single source"*. A
  # `.css` file cannot read a Ruby constant, so a stylesheet on disk would have to
  # restate `#0072B2` and `#333333` next to a chart layer that already owns them —
  # and "the axis is a slightly different grey in the PDF" is precisely the class of
  # difference `Palette`'s own header says nobody can find later.
  #
  # So the colours and the type scale are READ, the CSS text is built once, and there
  # is no second copy of a number to drift. `spec/report_stylesheet_spec.rb` asserts
  # this file contains no colour literal at all.
  #
  # --- AND WHY IT IS INLINED RATHER THAN `<link>`ED ---
  #
  # The HTML binding puts the report body in an opaque-origin `srcdoc` iframe whose
  # policy is `default-src 'none'; img-src data:; style-src 'unsafe-inline'`
  # (`ReportFrame::CONTENT_SECURITY_POLICY`). A `<link rel=stylesheet>` is a
  # `style-src` FETCH, which that policy denies — so a stylesheet the body needs
  # either gets inlined into the document `ReportDocument` assembles or the CSP has
  # to grow a hole. Inlining is the cheaper of the two by a wide margin, and it is
  # also what makes the PDF path work: `DocumentRequest#body` is "a COMPLETE,
  # already-asset-resolved document" and an engine that fetched a stylesheet would be
  # an engine fetching something on the viewer's behalf (INV-8).
  #
  # --- PRINT-FIRST MEANS THE BASE RULES ARE THE PRINT RULES ---
  #
  # Everything outside `@media screen` is what a PDF gets. The screen block adds what
  # only a browser can use (a reading measure, a scrollable wide table) and takes
  # nothing away, so a rule cannot be true in one binding and false in the other —
  # which is the defect class §9b.4 exists to remove ("the same document at two sizes
  # rather than two designs").
  #
  # --- EVERY BREAK RULE IS WRITTEN TWICE, AND THAT IS NOT REDUNDANCY ---
  #
  # `spec/conformance/F-05-page-breaks/document.html` carries `page-break-before` AND
  # `break-before` for a measured reason: this plugin renders on a 2011 WebKit
  # (`wkhtmltopdf`) that knows only the legacy spelling, and on Chromium, which knows
  # both. One spelling is a rule that silently does nothing on one of the three
  # engines in the support matrix.
  module ReportStylesheet
    Layout = Charts::ChartLayout
    Palette = Charts::Palette

    # --- THE TYPE SCALE. ONE, shared with the chart layer by REFERENCE. -------------
    #
    # Three of the five steps ARE `ChartLayout`'s own constants, not copies of their
    # values, so a table cell and a chart's tick label cannot end up one pixel apart.
    # The two above them have no chart equivalent — a chart has no `h1` — so they are
    # declared here, once, and nowhere else.
    #
    # The sizes are px and not pt or rem, deliberately. `SvgRenderer` draws in px
    # because `ChartLayout` computes in px, and a body scale in a different unit
    # would make "the same size" an arithmetic claim about two units instead of an
    # identity. rem would be worse still: it resolves against the document root,
    # which is Redmine's on one binding and the engine's default on the other.
    FONT_SMALL = Layout::TICK_FONT
    FONT_BODY = Layout::AXIS_TITLE_FONT
    FONT_H3 = Layout::TITLE_FONT
    FONT_H2 = 17
    FONT_H1 = 20

    SCALE = [FONT_SMALL, FONT_BODY, FONT_H3, FONT_H2, FONT_H1].freeze

    # Shared with the chart layer for the same reason the sizes are: a report whose
    # prose is set in one face and whose chart labels are set in another is two
    # documents. `SvgRenderer` writes this stack into one attribute on the `<svg>`
    # root; this is the same string object.
    FONT_FAMILY = Charts::SvgRenderer::FONT_FAMILY

    LINE_HEIGHT = Layout::LINE_HEIGHT_RATIO

    # §9b.4: "orphans/widows 3".
    ORPHANS = 3

    # The gutter the HTML binding needs and the print binding must not have. On paper
    # the margin comes from `DocumentRequest#margins_mm`, which the engine applies;
    # inside the frame there is no page, so without this the first character sits on
    # the frame's border.
    SCREEN_PADDING_PX = 10

    class << self
      # The stylesheet. Built once — every render of every report gets the same bytes,
      # which is also what makes "one stylesheet, two outputs" assertable by identity
      # rather than by comparing two strings.
      #
      # THE COMMENTS ARE STRIPPED ON THE WAY OUT, and a review is why. The heredocs below
      # explain every rule, and half the bytes were that explanation — which then travelled
      # into the `srcdoc` attribute of every frame on a page. At 15 report widgets on one
      # project dashboard that is tens of kilobytes of duplicated commentary, HTML-escaped,
      # in an attribute nobody reads. The rationale belongs where a maintainer looks for it,
      # which is this file; the artefact keeps one line saying where that is.
      def css
        @css ||= "#{BANNER}\n#{strip_comments(build)}".freeze
      end

      # The one comment the artefact keeps. A reader viewing a report's source should be able
      # to find out who wrote these rules and why without guessing.
      BANNER = '/* redmine_reporter_dashboards — the report stylesheet. Generated from ' \
               'lib/redmine_reporter_dashboards/report_stylesheet.rb, which explains every ' \
               'rule below. Do not edit a copy: there is one source. */'

      # What goes in the document head. `<style>` and not an attribute: the rules are
      # a document-wide cascade, and the CSP permits inline style.
      #
      # NOTHING HERE IS AUTHOR-SUPPLIED, so there is nothing to escape and no
      # `html_safe` (INV-9). Every byte comes from the constants above and from
      # `Palette`, and `Palette.rgb` refuses anything that is not `#rrggbb`.
      # NOT SYNCHRONISED, and it does not need to be: both memos derive from frozen constants
      # and a pure function of them, so two threads racing here build two identical strings and
      # one of them is discarded. The identity claims elsewhere in this change are about there
      # being one SOURCE, which no race can change.
      def style_element
        @style_element ||= "<style>\n#{css}\n</style>".freeze
      end

      private

      # Comment spans out, blank runs collapsed, trailing whitespace gone. Non-greedy and
      # multi-line — the greedy version of this deleted everything between the first `/*` and
      # the last `*/`, which is the defect `chrome_no_design_tokens.sh` records having had.
      def strip_comments(text)
        text.gsub(%r{/\*.*?\*/}m, '')
            .gsub(/[ \t]+$/, '')
            .gsub(/\n{3,}/, "\n\n")
            .strip
      end

      # The CSS, in the order a reader would look for it: the page, the type, the
      # flow, then the plugin's own emitted blocks.
      def build
        [page, typography, tables, blocks, mermaid, screen].join("\n")
      end

      def page
        <<~CSS
          /* --- the page ------------------------------------------------------------ */

          /* @page geometry is NOT set here. `DocumentRequest` carries page_size,
             orientation and margins_mm and every adapter applies them through its own
             API, which is the only spelling all three engines agree on; a competing
             @page rule would give one document two answers. */
          html { background: #{Palette::BACKGROUND}; }

          body {
            margin: 0;
            padding: 0;
            background: #{Palette::BACKGROUND};
            color: #{Palette::TEXT};
            font-family: #{FONT_FAMILY};
            font-size: #{FONT_BODY}px;
            line-height: #{LINE_HEIGHT};
            orphans: #{ORPHANS};
            widows: #{ORPHANS};
          }
        CSS
      end

      def typography
        <<~CSS
          /* --- type ---------------------------------------------------------------- */

          h1, h2, h3, h4 {
            color: #{Palette::TEXT};
            font-family: #{FONT_FAMILY};
            line-height: #{LINE_HEIGHT};
            margin: 0 0 6px;
            /* A heading at the foot of a page whose section starts on the next one is
               the single most common print defect in a long report. */
            page-break-after: avoid;
            break-after: avoid;
            page-break-inside: avoid;
            break-inside: avoid;
          }

          h1 { font-size: #{FONT_H1}px; }
          h2 { font-size: #{FONT_H2}px; margin-top: 14px; }
          h3 { font-size: #{FONT_H3}px; margin-top: 12px; }
          h4 { font-size: #{FONT_BODY}px; margin-top: 10px; font-weight: bold; }

          p, ul, ol { margin: 0 0 8px; }

          small, .rrd-muted, figcaption {
            font-size: #{FONT_SMALL}px;
            color: #{Palette::MUTED_TEXT};
          }

          /* A LINK IS UNDERLINED IN PRINT, and that is FR-76 rather than taste: on
             paper a link whose only mark is a colour is meaning carried by colour
             alone, and it is the same rule that puts a label beside every chart
             swatch. Drill-through targets stay real links (they are annotations in the
             PDF); the underline is what tells a reader on paper that they are. */
          a { color: #{Palette::LINK}; text-decoration: underline; }
        CSS
      end

      def tables
        <<~CSS
          /* --- tables -------------------------------------------------------------- */

          table { width: 100%; border-collapse: collapse; margin: 0 0 10px; }

          /* THE HEADER REPEATS ON EVERY PAGE. A three-page table whose columns are
             named only on page one is a table nobody can read past the first break,
             and `display: table-header-group` is the one spelling every engine in the
             matrix honours. */
          thead { display: table-header-group; }
          tfoot { display: table-footer-group; }

          /* A row split across a page boundary loses half its digits above the fold. */
          tr { page-break-inside: avoid; break-inside: avoid; }

          th, td {
            padding: 3px 6px;
            text-align: left;
            vertical-align: top;
            border-bottom: 1px solid #{Palette::GRID};
          }

          th {
            font-size: #{FONT_SMALL}px;
            font-weight: bold;
            border-bottom: 1px solid #{Palette::AXIS};
          }

          /* Numbers line up under each other or they are not a column. `tabular-nums`
             is ignored by the 2011 WebKit, which is why the alignment does not depend
             on it. */
          .rrd-number, td.rrd-number, th.rrd-number {
            text-align: right;
            font-variant-numeric: tabular-nums;
          }
        CSS
      end

      def blocks
        <<~CSS
          /* --- cards and chart blocks ---------------------------------------------- */

          /* `.rrd-card` is the ONE card class this plugin defines, and it defines no
             grid to put cards in. A grid would have to promise the same layout on a
             2011 WebKit with no flexbox and no CSS grid, and "it looked fine in the
             browser and broke in the PDF" is the defect class this whole dossier
             exists to remove — so the layout stays the author's and the page-break
             behaviour is ours. */
          .rrd-card {
            border: 1px solid #{Palette::GRID};
            padding: 8px 10px;
            margin: 0 0 8px;
            page-break-inside: avoid;
            break-inside: avoid;
          }

          .rrd-card > :first-child { margin-top: 0; }

          /* Every shape `{% chart %}` and `{% mermaid %}` can leave in a document:
             the HTML binding's canvas frame, the PDF binding's inline SVG, the
             placeholder a refused chart leaves behind, and a diagram. A chart broken
             over a page boundary is not a chart. */
          .rrd-chart-frame,
          .rrd-chart-placeholder,
          .rrd-mermaid,
          svg.rrd-chart,
          figure {
            page-break-inside: avoid;
            break-inside: avoid;
          }

          .rrd-chart-frame, figure { margin: 0 0 10px; }

          /* The SVG twin is a block so it does not sit on a text baseline, and it
             scales DOWN inside a narrow page rather than being clipped by it. */
          svg.rrd-chart { display: block; max-width: 100%; height: auto; }
        CSS
      end

      # Moved here from `assets/stylesheets/redmine_reporter_dashboards.css` by T-38,
      # and the move is a BUG FIX rather than tidying.
      #
      # Those rules lived in the chrome stylesheet, which Redmine loads into its own
      # page head. A `{% mermaid %}` diagram only ever exists inside the report body —
      # which is inside the opaque-origin `srcdoc` iframe on every HTML surface
      # (`ReportFrame` is the only thing that displays a body), or inside the document
      # an engine draws. Neither of those parses Redmine's stylesheet, so the rules
      # applied to NOTHING: a diagram wkhtmltopdf could not draw got no dashed border
      # and no muted monospace treatment, and FR-68's "emitted, labelled, never a blank
      # space" was half true — emitted, unlabelled. Here they apply.
      #
      # NO TEXT IN THE CSS, still, and for the reason the original said: `content:`
      # cannot be localised and this plugin ships nine locales (CLAUDE.md §10). The
      # treatment is typographic.
      def mermaid
        <<~CSS
          /* --- mermaid states (FR-68) ---------------------------------------------- */

          .rrd-mermaid { margin: 1em 0; overflow-x: auto; }

          /* Drawn: the SVG has replaced the source, so the <pre>'s own formatting must
             not fight it. */
          .rrd-mermaid[data-rd-mermaid-state="drawn"] {
            white-space: normal;
            font-family: inherit;
            background: none;
            border: 0;
            padding: 0;
          }

          /* Not drawn: the engine could not run the library, the diagram was refused,
             or it failed. Same treatment for all three — to a reader they are one
             situation: this is the source. */
          /* `border-radius` is here because the chrome version had it and the first draft of
             this move silently dropped it — an undocumented visual change inside a change
             whose whole thesis is that these rules finally apply. */
          .rrd-mermaid[data-rd-mermaid-state="unsupported"],
          .rrd-mermaid[data-rd-mermaid-state="failed"],
          .rrd-mermaid[data-rd-mermaid-state="refused"] {
            border: 1px dashed #{Palette::AXIS};
            border-radius: 3px;
            padding: 8px 10px;
            color: #{Palette::MUTED_TEXT};
            font-size: #{FONT_SMALL}px;
            font-family: monospace;
          }

          /* A refused diagram has an EMPTY body, so without a minimum it would be an
             invisible element and the gap INV-4 objects to would be back. */
          .rrd-mermaid[data-rd-mermaid-state="refused"] { min-height: 1.5em; }
        CSS
      end

      # WHAT ONLY A BROWSER CAN USE, and it is deliberately two rules rather than a
      # responsive framework.
      #
      # NOTHING HERE MAY CONTRADICT A PRINT RULE, which rules out the usual
      # `table { display: block; overflow-x: auto }` phone trick: `display: block` on
      # a table takes `thead` out of the table box, and `display: table-header-group`
      # — the rule two blocks up, the one a three-page table depends on — then has
      # nothing to apply to. A screen convenience that silently disables a print
      # guarantee is the exact shape of defect §9b.4 is written against.
      #
      # What makes the body readable on a phone instead: nothing here sets a width, so
      # text reflows, and the frame the HTML binding uses scrolls in both axes on its
      # own. A chart's frame is the one element with a fixed pixel width — the emitter
      # computes the canvas size — so it gets to scroll rather than widen the page.
      def screen
        <<~CSS
          /* --- screen only ---------------------------------------------------------- */

          @media screen {
            body { padding: #{SCREEN_PADDING_PX}px; }
            .rrd-chart-frame { max-width: 100%; overflow-x: auto; }
          }
        CSS
      end
    end
  end
end
