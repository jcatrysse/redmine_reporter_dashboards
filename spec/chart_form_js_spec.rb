# frozen_string_literal: true

require 'open3'
require 'tmpdir'

require_relative 'spec_helper'

# T-37 / FR-73 — `assets/javascripts/chart_form.js`, driven in node.
#
# The form's whole job is to write ONE LINE OF LIQUID into a textarea, and every property worth
# asserting about it is invisible by reading: whether the line PARSES as a `{% chart %}` tag,
# whether a title with a quote in it can end the tag early, whether a second insert overwrites
# the first, and whether the fieldset stays hidden when there is nothing to insert into.
#
# --- THE ES5 ASSERTION, and it is here for the same reason T-35's is ---
#
# This file never meets wkhtmltopdf — it is authoring chrome, not report output. It is still
# ES5, because `assets/javascripts/` is read as one directory and `mermaid_boot.js` DIES AT
# PARSE TIME on that engine over a single arrow function. One dialect for the directory means a
# reviewer never has to work out which of three files is allowed which syntax.

# NAMESPACED, because a constant assigned inside `RSpec.describe` lands on `Object` — the trap
# HANDOVER §1 records and `spec/charts/mermaid_boot_spec.rb` carries a header about.
module ChartFormSpecSupport
  SCRIPT = File.expand_path('../assets/javascripts/chart_form.js', __dir__)

  # A DOM small enough to read and complete enough to drive the script: the four element kinds
  # it touches, a textarea with a caret, and `readyState`.
  HARNESS = <<~JS
    var elements = {};
    var revealed = [];
    var focused = 0;

    function el(id, value) {
      return {
        id: id, value: value, hidden: false,
        textContent: '',
        removeAttribute: function (name) { if (name === 'hidden') { revealed.push(id); } },
        focus: function () { focused += 1; }
      };
    }

    function textarea(body, start, end) {
      var t = el('template_content', body);
      t.selectionStart = start;
      t.selectionEnd = end === undefined ? start : end;
      return t;
    }

    global.document = {
      readyState: 'complete',
      getElementById: function (id) { return elements[id] || null; },
      querySelector: function (selector) {
        return selector === '#rrd-chart-preview code' ? elements.preview : null;
      },
      addEventListener: function () {}
    };
  JS
end

RSpec.describe 'chart_form.js' do
  def script_path
    ChartFormSpecSupport::SCRIPT
  end

  def node(body)
    Dir.mktmpdir('rrd-chart-form') do |dir|
      path = File.join(dir, 'run.js')
      File.write(path, "#{ChartFormSpecSupport::HARNESS}\n#{body}", encoding: 'UTF-8')
      out, err, status = Open3.capture3('node', path)
      raise "node failed: #{err}" unless status.success?

      out
    end
  end

  # The fields the form offers, as the ids the script reads. Written out rather than derived so
  # that a renamed input is a red example here rather than a silently ignored box.
  def fields(overrides = {})
    defaults = { 'rrd-chart-id' => 'chart1', 'rrd-chart-from' => 'stats',
                 'rrd-chart-type' => 'bar', 'rrd-chart-orientation' => 'vertical',
                 'rrd-chart-x' => '', 'rrd-chart-y' => '', 'rrd-chart-series' => '',
                 'rrd-chart-title' => '' }
    defaults.merge(overrides)
  end

  def build_tag(overrides = {}, body: '', caret: 0)
    assignments = fields(overrides).map { |id, value| "elements['#{id}'] = el('#{id}', #{value.inspect});" }

    node(<<~JS)
      #{assignments.join("\n")}
      elements['reporter-chart-form'] = el('reporter-chart-form', '');
      elements['rrd-chart-insert'] = el('rrd-chart-insert', '');
      elements.preview = el('preview', '');
      elements['template_content'] = textarea(#{body.inspect}, #{caret});
      var form = require(#{script_path.to_json});
      form.boot();
      elements['rrd-chart-insert'].onclick();
      process.stdout.write(JSON.stringify({
        tag: form.tag(),
        body: elements['template_content'].value,
        caret: elements['template_content'].selectionStart,
        preview: elements.preview.textContent,
        revealed: revealed,
        focused: focused
      }));
    JS
  end

  # THE HASH IS BRACED AT EVERY CALL SITE, and it has to be: this method declares keyword
  # parameters, so `result('a' => 1)` is parsed as a keyword argument named "a" and raises
  # `unknown keywords`. The same Ruby trap `spec/liquid/chart_tag_spec.rb` and
  # `Charts::SvgRenderer#element` both carry a note about; six examples here failed on it.
  def result(overrides = {}, body: '', caret: 0)
    require 'json'
    JSON.parse(build_tag(overrides, body: body, caret: caret))
  end

  describe 'the dialect' do
    # An ES5-only parse. `node --check` accepts modern syntax, so the assertion has to be about
    # the CONSTRUCTS rather than about parseability.
    #
    # COMMENTS ARE STRIPPED FIRST. The first version of this example failed on the BACKTICKS in
    # this file's own header comment, which quote a directory name — the same lesson
    # `layer_purity.sh` records about its first run: "a gate that punishes writing down its own
    # rationale teaches people to delete the rationale."
    it 'uses no construct wkhtmltopdf\'s 2011 WebKit cannot parse' do
      source = File.read(script_path, encoding: 'UTF-8')
                   .gsub(%r{/\*.*?\*/}m, '').gsub(%r{^\s*//.*$}, '')

      expect(source).not_to match(/=>/), 'an arrow function'
      expect(source).not_to match(/\bconst\b|\blet\b/), 'a block-scoped declaration'
      expect(source).not_to match(/`/), 'a template literal'
      expect(source).not_to match(/\.\.\./), 'a spread'
      expect(source).not_to match(/\bclass\s+\w/), 'a class'
    end

    it 'parses under node' do
      _out, err, status = Open3.capture3('node', '--check', script_path)

      expect(status.success?).to be(true), err
    end
  end

  describe 'the tag it builds' do
    it 'writes the two parameters a chart always needs' do
      expect(result['tag']).to eq('{% chart id: chart1, from: stats %}')
    end

    # THE SHORTEST TAG THAT SAYS WHAT WAS ASKED. A form that wrote every defaulted parameter
    # would teach an author that this is complicated; `type: bar` and `orientation: vertical`
    # are the tag's own defaults, so writing them says nothing.
    it 'omits a value that is already the tag\'s default' do
      tag = result({ 'rrd-chart-type' => 'bar', 'rrd-chart-orientation' => 'vertical' })['tag']

      expect(tag).not_to include('type:')
      expect(tag).not_to include('orientation:')
    end

    it 'writes a type and an orientation that are not the default' do
      tag = result({ 'rrd-chart-type' => 'pie', 'rrd-chart-orientation' => 'horizontal' })['tag']

      expect(tag).to include('type: pie')
      expect(tag).to include('orientation: horizontal')
    end

    it 'writes the axis keys and the series name when they are filled in' do
      tag = result({ 'rrd-chart-x' => 'label', 'rrd-chart-y' => 'created,closed',
                       'rrd-chart-series' => 'Issues' })['tag']

      expect(tag).to include('x: "label"')
      expect(tag).to include('y: "created,closed"')
      expect(tag).to include('series_label: "Issues"')
    end

    it 'quotes the title, which is the one free-text parameter' do
      expect(result({ 'rrd-chart-title' => 'Issues by status' })['tag'])
        .to include('title: "Issues by status"')
    end

    # THE INJECTION THAT IS NOT AN INJECTION AND IS STILL A BROKEN TEMPLATE. `%}` inside a
    # title ends the tag early, and a `"` ends the quoted value; the tag's parameter reader has
    # no escape syntax, so there is nothing to escape TO. Two characters are dropped, which is
    # better than writing a template that will not parse.
    it 'cannot be made to end the tag early from a title' do
      tag = result({ 'rrd-chart-title' => 'a " and a %} and a {{' })['tag']

      expect(tag).to eq('{% chart id: chart1, from: stats, title: "a  and a  and a " %}')
      expect(tag.scan('%}').length).to eq(1)
    end

    it 'strips whitespace and separators out of a bare parameter' do
      expect(result({ 'rrd-chart-from' => 'by status, x' })['tag']).to include('from: bystatusx')
    end

    # The tag's parameter reader accepts a bare value as `[^\s,]+`, so an unquoted `y` would
    # end at the comma and `closed` would become a parameter of its own. This is the assertion
    # that found it.
    it 'quotes a comma-separated list so it survives the tag\'s own parser' do
      tag = result({ 'rrd-chart-y' => 'created,closed' })['tag']

      expect(tag).to eq('{% chart id: chart1, from: stats, y: "created,closed" %}')
    end

    # `id` is the one parameter the tag REFUSES to render without: with none it raises
    # `a chart needs an id:` and the render degrades. An empty box gets the tag's own fallback
    # rather than producing a template that fails at render time.
    it 'falls back to a usable id when the box is empty' do
      expect(result({ 'rrd-chart-id' => '' })['tag']).to start_with('{% chart id: chart, ')
    end

    it 'shows the tag it would write before anything is inserted' do
      expect(result['preview']).to eq('{% chart id: chart1, from: stats %}')
    end
  end

  describe 'the insertion' do
    it 'puts the tag at the caret, on its own line' do
      inserted = result({}, body: "<p>one</p>\n<p>two</p>", caret: 10)

      expect(inserted['body']).to eq("<p>one</p>\n{% chart id: chart1, from: stats %}\n\n<p>two</p>")
    end

    # A textarea with no `selectionStart` is what a browser gives for an element that has never
    # been focused, and `body.slice(0, undefined)` would silently produce an empty string —
    # losing the author's whole template. The append path is the guard.
    it 'appends to the end when the textarea has no caret' do
      out = node(<<~JS)
        elements['rrd-chart-id'] = el('rrd-chart-id', 'c1');
        elements['rrd-chart-from'] = el('rrd-chart-from', 'stats');
        elements['reporter-chart-form'] = el('reporter-chart-form', '');
        elements['rrd-chart-insert'] = el('rrd-chart-insert', '');
        elements.preview = el('preview', '');
        var t = el('template_content', '<p>keep me</p>');
        elements['template_content'] = t;
        var form = require(#{script_path.to_json});
        elements['rrd-chart-insert'].onclick();
        process.stdout.write(t.value);
      JS

      expect(out).to eq("<p>keep me</p>\n{% chart id: c1, from: stats %}\n")
    end

    # A SECOND INSERT MUST NOT OVERWRITE THE FIRST, which is what happens when the caret is
    # left where it was: the selection still spans the old text and the next insert replaces it.
    it 'leaves the caret after the tag it inserted' do
      inserted = result({}, body: 'x', caret: 1)

      expect(inserted['caret']).to eq(1 + "\n{% chart id: chart1, from: stats %}\n".length)
    end

    it 'puts the author back in the editor' do
      expect(result['focused']).to eq(1)
    end
  end

  describe 'what it does when there is nothing to insert into' do
    # THE FIELDSET STAYS HIDDEN. It ships with `hidden` and this script is what reveals it, so
    # a page with no textarea — or a browser that never ran this file — shows no form at all
    # rather than a button that does nothing.
    # `uniq`, because requiring the file boots it once by itself (its `readyState` branch) and
    # the harness then calls `boot()` explicitly. What matters is WHICH element was revealed and
    # that nothing else was.
    it 'reveals the form only when the editor is on the page' do
      expect(result['revealed'].uniq).to eq(['reporter-chart-form'])
    end

    it 'reveals nothing and raises nothing when the textarea is absent' do
      out = node(<<~JS)
        elements['reporter-chart-form'] = el('reporter-chart-form', '');
        elements['rrd-chart-insert'] = el('rrd-chart-insert', '');
        var form = require(#{script_path.to_json});
        form.boot();
        process.stdout.write(JSON.stringify(revealed));
      JS

      expect(out).to eq('[]')
    end

    it 'reveals nothing when the form itself is absent' do
      out = node(<<~JS)
        elements['template_content'] = textarea('x', 0);
        var form = require(#{script_path.to_json});
        form.boot();
        process.stdout.write(JSON.stringify(revealed));
      JS

      expect(out).to eq('[]')
    end
  end
end
