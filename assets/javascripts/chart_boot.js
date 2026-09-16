/*
 * The chart bootstrap — the only JavaScript that touches chart data, and it contains no
 * interpolated value at all.
 *
 * WHAT IT IS FOR. `{% chart %}` emits a `<canvas>` and a
 * `<script type="application/json">` block; this file finds the blocks, parses them and
 * builds the charts. That separation is technical-spec.md §6's, and the reason for it is
 * `reference/verification-liquid-js-escaping.md`: as long as a template writes chart data
 * INTO JavaScript, some value ending in a backslash breaks the string it sits in and the
 * whole <script> block dies with a SyntaxError — chart gone, drill links gone, every later
 * statement gone, nothing in any log. Data in a data block cannot do that. There is no
 * JavaScript syntax to break out of, and the five characters that could still end the
 * ELEMENT are escaped server-side by ScriptSafeJson.
 *
 * CHART.JS IS NOT ALLOWED TO AUTO-SCALE. The server computed the axis — min, max, the tick
 * VALUES and the printed tick LABELS — and Chart.js takes those through two callbacks,
 * which cannot travel in JSON. So they are installed here, from arrays in the payload.
 * Left to itself Chart.js picks bounds from the data and a tick count from the canvas
 * size, and the PDF twin of the same chart then disagrees with the screen about what the
 * axis says.
 *
 * READINESS IS NOT THE AUTHOR'S JOB. begin() before the chart is constructed and end()
 * after, both here, so `chart_shell.js`'s contract covers every chart without a template
 * ever mentioning it. A chart that throws still calls fail(), which still counts as
 * finished: one broken chart must not hold the document open until the watchdog and cost
 * the reader every OTHER chart.
 */
(function (global) {
  'use strict';

  var SELECTOR = 'script[type="application/json"][data-rd-chart-config]';

  function readiness() {
    return global.__rd || { begin: function () {}, end: function () {}, fail: function () {} };
  }

  // A payload that does not parse is a bug in this plugin, not in the report. It is
  // reported through fail() so the degradation reaches the render's diagnostics, and the
  // rest of the document still draws.
  function parseConfig(node) {
    try {
      return JSON.parse(node.textContent);
    } catch (e) {
      return null;
    }
  }

  // THE TWO FUNCTIONS JSON CANNOT CARRY.
  //
  // afterBuildTicks replaces whatever Chart.js decided with exactly the server's values;
  // the label callback prints exactly the server's strings, so no locale-dependent number
  // formatting can differ between the browser and the PDF.
  function pinScale(options, axis) {
    if (!options || !options.scales || !axis || !axis.ticks) { return; }
    var scale = options.scales[axis.value_axis];
    if (!scale) { return; }

    var values = axis.ticks;
    var labels = axis.tick_labels || [];

    scale.afterBuildTicks = function (built) {
      built.ticks = values.map(function (value) { return { value: value }; });
    };
    scale.ticks = scale.ticks || {};
    scale.ticks.callback = function (value) {
      var index = values.indexOf(value);
      return index === -1 ? String(value) : labels[index];
    };
  }

  // Drill-through. `getElementsAtEventForMode` is the Chart.js 4 spelling of the
  // `getElementAtEvent` the old examples call — the rename is one of the six items in
  // §6's 2→4 work package, and doing it here means no template carries it.
  //
  // The URL is opened, never evaluated. It arrived as JSON data and it goes into
  // `location`; there is no path from a report's data into code position.
  function attachDrill(chart, canvas, drill) {
    if (!drill) { return; }
    canvas.style.cursor = 'pointer';
    canvas.addEventListener('click', function (event) {
      var hits = chart.getElementsAtEventForMode(event, 'nearest', { intersect: true }, false);
      if (!hits.length) { return; }
      var row = drill[hits[0].datasetIndex];
      var url = row && row[hits[0].index];
      if (url) { global.open(url, '_blank', 'noopener'); }
    });
  }

  function build(node) {
    var rd = readiness();
    var config = parseConfig(node);
    if (!config) { rd.fail('chart_config_unparsable'); return; }

    var frame = node.parentNode;
    var canvas = frame && frame.querySelector('canvas');
    if (!canvas) { rd.fail('chart_canvas_missing'); return; }
    if (!global.Chart) { rd.fail('chart_library_missing'); return; }

    pinScale(config.options, config.axis);

    try {
      var chart = new global.Chart(canvas, {
        type: config.type,
        data: config.data,
        options: config.options
      });
      attachDrill(chart, canvas, config.drill);
      rd.end();
    } catch (e) {
      rd.fail('chart_draw_failed');
    }
  }

  // begin() for EVERY chart before ANY of them is built. Otherwise the first chart's
  // end() takes pending back to zero, the document declares itself ready, and an engine
  // snapshots it while the second chart is still drawing. `chart_shell.js` reopens
  // readiness on a late begin(), so this is belt and braces — but the belt is what stops
  // a two-chart report being a race.
  function boot(doc) {
    var nodes = doc.querySelectorAll(SELECTOR);
    var rd = readiness();
    var index;
    for (index = 0; index < nodes.length; index += 1) { rd.begin(); }
    for (index = 0; index < nodes.length; index += 1) { build(nodes[index]); }
  }

  global.__rdChartBoot = boot;

  if (global.document) {
    if (global.document.readyState === 'loading') {
      global.document.addEventListener('DOMContentLoaded', function () { boot(global.document); });
    } else {
      boot(global.document);
    }
  }
}(typeof window !== 'undefined' ? window : globalThis));
