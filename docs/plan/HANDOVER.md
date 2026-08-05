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

**MySQL and MariaDB truncate a returned column label at 256 characters, and
ActiveRecord reads grouped results back BY THE GROUP EXPRESSION'S TEXT.** Group on
anything longer and every key comes back nil, the result collapses into one bucket and
the count is silently wrong. This is defect D-1 (`implementation-plan.md` §Findings)
and it is live in `group_by: age` with the default four boundaries. It is also a trap
for any FUTURE grouping expression: keep them short, or alias them.

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
| Redmine 6.1-stable, standalone, PostgreSQL 16 | **yes, locally (2026-08-05)** | 951 rspec + 97 adapter + 215 corpus + 129 minitest, 0 failures |
| Redmine 6.1-stable, standalone, **MariaDB 10.11** | **yes, locally (2026-08-05)** | 97 adapter + 215 corpus, 0 failures. **This is the run that found defect D-1** |
| Redmine 7.0-stable, standalone, PostgreSQL | yes, before T-01 | 906 rspec + 86 adapter + 114 minitest, 0 failures, 4 skips |
| Redmine 6.1-stable, with reporter, PostgreSQL | yes, before T-01 | 906 + 86 + 114, 0 failures, 0 skips |
| Redmine 5.1-stable / 6.0-stable | **no** | Ruby floor; CI only |
| MySQL 8.0 proper, MariaDB 11 | **no** | CI only. MariaDB 10.11 was run locally and takes the same kernel branch |
| **CI, any job, on this work** | **NO — never run** | the workflow was rewritten and has not executed once |

The counts moved because T-01 added tests, not because anything changed: 906 → 951 rspec
(the corpus's DB-less coverage, ratchet and canonicaliser specs), 86 → 97 adapter (defect
D-1 and the four actors), 114 → 129 minitest (the scope fixture), plus the 215-example
corpus verification, which is a new invocation and only runs with the reference date
pinned. MariaDB 10.11 rather than 11 because that is what the container's apt repository
carries; both are the `mysql2` adapter and the same kernel branch, and CI runs 11.

**MySQL 8.0 itself is still unverified locally.** The Debian packages for MySQL and
MariaDB conflict, so only one of the two can be installed at a time. D-1's mechanism is
MySQL-family-wide (a server-side label limit, not a MariaDB quirk), so the expectation is
that 8.0 behaves identically — but that is an expectation, and the `corpus` job on MySQL
8.0 is what will settle it.

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
2. **T-02** needs production data and therefore needs the curator. Three claims in
   `claims.json` discriminate on that one measurement.
3. **T-03** (performance baseline) must precede T-10.
4. **The first real CI run** is still owed, and now has two more jobs in it. A red
   `corpus` job on MySQL 8.0 would be information, not a regression — see §4.

Use `TASK-PROMPT.md`; fill in the STATE block from §4 above rather than from memory.
