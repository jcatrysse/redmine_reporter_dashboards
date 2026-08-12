# Redmine Reporter Dashboards

Configurable project dashboards for Redmine, plus Liquid tags that replace slow per-issue loops with fast SQL aggregations.

It installs on a plain Redmine and needs no other plugin. One my-page widget still integrates with the [Redmine Reporter](https://www.redmineup.com/pages/plugins/reporter) plugin when that is installed — see [`redmine_reporter` is optional](#redmine_reporter-is-optional).

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

With `drill: true` every bar, slice, point and cell also carries a link to the Redmine issue list, filtered to exactly the issues behind it, inheriting the report query's own filters, columns, grouping, totals and sort order. See [Drill-through URLs](#drill-through-urls).

### `{% geo_version_map %}` Liquid tag — **deprecated**

It existed because the Reporter issue drop exposes `issue.version` as a scalar (the name only), with no id, which made version-filtered URLs — roadmap, issues list, time entries — impossible to build from a template. The tag provided a lookup from version name to its id and metadata.

**The owned drop layer answers all of that directly, so the tag is deprecated and is removed in the next minor version.** It still works, logs one deprecation line per process, and the template linter flags it. See [Migrating off `{% geo_version_map %}`](#migrating-off--geo_version_map-).

### `{% chart %}` Liquid tag

One line per chart, and no markup in the template. `{% chart %}` records what you asked for; the plugin decides how to draw it — a `<canvas>` drawn by the bundled Chart.js 4 on screen, and an inline `<svg>` computed on the server in a PDF. Both come from **one** layout calculation, so the axis, the ticks, the colours and the plot rectangle are the same in the two documents. Chart.js ships with the plugin; nothing is fetched from a CDN. See [Using the `{% chart %}` tag](#using-the--chart--tag).

### `{% version_rollup %}` Liquid tag

A per-**target-version** rollup, computed entirely in SQL. A "one card per version" dashboard normally loops over every version *and* every issue (`O(versions × issues)`) in Liquid, which gets very slow with many issues. `{% version_rollup %}` returns one ready-to-render row per version — counts, hours, min/max dates and summed numeric custom fields (e.g. cost) — in a handful of grouped queries, so the template only loops over the (few) versions.

## Requirements

- PostgreSQL or MySQL/MariaDB. The SQL aggregation tags use adapter-specific date
  formatting and refuse to guess on any other database — SQLite is not supported.

### `redmine_reporter` is optional

It used to be required, and the plugin refused to load without it. It no longer is:
project dashboards, the tab bar, the `{% sql_aggregate %}` / `{% version_rollup %}` /
`{% geo_version_map %}` Liquid tags and the statistics endpoint all work on a plain
Redmine. Installed or not, one line in the log says which mode you are in.

What still needs `redmine_reporter` — and only this:

- the **my-page** *Report by issues* widget, which renders one of Reporter's own report
  templates.

**The two PROJECT-DASHBOARD report widgets no longer do.** They render this plugin's own
report templates through its own render path, and their **Export as PDF** link produces the
PDF through this plugin's engines — so both work on a Redmine with neither
`redmine_reporter` nor the `redmineup` gem installed, which is the whole point of the
exercise. They are offered in the widget picker unconditionally; what they need is a report
template you can see, in a project with the **Reports** module enabled, and the widget's own
settings form says so when there is none.

`issue.target_version` and `issue.custom_field_value` used to be on this list. They were
added by prepending a module into Reporter's own Liquid drop; that prepend is **gone**,
and both accessors now live on this plugin's own issue drop instead — same spelling,
same behaviour, no reaching into another plugin's classes. See
[What changed for `issue.target_version`](#what-changed-for-issuetarget_version).

### Support matrix

Supported means: exercised by `.github/workflows/ci.yml` on every push and pull
request. Two suites run there, and they prove different things:

- **`spec/`** — the plugin's own specs. They stub Redmine away and never boot Rails,
  so they run against every supported Redmine branch without a database.
- **`spec/adapter/`** — the same aggregator, but its SQL executed against a real
  server. This is what proves the per-adapter branches (`TO_CHAR` vs `DATE_FORMAT`,
  the numeric `CAST`, `COUNT(DISTINCT CASE …)`, the visibility clauses in the join
  `ON` clauses) actually answer the same numbers on each engine, rather than merely
  producing the SQL string a unit spec expected.

| Redmine | Rails | Ruby (upstream range) | CI Ruby | Status |
|---------|-------|------------------------|---------|--------|
| 5.1 | 6.1 | >= 2.7, < 3.3 | 3.2 | tested — **but see the note below: the plugin could not run here at all until 2026-08-05** |
| 6.0 | 7.1 | >= 3.1, < 3.4 | 3.3 | tested |
| 6.1 | 7.2 | >= 3.2, < 3.5 | 3.4 | tested |
| 7.0 | 8.1 | >= 3.2, < 4.1 | 3.4 | tested, with one caveat — see below |

| Database | Status |
|----------|--------|
| PostgreSQL 16 | tested — `spec/adapter` runs against it |
| MySQL 8.0 | tested — `spec/adapter` runs against it |
| MariaDB 11 | tested — `spec/adapter` runs against it. **One remaining limitation: a MEASURED `group_by: age` with four or more boundaries — see below** |
| anything else | not supported. The aggregation tags refuse to guess at date formatting and log one clear line instead — SQLite included |

`requires_redmine` is set to 5.1 to match this table. Earlier 5.x releases may
well work; they are simply not tested, so the plugin does not claim them.

**Redmine 5.1, stated plainly.** Until 2026-08-05 the plugin did not work on Redmine 5.1
at all, in two independent ways:

1. `NameError: uninitialized constant ApplicationRecord` the moment any dashboard page or
   plugin test touched `ReporterProjectTab`. Redmine 5.1 has no `ApplicationRecord`; that
   class arrived in 6.0.
2. `undefined method 'sprite_icon'` from every dashboard view. `IconsHelper` also arrived
   in Redmine 6.0.

Both lines had been there since v0.5.0, and nothing caught them because the
full-application test suite could not run in CI at all until the private-plugin secret was
removed. Its first 5.1 run reported 92 errors — 65 of the first kind, 27 of the second.
Both are fixed (`RedmineReporterDashboards::Compat.base_record` and
`ReporterProjectPagesHelper#reporter_dashboard_icon`), and 5.1 now runs the full suite in
CI like every other branch. The row above says "tested" on that basis and not on an older
belief.

The plugin's own code stays inside Ruby 2.7 syntax, because that is the floor
Redmine 5.1 allows. `.codex/check_ruby_floor.sh` guards it and runs in CI.

#### Redmine 7.0: everything except the my-page report widget

**On Redmine 7.0 (Rails 8.1) the plugin runs standalone, in full.** Verified on
`7.0-stable` with no `redmine_reporter` and no `redmineup` gem installed: 2683 plugin
specs, 254 adapter execution specs against PostgreSQL 16, and 966 full-application tests —
0 failures. Since reporter is now optional, the Redmine 7 problem below no longer
affects anything but the one widget that actually needs it.

**This section used to say "except the two report widgets", and that stopped being true.**
The project-dashboard `report_by_issues` and `report_by_spent_time` widgets, and their PDF
export, are this plugin's own and work on Redmine 7.0 whether or not reporter is installed.
What is left is the **my-page** *Report by issues* widget, which still renders one of
reporter's report templates — so it cannot work on Redmine 7.0 with reporter installed,
because it depends on redmine_reporter's `ReportTemplate` and merely referencing that class
raises on Rails 8.1:

```
ArgumentError: wrong number of arguments (given 0, expected 1..2)
  plugins/redmine_reporter/app/models/report_template.rb:26:in '<class:ReportTemplate>'
```

`ReportTemplate` declares its enum with the keyword form, `enum orientation: {...}`.
Rails deprecated that in 7.2 ("will be removed in Rails 8.0") and removed it in 8.0:

| | signature | keyword form |
|---|---|---|
| Rails 7.2 (Redmine 6.1) | `def enum(name = nil, values = nil, **options)` | tolerated, deprecated |
| Rails 8.1 (Redmine 7.0) | `def enum(name, values = nil, **options)` | `ArgumentError` |

The fix belongs in redmine_reporter and is one line — `enum :orientation, {...}`. This
plugin deliberately does not patch it: reporter is a third-party plugin, and carrying a
patch for it would have to be re-applied at every reporter upgrade.

What this plugin does instead is refuse to fall over. The my-page widget checks whether
reporter's classes actually resolve before naming one, and rescues anything else its body
raises, so `/my/page` stays up and the block keeps its own close button — without which a
user could not remove it. The reason is written to `log/production.log`. The two
integration tests that need reporter to be genuinely absent **skip** with that explanation
rather than failing anonymously.

So on Redmine 7.0 today: every project-dashboard widget works normally, including both
report widgets and their PDF export, and the my-page report block degrades to a labelled
placeholder that can still be removed.

#### Fixed: `group_by: age` used to report everything as `(none)` on MariaDB

**If you run MariaDB and have an aging chart, it was wrong before this release** — and
worse than wrong: the total was taken from whichever group the server returned last, so
an issue could disappear from the count as well as from its bucket. Found on 2026-08-05
by the golden aggregation corpus on MariaDB 10.11 and confirmed on MariaDB 11.
**PostgreSQL 16 and MySQL 8.0 were unaffected** — measured, on both — so nothing changes
for those engines.

The `age` dimension groups on a generated `CASE`. ActiveRecord's grouped `.count`
derives a result-column *alias* from that expression's own text and then looks each key
up by it, and MariaDB truncates a returned column label at 256 characters. Past that
limit the two ends were asking and answering with different names: every key came back
`NULL` and the whole chart collapsed into the `(none)` bucket. **Four age boundaries are
enough to cross it, and the default is four** (`30, 60, 90, 180`).

A counted axis is now read back **by position** — `SELECT <expression>, COUNT(DISTINCT
issues.id) … GROUP BY <expression>` — so there is no alias for either end to disagree
about. It is the same statement and the same amount of work for the server; only the way
the result is read changed. The workaround this section used to recommend, pass three
boundaries or fewer on MariaDB, is no longer needed for a counted axis at any boundary
count, up to the 24 the plugin allows. This applies to every dimension, not just `age`:
any long group expression was exposed to the same truncation.

**One case is deliberately not covered**, because it needs a different change and no
template surveyed in this project reaches it:

| `group_by: age` block | MariaDB |
|---|---|
| a plain count, at any boundary count — including inside a crosstab | correct |
| with `measure: sum \| avg \| distinct` | still read through the alias, so still wrong past ~four boundaries |

Those measures go through ActiveRecord's `.sum` / `.average` / `.count`, each of which
keys its result by the same alias. Covering them means reimplementing three more grouped
calculations, which is a larger change than this defect justifies today. **On MariaDB, a
*measured* age axis should stay at three boundaries or fewer.** Nothing 500s in any case.

#### One known database limitation: `group_by: age` on MariaDB with `ONLY_FULL_GROUP_BY`

Every dimension groups on a bare column or a plain function — except `age`, whose
group expression is unavoidably a `CASE` over date boundaries. MariaDB's
`ONLY_FULL_GROUP_BY` check does not recognise a `CASE` in the select list as being
the same expression as the `CASE` in the `GROUP BY`, so it rejects the statement with
`'created_on' isn't in GROUP BY`. PostgreSQL and MySQL 8 both accept it (MySQL has
had expression matching since 5.7.5, and `ONLY_FULL_GROUP_BY` is in its default
`sql_mode`).

`ONLY_FULL_GROUP_BY` is **not** in MariaDB's default `sql_mode`, so this only bites
where a DBA has turned it on — and note that Rails appends to the server's mode
rather than replacing it, so it stays on if it is set globally. When it happens the
block renders empty with the error in `log/production.log`; nothing 500s. Either
group on something else, or drop `ONLY_FULL_GROUP_BY` from that server's `sql_mode`.

#### Running the adapter specs yourself

```bash
./.codex/redmine_clone.sh 6.1-stable
RRD_DB=postgresql ./.codex/test_setup.sh    # or RRD_DB=mysql / RRD_DB=mariadb
./.codex/test_plugin.sh
```

`test_setup.sh` creates a second database, `redmine_adapter_test`, and writes its URL
to `redmine/.rrd_adapter_url`; `test_plugin.sh` picks it up and runs `spec/adapter` in
its own process. Setting `RRD_ADAPTER_URL` yourself overrides that. The URL must name
a database whose name contains `test` — the specs recreate every table in it.

## Installation

```bash
cd {REDMINE_ROOT}/plugins
git clone https://github.com/jcatrysse/redmine_reporter_dashboards.git
cd {REDMINE_ROOT}
bundle install
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

Restart Redmine after installation.

### Uninstalling, and what a rollback does and does not touch

```bash
bundle exec rake redmine:plugins:migrate NAME=redmine_reporter_dashboards VERSION=0 RAILS_ENV=production
```

That removes every table this plugin's reporting schema adds — templates, their version
history, schedules, schedule runs, recipients and stored documents — together with their
indexes, and it removes the plugin's own row from `schema_migrations`.

**It deliberately leaves `reporter_project_tabs` in place**, which is where your project
dashboards live: their tabs, their layout and their widget settings. That table pre-dates
the reporting work, has no export path, and is the one thing a rollback could destroy that
you could not get back — so the down-migration does not touch it. Reinstalling adopts it
again, with the dashboards intact. If you genuinely want it gone, drop it by hand, and
take a backup first.

**This is tested rather than asserted, and here is exactly how far the testing goes.**
`script/migrate_updown.sh` runs a real up → `VERSION=0` → up → reinstall cycle and compares
the schema at each step; you can run it yourself against a Redmine checkout. It has been
executed on **Redmine 6.1 (Rails 7.2) with PostgreSQL 16**. The `migrate-updown` CI job runs
the same script on all four supported Redmine branches — 5.1, 6.0, 6.1 and 7.0 — and that
job is **new in this release, so its first run is its first evidence**. Until that run
exists, treat 5.1, 6.0 and 7.0 as untested for rollback specifically, the same way this
project treats every other unmeasured claim.

It is the difference between "it installed fine" and "it uninstalls without wrecking the
database", and only the first of those was ever being checked.

**Both plugins can be installed at the same time.** Every table this plugin adds is
prefixed `reporter_dashboards_`, and every model class is namespaced under
`RedmineReporterDashboards::`, so nothing collides with `redmine_reporter`'s
`report_templates`/`report_schedules` or with its top-level `ReportTemplate`. That is what
makes it possible to install this alongside your existing setup and compare the two,
rather than migrating and hoping.

## Surveying your existing Reporter templates

```bash
bundle exec rake reporter_dashboards:migrate_from_reporter:plan RAILS_ENV=production
```

**This task writes nothing.** It reads `redmine_reporter`'s tables and prints what it
finds: how many report templates you have by type, how many schedules exist and how
many are enabled, which Liquid accessors and filters your template bodies actually use,
and which templates contain something that will need changing — with the line number
and the line for each one.

It is useful in two situations:

- **before you upgrade**, to see the blast radius: templates using Chart.js 2 idioms,
  the old `window.status`/`geoChartBegin` handshake, `setLineDash`, wkhtmltopdf's
  `[page]` footer tokens, a library loaded from a CDN, or `{{ … }}` inside a `<script>`
  that is not passed through a `json` filter (that last one silently kills the whole
  script block — the chart just disappears);
- **to decide what matters to you**, because the usage counts tell you which parts of
  the old Liquid vocabulary your templates depend on and which they never touch.

It also says what it could **not** answer. If `redmine_reporter` is not installed in
the database you run it against, it says so plainly rather than reporting an empty
result as a clean bill of health.

## Checking that PDF rendering actually works

```bash
bundle exec rake reporter_dashboards:render:preflight RAILS_ENV=production
```

The same diagnostic is at **Administration → Render preflight** for anyone without a
shell on the box.

It does not look at the filesystem. It renders a real probe document through every
installed engine and then reads the result back out of the PDF: does a page break
produce a second page, is the `Page 1 of 2` footer compiled and numbered, are
backgrounds printed (so badges keep their colour), does an inline image decode to the
colour it was, does JavaScript run (so charts can draw), and does the readiness shell
load.

That is the point. **The failure this catches is "the container is healthy but every
PDF silently loses its assets"** — nothing is down, the binary is present, the bytes
come back, the file opens, and the reports are just missing their images. `File.exist?`
answers yes to all of it, and nobody notices until somebody reads a quarterly report a
quarter later.

Three things worth knowing about the output:

- **A Redmine-hosted image is reported as an *expected* failure.** Under the default
  asset policy the renderer has no network access at all, so a
  `<img src="https://your-redmine/…">` in a template cannot load. That is deliberate,
  and the preflight says so out loud rather than hiding it — an expected failure is its
  own state and does not make the run red.
- **`poppler-utils` is optional, and its absence is a skip, not a pass.** Without
  `pdfinfo`/`pdftotext`/`pdftoppm` the preflight can only report that bytes came back —
  which is the check that was already passing while every report lost its images. It
  names the package, the run is reported as *incomplete*, and the summary never reads a
  bare "OK".
- **Exit codes**, so the task can be a deploy step: `0` everything that ran passed,
  `1` at least one check failed, `2` nothing was verified — no engine is registered,
  the id you named does not exist, the selection named nothing at all (a mangled
  `RRD_ENGINE=','` is a typo, not a request for the default set), **or every engine this
  install has needs a service and none of them is the selected one**, so every report was
  a deferral and nothing was actually checked. That last case used to exit `0`, which told a
  deploy step everything was fine about a run that verified nothing. The deferral rows are
  still printed and they name what to do — and each engine's own line still reads "OK so far",
  which is that engine's summary (nothing failed, nothing ran); the run-level verdict is the
  exit code and the last line.
  `RRD_ENGINE=<id>` limits it to one engine; `RRD_FORMAT=json` prints the report as
  JSON for an issue or a log.

## Rendering in a container instead (Gotenberg)

**You do not need this.** The default engine is headless Chromium started by the plugin
itself, it needs no service, and it is the one every other section here assumes. Gotenberg
is offered as *one* of the options — it buys a render path that is already isolated at the
network level, and it costs you a service to run, monitor and patch.

**Measured in CI, enforced since 2026-08-11.** The numbers come from run 31408759956
(2026-08-10) and every run since; the promotion — the decision that those cells are a
contract rather than a report — was taken on 2026-08-11. Its column in
[`docs/engine-support-matrix.md`](docs/engine-support-matrix.md) carries measurements now —
19 fixtures pass and one is skipped, because Gotenberg does not declare the `:asset_inline`
capability that fixture needs — its asset model is **upload** rather than inline, which changes
nothing about how you write a template (see *What it can and cannot do* below). Those cells are a contract rather than a report: a
regression in any of them fails the build, and so does a Gotenberg that will not start
**wherever the corpus runs** — CI, or a developer's machine. What that costs, stated plainly:
the render-conformance job depends on the container registry serving the pinned digest, and a
local `RRD_CONFORMANCE=1 rspec spec/conformance` now needs a Gotenberg running and its
`RRD_GOTENBERG_*` variables set (`spec/conformance/README.md` has the commands).

Nothing auto-detects it. An engine that needs a service is never chosen for you: an install
without a container has not picked Gotenberg, it has simply not picked, and quietly selecting
it would turn every report into a connection error. You pick it, in one of two places:

- **Administration → Plugins → Redmine Reporter Dashboards → Render engine** — the whole
  installation. The dropdown is built from the engines actually registered on this host, and
  the line under each one says what it needs, whether it needs a service, whether it renders
  offline and what it cannot do — generated from `config/capabilities.yml` rather than written
  out, so it cannot drift from what the code does.
- **A template's `engine_hint`** — one report. A hint **outranks** the setting, deliberately:
  a hint is a statement about a document ("this one needs a modern JavaScript engine") and the
  setting is a statement about the installation, so an existing template keeps rendering
  exactly as it did when somebody changes the installation's engine. There is still no form
  field for a hint; you set it by exporting the template, adding `engine_hint: gotenberg`, and
  importing it again.

The full order is: the template's hint, then this installation's setting, then the engine
`config/capabilities.yml` declares as the default, then any engine that needs no service. An
engine that is not installed on this host is ignored at every step, with a line in the log,
rather than failing the report — so a template written elsewhere stays portable.

### It is refused unless it is authenticated

Gotenberg ships with **no authentication at all**, and an unauthenticated PDF service on an
internal network will render any HTML anybody who can reach it sends. So the preflight
**fails**, with a named remediation, in both of these cases:

- no credential is configured for the endpoint; or
- a credential is configured and the endpoint answers the conversion route without it.

That is a failure and not a warning, deliberately. If you want Gotenberg, you configure the
credential on both sides.

### The example compose file

`docker-compose.gotenberg.yml` in this repository is a documented example — the plugin never
ships or starts a container. It carries the four things that make the option safe: an
`internal: true` network, a non-root user, a read-only root filesystem, and the image pinned
**by digest** rather than by tag. That file is the ONE place the digest is written, and a
nightly CI job reads it from there and scans exactly those bytes.

```bash
export GOTENBERG_USERNAME=reporter GOTENBERG_PASSWORD="$(openssl rand -hex 24)"
echo "$GOTENBERG_PASSWORD"    # write this down — Redmine needs the same value below
docker compose -f docker-compose.gotenberg.yml up -d
```

Read the comments in that file before adapting it. In particular, `internal: true` means the
container has no route off its own network — so **Redmine has to be on that network**. If
Redmine is not in Docker, the file spells out the weaker alternative and what it costs
rather than leaving you to delete the line.

Then point the plugin at it, in Redmine's environment:

```bash
RRD_GOTENBERG_URL=http://gotenberg:3000
RRD_GOTENBERG_USERNAME=reporter
RRD_GOTENBERG_PASSWORD=…            # the same pair the container was started with
```

The credential lives in the environment rather than in the plugin settings form on purpose,
and the line between the two is worth stating now that the form carries an engine field: the
engine's **name** is a preference and belongs in the settings form; its **address and
credential** are deployment secrets and do not. The settings table is neither encrypted nor
hidden from anyone who can read the administration page.

### Check it before you rely on it

```bash
RRD_ENGINE=gotenberg bundle exec rake reporter_dashboards:render:preflight RAILS_ENV=production
```

Or without a shell: **Administration → Render preflight** has an engine selector — pick
`gotenberg` and run it. Either way, naming the engine is what runs its real checks
(credential included); the default run defers an engine that needs a service, because
you have not chosen it.

If you **have** chosen it — in the setting above — the default run stops deferring it and
checks it like any other engine, which also means `rake reporter_dashboards:render:preflight`
starts failing when your container is down. That is the point: the engine an installation
renders with is the one its deploy step has to be able to verify.

Two of those checks are worth knowing about, because both of them catch a container that
looks completely healthy:

- **The credential check asks the conversion route, not `/health`.** Gotenberg exempts its
  health endpoint from authentication, so a check pointed there answers *200 OK* on a
  locked-down service and on a wide-open one alike.
- **JavaScript liveness is checked by provoking an error.** A container started with
  `--chromium-disable-javascript` renders every report **without its charts** and reports
  nothing wrong — it also silently ignores the readiness signal, so the plugin does not even
  wait. The preflight sends a document whose script throws and expects to be told about it;
  a container that cannot be made to error has no JavaScript.

### What it can and cannot do

Its capabilities are in [`docs/engine-support-matrix.md`](docs/engine-support-matrix.md),
generated from an actual conformance run rather than written by hand. The one difference
from the default engine that is worth stating here: Gotenberg's asset model is **upload**,
so images, stylesheets and fonts travel alongside the document as separate files rather than
embedded in it. Nothing about how you write a template changes.

## Where a report's images and stylesheets come from

**Administration → Plugins → Redmine Reporter Dashboards.**

**The same page carries the render-engine selection** — which engine draws every PDF on this
installation, with one generated line per engine saying what it needs and what it cannot do.
It governs all three engines, not just the containerised one; the ordering rules and what a
template's own `engine_hint` does to them are under
[*Rendering in a container instead*](#rendering-in-a-container-instead-gotenberg), because
that is where an operator first meets the question.

A PDF is produced by handing a document to a rendering engine. Something has to obtain the
images, stylesheets, fonts and scripts that document points at, and there are only three ways
to do it: embed them in the document, send them alongside it, or let the engine go and fetch
them. Only the third needs network access, and by default this plugin does not use it.

| Asset policy | Local files | URLs on this Redmine | URLs anywhere else |
|---|---|---|---|
| **Bundled** (default) | embedded | mapped back to the file on disk and embedded | **refused, naming the URL** |
| **Redmine** | embedded | fetched, from hosts you list | refused |
| **External** | embedded | as above | fetched, from hosts you list |

### The default refuses rather than leaving a gap

Under **Bundled**, a report that references something not on this server's disk is **not
rendered**. You get a failure that names the URL, a correlation id, and the reason. That is
deliberate: a PDF with an empty rectangle where a chart used to be is indistinguishable from a
PDF that never had one, and if the report is an audit record that difference matters.

### Which URLs on this Redmine are mapped back to a file

"Mapped back to the file on disk" is exact, and two shapes are recognised:

- **`/plugin_assets/redmine_reporter_dashboards/…`** — anything this plugin ships.
- **`/attachments/download/<id>`** and **`/attachments/download/<id>/<filename>`** — a Redmine
  attachment. **The person the report is rendered as must be allowed to see it.** An
  attachment on an issue they cannot open is refused and named, exactly as a third-party URL
  is; a report is never a way to read a file you could not have downloaded. The same URL in
  the same template can therefore succeed for one recipient and refuse for another, which is
  the correct answer rather than an inconsistency.

Both work as absolute URLs too (`https://your-redmine/…`), matched against **Administration →
Settings → Host name**. If that setting is wrong, an absolute URL on your own server looks
like somebody else's and is refused.

Two attachment URL shapes are deliberately **not** mapped, and are refused with their reason:

- **`/attachments/<id>/<filename>`** is the *page* about an attachment, not the file.
- **`/attachments/thumbnail/<id>`** is a *resized copy*. Embedding the full-size original
  instead would put something other than what you asked for into the document without saying
  so. Reference the download URL and size it with CSS.

### Three properties that are not preferences

- **An empty host allowlist makes every value behave exactly as Bundled.** If you select
  *External* and save without adding a host, nothing is fetched — and the settings page tells
  you so, rather than showing you the value you chose and letting you assume it took effect.
  A half-finished configuration cannot open network access by accident.
- **It is a setting for this install, never for a report.** There is no project setting and no
  template field. Writing a report template is already permission to run code on this server;
  it must not additionally be permission to make the server fetch things. Nothing a template
  contains — a `<meta>` tag, a comment, a query string — changes this setting.
- **When a fetch is allowed, the plugin fetches and the engine gets bytes.** The rendering
  engine is never given network access, in any mode. Fetches are HTTPS only; carry **no**
  cookie, session, API key or `Authorization` header; follow **no** redirects; are size-capped
  and time-capped; and are refused when the host name resolves to a private, loopback or
  link-local address — checked *after* the name is resolved, and the connection is then made to
  the address that was checked. An asset that needs your credentials in order to load is an
  asset a report may not contain.

### Host names, not patterns

One host name per line. No scheme, no port, no path, and **no wildcards** — `*.example.com` is
rejected rather than interpreted, because `*.example.com` matching
`evil.example.com.attacker.net` is the classic way an allowlist turns out not to have been one.
A listed host does not authorise its subdomains.

### The two size settings

- **Embed assets up to (bytes)** — default 512 KiB. Above this an asset travels alongside the
  document rather than inside it, on engines that support that. This is a cost setting: base64
  encoding grows a file by a third, and past some size a second round trip is cheaper. Neither
  shipped engine supports the alongside model yet, so today a larger asset is embedded anyway
  and the render records that it did.
- **Refuse assets above (bytes)** — default 8 MiB. A hard limit. A larger asset is refused and
  named.

Values outside the supported range are not stored: they are replaced by the default, written to
the log, and listed on the settings page under *Some saved values could not be used*.

### A stylesheet's own references count too

A CSS file can point at images, fonts and further stylesheets. Those are resolved by the same rules
**before** the stylesheet is embedded, so a Bundled install cannot be talked into fetching something
by putting the URL one level down. A reference inside a stylesheet that the policy refuses fails the
report and names that inner URL, not the stylesheet.

JavaScript is different, and the difference is deliberate: a script can ask for anything at all
while it runs, and no amount of reading it beforehand changes that. The answer there is not to
inspect the script but to deny the rendering engine network access altogether — which is what
happens in every mode, including the two that fetch.

### Charts and fonts are never affected

Chart.js and the fonts this plugin ships are always embedded, whatever the asset policy says.
No value of this setting can make a chart depend on network access — the thing that must keep
working offline is not the thing a report author points at.

## Enabling the dashboard for a project

1. Open **Project → Settings → Modules** and enable **Project dashboard**.
2. Assign permissions to the relevant roles:
   - `view_reporter_project_page` — view the dashboard
   - `manage_reporter_project_page` — add and rearrange blocks
   - `manage_reporter_project_tabs` — create and rename tabs
3. A **Project dashboard** link appears in the project menu. The first visit automatically creates a default tab.

Those three cover the dashboard. **Report templates are a separate module with five
permissions of their own** — see *Report templates* below. The remaining reporting
features still being built arrive the same way, per role and per project, rather than
switching on through a plugin setting. Two things worth knowing either way.

**This plugin never grants a permission to a role — but Redmine's default configuration
does.** Nothing here ticks a box for you; administrators bypass permission checks, everyone
else starts with what you grant. The exception is not ours: *Administration → Settings →
Load the default configuration* creates a *Manager* role holding every permission it can
give, a plugin's included. If you run that step on a fresh Redmine that already has this
plugin installed, look at what *Manager* came out with.

**A permission name can only belong to one plugin.** If another installed plugin registers
one of these names too, the log says so at start-up and names it. That puts two identical
rows on the roles screen and makes access checks behave unpredictably, so it is worth
reporting rather than working around.

Widget settings (a query, a report template, an item limit, a column list) are
validated before they are stored: a setting whose value is not of the expected shape
is dropped rather than saved, with one line in `log/production.log` naming the widget
and the setting. Widgets contributed by other plugins keep working — their own
setting names are accepted, as bounded values.

## Report templates

A **report template** is a Liquid document that this plugin renders against a project's
issues, as a web page and as a PDF. It is a second project module, separate from the
dashboard, because *"we want dashboards, not the reporting surface"* is a real answer.

1. Open **Project → Settings → Modules** and enable **Reports**.
2. Assign permissions to the relevant roles.
3. A **Report templates** link appears in the project menu.

| Permission | What it allows |
|---|---|
| `view_reporter_dashboards_reports` | See the templates a project offers, open one, download its PDF |
| `add_reporter_dashboards_templates` | Create a template |
| `edit_own_reporter_dashboards_templates` | Edit and delete the templates you authored |
| `edit_reporter_dashboards_templates` | Edit and delete any template in the project |
| `manage_public_reporter_dashboards_templates` | Give a template a visibility wider than yourself |

**The four authoring permissions execute code, and their labels say so.** A template is
Liquid that runs on your server: whoever can write one can make the application do what
that template says. Redmine will not offer these to the *Anonymous* or *Non-member* role,
and they are not permitted in a closed project. Treat granting one the way you would treat
giving somebody a shell.

**A report is displayed inside a sandboxed frame, and that is load-bearing.** A template's
output is not part of the Redmine page around it: it is parsed as a separate document in a
frame with no access to your session, your cookies or the page it sits in, and with the
network switched off for everything except images already embedded in the document. Without
that, any member who can author a template could write one line of JavaScript and have it
run with the privileges of whoever opens the report — including an administrator. If you
are reviewing this plugin's security, that frame and the permission list above are the two
things to look at.

**Visibility works exactly like a saved query's** — *to me only*, *to these roles only*, or
*to any users* — and uses Redmine's own words for the three, so it is one concept rather
than two. Choosing anything wider than *to me only* needs
`manage_public_reporter_dashboards_templates`; without it, a template you create stays
private, silently in the sense that the form tells you so up front rather than refusing
your submission.

**Which issues a report covers.** By default, every issue in the project you can see. Pass
a saved query with `?query_id=…` and the report resolves through that query instead — and
only through queries you could already open, so a report can never show you issues the
issue list would not.

### Preview

The editor's **Preview** button renders the content in the form — not the saved version —
in **both** bindings: the HTML inline, and a PDF through the configured engine. Both,
always, because *"it looked fine in the browser and broke in the PDF"* is the failure this
plugin exists to remove; if no engine is installed or the PDF fails, the page says so with
the engine, the version and a correlation id rather than showing you the HTML and letting
you assume. Preview is bounded to **50 issues** and prints *"Preview of 50 of 1 284
issues"* when there are more.

### When a report cannot be generated

The page tells you: which template, what kind of failure, the code, the Liquid line number
where there is one, the engine and its version, how long it took, and a **correlation id**
to quote when you ask an administrator to look at the log. What it never shows you is the
raw exception — that goes to the application log, where the person who can read a stack
trace is.

**Optionally, you can get that as a PDF.** Tick *Produce a failure document* on the
template (off by default). Then, when a report cannot be produced, the download gives you a
real one-page PDF titled *"Report could not be generated"* and named
`report-FAILED-<correlation id>.pdf`, so it can never be filed as the report. It carries the
same safe summary as the panel and nothing else — no exception class, no SQL, no role,
member or project ids — because it is built from a fixed list of fields rather than from the
error text.

It is drawn without the PDF engine, on purpose: most of the reasons a report fails are
reasons the engine failed, so a failure document that needed the engine would be missing
exactly when you wanted it. Nothing is saved: downloading one writes no attachment and no
row anywhere.

**One limitation, stated rather than discovered.** The failure document is drawn with the
fonts every PDF reader is required to have, and those cover the Latin-1 alphabet and nothing
else. On an installation running in Russian, Chinese, Polish or Hungarian the document is
therefore written **in English** — the whole document, not a mixture — and a template whose
name uses characters outside that alphabet has that one line replaced with a sentence saying
so. Everything that identifies the run, the correlation id included, is unaffected. The
diagnostics panel in the browser has no such limit and is in your own language.

A **scheduled** report that fails is unchanged by this — its owner gets a notice with the
correlation id and no attachment, and its recipients get nothing.

### Import and export

**Export** writes a JSON *bundle* — `format_version`, `exported_at`, `plugin_version` and
a list of templates. Each template carries its own fields only: no ids, no project, no
author, no version history. **Import** reads that bundle, the single-template JSON earlier
versions of this plugin wrote, and the YAML a `redmine_reporter` export produces — mapping
its three template types onto this plugin's `source` and `output` fields through a fixed
table. A file naming a Ruby class, or using a YAML alias, is refused with a message rather
than loaded. Importing requires **both** `add_…` and `edit_…`: import is authoring, and a
weaker permission of its own would be a way around the authoring one. An imported template
is always private to whoever imported it, whatever the file asks for.

Exporting and importing a template returns the same bytes it started with, so a bundle can
be kept in version control and a difference in it is a real difference.

#### Moving several templates between installations

The buttons in the editor move one template at a time. For a whole project there are three
rake tasks, and the middle one is the point of them:

```bash
# write every template in a project to a file
bundle exec rake reporter_dashboards:export:bundle \
  RRD_PROJECT=my-project RRD_OUT=templates.json RAILS_ENV=production

# say what importing it would do — writes NOTHING
bundle exec rake reporter_dashboards:import:plan \
  RRD_PROJECT=other-project RRD_FILE=templates.json RAILS_ENV=production

# do it
bundle exec rake reporter_dashboards:import:run \
  RRD_PROJECT=other-project RRD_FILE=templates.json RAILS_ENV=production
```

`plan` reports, per template, whether it is new, would be skipped, renamed or overwritten,
plus any template-linter findings — and it writes nothing at all, so it is safe to run
against production. `apply` then does it **one transaction per template**, so one bad
template is reported with its reason and the rest of the bundle still imports.

`RRD_ON_CONFLICT` decides what happens when a template of that name is already there:

| | |
|---|---|
| `skip` (the default) | leave the existing template alone and say so |
| `rename` | import as *Name (2)* and keep both |
| `overwrite` | replace the content, keeping the previous version in the template's history so it can be rolled back to |

`overwrite` only touches templates the actor may edit, and never changes a template's
owner or its visibility — a bundle cannot make somebody else's private template public.
`RRD_ACTOR=login` chooses which administrator owns what is created; without it the first
active administrator does. The tasks exit `0` when everything was decided or applied, `1`
when a template failed, and `2` when the arguments were wrong (no file, no such project).

> These are **`import:`/`export:`**, not `import:`. `reporter_dashboards:migrate_from_reporter:*` is the one-way
> migration off `redmine_reporter` described below, which reads that plugin's database
> tables rather than a file.

### Two limits, and one thing this version does not do yet

* **A PDF export is capped at 50 documents.** It matters only for *one document per
  issue* templates: asking for more is refused before anything is rendered, with a message
  naming both the number you asked for and the limit.
* **A *one document per issue* template covering more than one issue downloads as a zip.**
  One PDF per issue, named after it. Expect a pause before the download starts: every
  document is rendered first, deliberately, so that a failure is still a proper error page
  rather than a half-finished archive. The 50-document cap above is what bounds both how
  long that takes and how much memory it needs, and it is still checked before anything is
  rendered at all.
* **A `source: time_entries` report has no time series.** Hours by activity, by user, by
  project, by issue and by four issue attributes all work (see *Reporting on spent time*
  below), but `{% sql_aggregate %}` with no `group_by` is refused there and says so on the
  page: a time entry is not opened and closed, so there is no created/closed flow to plot.
  Use `group_by:` and, if you want a trend, a `spent_on` filter on the saved query.

## Migrating from `redmine_reporter`

Three rake tasks, in the order you would run them:

```
rake reporter_dashboards:migrate_from_reporter:plan     # survey the old data. Writes nothing.
rake reporter_dashboards:migrate_from_reporter:run      # copy the templates across
rake reporter_dashboards:migrate_from_reporter:status   # what has drifted since
```

**It copies. It never adopts, and it never writes to the old plugin's tables.** That is not
tidiness: uninstalling `redmine_reporter` the documented way runs *its* down-migrations,
which drop its tables. If this plugin were live on those rows, they would go with it. So
your old templates stay exactly where they are, and you can uninstall the old plugin — or
not — without touching what has been migrated.

**Re-running is safe, and there are four outcomes rather than two.** A template is
*created* the first time, *unchanged* when nothing has moved, *updated* when the original
changed and your copy has not, and — the important one — **left alone** when you have
edited the copy here. It is never overwritten. `import:status` lists exactly those, so
drift is something you can see rather than something you discover.

`RRD_DRY_RUN=1` decides everything and writes nothing. `RRD_PROJECTS=1,5` limits it.
`RRD_ACTOR=login` chooses which administrator owns the copies; without it the task takes
the first active administrator, and refuses rather than guessing if there is none.

Imported templates are **private to the importer** — the old plugin's visibility settings
are not translated, and widening one is a deliberate act afterwards.

If you have edited a copy and decide you want the original after all, re-run with
`RRD_REWRITE=1`. That is **not** a plain overwrite: your version is written into the
template's own history first, so it is still there to roll back to from the editor.

A template belonging to a project that does not exist here is **skipped and named** rather
than imported — every page in this plugin is reached through a project, so such a template
would be invisible and impossible to delete. Migrate or recreate the project, then re-run.

**There is deliberately no `import:verify`.** It was meant to compare aggregation results
before and after, and it cannot work: your issues change every day, so the numbers change
every day, and a check that goes red every morning is one you would rightly switch off.
`import:status` compares the template *content* instead, which only changes when somebody
edits it — that is the drift worth watching.

## Sending a report by e-mail, once

*Send report by e-mail* on a report's page mails it to whoever you choose, now, without
creating a schedule. It needs two permissions — **Send a report by e-mail** and **View
report templates** — because mailing a report is a way of reading it.

Four things about it are deliberate, and each one is a thing the report you send cannot do:

* **You can only mail what you can see.** The report is produced with *your* access rights,
  not the recipient's, and the mail says so. If you name issue IDs and one of them is an
  issue you cannot see, **nothing is sent** — the whole request is refused rather than
  quietly reporting on the rest, because a report that silently covers less than it claims
  is worse than an error.
* **The sender is this Redmine, and you are in `Reply-To`.** There is no field for a
  sender, so a report cannot be mailed from an address that is not this installation's.
  Somebody who replies reaches you.
* **Recipients must be allowed to open reports in that project.** You can send to a
  colleague who could open the report themselves, and to yourself; you cannot use it to
  put a PDF in front of somebody with no business in the project. A project member whose
  role does not include *View report templates* is refused. So is anybody the project does
  not entitle — which, said precisely, means anybody who could not open the report
  themselves: in a **public** project that can include a non-member, if you have granted the
  permission to the Non-member role, and it always includes administrators. If one recipient
  in the list is not permitted — or is locked, or no longer exists — **nothing is sent**
  rather than the rest of the list receiving it quietly.
* **Recipients are Redmine users** unless an administrator has enabled external addresses
  in *Administration → Plugins → Reporter dashboards* **and** listed the permitted domains
  there. An empty domain list means no external address is accepted, whatever the checkbox
  says — the page warns when that is the state.
* **Every send is recorded**, with who sent it, when, which template, which issues and
  which recipients — including the exact address for an external one. Administrators see
  every row for the project; everybody else sees their own. There is also a per-user rate
  limit (12 sends an hour by default; `0` switches the feature off for the whole
  installation).

A render that fails mails nobody at all. You get the diagnostics panel with a correlation
ID, the same one the audit row carries, so nobody receives a green-looking e-mail with a
broken report in it.

## Scheduled reports

A schedule mails a report template to a list of Redmine users on a repeating day —
daily, weekly, monthly, quarterly or yearly, counted from its start date.

### The scheduler does not run itself

**This is the one thing to get right at install time.** Nothing inside Redmine wakes the
scheduler: there is no daemon, no background worker shipped with this plugin, and no timer
that starts when the application boots. A scheduled report is delivered exactly as often as
something outside calls the rake task. Add one cron entry:

```cron
# every morning at 06:00
0 6 * * *  cd /path/to/redmine && RAILS_ENV=production bundle exec rake reporter_dashboards:schedules:run
```

It exits **0** when every schedule either delivered or had nothing to do, and **1** when at
least one failed — so it can be monitored like any other job. A schedule that is still an
unfinished draft is reported but does *not* make the run exit non-zero; an exit code that is
always non-zero is one nobody reads.

If you are not sure whether it is running:

```bash
bundle exec rake reporter_dashboards:schedules:status
```

That writes nothing. It reports how many schedules are enabled, when one was last attempted,
and warns when there is work that should already have happened — which is what the failure
mode looks like when a cron entry was never added or was lost in a deployment. Everything
works, nothing is red, and no report is ever sent.

### What a run does

* **A day is claimed before it is rendered.** The claim is a database insert against a
  unique index, so two overlapping cron entries produce one delivery and one skip rather
  than two e-mails.
* **A normal run does not backfill.** If the machine was off for three days, switching it
  back on does not mail three reports to everybody. Pass `RRD_CATCH_UP=1` to recover missed
  days deliberately, bounded to the last 7 (`RRD_MAX_CATCHUP_DAYS=n`) — a schedule dormant
  for a year must not emit 365 e-mails.
* **One render per occurrence**, not one per recipient. Twenty recipients receive the same
  attachment from one render.
* **One failing schedule does not stop the others.** Its `last_status` becomes `failed`,
  its error is recorded, the run continues, and the task exits 1.

### Who the report is rendered as

Every schedule stores the identity its numbers are produced with — its author by default,
or a specific user. That identity is what the visibility rules are applied to, so two
schedules over the same template can legitimately produce different numbers, and the mail
says whose view it holds.

If that identity is locked, deleted, or set to a policy this version does not understand,
the schedule **fails** rather than falling back to somebody else. A report mailed as the
wrong person is worse than a report that did not arrive.

**Choosing somebody else's identity is a permission of its own.** By default you may only
schedule a report as yourself — otherwise anyone who can manage schedules could borrow a
colleague's wider visibility and have the result mailed to them. The role permission
*"Render reports as another user"* lifts that, within one project, and its description says
plainly what it grants: **access to everything that user can see**. Grant it deliberately.

The same permission governs the *Send a test* button: without it you can only test-send a
schedule that renders as you.

### When a report cannot be produced

The schedule's **owner** gets a notice naming what went wrong and a correlation id to quote.
**Recipients get nothing** — never an e-mail with a broken attachment, and never a file
named `.pdf` that is not one.

Sender addresses are server-controlled: schedules address Redmine *users*, and there is no
`from`, `to` or `bcc` field anywhere in the schema to forge.

### Limits

* Attachments totalling more than **10 MB** are refused before anything is sent, with a
  notice to the owner, rather than handed to a mail server that will bounce them.
* The 50-document PDF cap applies here too.
* A schedule with no active recipient does not render at all; its owner is told.

### Not built yet

Schedules have no UI in this version and no permissions of their own — they are created and
edited in the console. `RRD_SCHEDULE=<id>` runs a single schedule by hand, which still
respects the enabled flag.

## Sharing a report by link

A **share link** is a URL that serves one report to whoever holds it. It is not a shortcut
past Redmine's permissions: what it serves is a **snapshot** — a PDF that was rendered once,
as a named person, inside exactly what that person was allowed to see, and then frozen. When
somebody opens the link, nothing is queried and no permission is resolved. There is no
visibility decision at request time because there is nothing left to decide.

That is the whole design, and it is what makes the rest of it safe to offer.

Every link carries:

| | |
|---|---|
| **A mandatory expiry** | there is no such thing as a link that never expires. The column is `NOT NULL`, so neither a form nor a console session can create one |
| **Revocation** | one click's worth of work, and it takes effect on the next request. Deleting the template revokes every link to it |
| **An optional use limit** | "this link works three times". Two people opening a single-use link at the same moment get one download and one refusal, never two downloads |
| **An access log** | one row per attempt, with the time, the address and the browser — *including refusals*, because "somebody is trying expired links at us" is the question the log exists to answer |

**The token is never stored.** Only a SHA-256 digest of it is, so a copy of your database
yields no working links, and there is nowhere for anyone — including an administrator with a
console — to read an existing link's URL back out. It exists once, at the moment it is
created. If it is lost, make a new one.

### Public links

A link is private by default: the holder still has to be signed in to Redmine, so forwarding
the mail one more time does not turn it into a public URL. A **public** link is a second,
separate decision — it is reachable by anyone at all, with no account.

A public link still serves a snapshot, never a live query, so "public" never comes to mean
"visibility check skipped".

Note that a public link is served **even on an installation configured with
`login_required`**. That setting closes the instance to anonymous browsing; publishing one
frozen document is a deliberate act on top of it. If that is not what you want for your
installation, do not grant anybody the ability to publish.

### Who may do it

Two role permissions, and they are two rather than one because they are different
decisions:

| Permission | What it lets somebody do |
|---|---|
| **Create report share links** | Make a link to a report they can already open |
| **Make report share links public** | Additionally tick "public link", so it works with no Redmine account |

Neither is granted by default. Someone holding only the second one can do nothing — it
widens a choice on a form rather than opening a door.

**Revoking is not a permission.** A link can be revoked by whoever created it, by the
report's author, and by administrators. A colleague holding every permission in Redmine
still cannot revoke a link you made — that is deliberate, and there is a test for it.

### Making one

Open a report and choose **Share links**. That page lists every link for the report —
including revoked and expired ones, because a revoked link is exactly the thing you want
to confirm is revoked, and an expired one explains why a recipient is complaining. From
there, **New share link** asks for four things:

* a **purpose**, which is a note to yourself and is never shown to whoever opens the link;
* an **expiry**, defaulting to 30 days. There is no "never expires" option and there is no
  way to ask for one;
* an optional **maximum number of opens** — set it to 1 for a one-off send;
* whether it is **public**, if you hold that second permission.

The URL is shown once, on the page you land on after creating it. Copy it then: only a
fingerprint of the token is stored, so no page, console session or database query can
recover it afterwards. If you lose it, revoke the link and make another.

### Three things worth knowing

* **The token is in the URL path, so it is written to your `production.log` and to any
  reverse proxy's access log**, exactly as any link-based sharing is. That is inherent to
  handing somebody a URL. What bounds it is the expiry — prefer a short one. The same token
  also appears in the sign-in redirect for a private link, which adds no exposure the path
  did not already have.
* A snapshot is stored as a Redmine attachment with an expiry of its own, and **a link can
  never be created that outlives its snapshot**. Once a snapshot has expired the link stops
  serving it immediately, whether or not the file has been collected yet. Nothing may be
  kept longer than a year.
* **Deleting a report template destroys every link to it and purges its snapshots**, which
  is the most complete revocation available.

### One limitation, stated plainly

A share link authorises **one document and nothing it points at**. If a report's content
links to a Redmine attachment, that link travels into the PDF as written — it is not
rewritten, and it is not given any access of its own. Opening it lands the reader on
Redmine, which applies its own permission check, so a public-link holder with no account
gets a sign-in page rather than the file.

That is safe, but it is narrower than being able to *include* an attachment in a shared
report. Images referenced by URL will not appear in a snapshot at all: the renderer is
deliberately never given credentials, so it cannot fetch them. If your report needs an
image, embed it in the template rather than linking to it.

### Collecting expired snapshots

Expired snapshots stop being served the moment they expire, but their files stay on disk
until they are collected. Like the scheduler, the purge does not run itself:

```bash
# see what would go, and change nothing
RRD_DRY_RUN=1 bundle exec rake reporter_dashboards:documents:purge RAILS_ENV=production

# collect them
bundle exec rake reporter_dashboards:documents:purge RAILS_ENV=production
```

Run it from cron alongside `redmine:attachments:prune`. The rows are kept and stamped, so
you can still answer "a document existed here and was collected on this date" afterwards —
only the bytes go.

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

#### `open_at_end` — the backlog height

`created` and `closed` answer "how busy were we". `open_at_end` answers "is it
getting better": the number of issues that existed and were not yet closed at the
end of each period, aligned with `labels`.

```liquid
{% sql_aggregate from: issues, period: month, periods: 12, assign_to: stats %}

{% for label in stats.labels %}
  {{ label }}: {{ stats.open_at_end[forloop.index0] }} open
{% endfor %}
```

A template cannot compute this itself: a running total of `created - closed` in
JavaScript is wrong for every issue that already existed when the window opened.
It is one conditional aggregate per period in a single statement (chunked for a
90-day window), and it honours `closed_statuses` exactly like the `closed` series,
so the three can be charted together without disagreeing about what "closed" means.

Two caveats, both worth knowing before you put it on a dashboard:

- **A reopened issue counts as open until its last closing.** `closed_on` records
  only the *last* closing — Redmine preserves it when an issue is reopened, it does
  not clear it — so there is no record of an earlier one. An issue closed in March,
  reopened in April and closed again in June therefore counts as open for every
  period before June. Because `closed_on` survives a reopen, the query also requires
  the issue's *current* status to be a closed one; without that, an issue that is
  open again today would be reported as closed ever since the closing it once had.
  Recovering the real history means replaying journals, which costs far more than
  this query and is deliberately not done.
- **`open_at_end` points carry no drill-through URL**, and that is not a bug. The
  set is "created on or before X **and** (still open **or** closed after X)" — an
  OR across two fields, which a Redmine issue query cannot express. Note that
  `drill: true` does nothing at all in time-series mode — no series has links there,
  not just this one — so the tag reports `drill_available: false` and points you at
  `group_by: period` in the log. If you want a clickable period chart, use that.

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

A field the viewer is entitled to **nowhere** is refused outright — the tag logs one
line and assigns the empty-safe result — because its *name* would otherwise appear as
`field_name` or as a completeness label, and Redmine keeps restricted field names out
of that user's filter list too.

### Who sees what: two people, two sets of numbers

A dashboard has two layers, and they answer to different people:

| Layer | Decided by | Same for everyone? |
|---|---|---|
| The **query definition** — filters, columns, grouping | whoever built the dashboard | **yes** |
| The **rows** it aggregates | the person looking at it | **no** |

The second layer comes from `IssueQuery#base_scope`, which is
`Issue.visible.joins(:status, :project).where(statement)`. `statement` is your filter
definition, applied identically for everyone; `Issue.visible` takes no argument, so
it resolves against `User.current` — the viewer. Redmine then applies `:view_issues`
per project, the role's `issues_visibility` setting (`all`, `default` = public plus
own, `own`) and private issues.

So a project manager may see 49 issues where a team member sees 31, and everything
derived from that moves with it: percentages, the `Other` bucket, `median_open_days`,
the completeness figures. Four more places narrow per viewer:

- a **role-restricted custom field** is refused as a dimension, measure or
  completeness field for a viewer who is not entitled to it — the same way Redmine
  leaves it out of that user's filter list;
- **`of: spent_hours`** only counts time entries the viewer may see;
- the **drill-through URLs** are built against the renderer's own available filters;
- a widget whose saved query is **private** is not rendered for others at all (404
  for that widget), and a template hardcoding `query_id:` of a private query gets an
  empty result rather than someone else's numbers.

**This is deliberate, and the alternative leaks.** If everyone saw the dashboard
builder's numbers, "49" would tell a viewer who may see 31 that 18 issues exist that
they may not. Redmine shows per-user counts everywhere — the sidebar, the issue list,
the roadmap — and a dashboard is not the place to make an exception.

In practice the numbers are usually identical: if every viewer has `:view_issues`
with `issues_visibility: all`, there are no private issues and no role-restricted
fields in play, everyone sees the same thing. The figures diverge exactly where
Redmine's permissions are meant to make them diverge.

If you need one set of numbers that is provably the same for everyone, export the
**PDF once** and distribute that file. Then it is explicit that it is "the numbers as
of this date, as seen by this account", instead of a live page that quietly reports
something different per reader. It is also worth putting that in the caption of a
shared widget — for example `{{ stats.total }} issues you can see` — so nobody reads
a permission difference as a bug.

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
| `fields` | – | Field list for `group_by: completeness`, semicolon or comma separated (max 12) |
| `measure` | `count` | `count`, `distinct`, `sum` or `avg` — see [Measures](#measures) |
| `of` | – | Field the measure applies to (`author`, `cf_94`, `estimated_hours`, `spent_hours`) |
| `drill` | `false` | `true` adds drill-through URLs — see [Drill-through URLs](#drill-through-urls) |
| `drill_max_url` | `2000` | Maximum URL length; over it the URL sheds `c`/`t`, then `group_by`/`sort`, and only then gives up |
| `drill_inherit` | `all` | `all` or `filters` — what a drill-down URL inherits from the report query |

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
    labels: [{% for row in xtab.rows %}{{ row.label | json }}{% unless forloop.last %},{% endunless %}{% endfor %}],
    datasets: [
      {% for name in xtab.series %}
      {
        label: {{ name | json }},
        backgroundColor: ['#4e79a7', '#e15759', '#59a14f'][{{ forloop.index0 | json }} % 3],
        data: [{% for row in xtab.rows %}{{ row.cells[name] | json }}{% unless forloop.last %},{% endunless %}{% endfor %}]
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
| `stats.open_at_end` | array | Issues still open at the **end** of each period |
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
| `.buckets[].value` | string | The **raw stored value** behind the label (`415`), `nil` for the `Other` and no-value rows |
| `.buckets[].values` | array | Every raw value an `Other` row collapsed; present on that row only |
| `.buckets[].filter` | hash | `{field, operator, values}` — the issue-list filter isolating that row, or `nil` |
| `.measure` | string | `count` (the default), `distinct`, `sum` or `avg` |
| `.measure_field` | string | The `of:` field, `nil` for a plain count |

`value` is what `custom_values.value` (or `issues.status_id`, …) actually holds,
which is what a filter URL needs; `label` is unchanged and stays the text to
print. `filter` is `nil` whenever the row cannot be expressed as an issue-list
filter, in which case there is no drill-down URL for it either.

**Crosstab** (`split_by` present):

| Key | Type | Content |
|-----|------|---------|
| `.series` | array | Series labels — the `split_by` axis (plain strings, unchanged) |
| `.series_entries` | array | `[{label, value, filter}, ...]`, aligned with `.series` |
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
`newest_open_days`, `median_open_days`, `p90_open_days`. They are available both at the top level (`{{ kpi.total }}`)
and under `flags` (`{{ kpi.flags.total }}`). `open` / `closed` honour
`closed_statuses`, `overdue` counts open issues past their due date, and the
`*_open_days` values are `nil` when nothing is open.

**`median_open_days` and `p90_open_days`** are fairer openers than "the oldest is
146 days": one outlier cannot move them. `p90` is the old end — 90% of open issues
are younger than that — so it is always at or above the median.

```liquid
Half the open work is older than {{ kpi.median_open_days }} days;
one in ten is older than {{ kpi.p90_open_days }} days.
```

They are read with a portable offset rather than `percentile_cont`, which is
PostgreSQL only: two indexed single-row reads ordered on `created_on`. Two
consequences worth knowing:

- It is the **lower** percentile, not the interpolated one. With an even number of
  open issues the median is the younger of the two middle ages instead of their
  average, and with very few open issues `p90` can land on the same issue as the
  median. For issue ages that is a distinction without a difference, and it is what
  buys MySQL support.
- The offset counts **rows**. If the report query itself carries a join that
  multiplies rows — sorting or grouping on a multi-valued custom field — the
  percentile can shift by a place or two. The counts around it are unaffected;
  they all count distinct issues.

`stages` projects four of them as a funnel, so a funnel widget does not have to
hardcode which counter maps to which filter:

| Key | Label | Filter |
|-----|-------|--------|
| `total` | Registered | `nil` — the report query unchanged |
| `assigned` | Has assignee | `assigned_to_id` `*` |
| `with_due_date` | Has due date | `due_date` `*` |
| `closed` | Closed | `status_id` `c` |

The labels are English defaults, like `Other` and `(none)`; use `stage.key` if
your template needs its own wording.

On any error — an unresolvable scope, an invalid dimension, a database problem —
the tag assigns an empty-safe result with **all** of these keys (empty arrays,
zeros, `false`) and logs to `Rails.logger`, so a template that reads `res.rows`
or `res.series` still renders.

### `group_by: completeness` — how much is actually filled in

Every other widget on a dashboard is only as trustworthy as the data behind it. A
Department chart says nothing useful if Department is filled on 22% of issues.

```liquid
{% sql_aggregate from: issues, group_by: completeness,
   fields: "cf_86;cf_92;cf_94;cf_99;assigned_to_id;due_date",
   drill: true, assign_to: filled %}

<table>
{% for f in filled.buckets %}
  <tr>
    <td>{{ f.label }}</td>
    <td>{{ f.pct }}%</td>
    <td>{% if f.empty > 0 and f.empty_url %}
          <a href="{{ f.empty_url }}" target="_blank">{{ f.empty }} to fix</a>
        {% else %}{{ f.empty }}{% endif %}</td>
  </tr>
{% endfor %}
</table>
```

One bucket per field named in `fields:`, **in that order** — `sort` and `limit` do
not apply, like `period` and `age`:

| Key | Content |
|-----|---------|
| `.buckets[].label` | The custom field's name, or the core field's label |
| `.buckets[].count` | Issues where it **is** filled, so an existing bar chart works unchanged |
| `.buckets[].empty` | Issues where it is not |
| `.buckets[].total` | Issues in scope |
| `.buckets[].pct` | `count / total`, rounded to an integer |
| `.buckets[].value` | The field key (`cf_94`, `assigned_to_id`) |
| `.buckets[].url` | Issue list filtered to "is set" (with `drill: true`) |
| `.buckets[].empty_url` | Issue list filtered to "is **not** set" — the actionable one |
| `.total` | Issues in scope, **not** the sum of the buckets |

`fields:` accepts `cf_<id>` and the nullable core fields `assigned_to_id`,
`category_id`, `fixed_version_id`, `parent_id`, `due_date`, `start_date`,
`estimated_hours` and `description`, plus the dimension-style aliases (`assignee`,
`version`, `category`, `parent`, `due`, `start`, `estimated`). A field that cannot
be resolved is skipped with a logged warning; more than 12 is refused outright
rather than building an unreadable chart.

It is one statement: one conditional aggregate per field, and a **single**
`custom_values` join for all of the custom fields rather than one join each.

Three caveats:

- **`empty_url` is the actionable link, and it is deliberately not in `url`.**
  `url` is "is set", `empty_url` is "is not set". Redmine does not allow the
  "none" operator on every filter type — a status-like list has no `!*` — so
  `empty_url` can be `nil` while `url` works. Check it before printing a link.
- **A multi-valued custom field counts as filled when it holds at least one value.**
- **The percentages are what the *viewer* may see.** A custom field restricted to
  roles is skipped entirely for a user without them — the bucket is absent rather
  than reported as 0% — so two people can legitimately see a different number of
  bars, and a scheduled PDF reports whatever the account rendering it can see. See
  [Who sees what](#who-sees-what-two-people-two-sets-of-numbers).

### Measures

Every bucket value is a count of issues unless you say otherwise. `measure:` changes
what the number *is*:

| `measure` | Needs `of:` | Meaning |
|-----------|-------------|---------|
| `count` | no | Issues per bucket. The default, unchanged. |
| `distinct` | yes | `COUNT(DISTINCT of)` — how many *different* values |
| `sum` | yes, numeric | `SUM(of)` |
| `avg` | yes, numeric | `AVG(of)`, rounded to 2 decimals |

`of:` accepts `author`, `assignee`, `tracker`, `status`, `priority`, `category`,
`version`, `project` and `issue` (all `distinct` only), the numeric columns
`estimated_hours` and `done_ratio`, `spent_hours` (`sum` only), and `cf_<id>` —
`distinct` on any format, `sum` / `avg` only on an `int` or `float` field.

The question this answers that a count cannot:

```liquid
{% sql_aggregate from: issues, group_by: period, period: month, periods: 12,
   measure: distinct, of: author, assign_to: filers %}

{% for label in filers.buckets %}
  {{ label.label }}: {{ label.count }} different people filed
{% endfor %}
```

That is an adoption curve rather than a volume curve — twelve lessons from one
person is not the same as twelve from twelve people, and a row count cannot tell
them apart.

The result gains `measure` and `measure_field` so a template knows what it is
holding. Everything else — buckets, labels, drill-through, `limit`, `Other` — works
as before, with these consequences:

- **Bucket values do not add up to `total` any more.** A distinct count does not
  add up and an average certainly does not, so for those measures `total` is the
  same measure computed over the whole scope in its own query. It will usually be
  *smaller* than the sum of the buckets (the same person files in several months).
  For `measure: count` `total` stays exactly what it was: the sum of the buckets.
- **The `Other` bucket is its own aggregate** for `distinct` and `avg`, not the sum
  of what it collapsed. Same for the row and column totals of a crosstab.
- **A cumulative percentage or Pareto is a count-only chart.** Running totals of
  distinct counts or averages mean nothing.
- **`sort: count` keeps its name** and means "by the measure value, descending".
- **A distinct-count bar will not match the row count of its own drill-down list**,
  and that is not a bug: the bar says "7 different authors", the list shows all
  their issues. Drill-through URLs are unaffected by the measure.
- **A multi-valued custom field as the dimension inflates a `sum`**, the same way it
  inflates a count: the issue is joined once per value, so its hours are counted
  once per value. Check `.multi_value`.
- **A corrupt value in a numeric custom field is skipped, not fatal.** Empty values
  never reach the cast — the join leaves them out — and a value that is not a number
  yields `NULL`, which `SUM` and `AVG` ignore.
- `avg` on an empty bucket is reported as `0`, not `nil`, so a chart array stays
  valid JavaScript.
- `measure:` needs a `group_by`. The time series always counts issues, and
  `group_by: flags` has fixed counters; both log a warning and ignore it.

### Drill-through URLs

`drill: true` turns every bar, slice, point and heatmap cell into a link to the
Redmine issue list, filtered to exactly the subset that element represents — in
the context of the report's own query.

```liquid
{% sql_aggregate from: issues, group_by: cf_92, drill: true, assign_to: by_dept %}

{% for b in by_dept.buckets %}
  {% if b.url %}
    <a href="{{ b.url }}" target="_blank">{{ b.label }}</a>: {{ b.count }}
  {% else %}
    {{ b.label }}: {{ b.count }}
  {% endif %}
{% endfor %}
```

Clicking *Survey* in a Department chart opens the issue list showing the
report's own issues, narrowed to Department = Survey.

**What the URL inherits.** Everything, not just the filters: the report query's
filters, columns, grouping, totals and sort order, plus the dimension filter, with
`set_filter=1`. A saved query cannot be extended through a URL — Redmine's
`retrieve_query` short-circuits on `query_id` and ignores any `f`/`op`/`v` that
follow — so the parameters are replicated instead. The serialisation is Redmine's
own `Query#as_params`, applied to an unsaved copy of the query, so the parameter
names stay correct across Redmine versions.

**Keys added by `drill: true`:**

| Key | Content |
|-----|---------|
| `.drill_available` | `true` when URLs were emitted, `false` when no `IssueQuery` could be resolved |
| `.base_url` | The report query itself, unfiltered by any dimension |
| `.buckets[].url` | One element URL, or `nil` |
| `.rows[].url` | Crosstab row URL |
| `.series_entries[].url` | Crosstab series URL |
| `.stages[].url` | Funnel stage URL (`total` links to `base_url`) |
| `.cell_urls` | Dense rows × series array, aligned with `matrix`; each entry ANDs the row and series filters |
| `.cell_urls_truncated` | `true` when the crosstab was past the 5000-cell cap, so every `cell_urls` entry is `nil` for that reason and not for lack of a filter |
| `.drill_degraded` | `true` when at least one URL had to drop its inherited columns and totals to fit — the linked list then matches the element but is not laid out like the report |

Without `drill`, none of these keys exist and the result is exactly what it was
before — existing templates are unaffected.

**URLs are absolute** (`https://host/projects/<identifier>/issues?…`, or
`/issues` for a query without a project), built from `Setting.protocol` and
`Setting.host_name` like `issue.target_version` already is, because the same
markup is exported to PDF where a relative path has nothing to resolve against.
They are already percent-encoded; print them with `{{ b.url }}`, no `escape`
filter needed.

**`drill: true` implies the dimension path.** Only it knows the raw stored value
behind a label. For one of the seven core fields that means the dimension's own
labels — display names for `assignee` / `author` instead of logins; pass
`user_label: login` to keep the legacy text. A falsy `drill` changes nothing.

**What `drill_inherit: filters` is for.** The default inherits the report's
`group_by` too, so clicking *Survey* in a Department chart lands on a list grouped
by Department with exactly one group. Harmless, but if you would rather land on a
plain flat list — or you want the shortest possible URL — `drill_inherit: filters`
keeps the filters and drops the columns, grouping, totals and sort order.

**No URL is better than a wrong URL.** An element gets `nil` instead of a link
when:

- the dimension is not an available issue-list filter — a custom field needs
  `is_filter` and must be enabled for the project and the tracker (logged once
  per render);
- Redmine does not allow the operator on that filter type (a boolean custom field
  is a plain list with no "none" operator, for instance);
- the bucket cannot be expressed as a filter at all (a group value that is not a
  period or age label);
- the bucket range and the query's own date filter are **disjoint** — a zero-count
  period bucket outside the report's window, which no drill-down can populate;
- the dimension is a **date** filter but the bucket's stored value is not a date
  Redmine accepts (a date-format custom field holding something else): Redmine
  would answer "Date is invalid" rather than a list;
- the URL is still over `drill_max_url` (2000 characters by default) **with the
  filters alone** — an `Other` row collapsing hundreds of values hits this, and
  gets no link rather than a truncated one. Each refusal logs the real length and
  the cap, so you can raise `drill_max_url` deliberately instead of guessing why
  some bars are clickable and others are not.

**Over-long URLs shed the cosmetics before they give up.** Because a drill-down
inherits `c[]`, a report with many columns can push a two-filter crosstab cell
past the cap on its own. Rather than lose the link, the URL is rebuilt without the
inherited columns and totals, and if that is still too long without the grouping
and sort order either. The filters are never dropped — they are what makes the
list match the element. `drill_degraded` reports that it happened, and one log
line per render says what was dropped. Set `drill_inherit: filters` to take that
route from the start.

**Replace versus intersect.** Redmine allows exactly one filter per field, so the
dimension filter is merged into the inherited set:

- field not filtered yet → added;
- field already filtered, **non-date** → **replaced**. A bucket is by construction
  a subset of whatever the query filtered on that field, so replacing cannot
  widen the result;
- field already filtered, **date** (`period`, `age`) → **intersected**, because
  replacing a date range could widen it. Only absolute operators (`><`, `>=`,
  `<=`, `=`) can be intersected at render time. When the query uses a relative
  one (`t-`, `w`, `m`, `>t-`, …) the drill-down falls back to the bucket range and
  logs at debug level: **this is the one case where the drill-down can show more
  issues than the chart element counted.**

**Period and age ranges.** A period bucket becomes `created_on` (or `closed_on`)
`><` the bucket's first and last day. An age bucket becomes the range its label
names — `31-60` is `[today-60, today-31]` — with the newest bucket open at the
recent end (`>=`) and the oldest open at the old end (`<=`). The SQL compares
timestamps while a Redmine date filter compares dates, so an issue created on a
boundary day can land in the neighbouring bucket; and the buckets are computed in
the server time zone while the filter is applied in the viewer's.

**Multi-valued custom fields.** As with the `multi_value` flag, an issue holding
several values is counted once per value, and the drill-down lists every issue
holding the clicked value. The counts agree with each other; they just sum to more
than the number of issues. An empty entry among those values is ignored, so such an
issue does not also appear in the no-value bucket.

**Permissions.** See [Who sees what](#who-sees-what-two-people-two-sets-of-numbers)
for the whole picture. A drill-down is only a filter — Redmine re-applies issue
visibility when the list is rendered. A viewer may therefore see fewer issues
than the chart suggested if the chart was rendered for someone else (a scheduled
report, a shared PDF). That is correct behaviour, not a mismatch to fix.

There is one case that goes the other way, and it cannot be fixed from here: the
URL is built against the *renderer's* `available_filters`. If the person who opens
a shared link may not use that filter at all — a custom field restricted to roles
they do not have — Redmine's `add_filters` drops it and they land on the report's
own list, unnarrowed. The link is validated when it is written, but only the click
decides. If that matters for a report you share outside its project, prefer
filters everyone involved can use.

**`closed_statuses` and the funnel.** The `closed` stage links with
`status_id=c`, Redmine's own `is_closed` flag, so it stays right whatever
`closed_statuses` was passed. If you pass an explicit `closed_statuses:` that is
not the same set, the stage count and the linked list differ; the tag logs a
warning when both are in play.

**Cost.** `drill: true` adds one `available_filters` build per render (a handful
of small queries) and no query at all per element. It runs no extra aggregation.

**Time series.** `drill: true` is not supported for the time-series mode (no
`group_by`): its labels carry no raw value to filter on. Use
`group_by: period` instead — same chart, drillable buckets. The tag sets
`drill_available` to `false` and says so in the log.

#### Worked example — a clickable crosstab chart

`cell_urls` is aligned with `matrix`, so the Chart.js `onClick` idiom the
"Version overview" template already uses works unchanged:

```liquid
{% sql_aggregate from: issues, group_by: cf_92, split_by: cf_86,
   drill: true, assign_to: xt %}

<canvas id="chart_xt" width="600" height="300"></canvas>
<script>
(function(){
  var labels = [{% for r in xt.rows %}{{ r.label | json }}{% unless forloop.last %},{% endunless %}{% endfor %}];
  var urls   = [{% for row in xt.cell_urls %}[{% for u in row %}{% if u %}{{ u | json }}{% else %}null{% endif %}{% unless forloop.last %},{% endunless %}{% endfor %}]{% unless forloop.last %},{% endunless %}{% endfor %}];

  // Same shape as openFrom() in the "Version overview" template, one dimension deeper.
  function openCell(urlGrid, chart, evt){
    var pts = chart.getElementAtEvent(evt);
    if (pts && pts.length){
      var row = urlGrid[pts[0]._index] || [];
      var u   = row[pts[0]._datasetIndex];
      if (u) window.open(u, '_blank');
    }
  }

  new Chart(document.getElementById('chart_xt'), {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [
        {% for s in xt.series_entries %}
        { label: {{ s.label | json }},
          data: [{% for r in xt.rows %}{{ r.cells[s.label] | json }}{% unless forloop.last %},{% endunless %}{% endfor %}] }{% unless forloop.last %},{% endunless %}
        {% endfor %}
      ]
    },
    options: {
      onClick: function(e){ openCell(urls, this, e); },
      animation: { duration: 0 }
    }
  });
})();
</script>
```

For a single-dimension chart the row-only variant is simpler — collect the URLs
into one array and reuse `openFrom(urls, this, e)` exactly as the version
dashboard does:

```liquid
var urls = [{% for b in by_dept.buckets %}{% if b.url %}{{ b.url | json }}{% else %}null{% endif %}{% unless forloop.last %},{% endunless %}{% endfor %}];
```

**A `<canvas>` is a raster in an exported PDF: `onClick` works on screen only.**
HTML-based widgets — a table, or the heatmap — get real `<a href>` elements and
stay clickable in the PDF, which is the reason the URLs are absolute.

### Notes and caveats

- **Counting.** The dimension path counts `COUNT(DISTINCT issues.id)`, because the
  query's own scope may already join tables that multiply rows (a filter on a
  custom field, watchers, spent time) and the custom field dimension adds a join
  of its own. The seven core fields keep their original plain `COUNT(*)` when
  used without any of the new parameters, so existing templates are unaffected.
- **Multi-valued custom fields.** An issue with several values is counted once per
  value, so the bucket counts sum to more than the number of issues. Check
  `.multi_value` if that matters for the caption you print. A drill-down from such
  a bucket lists every issue holding that value, so the two agree with each other
  — they just both exceed the issue count.
- **Labels come from your data.** Custom field values, user names and version
  names end up in the result. Escape them in HTML and in Chart.js label arrays
  (`{{ label | escape }}`), exactly as the version dashboard example does.
- **Duplicate series labels.** If two stored values resolve to the same label,
  `series` contains that label twice and `cells` keeps only the last of them;
  `counts` and `matrix` stay correct and aligned.
- **Three joins.** A crosstab over two custom fields with a custom-field measure
  carries three `custom_values` joins (`rrd_cv_g`, `rrd_cv_s`, `rrd_cv_m`). Each one
  fans for a multi-valued field, and they multiply: an issue with 5 departments, 3
  lesson types and 2 values in the measured field produces 30 rows. Counts stay
  right (they are `DISTINCT`), sums do not — see the `multi_value` note above.
- **Cost.** The time series runs one extra statement for `open_at_end` (three for a
  90-day window, which is chunked), so an existing time-series widget costs a little
  more than it did. Each period in it is a `COUNT(DISTINCT … CASE …)`, so a 90-day
  window is materially more expensive than a 13-week one covering the same span —
  prefer `week` or `month` for long windows. The aggregation itself is always a single `COUNT … GROUP BY`, one or
  two dimensions alike. Label resolution adds at most one batched primary-key
  lookup per dimension (one more when `sort: position` needs the enumeration
  order). `flags` runs a handful of small aggregates. No issue is ever loaded
  into Ruby, and nothing is done per row.

## Reporting on spent time

A report template has a **data source**. Set it to *Spent time* and the same tag and the same
bucket structure report **hours** instead of issue counts — one template model, one editor,
one preview, two sources.

```liquid
{% sql_aggregate group_by: activity, assign_to: by_activity %}

{% for bucket in by_activity.buckets %}
- {{ bucket.label }}: {{ bucket.count }} h
{% endfor %}
Total: {{ by_activity.total }} h
```

`bucket.count` carries the **measure**, which is hours here — the same key an issue report
uses for its counts, so a template written against one source reads the other. `measure`
and `measure_field` on the result say which you are looking at (`hours`/`hours` or
`count`/`nil`), and the result's key set is asserted against a real issue-path call by a test
rather than promised here.

### `from:` is not used on a time-entry template

The scope comes from the template's source and the saved query on the page, not from the
tag. `from: issues` inside a *Spent time* template is ignored; use `query_id:` to point at a
saved **spent-time** query.

### Dimensions

| On the entry itself | Through the entry's issue |
|---|---|
| `activity` · `user` · `project` · `issue` | `tracker` · `status` · `priority` · `author` · `assignee` · `version` · `category` |

`activity` and `user` do not exist on the issue path at all — they are the two an hours
report is usually about. The seven on the right need the entry to be joined to its issue,
which a saved spent-time query provides; without one they are refused and the page says so
rather than reporting a wrong number.

An entry with no activity, or logged against a project rather than an issue, lands in the
`(none)` bucket — never folded into `(other)`, however tight the `limit:` — and its filter
payload asks for *none* rather than for an empty value.

An hours-by-issue axis names each issue `#42: subject`. **An issue you may not see is named
`#42` and nothing else**, exactly as Redmine's own spent-time report does it: the hours are
still yours to see and count, the issue's subject is not yours to read.

Activities a project has **overridden** are rolled up to the activity they override, so you
get one bucket rather than two carrying the same name — again matching the report Redmine
ships.

### Measures

| `measure:` | What it computes |
|---|---|
| `hours` (default) | `SUM` of the hours logged, rounded to two places |
| `count` | how many entries, counted distinctly |

`limit:`, `other_label:` and `empty_label:` behave as they do on the issue path, including the
folded `(other)` bucket and the `truncated` flag that admits to it. **An axis is capped at 200
buckets whether or not you set a `limit:`** — the same ceiling the issue path has — and the
tail is folded rather than dropped, with a note on the page saying how many.

`sort:` takes `count` (default) or `label`. `position` is not available here, and asking for
it says so on the page rather than quietly ordering by something else. Ties are broken
deterministically, so two engines and two page loads agree on the order — and, past the cap,
on which buckets exist at all.

### What it does not do

Each of these is **refused visibly** — the aggregation still returns what it can, and the page
lists what it could not do. None of them fails silently.

- **No time series.** `{% sql_aggregate %}` with no `group_by` is refused: a time entry is
  not opened and closed, so there is nothing to plot over time. Filter by `spent_on` on the
  saved query instead.
- **No `split_by:`**, so no crosstab over two dimensions.
- **No `drill: true`.** Buckets carry the filter payload a drill-through would be built from,
  and a spent-time URL is not built from it yet, so `bucket.url` is not set. The payloads are
  checked against Redmine's real spent-time filter list by a test, so what is there is right;
  it is the link that is missing.
- **No custom-field dimensions.** The issue path can group by `cf_92`; this one cannot group
  by a time-entry, project or issue custom field yet.
- **`{% version_rollup %}` is issue-only** and is refused on a time-entry template, visibly.
- **Mixing sources in one template is not supported** and is not planned. A report is about
  issues or about hours.

### You see the hours your role lets you see, and the report says when that is less

Redmine's own permission for spent time has three states per role: all of it, **only your
own**, or none. The middle one is the dangerous one — an ordinary member opens the team's
hours report and sees a smaller, entirely believable total with nothing to indicate it is
their own timesheet. So the page carries a notice when your role narrowed the data, and the
report is not silently smaller. Turning the project's *Time tracking* module off means no
hours at all, for administrators too, and that is also said rather than shown as zero.

### Cost, and one limit worth knowing

An hours breakdown costs **three statements** — the grouped read, one batched label lookup
for every bucket at once, and the total. A count breakdown costs two, because a counted axis
is totalled from its own buckets. Neither grows with the number of buckets, and no time entry
is ever loaded into Ruby.

**The one limit:** if a query's own joins multiply rows, the entry *count* is still right
(it is `DISTINCT`) but the **hours sum is not** — it multiplies with them. No `SELECT
DISTINCT` fixes a `SUM`: two people logging the same number of hours are two entries, not a
duplicate. None of Redmine's own spent-time filters produces such a join, so this does not
arise in normal use; it is written down here because it would be invisible if it ever did.

### Legacy alias

The tag was previously called `{% geo_aggregate %}`. That name still works as an alias so existing templates keep working without changes.

## Using the `{% geo_version_map %}` tag — **deprecated**

> **This tag is removed in the next minor version.** It still works exactly as
> documented below, writes one deprecation line to the log per process, and the
> template linter reports it as a warning. Everything it provided is now on the version
> object itself — see [Migrating off `{% geo_version_map %}`](#migrating-off--geo_version_map-)
> at the end of this section. Run `rake reporter_dashboards:migrate_from_reporter:plan` to list the
> templates that still use it.

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

By default the map covers **every version the person reading the report may see** — never every version in the database. Pass a project identifier to limit it to that project's shared versions:

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

### Migrating off `{% geo_version_map %}`

The tag existed for one reason: the version was a bare name and you needed its id. It
is not any more. Delete the tag and read the version directly — the version still prints
and compares as its own name, so `{% if issue.version == "2026.1" %}` keeps working.

```liquid
{% comment %} before {% endcomment %}
{% geo_version_map assign_to: geo_versions %}
{% assign v = geo_versions[issue.version] %}
<a href="/projects/{{ v.project }}/roadmap">{{ issue.version }}</a>

{% comment %} after — no tag, and the link is absolute so it survives PDF export {% endcomment %}
<a href="{{ issue.version.roadmap_url }}">{{ issue.version }}</a>
```

| Was | Now |
|-----|-----|
| `geo_versions[issue.version].id` | `issue.version.id` |
| `geo_versions[issue.version].effective_date` | `issue.version.effective_date` |
| `geo_versions[issue.version].status` | `issue.version.status` |
| `geo_versions[issue.version].project` | `issue.version.project_identifier` |
| hand-built roadmap / issue-list / time URLs | `.roadmap_url` `.issues_url` `.open_issues_url` `.closed_issues_url` `.time_url`, all absolute |

The same accessors are on `{% version_rollup %}`'s `row.version`, so a dashboard built on
that tag needs no change at all.

## Using the `{% chart %}` tag

> **This tag needs the plugin's own report renderer, which is still being built.** Pasted
> into a Reporter report template today it records the chart and leaves a placeholder that
> Reporter's renderer does not fill. The two hand-written example templates are unchanged
> and keep working.

Point it at anything `{% sql_aggregate %}` or `{% version_rollup %}` assigned:

```liquid
{% sql_aggregate from: issues, group_by: status, drill: true, assign_to: by_status %}
{% chart id: status, from: by_status, title: "Issues by status", y_title: "Issues" %}
```

That is the whole chart. There is no `<canvas>`, no `<script>`, no Chart.js config, no
data array, no readiness handshake and no `responsive: false` — and none of them is
something you are allowed to add, because each is a fact about the renderer rather than
about the report. See [`examples/chart_tag_showcase.liquid`](examples/chart_tag_showcase.liquid).

### Parameters

| Parameter | Content |
|-----------|---------|
| `id` | Required. Letters, digits, `_` and `-`; it becomes a DOM id, so it is restricted rather than escaped. Two charts sharing one is refused, not renamed |
| `from` | The variable holding the aggregation result (default: `stats`) |
| `type` | `bar` (default), `stacked_bar`, `diverging_stacked_bar`, `line`, `pie`, `doughnut`, `progress`. Anything else still draws, through Chart.js, and says so |
| `orientation` | `vertical` (default) or `horizontal`. On a horizontal bar the category labels move to the value-axis side and the layout reserves the width for them |
| `title` `x_title` `y_title` | Text |
| `width` `height` | Pixels (default 640 × 360), bounded |
| `x` `y` | Which keys to read. For a breakdown, `y` is the bucket key (`count` by default, or `value` for a measure). For a time series, `y` is a comma-separated list of the arrays to draw — `created,closed` by default, because putting `open_now` on the same axis is a chart nobody asked for |
| `legend` | `true` / `false`. Left alone it shows when there is more than one series, and for a pie when there is more than one slice |

Drill-through comes from the aggregation, not from the chart: `drill: true` on the
`{% sql_aggregate %}` puts a URL on every bucket, and the chart carries it through — as an
`<a xlink:href>` per element in the SVG, and as a click handler in the browser.

### The two outputs

| | On screen | In a PDF |
|---|---|---|
| Element | `<canvas>` + a `<script type="application/json">` data block | inline `<svg>` |
| Drawn by | the bundled Chart.js 4.5.0 | the server, in Ruby |
| JavaScript | yes | **none** |
| Drill-through | click handler | real links, so a PDF chart is clickable |
| Text | canvas pixels, plus an `aria-label` carrying the numbers | selectable, with `<title>`/`<desc>` carrying the numbers |

An unsupported type is the one case that needs JavaScript in the PDF as well; the plugin
knows that as a fact about the document rather than by searching the finished HTML for a
`<canvas>`, and negotiates the engine's capabilities accordingly.

### Why they agree

Everything a chart's geometry depends on — the value range, the tick array, the tick
labels, the palette, the label truncation and the plot rectangle — is computed **once**, on
the server, and handed to both paths. Chart.js is given explicit bounds and an explicit
tick array and is not allowed to choose its own.

That is checked rather than asserted: `spec/charts/shared_layout_falsifier_spec.rb` renders
a horizontal bar with twelve long labels in a real browser and compares Chart.js's own plot
area with the server's. It currently agrees to within **1.17%**, against a 2% tolerance,
and it runs in CI on every push. If it ever exceeds the tolerance the answer is to serve
the server-drawn SVG on both paths, not to widen the tolerance.

### Accessibility

Charts are readable without being seen (FR-76). Every SVG carries a `<title>` and a
`<desc>` with the numbers in them; every canvas carries the same sentence as an
`aria-label`; the palette is the Okabe–Ito set designed for the three common colour-vision
deficiencies; and every fill has a darker outline, so two adjacent bars stay two bars in a
greyscale print. Meaning is never carried by colour alone.

## Using the `{% mermaid %}` tag

```liquid
{% mermaid id: approval %}
graph LR
  A[Submitted] --> B{Approved?}
  B -->|yes| C[Scheduled]
  B -->|no| A
{% endmermaid %}
```

Mermaid 11 ships inside the plugin — nothing is fetched from the internet when a report is drawn.
In a PDF the diagram is real vector graphics: selectable, searchable, and printable at any size.

**The body is not interpreted.** Mermaid syntax is full of `{`, `}` and `|`, which a template
language would otherwise try to read as its own markup. Write ordinary Mermaid; nothing is done to
it.

### Parameters

| Parameter | Default | What it does |
|---|---|---|
| `id` | `mermaid` | Identifies the diagram in the page. Letters, digits, `_` and `-` |
| `interpolate` | `false` | Allows `{{ value }}` in the diagram — see below |

### Putting report data into a diagram

```liquid
{% mermaid id: release interpolate: true %}
graph LR
  A[{{ version.name }}] --> B[{{ version.status }}]
{% endmermaid %}
```

Two limits, both deliberate:

- **Values, not template logic.** `{{ something }}` is substituted; `{% if %}` and `{% for %}` are
  not run, and filters are not applied. A diagram is not a place for control flow — build the text
  above the tag and interpolate one variable if you need to.
- **Substituted values are escaped.** An issue subject is written by whoever wrote the issue, not
  by you, so it goes in as text and cannot become markup. This is the one place in a diagram where
  content you did not write ends up in the output, which is why it is the one place with a rule.

### When a diagram cannot be drawn

You get **the diagram source, marked as undrawn** — never a blank space. A reader can see that
something was meant to be there and what it said.

That happens on the old wkhtmltopdf engine, which reports having JavaScript and cannot run any
library written in the last several years. The engine comparison at
[`docs/engine-support-matrix.md`](docs/engine-support-matrix.md) has a **modern JavaScript** row
that says so; if it reads `—` for your engine, diagrams and current Chart.js will not draw and the
fix is to switch engines rather than to change the template.

A diagram larger than **16 KB of source** is refused rather than spending the render budget on a
drawing nobody can read. The refusal leaves a marked, empty block so the gap is visible.

### Using other JavaScript libraries

Nothing about the above is specific to Mermaid. A report can use any modern JavaScript library:
reference it like any other asset and it is embedded in the document, and tell the renderer to wait
for it with `window.__rd.begin()` and `window.__rd.end()` around your own drawing code. Chart.js and
Mermaid ship with the plugin because they are the common cases — not because they are the only ones
supported.

## Using the `{% version_rollup %}` tag

Aggregates the report's issues per target version in SQL and assigns a ready-to-render Array. Use it instead of a nested `{% for version %}{% for issue %}` loop when you build a per-version dashboard.

```liquid
{% version_rollup from: issues, closed_statuses: "Closed;Rejected", cost_fields: "20,21", assign_to: versions %}
{% for v in versions %}
  <h3><a href="{{ v.version.url }}">{{ v.name }}</a></h3>   {# v.version is the version object, nil for the "None" bucket #}
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
| `.version` | object / nil | The version, with the same accessors as `issue.target_version` (absolute, PDF-safe URLs: `.url`, `.roadmap_url`, `.issues_url`, …); nil for `None` |
| `.total` `.open` `.closed` | integer | Issue counts |
| `.open_done_sum` | integer | Σ `done_ratio` over open issues (for % complete) |
| `.overdue_open` `.unassigned_open` `.no_estimate` | integer | Flag counts |
| `.est_hours` `.spent_hours` | float | Σ estimated / spent hours |
| `.start_date` `.due_date` | date / nil | MIN start / MAX due over the version's issues |
| `.cost` | hash | `{ "<field_id>" => float }` summed per numeric custom field |

Cost sums mirror Redmine's own numeric custom-field totalling (`joins(:custom_values)`, empty values skipped, `CAST(... AS decimal)`), so they are correct on PostgreSQL and MySQL. On any error the tag assigns an empty Array so the template never crashes. See [`examples/version_status_dashboard.liquid`](examples/version_status_dashboard.liquid) for a full dashboard built on this tag.

## `issue.target_version` in report templates

`issue.target_version` is a drop wrapping the issue's target version with everything needed to build links — and **all URLs are absolute**, so they keep working when a report is exported to PDF by wkhtmltopdf. It is also what `{% version_rollup %}` puts in each row's `.version`.

### What changed for `issue.target_version`

Until now this accessor was added by **prepending a module into Reporter's own issue drop**. A prepend is a second owner for another plugin's method table: it breaks silently when their class moves, and it is precisely the coupling this plugin is removing.

It is gone. Both `issue.target_version` and `issue.custom_field_value` are now defined on **this plugin's own issue drop**, with the same spelling and the same behaviour — `target_version` as a second name for `issue.version`, which is now a full version object rather than a bare string.

One consequence worth stating plainly, because it is a real gap rather than a detail: **this plugin's issue drop is not yet what renders a Reporter report.** Until the owned report renderer ships, a template rendered by Reporter gets Reporter's drop, which has neither accessor — so `{% if issue.target_version %}` is simply false and that part of the report renders empty. `{% version_rollup %}` and `{% sql_aggregate %}` are unaffected, and `{% geo_version_map %}` (deprecated, still working) reaches the same version metadata in the meantime.

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
| `.sharing` | Redmine's version sharing mode |
| `.completed_percent` | Completion percentage |
| `.project` | The version's project, itself an object (`.name`, `.identifier`, `.url`) |
| `.project_identifier` / `.project_name` | The same two facts as plain strings |
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

Report widgets show an **Export as PDF** link in their header. It opens the same report the widget renders — the same template, over the same scope — as a PDF in a new tab, through this plugin's own render path: the export and the widget are one resolution differing in one argument, so the export cannot show a report the widget would refuse. PDF output needs one of this plugin's render engines to be available; see [`docs/engine-support-matrix.md`](docs/engine-support-matrix.md) and the admin render preflight page. A failure answers with a clean error page and no bytes, never a file named `.pdf` that is not one.

A widget's export is bounded the way the widget is: it draws **one** document, and only `combined` report templates are offered to a widget, because a dashboard box is one document and a per-record template is one per row.

### Which PDF path a report takes, and which rules apply to it

There are two, and which one you are on decides whether the constraints below apply.

**This plugin's own report templates** — the ones the widgets above render, authored under
a project's **Reports** tab — go through this plugin's render path: three engines behind
one interface, a readiness protocol instead of a fixed delay, and a conformance corpus that
measures what each engine actually does
([`docs/engine-support-matrix.md`](docs/engine-support-matrix.md), generated from the run
rather than written by hand). The flexbox and `responsive: false` rules below are a
property of the engine your installation selected, not something you have to remember; on
Chromium or Gotenberg they do not apply at all.

**Reporter's own report templates**, rendered by that plugin, still go through its
wkhtmltopdf call with a fixed delay and injected polyfills — and the rules below are the
truth for those.

**This paragraph used to say "None of it is wired to a button yet."** That was true when it
was written and stopped being true when the project-dashboard widgets became this plugin's
own; the export link in a widget header is that button.

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
