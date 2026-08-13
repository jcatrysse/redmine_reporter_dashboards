# frozen_string_literal: true

require 'json'
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

# NAMESPACED, because a constant assigned inside `RSpec.describe` is assigned at the FILE's top
# level — `BOOT_PATH` was `Object::BOOT_PATH` for the whole process, which is the trap
# `spec/report_stylesheet_spec.rb` and `spec/reporting/report_run_spec.rb` both carry a header
# about. Pre-existing; fixed while T-38 had the file open.
module MermaidBootSpecSupport
  BOOT_PATH = File.expand_path('../../assets/javascripts/mermaid_boot.js', __dir__)
end

RSpec.describe 'mermaid_boot.js' do
  # A METHOD, so nothing leaks. `MODERN_CONSTRUCTS` below is left as it is: it is this file's
  # own vocabulary rather than a name anything else could want, and moving it is not T-38's.
  def self.boot_path
    MermaidBootSpecSupport::BOOT_PATH
  end

  def boot_path
    MermaidBootSpecSupport::BOOT_PATH
  end

  def node(script)
    Dir.mktmpdir('rrd-mermaid-boot') do |dir|
      path = File.join(dir, 'run.js')
      File.write(path, script, encoding: 'UTF-8')
      out, err, status = Open3.capture3('node', path)
      raise "node failed: #{err}" unless status.success?

      out
    end
  end

  # A DOM small enough to read and complete enough to drive the script: the methods it calls
  # (`querySelectorAll`, `setAttribute`, and — since T-38 — `getAttribute`, `textContent`,
  # `querySelector` and a document that can create SVG nodes) plus `readyState`.
  #
  # THE FAKE SVG IS PART OF THE HARNESS AND NOT PART OF A TEST, because the thing T-38 has
  # to assert is a DOM WRITE: the boot script inserts a `<title>` and a `<desc>` into the SVG
  # Mermaid produced. Asserting that by reading the source would assert nothing — the whole
  # point of driving this file under node is that its behaviour is not visible by reading.
  # `insertBefore` is modelled honestly (position, and `firstChild` moving with it) because
  # the ORDER of those two children is the property that decides whether a screen reader
  # announces a name at all.
  HARNESS = <<~JS
    var marks = [];

    function fakeDoc() {
      return {
        createElementNS: function (ns, name) {
          return {
            ns: ns, nodeName: name, childNodes: [],
            appendChild: function (n) { this.childNodes.push(n); return n; }
          };
        },
        createTextNode: function (t) { return { nodeName: '#text', text: t }; }
      };
    }

    function fakeSvg() {
      var svg = {
        nodeName: 'svg', ownerDocument: fakeDoc(), childNodes: [], firstChild: null,
        insertBefore: function (node, ref) {
          var at = this.childNodes.length;
          if (ref) {
            var found = this.childNodes.indexOf(ref);
            if (found >= 0) { at = found; }
          }
          this.childNodes.splice(at, 0, node);
          this.relink();
          return node;
        },
        // `firstChild` and `nextSibling` are maintained because the script READS both to
        // decide where a label goes. A fake that let them go stale would let a real
        // ordering bug pass — which is what happened to the first version of the script.
        relink: function () {
          for (var i = 0; i < this.childNodes.length; i += 1) {
            this.childNodes[i].nextSibling = this.childNodes[i + 1] || null;
          }
          this.firstChild = this.childNodes[0] || null;
        }
      };
      return svg;
    }

    function makeEl(source) {
      return {
        attrs: { 'data-rd-mermaid-title': 'graph' },
        svg: fakeSvg(),
        textContent: source,
        setAttribute: function (k, v) { this.attrs[k] = v; marks.push(k + '=' + v); },
        getAttribute: function (k) {
          return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null;
        },
        querySelector: function (sel) { return sel === 'svg' ? this.svg : null; }
      };
    }

    var els = [makeEl('graph LR\\n  A --> B'), makeEl('pie title Split')];
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

    // What ended up in each element's SVG, in order, as `name:text`.
    function labels() {
      var out = [];
      for (var i = 0; i < els.length; i += 1) {
        var kids = els[i].svg ? els[i].svg.childNodes : [];
        var one = [];
        for (var k = 0; k < kids.length; k += 1) {
          var text = kids[k].childNodes && kids[k].childNodes[0] ? kids[k].childNodes[0].text : '';
          one.push(kids[k].nodeName + ':' + text);
        }
        out.push(one);
      }
      return out;
    }
  JS

  # `setup` runs BEFORE the boot script and after the harness, so an example can change the
  # DOM the script is about to meet — remove the SVG, plant an existing `<title>`, set a
  # `desc` attribute. `extra` runs after, for the two examples that drive `boot()` again.
  def run(mermaid_stub, extra = '', setup: '')
    node(<<~JS)
      #{HARNESS}
      #{mermaid_stub}
      #{setup}
      #{File.read(boot_path, encoding: 'UTF-8')}
      #{extra}
      setTimeout(function () {
        console.log(JSON.stringify({ marks: marks, rd: rdCalls, labels: labels() }));
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

    let(:source) { File.read(boot_path, encoding: 'UTF-8') }

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
          new vm.Script(fs.readFileSync(#{boot_path.inspect}, 'utf8'));
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
        #{File.read(boot_path, encoding: 'UTF-8')}
        setTimeout(function () { console.log(JSON.stringify({ marks: marks })); }, 20);
      JS

      expect(JSON.parse(out)['marks'].last).to eq('data-rd-mermaid-state=drawn')
    end
  end

  # ------------------------------------------------------------------
  # T-38 — "every SvgRenderer AND MERMAID output carries <title>/<desc>".
  #
  # Mermaid draws in the BROWSER on both bindings (§Findings F-17, measured), so this file is
  # the only place a label can reach its SVG — and F-17 also measured that Mermaid emits
  # neither element in this configuration, so without this a screen reader meets several
  # hundred unlabelled `<path>`s.
  #
  # The TITLE is computed in Ruby (`MermaidTag#diagram_title`) and travels as an attribute;
  # the DESC is the diagram source, read out of the `<pre>` before Mermaid replaces it.
  describe 'the accessibility labels (FR-76)' do
    it 'inserts a <title> and a <desc> into the SVG once the diagram is drawn' do
      result = JSON.parse(run(MERMAID_OK))

      # A REAL newline: the harness's `'graph LR\\n  A --> B'` is inside a Ruby heredoc, so
      # what reaches node is a JS escape and what reaches the DOM is one line break.
      expect(result['labels'].first).to eq(['title:graph', "desc:graph LR\n  A --> B"])
    end

    # TITLE FIRST. An SVG's accessible name comes from a `<title>` that is the FIRST child,
    # so inserting the desc first and the title in front of it is not an implementation
    # detail — the other order produces an SVG with a description and no name.
    it 'puts the <title> before the <desc>, which is what makes it the accessible name' do
      result = JSON.parse(run(MERMAID_OK))

      result['labels'].each do |labels|
        expect(labels.first).to start_with('title:')
        expect(labels.last).to start_with('desc:')
      end
    end

    it 'labels every diagram on the page, not only the first' do
      result = JSON.parse(run(MERMAID_OK))

      expect(result['labels'].length).to eq(2)
      expect(result['labels'].last).to eq(['title:graph', 'desc:pie title Split'])
    end

    it 'prefers an authored desc over the source when the tag emitted one' do
      result = JSON.parse(run(MERMAID_OK, setup: <<~JS))
        els[0].attrs['data-rd-mermaid-desc'] = 'Two states and the transition between them';
      JS

      expect(result['labels'].first)
        .to eq(['title:graph', 'desc:Two states and the transition between them'])
    end

    # AN EXISTING LABEL WINS. An author who wrote `accTitle:` in the diagram source has said
    # what they want and Mermaid has already emitted it; overwriting it would make the
    # library's own accessibility feature unreachable through this tag.
    it 'leaves a <title> Mermaid itself emitted alone' do
      result = JSON.parse(run(MERMAID_OK, setup: <<~JS))
        var own = { nodeName: 'title', childNodes: [{ nodeName: '#text', text: 'accTitle wins' }] };
        els[0].svg.childNodes.push(own);
        els[0].svg.relink();
      JS

      expect(result['labels'].first.first).to eq('title:accTitle wins')
      expect(result['labels'].first.grep(/\Atitle:/).length).to eq(1)
    end

    # DIRECT CHILDREN ONLY. `getElementsByTagName` searches descendants, so one `<title>`
    # inside one node of a flowchart would read as "the diagram has a name" and the diagram
    # would get none. This is the example that tells the two implementations apart.
    it 'is not fooled by a <title> nested inside the diagram\'s own nodes' do
      result = JSON.parse(run(MERMAID_OK, setup: <<~JS))
        var group = { nodeName: 'g', childNodes: [{ nodeName: 'title', childNodes: [] }] };
        els[0].svg.childNodes.push(group);
        els[0].svg.relink();
      JS

      expect(result['labels'].first.first).to eq('title:graph')
    end

    it 'writes no <title> when the tag could not name the diagram' do
      result = JSON.parse(run(MERMAID_OK, setup: <<~JS))
        delete els[0].attrs['data-rd-mermaid-title'];
      JS

      expect(result['labels'].first.grep(/\Atitle:/)).to be_empty
      expect(result['labels'].first.grep(/\Adesc:/).length).to eq(1)
    end

    it 'labels nothing when the diagram was not drawn' do
      # No mermaid global: the source stays visible in the `<pre>`, which IS the accessible
      # content, and there is no SVG to label.
      result = JSON.parse(run(''))

      expect(result['labels']).to eq([[], []])
    end

    # THE READINESS CONTRACT OUTRANKS THE LABEL. `labelAll` runs inside `finish`, which calls
    # `rd.end()`, so an exception in it would hold the document open until the watchdog fires
    # — an accessibility nicety costing the reader the full readiness timeout.
    it 'still ends the readiness contract when labelling throws' do
      result = JSON.parse(run(MERMAID_OK, setup: <<~JS))
        els[0].querySelector = function () { throw new Error('hostile DOM'); };
      JS

      expect(result['rd']).to eq(%w[begin end])
      expect(result['marks'].last).to eq('data-rd-mermaid-state=drawn')
      expect(result['labels'].last).to eq(['title:graph', 'desc:pie title Split'])
    end

    it 'does not throw when the element has no SVG at all' do
      result = JSON.parse(run(MERMAID_OK, setup: <<~JS))
        els[0].querySelector = function () { return null; };
      JS

      expect(result['rd']).to eq(%w[begin end])
      expect(result['labels'].first).to eq([])
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
        #{File.read(boot_path, encoding: 'UTF-8')}
        console.log(JSON.stringify(rdCalls));
      JS

      expect(JSON.parse(out)).to be_empty
    end
  end
end
