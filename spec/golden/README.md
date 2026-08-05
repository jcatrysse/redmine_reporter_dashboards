# The golden oracle (T-01)

Everything here exists to answer one question during the decoupling sequence: **did the
numbers change?** The aggregation kernel is being lifted out of one plugin and re-seamed
into another, and the only honest way to do that is to write down what it answers today
and keep comparing.

Nothing in this directory tests the plugin's behaviour. It tests that the behaviour has
not moved.

## What is here

| Artefact | What it freezes | Regenerable? |
|---|---|---|
| `baseline.rb` | the commit the kernel is diffed against for gate G7 | it is a SHA |
| `reference_date.rb` | the pinned date the corpus is generated with, and the refusal to run unpinned | n/a |
| `corpus_canonicaliser.rb` | one result → one byte sequence (`technical-spec.md` §2 Step 0) | n/a |
| `corpus_cases.rb` | **the questions**: 174 (entry point, scope, actor, arguments) tuples | n/a |
| `aggregation/values.jsonl` | **the answers**, one canonical JSON record per case | yes, from the baseline commit |
| `aggregation/manifest.json` | provenance: baseline commit, reference date, zone, engine, digests | yes |
| `aggregation/overlay/*.jsonl` | the per-engine exceptions the overlay declares | yes |
| `adapter_overlay.rb` | which cases may differ per engine, why, and how many may exist | n/a |
| `scope/scope.jsonl` | **the irrecoverable one**: what `ScopeResolution` resolves, per (template, query, actor) | **no** |
| `sql/scope_sql.jsonl` | the SQL those scopes generate, tokenised | yes |

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
```

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

**Defect D-1** — `group_by: age` collapses into the `(none)` bucket on **MariaDB**
whenever the generated `CASE` passes 256 characters, which four age boundaries do, which
is the default. Documented in the README's database section, asserted on every engine in
`spec/adapter/query_aggregator_execution_spec.rb` (MariaDB's branch pins the defect, the
others pin the correct answer), and carried as the overlay's only two entries. Not fixed
here: gate G7 freezes the kernel byte-for-byte, and §1's ordering guard refuses a change
to the aggregator until T-03 has measured the performance baseline against it.

**And the corpus corrected itself.** D-1 was first written up as affecting the whole
MySQL family, on the evidence of one engine. The first CI run measured MySQL 8.0.46
answering correctly and refuted it — which is why `mysql` and `mariadb` are now separate
overlay families, and why the exhaustiveness assertion matters: it failed on MySQL for
declaring an exception that engine did not need.

That is the oracle earning its keep twice in one day: once on an engine CI had been
reporting green for months, and once on the write-up of its own finding.
