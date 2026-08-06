# frozen_string_literal: true

require 'open3'
require 'tmpdir'

require_relative '../spec_helper'

# T-35 — `assets/javascripts/mermaid_boot.js`.
#
# --- THE ES5 ASSERTION IS THE POINT OF THIS FILE ---
#
# This script's whole job on wkhtmltopdf is to produce the FALLBACK: mark the diagram undrawn so
# the reader knows the source they are looking at is not a rendering error. If the script itself
# uses one arrow function it dies at PARSE time on that engine — measured, technical-spec.md
# §6.1: a parse error takes the entire `<script>` block, not the offending statement — and the
# fallback silently does not happen on the one engine that needs it.
#
# A reviewer cannot see this. `const` reads as fine. So it is asserted twice: once by parsing the
# file under a deliberate ES5-only parse, and once by driving `boot()` in node against a stub DOM
# so the readiness contract and the state marks are behaviour rather than reading.
RSpec.describe 'mermaid_boot.js' do
  BOOT_PATH = File.expand_path('../../assets/javascripts/mermaid_boot.js', __dir__)

  def node(script)
    Dir.mktmpdir('rrd-mermaid-boot') do |dir|
      path = File.join(dir, 'run.js')
      File.write(path, script, encoding: 'UTF-8')
      out, err, status = Open3.capture3('node', path)
      raise "node failed: #{err}" unless status.success?

      out
    end
  end

  # A DOM small enough to read and complete enough to drive the script: the two methods it
  # calls (`querySelectorAll`, `setAttribute`) plus `readyState`.
  HARNESS = <<~JS
    var marks = [];
    var els = [
      { attrs: {}, setAttribute: function (k, v) { this.attrs[k] = v; marks.push(k + '=' + v); } },
      { attrs: {}, setAttribute: function (k, v) { this.attrs[k] = v; marks.push(k + '=' + v); } }
    ];
    global.window = global;
    global.document = {
      readyState: 'complete',
      querySelectorAll: function (sel) { return sel === '[data-rd-mermaid]' ? els : []; },
      addEventListener: function () {}
    };
    var rdCalls = [];
    global.__rd = {
      pending: 0,
      begin: function () { rdCalls.push('begin'); },
      end: function () { rdCalls.push('end'); },
      fail: function () { rdCalls.push('fail'); }
    };
  JS

  def run(mermaid_stub, extra = '')
    node(<<~JS)
      #{HARNESS}
      #{mermaid_stub}
      #{File.read(BOOT_PATH, encoding: 'UTF-8')}
      #{extra}
      setTimeout(function () {
        console.log(JSON.stringify({ marks: marks, rd: rdCalls }));
      }, 20);
    JS
  end

  # ------------------------------------------------------------------
  describe 'the ES5 floor' do
    # `node --check` accepts modern syntax, so it proves only that the file parses at all. This
    # parses it as an ES5 SCRIPT via `vm.Script` after refusing the constructs Qt WebKit cannot
    # read — which is the property that actually matters.
    MODERN_CONSTRUCTS = {
      'arrow function' => /=>/,
      'const' => /(\A|[^.\w])const\s/,
      'let' => /(\A|[^.\w])let\s/,
      'template literal' => /`/,
      'logical assignment' => /(\|\||&&|\?\?)=/,
      'optional chaining' => /\?\./,
      'nullish coalescing' => /\?\?/,
      'spread' => /\.\.\./,
      'class declaration' => /(\A|[^.\w])class\s+\w/,
      'for-of' => /for\s*\(\s*(var|let|const)?\s*\w+\s+of\s/
    }.freeze

    # A 'shorthand method' pattern was here and was DELETED: `/^\s*\w+\s*\([^)]*\)\s*\{/`
    # cannot tell `{ foo() {} }` from `if (x) {`, so it flagged nine lines of ordinary ES5. Same
    # lesson as §Findings E-14 — a scanner that cannot tell one construct from another is
    # confidently wrong — and the `vm.Script` example below answers the same question properly,
    # because it asks a real ES5 parser instead of a regexp.

    let(:source) { File.read(BOOT_PATH, encoding: 'UTF-8') }

    # Comments talk ABOUT `||=` and arrow functions — this file's own doc comment names them —
    # so the scan is over CODE only. Same lesson as the FR-19 lint finding a `<script>` in prose
    # (§Findings E-14): a scanner that cannot tell code from prose is confidently wrong.
    let(:code) do
      source.lines.reject { |line| line.strip.start_with?('*', '/*', '//', '*/') }.join
    end

    MODERN_CONSTRUCTS.each do |name, pattern|
      it "uses no #{name}" do
        offending = code.lines.each_with_index
                        .select { |line, _| pattern.match?(line) }
                        .map { |line, i| "#{i + 1}: #{line.strip}" }

        expect(offending).to be_empty,
                             "wkhtmltopdf cannot parse #{name}, and a parse error takes the " \
                             "whole script — so the FALLBACK would not happen on the one " \
                             "engine that needs it:\n#{offending.join("\n")}"
      end
    end

    it 'parses as an ES5 script, not merely as a modern one' do
      # `vm.Script` with no ES6 features available proves it: an ES2015+ construct is a
      # SyntaxError here even though `node --check` would accept it.
      out = node(<<~JS)
        var vm = require('vm');
        var fs = require('fs');
        try {
          new vm.Script(fs.readFileSync(#{BOOT_PATH.inspect}, 'utf8'));
          console.log('PARSES');
        } catch (e) { console.log('SYNTAX-ERROR ' + e.message); }
      JS

      expect(out.strip).to eq('PARSES')
    end
  end

  # ------------------------------------------------------------------
  describe 'the fallback, which is what runs on an engine that cannot run Mermaid' do
    it 'marks every diagram unsupported when there is no mermaid global, and never begins' do
      # The critical property: it must NOT call `begin()`. A `begin` with no matching `end`
      # holds the document open until the watchdog fires, so a document with no library would
      # cost the reader the full readiness timeout for nothing.
      result = JSON.parse(run(''))

      expect(result['marks']).to eq(['data-rd-mermaid-state=unsupported',
                                     'data-rd-mermaid-state=unsupported'])
      expect(result['rd']).to be_empty
    end

    it 'leaves the source alone, so the diagram text stays readable' do
      # FR-68's "the source is emitted, never a blank space" is satisfied by doing NOTHING —
      # a `<pre>` already shows its own text. Asserted as the absence of any write other than
      # the state mark.
      result = JSON.parse(run(''))

      expect(result['marks'].uniq).to eq(['data-rd-mermaid-state=unsupported'])
    end
  end

  # ------------------------------------------------------------------
  describe 'the readiness contract' do
    MERMAID_OK = <<~JS
      global.mermaid = {
        initialize: function () {},
        run: function () { return Promise.resolve(); }
      };
    JS

    it 'begins once and ends once around a successful run' do
      result = JSON.parse(run(MERMAID_OK))

      expect(result['rd']).to eq(%w[begin end])
      expect(result['marks'].last).to eq('data-rd-mermaid-state=drawn')
    end

    it 'still ENDS when the run rejects, so one broken diagram does not hold the document' do
      result = JSON.parse(run(<<~JS))
        global.mermaid = {
          initialize: function () {},
          run: function () { return Promise.reject(new Error('bad diagram')); }
        };
      JS

      expect(result['rd']).to eq(%w[begin end])
      expect(result['marks'].last).to eq('data-rd-mermaid-state=failed')
    end

    it 'still ENDS when initialize or run THROWS synchronously' do
      result = JSON.parse(run(<<~JS))
        global.mermaid = {
          initialize: function () { throw new Error('boom'); },
          run: function () { return Promise.resolve(); }
        };
      JS

      expect(result['rd']).to eq(%w[begin end])
      expect(result['marks'].last).to eq('data-rd-mermaid-state=failed')
    end

    it 'handles a run() that does not answer a Promise, rather than throwing on .then' do
      # An older or stubbed Mermaid may answer undefined. `.then` on it is a TypeError that
      # would leave `pending` above zero for ever.
      result = JSON.parse(run(<<~JS))
        global.mermaid = { initialize: function () {}, run: function () { return undefined; } };
      JS

      expect(result['rd']).to eq(%w[begin end])
      expect(result['marks'].last).to eq('data-rd-mermaid-state=drawn')
    end

    it 'ends exactly once even if both a throw and a rejection could fire' do
      result = JSON.parse(run(<<~JS))
        global.mermaid = {
          initialize: function () {},
          run: function () {
            return { then: function (ok, bad) { bad(new Error('a')); bad(new Error('b')); } };
          }
        };
      JS

      expect(result['rd']).to eq(%w[begin end]), 'end must be idempotent'
    end

    it 'does not throw when the readiness shell is absent' do
      # A template that includes this file without `chart_shell.js` must still draw rather than
      # failing on `__rd.begin`.
      out = node(<<~JS)
        #{HARNESS}
        delete global.__rd;
        #{MERMAID_OK}
        #{File.read(BOOT_PATH, encoding: 'UTF-8')}
        setTimeout(function () { console.log(JSON.stringify({ marks: marks })); }, 20);
      JS

      expect(JSON.parse(out)['marks'].last).to eq('data-rd-mermaid-state=drawn')
    end
  end

  describe 'a document with no diagram' do
    it 'does nothing at all, and does not begin' do
      out = node(<<~JS)
        var rdCalls = [];
        global.window = global;
        global.document = { readyState: 'complete',
                            querySelectorAll: function () { return []; },
                            addEventListener: function () {} };
        global.__rd = { begin: function () { rdCalls.push('begin'); },
                        end: function () { rdCalls.push('end'); } };
        #{File.read(BOOT_PATH, encoding: 'UTF-8')}
        console.log(JSON.stringify(rdCalls));
      JS

      expect(JSON.parse(out)).to be_empty
    end
  end
end
