# Redmine Reporter Dashboards

Dashboard extension for the [Redmine Reporter](https://www.redmineup.com/pages/plugins/reporter)
plugin, adding:

- **Project dashboards** — configurable, tabbed dashboard pages per project with
  drag-and-drop blocks (issues, news, documents, calendar, time log, activity,
  saved queries and report blocks).
- **SQL statistics** — a fast pure-SQL issue flow aggregator and a
  `sql/stats/monthly_flow` JSON endpoint.
- **`{% sql_aggregate %}` Liquid tag** — server-side SQL aggregation for report
  templates, replacing expensive `{% for issue in issues %}` loops. The legacy
  name **`{% geo_aggregate %}`** keeps working as an alias.

It also carries a few performance/quality patches that re-apply, as overlays, the
fixes that previously lived inside the reporter plugin so that **the third-party
`redmine_reporter` plugin can stay pristine** and receive vendor updates cleanly.

## Requirements

- Redmine 5.0 or higher
- `redmine_reporter` plugin, version 2.0.5 or higher (hard dependency — this
  plugin will refuse to load without it)

## Installation

```bash
cd {REDMINE_ROOT}/plugins
git clone https://github.com/jcatrysse/redmine_reporter_dashboards.git
cd {REDMINE_ROOT}
bundle install
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

Restart Redmine afterwards.

## Enabling the dashboard for a project

The dashboard is a standard Redmine project module. The reporter performance
patches, SQL statistics endpoint and Liquid aggregation tag are plugin-wide and
remain active regardless of whether a specific project enables the dashboard
module.

1. Open **Project → Settings → Modules** and enable **Project dashboard** for the
   project.
2. Grant the `view_reporter_project_page` / `manage_reporter_project_page` /
   `manage_reporter_project_tabs` permissions to the relevant roles.
3. A **Project dashboard** entry appears in the project menu. The first visit
   creates the default dashboard tab automatically when no tab exists yet.

Existing installations that used the previous **Project dashboard** settings tab
can manually enable the new project module on the few projects that should keep
using dashboards; no data migration is required for the dashboard tabs/widgets
already stored by this plugin.

## Testing

The `.codex/` scripts spin up a Redmine checkout and run the suite. Because this
plugin depends on `redmine_reporter`, provide a reporter checkout alongside (a
sibling `../redmine_reporter` directory is picked up automatically, or set
`REPORTER_PLUGIN_PATH`):

```bash
./.codex/redmine_clone.sh 5.1-stable
./.codex/test_setup.sh
./.codex/test_plugin.sh
```

- The **RSpec** specs (`spec/`) cover the SQL aggregation code and run standalone —
  they need neither `redmine_reporter` nor any credential.
- The **minitest** suite (`test/`) covers the dashboard controllers/models/helper
  and boots the full Redmine app, so it needs `redmine_reporter` installed.

### Providing the `redmine_reporter` dependency

`redmine_reporter` is a private hard dependency. The only thing that ever needs a
credential is *fetching it over the network into a fresh machine*. Wherever a
checkout is already on disk next to this plugin, setup is zero-config.

| Environment | How reporter is provided | Credential needed |
| --- | --- | --- |
| **Local** | `redmine_clone.sh` copies the sibling `../redmine_reporter` (rsync, no git) | No |
| **Cloud agent** (Codex / Claude Code) with reporter pre-seeded | sibling checkout, or `REPORTER_PLUGIN_PATH` | No |
| **Cloud agent** with only this repo checked out | a setup step must clone reporter | Yes (token / platform auth) |
| **GitHub Actions** | `actions/checkout` of the private repo | Yes — `REPORTER_REPO_TOKEN` secret |

**Local / cloud — point the script at any reporter checkout:**

```bash
# Default: a sibling directory ../redmine_reporter is detected automatically.
./.codex/redmine_clone.sh 5.1-stable

# Or place reporter anywhere and point REPORTER_PLUGIN_PATH at it:
REPORTER_PLUGIN_PATH=/abs/path/to/redmine_reporter ./.codex/redmine_clone.sh 5.1-stable
```

If reporter is not found, `redmine_clone.sh` prints a warning and continues. The
`.codex` setup/test scripts then run the standalone RSpec specs and skip the
minitest suite that boots Redmine, unless full dependency enforcement is enabled:

```bash
# Fail instead of skipping when redmine_reporter is missing.
REQUIRE_REPORTER_PLUGIN=1 ./.codex/test_setup.sh
REQUIRE_REPORTER_PLUGIN=1 ./.codex/test_plugin.sh
```

`CI=true` also enables this strict mode by default; set
`REQUIRE_REPORTER_PLUGIN=0` only for an intentional standalone-spec run.

**Cloud agent that must fetch reporter** — add a setup step before the test
scripts that clones it next to this plugin using a read-only credential provided
by the platform. Prefer platform authentication, a deploy key, or a masked secret
instead of pasting a token into shell history. For example, after authenticating
with GitHub CLI:

```bash
gh repo clone jcatrysse/redmine_reporter ../redmine_reporter
```

**GitHub Actions** — create a fine-grained PAT (or deploy key) with read-only
`Contents` access to `redmine_reporter`, store it on *this* repo as the
`REPORTER_REPO_TOKEN` secret, and the workflows check reporter out automatically.
The secret is encrypted and never exposed in the public source. Adjust the
`repository:` line in `.github/workflows/*.yml` if your reporter repo path differs.

## License

Author: Jan Catrysse
