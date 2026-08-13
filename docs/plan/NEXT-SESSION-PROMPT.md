# Prompt for the next session

Copy everything below the line into a fresh session.

---

Work on `jcatrysse/redmine_reporter_dashboards`, on the branch
**`claude/next-session-prompt-it4too`**, which is the integration branch this project actually
works in. Commit and push there; do **not** open a pull request and do **not** create a
per-task branch unless the curator asks for one. `CLAUDE.md` §9 carries the same sentence and
is the one a fresh session obeys — if the branch changes, change it there.

Read `CLAUDE.md` first, then `docs/plan/HANDOVER.md` §1 (traps) and §3 (environment) — both
record traps that produce a green run meaning nothing. Then read this brief twice.

**Your task is T-37 · The authoring experience.** Its `Accept:` list is in
`docs/plan/implementation-plan.md` and its shape is settled: `[OQ-M]` is CLOSED, the answer is
NO, and the section below says what that leaves.

## Where the work stands

**37 of 38 tasks are done.** T-38 landed on 2026-08-13. What remains is **T-37**, **T-27**
(blocked on a decision that belongs to it), the T-26 remainder (**S-30**) and T-03's twelve
render performance cells, which the curator said to leave.

Verified at HEAD, on Redmine **7.0-stable** with **PostgreSQL 16**, standalone (no
`redmine_reporter`, no `redmineup` gem):

    minitest              985 runs, 4711 assertions, 0 failures, 0 errors, 0 skips
    rspec                 spec/ green (see the commit message for the exact count)
    rspec spec/golden     167 examples, 0 failures, 0 pending          <- G7 RAN
    rspec -r liquid spec_liquid  301 examples, 0 failures
    conformance corpus    100 examples, 0 failures — chromium_cdp 23/0/0, gotenberg 22/0/1,
                          wkhtmltopdf (PATCHED qt) 21/0/2. G9 verified on a SECOND run with
                          RRD_MATRIX_WRITE unset, which is the only way it is a check
    ten gates rc=0, script/migrate_updown.sh rc=0 (G11), .codex/check_ruby_floor.sh rc=0

**CI has not been read for these commits.** The curator believes it is green; confirm before
claiming any Redmine other than 7.0 or any engine other than PostgreSQL. That is INV-7 and it
is this project's oldest broken promise.

## THE ONE TRAP THAT COST T-38 A ROUND, AND IT IS IN THE HANDOVER IN CAPITALS

**`apt install wkhtmltopdf` gives you the UNPATCHED-Qt build, and it is wrong about more than
footers.** T-38 needed two engine facts, measured both on that binary, and got NO to both:
`thead { display: table-header-group }` does not repeat a header there, and an
`<a xlink:href>` inside an inline SVG produces no PDF link annotation. Two capabilities were
written into the CLOSED vocabulary on that evidence and two fixtures were given a `requires!`
so wkhtmltopdf would skip them. Then the patched build — `0.12.6.1 (with patched qt)`, the
release `.deb` CI installs — answered **YES to both**, so there was no support difference and
everything was retracted the same day.

    curl -fsSL -o /tmp/wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb
    apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb
    wkhtmltopdf --version     # must say "(with patched qt)"

`Render::Capabilities` carries the retraction and the rule it leaves: **a capability is a claim
about every SUPPORTED build, so measure it on the build the matrix is about.** Treat the distro
build as answering NO to any print-pipeline question until the patched one agrees.

## What T-38 built, because T-37 sits on top of it

| | |
|---|---|
| `lib/…/report_stylesheet.rb` | the print-first stylesheet, built in **Ruby** so the palette and three of the five type steps are READ from `Charts::Palette`/`ChartLayout`. A `.css` file cannot read a constant, which is the whole reason it is Ruby |
| `lib/…/report_document.rb` | the ONE assembler. `ReportFrame.document` delegates and keeps the CSP; `ReportRun#pdf_document` wraps the PDF body, which used to reach the engine as a bare FRAGMENT |
| `script/gates/chrome_no_design_tokens.sh` | §9b's "no design language of its own for chrome", enforced over `assets/stylesheets/` |
| `F-21`, `F-22`, `F-23` | conformance fixtures for the repeating header, the unbroken block and the drill-through link annotation, all three green on all three engines |
| `{% mermaid title:/desc: %}` | plus the boot-script insertion that gives a diagram a `<title>`/`<desc>` |
| `chart.pie_legend_disabled` (error), `chart.legend_disabled` (warning) | FR-76's colour-alone clause, in the linter |

**Three class names are now public API for a template author** — `.rrd-card`, `.rrd-number`,
`.rrd-muted` — documented in the README under *How a report is styled*. The starter gallery
T-37 owes should use them, and its thumbnails will inherit the stylesheet for free.

## What T-37 has to do

`[OQ-M]` is **closed, measured, answer NO**: there is no pre-built CodeMirror 6 bundle to
vendor. `codemirror@6.0.2` is a meta-package whose `dist/index.js` is a 4,737-byte re-export
shim importing seven bare specifiers; one usable file needs a bundler, which §6 forbids, and
the result would be *our* artefact, so `THIRD_PARTY.md`'s three-independent-origin byte check
could not apply to it. **Curator decision: take the fallback.** T-37 is therefore a plain
`<textarea>` plus a server-rendered lint panel — findings with line and column beside the
editor, **not** in a gutter, and the `Accept:` clause is already reworded to say so. Nothing is
vendored; the CodeMirror line in `Touches:` is void.

The rest is mostly assembly: the panel is fed by **the same linter object** the rake task calls
(assert both over one fixture and compare the finding lists), the preview renders HTML **and**
PDF and says "preview of N of M", a failed preview shows FR-58's diagnostics in the editor, the
drop reference is generated from the declared surfaces with a `drop_reference_parity` gate
asserting both directions, and the starter gallery's every entry lints clean and renders on
every engine in the matrix.

**One thing to know before writing the lint panel.** `Liquid::HtmlScanner#script_regions` is
**quadratic in a non-ASCII body**: measured 2026-08-13, `TemplateLinter.analyse` takes **35.6
seconds** on a 512 KiB body of `é` — which is exactly `MAX_BODY_BYTES`, so the bound does not
protect it. It indexes by CHARACTER into a String (`@source[index]`), and character indexing
into a multi-byte String is O(index). The lint panel is a synchronous request over an
author-supplied body, so this is a hold-a-worker defect on the surface T-37 builds. It is
T-19's code and it is **reported, not fixed** — see *Open for the curator*.

## S-30 — the one piece of T-26 still owed, and it is bigger than it looks

`glue/legacy/scope_resolution.rb` was authorised for deletion by the curator, attempted, and
**reverted on a measurement**. Read §Findings **S-30** before touching it.

The production argument is sound: after T-26a nothing constructs a render without an owned
`RenderContext`, so `ScopeBinding#bind`'s legacy branch is unreachable. What the plan never
recorded is that **the DB-less tag suite uses that path as its harness** —
`spec/sql_aggregation/liquid_aggregate_tag_spec.rb` builds contexts with the `sql_issue_query`,
`container` and `controller` registers, an `issues` drop assign, a `@sql_base_scope` ivar and a
thread-local, which are the six sources that module resolves. Removing the branch is **166 of
249 examples red**, and most of them cannot be ported because the behaviour genuinely stops
existing.

Its shape, if a later session takes it: rewrite the two tag specs onto `RenderContext`, delete
the six-source examples with an argued list of what coverage went, then delete `glue/`,
`#legacy_bind`, `LegacyHost`, `test/unit/golden_scope_fixture_test.rb` (it `include`s the
module, so deletion is a LOAD failure taking all twelve of its methods) and the
`no_thread_local` exemptions. **`spec/golden/scope/scope.jsonl` must survive whatever happens
to its subject** — it is the one artefact in this repository that cannot be regenerated.

## Open for the curator

- **`HtmlScanner` is quadratic on a multi-byte body** — 35.6 s for one `TemplateLinter.analyse`
  call at `MAX_BODY_BYTES`, measured. Pre-existing (T-19), unrelated to T-38, and it lands on
  T-37's lint panel. The fix is small — stop indexing by character; walk bytes or use
  `Regexp#match(str, pos)` — but it is T-19's file and its own spec file is where the 36 s in
  the suite goes.
- **Nothing REQUIRES a drill-through capability, because there is no capability to require.**
  All three engines produce the annotation on their supported builds, so a chart's clickable
  links need no negotiation. Recorded because the first version of T-38 thought otherwise.
- **`ZERO_REPORTER_MODE=strict` is at 6 files, from 12.** Two are comment-only historical
  records (`positioned.rb`, migration 001) and want a `[permanent]` marker or a reword. Three
  are the detection — and nothing is patched on its answer any more, so its only consumers are
  `init.rb`'s boot log and the one glue require. **That boot line is T-27's upgrade diagnostic
  in embryo**, which is why T-27 is still blocked and why the decision belongs to it. The
  sixth is S-30.
- **MariaDB `group_by: age` with `measure: sum | avg | distinct`** is still wrong past about
  four boundaries (README, database section; plain counts are correct at any boundary count,
  and nothing 500s). It is D-1's alias-truncation defect, fixed for the COUNTING path in T-08
  and not for the three grouped calculations that still go through ActiveRecord's
  `.sum`/`.average`/`.count`. The fix is to give them `grouped_counts`' positional shape.
  **A release blocker by decision**, because MariaDB is in the curator's plan before go-live.
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
- **minitest, whole suite** (~85 s), from `redmine/`:
  `LANG=C.UTF-8 RAILS_ENV=test bundle exec rake redmine:plugins:test NAME=redmine_reporter_dashboards`
  One file: `bundle exec ruby -Itest plugins/redmine_reporter_dashboards/test/...`
- **rspec**, from the PLUGIN root (not from `redmine/`):
  `LANG=C.UTF-8 BUNDLE_GEMFILE=$PWD/redmine/Gemfile bundle exec rspec -I spec spec`
- **THE G7 TRAP:** a suite run from a copy with **no `.git`** silently skips the ten
  `spec/golden` byte-identity examples — gate **G7**. `rspec spec/golden` is **167 examples, 0
  failures, 0 pending**; any pending there means it did not run. A cloud session also starts
  from a shallow clone, which makes those examples FAIL in a way that reads like a real G7
  breach: `git fetch --unshallow origin` is the first thing to try.
- **RUN MINITEST BEFORE RSPEC, or repair in between.** `rspec spec` wrecks the plugin tables in
  `redmine_test`, and the next `migrate_updown.sh` then fails G11 with "the database still
  contains objects this plugin's…" — which reads exactly like a broken migration. The repair is
  HANDOVER §3's `rails runner` drop plus `rake redmine:plugins:migrate`; T-38 met this and it
  cost a wrong G11 verdict for one round.
- **THE CORPUS NEEDS FOUR THINGS**, and it is worth the ten minutes:

      apt-get install -y poppler-utils            # pdfinfo, pdftotext, pdftoppm, pdftohtml
      curl -fsSL -o /tmp/wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb
      apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb   # PATCHED qt — see above
      nohup dockerd --iptables=false --ip6tables=false >/tmp/dockerd.log 2>&1 &
      docker run --rm -d --name gt-auth -p 127.0.0.1:3098:3000 \
        -e GOTENBERG_API_BASIC_AUTH_USERNAME=rrd -e GOTENBERG_API_BASIC_AUTH_PASSWORD=s3cret \
        "$(grep -oE 'gotenberg/gotenberg:8@sha256:[0-9a-f]+' docker-compose.gotenberg.yml)" \
        gotenberg --api-enable-basic-auth --api-timeout=60s
      # warm the browser: a FRESH container fails the preflight's JS check, see HANDOVER §3

  Then, as a non-root user, because Chromium refuses to run as root and `--no-sandbox` is not
  the answer:

      useradd -m -u 4242 rrdbench && chmod -R a+rX /home/user/redmine_reporter_dashboards
      su rrdbench -c 'export HOME=/home/rrdbench LANG=C.UTF-8 \
        CHROME_PATH=/opt/pw-browsers/chromium-1194/chrome-linux/chrome \
        RRD_GOTENBERG_URL=http://127.0.0.1:3098 RRD_GOTENBERG_USERNAME=rrd \
        RRD_GOTENBERG_PASSWORD=s3cret \
        BUNDLE_GEMFILE=/home/user/redmine_reporter_dashboards/redmine/Gemfile \
        RRD_CONFORMANCE=1 && bundle exec rspec -I spec spec/conformance'

  Add `RRD_MATRIX_WRITE=1` to regenerate `docs/engine-support-matrix.md`, and then **run it
  again without that variable** — a write is not a check, and G9 is the comparison.
- **PostgreSQL dies in this container, repeatedly.** `service postgresql start`, then
  `pg_isready -h 127.0.0.1`, before concluding anything from a database error. Starting
  `dockerd` has coincided with it going down.
- **Gates:** ten `script/gates/*.sh` take no arguments and all exit 0 (`cve_accepted_diff.sh`
  takes arguments — CI passes `--validate-only --expiry-advisory` plus the allowlist). There is
  **no RuboCop** in this repo — G3 is "no linter configured for this path", not a pass.
- **The base plugin's source is readable.** `jcatrysse/redmine_reporter` is private but can be
  attached: `add_repo`, then one shallow clone. Several rounds of this project GUESSED at its
  behaviour from this plugin's own overrides and were subtly wrong. Attach it before designing
  against an assumption about it.

## Discipline this project actually enforces

All four CLAUDE.md roles, every task. **Use a fresh subagent for the review and brief it to
REJECT.** Snapshot the intended tree BEFORE launching review agents and never `git add -A`
while one is live — a mutation harness edits the tree by design.

Five habits that earned their keep, all of them cheap:

- **Mutation-test, and believe a survivor.** A guard with no observable effect is a comment;
  delete it rather than keeping it (T-25's precedent).
- **Measure the fixture, do not assume it** — and measure the BINARY too. T-38's whole
  retraction is one binary's accident mistaken for an engine's property.
- **The evidence sentence must name a CALL, not a constant.**
- **Measure before an irreversible deletion, not after.** S-30 is the whole lesson.
- **A check that could not run looks exactly like a check that passed.** T-38's own new gate
  reported OK for four arms while its comment-stripper was crashing, because a failing pipe
  and a clean file are the same empty string. Every gate arm needs to fail once, in front of
  you, on a violation you planted where you did not expect it to be found.

Finish with CLAUDE.md §12's output format, and G1–G12 each with the evidence you actually saw.
`UNVERIFIED` is an acceptable answer; a fabricated `PASS` is not.
