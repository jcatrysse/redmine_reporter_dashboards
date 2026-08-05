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
`lib/sql_aggregation/query_aggregator.rb:1135` is its single clock read. Pin the corpus
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
wrong. This is defect D-1 (`implementation-plan.md` §Findings), live in `group_by: age`
with the default four boundaries. A trap for any FUTURE grouping expression too: keep
them short, or alias them. **MySQL 8.0 does NOT do this** — it was written up as a
MySQL-family defect and the first CI run refuted that, which is why the overlay has a
`mariadb` family separate from `mysql`.

**MySQL 8 evaluates `projects.<col> IN (SELECT …)` inside a LEFT JOIN's ON clause as
TRUE.** Measured on 8.0.46 (E-1 in §Findings). An entitlement check written that way
passes for everyone, silently, on that engine only. `issues.project_id IN (SELECT …)` and
a literal `projects.id IN (1,2,3)` are both correct everywhere — and both are what
Redmine actually emits, so no production path is affected. If you are writing a stubbed
visibility condition, copy Redmine's shape rather than inventing an equivalent one; the
harness did, and MySQL then made the harness lie about visibility.

**A plugin's `lib/` is on Rails' autoload paths, so Zeitwerk demands path-to-constant
agreement there.** `lib/redmine_reporter_dashboards/compat/base_record.rb` that defines a
method on `Compat` instead of a `Compat::BaseRecord` class raises `Zeitwerk::NameError`
at boot — not at require time, which is why it survives a green rspec run and dies in the
full-application suite. The plan's future `compat/enum.rb` and `compat/serialize.rb` have
to define `Compat::Enum` and `Compat::Serialize`, or live as methods in `compat.rb`.

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
3. **D-1 is DECIDED and closed for now: it waits for T-08.** The curator chose this on
   2026-08-05 after the measurement showed it is not the one-line change the plan claimed and
   that fixing it today would mean weakening gate G7. Their production is PostgreSQL, which is
   unaffected. **Do not pick this up as low-hanging fruit** — see §Findings D-1 in
   `implementation-plan.md` for the mechanism, the two candidate fixes, and the G7 question
   that has to be re-opened with the curator if anyone wants to move it earlier.
4. **T-02** needs nothing from the curator any more — the production export has been supplied
   (26 templates, PostgreSQL, no mail schedules yet). Its survey has already been done
   informally and found the corpus gap noted in §Findings; the task itself (the reporting
   script) is unwritten.
5. **T-07 / T-08**: the re-seam. Both are now unblocked, and T-08 carries D-1.

Use `TASK-PROMPT.md`; fill in the STATE block from §4 above rather than from memory.
