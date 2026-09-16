/*
 * The readiness contract — ONE DOM protocol, three signals, emitted by this shell and
 * never by a template author.
 *
 * WHAT THIS REPLACES. Every example template today hand-rolls a `geoChartBegin` /
 * `geoChartEnd` / `__geoChartsPending` handshake and sets `window.status`, and NOTHING
 * READS IT: the PDF path uses a flat `javascript_delay: 3000` with the engine's runaway
 * guard switched off. So the handshake is dead code, the delay is a guess, and the guard
 * that would have caught a runaway chart is off. A document with three slow charts is
 * cut off at three seconds; a document with none waits three seconds for nothing.
 *
 * THE CONTRACT. `window.__rd`:
 *
 *   pending          how many charts have begun and not finished
 *   ready            true once pending reaches zero (or the watchdog fired)
 *   degraded         array of reasons, e.g. ['client_watchdog']
 *   begin()          a chart started
 *   end()            a chart finished; at zero this signals ready
 *   fail(reason)     a chart gave up; counts as finished and records why
 *
 * THREE SIGNALS for one contract, because the engines read different things:
 *   - `window.__rd.ready`                        Chromium / Gotenberg (JS expression)
 *   - `document.documentElement.dataset.rdReady` any DOM-only engine
 *   - `window.status = 'rd-ready'`               wkhtmltopdf (--window-status)
 * All three are set at the same moment, so no engine needs a different document.
 *
 * BEGIN/END ARE NEVER THE AUTHOR'S JOB. Every chart goes through `{% chart %}`, which
 * emits the begin/end pair around its own draw call. An author who has to remember a
 * handshake will forget it, and the failure mode is a PDF that renders before its charts
 * do — which looks like a slow machine rather than a bug.
 */
(function (global) {
  'use strict';

  var DEFAULT_CLIENT_TIMEOUT_MS = 8000;

  function Readiness(options) {
    var opts = options || {};
    this.pending = 0;
    this.ready = false;
    this.degraded = [];
    this.startedAt = (global.Date && global.Date.now) ? global.Date.now() : 0;
    this.clientTimeoutMs = opts.clientTimeoutMs || DEFAULT_CLIENT_TIMEOUT_MS;
    this._document = opts.document || global.document;
    this._armWatchdog(opts);
  }

  // A chart started. Beginning after the document already went ready REOPENS it: a
  // late-arriving chart that silently drew into a finished document is exactly the
  // race the flat delay used to hide.
  Readiness.prototype.begin = function begin() {
    this.pending += 1;
    if (this.ready) {
      this.ready = false;
      this._clearSignals();
    }
    return this.pending;
  };

  Readiness.prototype.end = function end() {
    if (this.pending > 0) {
      this.pending -= 1;
    }
    if (this.pending === 0) {
      this._signalReady();
    }
    return this.pending;
  };

  // A chart that gave up still FINISHES. Not calling end() on failure is how one broken
  // chart holds the whole document open until the timeout — the reader then waits, and
  // gets a document missing every chart rather than missing one.
  Readiness.prototype.fail = function fail(reason) {
    this.degraded.push(String(reason || 'chart_failed'));
    return this.end();
  };

  // THE CHART-FREE CASE, and it is not an afterthought — it is the first of T-11's
  // three falsifying fixtures ("0 charts, under a second"). Without this, a document
  // with no charts never calls end(), never reaches zero from above zero, and waits out
  // the watchdog: a page with nothing to draw would be the SLOWEST one to render. So
  // once the document has finished parsing, no chart has begun and none is pending, the
  // document is ready immediately.
  //
  // Called again later it is harmless: begin() reopens readiness, so a chart registered
  // after settle() still holds the document open.
  Readiness.prototype.settle = function settle() {
    if (!this.ready && this.pending === 0) {
      this._signalReady();
    }
    return this.ready;
  };

  Readiness.prototype.elapsedMs = function elapsedMs() {
    if (!(global.Date && global.Date.now)) { return 0; }
    return global.Date.now() - this.startedAt;
  };

  // The IN-PAGE watchdog. The engine has its own timeout, and this one is deliberately
  // shorter: if the page declares itself ready the engine gets a clean signal and a
  // recorded degradation, whereas if only the engine times out all it knows is that
  // nothing ever answered. A page that can explain why it gave up is worth more than
  // one that is cut off.
  Readiness.prototype._armWatchdog = function _armWatchdog(opts) {
    var self = this;
    var timer = opts.setTimeout || global.setTimeout;
    if (!timer) { return; }
    this._watchdog = timer(function () {
      if (self.ready) { return; }
      self.degraded.push('client_watchdog');
      self._signalReady();
    }, this.clientTimeoutMs);
  };

  Readiness.prototype._signalReady = function _signalReady() {
    this.ready = true;
    var doc = this._document;
    if (doc && doc.documentElement) {
      if (doc.documentElement.dataset) {
        doc.documentElement.dataset.rdReady = '1';
      } else if (doc.documentElement.setAttribute) {
        doc.documentElement.setAttribute('data-rd-ready', '1');
      }
    }
    try {
      global.status = 'rd-ready';
    } catch (e) {
      /* window.status is read-only in some engines; the other two signals still stand. */
    }
  };

  Readiness.prototype._clearSignals = function _clearSignals() {
    var doc = this._document;
    if (doc && doc.documentElement && doc.documentElement.removeAttribute) {
      doc.documentElement.removeAttribute('data-rd-ready');
    }
    try {
      global.status = '';
    } catch (e) {
      /* as above */
    }
  };

  global.__rd = global.__rd || new Readiness(global.__rdOptions || {});
  global.__rdReadiness = Readiness;

  // Settle when parsing is done. Every `{% chart %}` emits its begin() inline, so by the
  // time this fires each chart on the page has already registered — which is what makes
  // "pending === 0 means nothing to wait for" true rather than merely likely.
  (function armSettle(rd, doc) {
    if (!doc || !doc.addEventListener) { return; }
    if (doc.readyState === 'complete' || doc.readyState === 'interactive') {
      rd.settle();
      return;
    }
    doc.addEventListener('DOMContentLoaded', function () { rd.settle(); });
  }(global.__rd, global.document));
}(typeof window !== 'undefined' ? window : globalThis));
