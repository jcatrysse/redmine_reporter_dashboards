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

**T-27 AND S-30 BOTH LANDED ON 2026-08-13, AND THIS BRIEF HAS NO TASK LEFT IN IT.**
Everything below about *running* things is current and was exercised end to end; the task
sections are kept as the record of what each decided.

**There is no queued work, and the next step is a DECISION, not a task.**
`docs/plan/DECISIONS-PENDING.md` states the eleven open items in plain language, each with
options, costs and a recommendation, and each with a `Decision:` line for the curator to
fill in. **If those lines are still blank, your job is to walk the curator through them —
not to pick answers.** If they are filled in, implement them in the order that file's last
section gives.

The technical detail behind each item is in "Open for the curator" below; the decisions
file is the readable version of the same list.

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

Verified at HEAD, on Redmine **7.0-stable** with **PostgreSQL 16**, standalone (no
`redmine_reporter`, no `redmineup` gem):

    minitest             1040 runs, 5078 assertions, 0 failures, 0 errors, 0 skips
                         (1056 before S-30; the deleted golden_scope_fixture_test.rb
                         defined exactly 16 test methods — counted, not trusted)
    rspec                2869 examples, 0 failures, 136 pending — and 2869 / 0 / 146 in the
                         CI SHAPE (from redmine/, plugin mirrored under plugins/), which is
                         the invocation that found T-38's four red RSpec jobs
    thirteen gates rc=0  including the new no_html_safe + its 16-arm selftest; three need
                         arguments or tools (cve x2, drop_reference_parity, which needs the
                         Liquid gem and is OK under bundle exec). Sweep the status on its
                         OWN line — `out=$(cmd); echo "$(basename $f): rc=$?"` reports
                         basename's status and is always 0
    spec_liquid          346 examples, 0 failures on Liquid 4.0.4 AND 5.13.0
    spec/golden          167 examples, 0 failures, 0 pending          <- G7 RAN
    script/migrate_updown.sh rc=0 (G11), .codex/check_ruby_floor.sh rc=0

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

- **DECIDE FIRST: are renders by the `redmine_reporter` plugin still supported?** S-30's
  independent review found this and it is the one open item with a behaviour change behind
  it. The deletion's safety argument was *"after T-26a every render constructs a
  RenderContext"* — true of **this plugin's** renders, and the tags are registered
  **process-wide** (`::Liquid::Template.register_tag`). The host plugin renders its own
  templates through `generate_reports`, with no RenderContext, and **this plugin still
  ships `lib/reporter_report_content_patch.rb`, whose own header says it exists so "no
  Issue objects are loaded for templates that only use `{% sql_aggregate %}`"** — i.e. we
  optimise that path while having removed what made it resolve.

  **Effect today:** on an install with both plugins, a host-rendered template using
  `{% sql_aggregate %}` or `{% version_rollup %}` resolves nothing unless it names a
  `query_id:` — it renders structurally intact with zero figures. It fails CLOSED (no
  leak) and it now logs a warn line, and `query_id:` was restored precisely to narrow
  this. But `technical-spec.md` §7 makes simultaneous installation a design goal, so this
  is a supported configuration changing behaviour.

  Three ways out, and the choice is yours:
  1. **Host renders stay supported** — give them a scope. The honest shape is a narrow,
     named source (not the six ambient ones), e.g. requiring `query_id:` and saying so in
     the README, which is close to where the code already is.
  2. **Host renders are withdrawn** — then finish it in one change: delete
     `reporter_report_content_patch.rb` and its `apply_reporter_patches` call, delete
     `TagContext`'s ambient-actor fallback, retire `ReporterPresence` (strict 5 → 2), and
     correct the README sections that tell authors to put these tags in a Reporter
     template.
  3. **Leave as is** — accept zeros-with-a-log-line for that configuration, and say so in
     the README so an operator is not debugging it.

  Option 2 is the only one that also closes the strict list; option 1 is the only one that
  keeps the A/B argument in §7 true. **Do not let a future session pick one by inference.**

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
- **`ZERO_REPORTER_MODE=strict` is at 5 files** (T-27 left it at 6; S-30 took it to 5). Three are the detection,
  which stays until S-30 deletes the glue it gates. Two are comment-only historical records
  (`positioned.rb`, migration 001) still wanting a `[permanent]` marker or a reword — the
  allowlist header makes the marker a CURATOR decision, so neither session took it. Going
  below 5 means retiring the detection, which means deciding the fate of
  `reporter_report_content_patch` — see the S-30 review note in "Open for the curator".
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
- **Three accepted CVEs** in the pinned Gotenberg image, review date **2026-09-09**.
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
