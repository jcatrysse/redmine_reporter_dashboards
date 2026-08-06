# frozen_string_literal: true

# T-19's acceptance list says the FR-19 lint must *"parse rather than regex the HTML"*.
# `Liquid::HtmlScanner` is what it parses with, and this file is the argument for why the
# change was worth making — every example is a case the regexp it replaced got wrong.
#
# The rule the scanner feeds is the one the security review ranked highest. Getting
# "where is the script" wrong means answering the right question about the wrong text,
# which is a worse failure than not asking: a linter that reports findings in the wrong
# place is a linter somebody switches off.
#
# NO LIQUID GEM NEEDED. The scanner is plain Ruby over a String, which is why it can live
# in the DB-less suite next to the linter that uses it.

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/liquid/html_scanner'

module RedmineReporterDashboards
  module Liquid
    RSpec.describe HtmlScanner do
      def contents(source)
        described_class.new(source).script_regions.map(&:content)
      end

      describe 'the ordinary case' do
        it 'finds the content between the tags' do
          expect(contents('<p>x</p><script>var a = 1;</script>')).to eq(['var a = 1;'])
        end

        it 'finds several, in source order' do
          expect(contents('<script>one</script><p>y</p><script>two</script>')).to eq(%w[one two])
        end

        it 'reports the offset the content really starts at, so a line number is real' do
          source = "line one\n<script>\nvar a = 1;\n</script>"
          region = described_class.new(source).script_regions.first

          expect(source[region.content_offset, 1]).to eq("\n")
          expect(source[0, region.content_offset].count("\n")).to eq(1)
        end
      end

      # --------------------------------------------------------------
      # What a regexp got wrong. Each of these is why this class exists.
      # --------------------------------------------------------------

      describe 'cases the regexp it replaced got wrong' do
        # WRONG FINDING, not a missing one, which is the worse direction: the author is
        # told to fix code they had already commented out.
        it 'ignores a script inside an HTML comment' do
          expect(contents('<!-- <script>{{ x }}</script> --><script>real</script>')).to eq(['real'])
        end

        # `<script\b[^>]*>` stops at the `>` inside the attribute. Everything after it is
        # then read as document text, so the script content is never linted AT ALL — and
        # the template looks clean.
        it 'does not end the open tag at a `>` inside an attribute value' do
          expect(contents('<script data-note="a>b">var a = 1;</script>')).to eq(['var a = 1;'])
          expect(contents("<script data-note='a>b'>var a = 1;</script>")).to eq(['var a = 1;'])
        end

        # A Liquid expression is not markup, and `{{ a > b }}` in an attribute is ordinary.
        it 'does not treat a `>` inside a Liquid expression as the end of a tag' do
          expect(contents('<div title="{{ a > b }}">t</div><script>real</script>')).to eq(['real'])
        end

        # THE ONE THAT ACTUALLY BIT, while writing T-19. A `{% comment %}` explaining why
        # chart data must not be built by string concatenation mentioned `<script>` in
        # prose; the scanner opened a region there and ran to the next real `</script>`
        # several hundred lines away. The linter reported 72 escaping findings in a
        # template that had none.
        it 'skips a {% comment %} BODY, not just the tag' do
          source = '{% comment %} beware <script> in prose {% endcomment %}' \
                   '<p>{{ x }}</p><script>real</script>'
          expect(contents(source)).to eq(['real'])
        end

        # `{% raw %}` renders its body literally, so `{{ x }}` in it is text rather than
        # interpolation — scanning it would describe a document that does not exist.
        it 'skips a {% raw %} body' do
          expect(contents('{% raw %}<script>{{ x }}</script>{% endraw %}<script>real</script>'))
            .to eq(['real'])
        end

        it 'skips whitespace-control forms of both' do
          expect(contents('{%- comment -%}<script>a</script>{%- endcomment -%}<script>b</script>'))
            .to eq(['b'])
        end

        it 'does not confuse `<style>` with `<script>`' do
          expect(contents('<style>a{color:red}</style><script>s</script>')).to eq(['s'])
        end

        it 'does not treat prose `a < b` as an element' do
          expect(contents('<p>a < b and c</p><script>s</script>')).to eq(['s'])
        end
      end

      # --------------------------------------------------------------
      # HTML's own rules, which are not always the intuitive ones
      # --------------------------------------------------------------

      describe "HTML's raw-text rules" do
        # THE REASON `| json` HAS TO ESCAPE `<`. The HTML tokenizer never looks inside a
        # JavaScript string, so `"</script>"` ends the ELEMENT — no amount of correct
        # JavaScript quoting helps, and this is not a quirk of the scanner but the spec.
        it 'ends the element at `</script>` even inside a JS string literal' do
          expect(contents('<script>var s = "</script>";</script>')).to eq(['var s = "'])
        end

        it 'does not end the element at `</scriptfoo>`' do
          expect(contents('<script>a</scriptfoo>b</script>')).to eq(['a</scriptfoo>b'])
        end

        it 'accepts whitespace and a slash before the end tag\'s `>`' do
          expect(contents('<script>a</script >')).to eq(['a'])
        end

        it 'is case-insensitive about both tags' do
          expect(contents('<SCRIPT>a</SCRIPT>')).to eq(['a'])
        end
      end

      describe 'the type attribute' do
        it 'reads it, quoted either way or bare' do
          expect(described_class.new('<script type="application/json">{}</script>')
                                .script_regions.first.type).to eq('application/json')
          expect(described_class.new("<script type='module'>a</script>")
                                .script_regions.first.type).to eq('module')
          expect(described_class.new('<script type=module>a</script>')
                                .script_regions.first.type).to eq('module')
        end

        it 'calls an absent or JavaScript type executable, and a data block not' do
          expect(described_class.new('<script>a</script>').script_regions.first).to be_javascript
          expect(described_class.new('<script type="text/javascript">a</script>')
                                .script_regions.first).to be_javascript
          expect(described_class.new('<script type="application/json">{}</script>')
                                .script_regions.first).not_to be_javascript
        end
      end

      # --------------------------------------------------------------
      # Bounds and malformed input. This runs on author-supplied text.
      # --------------------------------------------------------------

      describe 'malformed and hostile input' do
        it 'treats an unterminated script as running to the end, which is what a browser does' do
          expect(contents('<script>var a = 1;')).to eq(['var a = 1;'])
        end

        it 'terminates on an unterminated Liquid tag' do
          expect(contents('{{ never closed')).to eq([])
        end

        it 'terminates on an unterminated HTML comment' do
          expect(contents('<!-- never closed')).to eq([])
        end

        it 'terminates on an unterminated {% comment %}' do
          expect(contents('{% comment %} never closed <script>a</script>')).to eq([])
        end

        it 'terminates on an unterminated open tag' do
          expect(contents('<script data-a="unclosed')).to eq([])
        end

        it 'does not look for an end tag after a self-closing script' do
          expect(contents('<script src="x.js"/><p>after</p>')).to eq([])
        end

        it 'handles an empty and a nil-ish source' do
          expect(contents('')).to eq([])
          expect(contents(nil)).to eq([])
        end

        # The cap, at it and one past it. A document is author-supplied and the linter
        # bounds the body separately, so this is the second of two limits rather than the
        # only one.
        it 'stops at MAX_REGIONS' do
          many = '<script>a</script>' * (described_class::MAX_REGIONS + 10)
          expect(described_class.new(many).script_regions.length).to eq(described_class::MAX_REGIONS)
        end

        it 'returns everything when the document is exactly at the cap' do
          exact = '<script>a</script>' * described_class::MAX_REGIONS
          expect(described_class.new(exact).script_regions.length).to eq(described_class::MAX_REGIONS)
        end

        # A pathological body must not take exponential time. Not a benchmark — a
        # regression guard against a future rewrite that backtracks.
        it 'scans a large document in linear time' do
          source = ("<div title=\"{{ a > b }}\">x</div>\n" * 5_000) + '<script>real</script>'
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          expect(contents(source)).to eq(['real'])
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5.0
        end
      end
    end
  end
end
