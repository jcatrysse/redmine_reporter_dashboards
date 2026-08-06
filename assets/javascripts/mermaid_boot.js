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

    var finished = false;
    function finish(state) {
      if (finished) { return; }
      finished = true;
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
