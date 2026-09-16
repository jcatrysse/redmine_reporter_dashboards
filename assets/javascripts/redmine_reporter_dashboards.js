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
  //
  // `min-height` is cleared on the element at the same time, because the CSS floor is the
  // no-message fallback and a measured frame must be able to SHRINK below it. With scripts
  // off, or if no message ever arrives, the stylesheet answers exactly as it did before.
  var MAX_HEIGHT = 20000;

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
          frames[index].style.minHeight = '0';
          frames[index].style.height = Math.min(Math.ceil(height), MAX_HEIGHT) + 'px';
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
