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

## Requirements

- Redmine 5.0 or higher
- `redmine_reporter` plugin version 2.0.5 or higher

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

Supported `group_by` values:

| Value | Groups by |
|-------|-----------|
| `status` | Issue status |
| `priority` | Priority |
| `tracker` | Tracker |
| `assignee` | Assigned user |
| `author` | Author |
| `category` | Category |
| `version` | Target version |

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
