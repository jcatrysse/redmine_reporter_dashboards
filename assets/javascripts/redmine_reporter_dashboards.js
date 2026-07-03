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

  $(document).ready(function () {
    initSettingsToggle();
  });
}(jQuery));
