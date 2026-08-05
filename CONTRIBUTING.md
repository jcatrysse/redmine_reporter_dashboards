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
| **minitest** | `test/unit`, `test/functional`, `test/integration` | Redmine (reporter optional) | Dashboard controllers, models, helpers, the HTTP verb of every route, and the golden scope fixture |
| **golden corpus** | `spec/golden/`, verified by `spec/adapter/aggregation_corpus_spec.rb` | A database **and** `RRD_REFERENCE_DATE` | That the aggregation numbers have not moved — gate G7's differential |
| **R7 invariants** | `spec/adapter/performance_invariants_spec.rb` | A database | Query count independent of issue count, zero issue instantiation, bounded output — asserted hard, every run |
| **the importer survey** | `spec/template_linter_spec.rb`, `spec/import/`, `spec/adapter/import_survey_spec.rb` | The last one needs a database | The template linter's rules, the report's copy and bounds, and that `import:plan` issues nothing but `SELECT` |
| **performance baseline** | `spec/golden/performance/`, measured by `spec/adapter/performance_baseline_spec.rb` | A database, `RRD_REFERENCE_DATE` **and** `RRD_BENCH=1` | The timings the re-seam will be compared against. Opt-in, ~3 minutes, and it asserts no timing |

The RSpec specs run without `redmine_reporter` and without a database. The minitest
suite boots the full Redmine app; since reporter became optional it runs **standalone**,
which is the configuration CI proves, and four report-widget tests skip with a reason
when reporter is absent.

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
