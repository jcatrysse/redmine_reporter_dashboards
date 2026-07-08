# Changelog

All notable changes to this plugin are documented in this file.

## [0.4.0] - 2026-07-08

- Harden the version status dashboard example against injection: version names are
  HTML-escaped in the card title and stripped of angle brackets before going into
  the Chart.js label arrays (defence in depth; names are manager-controlled).
- Add the `{% version_rollup %}` Liquid tag: aggregates a report's issues per
  target version entirely in SQL (counts, estimated/spent hours, MIN start / MAX
  due dates, and summed numeric custom fields such as cost) and returns one
  ready-to-render row per version. Replaces the `O(versions × issues)` Liquid
  double loop that made per-version dashboards slow on large issue sets. Cost
  sums mirror Redmine's own numeric custom-field totalling, so they are correct
  on PostgreSQL and MySQL. Scope resolution is now shared with `{% sql_aggregate %}`
  (extracted to `SqlAggregation::ScopeResolution`). `examples/version_status_dashboard.liquid`
  now builds on this tag and no longer iterates issues in Liquid.
- Add `VersionDrop#project_name` (alongside `project_identifier`).

- ## [0.3.0] - 2026-07-07 

- Expose `issue.custom_field_value` on the Reporter issue drop: a by-**id**
  accessor for **any** custom field, e.g. `{{ issue.custom_field_value[20] }}`
  (the id may be an integer, string, or Liquid variable). Complements Reporter's
  by-name `custom_field` filter and is stable across field renames/translations.
  Returns the raw stored value (`nil` when unset) via `Issue#custom_field_value`;
  added through the same prepend as `issue.target_version`, so no Reporter file
  is edited.

## [0.2.0] - 2026-07-04

- When PDF generation fails, log the error class, the wkhtmltopdf exe path and
  the first backtrace line, so a non-runnable binary (missing shared libs) can be
  told apart from a rendering error.
- Expose `issue.target_version` on the Reporter issue drop: a `VersionDrop`
  wrapping the issue's target version with `id`, `name`, `description`,
  `effective_date`, `status`, `completed_percent`, `project_identifier`, and
  **absolute** `url` / `roadmap_url` / `issues_url` / `open_issues_url` /
  `closed_issues_url` / `time_url` (built from the Redmine host settings so links
  survive wkhtmltopdf PDF export). Added via a prepend on Reporter's issue drop,
  so no Reporter file is edited.
- Add an "Export as PDF" link to report widgets, generating the report for the
  widget's configured query via the Reporter plugin's own PDF pipeline.
- Make JavaScript charts (e.g. Chart.js) render in **all** Reporter PDFs
  (dashboard export, Reporter's own preview/export, scheduled reports): when a
  report contains a chart (a <canvas>), inject ES2015 polyfills for wkhtmltopdf's
  old WebKit and add a bounded delay so asynchronously-loaded chart scripts finish
  before capture. Chart-less reports are unaffected (no delay). Previously the
  canvas came out empty while the HTML/CSS around it rendered.
- Report widgets now resize their embedded frame as asynchronous content
  (charts, images, fonts) renders, so large reports are no longer cut off.
- Replace dashboard widget drag-and-drop with a flexible **rows** layout driven
  by up/down/left/right move buttons. Widgets can now be stacked one per line or
  placed several per line in any arrangement, without the fiddly jQuery-UI
  sortable. Existing dashboards are migrated to the new format automatically on
  first read.
- Add the `{% geo_version_map %}` Liquid tag: builds a version-name → id/metadata
  lookup so report templates can construct version-filtered URLs (roadmap,
  issues list, time entries) from the Reporter issue drop, which only exposes
  `issue.version` as a scalar name.

## [0.1.0] - 2026-05-31

- Initial release.
