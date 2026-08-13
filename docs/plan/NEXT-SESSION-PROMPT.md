# Prompt for the next session

Copy everything below the line into a fresh session.

---

Work on `jcatrysse/redmine_reporter_dashboards`, on the branch
**`claude/plugin-repo-docs-setup-8u9k17`**, which is the integration branch this project
actually works in. Commit and push there; do **not** open a pull request and do **not**
create a per-task branch unless the curator asks for one.

Read `CLAUDE.md` first, then `docs/plan/HANDOVER.md` §1 (traps) and §3 (environment) — both
record traps that produce a green run meaning nothing. Then read this brief twice.

**Your task is T-38 · One stylesheet, two outputs.** Its `Accept:` list is in
`docs/plan/implementation-plan.md`. T-37 is the task after it and there is a section on it
below, because its shape changed and the next session should not re-derive that.

## Where the work stands

**36 of 38 tasks are done.** T-26a landed across four increments and **the plugin no longer
needs `redmine_reporter` for anything a user touches**: both report widgets on the project
dashboard, both on my-page, the PDF export, and the migration that repoints existing
dashboards. What remains is **T-38**, **T-37**, **T-27** (blocked), the T-26 remainder
(**S-30**, below) and T-03's twelve render performance cells, which the curator said to leave.

Verified at HEAD, on Redmine **7.0-stable** with **PostgreSQL 16**, standalone (no
`redmine_reporter`, no `redmineup` gem):

    minitest            985 runs, 4691 assertions, 0 failures, 0 errors, 4 skips
    rspec               2672 examples, 0 failures, 175 pending
    rspec spec/golden   167 examples, 0 failures, 0 pending   <- G7 RAN
    adapter             254 examples, 0 failures, 9 pending (RRD_ADAPTER_URL, real PG 16)
    nine argument-free gates rc=0, .codex/check_ruby_floor.sh rc=0

**CI has not been read for these commits.** The curator believes it is green; confirm before
claiming any Redmine other than 7.0 or any engine other than PostgreSQL. That is INV-7 and it
is this project's oldest broken promise.

## THE CURATOR'S ENVIRONMENT, AND ONE COMMITMENT IT CREATES

Redmine **7.0**, currently **PostgreSQL**, and **MariaDB before go-live**. That last part was
decided this session and it turns one open defect into a release blocker rather than a
curiosity:

**`group_by: age` with `measure: sum | avg | distinct` is still wrong on MariaDB past about
four boundaries** (README, database section; plain counts are correct at any boundary count,
and nothing 500s). It is D-1's alias-truncation defect, fixed for the COUNTING path in T-08
and not for the three grouped calculations that still go through ActiveRecord's
`.sum`/`.average`/`.count`. The fix is to give them `grouped_counts`' positional shape.
**Do not start it without asking** — it is not T-38 — but it must not be forgotten either.

## S-30 — the one piece of T-26 still owed, and it is bigger than it looks

`glue/legacy/scope_resolution.rb` was authorised for deletion by the curator, attempted, and
**reverted on a measurement**. Read §Findings **S-30** before touching it.

The production argument is sound: after T-26a nothing constructs a render without an owned
`RenderContext`, so `ScopeBinding#bind`'s legacy branch is unreachable. What the plan never
recorded is that **the DB-less tag suite uses that path as its harness** —
`spec/sql_aggregation/liquid_aggregate_tag_spec.rb` builds contexts with the
`sql_issue_query`, `container` and `controller` registers, an `issues` drop assign, a
`@sql_base_scope` ivar and a thread-local, which are the six sources that module resolves.
Removing the branch is **166 of 249 examples red**, and most of them cannot be ported because
the behaviour genuinely stops existing.

Its shape, if a later session takes it: rewrite the two tag specs onto `RenderContext`, delete
the six-source examples with an argued list of what coverage went, then delete `glue/`,
`#legacy_bind`, `LegacyHost`, `test/unit/golden_scope_fixture_test.rb` (it `include`s the
module, so deletion is a LOAD failure taking all twelve of its methods) and the
`no_thread_local` exemptions. **`spec/golden/scope/scope.jsonl` must survive whatever happens
to its subject** — it is the one artefact in this repository that cannot be regenerated.

## What T-38 has to do, and what already exists to build on

Its `Accept:` list, with what is already in the tree beside each clause:

| Clause | What exists now |
|---|---|
| one print-first stylesheet and one type scale used by the HTML view **and** the PDF body | `assets/stylesheets/redmine_reporter_dashboards.css` is CHROME only (dashboard layout, the sandboxed frame, mermaid states). Nothing styles a report BODY on either binding — that is the gap |
| `thead` repeats across pages in a ≥3-page table fixture | `spec/conformance/` is the harness and `docs/engine-support-matrix.md` is generated from the run (gate G9). A new fixture goes there |
| `break-inside: avoid` for cards and chart blocks | same harness |
| the palette is **read from `ChartLayout`**, not duplicated in CSS — a test asserts a single source | `charts/palette.rb` + `charts/chart_layout.rb`. This is the clause most likely to be got wrong, by writing hex values into the CSS |
| every `SvgRenderer` and Mermaid output carries `<title>`/`<desc>` | `charts/svg_renderer.rb`; `liquid/tags/mermaid_tag.rb`. Mermaid draws in the BROWSER, so this plugin never sees its SVG on the `:html` path — §Findings F-17 |
| a chart whose meaning rests on colour alone fails a lint | `template_linter.rb` + `liquid/html_scanner.rb` are where lint rules live; `spec/shipped_templates_lint_spec.rb` holds the ratchet |
| drill-through links in the PDF are real links, asserted | `charts/svg_renderer.rb` emits `<a xlink:href>` per element; the conformance corpus reads a PDF back with `pdftotext`/`pdfinfo` |

**The corpus needs a real engine, and Chromium refuses to run as root** — HANDOVER §3 has the
`useradd rrd` recipe and the three `RRD_GOTENBERG_*` variables that are no longer optional
since that engine was promoted to `verification: corpus`. Budget for it: two of T-38's clauses
cannot be asserted any other way.

One thing to decide early rather than discover: the report body is rendered inside an
**opaque-origin `srcdoc` iframe** on the HTML binding (`ReportFrame`), whose CSP is
`default-src 'none'; img-src data:; style-src 'unsafe-inline'`. A stylesheet the body needs
therefore cannot be `<link>`ed — it has to be inlined into the document `ReportFrame` builds,
or the CSP has to change. `ReportFrame` is the only place that assembles that document, and it
says so.

## T-37, for the session after — its shape CHANGED

`[OQ-M]` is **closed, measured, answer NO**: there is no pre-built CodeMirror 6 bundle to
vendor. `codemirror@6.0.2` is a meta-package whose `dist/index.js` is a 4,737-byte re-export
shim importing seven bare specifiers; one usable file needs a bundler, which §6 forbids, and
the result would be *our* artefact, so `THIRD_PARTY.md`'s three-independent-origin byte
check could not apply to it. **Curator decision: take the fallback.** T-37 is therefore a
plain `<textarea>` plus a server-rendered lint panel — findings with line and column beside
the editor, **not** in a gutter, and the `Accept:` clause is already reworded to say so.
Nothing is vendored; the CodeMirror line in `Touches:` is void.

The rest of T-37 is unchanged and mostly assembly: the panel is fed by **the same linter
object** the rake task calls (assert both over one fixture and compare the finding lists), the
preview renders HTML **and** PDF and says "preview of N of M", a failed preview shows FR-58's
diagnostics in the editor, the drop reference is generated from the declared surfaces with a
`drop_reference_parity` gate asserting both directions, and the starter gallery's every entry
lints clean and renders on every engine in the matrix.

## Open for the curator

- **`ZERO_REPORTER_MODE=strict` is at 6 files, from 12.** Two are comment-only historical
  records (`positioned.rb`, migration 001) and want a `[permanent]` marker or a reword. Three
  are the detection — and nothing is patched on its answer any more, so its only consumers are
  `init.rb`'s boot log and the one glue require. **That boot line is T-27's upgrade diagnostic
  in embryo**, which is why T-27 is still blocked and why the decision belongs to it. The
  sixth is S-30.
- **MariaDB `group_by: age` with a measure** — above. A release blocker now, by decision.
- **`hu`, `pl`, `zh`** values were written by a model, not a native speaker. The curator's
  answer was "don't care, leave it" — recorded so the next session does not re-raise it.
- **Three accepted CVEs** in the pinned Gotenberg image, review date **2026-09-09**.
- **FR numbering**: the engine-selection screen is cited as FR-50 in nine locale-file headers
  while `functional-spec.md` defines FR-50 as the generated support matrix (§Findings E-29
  row 8).

## How to run things here (learned the hard way — do not rediscover)

- **Set up from scratch** (~8 min, mostly `bundle install`):

      apt-get update && apt-get install -y rsync
      REPORTER_PLUGIN_PATH=/nonexistent ./.codex/redmine_clone.sh 7.0-stable
      REQUIRE_REPORTER_PLUGIN=0 ./.codex/test_setup.sh

- **THE MIRROR TRAP:** `rake`/`rails`/`ruby` run from `redmine/` read
  `redmine/plugins/redmine_reporter_dashboards/`, which is a COPY. Re-mirror before EVERY run:

      rsync -a --delete --exclude redmine/ --exclude .git/ ./ redmine/plugins/redmine_reporter_dashboards/

  Never edit inside the mirror — the clone script destroys it.
- **minitest, whole suite** (~100 s), from `redmine/`:
  `LANG=C.UTF-8 RAILS_ENV=test bundle exec rake redmine:plugins:test NAME=redmine_reporter_dashboards`
  One file: `bundle exec ruby -Itest plugins/redmine_reporter_dashboards/test/...`
- **rspec**, from the PLUGIN root (not from `redmine/`):
  `LANG=C.UTF-8 BUNDLE_GEMFILE=$PWD/redmine/Gemfile bundle exec rspec -I spec spec`
- **THE G7 TRAP:** a suite run from a copy with **no `.git`** silently skips the ten
  `spec/golden` byte-identity examples — gate **G7**. `rspec spec/golden` is **167 examples, 0
  failures, 0 pending**; any pending there means it did not run. A cloud session also starts
  from a shallow clone, which makes those examples FAIL in a way that reads like a real G7
  breach: `git fetch --unshallow origin` is the first thing to try.
- **adapter specs:** `RRD_ADAPTER_URL=postgres://redmine:redmine@127.0.0.1/redmine_adapter_test`
- **PostgreSQL dies in this container, repeatedly.** `service postgresql start`, then
  `pg_isready -h 127.0.0.1`, before concluding anything from a database error. It went down
  three times in one session and each time the first symptom looked like a code defect.
- **Gates:** nine `script/gates/*.sh` take no arguments and all exit 0. There is **no RuboCop**
  in this repo — G3 is "no linter configured for this path", not a pass.
- **The base plugin's source is readable.** `jcatrysse/redmine_reporter` is private but can be
  attached: `add_repo`, then one shallow clone. Several rounds of this project GUESSED at its
  behaviour from this plugin's own overrides and were subtly wrong. Attach it before designing
  against an assumption about it.

## Discipline this project actually enforces

All four CLAUDE.md roles, every task. **Use a fresh subagent for the review and brief it to
REJECT.** In this session it rejected T-26a increment 2 with a blocker that was a real
regression: every SECOND copy of a report widget on a dashboard was dead, because four places
stripped a `__N` instance suffix and the fifth did not.

Four habits that earned their keep, all of them cheap:

- **Mutation-test, and believe a survivor.** 45 mutations over four rounds. Twice a survivor
  was a real coverage gap; twice it was an equivalent mutant and the GUARD was deleted rather
  than kept (T-25's precedent). A guard with no observable effect is a comment.
- **Measure the fixture, do not assume it.** Three tests in one sitting asserted against
  Redmine's own fixtures and were wrong about all three — which projects jsmith is a member of,
  which roles grant `view_time_entries` and that two of them are BUILTIN, and which projects
  have `time_tracking` enabled. One `rails runner` loop printing those is faster than any of
  the three debugging sessions it prevents.
- **The evidence sentence must name a CALL, not a constant.** The defect this session opened
  with was `ReportRun::OUTPUT_CLASSES` lacking `:widget` while the commit cited
  `ExecutionPolicy::OUTPUT_CLASSES` — true of a different constant, so the caller raised for
  every template that resolved. A one-line probe of the call would have found it.
- **Measure before an irreversible deletion, not after.** S-30 is the whole lesson: the plan
  said the deletion was safe, production analysis agreed, and the suite said 166 of 249. The
  measurement cost ten minutes; a half-finished deletion would have cost a session.

Finish with CLAUDE.md §12's output format, and G1–G12 each with the evidence you actually saw.
`UNVERIFIED` is an acceptable answer; a fabricated `PASS` is not.
