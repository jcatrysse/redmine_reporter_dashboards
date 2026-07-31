# Changelog

All notable changes to this plugin are documented in this file.

## [0.5.0]

### Security

- The `/sql_stats` JSON endpoint aggregated over `Issue.where(project_id:)`. The
  `:view_issues` check on the project is not the whole story — Redmine also hides
  private issues and, per role, whole trackers — so a user who could see *some*
  issues in a project could read totals, statuses and a time series covering the
  ones they could not. It now aggregates over `Issue.visible(User.current,
  project: project)`; the explicit permission check stays, so a user without
  `:view_issues` still gets 403 rather than an empty 200.
- `query_id:` resolved a saved query with a bare `IssueQuery.find_by(id:)`. Issue
  data never leaked (`base_scope` starts from `Issue.visible`), but a template
  could aggregate through someone else's private query and learn that it exists.
  The lookup now goes through `IssueQuery.visible(User.current)` and logs when it
  skips an invisible query.
- `{% geo_version_map %}` built its map from `Version.all` and resolved `project:`
  with an unscoped `Project.find_by`, so a report template could read version
  names, dates and project identifiers out of projects the viewer cannot see. It
  now uses `Version.visible(User.current)`, resolves the project through
  `Project.visible`, and narrows `shared_versions` the same way. An invisible
  project is indistinguishable from a missing one.

### Changed

- **All issue counts are now per issue, not per joined row.** `aggregate`,
  `monthly_flow` and `breakdown` used a plain `COUNT(*)`; on a scope carrying a
  join that multiplies rows they reported more issues than exist (reproduced:
  4 issues counted as 8). They now count `DISTINCT issues.id`, like the dimension
  code always did. The numbers change only where they were wrong, at the cost of
  a slightly more expensive count on every time series.
- An unsupported database adapter now fails with a clear
  `UnsupportedAdapterError` instead of emitting MySQL date syntax and letting the
  database produce a puzzling error. PostgreSQL and MySQL/MariaDB are recognised;
  anything else (SQLite) is refused. It is a `StandardError`, so the tags still
  degrade to the empty-safe result rather than breaking a dashboard.
- `requires_redmine` is pinned to **5.1**, matching the versions CI actually
  exercises, and the README now carries an explicit support matrix. The plugin
  previously declared 5.0 and the README claimed "5.0 or higher" while only
  5.1/6.0/6.1 on PostgreSQL were tested. Redmine 7.0 and MySQL are documented as
  untested rather than implied to work.

- `{% sql_aggregate %}` (and its `{% geo_aggregate %}` alias) can now aggregate by
  **custom field** and by **two dimensions at once**, entirely in SQL:
  - `group_by: cf_<id>` groups on an issue custom field, resolving stored values to
    their labels through the field's own format (enumeration and
    depending_enumeration fields store the enumeration id, e.g. Department
    "Survey" is stored as `415`), with a real "no value" bucket.
  - `split_by: <dimension>` adds a second dimension and returns a dense
    rows × series crosstab (`series`, `rows`, `matrix`, `columns`) that feeds a
    stacked or grouped Chart.js dataset directly.
  - `group_by: period` makes the time axis a dimension, so "Lesson Type per month"
    is a single call; every period in the window is present, including empty ones.
  - `group_by: age` buckets issues by age (`0-30`, `31-60`, … `>180`) using
    portable SQL — no `DATEDIFF`, no `CURRENT_DATE` arithmetic — on PostgreSQL and
    MySQL alike.
  - `group_by: flags` returns one row of governance scalars (total, open, closed,
    assigned, unassigned, with/without due date, overdue, no estimate, oldest and
    newest open item in days) for KPI tiles and funnel widgets.
  - New parameters: `split_by`, `sort` (`count` / `label` / `position`), `limit`
    with an `Other` remainder, `other_label`, `empty_label`, `date_field`,
    `age_buckets`, `age_field`, `user_label`. Invalid values fall back to the
    default with a logged warning instead of raising.
  - Custom field **visibility is enforced**: the join carries Redmine's own
    `visibility_by_project_condition`, so a role-restricted field does not leak
    its values to a viewer who may not see them (their issues still count, but
    fall into the no-value bucket). A visibility clause that cannot be built
    hides the values rather than exposing them.
  - Rows and series are capped at 200 (remainder collapsed into `Other`,
    `truncated` set), so grouping on a free-text field cannot blow up a dashboard.
    `age_buckets` is capped at 24 boundaries for the same reason.
  - Enumeration-backed fields resolve their labels in one batched query. Redmine's
    own `cast_value` runs a `find_by_id` per value, which would be one round trip
    per bucket; other formats keep the format-first chain, so a `list` field whose
    options happen to be numeric is never named from unrelated enumeration rows.
  - The empty-safe result now carries every new key, so a template reading
    `res.rows` or `res.series` after a failed aggregation still renders.
- Fix the period window: `period_from` opened one full period earlier than
  `build_labels` covers, so a "last 6 months" aggregation actually scanned seven.
  The time-series result never showed it — counts outside the label list were
  discarded — but `group_by: period` reported the extra bucket as a stray row
  outside the chart axis. The window and the axis now cover the same span; the
  time-series output is unchanged (only fewer rows are scanned).
- Existing behaviour is unchanged: a `group_by` over the seven core fields that
  uses none of the new parameters runs the original code path, with the same keys,
  ordering, labels and plain `COUNT(*)` counting, pinned by a regression spec.
  The new dimensions count `COUNT(DISTINCT issues.id)` instead, because the
  incoming query scope may already carry joins that multiply rows.
- **Behaviour change, new code paths only:** in the new dimension path the
  `assignee` and `author` axes are labelled with the user's **display name**
  instead of the login, which is what a chart axis should read. The login is still
  available with `user_label: login`. Templates using the plain
  `group_by: assignee` breakdown keep the login.

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
