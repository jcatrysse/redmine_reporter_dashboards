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

**And it has a SECOND symptom that does not look like an encoding bug at all.** Hit
again in T-14: `Preflight` interpolated `File.read(chart_shell.js)` into a UTF-8 heredoc
and got `Encoding::CompatibilityError: incompatible character encodings: UTF-8 and
US-ASCII` — a different exception class, from a line that does no reading. **The same
applies to subprocess output**: `Open3.capture3` tags stdout with the default external
encoding too, so `pdftotext` output on a POSIX-locale host is US-ASCII and the first
accented character in a French document turns a regexp match into `ArgumentError`.
`PdfInspector.run` force-encodes to UTF-8 for exactly that reason. Rule: anything
crossing into this process from a file or a pipe gets its encoding named.

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
wrong. This was defect D-1 (`implementation-plan.md` §Findings), and the COUNTING path is
**fixed** — `measure_groups` reads a counted axis positionally (`SELECT <expr>, COUNT(...)
... GROUP BY <expr>` through `pluck`) instead of through ActiveRecord's alias-keyed
`.count`. **The trap is not fixed for anything that still uses `.count`/`.sum`/`.average`
on a grouped relation**, which is every `measure:` — those key their results by the same
alias, and are still exposed past ~4 age boundaries. Deliberate, and in the README's
database section.

Note that shortening or aliasing the expression does NOT save you: the alias is derived
from the expression's text and is ALREADY truncated on PostgreSQL, which answers
correctly. The defect is the two ends *disagreeing* about the truncation, not the length.
**MySQL 8.0 does NOT do this** — it was written up as a MySQL-family defect and the first
CI run refuted that, which is why the overlay has a `mariadb` family separate from
`mysql`. That family survives the fix; the reason it exists is a property of the engines.

**Do NOT "fix" a long group expression by replacing the GROUP BY with one conditional
aggregate per bucket.** That was D-1's first attempt: it is correct, it removes the alias,
and it is dramatically SLOWER on MariaDB — the engine the defect is on. Measured in the
same CI job: `completeness.seven` (seven `COUNT(DISTINCT CASE …)` in one statement) costs
**25-50 s per call** at 10 000 issues where the grouped read costs **0.02 s**, and the
`adapter (MariaDB 11)` cell went from 5 m 39 s to over 35 minutes without finishing.
Query COUNT is identical either way, which is the only thing R7 measures — so **no gate in
this project can catch it**. Read the CI cell's wall clock.

**`|| true` on a search inside a gate cannot tell "clean" from "did not run", and one
of them is a lie.** Written fresh on 2026-08-05 while building `layer_purity.sh`: the
first version used `rg -nE "$pattern" "$path" || true`. **In ripgrep `-E` is
`--encoding`, not "extended regex"** — rg is always a regex matcher — so it exited 2
with `unknown encoding: Rails\.|ActiveRecord|...`, `|| true` swallowed the crash, and
the gate reported every layer clean. A deliberately planted `Issue.visible` in
`render/` went undetected. It was caught only because the gate was negative-tested
before it was wired up; nothing else would have found it, because the gate's normal
output looked perfect.

Two rules follow. **Negative-test a gate before trusting it** — plant the violation it
exists to catch and watch it fail. And in a gate, treat a search's exit status as
three-valued: 0 = matches, 1 = no matches, **anything else = the tool failed and the
gate knows nothing**, which must be loud. `layer_purity.sh`'s `search()` does this.
`no_thread_local.sh` and `zero_reporter.sh` still use `|| true`; their rg invocations
are valid so they do not fail today, but the hazard is the same shape and is worth
closing the next time either is touched.

**A LINT THAT LOCATES `<script>` WILL FIND ONE IN PROSE, and then it is confidently wrong
about hundreds of lines.** Cost T-19 two rounds (§Findings E-14). `HtmlScanner` skipped the
`{% comment %}` tag but not its BODY, so a comment explaining why chart data must not be
concatenated — prose containing the word `<script>` — opened a raw-text region running to the
next real `</script>`: **72 escaping findings in a template that had none.** And linting
`README.md` as one document produced **23 findings in Markdown**, because the sentence
describing the rule contains a backticked `` `<script>` ``.

Two rules follow. The scanner skips `{% comment %}` and `{% raw %}` bodies (also the correct
semantics — one is not rendered, the other is rendered literally). And **a README is linted
per fenced snippet, never as a document** — prose talks ABOUT tags and no scanner can tell
that from markup. Neither bug was findable by reading the scanner; both were found by
pointing it at real files and disbelieving the count.

**Every name `Liquid::Drop` uses is reserved on every subclass, and two of them have now cost a
session each.** `key?` (E-8) made every accessor on `NamedRefDrop` render EMPTY, because Liquid's
`VariableLookup` asks `respond_to?(:key?)` to decide whether a value is hash-like. `@context`
(E-12) is worse, because it is an IVAR rather than a method: `Liquid::Drop` declares
`attr_writer :context` and assigns it on every touch, so a drop storing its own object there both
loses it mid-render and breaks Liquid's `strict_variables` check. The symptom was
`NoMethodError: undefined method 'actor' for an instance of Liquid::Context`, raised from the
timezone helper — three frames from the cause, and reading like a bug in the wrong file. The
reserved set is `@context`, `key?`, `invoke_drop`, `[]`, `to_liquid`, `liquid_method_missing`, and
`context=`. Neither of these is findable by reading; both were found by rendering a real template.

**A relation is not the same object twice, and `equal?` on one is a cap that silently does not
apply.** `IssueQuery#base_scope` builds a fresh `ActiveRecord::Relation` every call.
`RenderContext#batch_for` compared with `equal?`, so a caller that passed one relation to the
context and another to the collection drop got a SECOND `Batch` — with the default 5 000 cap
instead of the configured one, and duplicate queries for every key. Nothing raised. Compare by
`to_sql` (E-13). The test only caught it because it deliberately built the two relations
separately; write cap tests that way.

**Ruby's `IO.pipe` hands the CHILD a non-blocking descriptor, and Chromium hangs up on it.**
`O_NONBLOCK` lives on the open file description, so a child inherits it — and Chromium's
`--remote-debugging-pipe` reader treats the resulting `EAGAIN` as a closed connection. It answers
**exactly one command**, logs "Connection terminated while reading from pipe", and exits. The
symptom is a browser that replies to `Browser.getVersion` and dies on whatever you send second,
which reads as a CDP protocol error, a version incompatibility, or a message-framing bug — it is
none of those. Clear the flag on both child-facing ends before `Process.spawn`
(`CdpClient#blocking!`). Cost: about an hour, most of it spent suspecting the protocol.

**Chromium will not run as root, and that is the design working.** `--no-sandbox` is deliberately
never set, so the browser itself enforces "render as a non-root user". In this container you ARE
root, so the conformance corpus and anything else that draws a PDF has to be run as somebody else:

    useradd -m rrd && chmod -R a+rX . && su rrd -s /bin/bash -c '… rspec spec/conformance'

Two consequences worth knowing before you lose ten minutes to each. The repository must be
world-readable (`chmod -R a+rX`) or the run fails on a file it cannot open, and **`RRD_MATRIX_WRITE=1`
needs `docs/` writable by that user** — otherwise the matrix regeneration fails with `EACCES` from
inside an rspec example, which reads as a spec bug.

**The conformance harness needs poppler, and says so rather than skipping.** `pdfinfo`,
`pdftotext` and `pdftoppm` (`apt-get install -y poppler-utils`). A missing probe is an ERROR: a
matrix generated without them would still print PASS for every check that never ran.

**A poppler-less run is a DIFFERENT run, and the four `rspec` CI jobs are one.** Two preflight
examples passed locally and failed on all four branches because they inherited whether poppler
happened to be on PATH. Reproduce the CI environment before pushing:

    env PATH="$(python3 -c "import os;print(os.pathsep.join(d for d in os.environ['PATH'].split(os.pathsep) if not os.path.exists(os.path.join(d,'pdfinfo'))))")" \
      ruby -e "require 'rspec/core'; exit RSpec::Core::Runner.run(['spec/render','-I','spec'])"

The rule is CLAUDE.md §6: an example about a check's *reasoning* stubs `PdfInspector.available?`
rather than inheriting it. Only examples that genuinely need real probes may skip on their absence.

**wkhtmltopdf cannot be installed here.** Its package is gone from Ubuntu 24.04's archive and only
exists as a release `.deb`. So `:wkhtmltopdf` is CI-only, exactly like MariaDB and MySQL, and its
`verification: pending` in `config/capabilities.yml` is what keeps twenty unmeasured cells out of
the support matrix. **Promote it in the commit that reads a green CI run, not before.**

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
`lib/redmine_reporter_dashboards/compat/base_record.rb`, and this correction did not explain
it — it only showed the stated mechanism could not be it. **T-10 reproduced it cleanly on
2026-08-05 and it is REAL:** `render/result.rb` defined only `Success` and `Degradation`, and
the full application refused to boot with

    expected file .../render/result.rb to define constant
    RedmineReporterDashboards::Render::Result, but didn't (Zeitwerk::NameError)

So **path-to-constant agreement IS enforced for this plugin's `lib/`**, whatever the three
`false` measurements above say about autoload paths — they were taken from inside a booted
app and evidently do not describe what Zeitwerk scans at boot. Do not resolve the
contradiction by trusting either half: **name every file under `lib/` after the constant it
defines** and the question never arises. `compat.rb` is one file for this reason, and
`result.rb` now defines a `Result` module as well as the two classes.

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
  D-1's first attempt hit this: it made *"keeps counts for a value outside the expected
  bucket list"* unreachable and needed 11 unit examples rewritten. **The fix that actually
  landed needed none of that** — it still folds whatever keys the database returned, so
  that example survives untouched. Worth remembering as a design smell: when a change
  forces you to delete assertions about defensive behaviour, ask whether a smaller change
  gets the same correctness. Here one did.

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
| **Redmine 6.1-stable, standalone, PostgreSQL 16 — after D-1's fix** | **yes, locally (2026-08-05)** | 1127 rspec + 156 adapter + 217 corpus + 139 minitest, **0 failures**. Plus `spec/golden` from the PLUGIN CHECKOUT (where gate G7 has its git history): 0 pending. The corpus is byte-identical to before the fix — all 176 recorded values unchanged |
| **D-1's FIRST attempt, on MariaDB (CI run 31034989145)** | **YES, and it is why that attempt was replaced** | `corpus (MariaDB 11)` **green** — the fix was correct, and the overlay was rightly emptied. `adapter (MariaDB 11)` ran **over 35 minutes without finishing** against 5 m 39 s before it: the conditional-aggregate shape is pathologically slow on MariaDB at 10 000 issues. Correctness confirmed, performance refuted, in the same run |
| **D-1's fix on MariaDB (CI run 31036305443)** | **YES — 17 of 17 jobs green** | `adapter (MariaDB 11)` green in **4 m 16 s** of specs against **5 m 39 s** before the fix, and `corpus (MariaDB 11)` green with the overlay EMPTY and its exhaustiveness assertion live. Correctness AND performance confirmed on the engine the defect lives on. **The wall clock is half the measurement here** — the first attempt was green on the corpus too |
| Redmine 6.1-stable, standalone, **MariaDB 10.11** | **yes, locally** | 313 adapter+corpus, 0 failures. **The run that found defect D-1** |
| Redmine 6.1-stable, standalone, **MySQL 8.0.46** | **yes, locally** | 97 adapter + 214 corpus, 0 failures (before the last two cases were added). **The run that refuted D-1's scope** and exposed E-1 |
| **T-12/T-13: the engine conformance corpus, Chromium 141** | **yes, locally (2026-08-06)** | 20 of 20 fixtures pass — geometry, orientation+margins, footer tokens, page breaks, backgrounds, flexbox, the readiness six, inline assets, egress denial, typed refusal, a 2 000-row envelope, fonts, pathological input and the escaping payload set. Run as a **non-root user**, sandbox on, `--no-sandbox` never passed. **It found three defects on its first run** (§Findings E-2, E-3, E-4) |
| **T-12/T-13 DB-less half** | **yes, locally (2026-08-06)** | 155 examples green as root with no browser (45 pending), and 155 green as `rrd` with Chromium (22 pending — wkhtmltopdf, skipping with its reason). Includes the harness's own negative tests and 30 browser-less adapter examples |
| **`:wkhtmltopdf`** | **YES, once, in CI (run 31059574558)** | 13 of 20. Not installable here at all — the package is gone from Ubuntu 24.04 — so CI is the only place it runs, like MariaDB and MySQL. Four failures were fixture bugs (fixed), one was a real egress defect (fixed), **two are a curator decision** and are §Findings E-5. It stays `verification: pending`, which now means its results are REPORTED AND NOT ENFORCED, and the matrix carries no cells for it |
| **T-14: the render preflight, BOTH engines, in CI (run 31079493206)** | **YES** | **chromium_cdp 9/9 in 465 ms and wkhtmltopdf 9/9 in 380 ms**, both with the hosted image `EXPECTED_FAILURE` — INV-8 containment confirmed on two independent engines. This is the first time wkhtmltopdf has drawn the probe at all. It is **not** an argument for promoting it: `verification: corpus` is about T-12's twenty fixtures and E-5's two open curator items, and neither moved |
| **T-14: the render preflight, Chromium 141** | **yes, locally (2026-08-06)** | 9 of 9 checks pass in **943 ms**, run as the non-root user (see the Chromium note in §1): page breaks → 2 pages, `Page 1 of 2` compiled, page rgb[0,170,255] and badge rgb[204,0,0], the inline data: image decoding to its own colour, `CANVAS-STATE drawn`, `SHELL present`, and the Redmine-hosted image `EXPECTED_FAILURE` — INV-8 containment confirmed against a real browser rather than argued. **The first run took 17.5 s and was red**; the three defects it found were all in the diagnostic, not the engine (§Findings E-10) |
| **T-14 DB-less half** | **yes, locally (2026-08-06)** | 41 examples green with no browser (`spec/render/preflight_spec.rb`, `preflight_command_spec.rb`), including every one of the six document checks driven RED against a canned single-page PDF. `spec/render` + `spec/conformance` together: 205 examples, 0 failures, 49 pending. The Minitest half (`test/functional/reporter_preflight_controller_test.rb`, `test/unit/render_preflight_rake_test.rb`) **has not been executed** — it needs a booted Redmine, so the `standalone` CI job is its first run |
| **T-18: the drop layer, Liquid 4.0.4 AND 5.13.0** | **yes, locally (2026-08-06)** | 185 examples green under each major, run the way CI runs them (`rspec -r /tmp/pin.rb spec_liquid`). Includes the substitutability battery against `VersionDrop` as well as `NamedRefDrop`, and both E-8 gaps pinned as they are |
| **T-18: the gating performance criteria, PostgreSQL 16** | **yes, locally (2026-08-06)** | 31 adapter examples, 0 failures. Zero `Issue` instantiations at 10 and 10 000; one query for `size` at both; a custom field across 400 issues in 4 queries and a second for free; the cap AT and one past. The full adapter suite is **187 examples, 0 failures** with the harness's new `attachments` table and `Issue.visible`/`TimeEntry.visible` scopes, and the **corpus is unmoved — 217 examples, all 176 recorded values identical** |
| **T-18 in CI (run 31085742725)** | **YES — 18 of 18 green, first try** | Both things the local run could not answer are answered. `adapter (MySQL 8.0)` and `adapter (MariaDB 11)` green, so the batch's four visibility-filtered queries behave on all three engines. **All four `minitest` branches green** — 5.1, 6.0, 6.1 and 7.0 — which is the real answer to the Zeitwerk question in §1: `liquid/drops/` boots on every supported Redmine. All three `corpus` jobs green, so G7 holds across the harness change |
| **T-19: the filters and the lint, Liquid 4.0.4 AND 5.13.0** | **yes, locally (2026-08-06)** | 276 examples green under each major. Includes the `StandardFilters` enumeration (49 names on 4.0.4, 61 on 5.13.0, pinned per version), the 21-filter inventory, and the OQ-C measurement that closed it |
| **T-19: the escaping regression table, node v22** | **yes, locally (2026-08-06)** | 43 examples. 18 payloads through `| json`, each asserted to PARSE and to round-trip byte-for-byte; the OLD idiom pinned as measured — SyntaxError on a backslash terminator, and no payload reaching code position. **One assertion in it was wrong on the first run** and is now written from what the output actually is: the combined payload PARSES, because `| escape` turns its quotes into `&#39;` and `\&` is an identity escape. Two payload shapes, two outcomes |
| **T-19: the shipped copy-paste surface** | **yes, locally (2026-08-06)** | Both examples and all 25 README ```liquid snippets are FR-19-clean; the frozen reference copies asserted STILL defective, because `verification-liquid-js-escaping.md` cites their line numbers. 1433 DB-less examples, 187 adapter, corpus **byte-identical — 217 examples, all 176 values unchanged** |
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
3. **D-1 is FIXED**, in T-08, where the plan said it had to land. A counted axis is read
   positionally instead of through ActiveRecord's alias-keyed grouped `.count`; gate G7
   grew a declared-exception mechanism to express "the blob plus exactly this one argued
   hunk" (`spec/golden/kernel_exception.rb`); the per-adapter overlay is empty again with
   `RATCHET = 0`. **CI run 31036305443 is 17/17 green**, `adapter (MariaDB 11)` included and
   in 4 m 16 s against 5 m 39 s before the fix — so D-1 is measured fixed on the engine it
   lives on, not merely argued. What is
   still exposed, on purpose: a MEASURED age axis (README, database section). Read the
   §Findings entry before touching it — the first attempt is written up there and the
   reason it was replaced is a performance fact, not a correctness one.
8. **T-21 is done — the multi-actor visibility suite.** `test/unit/multi_actor_visibility_test.rb`,
   in the FULL APP because real `Role#issues_visibility`, a real private issue, a real
   role-restricted custom field and a real `IssueQuery` exist nowhere else. It builds its
   OWN substrate at reserved ids 940_xxx rather than sharing
   `golden_scope_fixture_test.rb`'s — that one is a frozen oracle whose output must not
   move, and the two need different rows. **Mutation-tested**: replacing
   `Issue.visible(User.current)` with `Issue` in its `base_scope` fails 4 of its 13
   tests, so it is load-bearing rather than decorative. Do that again if you change it.
   The trap it exists for is ORDERING: a memoised `User.current` or a cached visibility
   condition gives the second actor in a process the first one's answer, and every
   per-actor assertion still passes because each asserts one actor at a time.
10. **T-11, T-12 and T-13 are done, with one honest gap.** `render/engines/` holds a CDP client, a
   Chromium adapter and a wkhtmltopdf adapter; `spec/conformance/` holds 20 fixtures and the harness
   that applies the three-state rule; `docs/engine-support-matrix.md` is generated from the run and
   gate G9 compares it. **Chromium 141: 20 of 20.** Four things a later session should know.
   **F-7 is closed** — T-11's wall-clock falsifier is `F-13`, 3/3 attempts, and it discriminates
   because its timeout is 20 s rather than the default 10. **The corpus earned its keep on day one**,
   finding a half-built egress control, a footer that printed `Page1of3`, and a registry reset with
   no restore (§Findings E-2, E-3, E-4). **`:wkhtmltopdf` has never been run** and its
   `verification: pending` is load-bearing: promoting it puts twenty unmeasured cells in the matrix,
   which is INV-7's exact sin. And **the browser must not run as root** — see §1; that is the
   sandbox working, not an obstacle to route around with `--no-sandbox`.
   Next after T-13 was **T-14**, now done — see entry 11. **T-15** (render-path containment) is
   partly done and blocked on an entry point (§Findings E-6). **T-33** (the asset-resolution triple)
   depends on T-12 and is likewise open.

13. **T-19 is done — the owned filters and the FR-19 lint.** `liquid/filters.rb` plus six
   registered modules, `liquid/html_scanner.rb`, four new lint rules, and the examples and
   README actually fixed. Five things a later session should know.

   **REGISTRATION IS THE POINT, not the filter list.** `Filters.modules` is the DEFAULT of
   `TemplateRenderer#render`, and nothing anywhere calls `Template.register_filter` —
   `single_parse.sh` fails on one. The gem registers four modules globally at require time
   and monkey-patches `to_number` into `StandardFilters`; a spec asserts both are absent,
   because that is a property of the whole process and no care inside this plugin would
   restore it.

   **OQ-C IS CLOSED BY MEASUREMENT.** `where` and `sort_natural` are INHERITED — identical
   on both majors and already working on the drops, because Liquid's `where` reads through
   `Drop#[]`. `sum` is OWNED, because only Liquid 5 has one and a plugin supporting both
   majors cannot leave that divergence in place; it reproduces Liquid 5's semantics
   exactly, which is why it differs from its four neighbours on how it treats non-numbers.
   **The `StandardFilters` list is pinned per version and an unpinned Liquid FAILS** — that
   is the whole mechanism, and Liquid 5 added twelve filters since 4.0.4 without anybody
   choosing them.

   **`Support.read` GOES THROUGH `Drop#[]` AND NOTHING ELSE.** Never `send`, never
   `public_send`. §3.6 removes the gem's `call_method` as "the sharpest single instance of
   INV-9", and a filter resolving a property with `public_send` would reintroduce it one
   property name at a time — `avg: "estimated_hours"` and `avg: "destroy"` are the same
   call. A spec asserts the drop is never sent to.

   **THE LINT PARSES, AND ITS SPEC IS THE ARGUMENT.** See the trap in §1: the scanner cost
   two rounds. Every example in `spec/html_scanner_spec.rb` is a case the regexp it replaced
   got wrong, and the two hardest were prose mentioning `<script>`.

   **WHAT IS DEFERRED, AND WHAT IS HELD AT A RATCHET.** `| inline` is **F-10** and belongs to
   T-33 (`asset_policy`). The examples' Chart.js 2 idioms and `window.status` handshake are
   **not** fixed — they belong to T-16 and T-11, which rewrite that code — so
   `spec/shipped_templates_lint_spec.rb` pins FR-19 at ZERO and the rest at a per-file
   ratchet. Lower those numbers when their owner lands; never raise one.

12. **T-18 is done — the owned drop layer.** `liquid/drops/` (12 classes + 3 bases),
   `liquid/batch.rb`, `liquid/diagnostics.rb`, and `RenderContext` grown a `batch`, a
   `diagnostics` and a `budget`. Five things a later session should know.

   **THE SPECS ARE SPLIT IN TWO ON PURPOSE, and neither can answer the other's question.**
   `spec_liquid/drops_spec.rb` + `collection_drop_spec.rb` render REAL templates against fake
   records — that is where the disposition table, the drop protocol and the two Liquid majors are
   proven. `spec/adapter/drop_performance_spec.rb` drives the drops DIRECTLY with no template —
   that is where the SQL is. The adapter half cannot render a template: `adapter_helper.rb`
   requires `spec_helper.rb`, which defines the Liquid stub, and the stub and the real gem cannot
   share a process (E-7). Pulling the gem in there would break 200+ tag examples in `rspec spec`.
   Do not "unify" these two files.

   **VISIBILITY LIVES IN `Batch`, NOT IN THE DROPS**, and a reviewer should check that first. Four
   of the six keys read tables with their own rules, so the actor is a REQUIRED constructor
   argument. The case that matters is the auditor: they hold ROLE_MANAGER in a DIFFERENT project,
   so `CustomField.visible` resolves the restricted field for them and only Redmine's per-project
   `visible_by?` refuses it. Without that second call the leak passes for everyone holding the role
   anywhere — and a values-only assertion would not see it, which is why the spec asserts the
   field's NAME is absent too.

   **`total_spent_hours` short-circuits on a LEAF, and that is load-bearing.** The batch answers
   own-hours; the total is self-plus-descendants, so for a leaf the two are the same number and the
   batched value answers with no query. Only a parent pays. `leaf?` is `rgt - lft == 1` on the row
   already loaded, and it is `respond_to?`-guarded because the adapter harness's Issue has no
   nested-set columns.

   **THE CAP IS THE MEMORY BOUND AND `find_each` IS NOT.** Liquid's `{% for %}` calls
   `Utils.slice_collection_using_each`, which collects the WHOLE segment into an Array before
   rendering one iteration. Batching bounds the database result set and the preload working set,
   not the peak memory of the render. Also: an ORDERED scope is deliberately NOT walked with
   `find_each` — that forces primary-key order and silently discards the author's, which renders a
   report in the wrong sequence with nothing to say so.

   **What T-18 did NOT do, deliberately:** nothing constructs a drop yet. There is no producer,
   exactly as `RenderContext`'s own comment says of T-07 — T-19 (filters), T-20 (retiring the two
   compensating tags) and T-23 are what wire them in. The `liquid/{version,custom_field_value}_drop.rb`
   and `issue_drop_patch.rb` files in the OLD location are still live for installs with the host
   plugin; T-20 deletes them. The two questions it raised are ANSWERED (2026-08-06): **F-8** is
   closed — `UserDrop#mail` stays absent, and note the scope, because the name invites the wrong
   one: it is only about printing an address inside a template body, not about §7b.5's mail
   sending, which resolves Redmine users server-side and reads `User#mail` on the model. **F-9** is
   deferred to real-template testing, with `Drops::CLASSES` holding the inventory until then.

11. **T-14 is done — the render preflight, in three places that share one implementation.**
   `render/preflight.rb` builds the probe document and the checks, `render/pdf_inspector.rb` reads
   the PDF back, `render/preflight_command.rb` owns the exit codes; the rake task and
   `ReporterPreflightController` are glue over them. Four things a later session should know.

   **`spec/conformance/pdf_probe.rb` is now a POLICY over `PdfInspector`, not an implementation.**
   The one thing it still decides is the one thing the two callers genuinely disagree about: a
   missing poppler is a hard ERROR for the corpus (a matrix generated without the probes prints PASS
   for checks that never ran) and a named SKIP for an operator (it is an optional package). Keep new
   reading code in `PdfInspector`; keep policy in its caller. The harness spec plants a missing tool
   by stubbing `PdfProbe.missing_tools`, so `PdfProbe.require_tools!` must keep consulting its OWN
   `missing_tools` rather than reaching past it.

   **`:skip` does not make the run red, and `complete?` is why that is honest.** `ok?` means nothing
   failed; `complete?` means nothing was left unanswered; the headline never prints a bare "OK" when
   a check was skipped, and the exit code is 0/1/2 with **2 = no engine registered, so nothing was
   verified** — deliberately not 0. If you add a check, add its id to
   `ReporterPreflightHelper::CHECK_LABELS` and to all nine locale files, or a Russian UI silently
   renders the English title.

   **The probe document inlines the SHIPPED `chart_shell.js`, in `<head>`.** Not a copy of it, and
   not at the end of the body: the hosted-image probe calls `__rd.begin()`/`end()` inline so the
   document stays open until that fetch resolves, which is what makes `HOSTED-IMAGE blocked` a fact
   rather than a race. Without the shell the probe waited out the full watchdog — 17.5 s and a
   spurious `readiness_timeout` — which is §Findings E-10's first defect.

   **The probe's GEOMETRY is load-bearing too, and it fooled me once.** Anything the pixel checks
   sample must be `position: absolute` with a percentage top/height, like `.badge` and `.plate` —
   never in normal flow. A flow-positioned element lands wherever the engine's default margins put
   it, so a red pixel check cannot be told apart from a layout difference. That cost a CI round and
   very nearly put a false sentence about wkhtmltopdf into the support matrix (§Findings E-11):
   it decodes inline `data:` images perfectly, and my plate was 4mm off.

   **The probe's colours are load-bearing, and one of them was wrong.** `PROBE_PNG` must be a
   colour that appears NOWHERE else in the document. It was `#00aaff`, the page background, and
   the `inline_asset` check therefore passed whether or not the image decoded — the `<img>` has a
   fixed height, so the page showed through. If you change either `PROBE_PNG` or
   `body { background }`, check they still differ; a spec asserts it, because nothing else can.

   **A check that cannot run is emitted, never omitted.** `DOCUMENT_CHECKS` drives both the run
   path and the poppler-missing skip path so the report has ONE shape. The first version returned
   early with an umbrella skip and silently dropped the INV-8 containment check; two installs' JSON
   were also not comparable. Add a check to that table, not to the array.

   **`degradations` is not "any degradation is a defect".** wkhtmltopdf stamps `legacy_engine` on
   every render by design, and the blocked hosted image produces `asset_unresolved` — the one the
   probe deliberately provokes. Both are expected, both are still printed. Only the asset one is
   conditional: with no Redmine base URL, an unresolved asset IS a defect.

   **The Minitest half had never run when it was written.** `test/functional/reporter_preflight_controller_test.rb`
   and `test/unit/render_preflight_rake_test.rb` need a booted Redmine, so the `standalone` CI job
   is their first execution — it went green on all four branches on the first try. Local
   verification of anything in `app/` stops at `ruby -c` plus an ERB compile; note that plain ERB
   mis-parses `<%= form_tag … do %>` where Rails does not, so a bare `ERB.new(...).src` syntax check
   reports a false failure on any view with a block helper.

9. **T-10 is done — `render/` exists and `layer_purity` is STRICT.** The document-request
   interface only: types, a sum type, and the wrapper that makes INV-5 mechanical.
   Nothing renders yet. Two things a later session should know. **`DocumentRequest`'s
   security property is its SHAPE** — the spec asserts against the constructor's
   parameter list that no `cookies:`/`headers:`/`auth:`/`url:` exists, so adding any
   general-purpose escape hatch fails a test rather than passing review; read the file
   comment before you add a field. And **`Renderer` is where INV-5 stops being a rule** —
   it rewrites any adapter's output that is not `%PDF-`…`%%EOF` or is under
   MIN_PDF_BYTES, so no adapter can breach it by accident. Its documented LIMIT is next
   to the check: the byte test kills "exception as document" and says nothing about a
   VALID PDF whose content is wrong. Do not let it stand in for the whole invariant.
   **P-2's second premise is now half false** — Chromium 141 IS in this container, so
   T-11/T-13 can be exercised rather than written blind. A local Chromium is still not a
   CI-verified engine; that is T-12's job, and the `render-smoke` job it added is where
   that becomes true. **Both were exercised, 2026-08-06** — see entry 10.
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
   byte-identity; `query_aggregator.rb` declares ONE, D-1's.
7. **T-09 is done, and the status table used to say the opposite in both directions.**
   The secret, the probe job and the private checkout went earlier; this session added
   the two gates its `Accept:` list still named — `layer_purity.sh` (E3, internal
   layering) and `compat_size.sh` (E4, version divergence) — and moved the one scattered
   `Redmine::VERSION` out of a helper into `Compat`. **`layer_purity` runs in warn mode
   because `render/` does not exist until T-10, and it reports an absent layer on its own
   line rather than passing over it: T-10 should flip it to
   `LAYER_PURITY_MODE=strict` in the same PR that creates `render/`.** Two things stay
   open and are findings, not work: **F-4** (nobody has committed a `compat/` LOC number,
   and CLAUDE.md claims one exists) and **F-5** (the dated fork-PR run, which no job can
   produce). **Next: T-10**, which also owes T-03's blocked HTML|PDF baseline (P-2). **There is no writer for
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
