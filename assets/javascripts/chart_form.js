/*
 * T-37 / FR-73 — the chart form. It writes ONE LINE OF LIQUID into the editor's textarea and
 * then has no further opinion: no hidden field, nothing stored, and the template the author
 * saves is the template they can read, diff and export (§9b.1 clause 4 — "Rejected: a GUI
 * report builder storing structured JSON").
 *
 * --- ES5, AND THAT IS LOAD-BEARING FOR THE SAME REASON `mermaid_boot.js` IS ---
 *
 * `assets/javascripts/` is served to the AUTHORING CHROME here rather than to a report, so
 * this file never meets wkhtmltopdf's 2011 WebKit. It is still written in ES5, because the
 * three scripts in this directory are read together and one of them dies at PARSE TIME on a
 * single arrow function — a difference that is invisible until it is fatal. One dialect for
 * the directory; `spec/chart_form_js_spec.rb` parses this file the way T-35's does.
 *
 * --- IT REVEALS ITS OWN FIELDSET, WHICH IS THE JS-OFF ANSWER ---
 *
 * The fieldset ships with `hidden`. With no JavaScript the feature is ABSENT rather than a
 * button that does nothing, because a dead control tells an author the plugin is broken
 * instead of telling them a convenience is unavailable. The editor itself is a plain
 * `<textarea>` and needs none of this.
 */
(function () {
  'use strict';

  var FORM = 'reporter-chart-form';
  var TEXTAREA = 'template_content';

  // The parameters `{% chart %}` really accepts, in the order the README documents them.
  // `id` and `from` are always written; the rest only when the author filled them in, so the
  // tag that lands in the template is the shortest one that says what they asked for — an
  // author reading `{% chart id: c1, from: stats %}` learns the two things that matter, and
  // one carrying six defaulted parameters teaches them that this is complicated.
  var FIELDS = [
    { param: 'id', id: 'rrd-chart-id', always: true },
    { param: 'from', id: 'rrd-chart-from', always: true },
    { param: 'type', id: 'rrd-chart-type', skipIf: 'bar' },
    { param: 'orientation', id: 'rrd-chart-orientation', skipIf: 'vertical' },
    // QUOTED, ALL FOUR, and `y` is the one that proves it has to be: the tag's own parameter
    // reader accepts a bare value as `[^\s,]+`, so `y: created,closed` ends at the comma and
    // the second key becomes a parameter named `closed`. A quoted value is stripped of its
    // quotes and looked up in the context, misses, and falls back to the literal — which is
    // exactly what a key name should do.
    { param: 'x', id: 'rrd-chart-x', quote: true },
    { param: 'y', id: 'rrd-chart-y', quote: true },
    { param: 'series_label', id: 'rrd-chart-series', quote: true },
    { param: 'title', id: 'rrd-chart-title', quote: true }
  ];

  function value(id) {
    var el = document.getElementById(id);
    if (!el) { return ''; }
    return String(el.value == null ? '' : el.value).replace(/^\s+|\s+$/g, '');
  }

  // A tag parameter is `key: value` or `key: "value"`. Only the free-text ones are quoted,
  // and the quoting is not decoration: a title with a space in it is otherwise read as the
  // next parameter, and one containing a `"` or a `%}` would end the tag early. Both are
  // REMOVED rather than escaped — the tag's own parameter reader has no escape syntax, so
  // there is nothing to escape TO, and silently dropping two characters from a chart title is
  // better than writing a template that will not parse.
  function quoted(text) {
    return '"' + text.replace(/["%{}]/g, '') + '"';
  }

  function bare(text) {
    return text.replace(/[\s,"%{}]/g, '');
  }

  function tag() {
    var parts = [];
    var i;
    var field;
    var raw;

    for (i = 0; i < FIELDS.length; i += 1) {
      field = FIELDS[i];
      raw = value(field.id);
      if (!raw) { continue; }
      if (field.skipIf && raw === field.skipIf) { continue; }
      parts.push(field.param + ': ' + (field.quote ? quoted(raw) : bare(raw)));
    }

    // `id` is the one parameter the tag REFUSES to render without, so an empty box gets a
    // usable default rather than a template that degrades. `chart` is what the tag itself
    // falls back to for its placeholder.
    if (!value('rrd-chart-id')) { parts.unshift('id: chart'); }

    return '{% chart ' + parts.join(', ') + ' %}';
  }

  // AT THE CARET, and the two lines around it are the point: a tag inserted flush against the
  // author's previous line changes what that line means, and a `{% chart %}` inside a
  // paragraph is not what anybody asked for.
  function insert(textarea, text) {
    var start = textarea.selectionStart;
    var end = textarea.selectionEnd;
    var body = textarea.value;
    var block = '\n' + text + '\n';

    if (typeof start !== 'number' || typeof end !== 'number') {
      textarea.value = body + block;
      return;
    }

    textarea.value = body.slice(0, start) + block + body.slice(end);
    // The caret lands AFTER the inserted tag, so a second insert does not overwrite the
    // first — and `focus()` puts the author back in the editor rather than leaving them in a
    // form they have finished with.
    textarea.selectionStart = start + block.length;
    textarea.selectionEnd = textarea.selectionStart;
    textarea.focus();
  }

  function showPreview() {
    var target = document.querySelector('#rrd-chart-preview code');
    if (target) { target.textContent = tag(); }
  }

  function boot() {
    var form = document.getElementById(FORM);
    var textarea = document.getElementById(TEXTAREA);
    var button = document.getElementById('rrd-chart-insert');
    var i;
    var el;

    // NO TEXTAREA, NO FORM. This script is loaded by the editor's layout and would otherwise
    // reveal a fieldset on a page with nothing to insert into.
    if (!form || !textarea || !button) { return; }

    form.removeAttribute('hidden');

    button.onclick = function () {
      insert(textarea, tag());
      return false;
    };

    // The preview updates as the boxes change, so an author sees the syntax being built
    // rather than only its result. It is also the whole documentation of the tag for somebody
    // who never reads the README.
    for (i = 0; i < FIELDS.length; i += 1) {
      el = document.getElementById(FIELDS[i].id);
      if (!el) { continue; }
      el.onchange = showPreview;
      el.onkeyup = showPreview;
    }
    showPreview();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  // Exported for the node-driven spec, which is the only way to assert what this builds
  // without a browser. Same shape as `mermaid_boot.js`'s export and for the same reason.
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { tag: tag, insert: insert, quoted: quoted, bare: bare, boot: boot };
  }
})();
