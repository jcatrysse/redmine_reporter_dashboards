# Implementation plan — standalone `redmine_reporter_dashboards`

- **Idea:** 004-redmine-reporter-modern · **Decision:** **ADR-004**
- **Specs:** [`functional-spec.md`](./functional-spec.md) · [`technical-spec.md`](./technical-spec.md) · **Phasing:** [`07-phasing.md`](./07-phasing.md)
- **This is the handoff point.** Writing the code is a separate, explicit step outside this
  workflow. Everything below is a task breakdown, not an implementation.

## How to use this document

Tasks are `T-nn`, grouped by the phase they belong to, ordered so that **every task leaves the
plugin releasable**. Each carries: goal, components touched, dependencies, and **acceptance
criteria that can fail**. Task-level Definition of Done in §5 applies to all of them.

**Read `technical-spec.md` §0 first.** The coupling inventory found 18 sites, not 6, and two of
them — `up_acts_as_list` (C3) and the *second* tag including `ScopeResolution` (C16) — are
load-bearing for the first release and were missing from earlier lists.

**Before starting: five readiness items.** Not bureaucracy — each one is a thing that becomes
impossible or much more expensive later.

> **Who does these, restated 2026-08-04 because it was unclear and that was a drafting failure, not
> a reader's.** Nothing here is homework the curator must finish before work may begin. **DoR-1, 2
> and 3 *are* tasks T-02, T-01 and T-03** — the first three things Claude Code does. They appear as
> readiness items only because of their *ordering*: each one measures something that stops being
> measurable once later code lands, so they must be **first**, not **prior**. **DoR-4 is answered**
> (OQ-3/OQ-4 closed by curator decision 2026-08-04 — `technical-spec.md` §5.1/§5.2). **DoR-5 is now
> specified** in §5's capability vocabulary plus §5.1's three models, so it is a schema to write in
> T-12, not a decision to take. **Net: zero open human prerequisites.** The one thing still worth a
> human minute is the *tolerance* on the p95 comparison (a curator decision, labelled as such in
> `functional-spec.md`), and it is not needed until T-03 has produced a number to set it against.

| # | Item | Why it must precede code |
|---|---|---|
| DoR-1 | Run the four production queries (`SELECT type, count(*) FROM report_templates GROUP BY type`; active `report_schedules` count; a `content LIKE` sweep per drop accessor; a log grep for `/issue_mails` and `?token=`) | Three claims (A5, C-002, C-007) discriminate on this **one** measurement. The subset scope is provisional until it runs. Ships as T-02's `import:plan`, so it is repeatable rather than a one-off |
| DoR-2 | Freeze the goldens + the scope fixture (T-01) | The scope is unrecoverable once `scope_resolution.rb` is deleted |
| DoR-3 | Measure the performance baseline on v0.5.0 | Cannot be measured after the aggregator changes |
| ~~DoR-4~~ | ~~Answer OQ-3/OQ-4~~ — **ANSWERED 2026-08-04.** External container: yes, *as one option*, documented and safe → third CI-verified adapter, default unchanged (T-34). Assets: fetch external references, ship local ones with the request → three models + `asset_policy`, `:bundled` default, allowlist-only above (T-33) | it determined what the asset-resolution test expects; it now does |
| ~~DoR-5~~ | ~~Agree the engine `capabilities.yml` schema~~ — **SPECIFIED**: the closed capability vocabulary in `technical-spec.md` §5 plus the three asset models in §5.1. Written as a file in T-12, no longer a decision | the three-state conformance rule now has something to read |

## Status — what has landed

Kept here so a fresh session can read it rather than reconstruct it. `git log --oneline` is still
the authority; this is a summary, and CLAUDE.md §1 says to verify it.

**Read [`HANDOVER.md`](./HANDOVER.md) alongside this table.** It carries what this table cannot: the
traps that produce a green run meaning nothing, the code that looks like a violation and must be left
alone, and — most importantly — **which configurations have actually been executed**, including the
fact that CI has not yet run on this work at all.

| Task | State |
|---|---|
| T-00 | **VOID** — the fork is out of scope (curator, 2026-08-05). See below. |
| T-01 | **done** — reference date, canonicaliser, baseline commit, the 176-case value corpus, the per-adapter overlay, the 46-triple scope fixture and the `corpus` CI job. **It found defect D-1 on the way in** — see §Findings |
| T-02 | **done** — `rake reporter_dashboards:import:plan`, read-only (proven by a no-writes assertion, not by a comment), plus the template linter's first 13 rules. Three of R-15's four queries answered; the fourth is a log grep and is reported as unanswerable **with the command**. It found the G8 tension in §Findings F-3 |
| T-03 | **partly done** — the aggregation baseline is measured and committed (9 workloads × 3 issue counts, 20 warm runs, provenance-stamped) and R7's three *absolute* criteria are now hard assertions on every engine. **The HTML\|PDF half is blocked and recorded as blocked** — see §Findings P-2 |
| T-04 | **done** — `RedmineReporterDashboards::Positioned` replaces `up_acts_as_list` |
| T-05 | **done** — reporter optional; `ReporterPresence`, memoised at `after_plugins_loaded` |
| T-06 | **done** — widgets leave the picker, degrade in place, `report_pdf` 404s |
| T-07 onward | not started |

**Phase 1's promise is met and measured**: the plugin installs and runs with neither
`redmine_reporter` nor the `redmineup` gem. Verified on Redmine 6.1-stable with and without
reporter, and on 7.0-stable standalone, against real PostgreSQL. Not yet verified anywhere: Redmine
5.1 and 6.0, and MySQL/MariaDB — CI covers those, a local run has not.

**The one thing still owed before 0.6.0 can honestly ship** is T-09's CI change: the workflow still
checks out the private reporter plugin with a secret, so the standalone claim is not yet proved by
CI on every pull request. Until it is, INV-7 says the claim is weaker than it looks.

## Findings — what the work has turned up, and who owns the fix

**D-1 · `group_by: age` reports everything as `(none)` on MariaDB.** Found 2026-08-05 by T-01's
corpus on MariaDB 10.11, confirmed by the first CI run on MariaDB 11, and **measured absent on
MySQL 8.0.46 and PostgreSQL 16**. The age dimension groups on a generated `CASE`; ActiveRecord reads
the group key back out of the row **by the expression's own text**, and MariaDB truncates a returned
column label at 256 characters (measured: 261 works, 262 does not). Past it every key comes back
`NULL`, the chart collapses into the empty bucket, and the total is taken from whichever group the
server returned last — so an issue can vanish from the count as well. **Four boundaries cross the
limit and `DEFAULT_AGE_BUCKETS` is four**, so this is the DEFAULT behaviour on MariaDB, in
production, today. Every existing adapter example used three boundaries or fewer, which is the only
reason CI had been green.

*First written up as affecting "the whole MySQL family" — an inference from one engine, and the
first CI run refuted it.* MySQL 8.0 answers correctly, so the overlay now has a **`mariadb` family
of its own**, separate from `mysql`; the adapter name cannot tell them apart (mysql2 reports
"Mysql2" for both), so the family is asked of the server version.

**D-1's mechanism, measured 2026-08-05, and it corrects this entry's own prescription.** The line
above — "the one-line change is to alias the group expression or group on a short one" — does not
survive measurement. Two facts, both probed against the running stack rather than read off the source:

1. **The alias is already truncated on the engine that WORKS.** ActiveRecord derives the result-column
   name from the group expression's text (`calculations.rb#execute_grouped_calculation` →
   `ColumnAliasTracker#column_alias_for` → `table_alias_for`, which slices at `table_alias_length`).
   On PostgreSQL that limit is **63**, so the age CASE's alias is cut at 63 for three, four and five
   boundaries alike — measured expression lengths 242 / 305 / 368, aliases 218 / 274 / 330 — and
   PostgreSQL answers correctly at every one of them, because AR asks for the same truncated name it
   sent. The mysql2 adapter hardcodes **256** (`mysql/schema_statements.rb:130`), so AR emits a
   256-character alias there and MariaDB hands back a shorter one; MySQL 8 does not. So "the alias is
   too long" is not the defect — *the two ends disagreeing about the truncation* is, and shortening
   the expression only moves the cliff from four boundaries to some larger number. `MAX_AGE_BUCKETS`
   is 24, and 24 branches cannot fit in 256 characters at ~60 characters a branch.
2. **A select alias cannot be introduced without leaving AR's grouped-calculation path.**
   `execute_grouped_calculation` does `select_values += self.select_values` **`unless
   having_clause.empty?`** — with no HAVING it *overwrites* the relation's select list. Measured:
   `.select("CASE … AS rrd_short").group("rrd_short").count(…)` raises
   `PG::UndefinedColumn: column "rrd_short" does not exist`, because the SELECT that defined the alias
   was discarded.

So the fix is structural, not textual. The two candidates, both of which change how *every* measure
reads its groups: (a) leave `.count`/`.sum` on a grouped relation and read a hand-built
`select_all` with an alias this code owns; or (b) drop the GROUP BY for the age axis entirely and use
the shape `completeness` already uses — `aggregate_row(base, buckets.map { count_case(…) })`, one
query, one `COUNT(DISTINCT CASE …)` per bucket, read back **positionally** so no alias exists to
truncate. (b) is the smaller of the two and fits the age dimension exactly, because its keys are fixed
(`fixed_keys: labels`) just as completeness's are; it still has to be threaded through
`single_result`, `crosstab_result`, `fold_values` and `bucket_filter`.

**That is T-08-sized work in the file gate G7 freezes byte-for-byte, and it can only be *verified* on
MariaDB** — the one engine where the defect exists, and one this session's container does not have
installed (MySQL and MariaDB conflict; switching costs an apt purge and a datadir re-init). Two things
therefore need a curator decision before it is written, and neither is a judgement the specs leave to
the implementer:

- **G7.** Fixing the kernel means it is no longer byte-identical to `eddb8fa`, so the gate as written
  can never pass again. The honest mechanism is a *declared exception with its own ratchet*, mirroring
  `AdapterOverlay`: the diff against v0.5.0 must equal exactly the recorded hunk, with its reason. That
  is a change to a hard gate's reference, which `CLAUDE.md` §7 and §11.4 put outside an implementer's
  authority — the gate exists to answer a red-team finding, and the argument belongs with the finding.
- **Where it lands.** T-08 is where the kernel legitimately moves and where the corpus differential is
  the point. Absorbing it into another task's branch is exactly the R-02 stall risk §11.5 names.

*Not fixed in T-01, and for two independent reasons in the operating rules rather than one:* gate G7
diffs the kernel byte-for-byte against the baseline, and **§1's ordering guard refuses a change to
the aggregator while T-03 has not landed** — the performance baseline cannot be measured after the
aggregator moves, and there is no way back to it. So the earliest honest slot is **after T-03**, and
the natural home is **T-08**, which is where the kernel legitimately moves; the one-line change is to
alias the group expression or group on a short one.

**DECIDED by the curator, 2026-08-05: wait for T-08.** They first asked for D-1 to be fixed and left
the timing open; when the measurement above showed it is not a one-line change and that fixing it now
would mean weakening gate G7's byte-identity reference, they chose to leave the kernel frozen and let
the fix land in T-08, where that file is rewritten anyway. **Their own production runs PostgreSQL,
which is measured unaffected**, so the wait carries no exposure for them — it is other installations,
on MariaDB, that stay broken until T-08. Do not "helpfully" fix this earlier: the decision is
recorded, and re-opening it means re-opening the G7 question with the curator.

Meanwhile every engine is asserted in
`spec/adapter/query_aggregator_execution_spec.rb` (MariaDB's branch pins the defect, the others pin
the correct answer), it is documented in the README's database section, and the two affected corpus
cases carry MariaDB overlay entries — so the day it is fixed the suite says so and the ratchet goes
down. **It is also evidence on C-003** (`claims.json`, updated): the corpus is already not green on
all three engines before any port, and the cause is structural. Status and confidence left for the
curator.

**D-2 · the plugin could not run on Redmine 5.1 at all — FIXED 2026-08-05.**
`app/models/reporter_project_tab.rb:3` read `class ReporterProjectTab < ApplicationRecord`, and
Redmine 5.1 has no `ApplicationRecord`: that class arrived in 6.0. Every dashboard page and every
plugin test on 5.1 raised `NameError: uninitialized constant ApplicationRecord`. The line shipped in
v0.5.0; the README listed 5.1 as tested. Nothing caught it because the full-application suite could
not run in CI until T-09 removed the private-plugin secret — **its first 5.1 run reported 92 errors,
all this one line.** That is INV-7's failure mode exactly, and the sharpest possible argument for
T-09 having been worth doing.

Fixed here rather than deferred: `app/models` is not the frozen kernel and no ordering guard covers
it. `RedmineReporterDashboards::Compat.base_record` returns `ApplicationRecord` where it exists and
`ActiveRecord::Base` where it does not — the two are behaviourally equivalent for a plugin model,
verified against 5.1-stable's `config/initializers/10-patches.rb`, which monkey-patches the identical
`human_attribute_name` body onto `ActiveRecord::Base` that 6.x moved into `ApplicationRecord`. This
is the **first entry in `compat/`**, and it lives in `lib/redmine_reporter_dashboards/compat.rb`
rather than `compat/base_record.rb` because Redmine puts a plugin's `lib/` on the autoload paths and
Zeitwerk requires the path to match the constant.

**D-3 · `sprite_icon` does not exist on Redmine 5.1 either — FIXED 2026-08-05.** With D-2 fixed, the
same 5.1 job went from 92 errors to 27, all of them
`ActionView::Template::Error: undefined method 'sprite_icon'`. `IconsHelper` arrived in Redmine 6.0;
13 call sites in 9 files called it unguarded. The interesting part is that the *design* was already
right — every one of those links already carries Redmine 5's CSS icon classes
(`class: 'icon icon-settings'`) and `_report.html.erb` even documents "on Redmine 5 it renders no
`<svg>`, so the label gives the link a body". Only the belief underneath was wrong: on 5.1 the method
does not render nothing, it does not exist. So the fix is one helper —
`ReporterProjectPagesHelper#reporter_dashboard_icon`, branching on the `reporter_dashboard_svg_icons?`
predicate that was already there for the move controls — and no icon-name mapping at all, because the
class on each link already IS the 5.1 icon. Both branches are asserted by stubbing the predicate, so
the 5.1 path is testable on a machine that cannot run 5.1.

**The corpus had a gap, and T-02's data found it.** The production survey showed every template
writes `age_buckets: "30;60;90;180"` — the STRING form. `normalize_age_buckets` accepts a string or an
Array, and the corpus only ever asked for the Array, so the branch every real caller goes through was
unfrozen. Two cases added (`;` and `,` separated), plus an assertion that the string and Array
spellings answer identically. Three boundaries, not production's four: four is defect D-1's trigger
and belongs in `cap/age.*`, not in a parser case.

**E-1 · an environment fact worth not rediscovering: MySQL 8 ignores a `projects`-keyed subquery in a
LEFT JOIN's ON clause.** Measured on 8.0.46 while fixing the above: `projects.id IN (SELECT …)`
inside a `LEFT OUTER JOIN … ON` is evaluated as TRUE — an entitlement check written that way passes
for everyone. `issues.project_id IN (SELECT …)` and a literal `projects.id IN (1,2,3)` are both
correct, and PostgreSQL and MariaDB get all three right. **No production path is affected**, and that
is checked rather than assumed: `TimeEntry.visible_condition` reaches `projects` but emits literal id
lists (`Project.allowed_to_condition`), and `IssueCustomField#visibility_by_project_condition` does
emit a subquery but keys it on `issues.project_id` (`custom_field.rb:262`). The adapter harness had
invented the one shape Redmine never produces, so MySQL made the *harness* lie about visibility —
caught by the first CI run, and now the stub emits what Redmine emits.

**P-1 · the query-count control was a guess, and the measurement said so.** T-03's first draft
asserted one global ceiling — "no workload issues more than 12 queries" — and `version_rollup` issues
**18**. The interesting part is which of the two possible explanations it was. It issues 18 at 100
issues and 18 at 10 000: eleven grouped aggregates, the closed-status lookup, the cost-field
resolution and one grouped sum per cost field, none of which scale with rows *or* with the number of
versions. So the finding was the ceiling, not an N+1 — and a guessed ceiling cannot tell you that,
which is the whole argument for T-03 existing. The control is now
`PerformanceCases::QUERY_BUDGET`: one **measured** figure per workload, asserted as a ratchet
(`<=`), so a kernel that gets tighter passes and a kernel that adds a query fails with the workload
named. Every figure is also carried per cell in the artefact, so a later reader can see what was
true when.

*The same measurement caught a second thing, and this one was mine.* `completeness.seven` asked for
`assigned_to` and `done_ratio`. Neither is a completeness field — `assignee` is the alias and
`done_ratio` is not offered — so the kernel warned, dropped both, and the cell measured a **five**
field panel under a seven-field name. Every entry point logs-and-degrades on an unusable argument,
which is right for a template author and silent for a benchmark. `EXPECTED_RESULT_SIZE` now pins
what each workload must give back, asserted on every engine: a workload that quietly answers a
smaller question gets faster and reads as an improvement.

**P-2 · T-03's HTML|PDF half cannot be measured here, and the artefact says so rather than omitting
it.** The Accept list's axis is (reference template × issue count × **HTML|PDF**). The aggregation
axis is measured — 9 workloads × 3 issue counts, 20 warm runs after 3 discarded, provenance-stamped.
The render axis is not, for two reasons that are facts about the tree rather than decisions: **the only
Liquid renderer today is `redmine_reporter`'s**, a separate private plugin (T-10…T-15 build the
owned one), and **there is no PDF engine reachable from this session** — the curator has said a
running Gotenberg is not something they can provide. So all 12 render cells are written into
`spec/golden/performance/baseline.json` as `blocked`, each naming **T-10** as the task that owes it,
and a DB-less spec asserts they are all still declared blocked. An unmeasured cell written down as
unmeasured is a pause point; an unmeasured cell that is simply absent is a baseline quietly claiming
coverage it does not have — INV-7's rule applied to performance instead of to versions.

**P-3 · the timings are noisier than any tolerance anyone would set, measured.** Two consecutive runs
of the identical matrix on the identical machine, minutes apart, moved p95 by up to **×1.26** — and
`version_rollup.costs@100000` came back **invalid** (dispersion 0.417) in the first and valid (0.090)
in the second. The committed artefact therefore has zero invalid cells and that is an accident of when
it was measured, not a property of the kernel. This is the concrete argument for the `[GAP]` in
`functional-spec.md` §R7 being real: a relative p95 gate with any tolerance under ~30% would be red on
a quiet machine's bad minute. So the drift report is labelled **ADVISORY — non-deterministic — not a
correctness guarantee** (`CLAUDE.md` §7), and what carries the weight is the three *absolute* criteria,
which are exact integers and cannot be noisy. If a curator does set a tolerance, it needs to be set
against a dedicated runner, and the artefact records the CPU model, core count and image digest so
that comparison is possible rather than implied.

*One deliberate widening, labelled as such:* the two reference templates between them reach exactly
two of the kernel's six entry points (`.breakdown` and `.version_rollup`). T-07 and T-08 re-seam all
six, and a baseline over two of them would go stale the moment the re-seam touched the other four —
with no way back to it, which is the reason this task precedes them. So a third pseudo-template,
`production-shapes`, carries seven more workloads drawn from **T-02's survey of the 26 real
templates**, each naming the survey line it comes from. It measures more than the Accept list's axis,
never less.

**F-3 · gate G8's "empty allowlist at 1.0" target cannot survive shipping an importer, and that
is a curator question.** `script/gates/zero_reporter.allowlist` opens with "At 1.0 it should be
empty: the goal is a plugin that names neither upstream anywhere in `app/`, `lib/`, `db/`, `config/`
or `init.rb`." T-02 adds four files that name `redmine_reporter` **because reading reporter's data is
what they are for** — and that is the opposite of coupling: the survey reads *tables*, never
reporter's classes, and `spec/adapter/import_survey_spec.rb` runs it against bare tables with no
reporter code loaded at all. So the gate is matching a string here, not a dependency.

Removing the mentions would make the tool worse rather than purer: `rake -T` has to say whose data
`import:plan` surveys, the report has to name the tables it looked for, and the usage groups have to
say that six of the accessors come from *paid* RedmineUP plugins — which is precisely the fact an
operator needs in order to decide what can be dropped. So the four files are on the allowlist, in
their own section, with that reason.

What is **not** decided here: whether the 1.0 target becomes "empty except the importer", whether
`lib/redmine_reporter_dashboards/import/**` leaves the gate's search paths, or whether the importer
ships at all past the migration era. Each of those is a change to a documented gate or to the release
goal, which §11.4 and G9 put with the curator. The gate is unchanged and still green in warn mode; it
is the *goal statement above it* that now has an exception.

**F-2 · the registers relation path is not visibility-scoped.** `resolve_scope` returns
`registers[:container]` as-is when it is an AR relation, intersecting only the DROP path with
`Issue.visible`. The documented grounds are that every registers path is `IssueQuery#base_scope` and
therefore already visible — true of what reporter passes today, not true of the type. Not reachable
from a template (only the host plugin writes registers), so it is a finding rather than an
emergency, and the scope fixture **freezes the leak explicitly** (a triple in which every actor
resolves an issue from a project they are not a member of). **T-07 owns the decision**; when
`ScopeBinding` closes it, that triple changes and the change has to be argued for rather than
noticed later.

## 1. Work breakdown

### Phase 0 — unblock and freeze

**~~T-00~~ · VOID — the fork is out of scope** *(closed 2026-08-05 by curator decision)*

The task was "fix `enum orientation: [...]` in `redmine_reporter/app/models/report_template.rb:26`".
The curator has ruled that **`redmine_reporter` is not to be modified**: the goal is to merge and
improve its capabilities *into this plugin*, not to maintain the fork. T-00 therefore has no
deliverable and **must not be attempted**.

What replaced it, and why nothing is lost:

- **Redmine 7 was unblocked from the other end.** Since T-05 made reporter optional, the enum
  defect stops the two report widgets instead of the whole plugin. Redmine 7.0-stable was then run
  standalone and is green — 900 specs, 86 adapter specs, 114 full-application tests, 0 failures.
  The blocker was never in this plugin.
- **The `skip_unless_reporter_report_templates_load` helper stays.** T-00 would have deleted it;
  it is now load-bearing for a supported configuration, so it remains, with its message corrected
  to distinguish "reporter absent" (normal) from "reporter installed but broken" (a defect).
- **The tooling half of T-00 is done** and was mostly a false premise — see `CLAUDE.md` §4.
  `.codex/ruby_version.sh` fixes the real gap; `redmine_clone.sh` and `test_setup.sh` were also
  fixed so the standalone configuration can be set up and switched to at all.
- **The enum divergence is still owed to `compat/enum.rb`** for this plugin's own models, if any
  ever need an enum. Measured: `enum :name, {...}` raises `ArgumentError` on Rails 6.1, and
  `enum name: [...]` raises on Rails 8.1, so neither form spans 5.1→7.0 alone. Stored integers are
  identical either way.

*If reporter is ever fixed upstream*, the four skipping tests begin asserting on their own; nothing
here needs changing to allow that.

**T-01 · Freeze the oracle** *(the only time-sensitive task)*
*Goal:* capture what "the same numbers" means, before anything moves.
*Touches:* new `spec/golden/**` (`reference_date.rb`, `corpus_canonicaliser.rb`, `baseline.rb` and
the `aggregation/` fixtures) and a generator extending `spec/adapter/adapter_helper.rb` —
**extend, do not write a parallel harness**. **Corrected 2026-08-05:** the value corpus can be
generated from that harness, but **the scope fixture cannot** — `ScopeResolution#resolve_scope`
reaches `Issue.visible`, `IssueQuery.visible` and a thread-local, none of which exist in a harness
whose whole point is not booting Redmine. The scope fixture therefore also touches `test/` (the
full-app suite), where real roles and a real `IssueQuery` exist. Budget it as two pieces, not one.
*Deps:* none. **Corrected 2026-08-05:** was `T-00 (the generator must be able to boot)`. T-00 is
void, and the premise was wrong anyway — the generator boots on any Redmine whose Rails accepts
reporter's enum, and standalone it does not need reporter at all.
*Accept:*
- Generated against the **`v0.5.0` tag**, not a working tree.
- **A pinned reference date** is required and the verifier **refuses to run without it**. The
  existing fixture is `Time.zone.today`-relative (a 400-day sweep), so an unpinned corpus changes
  daily, goes red for the wrong reason, and gets switched off within a week.
- Canonicalisation per `technical-spec.md` §2: keys sorted recursively, **array order preserved**,
  floats as `(v*10_000).round` **plus** a `%.4f` string (4 dp is the declared contract — PostgreSQL
  `numeric` and MySQL `DECIMAL(20,4)` disagree beyond it), per-adapter overlay **with a written
  reason** instead of a tolerance.
- Covers: `.aggregate`, `.breakdown` (legacy), `.dimension_breakdown`, `.completeness`, `.flags`,
  `.version_rollup`; cap boundaries at 200 / 24 / 12 / 5 000; **and ≥3 actors with different roles
  including one role-restricted custom field** — absent from the fixture today, and the thing that
  makes INV-1/INV-2 testable at value level.
- **A scope fixture:** ~40 `(template, query, actor)` triples recording `to_sql` **and** the sorted
  issue-id set. *This is the genuinely irrecoverable artefact* — the numbers are regenerable from
  the tag; the scope is not, once `scope_resolution.rb` is gone.
- SQL strings in a **sibling** tree, not the value corpus (SQL is expected to change at the
  re-seam; the numbers are not, and a differential that fails for the wrong reason gets disabled).
- **Bit-reproducible across two independent runs** on all three engines. A corpus that is not
  reproducible is not an oracle.
- New CI job `corpus`, green, and **it stays green through every later task**.

*Done (2026-08-05).* What landed, and where to read it: `spec/golden/README.md` is the page for
anyone touching these artefacts.

- **Reference date** — `spec/golden/reference_date.rb`, default `2025-12-29`; the verifier refuses
  to run unpinned. Pinning the fixture is not enough on its own: the **clock must be frozen to the
  same date** or every period window comes back empty. The aggregator's only clock read is
  Ruby-side, so freezing Ruby is sufficient.
- **Canonicaliser** — `spec/golden/corpus_canonicaliser.rb`, per §2 Step 0.
- **Baseline** — `spec/golden/baseline.rb`: commit `eddb8fa`, not a tag, because this repository has
  none. See that file for the one way the reference can still be lost (a squash merge).
- **The value corpus** — `spec/golden/corpus_cases.rb` declares **176 cases** over the six entry
  points; `spec/golden/aggregation/values.jsonl` holds the answers with a manifest carrying the
  baseline commit, the pin, the zone and two digests (the file's, and the CASE LIST's, so a matrix
  that has moved on from its answers fails rather than passes). Caps covered **at** the boundary and
  **one past** it: 200 dimension keys, 24 age buckets, 24 periods, 12 completeness fields, 5 000
  crosstab cells. **Four actors, three roles, one role-restricted custom field** — the value-level
  INV-1/INV-2 evidence: the same call is refused for two actors, answers with values for a third,
  and hides the values while keeping the issues for the fourth.
- **The per-adapter overlay** — `spec/golden/adapter_overlay.rb`, file-backed, ratcheted, and
  **exhaustive by assertion**: the cases that differ on an engine must be exactly the cases it
  names. Two entries, both defect D-1 below.
- **The scope fixture** — `test/unit/golden_scope_fixture_test.rb` + `spec/golden/scope/scope.jsonl`,
  **46 (template, query, actor) triples** over all eleven documented resolution paths, four actors
  with three `issues_visibility` rules, private issues, an archived project and a project with no
  membership. `resolve_query`'s answer is recorded beside `resolve_scope`'s: the drill-through half
  is lost with the same file. SQL in the sibling tree `spec/golden/sql/`.
- **The `corpus` CI job** — all three engines, twice each, with the pinned date, and it runs the
  baseline checks **from the plugin checkout** (the mirror has no `.git`, so there they would skip
  and report green). It also fails if a run modified the corpus it was verifying.

*Two deviations from the wording above, both deliberate and both to serve it:* the scope fixture
records the issue set **by a stable per-issue key as well as by id**, because a fixture created
inside a rolled-back transaction has no stable ids and Redmine's own fixture sets differ between
5.1 and 7.0 — recording keys is what lets the fixture be verified on all four branches instead of
one pinned branch (ids are recorded too; the test assigns them explicitly from a reserved range).
And the 5 000-cell boundary is built from a `period` split rather than an `age` split, because a
24-boundary age CASE is exactly the shape defect D-1 breaks, and a cell-count boundary built on a
broken dimension would measure the defect instead of the cap.

*One constraint on that job, found the hard way:* `redmine_clone.sh` rsyncs the plugin into
`redmine/plugins/<name>/` with `--exclude .git/`, so the copy the suite normally runs from has no
history. `spec/golden/baseline_spec.rb` therefore **skips** there — correctly, but a skipped guard
reads exactly like a passing one. The `corpus` job must run the baseline checks **from the plugin
checkout**, not from inside the Redmine clone, or G7 has no reference check and stays green forever.

**T-02 · `import:plan` — the read-only survey**
*Goal:* make DoR-1 repeatable, and give the operator the blast radius before anything lands.
*Touches:* new rake task; the template linter's first rules.
*Deps:* none (can run in parallel with T-01).
*Accept:* writes nothing; reports counts by template type, active schedules and recipients, and
per-template lint findings (Chart.js 2 idioms, `window.status`, `geoChartBegin`,
`GEO_CHARTJS_SRC`, `setLineDash`, `[page]`, un-`json`-ed `{{ }}` inside `<script>`, gem-only drop
accessors, `new Chart(` occurrences and their `type:` values); exits 0 with a summary table.

**T-03 · Measure the performance baseline**
*Goal:* convert R7 from unfalsifiable to relative.
*Deps:* none *(corrected 2026-08-05: was T-00, which is void)*. *Must precede T-10.*
*Accept:* p50/p95/max/stddev over ≥20 warm runs (3 discarded) per (reference template × issue
count 1 000/10 000/100 000 × HTML|PDF), with a **recorded seed**, the runner image digest and the
CPU model captured; committed as a provenance-stamped artefact; a cell with `stddev/p50 > 0.35`
reported **invalid**, not averaged away.

### Phase 1 — standalone *(ships 0.6.0; delivers G1)*

**T-04 · Own the list behaviour — replace `up_acts_as_list`**
*Goal:* remove the plugin's own core-model dependency on the vendor gem.
*Touches:* new `glue/positioned.rb`; `app/models/reporter_project_tab.rb:7`.
*Deps:* none. **This is the first code task and it must not be reordered.**
*Accept:* `position` defaults to `max+1` scoped to `project_id`; `move_higher`/`move_lower`/`<=>`;
`before_destroy` reflow; the model has **zero** vendor-gem references; existing tab-ordering tests
pass unchanged. **Rationale: without this the plugin boots and then 500s on
`ReporterProjectTab` — verified, `up_acts_as_list` is defined only in the gem.**

**T-05 · Soft dependency detection**
*Touches:* `init.rb:12-16`, `:33`; a memoised `ReporterDashboards.reporter_present?`.
*Deps:* T-04.
*Accept:* the `raise` becomes a soft detect; `requires_redmine_plugin` deleted; the flag is
computed **once** at `after_plugins_loaded`; a boot spec passes with
`Redmine::Plugin.installed?` stubbed false. **Do not use `rescue NameError` for detection** —
`redmine_reporter_dashboards.rb:135` already swallows `NameError` silently, which is exactly why
C3 went unnoticed for a release line.

**T-06 · Report widgets leave the picker; already-placed widgets degrade**
*Touches:* move the two report partials to `blocks/optional/`; `project_page.rb:55-62`;
`show.html.erb`; `reporter_project_pages_controller.rb:85-91`.
*Deps:* T-05.
*Accept:* with reporter absent the two widgets are **absent from the picker**; a dashboard that
**already has one placed** returns 200 with an inline "widget unavailable" cell carrying
`degraded: true` and one log line — **not a 500**; `report_pdf` returns **404** (not 500) when
reporter is absent, both branches asserted. *A 500 in a monitored install is an alert about a
broken thing; a 404 is a correct statement about an uninstalled capability.*

**T-07 · `ScopeBinding` replaces `ScopeResolution`; re-seam **both** tags**
*Goal:* the render context carries the `IssueQuery` explicitly.
*Touches:* new `liquid/scope_binding.rb` (~60 lines) + `liquid/render_context.rb`;
`liquid_aggregate_tag.rb:106` **and `liquid_version_rollup_tag.rb:38`** — **there are two, not
one**; `scope_resolution.rb` demoted to `glue/legacy/`.
*Deps:* T-05. **T-01 is complete** — the scope fixture in `test/unit/golden_scope_fixture_test.rb`
is the oracle this task is measured against, and finding **F-2** (§Findings) is the decision it has
to take deliberately rather than by accident.
*Accept:* two resolution sources only (`IssueQuery.visible(actor).find_by(id:)` → `base_scope`;
`RenderContext#scope`); the `drop.instance_variables` walk, the `:container`/`:controller` ivar
archaeology, the `Issue.where(id: ids)` reconstruction, the thread-local **and the fail-open
`enforce_visibility` rescue** are all gone from the owned path; a gate asserts `Thread.current` is
absent from `lib/`/`app/` outside `glue/legacy/`; **`corpus` still green** — *this is the single
most important assertion in the whole plan*; drill-through still works for installs that still
have reporter (via `glue/legacy/`).

**T-08 · Port the aggregation kernel, byte-identically**
*Touches:* `aggregation/query_aggregator.rb`, `aggregation/drill_through.rb`, plus a 4-line
namespace assignment.
*Deps:* T-01 (complete). **This task owns the fix for defect D-1** (§Findings) — the only place the
kernel may legitimately change a byte. Fixing it deletes the overlay's two entries and lowers its
ratchet in the same commit.
*Accept:* both files are **byte-identical** to their `v0.5.0` blobs — `git diff --no-index` output
**empty**, not "ignoring whitespace"; they still open `module SqlAggregation`; namespacing is a
separate assignment file; the `corpus` job enforces this on every PR. *Re-indentation is a separate
mechanical commit, only after `corpus` has been green a full release cycle, and reverted rather
than fixed if it goes red.*

**T-09 · The G1 CI change**
*Touches:* `.github/workflows/ci.yml`; `test/test_helper.rb:45-54`; `script/gates/*`.
*Deps:* T-06, T-07.
*Accept:* the `reporter-secret` probe job, the `needs:`/`if:` gate and the private checkout step are
**deleted**; a new `minitest-standalone` job runs the full-app suite on 4 Redmine branches **with
no secret**; a `lint` check fails on any `secrets.` reference other than `GITHUB_TOKEN`;
`zero_reporter.sh` runs in **warn** mode with a committed allowlist that may only shrink;
`layer_purity.sh` green; the `compat/` LOC is printed on every PR. **G1**, plus one dated fork-PR
run recorded per release — *a workflow cannot fork itself without reintroducing the very credential
G1 removes, so that end-to-end proof is a human artefact and the grep is what keeps it true
between artefacts.*

### Phase 3 — own the render path *(ships 0.7.0; runs in parallel with Phase 2)*

**T-10 · The document-request interface**
*Touches:* `render/{document_request,page_furniture,result,failure,capabilities,registry,renderer}.rb`.
*Deps:* T-03 (baseline first). Independent of Phase 2.
*Accept:* `DocumentRequest` carries page geometry, orientation, margins, `PageFurniture`, media,
**`print_backgrounds` defaulting to `true`** (not to the engine's default — Chromium's is `false`
and a naive swap silently loses every badge colour), page breaks, readiness, timeout, metadata,
correlation id; **it has no field a credential could travel in** — no `cookies:`, `headers:`,
`auth:`, so cookie-passing is *unrepresentable*, not merely discouraged; `PageFurniture` slots take
literal text plus a **closed token set**; `Result` is a `Success | Failure` sum type with a closed
failure-code set; `Renderer` enforces the `%PDF-`/`%%EOF` and minimum-size post-conditions **above
every adapter**, so no adapter can violate INV-5 by accident; `layer_purity.sh` proves `render/**`
contains no `Rails.`, `ActiveRecord`, `Liquid`, `Issue`, `Net::HTTP`, `cookie` or `session`.

**T-11 · Readiness protocol + chart shell**
*Touches:* `render/readiness.rb`; `assets/javascripts/chart_shell.js`.
*Deps:* T-10.
*Accept:* one DOM contract (`window.__rd` with `pending/ready/begin/end/fail`, plus
`data-rd-ready` and `window.status`) emitted by the plugin's own shell, mapped per engine; an
in-page watchdog; on timeout the engine **still renders** and returns `Success` with
`Degradation(:readiness_timeout, pending: n)` unless `strict` — *a chart-less-but-correct document
beats no document*; **`begin`/`end` are never the template author's job.**
**The falsifier:** three fixtures — 0 charts, 3 charts that finish, 1 chart that never calls
`end()` — with expected durations <1 s / <3 s / ≈timeout. **A fixture signalling at ~6 s must
produce a document containing the post-readiness marker, and the harness's own monotonic
measurement must be ≥5.9 s and ≤12 s.** An implementation using today's fixed 3-second delay fails
this *by construction*; one that just waits out the timeout fails the upper bound. Run 3/3 attempts
on the gate with deliberately generous bounds — a tight wall-clock bound gets loosened after the
first flake and then proves nothing.

**T-12 · Engine conformance corpus + `render-smoke`**
*Touches:* `spec/conformance/F-nn-*/`; a new CI job.
*Deps:* T-10, T-11, DoR-5.
*Accept:* fixtures for page geometry, orientation+margins, per-page footer with page numbers,
page breaks, **background printing** (fails if `printBackground` defaults false), flexbox layout,
readiness (T-11's three), readiness timeout, **asset resolution with the engine in a different
network namespace**, failure semantics (typed error, zero bytes, no attachment, no journal),
resource envelope, egress denial, fonts, pathological input, and the escaping payload set under
**this engine's** JS parser. Three-state rule: an **undeclared** capability **skips with a reason**;
a **declared** capability that fails is a **hard failure**; and the support matrix is **generated
from the run**, with a lint check failing if the committed file differs.

**T-13 · Two adapters**
*Touches:* `render/engines/{chromium_cdp,wkhtmltopdf}.rb`; `pdf_polyfills.rb` → `glue/legacy/wk_legacy_shims.rb`.
*Deps:* T-12.
*Accept:* Chromium in a **separate process, never inside a Puma worker**, inline-only assets, name
resolution denied, non-root, `--no-sandbox` **not** set, a **process pool of size 1 by default**
with a bounded queue returning `Failure(:engine_unavailable)` rather than hanging;
wkhtmltopdf retained as a CI-verified **compatibility** engine with
`no_stop_slow_scripts` set back to **`false`** (today it is `true`, i.e. the engine's own
runaway-script guard is off with nothing replacing it), carrying the relocated shims plus a
`Degradation(:legacy_engine)` stamped into metadata, and **declared deprecated on arrival** with an
INV-7-shaped removal condition. Both pass T-12.
**Note the correction to ADR-004's consequence list:** the 61 polyfill lines are *not* deleted
here — they move, and are only recoverable when wkhtmltopdf is dropped.

**T-14 · Preflight / diagnostics**
*Deps:* T-13.
*Accept:* a **round trip, never `File.exist?`** — renders a probe document with a canvas, an inline
image, a Redmine-hosted image, a `{{page}}/{{pages}}` footer and a coloured background, and reports
per-check pass/fail/skip with timings; available as an admin page **and** a rake task exiting
non-zero; **it reports the renderer's actual fetch back to the Redmine host**, which is what
catches the "container is healthy but every PDF silently loses its assets" failure *at install
time* instead of in a quarterly report; output is structured (JSON) so it is asserted on rather
than log-scraped.

**T-15 · Render-path containment**
*Deps:* T-13.
*Accept:* a hard cap with **refusal before any render happens** (422, message naming the cap and
the actual count, and the render adapter double received **zero** calls — a refusal that first
renders 200 PDFs is not a refusal); a boundary test at exactly the cap; per-render timeout with a
bounded monotonic measurement **and the engine child process gone afterwards** (a timeout that
returns while the browser keeps burning CPU is the 504-with-a-burning-worker failure); a batch
timeout; concurrency observably bounded; archives **streamed** (no `Content-Length`); INV-5 asserted
— no `.pdf` containing an exception, `assert_no_difference` on **both** `Attachment.count` and
`Journal.count`.

**T-16 · Hybrid charts**
*Touches:* `render/charts/*`; `liquid/tags/chart_tag.rb`; vendored Chart.js 4.
*Deps:* T-11; needs T-19 for the tag itself.
*Accept:* `{% chart %}` emits **no markup** — it records a `ChartSpec` and a placeholder, and the
**output binding** decides: HTML → `<canvas>` plus a `<script type="application/json">` data block
(**never** a string-concatenated JS array literal, which is the entire class of the escaping
defect); PDF → server-side inline `<svg>`, vector and deterministic, with `<a xlink:href>` for
drill-through. **One shared `ChartLayout` computed server-side in Ruby for both paths**, and
Chart.js is handed explicit bounds and ticks and **not allowed to auto-scale** — that is what makes
"identical in HTML and PDF" a construction rather than an aspiration. Chart.js **vendored with a
recorded sha256, no CDN, ever**. `responsive: false` is emitted from the **engine's capabilities**,
not the author's choice — the concrete mechanism for G3. Six chart types; anything else degrades to
the JS path with a reason.
*Verify:* SVG goldens are **deterministic text**; the Chart.js visual diff is **advisory, never a
gate**. Plus the falsifier for the shared-layout claim: render a horizontal bar with 12 long labels
in both paths and compare plot-area bounding boxes — **>2% and "by construction" collapses to "by
careful tuning"**, with server-side SVG for *both* outputs as the fallback.

### Phase 2 — own the Liquid layer *(ships 0.8.0)*

**T-17 · Execution policy + the single parse entry point**
*Touches:* `liquid/{execution_policy,template_renderer}.rb`.
*Deps:* T-07.
*Accept:* **no `Liquid::Template.parse` anywhere outside `liquid/`** (gated); resource limits per
output class; a **cooperative wall-clock deadline** checked at every own tag's `render`, every
collection batch boundary and every prefetch — because resource limits bound *work units*, not
time, and a 90-second query costs one render-score point; `Timeout.timeout` **not** used
(interrupting ActiveRecord mid-statement trades a slow render for a poisoned pool); per-parse
`:strict` error mode; `strict_filters: true`, `strict_variables: false`; **errors never enter the
document** — they go to the diagnostics channel with correlation id, template id, project id, actor
and duration. *Both mechanisms are required; neither alone suffices, and the spec says so.*

**T-18 · Own drops**
*Touches:* `liquid/drops/*`, `liquid/batch.rb`.
*Deps:* T-17.
*Accept:* the disposition table in `technical-spec.md` §3.2 implemented exactly — field names kept
identical where they are just field names (the cheapest possible compatibility decision);
`closed_on` timezone-converted like its two siblings (today it is not); reference objects are
`NamedRefDrop` **plus** `*_id` accessors; `url` **always absolute**, which is what makes the base
plugin's 38-line Nokogiri-or-regexp URL rewriting unnecessary; the six other-plugin `respond_to?`
probes dropped; `all` **not implemented** on collections.
**Required spec before this task is done:** each of `to_s`, `==`, `eql?`/`hash`, `include?`,
`to_liquid` on `NamedRefDrop` renders **byte-identically to the String it replaces** under
**both Liquid 4.x and 5.x**. *Every one of those five is a claim about Liquid's internals and must
be proven by test, not by reasoning.*
*Absolute performance criteria, gating:* **zero `Issue` instantiations** for an aggregate-only
template, and **identical query count** at 10 vs 10 000 issues.

**T-19 · Own filters, incl. `| json`, + the lint**
*Deps:* T-18.
*Accept:* ~28 filters; **registration is per-render, never global** (the gem registers four modules
globally at require time and monkey-patches `Liquid::StandardFilters` unconditionally — never do
this, other plugins share the process); `call_method`, template-supplied regexes, `md5` and
`file_url` **removed, each for a stated security reason**; `| json` escapes `< > &` and
U+2028/2029; a lint rejects `{{ }}` inside `<script>` without `| json`/`| js`, **parses rather than
regexes** the HTML, and runs over the shipped examples **and the README's own snippets** — the
examples are the spec, and today the copy-paste surface carries the defective idiom. A regression
table from the escaping experiment including a **backslash-terminated** value, asserting the
assembled `<script>` block **parses** — because the actual finding was *denial of rendering via
`SyntaxError`*, so a test asserting only "no execution" would have passed the buggy code.
Plus a `StandardFilters` enumeration spec so a Liquid upgrade adding a filter is a **CI failure**
rather than a silent capability grant.

**T-20 · Retire the two compensating tags**
*Deps:* T-18.
*Accept:* `{% geo_version_map %}` (144), the addon's `VersionDrop` (108) and `issue_drop_patch.rb`
(43) deleted — **295 lines on top of the ~600 ADR-004 counts**; the tag **name** retained one minor
version as a deprecation shim that logs once and builds its map from **`Version.visible`, never
`Version.all`** (that was one of the five 0.5.0 visibility leaks); `lint_templates` flags templates
using it.

**T-21 · The multi-actor visibility suite** *(can start any time after T-07; do not defer)*
*Deps:* T-07.
*Accept:* a shared fixture with actors at `all`/`default`/`own` visibility, one without the
restricted-CF role, one without time-entry permission, an outsider and anonymous; a private issue;
a role-restricted custom field; a private saved query. Tests asserting **exact** per-actor totals
**and** strict inequality; that a restricted CF's **name appears nowhere** in the output for an
unentitled viewer (values-only assertions pass a leaky implementation); the fail-closed `'1=0'`
branch as a unit test; a zero-with-`degraded: false` case (a correctly-applied filter yielding zero
is *not* a refusal); **and an ordering test running two actors in one process in both orders, plus
an A/B/A** — a memoised `User.current` or a cached visibility condition passes one order and fails
the other, and the aggregator already memoises adapter family on the class, so this is not
paranoia.
Plus the **monotonicity property**: for actors u1 ⊆ u2, every count for u1 ≤ u2. ~40 lines, no
expected values to maintain, and it constrains every parameter combination — but **one-sided**
(a both-see-too-much regression passes by equality, so it must be paired with the strict case) and
**not applicable to `avg`/`distinct`** (removing rows can raise an average). Both limits written
into the file, or it produces false failures and gets deleted.

### Phase 4 — absorb the reporting surface *(ships 1.0.0)*

**T-22 · Own tables** — per `technical-spec.md` §7. *Accept:* namespaced classes and new table
names so **both plugins can be installed simultaneously** (which turns the riskiest event in the
project from a leap of faith into a comparison); schedule dates as `date` not `datetime`; run-state
columns; **a unique index on `(schedule_id, occurrence_date)`**; recipients are `user_id` only —
no free-text `to`/`cc`/`bcc`/`from`, a security-motivated schema decision; an append-only
template-versions table.

**T-23 · Template model, CRUD, preview.** *Accept:* template types by `source` field (T-31), not a subclass tree; the
template resolves through the same scope its picker offers; import uses a **closed type map** and
`safe_load` — never `YAML.load_file` + `constantize`, and never `rescue Exception`; export is a
plain Hash.

**T-24 · `import:run` / `import:verify`.** *Accept:* copy-only, forward-only, **never writes to
reporter's tables**, idempotent, stamping `source_template_id` + digest; `import_status` reports
divergence so drift is **visible rather than silent**; `import:verify` diffs **aggregation result
hashes**, not HTML — the corpus discipline applied to user data.
**Adopt is rejected**: an operator following Redmine's documented uninstall
(`migrate NAME=redmine_reporter VERSION=0`) would run reporter's own down-migrations and **drop the
tables the new plugin is live on**. Nothing inside the new plugin can prevent that.

**T-25 · Scheduler.** *Accept:* the runner **claims the occurrence first** by inserting the run row,
so a duplicate is caught by the unique index and skipped; **one render per occurrence, not per
recipient**; per-schedule rescue so one failure does not embargo later schedules, and the task exits
non-zero; bounded catch-up (`max_catchup_days` default 7 — a schedule dormant for a year must not
emit 365 e-mails), and a **plain run does not silently backfill**; a failure notifies the owner
**with no attachment**; the render identity is explicit, stored and auditable, and a test send uses
the **same** identity as the real run; the cron requirement is **documented** and preflight warns
when the task has never run.

**T-28 · Share links** *(deps: T-22, T-23)*
*Accept:* two tables (links + access log); **only the token digest stored**, constant-time
comparison; **mandatory expiry**, individually revocable, optional max-uses; **snapshot mode serves
frozen bytes so no visibility decision happens at request time**; live-query mode opt-in per template
and recording `render_as_user_id`; attachment URLs scoped to the link and revoked with it; owner/admin
UI listing active links with revoke and revoke-all. Tests: an expired link is refused; a revoked link
is refused; a link over `max_uses` is refused; a snapshot link returns identical bytes regardless of
who opens it; **a database dump contains no usable token**; every access appears in the log.

**T-29 · Template exchange bundle** *(deps: T-23)*
*Accept:* canonical **JSON** export with `format_version`; YAML accepted for reading via `safe_load`
with `permitted_classes` and `aliases: false`; type resolved through a **closed map** —
`constantize` appears nowhere; `import:plan` writes nothing and reports per-template new/updated/
skipped plus lint findings; `import:run` is transactional **per template** so one bad template does
not abort the bundle, each failure reported with a reason; `--on-conflict skip|rename|overwrite`;
**export → import → export is byte-identical** (a test).

**T-30 · Failure reports** *(deps: T-13, T-15)*
*Accept:* a diagnostics view naming template, Liquid line where applicable, engine + version,
duration and a **correlation id**; an **optional** failure document that is a real valid PDF titled as
a failure, filename `report-FAILED-<id>.pdf`, carrying the correlation id and a **safe** summary —
tests assert it contains **no** exception class name, no SQL fragment, no role/member/project ids;
default off; never persisted as an attachment unless requested; scheduled failure notifies the owner
with the correlation id and **no attachment**.

**T-31 · Time-entry reporting as a `source` field** *(deps: T-23; replaces a third template type)*
*Accept:* `source` ∈ `issues | time_entries` on the template model; **one** controller, CRUD and
preview serve both; a `TimeEntryQuery`-backed scope feeds the same aggregation core;
`{% sql_aggregate from: time_entries %}` works with every applicable dimension; a test puts issue data
and time data **in one template** — which the old two-branch design could not do; `spent_hours`
measures stop being a special case.

**T-32 · Ad-hoc report mail, controlled** *(deps: T-23, T-30)*
*Accept:* issues resolved through **`Issue.visible(User.current)`** — a test asserts an issue the
requester cannot see is refused, not silently included; **`From` is server-controlled** with the
requester in `Reply-To`; recipients are Redmine users unless an admin enables external addresses,
then against a **domain allowlist**; every send audited (who, when, template, issues, recipients) and
visible to admins; rate-limited per user; a render failure produces a failure notice, never a mail
with a broken attachment.

**T-26 · My-page widgets, locales, and the final gate flip.** *Accept:* `zero_reporter.sh` flips
from warn to **hard gate**; `glue/legacy/` deleted; the secret-gated job deleted;
`scope_resolution.rb` deleted.

**T-33 · The asset-resolution triple + `asset_policy`** *(deps: T-12; blocks nothing after T-13)*
*Touches:* `render/asset_resolver.rb`; `render/engines/*` capability sets; settings.
*Accept:* one `AssetResolver` walk choosing the **most restrictive model the engine declares**;
`:bundled` default proves a correct PDF with the engine's name resolution denied; a third-party URL
under `:bundled` yields `Failure(:asset_unresolved)` **naming the URL**, not a blank image; an empty
`asset_allowlist` under `:external` behaves **identically** to `:bundled` (the fail-closed test, and
the one most likely to be got wrong); a fetch carries **no** cookie/session/API-key/`Authorization`
header — asserted by a request-recording double, not by reading the code; a DNS name resolving to
`127.0.0.1`/`169.254.0.0/16`/RFC1918 is refused **after** resolution; size, time and redirect caps
each have a boundary test; and `:asset_http` is proven **off** in `:external` mode wherever the
engine supports `:asset_upload` — the inversion that keeps INV-8 true. A test asserts an author
**cannot** widen egress from template content.

**T-34 · The Gotenberg adapter** *(deps: T-13; parallel with T-14/T-15)*
*Touches:* `render/engines/gotenberg.rb`; `docker-compose.gotenberg.yml`; a third `render-smoke` leg.
*Accept:* `convert/html` with `:asset_upload` only, and the boundary grep asserts
`forms/chromium/convert/url` **absent from the whole tree**; passes T-12's corpus unmodified — the
proof that the interface, not the adapter, is the contract; `#preflight` **fails with a named
remediation** when the endpoint answers without the configured credential, and a test stands up an
unauthenticated instance to prove the failure fires (a security check that is never observed failing
is not a check); the container is pinned **by digest** and the CVE scan runs nightly against that
digest; the example compose file carries `internal: true`, non-root and a read-only root filesystem.
**Default engine unchanged** — a test asserts auto-detect never selects `:gotenberg`.

**T-35 · Mermaid** *(deps: T-16, T-33)*
*Touches:* `liquid/tags/mermaid_tag.rb`; `render/svg_sanitizer.rb`; vendored Mermaid 11.x.
*Accept:* block tag, body **not** Liquid-interpolated unless `interpolate: true`; readiness covered
by the existing `begin()`/`end()` contract with **no new handshake**; **one sanitiser shared with
`SvgRenderer`** — asserted by both producers running the same allowlist test set, including
`<script>`, `<foreignObject>`, `on*` and a non-drill `xlink:href`; on an engine without `:javascript`
the source is emitted, labelled, with `Degradation(:mermaid_unsupported)` — and the test asserts the
output is **not blank**; `mermaid_max_bytes` boundary; wkhtmltopdf declares `:mermaid` **absent**
even though it declares `:javascript` (settles `[OQ-L]` by measurement).

**T-36 · Reversible migrations + the `migrate-updown` job** *(deps: T-22; must land in the same
release as T-22, not after it)*
*Accept:* no `up`/`down` pair and no `execute` in a `change` block anywhere — a grep gate; a new CI
job per Rails branch that migrates up from empty, dumps the schema, migrates `VERSION=0`, and
asserts the dump **equals the pre-install dump** including `plugin_schema_info` **and** that
`reporter_project_tabs` still exists (the mirror of the hazard this dossier criticised in the base
plugin); up again is idempotent; a `column_present?` guard test for the three post-0.6 columns; and a
test asserting **no migration touches template content**. Failing this job blocks a release —
a plugin that cannot be uninstalled cleanly cannot honestly be offered for a trial install, and the
trial install is the entire A/B argument for copy-not-adopt.

**T-37 · The authoring experience** *(deps: T-19 for the linter, T-23 for the editor host; the
starter gallery additionally needs T-16 and T-35 to render its thumbnails)*
*Touches:* `app/views/…/templates/`; vendored CodeMirror 6; `render/drop_reference.rb`.
*Accept:* the editor's findings panel is fed by **the same linter object** the rake task calls —
asserted by a test that runs both over one fixture and compares the finding lists, so the two can
never diverge; findings carry line and column and are shown in the gutter; the editor degrades to a
`<textarea>` with server-side lint intact when JS is off; preview renders **HTML and PDF**, is
bounded and says *"preview of N of M"* rather than truncating silently; a failed preview shows
FR-58's diagnostics **in the editor**; the drop reference is **generated from the declared
surfaces** with a `drop_reference_parity` gate asserting both directions; a starter gallery whose
every entry lints clean and renders on every engine in the matrix, thumbnails generated in CI; a
chart form that **inserts the tag** and stores no hidden state. `[OQ-M]` — verify the CodeMirror
bundle against §6's no-build-step rule on a real Redmine 7.0 **before** vendoring it; the fallback
if it fails is a plain textarea plus the server-side lint panel, which already satisfies FR-71.

**T-38 · One stylesheet, two outputs** *(deps: T-16; parallel with T-37)*
*Accept:* one print-first stylesheet and one type scale used by the HTML view and the PDF body;
`thead` repeats across pages in a ≥3-page table fixture; `break-inside: avoid` holds for cards and
chart blocks; the palette is **read from `ChartLayout`**, not duplicated in CSS — a test asserts a
single source; every `SvgRenderer` and Mermaid output carries `<title>`/`<desc>`; a chart whose
meaning rests on colour alone fails a lint; drill-through links in the PDF are real links, asserted
by extracting the link annotations from the produced PDF. Chrome uses Redmine's own classes and icon
set per branch — a grep gate forbids a plugin-local design token in chrome CSS.

**T-27 · INV-9 as an enforced boundary.** *Accept:* the permission label reads *"Author report
templates (executes server-side code)"* with an inline warning and a README section; a
`template_authoring` setting (`:project_managers` for **upgraded** installs — a silent break is the
failure mode this project keeps naming — `:admins_only` for **new** ones); the widget iframe carries
`sandbox="allow-scripts"` **without** `allow-same-origin` plus a restrictive CSP, so template
JavaScript can neither read the session cookie nor call the API as the viewer; **the named
regression handled rather than discovered** — the height-fit script reads
`frame.contentWindow.document` and **breaks** under an opaque origin, so the shell posts its height
via `postMessage` with an `event.source` check and a numeric-range guard; `no_html_safe` gate allows
`raw(` in ≤2 files.

## 2. Sequencing

```mermaid
graph LR
  T00[T-00 enum] --> T01[T-01 freeze]
  T00 --> T03[T-03 baseline]
  T02[T-02 import:plan]
  T04[T-04 positioned] --> T05[T-05 soft detect] --> T06[T-06 widgets]
  T01 --> T07[T-07 ScopeBinding]
  T05 --> T07
  T01 --> T08[T-08 kernel port]
  T06 --> T09[T-09 G1 CI]
  T07 --> T09
  T07 --> T21[T-21 visibility suite]
  T03 --> T10[T-10 doc request]
  T10 --> T11 --> T12 --> T13 --> T14
  T13 --> T15
  T07 --> T17[T-17 policy] --> T18[T-18 drops] --> T19[T-19 filters]
  T18 --> T20
  T11 --> T16[T-16 charts]
  T19 --> T16
  T13 --> T22[T-22 tables] --> T23 --> T24 --> T25 --> T26
  T19 --> T23
  T26 --> T27
  T12 --> T33[T-33 asset policy]
  T13 --> T34[T-34 gotenberg]
  T16 --> T35[T-35 mermaid]
  T33 --> T35
  T22 --> T36[T-36 migrate updown]
  T19 --> T37[T-37 authoring UX]
  T23 --> T37
  T16 --> T38[T-38 one stylesheet]
```

**Critical path:** T-00 → T-01 → T-07 → T-17 → T-18 → T-19 → T-23 → T-25 → T-26. **T-33…T-38 are
off it** — none of the six is a prerequisite of another task, which is why they could be omitted for
this long without the plan noticing. That is a property of the plan worth distrusting, not
celebrating: *off the critical path* and *optional* are not the same thing, and T-36 in particular
must ship **with** T-22 rather than after it.

**T-28…T-32 (the six carried-forward capabilities, `technical-spec.md` §7b) hang off T-23** and
parallelise with each other and with T-25. T-30 additionally needs T-13/T-15 (the render path), and
T-31 *reduces* work relative to a third template type because it generalises rather than branches.

**Parallelisable:** T-02 and T-03 with T-01. **T-10…T-15 (the whole render path) with T-17…T-20
(the Liquid layer)** — the document-request interface takes HTML and does not care whether the
drops are owned yet. That is the only real compression available and it is worth taking, because
the render path carries the most uncertainty and starting early converts unknowns into
measurements. T-21 can start as soon as T-07 lands and **should not be deferred** — the drops are
where per-viewer scoping is easiest to lose silently.

**Hard ordering constraints:**
- T-01 **before** T-07 and T-08. The scope is unrecoverable after `scope_resolution.rb` goes.
- T-03 **before** T-10. The baseline cannot be measured after the aggregator changes.
- T-04 **before** T-05. Otherwise the plugin boots and 500s.
- T-07 **before** T-17. The tags need an owned context before an owned renderer can use them.
- T-11 **before** T-13. An engine cannot be conformance-tested against a contract that does not
  exist.

## 3. Verification strategy

| Layer | Runs | Proves |
|---|---|---|
| `lint` / `gates` | every PR, seconds | zero-reporter grep (with a lookahead — the plugin's own name is a substring of the forbidden one), no-secrets grep, layer purity, `no_html_safe`, `compat/` LOC, cap-table meta-test, golden-manifest check, support-matrix-is-generated, skip-has-a-reason |
| `rspec` (L1–L3) | every PR, 4 branches | library code, no DB, no Redmine boot |
| `adapter` | every PR, 3 engines | the aggregator's real SQL — **`corpus` folds in as a second invocation, 0 new jobs**, because the job cost is dominated by `bundle install` and folding is *how* the matrix stays additive |
| `minitest-standalone` | every PR, 4 branches, **no secret** | full-app, fork-runnable — G1 |
| `render-smoke` | every PR, **per engine (3)**, one branch | preflight round trip, conformance corpus, INV-5's forced failures, the readiness triple, the three asset models incl. the allowlist-refusal case, Mermaid's per-engine disposition |
| `migrate-updown` | every PR, 3 Rails branches | up → `VERSION=0` → schema equals the pre-install dump → up again idempotently |
| nightly | — | extra engines (advisory), perceptual diff (advisory), perf baseline (fails on breach), ZIP memory, engine CVE scan on the pinned digest, dependency audit |

**Target 17 jobs (today 13): additive, not multiplicative.** `render-smoke` is per **engine on one
branch**, never engine × branch — the naive 4 × 3 × 3 = 36 must be refused. `migrate-updown` is the
one unavoidably per-branch addition, because reversibility across three Rails majors is precisely
what is in doubt. **The earlier "~16" figure predates the Gotenberg adapter and the reversibility
requirement and is superseded.**

**Rules written into the files, not merely intended.** A bare `skip` fails — two mechanisms,
because one is insufficient: a grep for argument-less `skip`, **plus** a run-level check that every
skipped example has a non-empty message and that the total is ≤ a committed inventory. The
run-level one is what matters; the grep is defeated by `skip ''` and by a skip inside a helper.
`fail-fast: false` on every matrix, or you cannot see which engine broke.

**PDF verification never byte-diffs** (timestamps, object ids). Page count, extracted text,
structural metadata, targeted **scalar probes over named rectangles** (robust to font hinting,
which is precisely why full-page diffing cannot gate), and the SVG chart source as deterministic
text. Perceptual full-page diffs are nightly and advisory. Goldens **never auto-accept**: a changed
golden requires a manifest line with a reason in the same commit, and review means **looking at the
diff artefact**, not trusting the hash.

## 4. Risks and rollback

| Risk | Mitigation in this plan | Rollback |
|---|---|---|
| **Silent numerical drift** (R-04, 15) | T-01 first; byte-identical port; `corpus` on every PR; pinned reference date; per-adapter overlay **with reasons** instead of a tolerance | revert the offending commit; `corpus` names the failing case, the parameters, expected and actual |
| **Visibility invariant lost** (R-03, 15) | two-source `ScopeBinding`; the fail-open rescue **deleted rather than carried**; T-21 before the drop work; the five historical fixes as named, counted tests | `glue/legacy/` keeps the old path available while reporter is installed |
| **Stall with two half-working systems** (R-02, 20) | every task leaves the plugin releasable; Phase 1 ships standalone value in week one; `glue/legacy/` means an install is never mid-migration | stop after any phase; **stopping after Phase 3 is a success, not a failure** |
| **PDF fidelity regression** (R-05) | wkhtmltopdf retained as a CI-verified compatibility engine; `lint_templates` shows the blast radius **before** the default changes | switch the engine setting back; it is configuration, not a deploy |
| **No engine passes T-12** | the interface is the deliverable, the engine is replaceable — **keep wkhtmltopdf as the reference engine behind the new interface**. This is why the interface is specified before the engine is chosen | no rollback needed; the off-ramp *is* the plan |
| **Migration data loss** | copy-only, forward-only, never writing to reporter's tables; `import:plan` dry run; mandatory backup documented; the `VERSION=0` footgun documented and designed around | reporter's tables are untouched, so reinstalling it restores the old world |
| **Chart layout diverges between HTML and PDF** | the shared server-side `ChartLayout`; the >2% bounding-box falsifier in T-16 | server-side SVG for **both** outputs, forfeiting tooltips and legend-toggling — drill-through survives via `<a xlink:href>`, which is the only interaction the templates actually use |
| **Scope grows because DoR-1 contradicts the subset** | ADR-004 records this as a **supersession trigger**, so it is a planned branch | absorb the extra surface as Phase 4b |

## 5. Definition of done

**Per task.** A test that **failed before** the change, linked in the PR. Every new cap constant in
the cap table (a meta-test requires it, so a new cap cannot be added without a test). Every new
empty-safe path carries `degraded` **and** has both a refusal test and a true-zero test. Every new
skip carries a reason and is in the inventory. `zero_reporter` allowlist shrank or held — **never
grew**. Any golden change has a manifest line with a reason and a reviewed diff artefact. A declared
capability has a passing fixture; an undeclared one skips with a reason and the regenerated support
matrix is committed. The PR body names which of G1–G7 and INV-1…INV-9 the change touches.

**Whole idea**, against `01-context.md`'s goals:

| Goal | Done when | Not mechanised |
|---|---|---|
| **G1** | no-secrets check green; no secret-gated job conditions; a dated fork-PR run recorded | the fork-PR run itself — self-testing it would reintroduce the credential |
| **G2** | the dependency-skip helper deleted, its call sites asserting, newest branch in every job, no skip-inventory entry for it | — |
| **G3** | no polyfill / readiness-handshake / float-layout in the reference template (grep); layout and background fixtures pass | "renders equivalently" is a perceptual judgement |
| **G4** | `corpus` green on three engines over the **enumerated** space; the case set a superset of the frozen one; every overlay entry reasoned | the corpus is a bounded sample — the word *enumerated* is load-bearing and must stay |
| **G5** | T-21 green incl. the ordering and A/B/A tests; the monotonicity property green; the five historical fixes present and counted | the property is one-sided; it needs the strict case beside it |
| **G6** | failure fixtures green; no attachment, no journal, no bytes; `rescue Exception` absent by grep | — |
| **G7** | the install job green on a **bare** image executing only the README's tagged block; preflight returns structured output with every check true | **restate honestly: "≈3 commands plus one documented package install"** if the Chromium engine is the default — the clean-image job will find this immediately, so say it in the README rather than being caught by it |

**Explicitly not covered by any of this:** whether the subset is the *right* subset. No test
settles that; DoR-1's four queries do, and they are unrun. If this plan's verification section is
read as coverage of the scope decision, it will mislead.
