# Changelog

All notable changes to this plugin are documented in this file.

## [Unreleased]

### Added

- **`rake reporter_dashboards:import:plan`** — a read-only survey of the
  `redmine_reporter` data this plugin will eventually import. It writes nothing, and
  that is enforced by a test rather than promised: the suite subscribes to
  `sql.active_record` and fails on any statement that is not a `SELECT`.

  It answers four things an operator needs before anything is migrated: how many
  templates there are by type, how many schedules exist and how many are enabled, what
  the stored template bodies actually **use** (which vendor-gem accessors, which
  filters, which of this plugin's own tags), and which templates will need rework —
  with the rule, the line number and the line itself for each finding. Findings cover
  Chart.js 2 idioms, the hand-rolled readiness handshake, `setLineDash`, wkhtmltopdf's
  `[page]` footer tokens, CDN-loaded libraries, and Liquid interpolation inside
  `<script>` that is not passed through `json`/`js`.

  It runs against a database from which `redmine_reporter` has already been removed —
  it reads tables, never Reporter's classes — and it says out loud what it could not
  answer, including the one question that lives in the request log rather than the
  database.

### Changed

- **`redmine_reporter` is now optional.** The plugin used to `raise` at load time
  without it, which made it uninstallable alongside a plain Redmine. Project
  dashboards, the tab bar, `{% sql_aggregate %}`, `{% version_rollup %}`,
  `{% geo_version_map %}` and the statistics endpoint never needed it. Installed or
  not, one `info` line in the log says which mode you are running.

  Only the two report widgets (*Report*, *Report by issues*), their **Export as PDF**
  link, and the `issue.target_version` / `issue.custom_field_value` additions to
  Reporter's own Liquid drop still require it.

- Ordered-list behaviour for dashboard tabs is now owned by the plugin
  (`RedmineReporterDashboards::Positioned`) instead of coming from the `redmineup`
  gem's `up_acts_as_list`. That gem arrived only as a transitive dependency of
  `redmine_reporter`, so without this the plugin would have booted without Reporter
  and then failed on its own `ReporterProjectTab` model. Positions stay 1-based,
  destroying a tab still closes the gap, and the reorder controls behave as before.
  Two behaviour improvements fall out of it: a tab moved to another project is
  re-numbered into its new project's list rather than keeping a position from the old
  one, and two tabs that somehow share a position now have a stable order instead of
  reshuffling between requests.

### Fixed

- With `redmine_reporter` absent, the two report widgets are no longer offered in the
  widget picker, and a dashboard that already has one placed renders a short
  "needs the redmine_reporter plugin" note in its place instead of failing. The
  widget keeps its box and its delete control, so it can still be removed. Its
  **Export as PDF** link answers `404` rather than a server error — the capability was
  never installed, which is not the same as something being broken.

- `.codex/test_setup.sh` / `.codex/test_plugin.sh` could not set up Redmine 7.0
  locally: the Ruby version was derived from the Gemfile's upper bound, and
  `ruby '>= 3.2.0', '< 4.1.0'` produced "Ruby 4.0". The two scripts now share
  `.codex/ruby_version.sh`, which uses the Ruby already on `PATH` when it satisfies
  Redmine's own requirement and otherwise picks the newest real version that does.

- The full-application tests were skipped entirely when `redmine_reporter` was
  absent. That is now the configuration most worth running, and both are exercised.

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

- **Dashboard widget settings are now typed and bounded instead of accepted as
  posted.** `update_page` handed `params[:settings][block].to_unsafe_hash` straight to
  the model after checking only that the widget NAME was known. Nothing looked at the
  keys or the values, and `settings` is a YAML-serialized column that is loaded,
  parsed and re-dumped on every dashboard render — so a user with
  `manage_reporter_project_page` could persist arbitrarily many keys, arbitrarily long
  values and arbitrarily deep nesting into it. (`to_unsafe_hash` yields only Hash,
  Array and String, so this was never object injection; it was an unbounded write.)
  `RedmineReporterDashboards::BlockSettings` now sanitizes each widget's settings in
  two tiers: the keys the core and report widgets read (`limit`, `days`, `query_id`,
  `report_template_id`, `columns`, `group_by`) are typed and validated, and anything
  else is accepted — a widget contributed by another plugin cannot have its setting
  names known here — but only as a bounded scalar or a flat list of them. Everything
  dropped is logged with the widget and the key, so an admin whose setting did not
  stick can see why. `ReporterProjectTab` also caps the whole column at 64 KB, which
  is the backstop for many widgets each holding a legal number of legal keys — measured
  after the settings of widgets no longer on the dashboard are dropped, so they cannot
  push a live dashboard over the limit.
  - The numeric settings are now stored as Integers rather than the form's Strings.
    Every reader already called `to_i` or handed the value to `find_by`, and the
    selects compare with `to_s` on both sides, so nothing reads differently.

- **A report widget now resolves its report template through the same scope its
  settings picker offers.** The picker lists `in_project_and_global(project)`, but the
  render path and the PDF export resolved the stored `report_template_id` with a bare
  `find_by`, so a widget could keep rendering a template belonging to another project —
  one the picker would never have listed, and that a project administrator cannot see
  in order to change it. Reports are per-project or global, never private, so this is
  consistency and defence in depth rather than a leak; the PDF export in particular
  exists to show "the same report the widget shows", so its resolution has to be
  identical to the widget's.

- **A dashboard page view no longer writes to the database.** The default tab was
  created from a `before_action` that also runs on `show`, so a plain GET performed an
  INSERT: a crawler or a monitoring probe created rows, the request failed outright
  against a read-only replica, and two simultaneous first visits each passed the
  `exists?` check and created a tab of their own. `show` now renders an unsaved default
  tab — the page looks exactly as it did, the widget picker and the "add tab" control
  both work — and the row is created by the first action that actually writes, inside a
  lock on the project row so concurrent writes cannot both create one. As a side
  effect the tab is named in the language of a user who can rename it, rather than in
  whatever language the first visitor happened to be using.

- **A dashboard change that fails to save now says so.** `update_page`, `add_block`,
  `remove_block` and `move_block` all ignored what `save` answered, so a rejected write
  was indistinguishable from a successful one: the widget redrew from the in-memory
  object the user had just changed, and the next page load quietly showed the old
  settings. The three redirecting actions set `flash[:error]`; `update_page` reloads the
  page, so the message renders through Redmine's own flash area instead of this plugin
  inventing an error area of its own — and the widgets come back from the database
  rather than from the change that was refused. New key
  `error_reporter_dashboard_save_failed`, translated in all nine locales.

- **A dashboard tab title is stripped and length-limited.** It was validated for
  presence only, so a title of nothing but spaces was accepted — producing a tab
  nobody can click accurately — and a title past the column's `varchar(255)` would
  have been silently truncated by MySQL or raised on PostgreSQL. Titles are now
  stripped before the presence check and capped at 60 characters, which is the width
  of the inputs that edit them; both inputs carry a matching `maxlength`.
  - **Existing titles are grandfathered.** The length is only checked while the title
    is being changed, so a tab already carrying a longer one keeps working: validating
    it unconditionally would have failed every later save of that tab — every
    `add_block`, `move_block` and settings change — and left the dashboard read-only
    after an upgrade. Editing the title still requires a valid one. The strip is
    conditional for the same reason: stripping a stored title that merely has
    surrounding whitespace would mark it changed and switch the length check back on.

- **Deleting a dashboard tab can no longer leave a project with none.** "At least one
  tab must remain" was checked with a count and then acted on, so two people deleting
  the last two tabs at the same moment both saw a count of 2 and both deletes went
  through. The count, the choice of the tab to land on and the delete now happen under
  a lock on the project row.

- **The dashboard routes now use the verb that matches what they do.** All four write
  actions were POST, so a delete and two updates were indistinguishable from a create
  to anything reading an access log or applying method rules at a proxy.
  `remove_block` is DELETE, `move_block` and `update_page` are PATCH; `add_block` stays
  POST, and tab ordering keeps its own POST endpoint. Every caller was updated with
  them — the seven widget settings forms, the issue widget's sort links, the widget
  close button and the widget move controls. A new `test/integration` routing test pins
  each verb, because a controller test generates the path from the parameters and never
  checks the verb at all. Note for anyone upgrading with a dashboard open in a browser:
  the old POST routes are gone, so a stale page needs one reload.

- **Known limitation on Redmine 7.0: the report widgets need a fix in
  redmine_reporter.** Adding Redmine 7.0 to CI surfaced it. Referencing
  `IssueListReportTemplate` raises on Rails 8.1, because reporter's `ReportTemplate`
  declares its enum with the keyword form (`enum orientation: {...}`) — deprecated in
  Rails 7.2 with the message "will be removed in Rails 8.0", and duly removed:
  `def enum(name = nil, ...)` became `def enum(name, ...)`, so the keyword-only call
  raises `ArgumentError: wrong number of arguments (given 0, expected 1..2)`. Nothing in
  this plugin can work around a class that will not load; the fix is one line in
  reporter, and this plugin deliberately does not patch a third-party plugin to get it.
  Everything else on Redmine 7.0 passes, and the four functional tests that have to
  touch a report widget now **skip** there with that explanation instead of reporting
  the same anonymous ArgumentError four times.
  - **What did need fixing here: one failing widget used to take the whole dashboard
    page with it.** `render_reporter_project_block_content` rescued only
    `ActionView::MissingTemplate` — it was written from Redmine core's `my_helper`,
    which does the same — but the two are not in the same position: this plugin's block
    registry discovers widgets by globbing *other* plugins' view directories, so a
    foreign partial raising is a first-class scenario, not an edge case. A widget that
    raises now renders a placeholder with the reason in the log, and the rest of the
    page is unaffected. The placeholder keeps the widget's box, and therefore its close
    button, so a broken widget can still be removed from the layout — returning nothing
    would have made it invisible and unremovable. The report PDF export answers with the
    existing `error_reporter_pdf_generation_failed` message instead of a stack trace.
    New key `error_reporter_widget_render_failed`, translated in all nine locales.

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
  5.1/6.0/6.1 on PostgreSQL were tested.
- **The support matrix is now real rather than aspirational: Redmine 5.1, 6.0, 6.1
  and 7.0, on PostgreSQL 16, MySQL 8.0 and MariaDB 11.** Three things made that
  possible:
  - **New `spec/adapter` suite — the aggregator's SQL executed against a real
    server.** Everything under `spec/` stubs ActiveRecord away and asserts on the SQL
    *strings*, which proves intent but not that either engine accepts them or that
    they answer the same numbers. These 51 specs build a small real schema, seed a
    deterministic fixture (including one issue per day for 400 days, so the ISO-week
    turn of the year is always inside the window) and run the aggregator for real —
    period bucketing, `open_at_end`, the percentile flags, every dimension, the
    measures, `completeness`, `version_rollup`, the visibility clauses, and a group
    that repeats the grouped statements under MySQL's strictest `ONLY_FULL_GROUP_BY`.
    They found the `cf_<id>` defect listed under Fixed. Opt-in via `RRD_ADAPTER_URL`,
    which `.codex/test_setup.sh` now provisions.
  - **The three near-identical per-version workflows are replaced by one
    `.github/workflows/ci.yml` that runs automatically.** They were
    `workflow_dispatch`-only because each checked out the private
    `redmine_reporter` plugin with `secrets.REPORTER_REPO_TOKEN` before running
    anything, and a fork pull request cannot read that secret. The jobs are now split
    by what they actually need: `rspec` (no database, no reporter) across the four
    Redmine branches, `adapter` once per database engine, and `minitest` gated on the
    secret being readable so it is skipped rather than failed.
  - `.codex/test_setup.sh` takes `RRD_DB=postgresql|mysql|mariadb` and provisions the
    matching engine plus a separate `redmine_adapter_test` database;
    `.codex/test_plugin.sh` runs the adapter specs in their own process when a URL is
    available. `.codex/check_ruby_floor.sh` guards the Ruby 2.7 syntax floor that
    Redmine 5.1 support implies, and runs in CI.

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
- **Fix a timezone off-by-one across every date this plugin computes.**
  `build_labels` read `Date.today` (the server's system timezone) while
  `period_from` is `Time.zone`-based, which is also what Rails stores and compares
  timestamps in and therefore what the database's own `TO_CHAR` / `DATE_FORMAT`
  bucketing sees. On a host that is not UTC the two disagreed, so the WHERE window
  could start a day — or a month — away from the oldest label: the oldest bucket
  reported zero, or an unlabelled period leaked into the result. There is now one
  clock (`current_date`, `Time.zone`-based) behind `build_labels`, `period_from`,
  the `age` boundaries, `overdue` and the `*_open_days` values. On a UTC host
  nothing changes. Note that Redmine applies its own date *filters* in
  `User.current.time_zone`, which is a different clock again — documented next to
  the drill-through ranges.
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

### Fixed

- **Every `cf_<id>` dimension failed on a MySQL or MariaDB server configured with
  `ONLY_FULL_GROUP_BY`.** The dimension grouped on `NULLIF(rrd_cv_g.value, '')`, and
  MariaDB's matcher does not recognise a `CASE`-family expression in the select list
  as equal to the same expression in the `GROUP BY`, so the statement was rejected
  outright with `'value' isn't in GROUP BY` — every such dashboard block rendered
  empty. `custom_value_join` now keeps the empty-value rows out of the join instead,
  so the dimension groups on a bare column: same buckets, and an index can be used.
  Found by the new adapter execution specs, on MariaDB 11 with `ONLY_FULL_GROUP_BY`
  forced on.
  - Side effect, and an improvement: an issue holding several values for a
    multi-valued custom field, one of them empty, used to be counted under its real
    values *and* in the no-value bucket. It is no longer counted twice.
- `/sql_stats` stamped `generated_at` with `Time.now`, the server's system timezone,
  next to data aggregated on `Time.zone` — which is also the clock the database
  compares on. It uses `Time.current` now, so the whole response is on one clock: the
  same defect this release fixed inside the aggregator.

### Security

- **A role-restricted custom field is no longer usable as a dimension, measure or
  completeness field by a viewer who is not entitled to it.** Its *values* were
  already protected by `visibility_by_project_condition`, but its *name* was not: a
  dimension reports it as `field_name` and a completeness bucket uses it as a label.
  Redmine builds a query's custom-field filters from `CustomField.visible`, so such a
  field does not appear in that user's filter list at all — and drill-through already
  refused to link it for exactly that reason. The gate now uses Redmine's own
  `CustomField.visible` predicate (one indexed `EXISTS`) and fails closed. A viewer
  who is entitled in at least one project keeps the field; the per-project narrowing
  stays in SQL, as before.
- **`version_rollup` summed spent time and cost custom fields without any
  visibility check.** `spent_hours` joined `time_entries` raw — the same defect as
  the one below, in code that shipped in 0.4.0 — and each `cost_fields:` id was
  summed straight out of `custom_values` with no `visibility_by_project_condition`,
  so a restricted cost field could be read per version by any dashboard viewer.
  Spent time now carries `TimeEntry.visible_condition`; each cost field is resolved
  through the same path as a `cf_<id>` dimension (so a field the viewer may not see
  is skipped with a log line) and its join carries the field's own visibility clause
  under a per-field alias.
- **A scope resolved from a Liquid drop is now intersected with
  `Issue.visible(User.current)`.** The `query_id:` and `context.registers` paths are
  `IssueQuery#base_scope`, which starts from `Issue.visible`, but the `from:` drop
  path returns whatever ivar of the named context object responds to
  `where`/`group`/`count`. Merging `Issue.visible` makes the guarantee hold whatever
  a template names there. It fails open on an unexpected merge error, because the
  paths that matter are already scoped and an empty dashboard is a worse trade.
- **`measure: sum, of: spent_hours` summed time entries the viewer may not see.**
  Redmine applies `TimeEntry.visible_condition` everywhere it reports spent time (the
  issue list column subselect, `IssueQuery#total_for_spent_hours` and
  `Issue.load_visible_spent_hours`), because `:view_time_entries` is granted per
  project and a role can be limited to its *own* entries. The measure joined
  `time_entries` raw. The condition is now in the join's ON clause — so the join
  stays outer and a bucket with no visible entries still reports zero — and it fails
  closed if it cannot be built. Found in review of this release; the measure is new
  in it, so no released version is affected.

- New **`group_by: completeness`** dimension: one bucket per field named in
  `fields:`, reporting how many issues have it filled in (`count`), how many do not
  (`empty`), and the percentage (`pct`). This is the widget that makes the others
  trustworthy — a Department chart means nothing if Department is filled on 22% of
  issues.
  - One statement: one conditional aggregate per field, and a SINGLE
    `custom_values` join for all the custom fields rather than one join each. Each
    field's own visibility condition lives in its own aggregate, because they differ
    per field, so a role-restricted field is not reported as empty to someone who
    simply may not see it.
  - Custom field ids go through the same resolution as `group_by: cf_<id>`, so a
    non-issue or unknown field is skipped with a warning; the core fields accept the
    dimension-style aliases too. More than 12 fields is refused rather than building
    an unreadable chart.
  - Bucket order follows `fields:`; `sort` and `limit` do not apply, like `period`
    and `age`. `count` is the FILLED count, so an existing bar chart works unchanged.
  - With `drill: true` each bucket carries `url` ("is set") and `empty_url` ("is not
    set") — the actionable one, kept separate on purpose. Both go through the same
    availability and operator checks, so `empty_url` is `nil` rather than broken
    where Redmine does not allow the "none" operator on that filter type.
- `group_by: flags` gained **`median_open_days`** and **`p90_open_days`**, both
  `nil` when nothing is open. A median is a fairer opener than "the oldest is 146
  days", which one forgotten ticket can dominate. Read with a portable offset
  instead of `percentile_cont` (PostgreSQL only): two indexed single-row reads,
  newest first so the rows arrive in ascending age and the offset is an ordinary
  percentile index — oldest-first would have put p90 at the young end, the opposite
  of what the number means. It is the lower percentile, not the interpolated one,
  and the offset counts rows, so a fanning join in the report query can shift it by
  a place; both documented.
- `{% sql_aggregate %}` gained a **`measure:`** other than a row count: `distinct`,
  `sum` and `avg` over an `of:` field, next to the unchanged `count`.
  - The question it unlocks is `measure: distinct, of: author` with
    `group_by: period`: how many *different* people filed something each month,
    which is an adoption curve rather than a volume curve and which the old API
    could not express at all.
  - `of:` accepts the core reference columns (distinct), `estimated_hours` /
    `done_ratio` / `spent_hours`, and `cf_<id>` — distinct on any format, sum and
    avg only on an `int` or `float` field, with the numeric cast applied after
    `NULLIF(value, '')` so an empty string never reaches it and a corrupt one
    yields NULL instead of aborting the statement. Both adapters are handled
    (`AS numeric` / `AS DECIMAL(20,4)`).
  - The measure's custom-field join has its own alias (`rrd_cv_m`), so it cannot
    collide with the `group_by` (`rrd_cv_g`) or `split_by` (`rrd_cv_s`) joins even
    when all three appear in one statement. The join builder is now shared by all
    three instead of being written out twice.
  - `spent_hours` is `sum` only: `AVG(time_entries.hours)` averages time entries
    rather than issues, and charting the first as the second is worse than
    refusing. Its join is a LEFT OUTER one, so a bucket whose issues logged no time
    reports zero instead of vanishing from the axis.
  - **`total` is no longer the bucket sum** for a non-additive measure: it is the
    same measure over the whole scope, in its own query. `measure: count` keeps the
    old meaning exactly, so a multi-valued custom field still sums to more than the
    issue count. Crosstab row and column totals get the same treatment, and a
    collapsed `Other` bucket is its own aggregate rather than a sum of parts.
  - `measure` and `measure_field` are reported in the result. An unusable
    combination is refused with one logged warning and the empty-safe result, like
    an unusable `group_by`.
- `{% sql_aggregate %}` time series gained **`open_at_end`**: the number of issues
  that existed and were not yet closed at the end of each period, aligned with
  `labels`. A template could only approximate it with a running total of
  `created - closed`, which is wrong for every issue that already existed when the
  window opened. One conditional aggregate per period in a single statement
  (chunked at 30, so a 90-day window is three statements rather than one 90-column
  SELECT), with the period ends bound and taken from the same clock and the same
  label parser as the axis. It honours `closed_statuses` like the `closed` series
  does, so the three can be charted together — and because `closed_on` is preserved
  when an issue is reopened, requiring the current status to be a closed one is what
  makes the closed side right rather than merely consistent. Two documented limits: a
  reopened issue counts as open for every period before its LAST closing, because
  that is the only one `closed_on` records; and the points carry no drill-through
  URL, because "existed by X and (open or closed after X)" is an OR across two
  fields that a Redmine query cannot express.
- `{% sql_aggregate %}` can now build **drill-through URLs** with `drill: true`:
  every bucket, crosstab row, series and funnel stage carries a `url` pointing at
  the Redmine issue list, filtered to exactly the issues that element represents.
  - The URL inherits **everything** from the report query — filters, columns,
    grouping, totals and sort order — plus the dimension filter, with
    `set_filter=1`. A saved query cannot be extended through a URL
    (`retrieve_query` short-circuits on `query_id` and ignores any `f`/`op`/`v`),
    so the parameters are replicated using Redmine's own `Query#as_params` on an
    unsaved copy: no parameter names are reimplemented here.
  - Every row, series entry and bucket now also exposes the **raw stored value**
    (`value`, plus `values` on a collapsed `Other` row) and the issue-list
    `filter` that isolates it, independently of `drill`. `label` and `count` are
    untouched. The crosstab gains `series_entries` (label + value + filter,
    aligned with `series`); `series` itself stays the plain array of label strings
    every existing template feeds to Chart.js.
  - `group_by: flags` gains `stages`, the funnel projection of four counters with
    the filter for each, so a funnel widget no longer hardcodes the mapping.
  - `cell_urls` gives a crosstab a dense rows × series array, aligned with
    `matrix`, each entry ANDing the row and series filters.
  - A date field the query already filters on is **intersected**, not replaced, so
    a period or age bucket can never widen an inherited range. A relative
    inherited operator (`t-`, `w`, `m`, `>t-`, …) cannot be intersected at render
    time: it falls back to the bucket range and logs at debug level, the one case
    where a drill-down can show more issues than the element counted.
  - **No URL is better than a wrong URL.** An element gets `nil` when the field is
    not an available filter (`Query#add_filter` silently ignores those, which would
    drop the user on a wider list), when Redmine does not allow the operator on
    that filter type, when the bucket is inexpressible, when the bucket range and
    the query's own date filter are disjoint, or when the URL would exceed
    `drill_max_url` (2000 characters by default). Each refusal is logged once per
    render.
  - No `IssueQuery` resolvable means `drill_available => false` and no URLs at all,
    rather than a dimension-only URL that would show issues from outside the report
    scope.
  - `ScopeResolution#resolve_query` makes the report's `IssueQuery` reachable from
    the Liquid tags — via the `query_id:` param (visibility-scoped, as before),
    `context.registers`, or a thread-local `ReporterListPatch` sets around
    `liquidize()` and always clears in an `ensure`, so no query can leak into
    another request on a reused thread. The register lookups keep priority, so a
    future Reporter release that passes the query properly wins over the fallback.
  - `drill: true` implies the dimension path, because only it knows the raw value
    behind a label: for a core field that means display names for
    `assignee` / `author` (use `user_label: login` for the old text). A falsy
    `drill`, or no `drill` at all, changes nothing — pinned by a regression spec.
  - An over-long URL **sheds the cosmetics before it gives up**: because a
    drill-down inherits `c[]`, a report with many columns can push a two-filter
    crosstab cell over the cap on its own. The URL is rebuilt without the inherited
    columns and totals, then without the grouping and sort order, and only then
    refused. The filters are never dropped. `drill_degraded` reports it, and the
    log names the real length, the cap and what was dropped — a silent cap would
    have left half a chart clickable for no visible reason.
  - `drill_inherit: filters` takes that route from the start: filters only, no
    columns, grouping, totals or sort order. Useful for the shortest possible URL,
    and to land on a flat list instead of one grouped by the report's own
    `group_by` (which, inherited, groups the drill-down by the very dimension you
    clicked).
  - `cell_urls_truncated` distinguishes "past the 5000-cell cap" from "no filter",
    which a dense all-nil `cell_urls` could not.
  - The **visibility gate is one gate for all five sources.** `query_from_query_id`
    was scoped by `IssueQuery.visible` but the thread-local was not, because
    `ReporterListPatch` resolves it with a bare `find_by` that also feeds
    `base_scope`. `resolve_query` now runs every resolved query through one
    `#visible?` check, so the guarantee no longer depends on where the query came
    from — it holds the first time a report renders under another user.
  - A date dimension whose bucket value is not a date Redmine accepts (a
    date-format custom field holding something else) yields no URL, instead of a
    link to "Date is invalid" — or, when that field was already filtered, instead
    of silently falling back to the report's whole date range behind one element.
  - The operator is validated a second time on the RESULT of a merge, since an
    intersection synthesises one (`><` becomes `>=` or `<=` when an end opens up)
    that no earlier check had seen.
  - Date values are read with Redmine's own accepted shape rather than
    `Date.parse`, which reads `"30"` as the 30th of the current month and would
    have invented a bound out of a value Redmine itself rejects.
  - Not supported for the time-series mode, whose labels carry no raw value:
    `drill_available` is `false` and the log points at `group_by: period`.

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
