/*
 * The Mermaid bootstrap — and the smallest amount of code that can honestly be here.
 *
 * WHAT IT IS FOR. `{% mermaid %}` emits a `<pre class="mermaid" data-rd-mermaid="id">` with
 * the diagram source inside it. This file asks Mermaid to replace that source with an SVG,
 * inside the readiness contract so the PDF path waits for it. That is all. There is no
 * `MermaidSpec`, no collector and no per-diagram plumbing, because Mermaid computes its own
 * layout — the reason `{% chart %}` needs all three is that the PLUGIN computes a chart's
 * layout and both outputs must agree about it (implementation-plan.md §Findings F-17).
 *
 * --- THIS FILE IS ES5, AND THAT IS LOAD-BEARING RATHER THAN STYLISTIC ---
 *
 * One arrow function here and the whole file dies at PARSE time on wkhtmltopdf — measured,
 * with the discriminator, in technical-spec.md §6.1: that engine cannot parse `x.a ||= 1`,
 * and a parse error takes the entire `<script>` block, not just the offending statement.
 *
 * The consequence is the point: wkhtmltopdf is exactly the engine where the FALLBACK has to
 * work. If this file cannot run there, nothing marks the diagram as undrawn and the reader
 * gets raw `graph LR` text with no indication that anything went wrong. So: `var`, `function`,
 * no template literals, no `const`, no optional chaining, no `Promise` assumed to exist.
 * `spec/` asserts this file parses under an ES5-only parse, because a reviewer cannot see it.
 *
 * --- THE FALLBACK IS THE ABSENCE OF AN ACTION ---
 *
 * A `<pre>` already shows its own text. So when Mermaid is missing or fails, this file does
 * not build anything: it stamps `data-rd-mermaid-state` and stops, and the source the author
 * wrote stays on the page. FR-68's "the source is emitted, never a blank space" is therefore
 * satisfied by doing nothing, which is the most reliable way to satisfy anything.
 *
 * --- NO SANITISER, ON PURPOSE ---
 *
 * An earlier design sanitised Mermaid's SVG against an allowlist. It was dropped: an author
 * may write `<script>` directly (INV-9 — authoring IS code execution), so stripping it from a
 * library's output in the same document is a cost with a security-shaped name. The control
 * that matters is that REDMINE CONTENT entering a document stays escaped, and that lives in
 * the tag (`interpolate:`) and in FR-19's filters, not here. §Findings F-17.
 */
(function (global) {
  'use strict';

  var STATE = 'data-rd-mermaid-state';
  var SELECTOR = '[data-rd-mermaid]';

  // T-38 — the accessibility labels the TAG computed. See `mermaid_tag.rb`: Mermaid draws
  // in the browser, so this is the only place a `<title>`/`<desc>` can be put into its SVG,
  // and F-17 measured that Mermaid emits neither in this configuration.
  var TITLE_ATTR = 'data-rd-mermaid-title';
  var DESC_ATTR = 'data-rd-mermaid-desc';
  var SVG_NS = 'http://www.w3.org/2000/svg';

  // The settings §6.1 keeps as DEFAULTS rather than as a defence. They cost nothing and
  // spare an author from knowing about them; nothing downstream depends on them being
  // honoured, because after F-17 nothing needs to.
  var CONFIG = {
    startOnLoad: false,
    securityLevel: 'strict',
    htmlLabels: false,
    flowchart: { htmlLabels: false }
  };

  function nodes() {
    if (!global.document || !global.document.querySelectorAll) { return []; }
    var found = global.document.querySelectorAll(SELECTOR);
    var out = [];
    for (var i = 0; i < found.length; i += 1) { out.push(found[i]); }
    return out;
  }

  function mark(list, state) {
    for (var i = 0; i < list.length; i += 1) { list[i].setAttribute(STATE, state); }
  }

  // The diagram source, per element, READ BEFORE MERMAID RUNS. Mermaid replaces the
  // `<pre>`'s content with the SVG, so afterwards the source is gone — and the source is
  // what the `<desc>` says, for the reason `mermaid_tag.rb` gives: `A --> B` describes the
  // picture, so it is the diagram's equivalent of the numbers `SvgRenderer` puts in its own
  // `<desc>`.
  function sources(list) {
    var out = [];
    for (var i = 0; i < list.length; i += 1) {
      out.push((list[i].textContent || '').replace(/^\s+|\s+$/g, ''));
    }
    return out;
  }

  // The SVG's own direct child of this name, or null.
  //
  // DIRECT CHILDREN ONLY, and `getElementsByTagName` would have been wrong: it searches
  // DESCENDANTS, so one `<title>` inside one node of a large flowchart would look like the
  // diagram having a name and this would add none.
  function childNamed(svg, name) {
    var kids = svg.childNodes || [];
    for (var i = 0; i < kids.length; i += 1) {
      if (kids[i].nodeName && String(kids[i].nodeName).toLowerCase() === name) { return kids[i]; }
    }
    return null;
  }

  // `<name>text</name>`, inserted before `ref` — or appended when `ref` is null, which is
  // what `insertBefore` does with a null reference in every DOM.
  function insertLabel(svg, name, text, ref) {
    var doc = svg.ownerDocument;
    if (!doc || !doc.createElementNS) { return null; }

    var node = doc.createElementNS(SVG_NS, name);
    node.appendChild(doc.createTextNode(text));
    svg.insertBefore(node, ref || null);
    return node;
  }

  // THE ORDER IS THE ACCESSIBLE NAME, and the first version of this got it wrong in exactly
  // one case. SVG takes a graphic's name from a `<title>` that is the FIRST child, so:
  //
  //   * a missing `<title>` goes at the head;
  //   * a missing `<desc>` goes immediately AFTER the title — not at the head. Inserting it
  //     at the head is correct only while there is no title, and when Mermaid had emitted one
  //     itself (an author's `accTitle:`) it pushed that title into second place and the
  //     diagram lost its name. Caught by the example that plants an existing title.
  //
  // AN EXISTING LABEL WINS, both of them: an author who wrote `accTitle:`/`accDescr:` has
  // said what they want, and overwriting it would make the library's own accessibility
  // feature unreachable through this tag.
  function label(element, source) {
    if (!element.querySelector) { return; }

    var svg = element.querySelector('svg');
    if (!svg) { return; }

    var title = childNamed(svg, 'title');
    var titleText = element.getAttribute(TITLE_ATTR);
    if (!title && titleText) {
      title = insertLabel(svg, 'title', titleText, svg.firstChild);
    }

    if (childNamed(svg, 'desc')) { return; }

    var descText = element.getAttribute(DESC_ATTR) || source;
    if (!descText) { return; }

    insertLabel(svg, 'desc', descText, title ? title.nextSibling : svg.firstChild);
  }

  // A LABEL FAILURE MUST NOT COST THE DIAGRAM. This runs inside `finish`, which is what
  // calls `rd.end()`, so an exception here would hold the document open until the watchdog
  // — the readiness contract paying for an accessibility nicety. Wrapped per element so one
  // odd SVG does not take the rest with it.
  function labelAll(list, texts) {
    for (var i = 0; i < list.length; i += 1) {
      try { label(list[i], texts[i]); } catch (e) { /* the diagram is drawn; the label is not */ }
    }
  }

  // The readiness contract (T-11), reached defensively: `chart_shell.js` normally defines it,
  // but a template that includes this file without the shell must still draw rather than
  // throwing on `__rd.begin`.
  function readiness() {
    var rd = global.__rd;
    if (rd && typeof rd.begin === 'function' && typeof rd.end === 'function') { return rd; }
    return { begin: function () {}, end: function () {}, fail: function () {} };
  }

  function boot() {
    var list = nodes();
    if (list.length === 0) { return; }

    // NO GLOBAL means the library did not load, or the engine could not parse it. Both are
    // the same thing to a reader, and both leave the source visible.
    if (typeof global.mermaid === 'undefined') {
      mark(list, 'unsupported');
      return;
    }

    var rd = readiness();
    rd.begin();
    mark(list, 'pending');

    // Captured here, before `mermaid.run` replaces the elements' content.
    var texts = sources(list);

    var finished = false;
    function finish(state) {
      if (finished) { return; }
      finished = true;
      if (state === 'drawn') { labelAll(list, texts); }
      mark(list, state);
      rd.end();
    }

    try {
      global.mermaid.initialize(CONFIG);
      var result = global.mermaid.run({ querySelector: SELECTOR });
      // Mermaid 11 answers a Promise. An older or stubbed one may not, and a `.then` on a
      // non-Promise is a TypeError that would leave the document open until the watchdog.
      if (result && typeof result.then === 'function') {
        result.then(function () { finish('drawn'); }, function () { finish('failed'); });
      } else {
        finish('drawn');
      }
    } catch (e) {
      // A diagram that throws still counts as FINISHED. One broken diagram must not hold the
      // document open until the watchdog and cost the reader every other diagram — the same
      // rule `chart_boot.js` applies to a chart that throws.
      finish('failed');
    }
  }

  if (global.document && global.document.readyState === 'loading') {
    global.document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  // Exposed for the specs, which drive `boot` directly rather than waiting on a document.
  global.__rdMermaidBoot = boot;
}(typeof window !== 'undefined' ? window : this));
