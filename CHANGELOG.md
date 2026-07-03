# Changelog

All notable changes to this plugin are documented in this file.

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
