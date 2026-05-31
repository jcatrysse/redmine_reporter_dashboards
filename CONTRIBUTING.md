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

Supported Redmine versions: `5.1-stable`, `6.0-stable`, `6.1-stable`.

## Test suites

| Suite | Directory | Dependencies | What it covers |
|-------|-----------|--------------|----------------|
| **RSpec** | `spec/` | None | SQL aggregation code (standalone) |
| **minitest** | `test/` | Redmine + reporter | Dashboard controllers, models, helpers |

The RSpec specs run without `redmine_reporter` and without a database. The minitest suite boots the full Redmine app and requires reporter to be present.

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

Three parallel workflows live in `.github/workflows/`:

| File | Redmine version |
|------|-----------------|
| `rspec_minitest-51.yml` | 5.1-stable |
| `rspec_minitest-60.yml` | 6.0-stable |
| `rspec_minitest-61.yml` | 6.1-stable |

Each workflow:
1. Clones Redmine at the specified version
2. Checks out `redmine_reporter` using the `REPORTER_REPO_TOKEN` secret
3. Starts a PostgreSQL 16 service
4. Installs gems and migrates the database
5. Runs `spec/` (RSpec) and `test/` (minitest)

### Setting up `REPORTER_REPO_TOKEN`

1. Create a **fine-grained PAT** with `Contents: read` access to the `redmine_reporter` repo only.
2. Store it as the secret `REPORTER_REPO_TOKEN` on *this* repo (Settings → Secrets → Actions).
3. The secret is encrypted and never exposed in logs.

Adjust the `repository:` line in the workflow YAMLs if your reporter repo path differs.

### Triggering workflows manually

The workflows are set to `workflow_dispatch` — they only run when triggered manually via the GitHub Actions UI or the CLI:

```bash
gh workflow run rspec_minitest-51.yml
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
test/                 minitest suite (Redmine + reporter needed)
.github/workflows/    CI configuration
.codex/               Local / cloud-agent setup and test scripts
```
