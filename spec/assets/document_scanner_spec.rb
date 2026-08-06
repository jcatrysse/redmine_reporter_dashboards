# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/assets'

# T-33 — `DocumentScanner`.
#
# HANDOVER §1 records what the FR-19 lint's regexp cost when it met prose containing the
# word `<script>`: 72 findings in a template that had none, and two rounds to fix. This
# scanner has the same three hazards, and here each one is a HOLE rather than a false
# positive:
#
#   * a URL in an HTML comment is never fetched, so refusing a document over it is wrong
#   * a URL in a `<script>` BODY is a string in a program, and rewriting it corrupts the
#     program
#   * an attribute this table does not list is a subresource nobody checked, which is what
#     `F-15-egress-denial` means by "one allowed subresource is all an SSRF needs"
#
# So the negatives are asserted as hard as the positives, and the table is enumerated.
module RedmineReporterDashboards
  module Assets
    RSpec.describe DocumentScanner do
      let(:origin) { Origin.from_settings('https', 'redmine.example') }

      def scan(html)
        described_class.scan(html, origin: origin)
      end

      def urls(html)
        scan(html).map(&:url)
      end

      # ------------------------------------------------------------------
      describe 'what it must find' do
        it 'finds an image, a stylesheet, a script and a font' do
          refs = scan(<<~HTML)
            <link rel="stylesheet" href="/a.css">
            <script src="/b.js"></script>
            <img src="/c.png">
            <style>@font-face { src: url(/d.woff2); }</style>
          HTML

          expect(refs.map { |ref| [ref.usage, ref.url] }).to eq(
            [[:stylesheet, '/a.css'], [:script, '/b.js'], [:image, '/c.png'], [:font, '/d.woff2']]
          )
        end

        it 'finds a url() in a STYLE ATTRIBUTE as well as in a <style> body' do
          expect(urls(<<~HTML)).to eq(['/in-attribute.png', '/in-body.png'])
            <p style="background: url('/in-attribute.png')">x</p>
            <style>.y { background-image: url("/in-body.png"); }</style>
          HTML
        end

        it 'finds `@import "x.css"`, the form a url() pattern misses' do
          refs = scan('<style>@import "/imported.css"; @import url(/other.css);</style>')

          # In DOCUMENT order, which is not the order the two patterns run in. And both
          # typed `:stylesheet` — an `@import url(x.css)` typed `:image` would be refused
          # for a usage mismatch, with the refusal blaming the file.
          expect(refs.map { |ref| [ref.usage, ref.url] })
            .to eq([[:stylesheet, '/imported.css'], [:stylesheet, '/other.css']])
        end

        it 'finds the legacy presentational attributes both engines still honour' do
          expect(urls('<body background="/bg.png"><table background="/t.png"><td background="/d.png">'))
            .to eq(['/bg.png', '/t.png', '/d.png'])
        end

        it 'finds SVG href and xlink:href' do
          expect(urls('<svg><image href="/a.png"/><use xlink:href="/b.svg#i"/></svg>'))
            .to eq(['/a.png', '/b.svg#i'])
        end

        it 'finds an <iframe>, an <object> and an <embed> so they can be REFUSED' do
          # A report should contain none of these. Listing them means an operator is told
          # about one rather than the engine quietly being handed a URL to fetch.
          refs = scan('<iframe src="https://x/a"></iframe><object data="https://x/b"></object>' \
                      '<embed src="https://x/c">')

          expect(refs.map(&:usage)).to eq(%i[other other other])
        end

        it 'reads a value whose quotes contain a `>`' do
          # `index(">")` would end the tag inside the alt text and lose the src entirely.
          expect(urls('<img alt="a > b" src="/after-the-gt.png">')).to eq(['/after-the-gt.png'])
        end

        it 'reads an unquoted attribute value' do
          expect(urls('<img src=/unquoted.png width=10>')).to eq(['/unquoted.png'])
        end

        it 'reads a single-quoted value' do
          expect(urls("<img src='/single.png'>")).to eq(['/single.png'])
        end

        it 'is case-insensitive about tag and attribute names' do
          expect(urls('<IMG SRC="/upper.png"><LINK REL="STYLESHEET" HREF="/upper.css">'))
            .to eq(['/upper.png', '/upper.css'])
        end
      end

      # ------------------------------------------------------------------
      # The three hazards. Each of these passing is the difference between a scanner and a
      # regexp that looked like one.
      describe 'what it must NOT find' do
        it 'ignores a reference inside an HTML comment' do
          expect(urls('<!-- <img src="https://evil.example/tracker.png"> --><p>x</p>')).to be_empty
        end

        it 'ignores a reference inside a <script> BODY' do
          html = <<~HTML
            <script>
              var next = "/issues/42";
              document.title = '<img src="https://evil.example/x.png">';
            </script>
          HTML

          expect(urls(html)).to be_empty
        end

        it 'still finds the src of the script element whose body it ignores' do
          expect(urls('<script src="/real.js">var x = "/not-real.png";</script>'))
            .to eq(['/real.js'])
        end

        it 'ignores a reference inside a <textarea>, which is literal text for a reader' do
          expect(urls('<textarea><img src="https://evil.example/x.png"></textarea>')).to be_empty
        end

        it 'ignores a <link> whose rel is not a subresource' do
          expect(urls('<link rel="canonical" href="https://evil.example/c">' \
                      '<link rel="alternate" href="https://evil.example/a">')).to be_empty
        end

        it 'ignores an <a href>, which is a link and not a subresource' do
          expect(urls('<a href="https://evil.example/page">x</a>')).to be_empty
        end

        it 'ignores a valueless attribute' do
          expect(urls('<img src>')).to be_empty
          expect(urls('<script src></script>')).to be_empty
        end

        it 'ignores an empty or whitespace-only value' do
          expect(urls('<img src="">')).to be_empty
          expect(urls('<img src="   ">')).to be_empty
        end
      end

      # ------------------------------------------------------------------
      describe 'srcset' do
        it 'is ONE reference over the whole attribute, resolving the first candidate' do
          # A `data:` URI contains a comma and `srcset` is comma-separated, so splicing a
          # replacement per candidate would produce an attribute that no longer parses.
          refs = scan('<img srcset="/a.png 1x, /b.png 2x, /c.png 3x" src="/fallback.png">')

          expect(refs.length).to eq(2)
          expect(refs.first.url).to eq('/a.png')
          expect(refs.first.candidates).to eq(3)
          # The span covers the WHOLE value, so the replacement replaces all three.
          expect(refs.first.span.last).to eq('/a.png 1x, /b.png 2x, /c.png 3x'.length)
        end

        it 'reports one candidate when there is only one' do
          expect(scan('<img srcset="/a.png">').first.candidates).to eq(1)
        end

        # ONE COMMA DEFEATED THE HOSTILE-DOCUMENT TEST. `srcset=",/x.png 1x"` is legal — a browser
        # skips the empty segment — and the first version read `segments.first`, found nothing,
        # and produced NO reference at all: the URL travelled through unrewritten and unrefused
        # with `ok?` true.
        it 'skips empty segments rather than giving up on the attribute' do
          [',https://evil.example/c.png 1x',
           ' , https://evil.example/c.png 1x',
           ',,https://evil.example/c.png 1x, /b.png 2x',
           'https://evil.example/c.png 1x,,'].each do |value|
            refs = scan(%(<img srcset="#{value}">))

            expect(refs.length).to eq(1), value
            expect(refs.first.url).to eq('https://evil.example/c.png'), value
          end
        end

        it 'produces no reference only when there is genuinely no candidate' do
          expect(scan('<img srcset=",,,">')).to be_empty
          expect(scan('<img srcset="  ">')).to be_empty
        end
      end

      # ------------------------------------------------------------------
      describe 'element spans' do
        it 'records the whole <link> element, so it can become a <style> block' do
          html = '<head><link rel="stylesheet" href="/a.css"></head>'
          span = scan(html).first.element_span

          expect(html[span.first, span.last]).to eq('<link rel="stylesheet" href="/a.css">')
        end

        it 'records the whole <script> element INCLUDING its closing tag' do
          html = '<head><script src="/a.js"></script></head>'
          span = scan(html).first.element_span

          expect(html[span.first, span.last]).to eq('<script src="/a.js"></script>')
        end

        it 'records NO element span for anything else' do
          expect(scan('<img src="/a.png">').first.element_span).to be_nil
        end

        # The resolver needs these to decide whether a structural rewrite would change what the
        # element MEANS — `media=print` on a stylesheet, `type=module` on a script.
        it 'records the element\'s own attributes alongside the reference' do
          reference = scan('<link rel="stylesheet" media="print" href="/a.css">').first

          expect(reference.element_attributes)
            .to eq('rel' => 'stylesheet', 'media' => 'print', 'href' => '/a.css')
        end

        it 'records them through the <script> element-span patch as well' do
          reference = scan('<script src="/a.js" type="module" defer></script>').first

          expect(reference.element_attributes.keys).to include('src', 'type', 'defer')
          expect(reference.element_span).not_to be_nil
        end

        it 'records no element span for an UNCLOSED script, so nothing can be truncated' do
          # A structural rewrite driven by a span running to the end of the document would
          # delete the rest of the report.
          reference = scan('<script src="/a.js">').first

          expect(reference.element_span).to eq([0, nil])
        end
      end

      # ------------------------------------------------------------------
      # For anything with a limit, test AT the limit and one past it (CLAUDE.md §3). For a
      # scanner the equivalent is malformed input: it must terminate.
      describe 'malformed input terminates' do
        it 'survives an unterminated comment' do
          expect { scan('<!-- <img src="/a.png">') }.not_to raise_error
          expect(urls('<!-- <img src="/a.png">')).to be_empty
        end

        it 'survives an unterminated tag' do
          expect { scan('<img src="/a.png"') }.not_to raise_error
        end

        it 'survives an unterminated quoted value' do
          expect { scan('<img src="/a.png') }.not_to raise_error
        end

        it 'survives a bare `<` in text' do
          expect(urls('a < b <img src="/a.png">')).to eq(['/a.png'])
        end

        it 'survives a doctype and a processing instruction' do
          expect(urls('<!DOCTYPE html><?xml version="1.0"?><img src="/a.png">')).to eq(['/a.png'])
        end

        it 'survives an empty document' do
          expect(urls('')).to be_empty
        end

        # DETERMINISTIC, and pointed at the elements the raw-text scan actually runs for.
        # The first version timed a wall clock over 500 `<img>` tags — which never enter
        # `raw_text_bounds` at all, so it could not have caught the per-element `@html.downcase`
        # it claimed to, and a wall clock on a shared runner is not an assertion (CLAUDE.md §6).
        it 'scans 500 raw-text elements, finding every reference in them' do
          html = (1..500).map { |n| %(<style>.s#{n}{background:url(/a#{n}.png)}</style>) }.join
          refs = scan(html)

          expect(refs.length).to eq(500)
          expect(refs.first.url).to eq('/a1.png')
          expect(refs.last.url).to eq('/a500.png')
        end

        it 'does not downcase the whole document per raw-text element' do
          # The quadratic shape stated as a fact about calls rather than about a clock: one
          # `String#downcase` of the document per `<style>` is what the first draft did, and
          # `String#index(/regex/i, offset)` is what replaced it.
          html = (1..50).map { |n| %(<style>.s#{n}{background:url(/a#{n}.png)}</style>) }.join
          downcased = 0
          allow_any_instance_of(String).to receive(:downcase).and_wrap_original do |original, *args|
            downcased += 1
            original.call(*args)
          end

          scan(html)

          # Per-element work is fine; per-element work OVER THE WHOLE DOCUMENT is not. 50
          # elements must not cost 50 copies of a 2 000-character document.
          expect(downcased).to be < 50 * 4
        end
      end

      # ------------------------------------------------------------------
      # THE TABLE IS THE SECURITY PROPERTY, so it is enumerated rather than sampled. The review
      # measured that 12 of the attribute slots and 9 of the 10 `rel` values could be DELETED
      # with the whole suite green — a table whose completeness is the point, and whose rows
      # were almost entirely unasserted.
      describe 'the reference table, enumerated' do
        MINIMAL_ELEMENT = {
          'srcset' => ->(tag, attr) { %(<#{tag} #{attr}="/x.png 1x">) },
          'default' => ->(tag, attr) { %(<#{tag} #{attr}="/x.png">) }
        }.freeze

        it 'finds a reference for EVERY tag/attribute pair in ATTRIBUTE_REFERENCES' do
          described_class::ATTRIBUTE_REFERENCES.each do |tag, attributes|
            attributes.each do |attribute, usage|
              builder = MINIMAL_ELEMENT[attribute] || MINIMAL_ELEMENT['default']
              refs = scan(builder.call(tag, attribute))

              expect(refs.length).to eq(1), "#{tag}[#{attribute}] produced #{refs.length} references"
              expect(refs.first.usage).to eq(usage), "#{tag}[#{attribute}] usage"
              expect(refs.first.url).to eq('/x.png'), "#{tag}[#{attribute}] url"
            end
          end
        end

        it 'finds a reference for EVERY rel value in LINK_RELS, and none for one outside it' do
          described_class::LINK_RELS.each do |rel, usage|
            refs = scan(%(<link rel="#{rel}" href="/x.css">))

            expect(refs.length).to eq(1), "rel=#{rel}"
            expect(refs.first.usage).to eq(usage), "rel=#{rel} usage"
          end

          expect(scan('<link rel="canonical" href="/x">')).to be_empty
        end

        it 'covers every usage the resolver can be handed' do
          # A usage in `Reference::USAGES` that nothing produces is either dead or a hole. `:font`
          # comes from CSS rather than an attribute, so it is checked separately.
          from_table = described_class::ATTRIBUTE_REFERENCES.values.flat_map(&:values) +
                       described_class::LINK_RELS.values
          # `:script` and `:stylesheet` are the two `usage_for` special-cases (they need element
          # spans, so they are not in `ATTRIBUTE_REFERENCES`), and `:font` comes from CSS.
          from_special = scan('<script src="/a.js"></script>').map(&:usage)
          from_css = scan('<style>@font-face{src:url(/f.woff2)}</style>').map(&:usage)

          expect((from_table + from_special + from_css).uniq.sort).to eq(Reference::USAGES.sort)
        end
      end

      # ------------------------------------------------------------------
      # A trailing `/` MEANS NOTHING in HTML, and honouring it was a blocker: `<style/>` made an
      # entire stylesheet invisible to this scanner (an egress hole) and `<script/>` made a
      # program body get scanned as markup (the corruption this class exists to prevent).
      describe 'a trailing slash on a raw-text element' do
        it 'still scans a <style/> body, because <style/> is an OPEN style element' do
          expect(urls('<style/>body{background:url(https://evil.example/x.png)}</style>'))
            .to eq(['https://evil.example/x.png'])
        end

        it 'still treats a <script/> body as opaque, and keeps scanning after it' do
          refs = scan('<script/>var u = "https://evil.example/x.png";</script><img src="/after.png">')

          expect(refs.map(&:url)).to eq(['/after.png'])
        end

        it 'still treats a <textarea/> body as opaque' do
          expect(urls('<textarea/>https://evil.example/x.png</textarea><img src="/after.png">'))
            .to eq(['/after.png'])
        end

        # The one exception, and it is tracked rather than assumed: inside `<svg>`/`<math>` XML
        # rules apply and `<style/>` really is empty. Treating it as open would search for a
        # `</style>` that is not there, and the scanner would stop and miss the rest.
        it 'honours <style/> INSIDE svg, so the rest of the document is still scanned' do
          expect(urls('<svg><style/></svg><img src="/after.png">')).to eq(['/after.png'])
        end

        it 'honours it inside math too, and stops honouring it after </svg>' do
          expect(urls('<math><style/></math><img src="/a.png">')).to eq(['/a.png'])
          expect(urls('<svg></svg><style/>b{background:url(/b.png)}</style>')).to eq(['/b.png'])
        end

        it 'handles nested svg without leaving foreign content early' do
          expect(urls('<svg><svg><style/></svg><style/></svg><img src="/a.png">')).to eq(['/a.png'])
        end
      end

      describe 'spans do not overlap' do
        it 'produces disjoint value spans across a realistic document' do
          html = <<~HTML
            <link rel="stylesheet" href="/a.css">
            <script src="/b.js"></script>
            <style>.x { background: url(/c.png); }</style>
            <img src="/d.png" srcset="/e.png 1x, /f.png 2x">
            <p style="background:url(/g.png)">t</p>
          HTML

          spans = scan(html).map(&:span).sort_by(&:first)
          spans.each_cons(2) do |(start, length), (next_start, _)|
            expect(start + length).to be <= next_start
          end
          expect(spans.length).to eq(6)
        end
      end
    end
  end
end
