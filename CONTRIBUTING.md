# Contributing

## Development setup

The plugin has two hard dependencies:

- **Redmine** — a checkout is needed to run the minitest suite
- **redmine_reporter** — a private plugin; see below for how to make it available

### Local

The `.codex/` scripts handle everything:

```bash
./.codex/redmine_clone.sh 5.1-stable   # clone Redmine + copy plugins
./.codex/test_setup.sh                  # configure database and install gems
./.codex/test_plugin.sh                 # run RSpec + minitest
```

Supported Redmine versions: `5.1-stable`, `6.0-stable`, `6.1-stable`,
`7.0-stable` — see the support matrix in the README. `requires_redmine` is pinned
to 5.1 so the plugin's claim matches what CI exercises; widening it means adding
the branch to the matrix in `.github/workflows/ci.yml` first.

`test_setup.sh` provisions PostgreSQL by default. Pass `RRD_DB=mysql` or
`RRD_DB=mariadb` for the other supported engines — the Debian packages conflict,
so only one of the two can be installed at a time.

## Test suites

| Suite | Directory | Dependencies | What it covers |
|-------|-----------|--------------|----------------|
| **RSpec** | `spec/` | None | SQL aggregation code (standalone) |
| **adapter execution** | `spec/adapter/` | A PostgreSQL or MySQL/MariaDB server | The aggregator's SQL actually run against a real engine |
| **minitest** | `test/unit`, `test/functional`, `test/integration` | Redmine + reporter | Dashboard controllers, models, helpers, and the HTTP verb of every route |

The RSpec specs run without `redmine_reporter` and without a database. The minitest suite boots the full Redmine app and requires reporter to be present.

`spec/adapter/` is the exception to "no database". It loads the real ActiveRecord,
recreates a small schema and runs the aggregator for real, so it always runs as its
own `rspec` invocation — `test_plugin.sh` excludes it from the main run and then
executes it separately when a URL is available. It skips with an explanatory message
unless `RRD_ADAPTER_URL` is set (`test_setup.sh` writes one to
`redmine/.rrd_adapter_url`), and it refuses any URL whose database name does not
contain `test`, because it drops and recreates every table.

### Ruby version floor

Redmine 5.1 runs on Ruby 2.7, so the plugin's own code has to parse under 2.7 —
including the specs. `./.codex/check_ruby_floor.sh` greps for the constructs that
floor rules out (endless method definitions, `Hash#except`, hash value omission) and
runs in CI.

## The `redmine_reporter` dependency

`redmine_reporter` is a private plugin. Only *fetching it over the network onto a fresh machine* requires a credential. If a checkout already exists next to this plugin, everything works without any configuration.

| Environment | How reporter is provided | Credential needed? |
|-------------|--------------------------|-------------------|
| Local | `redmine_clone.sh` copies the sibling `../redmine_reporter` directory (rsync, no git) | No |
| Cloud agent with reporter pre-seeded | sibling checkout or `REPORTER_PLUGIN_PATH` | No |
| Cloud agent without reporter | a setup step must clone reporter | Yes |
| GitHub Actions | `actions/checkout` of the private repo | Yes — `REPORTER_REPO_TOKEN` secret |

**Point the script at a specific reporter checkout:**

```bash
# Default: ../redmine_reporter is detected automatically.
./.codex/redmine_clone.sh 5.1-stable

# Or point REPORTER_PLUGIN_PATH at any path:
REPORTER_PLUGIN_PATH=/abs/path/to/redmine_reporter ./.codex/redmine_clone.sh 5.1-stable
```

**When reporter is missing — script behaviour:**

If reporter is not found, `redmine_clone.sh` prints a warning and continues. The scripts then run only the standalone RSpec specs and skip the minitest suite. To enforce the full suite:

```bash
REQUIRE_REPORTER_PLUGIN=1 ./.codex/test_setup.sh
REQUIRE_REPORTER_PLUGIN=1 ./.codex/test_plugin.sh
```

`CI=true` enables this strict mode automatically. Set `REQUIRE_REPORTER_PLUGIN=0` only for an intentional standalone-spec run.

**Cloud agent that must fetch reporter itself:**

```bash
gh repo clone jcatrysse/redmine_reporter ../redmine_reporter
```

Prefer platform authentication, a deploy key, or a masked secret — avoid pasting a token into shell history.

## GitHub Actions

One workflow, `.github/workflows/ci.yml`, running on every push and pull request.
It has four jobs, split by what each one actually needs:

| Job | Matrix | Needs a database? | Needs `redmine_reporter`? |
|-----|--------|-------------------|---------------------------|
| `rspec` | Redmine 5.1 / 6.0 / 6.1 / 7.0 | No | No |
| `adapter` | PostgreSQL 16, MySQL 8.0, MariaDB 11 | Yes (service container) | No |
| `minitest` | Redmine 5.1 / 6.0 / 6.1 / 7.0 | PostgreSQL 16 | **Yes** |
| `ruby-floor` | — | No | No |

That split is the point. The three workflows this replaced were
`workflow_dispatch`-only because each of them checked out the private
`redmine_reporter` plugin before running anything, and a fork pull request cannot
read `secrets.REPORTER_REPO_TOKEN` — so `on: pull_request` would have made every
outside contribution red. Only `minitest` needs that secret now, and a
`reporter-secret` job checks whether it is readable so `minitest` is *skipped*
rather than failed when it is not.

### Setting up `REPORTER_REPO_TOKEN`

1. Create a **fine-grained PAT** with `Contents: read` access to the `redmine_reporter` repo only.
2. Store it as the secret `REPORTER_REPO_TOKEN` on *this* repo (Settings → Secrets → Actions).
3. The secret is encrypted and never exposed in logs.

Adjust the `repository:` line in the `minitest` job if your reporter repo path differs.

### Triggering the workflow manually

```bash
gh workflow run ci.yml
```

## Architecture overview

```
app/
  controllers/        Dashboard and SQL stats controllers
  models/             ReporterProjectTab (layout + settings stored as YAML)
  views/              ERB templates for dashboard UI and blocks
lib/
  sql_aggregation/
    liquid_aggregate_tag.rb   Liquid tag implementation
    query_aggregator.rb       Pure-SQL aggregations (time series + breakdown)
  redmine_reporter_dashboards/
    patches/          Overlays on Reporter without modifying the vendor plugin
    project_page.rb   Block registry
spec/                 RSpec specs (standalone, no Redmine needed)
  adapter/            The aggregator's SQL run against a real PostgreSQL / MySQL server
test/                 minitest suite (Redmine + reporter needed)
  integration/        Route verbs — a controller test does not check them
.github/workflows/    CI configuration (one workflow, ci.yml)
.codex/               Local / cloud-agent setup and test scripts
```
