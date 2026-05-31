/*
 * Project dashboard behaviour for redmine_reporter_dashboards.
 *
 * Extracted from the inline <script> blocks that previously lived in
 * reporter_project_pages/show.html.erb. The per-request order URL is passed
 * through the data-reporter-order-url attribute on #reporter-project-page,
 * which is only present when the current user may manage the page.
 */
(function ($) {
  'use strict';

  function initBlockSortable() {
    var $page = $('#reporter-project-page');
    var orderUrl = $page.data('reporter-order-url');
    if (!$page.length || !orderUrl) {
      return; // not editable — no drag and drop
    }

    $('#reporter-block-select').val('');

    $('.block-receiver').sortable({
      connectWith: '.block-receiver',
      tolerance: 'pointer',
      handle: '.sort-handle',
      start: function (event, ui) {
        $page.addClass('reporter-dragging');
        $('.reporter-column-collapsible').removeClass('reporter-column-collapsed');
      },
      stop: function (event, ui) {
        $page.removeClass('reporter-dragging');
        $('.reporter-column-collapsible').each(function () {
          var $column = $(this);
          if ($column.children('.mypage-box').length === 0) {
            $column.addClass('reporter-column-collapsed');
          }
        });
      },
      update: function (event, ui) {
        if ($(this).find(ui.item).length > 0) {
          // Collect only children whose id starts with "reporter-block-".
          var blockIds = $.map($(this).children('[id^="reporter-block-"]'), function (el) {
            return $(el).attr('id').replace(/^reporter-block-/, '');
          });

          $.ajax({
            url: orderUrl,
            type: 'post',
            data: {
              'group': $(this).attr('id').replace(/^reporter-list-/, ''),
              'blocks': blockIds
            },
            error: function () {
              // Revert the sortable to the server-side order on failure.
              $('.block-receiver').sortable('cancel');
            }
          });
        }
      }
    });
  }

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
    initBlockSortable();
    initSettingsToggle();
  });
}(jQuery));
