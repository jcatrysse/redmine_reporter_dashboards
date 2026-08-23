# Template authoring

Writing report templates. A template is a [Liquid](https://shopify.github.io/liquid/)
document that the plugin renders against a project's issues or time entries, as a web page
and as a PDF.

- [The shape of a template](#the-shape-of-a-template)
- [`{% sql_aggregate %}` — counting in SQL](#-sql_aggregate---counting-in-sql)
- [Drill-through URLs](#drill-through-urls)
- [Reporting on spent time](#reporting-on-spent-time)
- [`{% version_rollup %}` — one row per version](#-version_rollup---one-row-per-version)
- [`{% chart %}` — charts](#-chart---charts)
- [`{% mermaid %}` — diagrams](#-mermaid---diagrams)
- [Reading issue data directly](#reading-issue-data-directly)
- [Limits](#limits)
- [Deprecated: `{% geo_version_map %}`](#deprecated--geo_version_map-)

## The shape of a template

Aggregate at the top, render below.

```liquid
{% sql_aggregate from: issues, group_by: status, drill: true, assign_to: by_status %}
{% sql_aggregate from: issues, period: month, periods: 6, assign_to: trend %}

<h1>{{ project.name }} — status</h1>

{% chart id: status, from: by_status, title: "Issues by status" %}
{% chart id: trend, from: trend, type: line, title: "Created and closed" %}

<table>
  {% for bucket in by_status.buckets %}
  <tr><td>{{ bucket.label }}</td><td>{{ bucket.count }}</td></tr>
  {% endfor %}
</table>

Total: {{ by_status.total }}
```

Start from a starter (**New from starter** in the editor) rather than a blank page. Press
**Preview** as you go — it renders what is in the box without saving.

### Why not just loop over issues?

You can, and for a per-issue document you should. But this:

```liquid
{% for issue in issues %}{% if issue.status == "Closed" %}…{% endif %}{% endfor %}
```

loads every issue as an object. Over a few thousand issues it is slow and memory-hungry. The
aggregation tags do the same counting in SQL — no issue objects, a fixed number of queries
regardless of how many issues match — and hand you the result as a Liquid variable.

Rule of thumb: **numbers about issues → aggregation tag. Text about each issue → a loop.**

### Escaping inside `<script>`

If you put a Liquid value inside a `<script>` block, pass it through `json`:

```liquid
<script type="application/json" id="data">{{ by_status.buckets | json }}</script>
```

Without it, a value containing a quote or a backslash breaks the token and kills the whole
script block — the chart silently disappears. The lint panel flags this.

You rarely need to: `{% chart %}` emits its own data block.

## `{% sql_aggregate %}` — counting in SQL

Two modes. Give it a `period:` and you get a time series; give it a `group_by:` and you get a
breakdown.

### Time series

```liquid
{% sql_aggregate from: issues, period: month, periods: 6,
   closed_statuses: "Closed;Rejected", assign_to: stats %}

| Month | Created | Closed |
|-------|---------|--------|
{% for i in (0..5) %}| {{ stats.labels[i] }} | {{ stats.created[i] }} | {{ stats.closed[i] }} |
{% endfor %}

Open now: {{ stats.open_now }} — total: {{ stats.total }}
```

| `period` | Default periods | Maximum |
|---|---|---|
| `day` | 30 | 90 |
| `week` | 13 | 52 |
| `month` (default) | 6 | 24 |
| `year` | 3 | 10 |

**Result keys:** `labels`, `created`, `closed`, `open_at_end`, `open_now`, `total`, `period`,
`periods`.

`open_at_end` is the backlog height — how many issues existed and were not yet closed at the
end of each period. A template cannot compute this itself; a running total of
`created - closed` is wrong for every issue that already existed when the window opened.

Two caveats on `open_at_end`:

- **A reopened issue counts as open until its last closing.** Redmine records only the most
  recent `closed_on`, so an issue closed in March, reopened in April and closed again in June
  counts as open for every period before June.
- **Time-series points carry no drill-through URL.** The set is "created on or before X *and*
  (still open *or* closed after X)", which a Redmine issue query cannot express. Use
  `group_by: period` if you want a clickable period chart.

### Breakdown

```liquid
{% sql_aggregate from: issues, group_by: assignee, sort: count, limit: 10, assign_to: by_who %}

{% for bucket in by_who.buckets %}
  {{ bucket.label }}: {{ bucket.count }}
{% endfor %}
```

**Result keys:** `buckets` (each with `label` and `count`), `total`, `group_by`. A breakdown
over a custom field or a pseudo-dimension adds `dimension`, `field_name`, `multi_value`,
`truncated`, and per bucket `value` (the raw stored value) and `filter`.

### Dimensions

`group_by` — and the second dimension `split_by` — accept:

| Value | Groups by |
|---|---|
| `status` `priority` `tracker` `category` | The obvious field |
| `assignee` `author` | A user |
| `version` | Target version |
| `cf_<id>` | An issue custom field by numeric id, e.g. `cf_92` |
| `period` | Date bucket — see `period` / `periods` / `date_field` |
| `age` | Age bucket — see `age_buckets` / `age_field` |
| `flags` | Scalar governance counters. `group_by` only |
| `completeness` | How much of a field list is filled in — see `fields` |

Custom fields resolve to their **labels**, not their stored values: Redmine stores an
enumeration field as an id, so grouping in Liquid would need a hardcoded id-to-label map.

**Custom field visibility is enforced.** If a field is restricted to certain roles, a viewer
without one of those roles does not see its values — their issues are still counted, but land
in the no-value bucket. A report can therefore be shared without leaking a restricted field.

A dimension that does not exist logs a warning and yields an empty result. It never raises, so
a typo cannot take down a dashboard or a PDF export.

### Parameters

| Parameter | Default | |
|---|---|---|
| `assign_to` | `stats` | Result variable name |
| `from` | `issues` | Liquid variable holding the issues drop |
| `query_id` | – | Aggregate a saved query instead |
| `group_by` | – | Dimension; switches to breakdown mode |
| `split_by` | – | Second dimension; needs `group_by`, produces a crosstab |
| `period` | `month` | `day` / `week` / `month` / `year` |
| `periods` | 30 / 13 / 6 / 3 | Capped at 90 / 52 / 24 / 10 |
| `date_field` | `created` | `created` or `closed` — what `period` buckets on |
| `closed_statuses` | – | Status **names**, `;` or `,` separated. Omit to use the `is_closed` flag |
| `sort` | `count` | `count` (desc), `label` (asc, natural), `position` (field order) |
| `limit` | `0` | Keep the top N; the rest collapses into one `Other` row |
| `other_label` | `Other` | Label of the collapsed row |
| `empty_label` | `(none)` | Label of the no-value row |
| `age_buckets` | `30;60;90;180` | Ascending day boundaries, max 24 |
| `age_field` | `created` | `created`, `updated` or `due` |
| `user_label` | `name` | `name` or `login`, for `assignee` / `author` |
| `fields` | – | Field list for `group_by: completeness`, max 12 |
| `measure` | `count` | `count`, `distinct`, `sum` or `avg` |
| `of` | – | Field the measure applies to |
| `drill` | `false` | `true` adds drill-through URLs |
| `drill_inherit` | `all` | `all` or `filters` — what a drill URL inherits |

An invalid value (`sort: banana`) falls back to the default and logs a warning.

### Quoted or unquoted

This matters and catches people out:

| You write | It means |
|---|---|
| `group_by: "user"` | The **text** `user` — never looked up |
| `group_by: user` | The **Liquid variable** `user`, falling back to the text `user` if no such variable exists |

Write dimensions unquoted, except `user` and `project` on a time-entry report — those are also
the names of variables every report assigns, so quote them.

### Measures

Every bucket is a count of issues unless you say otherwise.

| `measure` | Needs `of:` | |
|---|---|---|
| `count` | no | Issues per bucket. The default |
| `distinct` | yes | How many *different* values |
| `sum` | yes, numeric | Σ of the field |
| `avg` | yes, numeric | Mean, rounded to 2 decimals |

`of:` accepts `author`, `assignee`, `tracker`, `status`, `priority`, `category`, `version`,
`project` and `issue` (`distinct` only), the numeric columns `estimated_hours` and
`done_ratio`, `spent_hours` (`sum` only), and `cf_<id>`.

```liquid
{% sql_aggregate from: issues, group_by: period, period: month, periods: 12,
   measure: distinct, of: author, assign_to: filers %}

{% for b in filers.buckets %}{{ b.label }}: {{ b.count }} different people filed
{% endfor %}
```

### Crosstabs

`split_by` gives a second axis:

```liquid
{% sql_aggregate from: issues, group_by: assignee, split_by: status, assign_to: grid %}

<table>
  <tr><th></th>{% for s in grid.series %}<th>{{ s }}</th>{% endfor %}</tr>
  {% for row in grid.rows %}
  <tr><td>{{ row.label }}</td>{% for n in row.counts %}<td>{{ n }}</td>{% endfor %}</tr>
  {% endfor %}
</table>
```

**Result keys:** `series`, `series_entries`, `rows` (each with `label`, `total`, `counts`,
`cells`).

A crosstab feeds a stacked bar directly:

```liquid
{% sql_aggregate from: issues, group_by: assignee, split_by: priority,
   sort: count, limit: 8, drill: true, assign_to: workload %}

{% chart id: workload, from: workload, type: stacked_bar, orientation: horizontal,
   title: "Open work per person, by priority", x_title: "Issues" %}
```

### Ageing

```liquid
{% sql_aggregate from: issues, group_by: age, age_buckets: "7;30;90",
   age_field: updated, drill: true, assign_to: stale %}

{% chart id: stale, from: stale, title: "Time since last update" %}

{% for b in stale.buckets %}
  {{ b.label }}: {{ b.count }}
{% endfor %}
```

`age_field` picks which date ages: `created`, `updated` or `due`. Untouched-for-90-days is
`age_field: updated`; overdue-by-how-long is `age_field: due`.

### How complete is the data?

`group_by: completeness` counts how many of a named field list each issue has filled in:

```liquid
{% sql_aggregate from: issues, group_by: completeness,
   fields: "assigned_to;due_date;estimated_hours;cf_92", assign_to: filled %}

{% for b in filled.buckets %}
  {{ b.label }}: {{ b.count }} issues
{% endfor %}
```

Useful for a data-quality report: "how many issues have an owner, a date and an estimate".

## Drill-through URLs

`drill: true` turns every bucket, bar, slice, point and crosstab cell into a link to the
Redmine issue list, filtered to exactly the subset that element represents — inside the
report's own query.

```liquid
{% sql_aggregate from: issues, group_by: cf_92, drill: true, assign_to: by_dept %}

{% for b in by_dept.buckets %}
  {% if b.url %}<a href="{{ b.url }}">{{ b.label }}</a>{% else %}{{ b.label }}{% endif %}: {{ b.count }}
{% endfor %}
```

Clicking *Survey* in a Department chart opens the issue list showing the report's own issues,
narrowed to Department = Survey.

**The URL inherits everything** — the report query's filters, columns, grouping, totals and
sort order, plus the dimension filter. URLs are absolute and already percent-encoded; print
them with `{{ b.url }}`, no `escape` filter.

**Keys added by `drill: true`:**

| Key | |
|---|---|
| `.drill_available` | `true` when URLs were emitted |
| `.base_url` | The report query itself, unfiltered |
| `.buckets[].url` | One element URL, or `nil` |
| `.rows[].url` `.series_entries[].url` | Crosstab axes |
| `.cell_urls` | Rows × series, aligned with the matrix |
| `.drill_degraded` | `true` when a URL had to drop its columns to fit the length limit |

A chart picks these up automatically — `drill: true` on the aggregation is all you write.

## Reporting on spent time

A template has a **data source**. Set it to *Spent time* and the same tag with the same bucket
structure reports **hours** instead of issue counts.

```liquid
{% sql_aggregate group_by: activity, assign_to: by_activity %}

{% for bucket in by_activity.buckets %}
- {{ bucket.label }}: {{ bucket.count }} h
{% endfor %}
Total: {{ by_activity.total }} h
```

`bucket.count` carries the measure, which is hours here — the same key an issue report uses,
so a template written against one source reads the other.

**`from:` is not used.** The scope comes from the template's source and the saved query on the
page. Use `query_id:` to point at a saved *spent-time* query.

| On the entry itself | Through the entry's issue |
|---|---|
| `activity` · `"user"` · `"project"` · `issue` | `tracker` · `status` · `version` · `category` |

The four on the right need the entry joined to its issue, which a saved spent-time query
provides. Without one they are refused and the page says so rather than reporting a wrong
number.

`priority`, `author` and `assignee` are not available. `author` is the trap: `author_id` *is*
a spent-time filter and it means **who recorded the entry**, not the issue's author, so a
drill-through built from it would land on a plausible, wrong set of rows.

An hours-by-issue axis names each issue `#42: subject`. **An issue you may not see is named
`#42` and nothing else** — the hours are yours to count, the subject is not yours to read.

A monthly timesheet by person:

```liquid
{% sql_aggregate group_by: "user", split_by: activity, assign_to: sheet %}

<table>
  <tr><th>Person</th>{% for a in sheet.series %}<th>{{ a }}</th>{% endfor %}<th>Total</th></tr>
  {% for row in sheet.rows %}
  <tr>
    <td>{{ row.label }}</td>
    {% for hours in row.counts %}<td>{{ hours }}</td>{% endfor %}
    <td>{{ row.total }}</td>
  </tr>
  {% endfor %}
</table>

Total logged: {{ sheet.total }} h
```

## `{% version_rollup %}` — one row per version

A per-target-version rollup computed in SQL. Use it instead of a nested
`{% for version %}{% for issue %}` loop, which costs `O(versions × issues)`.

```liquid
{% version_rollup from: issues, closed_statuses: "Closed;Rejected",
   cost_fields: "20,21", assign_to: versions %}

{% for v in versions %}
  <h3><a href="{{ v.version.url }}">{{ v.name }}</a></h3>
  {{ v.open }} open / {{ v.closed }} closed · {{ v.spent_hours }} / {{ v.est_hours }} h
{% endfor %}
```

Parameters: `from` (default `issues`), `closed_statuses`, `cost_fields` (numeric custom field
ids to sum), `assign_to` (default `versions`).

One row per version, sorted by name, with a `None` row for issues with no target version:

| Key | |
|---|---|
| `.name` | Version name, or `None` |
| `.version` | The version object with `.url`, `.roadmap_url`, `.issues_url`; `nil` for `None` |
| `.total` `.open` `.closed` | Counts |
| `.open_done_sum` | Σ `done_ratio` over open issues, for a % complete bar |
| `.overdue_open` `.unassigned_open` `.no_estimate` | Flag counts |
| `.est_hours` `.spent_hours` | Σ hours |
| `.start_date` `.due_date` | MIN start / MAX due |
| `.cost` | `{ "<field_id>" => float }` per numeric custom field |

A release dashboard with a progress bar per version:

```liquid
{% version_rollup from: issues, assign_to: versions %}

{% for v in versions %}
  {% if v.total > 0 %}
    <h3>{{ v.name }} — {{ v.closed }} / {{ v.total }} done</h3>
    <p>
      {{ v.spent_hours }} h spent of {{ v.est_hours }} h estimated
      {% if v.overdue_open > 0 %} · {{ v.overdue_open }} overdue{% endif %}
      {% if v.unassigned_open > 0 %} · {{ v.unassigned_open }} unassigned{% endif %}
    </p>
  {% endif %}
{% endfor %}
```

See [`starters/version-status.liquid`](../starters/version-status.liquid).

## `{% chart %}` — charts

Point it at anything an aggregation tag assigned:

```liquid
{% sql_aggregate from: issues, group_by: status, drill: true, assign_to: by_status %}
{% chart id: status, from: by_status, title: "Issues by status", y_title: "Issues" %}
```

That is the whole chart. No `<canvas>`, no `<script>`, no Chart.js config, no data array.

| Parameter | |
|---|---|
| `id` | Required. Letters, digits, `_`, `-`. It becomes a DOM id; two charts sharing one is refused |
| `from` | The variable holding the result (default `stats`) |
| `type` | `bar` (default), `stacked_bar`, `diverging_stacked_bar`, `line`, `pie`, `doughnut`, `progress` |
| `orientation` | `vertical` (default) or `horizontal` |
| `title` `x_title` `y_title` | Text |
| `width` `height` | Pixels, default 640 × 360 |
| `x` `y` | Which keys to read. For a breakdown, `y` is the bucket key. For a time series, a comma-separated list — `created,closed` by default |
| `legend` | `true` / `false`. Left alone, it shows when there is more than one series |

### The two outputs

| | On screen | In a PDF |
|---|---|---|
| Element | `<canvas>` + a JSON data block | inline `<svg>` |
| Drawn by | Chart.js 4, bundled | The server, in Ruby |
| JavaScript | yes | none |
| Drill-through | click handler | real links — a PDF chart is clickable |
| Text | canvas pixels + an `aria-label` | selectable, with `<title>` / `<desc>` |

Everything the geometry depends on — value range, ticks, palette, label truncation, plot
rectangle — is computed once on the server and handed to both paths, so the two agree.

### Accessibility

Charts are readable without being seen. Every SVG carries a `<title>` and `<desc>` with the
numbers; every canvas carries the same sentence as an `aria-label`. The palette is the
Okabe–Ito set designed for the three common colour-vision deficiencies, and every fill has a
darker outline so two adjacent bars stay two bars in a greyscale print. Meaning is never
carried by colour alone.

## `{% mermaid %}` — diagrams

```liquid
{% mermaid id: approval %}
graph LR
  A[Submitted] --> B{Approved?}
  B -->|yes| C[Scheduled]
  B -->|no| A
{% endmermaid %}
```

Mermaid 11 ships inside the plugin. In a PDF the diagram is real vector graphics: selectable,
searchable, printable at any size.

**The body is not interpreted.** Mermaid syntax is full of `{`, `}` and `|`, which a template
language would otherwise read as its own markup. Write ordinary Mermaid.

| Parameter | Default | |
|---|---|---|
| `id` | `mermaid` | Identifies the diagram in the page |
| `interpolate` | `false` | Allows `{{ value }}` in the diagram |

With `interpolate: true`, `{{ something }}` is substituted — but `{% if %}` and `{% for %}` are
not run and filters are not applied. Build the text above the tag and interpolate one variable
if you need logic. Substituted values are escaped, because an issue subject is written by
whoever wrote the issue.

**When a diagram cannot be drawn** you get the diagram source, marked as undrawn — never a
blank space. That happens on wkhtmltopdf, which reports having JavaScript and cannot run any
library written in the last several years. The fix is to switch engines, not to change the
template.

A diagram over 16 KB of source is refused rather than spending the render budget on a drawing
nobody can read.

### Other JavaScript libraries

Nothing above is specific to Mermaid. Reference any library like any other asset — it is
embedded in the document — and tell the renderer to wait for it with `window.__rd.begin()` and
`window.__rd.end()` around your drawing code. Chart.js and Mermaid ship with the plugin
because they are the common cases, not because they are the only ones supported.

## Reading issue data directly

For a per-issue document, loop:

```liquid
{% for issue in issues %}
  <h2>#{{ issue.id }} {{ issue.subject }}</h2>
  {% if issue.target_version %}
    Version: <a href="{{ issue.target_version.url }}">{{ issue.target_version.name }}</a>
  {% endif %}
  {% assign cost = issue.custom_field_value[20] %}
  {% if cost %}Cost: {{ cost }}{% endif %}
{% endfor %}
```

`issue.target_version` is `nil` when there is none, so guard it. All its URLs are absolute, so
they survive export to PDF.

`issue.custom_field_value[id]` reads a custom field by numeric id. Assign the ids once at the
top of the template rather than repeating literals, so a template moved to another install has
one line to change. For per-version cost totals prefer `{% version_rollup %}`'s `.cost` — it
sums in SQL, where this accessor reads one issue at a time.

A per-issue document with a summary on top:

```liquid
{% sql_aggregate from: issues, group_by: tracker, assign_to: by_tracker %}

<h1>{{ project.name }} — open work</h1>
<p>{{ by_tracker.total }} issues:
{% for b in by_tracker.buckets %}{{ b.count }} {{ b.label }}{% unless forloop.last %}, {% endunless %}{% endfor %}
</p>

{% for issue in issues %}
  <h2>#{{ issue.id }} — {{ issue.subject }}</h2>
  <p>
    {{ issue.tracker }} · {{ issue.status }} · {{ issue.priority }}
    {% if issue.assigned_to %} · {{ issue.assigned_to }}{% endif %}
    {% if issue.due_date %} · due {{ issue.due_date }}{% endif %}
  </p>
{% endfor %}
```

Every object and accessor a template can read is listed in
[the drop reference](drop-reference.md), which is generated from the code.

## Limits

Templates are bounded, and hitting a bound is a visible refusal with a correlation ID — never
a report that quietly covers less than it says.

| | |
|---|---|
| Collections | `.all` on a collection is refused. Aggregate instead |
| Crosstab cells | 5 000; past it drill URLs are dropped |
| Breakdown rows | 200, then the rest collapses into `Other` |
| Diagram source | 16 KB |
| Mail attachments | 10 MB total |
| Execution time and output size | Bounded per render; the message names which limit |

A report reports on issues **or** time entries, never both.

## Deprecated: `{% geo_version_map %}`

It existed because the old issue drop exposed `issue.version` as a name only, with no id,
which made version-filtered URLs impossible to build from a template.

`issue.target_version` and `{% version_rollup %}` answer all of that directly. The tag still
works, logs one deprecation line per process, and the linter flags it. **It is removed in the
next minor version.** Replace it with `issue.target_version`.
