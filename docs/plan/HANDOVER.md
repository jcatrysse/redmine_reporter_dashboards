# Handover — what a fresh session cannot work out from the code

Everything else in `docs/plan/` describes the *plan*. This file records what was learned
by **running** it: traps that cost a session real time, work that looks broken and is
not, and what has actually been executed versus merely claimed.

It is not a diary. If something here stops being true, delete the entry — a stale
handover is worse than none.

**Where the rest of the state lives:** `implementation-plan.md` §Status (what landed),
`CLAUDE.md` (how to work), `reference/verification-*.md` (measurements), and the commit
messages, which carry the reasoning for every non-obvious decision.

---

## 1. Traps in this codebase

Each of these produced a green run that meant nothing. They are ordered by how easily
they fool you.

**Minitest silently does not run test methods defined after `private`.**
`test/functional/reporter_project_pages_controller_test.rb` has a `private` section
partway down. Ten tests appended below it were never executed, and the file reported
44 runs while defining 53 test methods. Nothing failed; the tests simply did not exist
as far as the runner was concerned. **Check that the run count moved** after adding
tests — `grep -c '^  def test_'` against the reported `N runs`.

**The mirrored plugin copy has no git history.** `.codex/redmine_clone.sh` rsyncs into
`redmine/plugins/<name>/` with `--exclude .git/`. Anything that inspects history —
`spec/golden/baseline_spec.rb`, and the future `corpus` job — *skips* there, and a
skipped guard is indistinguishable from a passing one. Those checks must be run **from
the plugin checkout**. The `baseline` CI job does this and fails if they report pending.

**Editing inside `redmine/` is destroyed on the next run.** Same rsync, `--delete`. Edit
the plugin repo and re-run the script.

**The aggregator reads the clock, so a pinned fixture is not enough.**
`lib/redmine_reporter_dashboards/aggregation/query_aggregator.rb:1135` is its single clock read. Pin the corpus
reference date without freezing time and every period window comes back **0** — which
looks like a broken aggregator and is not. `RrdAdapterHarness.freeze_to_reference_date!`
does both, and must run before `seed!`. Good news for the corpus: that one read is
Ruby-side, and `:2099` records that the SQL deliberately carries no `CURRENT_DATE`
arithmetic, so freezing Ruby is sufficient — there is no database clock to keep in step.

**Byte-identity comparisons need byte reads.** `git show` hands back bytes;
`File.read` applies an encoding. Compared directly, one em-dash reads as a three-byte
difference that is not a difference. Use `File.binread` against raw git output.

**`File.read` on a UTF-8 source file fails where `LANG` is unset.** Ruby's default
external encoding follows the locale, and a bare container has none — so reading any
file in this repo that contains an em-dash raises `invalid byte sequence in US-ASCII`.
It passes on a developer machine and fails in a minimal container. Name the encoding:
`File.read(path, encoding: 'UTF-8')`.

**Rails inserts every fixture set ANY test class in the process declares.** A class
that declares no `:issues` still finds Redmine's fixture issues in the database,
because another plugin test class declared them — and whether it does depends on the
order the classes ran in. Two of the scope-fixture tests were order-dependent on their
first run for exactly this reason, one passing and one failing in the same run. Do not
build a fixture on the ABSENCE of rows; restrict every query and every scope to the
records the test created, and assert that nothing resolved reaches outside them.

**A generating run writes into the MIRROR.** `RRD_CORPUS_WRITE=1` and
`RRD_SCOPE_WRITE=1` are executed from inside `redmine/`, so the files land in
`redmine/plugins/<name>/spec/golden/` and the next `redmine_clone.sh` deletes them.
Copy them back out before committing — `spec/golden/README.md` has the command.

**MariaDB truncates a returned column label at 256 characters, and ActiveRecord reads
grouped results back BY THE GROUP EXPRESSION'S TEXT.** Group on anything longer and
every key comes back nil, the result collapses into one bucket and the count is silently
wrong. This was defect D-1 (`implementation-plan.md` §Findings), and it is **fixed** —
the counted age axis no longer groups at all. **The trap is not.** It applies to any
FUTURE grouping expression: keep them short, or do what the age axis now does and count
the buckets with conditional aggregates read back positionally. Note that aliasing does
NOT save you — the alias is derived from the expression's text and is already truncated
on PostgreSQL, which answers correctly; the defect is the two ends *disagreeing* about
the truncation, not the length itself. **MySQL 8.0 does NOT do this** — it was written up
as a MySQL-family defect and the first CI run refuted that, which is why the overlay has
a `mariadb` family separate from `mysql`. That family survives the fix; the reason it
exists is a property of the engines, not of the defect.

**A measured or crosstabbed `group_by: age` still groups on the CASE**, so it is still
exposed on MariaDB past ~4 boundaries. That is deliberate and documented in the README's
database section — not an oversight, and not something to "finish" without reading why.

**MySQL 8 evaluates `projects.<col> IN (SELECT …)` inside a LEFT JOIN's ON clause as
TRUE.** Measured on 8.0.46 (E-1 in §Findings). An entitlement check written that way
passes for everyone, silently, on that engine only. `issues.project_id IN (SELECT …)` and
a literal `projects.id IN (1,2,3)` are both correct everywhere — and both are what
Redmine actually emits, so no production path is affected. If you are writing a stubbed
visibility condition, copy Redmine's shape rather than inventing an equivalent one; the
harness did, and MySQL then made the harness lie about visibility.

**CORRECTED 2026-08-05 — a plugin's `lib/` is NOT autoloaded, so path-to-constant
agreement is not required there.** This entry used to say the opposite, and T-08's kernel
move measured it: the two kernel files now live at
`lib/redmine_reporter_dashboards/aggregation/` while still declaring
`module SqlAggregation`, and the full application boots (139 minitest runs, 0 errors).
Measured inside the booted app:

    Rails.configuration.respond_to?(:autoloader)                -> false  (Rails 7.2)
    plugin lib/ in ActiveSupport::Dependencies.autoload_paths    -> false
    plugin lib/ in Rails.application.config.eager_load_paths     -> false

Two things follow. `init.rb:20-21`, which tells Zeitwerk to `ignore` this plugin's `lib/`,
is **dead code on Rails 7+** — the `respond_to?` guard is false, so the ignore never runs
— and it does not matter, because Redmine does not put a plugin's `lib/` on either path in
the first place. Only `app/` is autoloaded, and THERE the constraint is real.

An earlier session did record a genuine `Zeitwerk::NameError` from
`lib/redmine_reporter_dashboards/compat/base_record.rb`. This correction does not explain
that observation — it only shows the stated mechanism cannot be it. `compat.rb` was kept as
one file anyway and works, so nothing is blocked; if you hit a NameError from `lib/`, treat
the cause as **unknown** rather than as this entry, and measure before concluding.

**Redmine 6.0 is where BOTH `ApplicationRecord` and `IconsHelper#sprite_icon` arrived.**
Neither exists on 5.1, and calling either raises rather than degrading. Both were in this
plugin from v0.5.0 (D-2, D-3). If you add anything that touches a Redmine core class or
helper, check when it appeared — `git -C redmine ls-tree origin/5.1-stable <path>` answers
it in one line, and the 5.1 minitest job answers it for real.

**Every aggregator entry point LOGS AND DEGRADES on an argument it cannot use.** An unknown
completeness field, a custom field the viewer may not see, a `group_by` that does not resolve — all
produce `Rails.logger.warn` and a smaller answer, never an exception. That is right for a template
author and silent for anything that measures. T-03's `completeness.seven` asked for two field names
the kernel does not accept and measured a five-field panel under a seven-field name for a whole
generation of the baseline artefact. **If you write anything that runs the kernel and reads a number
off it, pin the SIZE of the answer as well as the number** — `PerformanceCases::EXPECTED_RESULT_SIZE`
is that control, and the reason it exists.

**`.flags` returns `'buckets' => []` on purpose.** Its shape is `stages`; the empty array is there so
a template looping over buckets renders nothing rather than raising. Anything that measures "how big
was the answer" off `result['buckets'].length` therefore reports the flag funnel as **zero** and the
period series (which has no buckets at all) as its hash key count. `Performance.result_size` is
shape-aware for this reason; copy it rather than re-deriving it.

**Timings are measured with `CLOCK_MONOTONIC`, and they have to be.** The bench runs under the
corpus's frozen clock (`travel_to`), which stubs `Time.now` — a wall-clock timing there measures
**zero** for everything. The same applies to the artefact's `measured_at`, which reads
`CLOCK_REALTIME`: `Time.now` under the pin would stamp it with the reference date, a plausible-looking
lie about when the measurement happened.

**`rails` is `null` in the performance artefact's provenance, and that is correct.** The adapter
harness boots ActiveRecord *without* Rails and defines a stub `Rails` module carrying only `.logger`,
so `Rails::VERSION::STRING` genuinely does not exist in that process. `active_record` is the
load-bearing figure there.

**A CI step that needs the plugin checkout needs `working-directory` EVERY TIME.** The
`corpus` job checks out into `plugin/`; one step of six was missing it and failed in all
three engines for the one reason that step must never fail for — having found nothing to
check. `working-directory` is per step, not per job.

---

## 1b. Working agreement — verification, decided by the curator

**Curator decision, 2026-08-05: prefer pushing and letting CI judge over stopping.** Asked
whether a change whose only remaining unknown is an engine this container cannot run should
be held back or pushed, the answer was push. So:

- **A red CI cell on an engine that cannot be run locally is an ACCEPTED outcome**, not a
  failure of the change. MariaDB and MySQL are the concrete cases (their Debian packages
  conflict, so only one can be installed and neither is by default). Push, read the cell,
  iterate.
- **This does NOT extend to a locally red suite.** The distinction is the whole point: a
  test that could have been run here and was not is a different thing from a test that
  cannot be run here at all. D-1's first attempt was reverted because it left **11 DB-less
  unit examples** red — nothing to do with MariaDB — and that is still the right call.
  Local green, remote unknown: push. Local red: fix it or revert it.
- **Do not weaken an assertion to make the local suite green.** If an assertion has to
  change because the implementation legitimately made its subject unreachable, that is an
  argument for the pull request body, not an edit that quietly matches the new behaviour.
  D-1's fix hit this twice — *"keeps counts for a value outside the expected bucket list"*
  and its drill-through sibling, both pinning defensive handling of a group key the
  DATABASE invented, which is precisely what the fix makes unreachable. Both were
  **deleted and replaced by the invariant that took their place**, and argued in the pull
  request. That is the shape to copy: delete and state the inverse, never soften in place.

---

## 2. Known and deliberately untouched

**`lib/sql_aggregation/scope_resolution.rb` contains nine `rescue nil`,** a construct
`CLAUDE.md` §5 forbids, plus a fail-open `enforce_visibility` rescue. All pre-existing.
**Do not fix them.** T-07 deletes this file (demoted to `glue/legacy/`), so the work
would be thrown away, and touching it before T-01 is complete is a §1 refusal
condition. Flagged here so it is not mistaken for a new violation.

**`.codex/check_ruby_floor.sh` still exists and runs in CI.** `technical-spec.md` §8's
floor decision deletes it. Removing it changes a documented support claim, so it is a
curator decision (G9: the matrix changes in the same PR), not a cleanup.

**The registers-relation path in `scope_resolution.rb` does not enforce visibility.**
Finding F-2. It is FROZEN THAT WAY by a triple in the scope fixture, deliberately, so
that T-07 closing it is a visible decision rather than a diff nobody reads. Do not
"fix" it here: the file is the one T-07 demotes, and changing it now would move the
oracle it is measured against.

**`ZERO_REPORTER_MODE=strict` fails today, by design.** 13 files still name the base
plugin or the vendor gem, each listed with its reason in
`script/gates/zero_reporter.allowlist`. Warn mode enforces the ratchet. Strict is what
1.0 must pass.

---

## 3. Environment quirks (cloud sessions)

- **`rsync` may be absent.** `redmine_clone.sh` fails with exit 127 at the mirror step.
  `sudo apt-get install -y rsync`.
- **Never run two things that load `spec/adapter/adapter_helper.rb` at the same time.** They
  share one database; `load_schema!` recreates every table with `force: true` and `seed!`
  deletes every row, so the second process pulls the ground out from under the first. It cost
  a session two false diagnoses in one afternoon — first
  `PG::UndefinedTable: relation "users" does not exist` halfway through a working run, then a
  bench example reporting an **empty** substrate that was demonstrably there minutes earlier,
  both of which read as ordering bugs in the specs. It is not only `rspec`: a throwaway
  `bundle exec ruby` probe that requires the harness does exactly the same damage. Check with
  `pgrep -af rspec` (the `-f` matters — the process name is not "rspec") before starting
  anything, and when a long benchmark is in flight, wait.
- **PostgreSQL does not survive idle time.** `sudo service postgresql start`, then
  `pg_isready`. A stopped server surfaces as `ActiveRecord::ConnectionNotEstablished`
  in a `before(:suite)` hook, which reads like a spec bug.
- **Redmine 5.1 needs Ruby ≤ 3.2.** A container on 3.3+ cannot satisfy its Gemfile, so
  `detect_ruby_version` correctly refuses rather than running on an unsupported Ruby.
  5.1 is a CI-only branch unless `mise` is available.
- **`mise` is usually absent.** `.codex/ruby_version.sh` therefore prefers the Ruby
  already on `PATH` whenever it satisfies Redmine's own Gemfile — which covers 6.0,
  6.1 and 7.0 on a 3.3/3.4 container.
- **Switching Redmine branches** used to fail silently because `test_setup.sh` dirties
  Redmine's Gemfile. `redmine_clone.sh` now discards that and asserts `HEAD`. If you
  see a run reporting one Redmine version while behaving like another, check this first
  — it is exactly what happened once.

---

## 4. What has actually been executed

`CLAUDE.md` hard rule 3: an untested configuration is unsupported. This is the honest
record as of the last local run.

| Configuration | Executed? | Result |
|---|---|---|
| Redmine 6.1-stable, standalone, PostgreSQL 16 | **yes, locally (2026-08-05)** | 956 rspec + 96 adapter + 217 corpus + 133 minitest, 0 failures |
| **Redmine 6.1-stable, standalone, PostgreSQL 16 — after D-1's fix** | **yes, locally (2026-08-05)** | 1128 rspec + 157 adapter + 217 corpus + 139 minitest, **0 failures**. Plus `spec/golden` from the PLUGIN CHECKOUT (where gate G7 has its git history): 166 examples, 0 failures, **0 pending**. The corpus is byte-identical to before the fix — all 176 recorded values unchanged |
| **D-1's fix on MariaDB** | **no, and cannot be here** | MariaDB is not installable beside MySQL in this container. The `adapter (MariaDB 11)` and `corpus (MariaDB 11)` CI cells are the measurement, per §1b. **A red MariaDB cell after this lands is information, not a regression** |
| Redmine 6.1-stable, standalone, **MariaDB 10.11** | **yes, locally** | 313 adapter+corpus, 0 failures. **The run that found defect D-1** |
| Redmine 6.1-stable, standalone, **MySQL 8.0.46** | **yes, locally** | 97 adapter + 214 corpus, 0 failures (before the last two cases were added). **The run that refuted D-1's scope** and exposed E-1 |
| Redmine 7.0-stable, standalone, PostgreSQL | yes, before T-01 | 906 rspec + 86 adapter + 114 minitest, 0 failures, 4 skips |
| Redmine 6.1-stable, with reporter, PostgreSQL | yes, before T-01 | 906 + 86 + 114, 0 failures, 0 skips |
| Redmine 5.1-stable / 6.0-stable | **no, and cannot be** | 5.1's Gemfile refuses Ruby 3.3+; CI only |
| **CI** | **YES — first run 2026-08-05, run 30992686636** | 17 jobs, **5 red**: `corpus` ×3 (a missing `working-directory`), `adapter` MySQL 8 (D-1's scope + E-1), `minitest` 5.1 (**92 errors — D-2**). Everything else green |
| **CI, second run 30998558913** | **YES** | **16 of 17 green**, including all three `corpus` jobs — the first real proof of gate G7's differential on PostgreSQL, MySQL 8 and MariaDB 11. The one red was `minitest` 5.1 again, 92 → **27 errors**, all D-3 (`sprite_icon`) |
| **CI, third run 31000622798** | **YES** | **17 of 17 green** — the first fully green CI run on this branch |
| **T-03: the R7 invariants, PostgreSQL 16** | **yes, locally (2026-08-05)** | 34 examples, 0 failures. Every workload's query count identical at 100 and 10 000 issues; **zero** `Issue` instantiations everywhere; the capped axes bounded and their collapsed totals intact |
| **T-03: the benchmark, PostgreSQL 16** | **yes, locally, twice (2026-08-05)** | 27 cells, 20 warm runs after 3 discarded, 4-core Xeon @2.80GHz. **The two runs disagree by up to ×1.26 on p95**, and `version_rollup.costs@100000` was *invalid* in the first (dispersion 0.417) and valid in the second (0.090) — finding P-3, and the reason no timing is a gate. The HTML\|PDF axis is **not measured and recorded as blocked** (P-2) |
| **T-02: the survey, PostgreSQL 16** | **yes, locally (2026-08-05)** | 22 adapter examples + 53 linter + 25 formatter, 0 failures. The rake task was also **run end to end** on both paths — reporter absent, and against temporary reporter-shaped tables seeded into `redmine_test` and dropped again — because reading the real output is what found the duplicate-finding noise and the unwrapped messages |
| **T-03 on MySQL / MariaDB** | **no** | The invariants spec runs in the existing `adapter` CI job on all three engines, so CI answers it; the *benchmark* is deliberately not in CI — a timing on a shared runner is noise, which is what the dispersion rule and the advisory label are about |

**MySQL and MariaDB cannot be installed at the same time** — the Debian packages
conflict, and switching costs an apt purge plus a datadir re-init each way. Both have now
been run locally, one after the other; if you need to switch, `rm -rf /etc/mysql` will
break the *next* server's `!includedir` (the package config has to be reinstalled with
`--force-confmiss`), and a leftover `mysqld` keeps the socket until it is killed by pid.

That first CI run is the most useful thing that has happened to this branch: three of
the five failures were invisible to every local configuration, and one of them (D-2) had
been shipping since v0.5.0.

The counts moved because T-01 added tests, not because anything changed: 906 → 953 rspec
(the corpus's DB-less coverage, the ratchet, the canonicaliser and the compat shim),
86 → 97 adapter (D-1 and the four actors), 114 → 130 minitest (the scope fixture), plus
the 214-example corpus verification, which is a new invocation and only runs with the
reference date pinned. MariaDB 10.11 rather than 11 because that is what the container's
apt repository carries; CI runs 11 and agrees with it.

That last row is the important one. The CI rewrite (secret removal, standalone
minitest, the `gates` and `baseline` jobs) is verified only by local simulation of each
step. **The first real CI run is the real check**, and a red one is information, not a
regression.

The 4 skips in every standalone run are the two report widgets' functional tests. They
need the private reporter plugin, they carry a reason, and they are the accepted cost
of a CI that runs on fork pull requests.

---

## 5. Where to pick up

`implementation-plan.md` §Status is authoritative; verify it against `git log` per
`CLAUDE.md` §1. In short:

1. **T-01 is done.** The oracle exists: read `spec/golden/README.md` before touching
   anything in that directory, and treat a corpus difference as a finding to explain
   rather than a file to regenerate. Two things it produced that are somebody's work
   now: defect **D-1** (T-08 owns the fix) and finding **F-2** (T-07 owns the decision)
   — both in `implementation-plan.md` §Findings.
2. **T-03's aggregation half is done**, so `CLAUDE.md` §1's "no aggregator change before
   T-03" guard has expired. **T-03's HTML|PDF half stays owed by T-10** (P-2), recorded in
   the artefact as blocked.
3. **D-1 is FIXED**, in T-08, where the plan said it had to land. The counted age axis no
   longer groups; gate G7 grew a declared-exception mechanism to express "the blob plus
   exactly these three argued hunks" (`spec/golden/kernel_exception.rb`); the per-adapter
   overlay is empty again with `RATCHET = 0`. **Verified on PostgreSQL only** — MariaDB is
   not installable beside MySQL in this container, so the `adapter (MariaDB 11)` and
   `corpus (MariaDB 11)` CI cells are the measurement, per §1b. What is still exposed, on
   purpose: a MEASURED or crosstabbed age axis (README, database section).
4. **T-02 is done.** `rake reporter_dashboards:import:plan` is the repeatable form of the
   R-15 measurement, and `RedmineReporterDashboards::TemplateLinter` is the linter FR-71
   later puts behind the editor's lint panel — so extend that one rule table rather than
   writing a second checker. It raised **F-3** (a question about gate G8's 1.0 target)
   which is the curator's. What is still owed by a later task: `rake
   reporter_dashboards:lint_templates`, which the spec names in §6 — today it would be a
   duplicate of `import:plan`'s section 5, so it was deliberately not written twice.
5. **T-07 is done** — §6 records what is exercised and what deliberately is not.
6. **T-08 is done — port AND D-1 fix.** The two kernel files are at
   `lib/redmine_reporter_dashboards/aggregation/`, and `KERNEL_FILES` is a map (working-tree
   path => v0.5.0 blob path) so gate G7 compares the ported file with its baseline instead of
   comparing a path with itself. G7 now reconstructs the expected file as *blob + declared
   hunks* rather than diffing: `drill_through.rb` declares none and is held to plain
   byte-identity; `query_aggregator.rb` declares three, all D-1's. **There is no writer for
   those recorded fragments, deliberately** — an overlay entry records a MEASUREMENT and can
   be regenerated, an exception records an ARGUMENT and must be written by hand with its
   reason, or the gate becomes a formality. Next: **T-09 onward**.

---

## 6. T-07 as built — what is exercised, and what deliberately is not

Implemented 2026-08-05. The design that preceded it was right about the shape; this
records what a reader cannot see from the diff.

**The seam was five call sites.** Two `include`s, two `resolve_scope`, one
`resolve_query`. `Liquid::ScopeBinding` keeps those two method names, so each tag
changed by one line.

| Layer | File | Sources |
|---|---|---|
| owned | `liquid/scope_binding.rb` | **two**: `query_id:` → `IssueQuery.visible(actor)`, else `RenderContext#scope` |
| owned | `liquid/render_context.rb` | — carries actor, scope, query. **An actor is required to construct one** |
| legacy | `glue/legacy/scope_resolution.rb` | six, unchanged, moved |
| legacy | `glue/legacy/reporter_list_patch.rb` | owns the thread-local, moved |

**`enforce_visibility` was not ported, and that is the point.** It exists in the legacy
module because five of its six sources have provenance it cannot vouch for — which is
also why it has to fail OPEN. Both owned sources start from `Issue.visible`, so there is
nothing left to defend. An invariant held by construction, not by a patch.

**THE OWNED PATH IS NOT EXERCISED IN PRODUCTION YET, and must not be made to look as
if it is.** Nothing builds a `RenderContext`: these tags only ever run inside the
optional host plugin's renderer, and standalone T-06 degrades the widgets. So every
real render still takes the legacy path, which is exactly what T-07's acceptance list
asks for. T-10 is what fills it in. If you are tempted to have the glue synthesise a
`RenderContext` from the host's registers to "finish" this — don't. It would run the
same archaeology behind a new name and make the owned path look tested.

What *is* exercised: `spec/liquid/scope_binding_spec.rb`, 25 examples, including one
that stubs `User.current` to RAISE and asserts the owned path completes. INV-1 is the
easiest invariant here to lose silently, so it is tested by explosion rather than by
reading the code.

**The two results that mattered, both measured:** `spec/golden/` is byte-identical
(`git diff --stat -- spec/golden` empty) and all **217 corpus examples** pass — T-07's
acceptance list calls that "the single most important assertion in the whole plan".
F-2's decision is what bought the first one: closing the leak by construction in the
owned path, rather than patching the legacy module, means the frozen scope-fixture
triple never moved.

**A trap for the next mover.** The two tag specs and the scope-fixture test exercise
the LEGACY path, so they must `require` `glue/legacy/scope_resolution` explicitly.
On a real install it arrives via `REPORTER_GLUE_FILES`; in a spec process nothing loads
it, and `ScopeBinding` then correctly resolves *nothing* — which reads as 40 broken
examples rather than as a missing require.

**`REPORTER_GLUE_FILES` is separate from `REPORTER_PATCH_FILES` on purpose.** The legacy
module is loaded whenever the host plugin is present, not as a side effect of the
`IssueListReportTemplate` prepend succeeding. Tying the two would mean one failed patch
silently costing an install its scope resolution.

**The gate:** `script/gates/no_thread_local.sh`, wired into the `gates` job. It also
catches `thread_variable_set`/`Fiber[]`, because swapping the spelling would satisfy a
naive grep while changing nothing. Warn mode passes with two exemptions; strict mode
fails today by design, and is what 1.0 must pass once `glue/legacy/` is gone.

**Still under `lib/` rather than `glue/`**, and deliberately left for a later mechanical
move: `reporter_report_content_patch.rb`, `patches/report_patch.rb`,
`liquid/issue_drop_patch.rb`, `liquid/custom_field_value_drop.rb`. All host-plugin-only.
T-07 moved exactly what its `Touches:` line named plus what the new gate forced; a
general reorganisation is a different commit.
