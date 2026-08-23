# Contributing

## Development setup

> **Do not run `bundle` in this checkout.** The `Gemfile` here declares the plugin's gems
> for *Redmine's* bundle and deliberately has no `source` line — Redmine's own `Gemfile`
> supplies one when it evaluates plugin Gemfiles. Run Bundler here and you get
> `bundler: command not found: rspec`, then `Could not find gem 'liquid (>= 4.0, < 6.0)'
> in locally installed gems` from `bundle install`: a source-less Gemfile resolves against
> installed gems only. That looks like a broken suite and is not one, and adding a
> `source` or committing a lockfile to make it go away would break the real bundle. Use
> the `.codex/` scripts below, which run every suite the way CI does.

The plugin has one hard dependency:

- **Redmine** — a checkout is needed to run the minitest suite

`redmine_reporter` is **optional**. The plugin is standalone: nothing here requires it at
runtime, and both the RSpec and minitest suites run without it — which is the
configuration CI proves. It matters only for the migration/import path and for four
report-widget tests, which skip with a reason when it is absent. See
[The `redmine_reporter` dependency — optional](#the-redmine_reporter-dependency--optional)
below if you need it available.

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
| **minitest** | `test/unit`, `test/functional`, `test/integration` | Redmine (reporter optional) | Dashboard controllers, models, helpers, the HTTP verb of every route, and the golden scope fixture |
| **system (browser)** | `test/system/` | Redmine, a database, **Chrome and a matching chromedriver** | The primary journeys in a real browser: the Preview button's form submission, the scripts that reveal the chart form and the settings box, and the `data-method` / `data-confirm` controls. Opt-in locally (`RRD_SYSTEM_TESTS=1`); CI runs it on 5.1 and 7.0 |
| **golden corpus** | `spec/golden/`, verified by `spec/adapter/aggregation_corpus_spec.rb` | A database **and** `RRD_REFERENCE_DATE` | That the aggregation numbers have not moved — gate G7's differential |
| **R7 invariants** | `spec/adapter/performance_invariants_spec.rb` | A database | Query count independent of issue count, zero issue instantiation, bounded output — asserted hard, every run |
| **the importer survey** | `spec/template_linter_spec.rb`, `spec/import/`, `spec/adapter/import_survey_spec.rb` | The last one needs a database | The template linter's rules, the report's copy and bounds, and that `import:plan` issues nothing but `SELECT` |
| **performance baseline** | `spec/golden/performance/`, measured by `spec/adapter/performance_baseline_spec.rb` | A database, `RRD_REFERENCE_DATE` **and** `RRD_BENCH=1` | The timings the re-seam will be compared against. Opt-in, ~3 minutes, and it asserts no timing |

The RSpec specs run without `redmine_reporter` and without a database. The minitest
suite boots the full Redmine app; since reporter became optional it runs **standalone**,
which is the configuration CI proves, and four report-widget tests skip with a reason
when reporter is absent.

### The browser suite

`test/system/` is opt-in locally, because it needs a browser and a matching driver that
`test_setup.sh` does not install. `test_plugin.sh` prints one line saying it did not run
them rather than quietly running a smaller suite.

```bash
RRD_SYSTEM_TESTS=1 ./.codex/test_plugin.sh
```

Two environment variables shape it, and both exist because a browser is the runner's
business rather than the test's:

- **`GOOGLE_CHROME_OPTS_ARGS`** — Redmine's own variable, comma-delimited. `test_plugin.sh`
  defaults it to `--headless=new,--no-sandbox,--disable-dev-shm-usage,--disable-gpu`, which
  is what a container running as root needs. Set it yourself to keep the sandbox.
- **`RRD_CHROME_PATH`** — where the browser is, when it is not where chromedriver looks.
  Without it a container holding Chrome for Testing in a cache fails every example with
  `unknown error: cannot find Chrome binary`, which reads like a broken suite and is not one.

If Selenium warns that the chromedriver in `PATH` does not match the browser, take that
driver off `PATH` and let Selenium Manager fetch the matching one.

**A recipe that works in a bare container, measured 2026-08-21 on Redmine 7.0 / Rails 8.1
(12 of 12 examples green), and the two things it gets right.** Both are the reason the
naive version fails:

```bash
# 1. A MATCHED PAIR. Chrome and chromedriver must agree on the MAJOR version. A
#    container that has both usually has them from different sources — here it was
#    Playwright's Chromium 141 and npm's chromedriver 147, six majors apart, which
#    reports as `cannot find Chrome binary` / `session not created` and reads like a
#    broken suite.
curl -s https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json
#    take the Stable channel's `chrome` and `chromedriver` linux64 URLs, unzip both, then
ln -sf /opt/cft/chromedriver-linux64/chromedriver /usr/local/bin/chromedriver

# 2. A NON-ROOT USER, rather than `--no-sandbox`. Chrome refuses to start as root
#    without that flag, and the flag turns off the one control that contains a
#    compromised renderer. A user costs three lines.
useradd -m -u 4242 rrdtest
chmod a+rX /path/to/plugin /path/to/plugin/redmine
chown -R rrdtest redmine/tmp redmine/log redmine/files

su rrdtest -c 'export HOME=/home/rrdtest RAILS_ENV=test \
  RRD_CHROME_PATH=/opt/cft/chrome-linux64/chrome \
  GOOGLE_CHROME_OPTS_ARGS="--headless=new,--disable-gpu,--disable-dev-shm-usage" && \
  cd redmine && bundle exec rails test plugins/<name>/test/system'
```

The `dbus` errors Chrome prints on start-up in a container are noise; the run is green
with them present.

`spec/adapter/` is the exception to "no database". It loads the real ActiveRecord,
recreates a small schema and runs the aggregator for real, so it always runs as its
own `rspec` invocation — `test_plugin.sh` excludes it from the main run and then
executes it separately when a URL is available. It skips with an explanatory message
unless `RRD_ADAPTER_URL` is set (`test_setup.sh` writes one to
`redmine/.rrd_adapter_url`), and it refuses any URL whose database name does not
contain `test`, because it drops and recreates every table.

### The golden oracle

`spec/golden/README.md` is the page to read before touching anything in that directory.
In short: the aggregation numbers and the resolved scopes are frozen there so the
decoupling sequence can prove it changed neither, the corpus **refuses to run without a
pinned reference date**, and the scope fixture is the one artefact that cannot be
regenerated once `scope_resolution.rb` is deleted.

The corpus is verified, not generated, by `test_plugin.sh` and by CI. It is generated
only deliberately, with `RRD_CORPUS_WRITE=1` — and a difference is a finding to explain,
never a file to bring into line.

### The template linter

`RedmineReporterDashboards::TemplateLinter` is one rule table with two outputs, and the
split is the design: **findings** are things that will break (each with a line number,
because FR-71 puts this same linter behind the editor's lint panel) and **usage** is
what a template depends on (the evidence for which vendor accessors the owned drop layer
has to reproduce). A dependency reported as a defect is how a linter loses its readers.

Two conventions to keep when adding a rule:

- **Declare its scope.** A JS rule searches `<script>` bodies, a usage marker searches
  Liquid expressions. `legend:` in a stylesheet is not a Chart.js option and `color:` in
  CSS is not `issue.color`; scope removes those false positives outright.
- **Cite the evidence.** Every rule names the spec line or verification document that
  established it. The Chart.js list is the six migrations `technical-spec.md` §6
  enumerated *from the shipped examples* — it grows on evidence, not on intuition,
  because one false positive costs more credibility than one miss costs work.

Where a pattern genuinely cannot decide, the rule is a `:warning` and its **message says
so**. Two Chart.js keys are in that position; `suppressed_by` is how one of them asks a
question about the surrounding script instead of guessing.

### The performance baseline

Same directory, opposite kind of file. `spec/golden/performance/baseline.json` is a
**measurement**, not an oracle: nothing asserts a millisecond figure, because no tolerance
has been decided and a red/green verdict on a timing would be a number this project
invented on hardware it does not control. The benchmark prints its drift against the
committed artefact labelled *advisory*.

The parts of the performance requirement that *are* falsifiable — query count independent
of issue count, zero issue-object instantiation, bounded output — are ordinary assertions in
`spec/adapter/performance_invariants_spec.rb` and run on every engine on every adapter run.
The benchmark itself is opt-in (`RRD_BENCH=1`), takes about three minutes and seeds 100 000
issues; `spec/golden/README.md` has the commands and the knobs.

### Ruby version floor

Redmine 5.1 runs on Ruby 2.7, so the plugin's own code has to parse under 2.7 —
including the specs. `./.codex/check_ruby_floor.sh` greps for the constructs that
floor rules out (endless method definitions, `Hash#except`, hash value omission) and
runs in CI.

### Run under a UTF-8 locale

`./.codex/test_plugin.sh` sets `LANG=C.UTF-8` when it is unset, and if you invoke `rspec`
or `rake` yourself you want the same. With `LANG` and `LC_ALL` unset — the default in a
container — Ruby's `Encoding.default_external` is **US-ASCII**, and every spec that hands a
non-ASCII string to `JSON.parse` fails with

    Encoding::InvalidByteSequenceError: "\xE2" on US-ASCII

`spec_liquid/escaping_regression_spec.rb`'s U+2028 and U+2029 payloads are the three that
trip on it. It reads as a lost byte in the code under test; it is the shell. GitHub runners
set `LANG=C.UTF-8`, so CI cannot warn you.

## The `redmine_reporter` dependency — optional

**You do not need it.** Clone this repository, run the scripts, and the whole suite
runs: the plugin boots on a plain Redmine, and CI runs its full test suite that way
on every pull request, including one from a fork.

It used to be a hard dependency enforced by a `raise` in `init.rb`, which meant no
outside contributor could run — or have CI run — the functional tests at all.

What still needs it is the two **report widgets** and their PDF export, because those
render one of Reporter's own report templates. Their four functional tests `skip` with
a reason when it is absent, so the number is visible rather than the coverage being
silently smaller.

| Environment | Reporter provided how | Credential? |
|-------------|-----------------------|-------------|
| Local, standalone | nothing to do | No |
| Local, with reporter | `redmine_clone.sh` copies the sibling `../redmine_reporter`, or `REPORTER_PLUGIN_PATH` | No |
| GitHub Actions | **not at all, deliberately** — see below | **No** |

**Running the reporter-present configuration locally**, if you have a checkout:

```bash
# Default: ../redmine_reporter is detected automatically.
./.codex/redmine_clone.sh 6.1-stable

# Or point it anywhere:
REPORTER_PLUGIN_PATH=/abs/path/to/redmine_reporter ./.codex/redmine_clone.sh 6.1-stable
```

`REQUIRE_REPORTER_PLUGIN=1` makes the scripts **fail** if reporter is missing — use it
when you mean to test that configuration and want a missing checkout to be an error
rather than a quietly different run. It no longer decides whether the full-app tests
run at all: they run either way, because the standalone configuration is the one most
worth exercising.

## GitHub Actions

One workflow, `.github/workflows/ci.yml`, on every push and pull request.

**No job needs a secret.** That is the headline, and it is what makes an outside
contribution testable:

| Job | Matrix | Database | Needs `redmine_reporter`? |
|-----|--------|----------|---------------------------|
| `rspec` | Redmine 5.1 / 6.0 / 6.1 / 7.0 | No | No |
| `adapter` | PostgreSQL 16, MySQL 8.0, MariaDB 11 | Yes (service container) | No |
| `minitest` | Redmine 5.1 / 6.0 / 6.1 / 7.0 | PostgreSQL 16 | **No — asserts its absence** |
| `baseline` | — | No | No |
| `gates` | — | No | No |
| `ruby-floor` | — | No | No |

### Why there is no longer a `REPORTER_REPO_TOKEN`

The `minitest` job used to check out the private `redmine_reporter` repository with
`secrets.REPORTER_REPO_TOKEN`. A fork pull request cannot read a secret, so a
`reporter-secret` probe job decided whether `minitest` ran — and on every outside
contribution it did not. The suite was *skipped*, and a skipped job is
indistinguishable from a passing one at a glance.

The secret, the probe job and the private checkout step are all deleted.
`script/gates/no_secrets.sh` fails the build on any secret other than `GITHUB_TOKEN`,
which GitHub provides to every run including a fork's. If a private dependency is ever
genuinely needed again, that gate makes it a deliberate decision rather than a step
someone adds in passing — the cost being the project's ability to accept tested
contributions.

The trade-off, stated plainly: the two report widgets are not exercised in CI. Run the
suite locally with a reporter checkout to cover them.

### The non-test gates

A green test suite says nothing about these, which is why they are separate jobs:

- **`no_secrets`** — no secret but `GITHUB_TOKEN`, as above.
- **`zero_reporter`** — every file naming `redmine_reporter` / `redmineup` is on
  `script/gates/zero_reporter.allowlist` with a written reason. A new reference fails;
  a stale entry is reported so the list shrinks. `ZERO_REPORTER_MODE=strict` is what
  1.0 has to pass, and it fails today by design. The remaining count is printed on
  every run.
- **`no_thread_local`** — `Thread.current` (and `thread_variable_*`, and `Fiber[]`)
  appears nowhere in `lib/` or `app/` except under `glue/legacy/`. The owned path
  carries the actor, the scope and the query in a `Liquid::RenderContext`, which is an
  argument; the legacy glue still needs a thread-local because the host plugin's
  `liquidize()` has no channel to pass an `IssueQuery` through. Two exemptions, each
  with its reason in the script, and the list may only shrink.
  `NO_THREAD_LOCAL_MODE=strict` is what 1.0 has to pass, when that glue is gone.
- **`baseline`** — the corpus reference checks, run from the plugin checkout rather
  than the mirrored copy inside the Redmine clone, because the mirror has no git
  history and the checks would skip there. The job **fails if they skip**: a guard that
  quietly checks nothing is worse than no guard.
- **`corpus`** — gate G7's differential: the declared case matrix re-run against
  PostgreSQL, MySQL and MariaDB and compared with the committed corpus, twice per
  engine, with the reference date pinned. It repeats the baseline checks from the
  checkout on purpose — a green corpus job must not be able to mean "the reference was
  never checked" — and it fails if the examples were pending, if the numbers differ
  anywhere the per-adapter overlay does not name, or if the run modified the corpus it
  was supposed to be verifying.

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
