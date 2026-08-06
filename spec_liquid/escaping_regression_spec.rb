# frozen_string_literal: true

# T-19's regression table, and the one assertion in this repository that has to be
# phrased exactly right.
#
# --- WHY IT ASSERTS "PARSES" AND NOT "DOES NOT EXECUTE" ---
#
# The security review ranked data-driven XSS through the documented escaping idiom as its
# HIGHEST finding, and flagged it as derived rather than demonstrated.
# `reference/verification-liquid-js-escaping.md` ran the experiment and corrected it in
# both directions: the injection is real — neither shipped idiom strips a backslash — and
# the XSS is not, because 0 of 2 940 payloads executed. Breaking out of the string
# succeeds; re-synchronising the parse needs a quote, and both idioms make a quote
# impossible.
#
# So the measured impact is **denial of rendering**: the array literal is left
# unterminated and the whole `<script>` block dies with a SyntaxError, taking the chart,
# the drill-through URLs and the readiness handshake with it.
#
# T-19's acceptance list is explicit about the consequence for this file:
#
#   "A regression table from the escaping experiment including a backslash-terminated
#    value, asserting the assembled `<script>` block PARSES — because the actual finding
#    was denial of rendering via SyntaxError, so a test asserting only 'no execution'
#    would have passed the buggy code."
#
# It would have. Under the old idiom nothing executed either. A test that checked only
# for execution would have gone green against the defect it was written for.
#
# --- SO THIS FILE PROVES BOTH HALVES ---
#
# For each payload it renders the SAME chart block twice — once through the old idiom
# and once through `| json` — and parses both with a real JavaScript engine:
#
#   the old idiom  must FAIL to parse for the backslash payloads. Pinned as it IS, so
#                  the day somebody "improves" the verification's conclusion this file
#                  says what moved.
#   `| json`       must PARSE for every payload, and the parsed value must equal the
#                  input byte for byte — escaping that loses data is a different bug
#                  wearing the same green tick.
#
# Node, because Chromium is V8 and so is Node, so the reference engine's parser is the
# one under test. `spec/render/readiness_spec.rb` already runs JS this way.

require 'liquid'
require 'json'
require 'open3'
require 'tempfile'

require_relative '../lib/redmine_reporter_dashboards/liquid/filters'

module RedmineReporterDashboards
  module Liquid
    RSpec.describe 'the JS escaping regression table (FR-19)' do
      # Every one of these is a value an ordinary project member can set: a version name,
      # a custom field, an issue subject. None of them needs any privilege.
      PAYLOADS = {
        'backslash terminator' => 'x\\',
        'backslash then break out' => 'a\\',
        'the measured pair, second half' => '-alert(1)//',
        'double backslash' => 'x\\\\',
        'single quote' => "it's",
        'double quote' => 'say "hi"',
        'closing script tag' => '</script>',
        'closing script tag, spaced' => '</script >',
        'template literal interpolation' => '${alert(1)}',
        'backtick' => 'a`b',
        'line separator U+2028' => "a\u2028b",
        'paragraph separator U+2029' => "a\u2029b",
        'newline' => "a\nb",
        'carriage return' => "a\rb",
        'nul' => "a\0b",
        'ampersand and angles' => 'a & b < c > d',
        'html entity that must stay literal' => '&quot;',
        'combined' => "x\\'-alert(1)//</script>\u2028`${x}`"
      }.freeze

      before do
        skip 'run with the real gem: rspec -r liquid spec_liquid' unless defined?(::Liquid::VERSION)
      end

      # THE OLD IDIOM, verbatim from what the README and the shipped examples carried
      # before T-19: a single-quoted JS string built by concatenation, with `| escape`
      # doing HTML escaping on JavaScript.
      OLD_IDIOM = <<~LIQUID
        (function(){
          var labels = ['{{ value | escape }}','ok'];
          var n = labels.length;
          return n;
        })();
      LIQUID

      # THE OWNED IDIOM. `| json` emits its own quotes, so the author cannot forget them,
      # and it escapes the backslash the old one let through.
      NEW_IDIOM = <<~LIQUID
        (function(){
          var labels = [{{ value | json }},'ok'];
          var n = labels.length;
          return n;
        })();
      LIQUID

      def render(source, value)
        template = ::Liquid::Template.parse(source, error_mode: :strict)
        context = ::Liquid::Context.new([{ 'value' => value }], {}, {}, true)
        context.add_filters(Filters.modules)
        template.render(context)
      end

      # A real JavaScript parse. `--check` parses without running, which is exactly the
      # question: the finding was that the block does not PARSE.
      def parses?(script)
        file = Tempfile.new(['rrd_escape', '.js'])
        file.write(script)
        file.close
        _out, _err, status = Open3.capture3('node', '--check', file.path)
        status.success?
      ensure
        file&.unlink
      end

      # What the engine actually ended up with, so "it parsed" cannot hide "it parsed and
      # lost half the value".
      def first_label(script)
        wrapped = "#{script.sub('return n;', 'return labels[0];')}"
        out, err, status = Open3.capture3('node', '-e',
                                          "process.stdout.write(JSON.stringify(#{wrapped.strip.chomp(';')}))")
        raise "node refused: #{err}" unless status.success?

        JSON.parse(out)
      end

      it 'has node available, or says so rather than passing quietly' do
        expect(Open3.capture3('node', '--version')[2]).to be_success
      end

      describe 'the owned idiom — `| json`' do
        PAYLOADS.each do |label, value|
          it "parses with a #{label}" do
            script = render(NEW_IDIOM, value)
            expect(parses?(script)).to be(true),
                                       "the assembled block does not parse:\n#{script}"
          end

          it "round-trips a #{label} without losing a byte" do
            expect(first_label(render(NEW_IDIOM, value))).to eq(value)
          end
        end

        # The one property no payload table can establish on its own: `</script>` must not
        # survive into the output in a form the HTML tokenizer would act on. It ends the
        # ELEMENT, and the tokenizer never looks inside a JS string — which is why `<` is
        # escaped rather than trusted to the quotes.
        it 'never emits a literal `</script` sequence' do
          PAYLOADS.each_value do |value|
            expect(render(NEW_IDIOM, value)).not_to include('</script')
          end
        end

        it 'never emits a raw line separator, which pre-ES2019 engines break on' do
          expect(render(NEW_IDIOM, "a\u2028b")).not_to include("\u2028")
          expect(render(NEW_IDIOM, "a\u2029b")).not_to include("\u2029")
        end
      end

      describe 'the old idiom — pinned AS MEASURED, not as it should be' do
        # This is the finding. Asserted so that the day somebody "fixes" `| escape` or
        # revisits the verification, this file says what moved rather than going quietly
        # green.
        it 'fails to parse on a backslash-terminated value' do
          script = render(OLD_IDIOM, 'x\\')

          expect(parses?(script)).to be(false),
                                     'the old idiom now parses; ' \
                                     'reference/verification-liquid-js-escaping.md needs revisiting'
        end

        it 'lets the backslash through unchanged, which is the input-handling defect' do
          expect(render(OLD_IDIOM, 'x\\')).to include("['x\\',")
        end

        # The half the review got wrong, kept because "Medium, not High" is only true
        # while this holds — and phrased from what the output ACTUALLY is rather than from
        # what the finding's headline suggests.
        #
        # This example first claimed the combined payload also fails to parse. It does
        # not, and the measurement says why: `| escape` turns the payload's quotes into
        # `&#39;`, `\&` is an identity escape in JavaScript, so the string simply
        # continues to the template's own closing quote and the block parses fine. What
        # the payload cannot do is REACH CODE POSITION, and that — not a SyntaxError — is
        # the property that makes it a denial of rendering rather than an XSS.
        #
        #   emitted: var labels = ['x\&#39;,&#39;-alert(1)//','ok'];
        #
        # The SyntaxError case is the backslash TERMINATOR, asserted above. Two different
        # payload shapes, two different outcomes, and conflating them is how a test ends
        # up asserting something that is not true.
        it 'never lets a payload reach code position — the re-sync quote is entity-encoded' do
          script = render(OLD_IDIOM, "x\\','-alert(1)//")

          expect(script).not_to include("'-alert"), 'a raw quote reached the output'
          expect(script).to include('&#39;')
          # Whatever it did to the token structure, `alert` is inside the string.
          expect(first_label(script)).to include('-alert(1)//')
        end

        # And the same value through the owned filter, side by side, so the fix is visible
        # in one place rather than inferred from two describes.
        it 'is fixed by `| json` for the same value' do
          expect(parses?(render(NEW_IDIOM, 'x\\'))).to be(true)
          expect(first_label(render(NEW_IDIOM, 'x\\'))).to eq('x\\')
        end
      end
    end
  end
end
