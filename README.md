# Redmine Reporter Dashboards

A dashboard extension for the [Redmine Reporter](https://www.redmineup.com/pages/plugins/reporter) plugin. Adds configurable project dashboards and replaces slow Liquid loops in report templates with fast SQL aggregations.

## What does it do?

### Project dashboards

Each project gets its own dashboard page with tabs. Arrange widgets with simple up/down/left/right buttons — stack them one per line or place several per line, in any arrangement:

- **Issues** — a filtered issue list driven by a saved query
- **Report** — a Reporter report block embedded directly on the dashboard
- **Activity**, **Calendar**, **News**, **Documents**, **Time log**

Widgets are laid out as ordered rows. **Up** / **down** move a widget to the adjacent row (joining it, or splitting onto a new line); **left** / **right** reorder it within its row. There is no drag-and-drop, and the controls work on both Redmine 5 and Redmine 6. Each tab is configured independently per project and per role.

### `{% sql_aggregate %}` Liquid tag

The standard Liquid approach in Reporter templates iterates over all issues as objects:

```liquid
{% for issue in issues %}...{% endfor %}
```

With hundreds or thousands of issues that gets slow. The `{% sql_aggregate %}` tag does the same work entirely in SQL — no Issue objects loaded, no memory pressure — and returns the result as a Liquid variable you can use directly in your template.

### `{% geo_version_map %}` Liquid tag

The Reporter issue drop exposes `issue.version` as a scalar (the name only), with no id. That makes it impossible to build version-filtered URLs — roadmap, issues list, time entries — from a template. The `{% geo_version_map %}` tag provides a lookup from version name to its id and metadata so you can construct those links.

### `{% version_rollup %}` Liquid tag

A per-**target-version** rollup, computed entirely in SQL. A "one card per version" dashboard normally loops over every version *and* every issue (`O(versions × issues)`) in Liquid, which gets very slow with many issues. `{% version_rollup %}` returns one ready-to-render row per version — counts, hours, min/max dates and summed numeric custom fields (e.g. cost) — in a handful of grouped queries, so the template only loops over the (few) versions.

## Requirements

- `redmine_reporter` plugin version 2.0.5 or higher
- PostgreSQL or MySQL/MariaDB. The SQL aggregation tags use adapter-specific date
  formatting and refuse to guess on any other database — SQLite is not supported.

### Support matrix

Supported means: exercised by the CI workflows in `.github/workflows/`.

| Redmine | Rails | Ruby (upstream range) | Database | Status |
|---------|-------|------------------------|----------|--------|
| 5.1 | 6.1 | >= 2.7, < 3.3 | PostgreSQL | tested |
| 6.0 | 7.1 | >= 3.0, < 3.4 | PostgreSQL | tested |
| 6.1 | 7.2 | >= 3.2, < 3.5 | PostgreSQL | tested |
| 7.0 | 8.1 | >= 3.2, < 4.1 | — | **not tested — do not assume it works** |
| any | — | — | MySQL/MariaDB | **not tested in CI** — the code is written for it and the SQL is adapter-aware, but no workflow proves it |

`requires_redmine` is set to 5.1 to match this table. Earlier 5.x releases may
well work; they are simply not tested, so the plugin does not claim them.

## Installation

```bash
cd {REDMINE_ROOT}/plugins
git clone https://github.com/jcatrysse/redmine_reporter_dashboards.git
cd {REDMINE_ROOT}
bundle install
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

Restart Redmine after installation.

## Enabling the dashboard for a project

1. Open **Project → Settings → Modules** and enable **Project dashboard**.
2. Assign permissions to the relevant roles:
   - `view_reporter_project_page` — view the dashboard
   - `manage_reporter_project_page` — add and rearrange blocks
   - `manage_reporter_project_tabs` — create and rename tabs
3. A **Project dashboard** link appears in the project menu. The first visit automatically creates a default tab.

## Using the `{% sql_aggregate %}` tag

Place the tag at the top of your Reporter template. It writes the result into a Liquid variable (`stats` by default) that you can then use freely.

### Time series — created and closed per period

```liquid
{% sql_aggregate from: issues, period: month, periods: 6,
   closed_statuses: "Closed;Rejected", assign_to: stats %}

| Month | Created | Closed |
|-------|---------|--------|
{% for i in (0..5) %}| {{ stats.labels[i] }} | {{ stats.created[i] }} | {{ stats.closed[i] }} |
{% endfor %}

Currently open: **{{ stats.open_now }}** — Total: **{{ stats.total }}**
```

Four period sizes are supported: `day`, `week`, `month` (default) and `year`.

| Parameter | Default | Maximum |
|-----------|---------|---------|
| `period: day` | 30 days | 90 |
| `period: week` | 13 weeks | 52 |
| `period: month` | 6 months | 24 |
| `period: year` | 3 years | 10 |

### Categorical breakdown

With `group_by` the tag switches to a category summary instead of a time series.

```liquid
{% sql_aggregate from: issues, group_by: status, assign_to: by_status %}

{% for bucket in by_status.buckets %}
- {{ bucket.label }}: {{ bucket.count }}
{% endfor %}
Total: {{ by_status.total }}
```

### Dimensions

`group_by` — and the second dimension `split_by` — accept any of these:

| Value | Groups by |
|-------|-----------|
| `status` | Issue status |
| `priority` | Priority |
| `tracker` | Tracker |
| `assignee` | Assigned user |
| `author` | Author |
| `category` | Category |
| `version` | Target version |
| `cf_<id>` | An **issue custom field** by numeric id, e.g. `cf_92` |
| `period` | Date bucket — see `period` / `periods` / `date_field` |
| `age` | Age bucket — see `age_buckets` / `age_field` |
| `flags` | Scalar governance counters. `group_by` only, never `split_by` |

Custom fields are resolved to their **labels**, not their stored values: for
`enumeration` and `depending_enumeration` fields Redmine stores the enumeration
id in `custom_values.value` (Department "Survey" is stored as `415`), so grouping
in Liquid would need a hardcoded id-to-label map. The tag resolves the label
through the field's own format, falling back to the enumeration name and finally
to the raw value.

An unusable dimension — a `cf_` id that does not exist, is not an issue custom
field, or is not numeric — logs a warning and yields the empty result. It never
raises, so a typo cannot take down a dashboard or a PDF export.

**Custom field visibility is enforced**, the same way Redmine enforces it when a
query groups or sorts on a custom field: if the field is restricted to roles, a
viewer without one of those roles does not see its values. Their issues are
still counted, but they land in the no-value bucket. A report can therefore be
shared without leaking the values of a restricted field.

### Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `assign_to` | `stats` | Result variable name |
| `from` | `issues` | Liquid variable holding the issues drop |
| `query_id` | – | Aggregate a saved `IssueQuery` instead |
| `group_by` | – | Dimension; switches to breakdown mode |
| `split_by` | – | Second dimension; requires `group_by`, produces a crosstab |
| `period` | `month` | `day` / `week` / `month` / `year` |
| `periods` | 30 / 13 / 6 / 3 | Capped at 90 / 52 / 24 / 10 |
| `months` | – | Legacy alias for `periods` when `period: month` |
| `date_field` | `created` | `created` or `closed` — which timestamp `period` buckets on |
| `closed_statuses` | – | Semicolon/comma-separated status **names**; omit to use the `is_closed` flag |
| `sort` | `count` | `count` (desc), `label` (asc, natural), `position` (field-defined order) |
| `limit` | `0` | Keep the top N rows; the rest collapses into one `Other` row |
| `other_label` | `Other` | Label of the collapsed row |
| `empty_label` | `(none)` | Label of the no-value row (`Unassigned` for `assignee`, `None` for the other core fields) |
| `age_buckets` | `30;60;90;180` | Ascending day boundaries, semicolon or comma separated (max 24) |
| `age_field` | `created` | `created`, `updated` or `due` |
| `user_label` | `name` | `name` (display name) or `login`, for `assignee` / `author` |

An invalid enum-ish value (`sort: banana`, `age_field: banana`) falls back to the
default and logs a warning — it never raises.

**Ordering.** Sorted rows first, then the `Other` row, then the no-value row.
Both special rows always sit at the end, whatever `sort` says. `sort: position`
uses the custom field's own value order (`CustomFieldEnumeration#position`, or
the index in `possible_values`); values with no known position sort last. For
core fields, `position` behaves like `label`.

**`sort`, `limit` and `other_label` are ignored for `period` and `age`.** Those
axes are always chronological / ascending and always contain every bucket in the
window, including the empty ones, so a chart's x-axis has no gaps.

**`group_by: period` also restricts the aggregation to that window**, exactly like
the time-series mode: `total` is the window total, not the size of the query.
With `date_field: closed` only issues actually closed inside the window are
counted at all — issues that are still open have no `closed_on` date.

Independently of `limit`, the number of rows and of series is capped at **200**;
anything beyond that collapses into `Other` and sets `truncated` to `true`. This
protects a dashboard from a `group_by` on a free-text custom field.

### More examples

**Weekly throughput — last quarter:**

```liquid
{% sql_aggregate from: issues, period: week, periods: 13,
   closed_statuses: "Closed", assign_to: weekly %}

{% for i in (0..12) %}
Week {{ weekly.labels[i] }}: {{ weekly.created[i] }} created, {{ weekly.closed[i] }} closed
{% endfor %}
```

**Top trackers:**

```liquid
{% sql_aggregate from: issues, group_by: tracker, assign_to: by_tracker %}

{% for bucket in by_tracker.buckets %}
{{ bucket.label }} — {{ bucket.count }} issues
{% endfor %}
```

**Via a saved query (query_id):**

When the Reporter plugin exposes `query_id` in the template context:

```liquid
{% sql_aggregate query_id: query_id, period: month, periods: 3,
   closed_statuses: "Closed;Rejected", assign_to: stats %}
```

**Issues per department (custom field 92), top 10 plus "Other":**

```liquid
{% sql_aggregate from: issues, group_by: cf_92, sort: count, limit: 10,
   other_label: "Other departments", assign_to: by_dept %}

### {{ by_dept.field_name }}
{% for bucket in by_dept.buckets %}
- {{ bucket.label }} — {{ bucket.count }}
{% endfor %}
Total: {{ by_dept.total }}{% if by_dept.truncated %} (long tail grouped){% endif %}
```

**Department × Lesson Type — a stacked Chart.js bar chart in one call:**

```liquid
{% sql_aggregate from: issues, group_by: cf_92, split_by: cf_86,
   sort: position, assign_to: xtab %}

<canvas id="deptChart" width="600" height="320"></canvas>
<script>
new Chart(document.getElementById('deptChart').getContext('2d'), {
  type: 'bar',
  data: {
    labels: [{% for row in xtab.rows %}"{{ row.label | escape }}"{% unless forloop.last %},{% endunless %}{% endfor %}],
    datasets: [
      {% for name in xtab.series %}
      {
        label: "{{ name | escape }}",
        backgroundColor: ['#4e79a7', '#e15759', '#59a14f'][{{ forloop.index0 }} % 3],
        data: [{% for row in xtab.rows %}{{ row.cells[name] }}{% unless forloop.last %},{% endunless %}{% endfor %}]
      }{% unless forloop.last %},{% endunless %}
      {% endfor %}
    ]
  },
  options: { responsive: false, animation: false,
             scales: { xAxes: [{ stacked: true }], yAxes: [{ stacked: true, ticks: { beginAtZero: true } }] } }
});
</script>
```

`xtab.matrix` is the same data as one array per row, so
`data: [{{ row.counts | join: "," }}]` works too. Every row has exactly
`series.length` entries and every entry is a real number — never `nil` — so the
generated JavaScript is always valid.

**Lesson Type per month — a time axis split by a custom field:**

```liquid
{% sql_aggregate from: issues, group_by: period, split_by: cf_86,
   period: month, periods: 12, date_field: created, assign_to: per_month %}

| Month | {% for s in per_month.series %}{{ s }} | {% endfor %}
|-------|{% for s in per_month.series %}---|{% endfor %}
{% for row in per_month.rows %}| {{ row.label }} | {% for n in row.counts %}{{ n }} | {% endfor %}
{% endfor %}
```

Every month in the window is present, including months with no issues, so the
axis is continuous.

**Age histogram — how old is the open work?**

```liquid
{% sql_aggregate from: issues, group_by: age, age_buckets: "30;60;90;180",
   age_field: created, assign_to: ages %}

{% for bucket in ages.buckets %}
{{ bucket.label }} days: {{ bucket.count }}
{% endfor %}
```

Buckets come back in ascending age order (`0-30`, `31-60`, `61-90`, `91-180`,
`>180`), including empty ones. Issues whose date field is `NULL` (relevant for
`age_field: due`) land in the `(none)` bucket, not in the oldest one.

**Governance KPI tiles:**

```liquid
{% sql_aggregate from: issues, group_by: flags,
   closed_statuses: "Closed;Rejected", assign_to: kpi %}

{{ kpi.total }} issues · {{ kpi.open }} open · {{ kpi.closed }} closed
{{ kpi.unassigned }} unassigned · {{ kpi.overdue }} overdue
{% if kpi.oldest_open_days %}Oldest open item: {{ kpi.oldest_open_days }} days{% endif %}
```

### Result structure

**Time series** (`assign_to: stats`):

| Key | Type | Content |
|-----|------|---------|
| `stats.labels` | array | Period labels, oldest first |
| `stats.created` | array | Issues created per period |
| `stats.closed` | array | Issues closed per period |
| `stats.open_now` | integer | Current number of open issues |
| `stats.total` | integer | Total issues in scope |
| `stats.period` | string | Period used (`month`, `week`, …) |
| `stats.periods` | integer | Number of periods in the series |

**Breakdown** (`assign_to: by_status`):

| Key | Type | Content |
|-----|------|---------|
| `by_status.buckets` | array | `[{label, count}, ...]` sorted by count descending |
| `by_status.total` | integer | Sum of all counts |
| `by_status.group_by` | string | Grouping used |

A breakdown over a custom field, `period`, `age`, or any core field combined with
one of the new parameters additionally exposes:

| Key | Type | Content |
|-----|------|---------|
| `.dimension` | string | The dimension that was requested (`cf_92`) |
| `.field_name` | string | Human name of the custom field (`Department`); nil for core and pseudo dimensions |
| `.multi_value` | boolean | True when the custom field accepts several values per issue |
| `.truncated` | boolean | True when `limit` or the 200-row cap collapsed rows into `Other` |

**Crosstab** (`split_by` present):

| Key | Type | Content |
|-----|------|---------|
| `.series` | array | Series labels — the `split_by` axis |
| `.rows` | array | `[{label, total, counts, cells}, ...]` |
| `.rows[].counts` | array | One number per series, aligned with `.series` |
| `.rows[].cells` | hash | The same numbers keyed by series label |
| `.matrix` | array | Rows × series, aligned with `.rows` and `.series` |
| `.columns` | array | Per-series totals, aligned with `.series` |
| `.buckets` | array | Row totals as `[{label, count}]`, for templates that only need one dimension |
| `.total` | integer | Sum of the whole matrix |
| `.split_by` | string | Second dimension requested |
| `.series_field_name` | string | Human name of the second custom field |

`matrix` and `counts` are dense: every row has exactly `series.length` integers,
zeros included, so `{{ row.counts | join: "," }}` always produces valid
JavaScript.

**Flags** (`group_by: flags`):

`total`, `open`, `closed`, `assigned`, `unassigned`, `with_due_date`,
`without_due_date`, `overdue`, `no_estimate`, `oldest_open_days`,
`newest_open_days`. They are available both at the top level (`{{ kpi.total }}`)
and under `flags` (`{{ kpi.flags.total }}`). `open` / `closed` honour
`closed_statuses`, `overdue` counts open issues past their due date, and the
`*_open_days` values are `nil` when nothing is open.

On any error — an unresolvable scope, an invalid dimension, a database problem —
the tag assigns an empty-safe result with **all** of these keys (empty arrays,
zeros, `false`) and logs to `Rails.logger`, so a template that reads `res.rows`
or `res.series` still renders.

### Notes and caveats

- **Counting.** The dimension path counts `COUNT(DISTINCT issues.id)`, because the
  query's own scope may already join tables that multiply rows (a filter on a
  custom field, watchers, spent time) and the custom field dimension adds a join
  of its own. The seven core fields keep their original plain `COUNT(*)` when
  used without any of the new parameters, so existing templates are unaffected.
- **Multi-valued custom fields.** An issue with several values is counted once per
  value, so the bucket counts sum to more than the number of issues. Check
  `.multi_value` if that matters for the caption you print.
- **Labels come from your data.** Custom field values, user names and version
  names end up in the result. Escape them in HTML and in Chart.js label arrays
  (`{{ label | escape }}`), exactly as the version dashboard example does.
- **Duplicate series labels.** If two stored values resolve to the same label,
  `series` contains that label twice and `cells` keeps only the last of them;
  `counts` and `matrix` stay correct and aligned.
- **Cost.** The aggregation itself is always a single `COUNT … GROUP BY`, one or
  two dimensions alike. Label resolution adds at most one batched primary-key
  lookup per dimension (one more when `sort: position` needs the enumeration
  order). `flags` runs a handful of small aggregates. No issue is ever loaded
  into Ruby, and nothing is done per row.

### Legacy alias

The tag was previously called `{% geo_aggregate %}`. That name still works as an alias so existing templates keep working without changes.

## Using the `{% geo_version_map %}` tag

Place the tag near the top of your Reporter template. It writes a lookup table into a Liquid variable (`geo_versions` by default), keyed by version name.

```liquid
{% geo_version_map assign_to: geo_versions %}

{% for issue in issues %}
{% assign v = geo_versions[issue.version] %}
- {{ issue.subject }} — [roadmap](/projects/{{ v.project }}/roadmap) ·
  [issues](/projects/{{ v.project }}/issues?set_filter=1&fixed_version_id={{ v.id }}) ·
  [time entries](/projects/{{ v.project }}/time_entries?set_filter=1&issue.fixed_version_id={{ v.id }})
{% endfor %}
```

By default the map covers every version (`Version.all`). Pass a project identifier to limit it to that project's shared versions:

```liquid
{% geo_version_map project: my-project, assign_to: geo_versions %}
```

The `project:` value is a literal identifier (not a Liquid variable). It is resolved by identifier first, then by numeric id. If the project cannot be found, the map is left empty rather than falling back to every version.

### Result structure

Each entry is keyed by the version **name**; the value exposes:

| Key | Type | Content |
|-----|------|---------|
| `.id` | integer | Version id (use it in `fixed_version_id` filters) |
| `.effective_date` | date / nil | The version's due date, or empty when unset |
| `.status` | string | `open`, `locked` or `closed` |
| `.project` | string | Identifier of the project the version belongs to |

Look up a version by name — typically the scalar `issue.version` from the issue drop:

```liquid
{{ geo_versions[issue.version].id }}
```

If the name is unknown (for example an issue with no target version), the lookup returns nothing and the surrounding template still renders. The tag itself produces no output; on any error it assigns an empty map so the template never crashes.

## Using the `{% version_rollup %}` tag

Aggregates the report's issues per target version in SQL and assigns a ready-to-render Array. Use it instead of a nested `{% for version %}{% for issue %}` loop when you build a per-version dashboard.

```liquid
{% version_rollup from: issues, closed_statuses: "Closed;Rejected", cost_fields: "20,21", assign_to: versions %}
{% for v in versions %}
  <h3><a href="{{ v.version.url }}">{{ v.name }}</a></h3>   {# v.version is a VersionDrop, nil for the "None" bucket #}
  {{ v.open }} open / {{ v.closed }} closed · {{ v.spent_hours }} / {{ v.est_hours }} h
  {% if v.cost['20'] or v.cost['21'] %}budget {{ v.cost['21'] }} / {{ v.cost['20'] }}{% endif %}
{% endfor %}
```

Params: `from` (issues drop, default `issues`), `closed_statuses` (semicolon/comma-separated names; else the `is_closed` flag), `cost_fields` (semicolon/comma-separated numeric custom field ids to sum), `assign_to` (default `versions`).

### Result structure

One row per target version (a nil version → name `None`), sorted by name. String keys, so Liquid dot-access works:

| Key | Type | Content |
|-----|------|---------|
| `.name` | string | Version name (`None` for issues with no target version) |
| `.version` | drop / nil | A `VersionDrop` (absolute, PDF-safe URLs: `.url`, `.roadmap_url`, `.issues_url`, …); nil for `None` |
| `.total` `.open` `.closed` | integer | Issue counts |
| `.open_done_sum` | integer | Σ `done_ratio` over open issues (for % complete) |
| `.overdue_open` `.unassigned_open` `.no_estimate` | integer | Flag counts |
| `.est_hours` `.spent_hours` | float | Σ estimated / spent hours |
| `.start_date` `.due_date` | date / nil | MIN start / MAX due over the version's issues |
| `.cost` | hash | `{ "<field_id>" => float }` summed per numeric custom field |

Cost sums mirror Redmine's own numeric custom-field totalling (`joins(:custom_values)`, empty values skipped, `CAST(... AS decimal)`), so they are correct on PostgreSQL and MySQL. On any error the tag assigns an empty Array so the template never crashes. See [`examples/version_status_dashboard.liquid`](examples/version_status_dashboard.liquid) for a full dashboard built on this tag.

## `issue.target_version` in report templates

Reporter's issue drop exposes `issue.version` as a scalar (the name only). This plugin adds `issue.target_version`, a drop wrapping the issue's target version with everything needed to build links — and **all URLs are absolute**, so they keep working when a report is exported to PDF by wkhtmltopdf.

```liquid
{% if issue.target_version %}
  <a href="{{ issue.target_version.roadmap_url }}">{{ issue.target_version.name }}</a>
  · <a href="{{ issue.target_version.open_issues_url }}">Open issues</a>
  · <a href="{{ issue.target_version.time_url }}">Time entries</a>
{% endif %}
```

| Accessor | Content |
|----------|---------|
| `.id` `.name` `.description` | Version identity |
| `.effective_date` | Due date (`Date` or empty) |
| `.status` | `open` / `locked` / `closed` |
| `.completed_percent` | Completion percentage |
| `.project_identifier` | Identifier of the version's project |
| `.url` | Absolute link to the version page |
| `.roadmap_url` | Absolute link to the project roadmap |
| `.issues_url` / `.open_issues_url` / `.closed_issues_url` | Absolute issue-list links filtered by this version (all / open / closed) |
| `.time_url` | Absolute time-entries link filtered by this version |

`issue.target_version` is `nil` when the issue has no target version, so guard with `{% if issue.target_version %}`. See [`examples/sample_report_template.liquid`](examples/sample_report_template.liquid) for it in a full template alongside `{% sql_aggregate %}` and a Chart.js chart.

## `issue.custom_field_value[id]` in report templates

Reporter's `{{ issue | custom_field: "Name" }}` filter looks a custom field up by **name**. When you'd rather read a custom field **by id** — stable across renames and translations — this plugin adds `issue.custom_field_value`, a drop whose bracket lookup returns **any** custom field by id:

```liquid
{{ issue.custom_field_value[20] }}                     {% comment %} value of custom field 20 {% endcomment %}
{% assign fid = 21 %}{{ issue.custom_field_value[fid] }} {% comment %} id from a variable {% endcomment %}
```

The id can be an integer literal, a string, or a Liquid variable. The **raw stored value** is returned (a `String` for text/numeric fields, an `Array` for multi-value fields, empty/`nil` when the field is unset on the issue). For numeric fields, coerce in the template — `nil`/`""` become `0`:

```liquid
{% assign cost = issue.custom_field_value[20] | times: 1.0 %}
{% if cost > 0 %}Cost: {{ cost | round: 0 }}{% endif %}
```

Under the hood it reads `Issue#custom_field_value(id)` (Redmine's `Acts::Customizable`). See [`examples/version_status_dashboard.liquid`](examples/version_status_dashboard.liquid), which sets two field ids at the top (`cf_est_cost` / `cf_actual_cost`) and uses this accessor to drive a per-version budget bar, badge, KPI tile and chart.

## Exporting a report widget to PDF

Report widgets show an **Export as PDF** link in their header. It opens the same report the widget renders — for the widget's configured query — as a PDF in a new tab, reusing the Reporter plugin's own PDF generation. (PDF output requires wkhtmltopdf to be configured for Reporter, the same as Reporter's own report preview.)

## Charts in report templates (Chart.js in the PDF)

Reporter renders report PDFs through **wkhtmltopdf**, whose WebKit engine is from
around 2011: it has no ES2015 and no CSS flexbox. This plugin makes JavaScript
charts (Chart.js and friends) render in every Reporter PDF automatically — when a
report contains a `<canvas>`, it injects the ES2015 polyfills the old engine is
missing and adds a bounded wait so asynchronously-loaded chart scripts finish
before the page is captured. Chart-less reports are untouched (no delay).

Your template still has to stay within what that old engine can lay out. Follow
these four rules and a chart-heavy report renders the same in the browser and the
PDF:

1. **No flexbox** — `display:flex` collapses to a single column in the PDF. Use
   `inline-block`, `float`, or tables for multi-column layouts.
2. **Charts: `responsive: false` + an explicit `width`/`height` on the
   `<canvas>`** (e.g. `<canvas width="470" height="300">`). This is the one that
   most often bites: wkhtmltopdf's WebKit fires no resize events, so Chart.js
   `responsive: true` reads a container width of `0` and draws an **empty**
   canvas — the charts come out blank while everything around them renders. A
   fixed-size canvas renders reliably. Add `max-width:100%; height:auto` in CSS so
   the fixed-size canvas still scales down proportionally in a narrower on-screen
   column (e.g. a dashboard tile) while staying crisp at native size in the PDF.
3. **Disable animation** — `options.animation = { duration: 0 }` so wkhtmltopdf
   never snapshots a chart mid-animation (a blank/half-drawn canvas).
4. **Use Chart.js 2.8**, not 3/4 — the injected polyfills target what 2.8 needs;
   3/4 require far more modern JS. Chart.js is loaded from a CDN, so the Redmine
   host needs outbound access to it at PDF time (or host `Chart.min.js` locally
   and point your template at that URL).
5. **Wrap your chart JS in an IIFE** (`(function(){ … })();`) and avoid top-level
   `var` names that collide with window properties — `closed`, `open`, `name`,
   `top`, `status`, `length`. A global `var closed = [...]` silently fails
   (`window.closed` is a read-only boolean), so `closed[i]` becomes `undefined`
   and the data turns to `NaN`. Function scope avoids this entirely.

A complete, self-contained example that combines `{% sql_aggregate %}`,
`{% geo_version_map %}`, `issue.target_version` and a PDF-safe Chart.js chart is in
[`examples/sample_report_template.liquid`](examples/sample_report_template.liquid).

## Questions or issues?

Open an issue on [GitHub Issues](https://github.com/jcatrysse/redmine_reporter_dashboards/issues).

Contributing to the code? See [CONTRIBUTING.md](CONTRIBUTING.md) for the developer setup, test instructions and how the CI workflows work.

## License

Author: Jan Catrysse
