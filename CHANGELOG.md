# Changelog

Notable changes, newest first. Entries describe what changed for someone using or running
the plugin — the implementation record lives in the git history and in `docs/plan/`.

## [Unreleased]

This release makes the plugin standalone. `redmine_reporter` and the `redmineup` gem are no
longer needed by anything, including the report widgets. It also adds the whole delivery
surface: PDF engines you choose, ad-hoc mail, share links, import/export, and a report
template that can cover spent time.

### Upgrading

- **Breaking: a quoted value in a report tag now means that text and nothing else.** Before,
  `group_by: "status"` and `group_by: status` behaved the same. Now a quoted value is
  literal and an unquoted one is looked up as a Liquid variable first. This matters on
  spent-time reports, where `user` and `project` are also variable names — write those two
  as `group_by: "user"` and `group_by: "project"`. Run
  `rake reporter_dashboards:lint_templates` to find affected templates.
- **`{% geo_version_map %}` is deprecated and is removed in the next minor version.** Use
  `issue.target_version`, which answers the same questions directly. The tag still works and
  logs one deprecation line per process; the linter flags it.
- **Check who can author templates.** Authoring is code execution. **Administration → Render
  preflight** now opens with a table of every role holding an authoring permission. On a
  fresh Redmine, Redmine's own "load the default configuration" step may have given the
  *Manager* role permissions nobody chose.
- **Add a cron entry for the scheduler** if you use scheduled reports, and one for
  `reporter_dashboards:documents:purge` if you use share links. Neither runs by itself.

### Added

- **Report templates cover spent time.** Set a template's source to *Spent time* and the same
  tags report hours instead of issue counts, with eight dimensions from Redmine's own
  spent-time report.
- **PDF engines you choose.** Headless Chromium (the default, no service needed), Gotenberg,
  or wkhtmltopdf for migration. The administration page names what each engine needs and
  cannot do; `docs/engine-support-matrix.md` is generated from CI runs.
- **Reports embed their images and stylesheets** instead of leaving a gap. The default asset
  policy allows no network access at all; two wider policies fetch from hosts you list.
- **`{% chart %}`** — one line per chart. A `<canvas>` on screen, inline SVG in a PDF, from
  one layout calculation, so the two agree. Charts carry drill-through links and are readable
  without being seen.
- **`{% mermaid %}`** — flowcharts, sequence and gantt diagrams from text. Mermaid ships with
  the plugin; a diagram becomes vector graphics in a PDF.
- **Send a report by e-mail, once**, without creating a schedule — with a recipient policy,
  an audit row per send and a per-user rate limit.
- **Share links** — a URL serving a frozen snapshot, with a mandatory expiry, revocation, an
  optional use limit and an access log. Only a digest of the token is stored.
- **Import and export.** A template downloads as a versioned bundle and imports into another
  installation, with a dry run first.
- **A one-document-per-issue report downloads as a zip** when it covers several issues.
- **A failed report can produce a PDF that says so**, clearly labelled, instead of nothing.
- **`rake reporter_dashboards:render:preflight`** renders a real probe document through every
  engine and reads the result back out of the PDF. It catches "the container is healthy but
  every PDF silently loses its assets".
- **Migration from `redmine_reporter` copies your templates across**, with a read-only survey
  first and a drift report afterwards.
- **A permission model in the normal Redmine way**, plus a warning at start-up when another
  plugin registers one of the same permission names.

### Changed

- Report widgets on project dashboards and on *My page* render this plugin's own templates
  through its own render path, and now show **only templates you are allowed to see**. The
  lookup they replaced applied no visibility rule at all.
- This plugin no longer patches `redmine_reporter`. If you still run it, its PDF export
  returns to its own behaviour.
- Reports declare their language as `<html lang="…">`.
- `render:preflight` no longer exits `0` after checking nothing.

### Fixed

- **`group_by: age` reported every issue as `(none)` on MariaDB**, and the total was taken
  from whichever group the server returned last, so an issue could vanish from the count as
  well as from its bucket. PostgreSQL and MySQL were unaffected. A counted axis is now read
  by position rather than by column alias. A *measured* age axis on MariaDB still needs three
  boundaries or fewer.
- The report and preview pages returned a 500 for any render by the compatibility engine.
- The spent-time documentation listed eleven groupings where there are eight.

### Removed

- The prepend into `redmine_reporter`'s issue drop. `issue.target_version` and
  `issue.custom_field_value` are unchanged in spelling and behaviour and now live on this
  plugin's own drop.

## [0.5.0]

### Security

- **The `/sql_stats` endpoint leaked issues the viewer could not see.** It aggregated over
  every issue in the project rather than the visible ones, so a user could read totals,
  statuses and a time series covering private issues and hidden trackers. It now aggregates
  over the viewer's visible scope.
- **`query_id:` could aggregate through somebody else's private query.** No issue data
  leaked, but the query's existence did. The lookup now goes through the viewer's visible
  queries.
- **`{% geo_version_map %}` read versions and project identifiers from invisible projects.**
  It now resolves both through the viewer's visible scope; an invisible project is
  indistinguishable from a missing one.
- **Dashboard widget settings were stored as posted.** Nothing checked keys or values, and
  the column is deserialized on every dashboard render, so a user who could manage a
  dashboard could persist unbounded data into it. Settings are now typed and bounded, and an
  over-limit value is dropped with one line in the log.

### Added

- Drill-through URLs: `drill: true` turns every bar, slice, point and crosstab cell into a
  link to the issue list, filtered to exactly that element, inheriting the report query's own
  filters, columns, grouping and sort.
- Custom-field, crosstab, period, age, flags and completeness dimensions for
  `{% sql_aggregate %}`, plus `measure:` / `of:` for sums, averages and distinct counts.
- `stats.open_at_end` — the backlog height per period, which a template cannot compute
  itself.
- `{% version_rollup %}` gained cost fields and per-version flag counts.

### Fixed

- Dashboard issue widgets reported the number of rows rendered rather than the number the
  query matches.

## [0.4.1] - 2026-07-31

- Fix the issue count next to a dashboard issue widget's title: it showed the
  number of rows rendered, so a widget limited to 25 items read "(25)" even when
  the query matched 43 issues. It now reports the number of issues the query
  matches (`IssueQuery#issue_count`), like Redmine's own My page widget and like
  the per-group badges inside the widget already did. Affects all five issue
  widgets (assigned to me, reported by me, updated by me, watched, custom query).

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

## [0.3.0] - 2026-07-07

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
