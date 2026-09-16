/*
 * Project dashboard behaviour for redmine_reporter_dashboards.
 *
 * Widget placement is driven entirely by server-side move buttons (POST +
 * redirect), so there is no drag-and-drop or sortable wiring here — only the
 * settings panel toggle needs JavaScript.
 */
(function ($) {
  'use strict';

  function initSettingsToggle() {
    var $settings = $('#reporter-dashboard-settings');
    if (!$settings.length) {
      return;
    }

    $('#reporter-dashboard-settings-toggle').on('click', function (event) {
      event.preventDefault();
      $settings.toggle();
    });

    $('.reporter-dashboard-settings-cancel').on('click', function (event) {
      event.preventDefault();
      $settings.toggle();
    });

    if (window.location.hash === '#reporter-dashboard-settings') {
      $settings.show();
    }
  }

  // T-44, §Findings M-5 — THE PARENT HALF OF THE FRAME'S OWN MEASUREMENT.
  //
  // The document inside `iframe.reporter-report-frame` posts its content height; this sets
  // it. Everything that makes it safe is here rather than in a comment:
  //
  //   * THE SENDER IS AUTHENTICATED BY OBJECT IDENTITY, not by origin. The frame has no
  //     `allow-same-origin`, so its origin is the string "null" and EVERY sandboxed frame
  //     on the page shares it — an origin check would let any one of them resize any other.
  //     `event.source === frame.contentWindow` is the only identification that means
  //     anything here, and it is why the frames are re-queried per message rather than
  //     captured once: a widget saved over AJAX inserts a new frame after page load.
  //   * THE VALUE IS TYPED AND BOUNDED. A finite positive number, ceilinged, and clamped
  //     to MAX_HEIGHT — a frame is a box on somebody's dashboard, not a scrollbar the
  //     report gets to control.
  //   * NOTHING IS READ ACROSS THE BOUNDARY. The parent never touches
  //     `contentWindow.document`; that is what it cannot do, and it does not need to.
  //   * THE NUMBER OF WRITES PER FRAME IS BOUNDED. See MAX_WRITES.
  //
  // `min-height` is cleared on the element at the same time, because the CSS floor is the
  // no-message fallback and a measured frame must be able to SHRINK below it. With scripts
  // off, or if no message ever arrives, the stylesheet answers exactly as it did before.
  var MAX_HEIGHT = 20000;

  // THE CONVERGENCE BOUND, AND THE CLAMP ABOVE IS NOT ONE.
  //
  // This is a feedback loop by construction: the child observes `document.body` and posts
  // when it resizes, the parent writes the value to the frame's height, and writing the
  // height changes the child's viewport — which can change `body.scrollHeight` again. The
  // child's `last` memo damps a value that repeats, and a memo of one step does not damp a
  // CYCLE. Two media queries in a report's own CSS produce one:
  //
  //     @media (max-height: 500px) { .x { height: 2000px } }
  //     @media (min-height: 501px) { .x { height:  100px } }
  //
  // 2000 → 100 → 2000 → …, neither value equal to the one before it, at ResizeObserver
  // frequency, on every viewer's machine, for as long as the dashboard is open. MAX_HEIGHT
  // bounds the VALUE and does nothing about the RATE — it only terminates the case that
  // grows monotonically. Found by an independent review; the T-44 spec tested hostile
  // VALUES and not a hostile SEQUENCE, which is the shape a live layout actually produces.
  //
  // So each frame gets a budget. Twenty is far more than any convergent document needs —
  // the three surfaces this was measured on settle in one write, and a late web font or a
  // chart drawing after load costs one more — and a document that has not settled in twenty
  // is not going to. The budget is spent only by a write that CHANGES something, so a frame
  // re-answering the parent's request with the height it already has costs nothing.
  //
  // The counter lives on the element rather than in a `Map` keyed by frame, because a frame
  // removed from the DOM has to take its counter with it, and because `Map` is not ES5.
  var MAX_WRITES = 20;
  var WRITES_ATTRIBUTE = 'data-rrd-height-writes';

  // INCLUDED FROM MORE THAN ONE PLACE, SO IT GUARDS ITSELF. The project dashboard puts this
  // file in `header_tags`; a my-page block cannot — its partial renders inside `#content`,
  // long after the head has been emitted — so it includes the same file in body position,
  // and a page with three report widgets would otherwise install three listeners. One file,
  // three call sites, one listener. (A second listener would not be a bug so much as three
  // identical writes per message; the flag is cheaper than the explanation.)
  function reportFrames() {
    return document.querySelectorAll('iframe.reporter-report-frame');
  }

  // Ask every frame for its height. Needed because the ordering cannot be relied on: a
  // frame can load and post before this listener exists, and on `/my/page` it always does —
  // the parent script is included in body position there, after the block that carries the
  // frame. The frames answer this on `message`; see `ReportFrame::AUTO_HEIGHT_SCRIPT`.
  function requestHeights() {
    var frames = reportFrames();
    for (var index = 0; index < frames.length; index += 1) {
      if (frames[index].contentWindow) {
        frames[index].contentWindow.postMessage({ rrdFrameHeightRequest: true }, '*');
      }
    }
  }

  // One write, budgeted. Separate from the listener so the budget is visible beside the
  // thing it bounds rather than buried in a loop.
  function applyHeight(frame, height) {
    var wanted = Math.min(Math.ceil(height), MAX_HEIGHT) + 'px';
    if (frame.style.height === wanted) {
      return;
    }

    var writes = parseInt(frame.getAttribute(WRITES_ATTRIBUTE), 10) || 0;
    if (writes >= MAX_WRITES) {
      return;
    }
    frame.setAttribute(WRITES_ATTRIBUTE, writes + 1);

    frame.style.minHeight = '0';
    frame.style.height = wanted;
  }

  function initReportFrameAutoHeight() {
    if (!window.addEventListener || window.rrdFrameAutoHeightReady) {
      return;
    }
    window.rrdFrameAutoHeightReady = true;

    window.addEventListener('message', function (event) {
      var data = event.data;
      if (!data || typeof data !== 'object') {
        return;
      }

      var height = data.rrdFrameHeight;
      if (typeof height !== 'number' || !isFinite(height) || height <= 0) {
        return;
      }

      var frames = reportFrames();
      for (var index = 0; index < frames.length; index += 1) {
        if (frames[index].contentWindow === event.source) {
          applyHeight(frames[index], height);
          return;
        }
      }
    });
  }

  // THE LISTENER IS INSTALLED AT PARSE TIME, not on ready. Waiting for ready is what made
  // the first version lose the dashboard's message about half the time: the frame's own
  // document finishes first often enough for it to be a coin toss, and a lost message is a
  // frame stuck at its CSS floor with nothing in any log.
  initReportFrameAutoHeight();

  $(document).ready(function () {
    initSettingsToggle();
    requestHeights();
  });

  // And once more after everything has loaded: a frame inserted by the settings form's AJAX
  // save has no message of its own that this page has heard.
  $(window).on('load', requestHeights);
}(jQuery));
