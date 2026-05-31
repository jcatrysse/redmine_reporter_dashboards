# Redmine Reporter Dashboards

A dashboard extension for the [Redmine Reporter](https://www.redmineup.com/pages/plugins/reporter) plugin. Adds configurable project dashboards and replaces slow Liquid loops in report templates with fast SQL aggregations.

## What does it do?

### Project dashboards

Each project gets its own dashboard page with tabs. Drag widgets into position or stack multiple tabs side by side:

- **Issues** — a filtered issue list driven by a saved query
- **Report** — a Reporter report block embedded directly on the dashboard
- **Activity**, **Calendar**, **News**, **Documents**, **Time log**

Each tab is configured independently per project and per role.

### `{% sql_aggregate %}` Liquid tag

The standard Liquid approach in Reporter templates iterates over all issues as objects:

```liquid
{% for issue in issues %}...{% endfor %}
```

With hundreds or thousands of issues that gets slow. The `{% sql_aggregate %}` tag does the same work entirely in SQL — no Issue objects loaded, no memory pressure — and returns the result as a Liquid variable you can use directly in your template.

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

## Questions or issues?

Open an issue on [GitHub Issues](https://github.com/jcatrysse/redmine_reporter_dashboards/issues).

Contributing to the code? See [CONTRIBUTING.md](CONTRIBUTING.md) for the developer setup, test instructions and how the CI workflows work.

## License

Author: Jan Catrysse
