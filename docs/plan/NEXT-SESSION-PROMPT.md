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

**Your task is T-27 · INV-9 as an enforced boundary.** Its `Accept:` list is in
`docs/plan/implementation-plan.md`. Read the *decision* section below before you start: T-27
carries a question that has been waiting for it, and answering it is part of the task.

## Where the work stands

**38 of 38 numbered tasks are done. T-37 landed on 2026-08-13.** What remains is **T-27**, the
T-26 remainder (**S-30**) and T-03's twelve render performance cells, which the curator said to
leave.

Verified at HEAD, on Redmine **7.0-stable** with **PostgreSQL 16**, standalone (no
`redmine_reporter`, no `redmineup` gem):

    minitest             1048 runs, 5152 assertions, 0 failures, 0 errors, 0 skips
    rspec                2899 examples, 0 failures, 136 pending — and 2899 / 0 / 146 in the
                         CI SHAPE (from redmine/, plugin mirrored under plugins/), which is
                         the invocation that found T-38's four red RSpec jobs
    twelve gates rc=0    plus the CVE gate in its CI form; sweep the status on its OWN line
    spec_liquid          346 examples, 0 failures on Liquid 4.0.4 AND 5.13.0
    spec/golden          167 examples, 0 failures, 0 pending          <- G7 RAN
    conformance corpus   109 examples, 0 failures — chromium_cdp 23/0/0, gotenberg 22/0/1,
                         wkhtmltopdf (PATCHED qt) 21/0/2
    starter gallery      15 of 15 — five starters x three engines, measured locally
    script/migrate_updown.sh rc=0 (G11), .codex/check_ruby_floor.sh rc=0

**CI HAS BEEN READ, AND IT WAS NOT GREEN.** T-38's run (31694811039, `1324c5a`) was 22 of 26
jobs green with **all four `RSpec` jobs red** — a source-level spec whose glob rejected any path
containing `/redmine/`, which is every path once the plugin is installed the way CI installs it.
Fixed in `a321ab9`, and the fix is verified in BOTH invocations. **Read the run for the head you
inherit rather than trusting this paragraph**, and reproduce the rspec job locally before you
push — the recipe is in HANDOVER §1. **T-37 also added a job**, `starter-gallery`, the only one
with both a database and all three engines, and it had never run when this was written.

## T-27, and the decision it owns

`Accept:` has four parts and three of them are small. The one that is not is this: the
`template_authoring` setting T-27's original text required is **GONE** — T-40 replaced it with
§4.1's role permissions — so what T-27 owes instead is the **upgrade diagnostic**: the preflight
page listing every role holding the base plugin's authoring permission BESIDE every role holding
ours, with a test for the case where the base plugin is absent (the list is empty, not an error)
**and** a test for a role that holds ours and not theirs. That last one is not hypothetical:
core's `DefaultData::Loader` grants Manager every setable permission on a fresh install, so on
that path the diagnostic is the ONLY thing that surfaces a code-execution grant nobody chose.

**THE DECISION THAT HAS BEEN WAITING FOR THIS TASK.** `ZERO_REPORTER_MODE=strict` is at **6
files**, from 12. Two are comment-only historical records (`positioned.rb`, migration 001) and
want a `[permanent]` marker or a reword. Three are the DETECTION (`ReporterPresence`) — and
nothing is patched on its answer any more, so its only consumers are `init.rb`'s boot log and
the one glue require. **That boot line is T-27's upgrade diagnostic in embryo.** The sixth is
S-30. Decide what the detection is FOR, then either grow it into the diagnostic or delete it and
build the diagnostic from Redmine's own permission tables.

The rest of T-27's list is already true and needs asserting rather than building: the widget
iframe carries `sandbox="allow-scripts"` without `allow-same-origin` plus a restrictive CSP
(`ReportFrame`, T-38), and the height-fit `postMessage` regression the `Accept:` line names was
never introduced because no height-fit script exists. Check both rather than assuming.

## S-30, if the curator sends you there instead

`glue/legacy/scope_resolution.rb` was authorised for deletion, attempted, and **reverted on a
measurement**. Read §Findings **S-30** before touching it. The production argument is sound —
after T-26a nothing constructs a render without an owned `RenderContext` — but the DB-less tag
suite uses that path as its harness, and removing the branch is **166 of 249 examples red**.
Its shape: rewrite the two tag specs onto `RenderContext`, delete the six-source examples with
an argued list of what coverage went, then delete `glue/`, `#legacy_bind`, `LegacyHost`,
`test/unit/golden_scope_fixture_test.rb` (it `include`s the module, so deleting it is a LOAD
failure taking all twelve of its methods) and the `no_thread_local` exemptions.
**`spec/golden/scope/scope.jsonl` must survive whatever happens to its subject** — it is the one
artefact in this repository that cannot be regenerated.

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
- **`ZERO_REPORTER_MODE=strict` is at 6 files** — see T-27 above, which is where the decision
  belongs.
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
