# The golden oracle (T-01) and the performance baseline (T-03)

Everything here exists to answer one question during the decoupling sequence: **did the
numbers change?** The aggregation kernel is being lifted out of one plugin and re-seamed
into another, and the only honest way to do that is to write down what it answers today
and keep comparing.

Nothing in this directory tests the plugin's behaviour. It tests that the behaviour has
not moved.

**The performance baseline (T-03) lives here too, and it is a different kind of file.** The
corpus is an *oracle*: a difference is a failure. `performance/baseline.json` is a
*measurement*: a difference is a number to look at. Nothing asserts a millisecond figure —
see [§The baseline is not an oracle](#the-baseline-is-not-an-oracle).

## What is here

| Artefact | What it freezes | Regenerable? |
|---|---|---|
| `baseline.rb` | the commit the kernel is diffed against for gate G7, and the map from each ported file to its v0.5.0 blob | it is a SHA |
| `reference_date.rb` | the pinned date the corpus is generated with, and the refusal to run unpinned | n/a |
| `corpus_canonicaliser.rb` | one result → one byte sequence (`technical-spec.md` §2 Step 0) | n/a |
| `corpus_cases.rb` | **the questions**: 176 (entry point, scope, actor, arguments) tuples | n/a |
| `aggregation/values.jsonl` | **the answers**, one canonical JSON record per case | yes, from the baseline commit |
| `aggregation/manifest.json` | provenance: baseline commit, reference date, zone, engine, digests | yes |
| `aggregation/overlay/*.jsonl` | the per-engine exceptions the overlay declares | yes |
| `adapter_overlay.rb` | which cases may differ per engine, why, and how many may exist | n/a |
| `scope/scope.jsonl` | **the irrecoverable one**: what `ScopeResolution` resolves, per (template, query, actor) | **no** |
| `sql/scope_sql.jsonl` | the SQL those scopes generate, tokenised | yes |
| `performance_cases.rb` | **the T-03 matrix**: 9 workloads × 3 issue counts, plus the query budget, the expected answer size and the two blocked render media | n/a |
| `performance.rb` | the statistics (nearest-rank percentiles, sample stddev), the `stddev/p50 > 0.35` invalid rule, and the artefact IO | n/a |
| `performance/baseline.json` | **the measurement**: p50/p95/max/stddev per cell, its provenance, and the 12 render cells recorded as blocked | yes, by re-running the benchmark |

The value corpus is regenerable because the kernel's signature does not change and
`v0.5.0` stays in git. **The scope fixture is not.** Once `scope_resolution.rb` is
deleted there is nothing left to ask. That is why it is frozen first.

## Regenerating

Never regenerate to make a failing comparison pass. A difference is a finding; the file
is the record. Regenerate only when the *question* changed — a new case, a new actor, a
deliberate behaviour change that has been argued for in the pull request.

```bash
# 1. the value corpus — PostgreSQL only (the canonical engine)
./.codex/redmine_clone.sh 6.1-stable && ./.codex/test_setup.sh
cd redmine
RRD_REFERENCE_DATE=2025-12-29 RRD_CORPUS_WRITE=1 \
  RRD_ADAPTER_URL=postgres://redmine:redmine@localhost/redmine_adapter_test \
  bundle exec rspec -I plugins/redmine_reporter_dashboards/spec \
                       plugins/redmine_reporter_dashboards/spec/adapter/aggregation_corpus_spec.rb

# 2. the per-engine overlay — only for a family that declares entries
RRD_REFERENCE_DATE=2025-12-29 RRD_CORPUS_OVERLAY_WRITE=1 \
  RRD_ADAPTER_URL=mysql2://redmine:redmine@127.0.0.1/redmine_adapter_test \
  bundle exec rspec -I plugins/redmine_reporter_dashboards/spec \
                       plugins/redmine_reporter_dashboards/spec/adapter/aggregation_corpus_spec.rb

# 3. the scope fixture — needs the full application
RRD_SCOPE_WRITE=1 bundle exec rake redmine:plugins:test \
  NAME=redmine_reporter_dashboards \
  TEST=plugins/redmine_reporter_dashboards/test/unit/golden_scope_fixture_test.rb

# 4. the performance baseline (T-03) — opt-in, ~3 minutes, seeds 100 000 issues
RRD_BENCH=1 RRD_BENCH_WRITE=1 RRD_REFERENCE_DATE=2025-12-29 \
  RRD_ADAPTER_URL=postgres://redmine:redmine@localhost/redmine_adapter_test \
  bundle exec rspec -I plugins/redmine_reporter_dashboards/spec \
                       plugins/redmine_reporter_dashboards/spec/adapter/performance_baseline_spec.rb
```

`RRD_BENCH_SEED` changes the fixture's data shape (recorded in the artefact, so a result
can be shown not to depend on one particular shape), `RRD_BENCH_RUNS` shortens the run for
shaking the harness out — and `save` **refuses** to write an artefact whose cells were
measured fewer than 20 times, so a short run cannot be committed. `RRD_BENCH_IMAGE_DIGEST`
carries the runner image digest, which a process cannot discover about itself; absent, it
is recorded as `null` rather than guessed.

**Do not run two `spec/adapter` invocations at once.** They share one database and the
harness recreates every table with `force: true`, so the second drops the first's tables
mid-run.

**Then copy the files back out of the clone.** `redmine_clone.sh` rsyncs the plugin
*into* `redmine/plugins/<name>/`, so a generating run writes there and the next mirror
destroys it:

```bash
cp -r redmine/plugins/redmine_reporter_dashboards/spec/golden/{aggregation,scope,sql} spec/golden/
```

## Three traps, each of which produced a green run meaning nothing

1. **The mirror has no git history.** `baseline_spec.rb` skips there — correctly, there
   is nothing to check in a copy — and a skipped guard looks exactly like a passing one.
   The `baseline` and `corpus` CI jobs run it **from the plugin checkout** and fail if it
   reports pending.
2. **Pinning the fixture is not enough; the clock has to move with it.** The aggregator
   reads the clock once (`query_aggregator.rb:1135`) to derive its windows. Pin the date
   without freezing time and every period count comes back 0, which looks like a broken
   aggregator. `RrdAdapterHarness.freeze_to_reference_date!` does both and must run
   before `seed!`.
3. **Other test classes' fixtures are in the database.** Rails inserts every fixture set
   any class in the process declares, so Redmine's own issues appear in a cross-project
   query — in *some* of the scope-fixture tests, depending on which class ran first.
   Every query and drop in that fixture is restricted to its own substrate, and one test
   asserts that no resolved scope ever reaches outside it.

## What the corpus has already found

**Defect D-1** — `group_by: age` collapsed into the `(none)` bucket on **MariaDB**
whenever the generated `CASE` passed 256 characters, which four age boundaries do, which
is the default. **Fixed in T-08**, where the plan said it had to land: the counted age
axis no longer groups, so there is no returned column label for MariaDB to truncate. The
overlay's only two entries are gone and `RATCHET` is back to **0** — which is the
mechanism working as designed rather than the entries having been wrong. "A named
pre-existing defect is a TEMPORARY entry; the commit that fixes it deletes the entry and
lowers the ratchet" is written in `adapter_overlay.rb`, and this is that commit.

Fixing it needed a second mechanism as well, because gate G7 could previously express
only "identical" or "different": `kernel_exception.rb` records the byte-exact hunks the
kernel is allowed to carry against the v0.5.0 blob, each with a reason, under its own
ratchet. The check reconstructs the expected file from the blob plus those hunks — so
one undeclared byte, *including inside a declared hunk*, still fails.

**And the corpus corrected itself.** D-1 was first written up as affecting the whole
MySQL family, on the evidence of one engine. The first CI run measured MySQL 8.0.46
answering correctly and refuted it — which is why `mysql` and `mariadb` are now separate
overlay families, and why the exhaustiveness assertion matters: it failed on MySQL for
declaring an exception that engine did not need.

**And T-02's production survey found a gap in it.** Every real template writes
`age_buckets: "30;60;90;180"` — the string form — and the corpus only ever asked for the
Array form, leaving the parsing branch every caller goes through unfrozen. Two cases were
added, with an assertion that the two spellings answer identically. An oracle is only as
good as its question list, and the question list is worth checking against what the
templates actually do.

That is the oracle earning its keep three times in one day: on an engine CI had been
reporting green for months, on the write-up of its own finding, and on its own coverage.

## The baseline is not an oracle

`performance/baseline.json` is the one file here a failing comparison must **not** be read
off. There is no committed tolerance — `functional-spec.md` §R7 says the tolerance is a
curator decision and marks the numeric target as a `[GAP]` — so a red/green verdict on a
millisecond figure would be a number this project invented, on a runner whose CPU it does
not control. The benchmark prints its drift against the committed artefact labelled
**ADVISORY — non-deterministic — not a correctness guarantee**, per `CLAUDE.md` §7.

The numbers show why. Two consecutive runs of the identical matrix on the identical machine,
minutes apart, moved p95 by up to **×1.26**, and one cell was reported *invalid* in the first
run and valid in the second. Any relative tolerance tighter than about 30% would be red on a
quiet machine's bad minute. The three *absolute* criteria below are exact integers and cannot
be noisy, which is why they are the ones that assert.

What *is* asserted, hard, on every engine on every adapter run — `performance_invariants_spec.rb`:

| Criterion | How |
|---|---|
| query count independent of issue count (FR-48) | the same count at 100 and at 10 000 issues, per workload |
| no per-row or per-bucket query hiding under that | a **measured** per-workload budget, as a `<=` ratchet |
| zero issue-object instantiation | `record_count` summed over `instantiation.active_record` for `Issue`, required 0 |
| bounded output regardless of input | the capped axes at their bound; the pareto axis returns the same bucket count at both sizes, and its collapsed total still equals the issue count |
| the measurement measures what it claims | the size of every workload's answer, pinned |

That last row is not one of R7's criteria and the baseline is worthless without it. Every
entry point **logs and degrades** on an argument it cannot use, so a workload can quietly
answer a smaller question, get faster, and read as an improvement. It happened here:
`completeness.seven` asked for two field names the kernel does not accept and measured a
five-field panel under a seven-field name.

And what is **not** measured is written down as not measured: all 12 (reference template ×
issue count × HTML|PDF) cells are recorded as `blocked`, each naming **T-10**, because the
only Liquid renderer today belongs to a separate private plugin and no PDF engine is
reachable. A DB-less spec asserts they are still declared blocked, so the day the render
path lands, the gap is in front of whoever runs the suite rather than absent from it.
