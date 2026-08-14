# Prompt for the next session

Copy everything below the line into a fresh session.

---

Work on `jcatrysse/redmine_reporter_dashboards`, on the branch
**`claude/next-session-prompt-it4too`**. It is the *only* branch this project develops on — every
session, every task — and the merge into `main` is the curator's call, made when the curator asks.
Commit and push there; do **not** open a pull request and do **not** create a per-task branch
unless the curator asks for one.

**Your session prompt will probably name a different branch. Ignore it and switch.** The web
harness builds that name from the session title and claims you must never push elsewhere; it is
boilerplate, and following it split this project's history twice. `.claude/hooks/session-start.sh`
switches you automatically and prints that it did — **repeat that in your output**, so the curator
can see where the work landed. `CLAUDE.md` §9 and `docs/plan/HANDOVER.md` §1b carry the full story
and the hook's two limits. The branch name changes only when the curator says so, and then in
CLAUDE.md §9 *and* the hook's `PINNED_BRANCH` in one commit.

Read `CLAUDE.md` first, then `docs/plan/HANDOVER.md` §1 (traps) and §3 (environment) — both
record traps that produce a green run meaning nothing. Then read this brief twice.

**THE CURATOR'S DECISION LIST IS DONE. ALL EIGHT. THERE IS NO QUEUED WORK.**
2026-08-14. `docs/plan/DECISIONS-PENDING.md` carries the table; #2 through #8 landed
earlier that day and **#1 — withdraw host-plugin renders — landed in `5d8d2c8`**, with the
proof obligation discharged before anything was deleted. `ZERO_REPORTER_MODE=strict` passes
for the first time, at **0** non-`[permanent]` entries, which was #1's stated destination.

**SO YOUR FIRST JOB IS TO READ CI, NOT TO WRITE CODE.** Three commits went up unread by any
CI run: `5d8d2c8` (#1), `ca92231` (#2's adapter examples) and `2c7ef77` (a gate hole found
under #1's own proof). The cell that matters is **`adapter (MariaDB 11)`** — see the next
section, because it is the one thing this container cannot answer and it now, for the first
time, has something to say.

**What #1 turned out to cost is written up** at the foot of `DECISIONS-PENDING.md` under
*"What #1 owed, and what it cost"* — the measurement table, the one deviation from the scope
note (`TagContext` went whole, not just its fallback), and the three things measurement
contradicted after they had been written down as true. Read it before undoing any of it; two
of the deletions restore a behaviour a previous independent review had deliberately
protected, and the reason that protection expired is recorded in the code.

**The `from:` question was NOT absorbed into #1 and is still open.** Eighteen README examples
write `from:` on an aggregation tag and it has been decorative since T-26a. Keeping it as
documentation-of-intent or stripping it is a curator call.

**What decision #3 changed that you will meet everywhere.** A QUOTED tag parameter is now
LITERAL TEXT; a bare one is a Liquid variable falling back to the literal. One module says
it — `liquid/tag_params.rb` — and five tags share it. If you touch tag markup, that is the
rule, and `TagParams::Value` is a String subclass that must never leave the layer (`resolve`
returns a plain String, and two examples assert it).

## Where the work stands

**Every numbered task is done, and so is the T-26 remainder.** What remains is T-03's twelve
render performance cells, which the curator said to leave.

**What T-27 settled, so you do not re-open it:** the upgrade diagnostic reads Redmine's own
permission tables and asks the plugin registry NOTHING, because a grant outlives the plugin that
registered it — gating it on `ReporterPresence` would print an empty list in the one case it
exists for.

**And what S-30 then changed about that answer.** T-27 said the detection's one consumer was
the `REPORTER_GLUE_FILES` require, and predicted that deleting the glue would take the detection
with it — strict 6 → 3. That prediction was WRONG by two, and the correction is worth carrying:
`reporter_present?` has a SECOND consumer, `apply_reporter_patches`, which after S-30 installs
exactly one thing — `reporter_report_content_patch`, a performance fix on the host plugin's own
report generation that depends on nothing this plugin resolves. So strict went **6 → 5**, not
6 → 3, and the detection survives as a one-question thing: may we patch the host plugin's
controller? Retiring it is a curator decision about whether this plugin should still improve an
installation that has both — not a tidy-up.

Be precise about one thing T-27 got wrong first and corrected: a dangling grant does NOT
authorise anything while its plugin is uninstalled (`Project#allows_to?` rejects it before the
role is consulted). It is stale data that re-arms on reinstall. Do not restore the stronger
claim.

**And one thing S-30 proved that is worth not re-deriving:** `from:` on an aggregation tag was
read ONLY by the deleted legacy module. The owned path returns `render_context.scope` and never
looks at it, so `from: issues` has been decorative on every production render since T-26a — the
README already says so for a spent-time template and it is in fact true everywhere. Eighteen
README examples still write it. Whether to keep it as harmless documentation-of-intent or to
strip it is a curator call; nothing depends on it either way.

Verified at HEAD (`27865db`, 2026-08-14), on Redmine **7.0-stable** with **PostgreSQL 16**,
standalone (no `redmine_reporter`, no `redmineup` gem):

    minitest             1042 runs, 5084 assertions, 0 failures, 0 errors, 0 SKIPS
                         (1040 before; the count moved by the two new functional tests,
                         counted with `grep -c '^  def test_'` rather than trusted.
                         0 skips only because poppler-utils is installed here — a run
                         without it reports 4, each with a reason)
    rspec                2948 examples, 0 failures, 136 pending
                         (2880 before; +68. **193 pending on the first run of this
                         session, and that was poppler's absence, not a regression** —
                         diff the pending LISTS before attributing a move)
    spec/golden          173 examples, 0 failures, 0 pending          <- G7 RAN
    spec_liquid          358 examples, 0 failures on Liquid 4.0.4 AND 5.13.0
                         (346 before; the 12 new ones are the quoting rule against the
                         REAL gem, which is where it had never been run)
    fourteen gates rc=0  including all three *_selftest.sh; `drop_reference_parity.sh` needs
                         `BUNDLE_GEMFILE=$PWD/redmine/Gemfile` or it exits 2 with
                         "the Liquid gem is not loadable" — which is the gate being
                         honest, not a failure. Sweep each status on its OWN line
    script/migrate_updown.sh rc=0 both arms (G11), .codex/check_ruby_floor.sh rc=0
    locale parity        396 keys x 9 files, verified by PARSING each file, with the
                         placeholders of the changed keys compared across all nine

**NOT VERIFIED HERE, AND MARIADB IS STILL THE ONE THAT MATTERS — BUT THE REASON HAS CHANGED,
SO READ THIS RATHER THAN THE OLD VERSION OF IT.** The 2026-08-14 session read the
`adapter (MariaDB 11)` cell at `b87b08c` and found it **green and incapable of confirming #2**:
decision #2 added examples only under `spec/sql_aggregation/`, which is DB-LESS (a stub cannot
truncate a column label — there is no server), and every pre-existing `measure:` case in both
the adapter suite and the golden corpus groups by `status`/`tracker`/`priority`, a few dozen
characters. Every `age` case is a plain COUNT. So the cell had never once run a grouped
aggregate over an expression past MariaDB's 256-character limit.

`ca92231` adds six adapter examples that do (the default age axis measures **333 characters**
with `SUM(issues.estimated_hours)` beside it). **Three of them can only discriminate on
MariaDB** — on PostgreSQL the alias truncates consistently at 63 on both ends, so the values
are right with or without the fix, and restoring the pre-#2 code locally failed only 1 of 69
(the statement-shape assertion). **So read the `adapter (MariaDB 11)` cell for the head you
inherit.** It is now the measurement rather than a formality.

Also unrun here: the conformance corpus and the starter gallery (no Chromium/Gotenberg/
wkhtmltopdf set up), and CI has not run on `5d8d2c8`, `ca92231` or `2c7ef77`.

**THE INDEPENDENT REVIEW RAN AND IT FOUND A BLOCKER**, which is the reason to keep briefing
one. Two subagents were used: the first died on an API spend limit mid-run and left a
mutation in the tree (HANDOVER §1's new first entry); the second completed, verified rather
than read — it reproduced the blocker and mutation-tested the controller test it was asked
to suspect of being vacuous — and returned **1 blocker, 5 majors, 8 minors**. All are closed
in `27865db`; that commit message is the list.

**The blocker is worth knowing even if you never touch tags**, because it is the shape this
project keeps producing: `query_id: "qid"` became a literal, `to_i`'d to zero, and returned
nil BEFORE the branch that logs — so a report rendered complete, showed no diagnostics panel
and read zero. My own example missed it because it used `query_id: "42"`, a NUMERIC literal
whose outcome is identical under both rules. **An example that exercises the changed line is
not the same as one that discriminates.**

**And the rule had only ever run against the STUB Liquid context.** `spec/spec_helper.rb`'s
`Context#[]` is a plain scope lookup; the real one parses its key as an EXPRESSION, so
`"7"`, `"true"`, `"nil"` and `a.b` all have real answers the stub returns nil for — several
examples were passing for the wrong reason. `spec_liquid/tag_params_spec.rb` now runs the
rule against the real gem on both majors. No difference found; established rather than
assumed.

**A CLOUD SESSION STARTS SHALLOW AND THAT FAILS G7 LIKE A REAL BREACH.** `git fetch
--unshallow origin` first, before concluding anything from `spec/golden`. And **`rspec spec`
wrecks the plugin tables**, so `migrate_updown.sh` then fails G11 with what reads as a broken
migration — the repair is in HANDOVER §3 and the order that always works is gates →
`migrate_updown.sh` → minitest → rspec.

**`spec_liquid` WAS RUN FOR S-30, because S-30 touched the Liquid layer** (`ScopeBinding#bind`)
and leaving it unverified would have been the one gap that mattered: **346 examples, 0
failures on Liquid 4.0.4 AND on 5.13.0**. The recipe is below under "How to run things here"
and it takes about a minute — two `gem install`s and a pin file.

Not re-run, and why: the conformance corpus and the starter gallery need render engines this
container had no Chromium/Gotenberg/wkhtmltopdf set up for, and neither T-27 nor S-30 touched
the render path. Their last measured numbers are T-37's.

**CI HAS BEEN READ, TWICE, AND THAT IS NEW HERE.** T-38's run (31694811039, `1324c5a`) was 22
of 26 green with **all four `RSpec` jobs red** — a source-level glob that rejected any path
containing `/redmine/`, which is every path once the plugin is installed the way CI installs it,
and one example in that file had been passing vacuously on an empty glob. Fixed in `a321ab9`.
T-37's run 250 (`6bc7d42`) is then **26 of 27 green**: every RSpec job recovered, and the one red
cell is the new `starter-gallery` job at **14 of 15** — `issue-document / chromium_cdp` timed out
as the FIRST render of the job while the other four chromium renders passed, which is a cold pool
rather than a starter. Every engine is warmed through `render:preflight` now (and the Gotenberg
warm-up it replaced had been posting the wrong form field, so it had never warmed anything).
**Read the run for the head you inherit rather than trusting this paragraph**, and reproduce the
rspec job locally before you push — the recipe is in HANDOVER §1.

## T-27, as built — the record, not a task

**DONE 2026-08-13.** Kept here because the decision it took is one a later session could
undo by accident.

The `template_authoring` setting T-27's original text required was already GONE (T-40
replaced it with §4.1's role permissions), so what it owed instead was the **upgrade
diagnostic**: the preflight page listing every role holding the base plugin's authoring
permission beside every role holding ours. That shipped as
`lib/redmine_reporter_dashboards/permissions/authoring_audit.rb` plus a section on
`reporter_preflight/show.html.erb`, with both `Accept:` cases tested by name (base plugin
absent → empty list, not an error; a role holding ours and not theirs).

**The base plugin's authoring permission is `:manage_report_templates`, and that was
MEASURED** from its own repository at `b1d1736` rather than inferred — `init.rb:19-32`
registers six permissions and only that one takes a template body from params
(`params[:report_template][:type].constantize.new`). The other five render STORED
templates. Attach the repo before second-guessing this.

**The asymmetry the page exists to show:** `:manage_report_templates` carries no `require:`,
so Redmine offers it to Non-member and Anonymous; ours cannot land there because
`Entry#requires` derives `:member` from `authoring`. Hence `Role.all`, not `Role.givable`.

The other three `Accept:` parts were already true and are now asserted rather than assumed:
the label reads *"Author report templates (executes server-side code)"* in all nine locales,
the widget iframe carries `sandbox="allow-scripts"` without `allow-same-origin` plus a
restrictive CSP (four tests across four surfaces), and the height-fit `postMessage`
regression was never introduced because no height-fit script exists — the CSS says so.

**`no_html_safe.sh` now exists, has a committed `_selftest.sh` (16 arms), and is wired into
CI's `gates` job.** Do not trust a gate here that has no self-test: this one was
negative-tested interactively, reported as tested, and an independent review then found four
holes in it. HANDOVER §1 carries the entry.

## S-30, as built — the record, not a task

**DONE 2026-08-13.** `glue/` is deleted: `scope_resolution.rb` (six ambient scope sources)
and `reporter_list_patch.rb` (the thread-local that fed one of them), plus
`spec/reporter_list_patch_spec.rb`, `test/unit/golden_scope_fixture_test.rb`,
`ScopeBinding`'s legacy dispatch and `LegacyHost`, `REPORTER_GLUE_FILES`, and the
`ReporterListPatch` line in `apply_reporter_patches`.

**Why it worked this time.** The 2026-08-12 attempt deleted first and measured 166 of 249
red. This one rebuilt the harness first: `spec/sql_aggregation` was moved onto an owned
`RenderContext` and proved indifferent to the module — 695 examples, 0 failures with it
present AND with `legacy_available?` stubbed false — before a file was removed. **If you ever
face a deletion like this again, that is the order.**

**The number worth carrying is the SPLIT, not the 166.** Of 150 failures, 121 were testing
the TAG and merely used a legacy source to hand it a scope: four harness-helper edits fixed
most of them. Only 38 examples had the deleted behaviour as their subject. The first attempt
read "166 red" as "166 to port" and reasonably called it a task. **Measure subject-versus-
harness before estimating a rebuild.**

**`spec/golden/scope/scope.jsonl` and `sql/scope_sql.jsonl` survive byte-identical** and are
now HISTORICAL RECORDS — `git diff` over `spec/golden/` shows only README changes. They are
the only surviving description of behaviour this plugin used to have and cannot be
regenerated, because their subject is gone. `spec/golden/README.md` says so and says not to
tidy them away. `scope_fixture.rb` stays as their reader.

**Not a visibility regression, and this is the claim to attack if you doubt one thing.**
`enforce_visibility` existed because a legacy source could hand over an arbitrary relation.
An owned context cannot: the constructor REFUSES a nil actor (INV-1) and the scope comes from
`ReportScope.build` over that actor's visible scope, so the intersection moved upstream and
became unconditional. `test/unit/multi_actor_visibility_test.rb` asserts it against a real
`Role#issues_visibility` and a real private issue.

## What T-37 built, because the authoring surface is now four things

| | |
|---|---|
| `_lint.html.erb` + `lint_report.rb` | FR-71. The panel is server-rendered and BOUNDED at 100 rows with the drop stated; `rake reporter_dashboards:lint_templates` is the same linter, and a test compares the two finding LISTS over one fixture |
| `liquid/drop_reference.rb` | FR-72. Accessor NAMES come from `Liquid::Drop.invokable_methods`; only the type and the batch flag are declared. `docs/drop-reference.md` is generated, and `drop_reference_parity.sh` has four arms |
| `starters/` + `starter_gallery.rb` | FR-73. Five entries, zero lint findings each, 15 of 15 on three engines, thumbnails with the digest of the body each was drawn from |
| `_chart_form.html.erb` + `chart_form.js` | FR-73's second half. Writes one line of Liquid at the caret and stores nothing; ships `hidden` and the script reveals it, so with JS off the feature is absent rather than broken |
| `_editor.html.erb` | ONE editor on three pages, `preview` included — which is what satisfies §9b.2's "diagnostics in the editor, next to the code" |

**Two deviations from §9b.1, both argued in place rather than absorbed.** The gallery's five
entries are purpose-built rather than the two legacy examples "cleaned" (they carry 12 and 44
lint findings, all of them the Chart.js 2 plumbing `{% chart %}` replaced, and they keep a second
job as the README's record of the old idiom). And the chart form has no "drill on/off" because
`{% chart %}` has no such parameter.

## Open for the curator

- **~~DECIDE FIRST: are renders by the base plugin still supported?~~ ANSWERED AND
  IMPLEMENTED.** The curator took **option 2 — withdrawn** (*"niemand gebruikt dat nog"*), and
  it landed in `5d8d2c8` on 2026-08-14. Kept here, struck through rather than deleted, because
  the three options and the reasoning behind them are what a later session would otherwise
  re-derive from scratch — and because option 2's own text under-described the work in two
  places that are worth knowing:

  It said *"delete `TagContext`'s ambient-actor fallback"*. Deleting the fallback cannot mean
  passing a nil actor instead: `Query.visible` opens with `user = args.shift || User.current`
  and `Version.visible` with `args.first || User.current`, on all four supported branches, so a
  nil actor reads the ambient one INSIDE REDMINE CORE where no gate here can see it. The
  fallback is replaced by an explicit REFUSAL, and `{% geo_version_map %}` needed its own
  because it resolves no scope and so never met the `scope.nil?` branch the aggregation tags had.

  It also said *"strict 5 → 2"*. The real arithmetic was **3 → 0**, because decision #5 marked
  two comment-only files `[permanent]` in between. That is the third time a session predicted
  this count and missed; the gate's own failure message now refuses to predict it.

  `DECISIONS-PENDING.md`'s closing section is the full record.

- **`group_by: user` CANNOT BE EXPRESSED on the spent-time source, and quoting does not help.**
  Found by T-37's own gallery harness. A bare tag parameter is resolved as a Liquid variable
  (`str_param` → `context[value]`), `user` and `project` are ALWAYS assigned in a report, and
  `parse_markup` strips the quotes before the lookup — so `group_by: "user"` asks for
  `group_by: "Redmine Admin"`. Two of that source's four own dimensions are unreachable. It
  fails VISIBLY (`aggregation_dimension_unknown` on the page), which is why it is a report
  rather than a blocker. The fix is small and its blast radius is not: 23 call sites go through
  `str_param`, and making a quoted parameter a literal changes the meaning of every quoted
  parameter in every existing template. **A compatibility decision, not a bug fix.**
- **The README's spent-time dimension table lists eleven and the code has eight.** `priority`,
  `author` and `assignee` were removed by T-31's review (they had no `TimeEntryQuery` filter to
  drill into) and the README was not updated with them.
- **MariaDB `group_by: age` with `measure: sum | avg | distinct`** is still wrong past about four
  boundaries. D-1's alias-truncation defect, fixed for the COUNTING path in T-08 and not for the
  three grouped calculations. **A release blocker by decision.**
- **`<html lang>` is absent from both bindings.** Setting it needs a decision about whose locale
  a SCHEDULED report speaks.
- **~~`ZERO_REPORTER_MODE=strict` is at 5 files~~ STRICT PASSES, at 0 non-`[permanent]`
  entries** (2026-08-14, decision #1). Seven files still name the base plugin and all seven
  carry the marker: five importer files, which read that plugin's tables because that is what
  an importer is for, and two comment-only historical records marked by decision #5. **The
  gate's DEFAULT is still `warn` and flipping it is a curator call** — warn already blocks
  silent regression, while defaulting to strict additionally refuses the reviewed decision to
  allowlist something, which is a policy change about what CI permits.
- **`manage_public_reporter_dashboards_templates` is flagged as code execution and cannot
  author.** T-40 marks it `authoring: true`, and its own comment says a role holding only it is
  refused at `#create` by a second guard. T-27's diagnostic reads the flag faithfully, so such a
  role prints *"Check that this was intended"* about somebody who cannot write a template — the
  cry-wolf failure that module is otherwise careful to avoid. Either the flag means "grants a
  code-execution privilege" (and this row does not) or it means "belongs to the authoring group"
  (and the audit needs a narrower predicate). **A one-line decision, and T-27 did not take it
  because the flag is T-40's contract.** Found by the independent review.
- **The audit's rows sort alphabetically by role name**, so a builtin role holding code execution
  — the most alarming row the page can print — lands wherever the alphabet puts it. It carries a
  warning icon and a note, and the table is small by construction (only authoring roles), so this
  was left as predictable-and-deterministic rather than sorted by severity. Worth a second
  opinion if any real install shows a long list.
- **`hu`, `pl`, `zh`** values were written by a model, not a native speaker; T-37 added 49 more
  keys in each. The curator's answer was "don't care, leave it" — recorded so it is not
  re-raised.
- **THE NIGHTLY GOTENBERG CVE SCAN IS RED, AND IT IS A CURATOR DECISION RATHER THAN A BUG.**
  Read 2026-08-14 while reading CI for #1; red on every commit that day, so it PREDATES the
  decision work and none of it is caused by it. Three CVEs are accepted with review date
  2026-09-09, and that count is what this line used to say. The scan now reports **38
  unaccepted fixable HIGH findings** — measured, from run 35's job log:

      accepted: CVE-2026-19155 CVE-2026-46602 CVE-2026-56852
      found:    41 ids, of which 38 are on no list
      cve_accepted_diff: FAIL — NEW fixable HIGH/CRITICAL findings in the pinned image

  Mostly a wave of Chromium advisories (CVE-2026-19137…19177 and 19556…19560: sandbox
  escapes, use-after-free in Blink/TabStrip, arbitrary code execution via extensions) plus
  two Go stdlib ones in `usr/bin/gotenberg` and `usr/bin/pdfcpu` (CVE-2026-39821,
  CVE-2026-46600). The allowlist's own header records that on 2026-08-10 the same digest had
  **five** fixable HIGH findings across four advisories, so the image did not change — the
  vulnerability database did, which is the mechanism that file already documents once (see
  the deleted CVE-2026-46604 note).

  **The digest cannot move**: `pinned` and what `gotenberg/gotenberg:8` resolves to are the
  SAME (`sha256:a16a14e1…`), which is the branch of the workflow's own message that says
  *"there is nowhere to move to and the decision is a human one"*. So the options are the
  gate's own: accept each with a reason and a valid-through date (the gate caps expiry at 90
  days and refuses a malformed record), or stop recommending the container. **Do not delete
  the gate, and do not make it advisory** — CLAUDE.md §7 forbids the second and the
  allowlist header forbids the first.

  Not touched by the 2026-08-14 session: 38 individual acceptances about a security posture
  is exactly the judgement CLAUDE.md §11 says to report rather than take. Note the
  containment argument is already written down in the allowlist and in
  `docker-compose.gotenberg.yml` (`internal: true`, non-root, Chromium's sandbox left on,
  read-only root, `cap_drop: ALL`, PDF-engine routes off) — it decides what an attacker
  reaches after an escape, and it fixes none of them.
- **FR numbering**: the engine-selection screen is cited as FR-50 in nine locale-file headers
  while `functional-spec.md` defines FR-50 as the generated support matrix (§Findings E-29 row 8).

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
- **rspec**, from the PLUGIN root (not from `redmine/`):
  `LANG=C.UTF-8 BUNDLE_GEMFILE=$PWD/redmine/Gemfile bundle exec rspec -I spec spec`
- **`spec_liquid` NEEDS THE REAL GEM AND `spec/` MUST NOT HAVE IT.** `spec/spec_helper.rb`
  installs a Liquid STUB; a `require 'liquid'` anywhere under `spec/` loads the real gem into a
  process the other files were written against and turns 19 of T-16's chart-tag examples red
  (`private method 'new' called for ChartTag` — `Liquid::Tag.new` is private on Liquid 5 and the
  stub's is not). T-37 lost a round to this. Both majors:

      gem install rspec liquid --no-document        # plus -v 4.0.4 for the older major
      PATH=/opt/rbenv/versions/3.3.6/bin:$PATH
      printf "gem 'liquid', '%s'\nrequire 'liquid'\n" '4.0.4' > /tmp/pin.rb
      rspec -r /tmp/pin.rb spec_liquid --format progress

- **THE G7 TRAP:** a suite run from a copy with **no `.git`** silently skips the ten
  `spec/golden` byte-identity examples — gate **G7**. `rspec spec/golden` is **167 examples, 0
  failures, 0 pending**; any pending there means it did not run. A cloud session also starts from
  a shallow clone, which makes those examples FAIL in a way that reads like a real G7 breach:
  `git fetch --unshallow origin` is the first thing to try.
- **RUN MINITEST BEFORE RSPEC, or repair in between.** `rspec spec` wrecks the plugin tables in
  `redmine_test`, and the next `migrate_updown.sh` then fails G11 with "the database still
  contains objects this plugin's…" — which reads exactly like a broken migration. The repair is
  HANDOVER §3's `rails runner` drop plus `rake redmine:plugins:migrate`.
- **THE STARTER GALLERY NEEDS DATA, AN ACTOR AND A NON-ROOT USER.** `rake …:gallery:verify`
  renders five templates on every registered engine; it needs fixtures in the database and an
  explicit actor, and Chromium refuses to run as root:

      cd redmine && LANG=C.UTF-8 RAILS_ENV=test bundle exec rake db:fixtures:load
      bundle exec rails runner 'Project.find(1).enable_module!(:reporter_dashboards_reports)'
      # then, as a non-root user, with CHROME_PATH and the Gotenberg variables set:
      RRD_PROJECT=ecookbook RRD_ACTOR=admin bundle exec rake reporter_dashboards:gallery:verify
      # RRD_THUMBNAILS=1 also redraws the PNGs — into the MIRROR, so copy them back

  **A FRESH GOTENBERG CONTAINER FAILS ITS FIRST TWO RENDERS** (the browser inside it starting
  up). Warm it, or read two false failures.
- **THE CORPUS NEEDS FOUR THINGS**, and it is worth the ten minutes:

      apt-get install -y poppler-utils            # pdfinfo, pdftotext, pdftoppm, pdftohtml
      curl -fsSL -o /tmp/wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb
      apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb   # PATCHED qt — see below
      nohup dockerd --iptables=false --ip6tables=false >/tmp/dockerd.log 2>&1 &
      docker run --rm -d --name gt-auth -p 127.0.0.1:3098:3000 \
        -e GOTENBERG_API_BASIC_AUTH_USERNAME=rrd -e GOTENBERG_API_BASIC_AUTH_PASSWORD=s3cret \
        "$(grep -oE 'gotenberg/gotenberg:8@sha256:[0-9a-f]+' docker-compose.gotenberg.yml)" \
        gotenberg --api-enable-basic-auth --api-timeout=60s

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
- **`apt install wkhtmltopdf` GIVES YOU THE UNPATCHED-QT BUILD, and it is wrong about more than
  footers.** T-38 wrote two capabilities into the closed vocabulary on that binary's answers and
  retracted both the same day when the patched build answered YES to each. `wkhtmltopdf --version`
  must say `(with patched qt)`. Treat the distro build as answering NO to any print-pipeline
  question until the patched one agrees.
- **PostgreSQL dies in this container, repeatedly.** `service postgresql start`, then
  `pg_isready -h 127.0.0.1`, before concluding anything from a database error. Starting `dockerd`
  has coincided with it going down.
- **Gates:** fourteen `script/gates/*.sh` take no arguments and all exit 0 (`cve_accepted_diff.sh`
  takes arguments). `drop_reference_parity.sh` needs the Liquid gem, so it runs in the `rspec` CI
  job rather than in `gates`, which installs none. There is **no RuboCop** in this repo — G3 is
  "no linter configured for this path", not a pass.
- **The base plugin's source is readable.** `jcatrysse/redmine_reporter` is private but can be
  attached: `add_repo`, then one shallow clone. Several rounds of this project GUESSED at its
  behaviour and were subtly wrong. T-27's upgrade diagnostic is ABOUT that plugin's permissions —
  attach it rather than inferring their names.

## Discipline this project actually enforces

All four CLAUDE.md roles, every task. **Use a fresh subagent for the review and brief it to
REJECT** — and if the session cannot spawn one, say in the output that it was self-review, so the
weaker evidence is visible rather than implied. T-37 was self-review for that reason.

Six habits that earned their keep, all of them cheap:

- **COMMIT BEFORE YOU MUTATE.** T-37's harness left one mutation in the working tree (a `cd` in a
  mutation command leaked into every later restore) and it cost nothing, because `git diff HEAD`
  named the file. Run each mutation's command in a SUBSHELL.
- **Mutation-test, and believe a survivor.** T-37's thumbnail staleness detector had four tests
  and every one passed against a version that always answered `[]` — because none had ever shown
  it the condition it detects. A detector with no negative case is an empty array with a name.
- **Measure the fixture, do not assume it** — and measure the BINARY too.
- **The evidence sentence must name a CALL, not a constant.**
- **Measure before an irreversible deletion, not after.** S-30 is the whole lesson.
- **A check that could not run looks exactly like a check that passed.** T-37's new gate reported
  FAIL-with-findings twice for a reader that had CRASHED, because an uncaught Ruby exception exits
  1 — which is the wrapper's code for "there are findings". Both arms exit 2 now. Every gate arm
  needs to fail once, in front of you, on a violation you planted where you did not expect it to
  be found.

Finish with CLAUDE.md §12's output format, and G1–G12 each with the evidence you actually saw.
`UNVERIFIED` is an acceptable answer; a fabricated `PASS` is not.
