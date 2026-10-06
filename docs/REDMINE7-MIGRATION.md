# Redmine 7 migration: redmine_reporter_dashboards

Start a Claude Code (or Codex) session on this repository, branch `redmine70-migration`, with:

> Read CLAUDE.md and docs/REDMINE7-MIGRATION.md, then carry out the Redmine 7 migration of this
> plugin as described there, on branch redmine70-migration. That includes the plugin's tests on
> PostgreSQL and MariaDB, every function exercised end to end on a real running Redmine in a
> browser (with and without permissions, failure paths included) with screenshots you looked at,
> and an OpenAI review of the diff when OPENAI_API_KEY is set. Report to me in Dutch at the end.

This file is the plan and the memory of that work. Update it as you go: verdicts, results,
what is left. Written 2026-10-06 from a measured analysis (report at the bottom).

## Status

| | |
|---|---|
| Plugin id | `redmine_reporter_dashboards` |
| GEOxyz runs today | `claude/next-session-prompt-it4too` |
| Upstream | geen |
| Runs on Redmine 7 as is | JA |
| Upstream sync | GEEN UPSTREAM |
| After sync | n.v.t. |
| Complexity (1 trivial .. 5 rewrite) | 1 for Redmine 7; the session found and fixed MariaDB and Redmine 5.1 defects next to it |
| Measured on | Redmine 7.0.1 (7.0-stable-GEOxyz 8067e23), Rails 8.1.3.1, Ruby 3.3.6, PostgreSQL 16 and MariaDB 10.11; Redmine 5.1-stable-GEOxyz (bcf917c), Ruby 3.2.6, PostgreSQL 16 |
| Migration session | 2026-10-06, done: work list closed, tests green on both databases, e2e green on both, reviews resolved (see "Verdicts" and the sections after it) |
| Branch head | see `git log`; the session's last code commit is `121c1dc` |

## Already on this branch

- `4c43d3c` Declare rexml as a test dependency for the SVG chart specs
- Migration session 2026-10-06, one concern per commit:
  - `86c74b3` Tooling: clone 7.0-stable-GEOxyz (`REDMINE_REPO_URL`), and never load another adapter's schema.rb
  - `9380ddd` Share-link concurrency test: run on MariaDB instead of hanging the suite
  - `ca33c96` Liquid 5.14.0: add it to the reviewed filter surface
  - `68baafa` Register Liquid tags through `Compat.register_liquid_tag` (no deprecation at boot, ready for Liquid 6)
  - `6000e85` Template: refuse content the database column cannot hold, instead of a 500
  - `dda0cfe` Tests: make the full-app suite pass on MariaDB (+ e2e scenarios)
  - `322e9b9`, `e997540`, part of `e047c62` Admin menu: Render preflight gets a core sprite icon (`checked`, present on 6.0, 6.1, 7.0)
  - `c4d91f5` Share links: show a new link's URL once, not also as a raw flash box
  - `6a323c8` e2e scenarios that pass on a real Redmine 7; smoke handles downloads
  - `673f23d` Tooling: start_server.sh writes file mail delivery for the server env only
  - `e047c62` Fixes from the independent review
  - `121c1dc` Gemfile: Liquid below 5.6 on Ruby older than 3.3, so Redmine 5.1 renders at all

## Work list for the migration session

In this order: things that break, security, the GEOxyz changes, the open items, then the checks.

**Priority items**

1. Nothing to migrate in the code. To switch production from main to the new line: merge claude/next-session-prompt-it4too (plus 4c43d3c, the rexml test gem) into main when the curator decides.
2. Liquid 5.14.0: add it to the reviewed list in spec_liquid or pin Liquid below 5.14.

**Open items from the analysis** (Dutch; where they conflict with a decision or a priority item above, those win)

3. commit 4c43d3c (rexml test-gem; zonder faalden 12 SVG-chart-specs op 7.0) overnemen in claude/next-session-prompt-it4too
4. curator: '5.14.0' aan PINNED in spec_liquid/filters_spec.rb toevoegen (zelfde 61 filters als 5.13.0) of liquid op < 5.14 zetten
5. voor Liquid 6: Template.register_tag (lib/redmine_reporter_dashboards.rb:407) vervangen door Environment#register_tag
6. charts en mermaid in een echte browser op 7.0 verifiëren (RRD_CONFORMANCE=1 render-smoke); Chart.js wordt zelf meegeleverd (v4.5.0 UMD) en in de sandbox-iframe geïnlined, dus #44018 raakt de plugin niet
7. stille breuk tussen plugins: todolists_with_positions van redmine_issue_todo_lists2 hangt alleen aan RedmineCrm::Liquid::IssueDrop; reporter_dashboards-sjablonen die het gebruiken renderen leeg

**Checks**

8. Run the plugin's whole test suite on Redmine 7.0-stable-GEOxyz with PostgreSQL AND MariaDB, and once on 5.1-stable if the branch is meant to stay 5.1-compatible.
9. Check Redmine 7 webhooks against this plugin (see "Rules"), and note the result here even if nothing is needed.
10. Verify every feature of the plugin by hand on a running Redmine 7 (screenshots).

### Verdicts (migration session 2026-10-06)

| # | Verdict |
|---|---|
| 1 | Open, the curator's call: merging into main is not done here. This branch is `claude/next-session-prompt-it4too` + the plan + this session's commits (see Q4). |
| 2, 4 | Done, both halves, because a measurement made the choice: 5.14.0 is in `PINNED` (`ca33c96`, same 61 filters, its one change tightens resource accounting) and stays what Redmine 7 (Ruby 3.3) resolves; Ruby < 3.3 is capped below 5.6 (`121c1dc`), because there Liquid ≥ 5.6.1 cannot parse anything (see "After the upgrade"); 5.5.1 is in `PINNED` too (a strict subset of 5.13.0's filters). |
| 3 | Done on this branch (`4c43d3c`); carrying it into the dev branch is part of item 1. |
| 5 | Done (`68baafa`): `Compat.register_liquid_tag`, `Environment.default` on 5.5+, `Template.register_tag` on 4.x and 5.0–5.4. The boot deprecation is gone (0 lines in the PostgreSQL run log, it printed at every boot before). spec_liquid green on 4.0.4, 5.5.1 and 5.14.0. |
| 6 | Done. In the browser on Redmine 7 (production mode, both databases): bar and pie charts (bundled Chart.js) and the Mermaid diagram draw in the sandboxed frame on the template page, the preview, the dashboard widget and the My page block; PDF via headless Chromium (`chromium_cdp` Chrome 141) for template, widget, mail, schedule and share link. Render conformance corpus (`RRD_CONFORMANCE=1 rspec spec/conformance`, non-root): chromium_cdp and Gotenberg (docker, pinned digest) all pass; wkhtmltopdf fails 4 corpus cases with Ubuntu's apt build (not the patched-Qt build CI uses), engine-level and independent of Redmine, so G9's matrix diff could not be regenerated here. |
| 7 | Measured, not built; open question Q3. With `redmine_issue_todo_lists2` installed and issue #1 on a list, `{{ issue.todolists_with_positions.size }}` prints nothing in this plugin's templates (`docs/e2e/together/todolists-with-positions-preview.png`), no error, no lint finding. The todo plugin extends only `RedmineCrm::Liquid::IssueDrop`, which does not exist without redmineup. |
| 8 | Done, numbers below. Redmine 5.1 run included: it found the Liquid/strscan break (fixed). |
| 9 | Checked, nothing needed: the plugin patches only `Project`, `ProjectsHelper` and `Role` (`lib/redmine_reporter_dashboards/patches/`), adds no issue fields, hides no issue data and has no issue API view. Core webhook payloads (`issues/show.api.rsb` as the webhook owner) are unaffected. |
| 10 | Done: 8 scenario files, every function below, on both databases. |

### Test results (final code, Redmine 7.0-stable-GEOxyz, Ruby 3.3.6)

| Suite | PostgreSQL 16 | MariaDB 10.11 |
|---|---|---|
| rspec `spec/` (no DB) | 2954 examples, 0 failures, 106 pending | 2954, 0 failures, 106 pending |
| rspec `spec/adapter` (real DB) | 260, 0 failures, 9 pending | 260, 0 failures, 3 pending |
| golden corpus (pinned 2025-12-29) | 217, 0 failures | 217, 0 failures |
| minitest units / functionals / integration | 605 / 456 / 58 runs, 0 failures, 0 errors, 0 skips | 605 / 456 / 58 runs, 0 failures, 0 errors, 0 skips |
| system tests (Chromium 141 + chromedriver 141) | 12 runs, 0 failures | 12 runs, 0 failures |
| spec_liquid (Liquid 5.14.0) | 373, 0 failures | 373, 0 failures |
| migrations down to 0 and up (`script/migrate_updown.sh`, both arms) | OK | OK |
| reversibility gate | OK, 10 migrations, 0 findings | |

Baseline before any change (same checkout): PostgreSQL 1113 minitest runs green, rspec green,
spec_liquid 1 failure (the 5.14.0 review gate). MariaDB: the unit run **hung** (the
share-link concurrency test, `9380ddd`), and once unblocked gave 18 failures and 23 errors, all
test-portability problems except one product defect (template content over 64 KiB → 500,
`6000e85`); CI never ran the full-app suite on MariaDB. Pending examples are the ones that need
an env var (browser corpus, Gotenberg, git history, benchmark); MariaDB has 3 instead of 9
because the MySQL-only adapter cases run there.

Redmine 5.1-stable-GEOxyz, Ruby 3.2.6, PostgreSQL (with `Gemfile.local`
`gem 'activerecord-session_store'`, which that branch's `config/application.rb` needs):
before `121c1dc` 44 failures, 27 errors and spec_liquid 275/373 failing (Liquid 5.13/5.14 on
Ruby 3.2); after it 2954 / 260 / 217 specs, 605 / 456 / 58 minitest runs (1 pre-existing
reasoned skip), spec_liquid 373, all 0 failures.

Together with `redmine_issue_todo_lists2` (its `redmine70-migration` branch, PostgreSQL): boot,
migrations, smoke 30 pages, core flows and all plugin scenarios green (`docs/e2e/together/`).

### End to end on a real Redmine 7 (production mode, seeded, as an unprivileged user)

`./.codex/start_server.sh --reset` + `./.codex/e2e.sh`, once per database, both on the final
code: **smoke 30 pages, core flows 6, 8 plugin scenarios with 56 screenshots, 0 problems** on
PostgreSQL (`docs/e2e/postgresql/`) and on MariaDB (`docs/e2e/mariadb/`). Every screenshot was
opened; findings from looking at them are in this file (share URL twice, missing menu icon,
blank frame captures that turned out to be capture timing). `docs/e2e/before/` holds the two
Redmine 7 pictures before the UI fixes. No Redmine 5.1 "before" pictures: no layout changed
except those two, and on 5.1 the admin menu has no icons and the flash code is the same (read
on 5.1-stable).

Functions, how they are reached, and where each is proven (scenario `test/e2e/<file>.mjs`,
screenshots `docs/e2e/<db>/<file>-*.png`, captions in `<file>.md`):

| Function | How a user reaches it | Scenario | Paths covered |
|---|---|---|---|
| Project dashboard page | Project menu "Project dashboard" (module + `view_reporter_project_page`) | dashboard | manager sees it; reporter: no menu item, 403; outsider on private project: 403; anonymous: login |
| Dashboard tabs (add) | "Add tab" in the tab bar → settings box (`manage_reporter_project_tabs`) | dashboard | tab created and selected |
| Widgets: add, move, remove | "Add" picker, arrows, close icon (`manage_reporter_project_page`) | dashboard | issue query, activity, spent time, issue report; move; remove |
| Report widget + its PDF | Report widget settings → template; PDF icon | dashboard | renders charts + Mermaid; PDF 33 KB `application/pdf` |
| Project settings tab "Reports and dashboards" | Project → Settings | templates | manager sees links; reporter 403 |
| Report templates: list, new (starter gallery), preview, create, show, edit, delete | Settings tab → Report templates | templates | unsaved preview (HTML + PDF); syntax error shown, no 500; create without name → error box; edit stored; delete with notice; reporter 403; outsider 403 |
| Template document (PDF) and export (JSON) | "Download as PDF", "Export" | templates | PDF 33 KB; JSON with the template |
| Template import (bundle) | rake `import:plan` / `import:run`; the "Import a report template" form on the list | rake_tasks | plan, missing file refused (exit 2), run into the private project. The upload form is shown (templates-index) but was not submitted in the browser; its controller path has functional tests |
| Ad hoc mail of a report | Template page → "Send report by e-mail" (`mail_reporter_dashboards_reports`) | delivery | no recipient → refused, nothing sent; sent with PDF attached; mail log; reporter 403 |
| Report schedules: list, new, create, show, edit, delete, test send | Settings tab → Report schedules | delivery | end date before start → refused; weekly created; test send (confirm) writes 1 mail; edited; deleted (404 afterwards); reporter 403; outsider 403 |
| Scheduler (cron) | `rake reporter_dashboards:schedules:run` / `:status` | rake_tasks | status warns before first run (exit 1, by design); run delivers 1 mail with PDF; second run same day delivers nothing; run row shown in the browser |
| Share links: list, new, create, revoke; public `/reporter/s/:token` | Template page → "Share links" (`share_reporter_dashboards_reports`, public needs `publish_…`) | share_links | URL shown once; non-public link: anonymous → login, member → PDF; public link anonymous → PDF; single-use second open refused; revoked refused; unknown token 404; reporter 403 |
| My page blocks "Issue report", "Spent time report" | My page → Add | my_page | both render for manager; reporter is offered no project/template (fails closed) |
| Plugin settings | Administration → Plugins → Configure | admin | page renders, save round-trip with notice; non-admin 403 |
| Render preflight | Administration → "Render preflight" | admin | Chromium probe: every check passed; non-admin 403 |
| Statistics JSON `/sql/stats/monthly_flow` | GET with `project_id`, `months` (logged in) | admin | visible project JSON; months capped at 24; unknown project 404; private project as outsider 404; anonymous refused |
| Liquid tags `sql_aggregate`, `version_rollup`, `chart`, `mermaid` | In templates | templates, dashboard, my_page | rendered in the seeded report on screen and in PDF |
| Rake: migrate_from_reporter plan, lint_templates, export bundle, documents purge (dry run), render preflight | Command line | rake_tasks | all exit as documented (`rake_tasks-commands.md`) |
| Mail in / REST API / webhooks | none in this plugin | - | n.v.t. |

Not covered, out of reach here: a real SMTP relay (mail went to files), Gotenberg as the
selected engine inside Redmine (it was exercised by the conformance corpus, not by the server),
real production templates (Q3).

### Reviews

- Own review: done while working (the adversarial re-read caught the MariaDB TEXT "off by one",
  which measurement then refuted: MariaDB trims the YAML dump's trailing newline; no change made,
  a test documents it).
- Independent review by a fresh subagent: 2 blockers, 5 should-fix, nits. Fixed in `e047c62`:
  `shield-check` absent on Redmine 6.0 (now `checked`, test checks the running sprite), project 1
  left archived by the non-transactional import test, validation not exercised in PostgreSQL CI
  (stubbed limit test added), `description` also a text column (covered), vacuous deprecation
  test (fixed, now fails if reverted), comment in the share-link controller, duplicated helper.
  Not changed, with reason: a non-String flash value for the share URL (it would raise in 5.1's
  `render_flash_messages`, read on 5.1-stable); deriving the 64 KiB settings cap from the column
  (measured working on MariaDB, test pins it); `:too_long` says "characters" for a byte limit
  (same message the tab model already uses, no new locale keys); e2e `if (count)` branches (each
  has an `else fail`).
- OpenAI review (`./.codex/openai_review.sh`, gpt-5): two rounds, one finding each, both the
  same false claim (`content_changed?` / `attribute_changed?` missing on Rails 8.1), refuted by
  measurement; resolutions in `docs/reviews/openai-2026-10-06-*.md`. Third round on the final
  head (`2afe62b`): "No findings."

### Findings recorded, not fixed (outside the migration's scope)

- **Every chart report shows "Parts of this report could not be produced as asked"** with
  default settings: the bundled Mermaid (3.5 MB) is above the 512 KB inline threshold. It is a
  notice, the report is complete. Same on every Redmine version (asset policy, not Redmine). UX
  worth a look: the notice reads like an error to a reader of a correct report.
- **Next run shows "-" for an enabled schedule until the first scheduler run** (it is computed
  by the runner). Correct but uninformative.
- **The admin menu icon `checked` is drawn dark**, like core's other glyph icons; fine, noted.
- **CI runs the full-app suite on PostgreSQL only**, which is why the MariaDB hang and failures
  above went unseen. Recommend a MariaDB leg in the `test` job (Actions are manual-only per the
  rules; `ci.yml` still has push/pull_request triggers, untouched here).
- **wkhtmltopdf conformance** needs the patched-Qt build; Ubuntu's apt build fails 4 cases.
- **Tooling** (`.codex/`): `rsync` and `rexml` gaps, and the session's three fixes are in the
  commits above; `test_setup.sh` still appends `rails-controller-testing` that the plugin Gemfile
  also declares (bundler warns about a duplicate, harmless).

## Open questions for Jan

Taken unattended, each built the way most likely right for GEOxyz and losing nothing:

- **Q1. Liquid version policy.** Options: (a) as built: 5.14.0 on Ruby ≥ 3.3, < 5.6 (5.5.1) on
  Ruby < 3.3; (b) one cap for all, < 5.6 (loses 5.14's range-accounting fix on Redmine 7 for no
  measured reason); (c) no cap (5.1 hosts break on the next `bundle update`). Recommendation: (a).
- **Q2. Templates over 64 KiB on MariaDB.** Built: a validation message instead of a 500;
  PostgreSQL unchanged. Alternative: widen `content`/`description` to MEDIUMTEXT on MySQL the way
  core does for `issues.description` (`limit: 16.megabytes`), which needs a `change_column`
  migration the project's reversibility gate (G11) forbids today. Recommendation: keep the
  validation unless GEOxyz runs MariaDB in production and has templates that large; which
  database does production use?
- **Q3. `todolists_with_positions` in reports.** Not built. Options: (a) `redmine_issue_todo_lists2`
  also extends this plugin's `IssueDrop` (the fix belongs there; this plugin has no drop
  extension point yet); (b) this plugin adds the accessor when the todo plugin is present (new
  drop surface, visibility to decide); (c) document it. Recommendation: first grep the production
  templates (`rake reporter_dashboards:migrate_from_reporter:plan` lists accessors, or SQL on
  `report_templates.content LIKE '%todolists_with_positions%'`); if any use it, (a).
- **Q4. Branch.** The task named `redmine70-migration`; the session-start hook pins
  `claude/next-session-prompt-it4too` and moved the session there; the session moved back
  because the task (with commit authority) named this branch explicitly. `CLAUDE.md`'s pin was not
  edited. Merge order suggestion: this branch into the dev branch, then the dev branch into main.
- **Q5. Admin menu icon.** `checked` was chosen (exists on 6.0/6.1/7.0). Any preference?

## GEOxyz changes to review or re-apply

Own plugin: all of it is GEOxyz code, so there is nothing to re-apply. While migrating, hold the code you touch to the rules below; list larger quality problems you find in the work list instead of fixing them in passing.

## After the upgrade (production)

Actions the person doing the upgrade must take, or know about, for this plugin:

- **`bundle install` after deploying this branch.** The plugin Gemfile now picks Liquid by Ruby
  version: Ruby 3.3+ (Redmine 7.0) resolves `liquid` 5.14.0; Ruby < 3.3 resolves 5.5.1. Nothing
  else changes in the bundle.
- **Ruby 3.2 hosts (Redmine 5.1, until the switch): run `bundle install` with this branch, or at
  least make sure Gemfile.lock does not hold Liquid 5.6.1 or newer.** With those, every report
  template fails to parse on Ruby 3.2 (`undefined method 'peek_byte' for StringScanner`). A host
  whose lock was written before Liquid 5.6.1 was released is not affected today, but any `bundle
  update` there would have broken all reports. Check: `grep '    liquid (' Gemfile.lock`.
- **No migration.** The schema is unchanged; `rake redmine:plugins:migrate` is a no-op for this
  plugin. Down/up was run on PostgreSQL and MariaDB (`script/migrate_updown.sh`: OK, both arms).
- **PDF engine**: the default engine is headless Chromium on the Redmine host and it refuses to
  run as root (it never sets `--no-sandbox`, on purpose). Redmine must run as an unprivileged
  user, as it normally does under Passenger or Puma. Measured: as root every PDF fails with
  `engine_crashed ... Running as root without --no-sandbox is not supported`.
- **Scheduled reports still need the cron entry** (`rake reporter_dashboards:schedules:run`,
  README). `schedules:status` exits 1 with a warning until the first run; that is by design.
- **MariaDB/MySQL**: a report template larger than 65 535 bytes (or a description over it) is now
  refused with a validation message instead of a 500 on save. PostgreSQL is unchanged (no limit).
  If GEOxyz has templates near that size on MariaDB, see "Open questions for Jan" (Q2).
- **Templates using `issue.todolists_with_positions`** (from `redmine_issue_todo_lists2`) render
  that part empty in this plugin; grep production templates before the switch (Q3).

## How to test

This repo has its own test tooling and CI: follow its CLAUDE.md for the suites. For the real Redmine and the browser checks, use the shared scripts in `.codex/` against the Redmine checkout your tooling made (`REDMINE_DIR=<that checkout>`; it needs a `test` entry in its config/database.yml):

```sh
./.codex/start_server.sh       # real Redmine (production mode) with this plugin, seeded users and projects
./.codex/e2e.sh                # browser: smoke over the plugin's pages, core issue flows, test/e2e/*.mjs
./.codex/openai_review.sh      # independent OpenAI review of the diff, only when OPENAI_API_KEY is set
```
Write one scenario per function in `test/e2e/<function>.mjs` (example at the top of
`.codex/e2e/lib.mjs`); screenshots and a table per scenario land in `docs/e2e/`. Users:
`admin`, `manager` (every permission), `reporter` (no plugin permissions), `outsider` (no
membership); password `Redmine7Test!`. Needs Node with Playwright and Chromium
(`npm install -g playwright && npx playwright install --with-deps chromium`).

The coordinator's harness (`plugin-check.sh` in the migration kit, kept outside this repo) adds a
browser smoke test of every page the plugin adds and runs all GEOxyz plugins together; the
results quoted in the analysis come from it.

Notes from the 2026-10-06 run, for whoever repeats it here:

- `REDMINE_REPO_URL=https://github.com/jcatrysse/redmine ./.codex/redmine_clone.sh 7.0-stable-GEOxyz`
  clones the GEOxyz branch; switching `RRD_DB` needs `bundle install` in the checkout (Redmine
  picks adapter gems from database.yml).
- Run `start_server.sh` and `e2e.sh` as an unprivileged user (the PDF engine refuses root),
  e.g. `su rrd -c '... ./.codex/start_server.sh --reset'`, with `PLAYWRIGHT_BROWSERS_PATH` set.
- The system tests need a chromedriver matching the Chromium (141 here, from
  chrome-for-testing), `RAILS_ENV=test`, `RRD_CHROME_PATH` and `GOOGLE_CHROME_OPTS_ARGS`.
- `script/migrate_updown.sh` needs a test database built by migrating, not by `db:schema:load`
  (the latter does not record the plugin's versions, and VERSION=0 then reverts nothing).
- Re-running the e2e set on a database not reset since the last run fails by design in two
  places: today's schedule is already delivered, and My page blocks are already placed.

## How the migration session works (same for every plugin)

1. **Start**: `git fetch && git checkout redmine70-migration && git pull`. Read this whole file,
   including the analysis report at the bottom. Do not reopen decisions recorded here.
2. **Baseline, before you change anything**:
   - the plugin's tests on Redmine 7.0-stable-GEOxyz with PostgreSQL and with MariaDB;
   - a real running Redmine with this plugin (`./.codex/start_server.sh`) and the browser run
     (`./.codex/e2e.sh`: smoke over every page the plugin adds, plus the core issue flows).
   Write the numbers here. Something already broken now is a finding, not your regression.
3. **Inventory of functions**: list every function of the plugin in this file, in a table
   "function | how a user reaches it | scenario | screenshot". Take them from the README,
   `init.rb` (permissions, menus, settings, project modules), routes, hooks and view
   overrides, macros, mail handling, API endpoints, rake tasks and cron jobs. This table is the
   coverage list for step 8; a function that is not in it will not be tested.
4. **GEOxyz changes**: go through the table above, one item at a time. Each kept or re-made change
   is its own commit with a test that proves it. Record the verdict in the table.
5. **Work list**: then the numbered list, in order. One concern per commit.
6. **Portability**: everything must run on Redmine's supported databases (PostgreSQL,
   MySQL/MariaDB; SQLite where the plugin already supports it). Migrations must be reversible and
   are run down and up on PostgreSQL and MariaDB.
7. **Together**: run with the other GEOxyz plugins installed (the migration kit's harness, or
   `RMP_EXTRA_PLUGINS`). A failure that only appears in combination is a finding to record here.
8. **End to end, visually, every function**: on the real Redmine from `start_server.sh`
   (production mode, the way GEOxyz runs it), write one scenario per function in
   `test/e2e/<function>.mjs` with `.codex/e2e/lib.mjs` and run them with `./.codex/e2e.sh`.
   - Each function as the users that matter: `admin`, `manager` (every permission, the
     plugin's included), `reporter` (member without the plugin's permissions), `outsider`
     (no membership, private project must stay invisible).
   - The failure paths too: setting off, permission absent, empty state, invalid input, the
     value that used to raise. A refusal that is shown is evidence as much as a success.
   - One screenshot per function and per path, with a caption saying what it proves. Open
     every screenshot and look at it: a picture nobody looked at proves nothing. Commit them
     in `docs/e2e/` and list them in the inventory table.
   - Functions without a page (mail in and out, REST API, rake tasks, cron, webhooks): exercise
     them against the same running instance (mails land in `redmine/tmp/mails`, `t.mails()`
     reads them; API through `t.page.request`) and record command and result.
   - Before pictures where behaviour or layout changes: the branch GEOxyz runs today, on
     Redmine 5.1, same scenarios, `RMP_E2E_OUT=docs/e2e/before`.
   - Run the whole e2e set once on MariaDB as well (`RMP_DB=mariadb`, then `start_server.sh --reset`).
9. **Independent review**: first your own, adversarial: re-read the whole diff as if someone
   else wrote it and you are paid to reject it. Then, **when `OPENAI_API_KEY` is set in the
   session**, `./.codex/openai_review.sh`: it sends the diff of this branch to an OpenAI model
   and writes `docs/reviews/openai-<date>-<sha>.md`. Every finding gets a `Resolution:` line
   there (fixed in <commit>, with a test, or why not). Fix, re-run the tests and the e2e set,
   and run the review again until it has nothing new that you accept. Without the key: write
   "OpenAI review: skipped, no OPENAI_API_KEY" in the report; never send code anywhere else.
10. **After the upgrade**: anything the production upgrade must do for this plugin (data fixes,
    settings, cron, files, removed features) goes into the section "After the upgrade".
11. **Finish**: update "Status", the inventory and the work list in this file, push
    `redmine70-migration`, and report: what changed, test numbers on both databases, e2e
    numbers (scenarios, screenshots, problems), the review result, what is left, what needs Jan.

### Stop and ask Jan when
- a GEOxyz change would be lost or behave differently for users;
- a new gem, a new setting with user impact, or a schema change not required by Redmine 7 seems needed;
- the change would send data to an external service (the OpenAI review of the code diff is the
  one exception Jan approved, and only when the key is present);
- upstream and GEOxyz disagree on behaviour and both are defensible.

## Rules

- **Target**: Redmine 7.0-stable-GEOxyz (https://github.com/jcatrysse/redmine), Rails 8.1, Ruby 3.3+.
  Core sources for comparison: branches `5.1-stable`, `6.1-stable`, `7.0-stable`, `7.0-stable-GEOxyz`.
- **Evidence**: never report a test, lint, browser check or review as passed without having seen
  it. Quote the summary lines; list the screenshots. "Should work" is not a result, and a green
  test suite is not proof that a feature works in the browser.
- **Tests**: never skip, delete or weaken a test. A test that encodes Redmine 5 markup or
  behaviour is updated to Redmine 7, with the reason in the commit. Every fix gets a test that
  fails without it.
- **Minimal diffs** in the plugin's own style. No reformatting, no unrelated refactoring.
  Something wrong elsewhere: write it down here, do not fix it in passing.
- **Security**: authorization on every action and entry point; `safe_attributes`, never
  `to_unsafe_hash` into `update`; no SQL built from params; no secrets in logs; no `html_safe` on
  user input.
- **Webhooks (new in Redmine 7)**: core sends issue payloads (core `issues/show.api.rsb`, rendered
  as the webhook owner) to webhook endpoints, past plugin hooks and controller patches. If the
  plugin hides, adds or changes issue data, make webhooks consistent with that or record why not.
- **Redmine 7 conventions**: SVG icons through `sprite_icon` (the `icon icon-*` CSS is gone),
  Propshaft assets under `assets/` (`/assets/plugin_assets/<id>/...`), the new header and user menu,
  `ContextMenus::*Controller`, Loofah-based text formatting, Chart.js as an ES module, sudo mode
  (on by default: `t.sudo()` in a scenario). The breaker list is in the migration kit's CHECKLIST.md.
- **Locales**: keep the locales the plugin ships in sync; translate a new key by matching the
  closest existing key in the same file, not from scratch; do not add new languages.
- **5.1 compatibility**: prefer fixes that also run on Redmine 5.1 so they can be merged early;
  say so when a fix cannot.
- **Git**: work on `redmine70-migration` only; never push to the default branch; never force-push
  a branch someone else uses. Descriptive commit messages (what and why). Push after every
  commit, together with the updated status in this file: a cloud session can stop at a usage
  limit, and work that is not pushed is lost with its container.
- **GitHub Actions**: manual only (`workflow_dispatch`). Do not add push, pull_request or schedule
  triggers.

## Definition of done

- All items of the work list are done or explicitly deferred with a reason, in this file.
- The plugin's tests are green on Redmine 7.0-stable-GEOxyz with PostgreSQL and MariaDB
  (numbers in this file); boot, production-like eager load, migrations up/down OK.
- Every function in the inventory exercised end to end on a real running Redmine, with and
  without permissions and on its failure paths; `./.codex/e2e.sh` green; screenshots looked at,
  committed in `docs/e2e/` and listed.
- Review done: your own, and the OpenAI review when the key is present, every finding resolved
  in `docs/reviews/`.
- No new failure when run together with the other GEOxyz plugins.
- "After the upgrade" lists every action production needs; "Status" is current.


## Analysis report (2026-10-06, Dutch)

# redmine_reporter_dashboards
- Gebruikte branch: **`claude/next-session-prompt-it4too`** @ 3c75ecc (2026-09-20). Dat is de "nieuwe branch, niet main" van Jan. `CLAUDE.md` §9 en `docs/plan/NEXT-SESSION-PROMPT.md` pinnen hem als "the *only* branch this project develops on"; de merge naar main is de keuze van de curator. Hij staat 7 commits voor main en 0 achter: T-51/T-52 (welk project een rapport/widget telt, de my-page-widget faalt gesloten) plus planning. Geen migratiewijziging t.o.v. main. Plugin id `redmine_reporter_dashboards`, versie 0.5.0, `requires_redmine version_or_higher: '5.1'`.
- main @ c25753d (2026-09-16) is ook getest, zie §1.
- Upstream: geen. Eigen plugin; de importer leest tabellen van `redmine_reporter` maar deelt geen code.
- Fork t.o.v. upstream: n.v.t.
- Andere relevante branches: `claude/redmine-plugin-compatibility-p1cmbh` (0 voor, 17 achter main) en `claude/remine-plugins-compatibility-check-3oatr5` (0 voor, 33 achter). Al gemerged, niet relevant.
- Gemfile: `liquid '>= 4.0', '< 6.0'` (lost op 7.0 op naar 5.14.0); test: `rspec-rails`, `rails-controller-testing`. 10 migraties (alle `change`). Tests: minitest (1113 runs op de nieuwe branch, 1086 op main), `spec/` (87 bestanden, 2995 examples), `spec_liquid/` (370 examples).

## 1. Werkt out of the box op Redmine 7?   JA (plugin) - testsuite DEELS
Harness op `origin/claude/next-session-prompt-it4too` (3c75ecc):
```
OK   bundle
OK   boot: ... redmine_reporter_dashboards 0.5.0
WARN [DEPRECATION] Template.register_tag is deprecated. Use Environment#register_tag instead. (lib/redmine_reporter_dashboards.rb:407)
OK   eager load (production-like)
OK   plugin migrations (development)
OK   plugin migrations (test)
OK   minitest redmine_reporter_dashboards: 1113 runs, 5763 assertions, 0 failures, 0 errors, 0 skips
OK   smoke: 79/79 pages+actions without server error (19 plugin routes)
```
Harness op `origin/main` (c25753d): dezelfde regels, met `minitest: 1086 runs, 5638 assertions, 0 failures, 0 errors, 0 skips` en smoke 79/79.
- WARN: Liquid 5.14 deprecation op `Liquid::Template.register_tag` (`lib/redmine_reporter_dashboards.rb:407`). Geen fout: de Gemfile begrenst Liquid op < 6.0.
- 18x `INFO 404` op `/projects/geoxyz-verify/reporter/...` en `/reporter/s/1`: de module is niet actief in het smoke-project en record 1 bestaat niet. Verwacht.
- **rspec liep niet via de harness** (harness-defect, zie het eindbericht). Handmatig gedraaid in slot 4, met hetzelfde commando via `rspec-core/exe/rspec`: **2995 examples, 12 failures, 148 pending**, zowel op de nieuwe branch als op main. Alle 12 falen met `LoadError: cannot load such file -- rexml/document` in `spec/charts/golden_svg_spec.rb` (10) en `spec/charts/charts_spec.rb:398,459`. Oorzaak: de Gemfile van Redmine 5.1 declareerde `rexml` (`Gemfile:24`), die van 7.0 niet meer. Alleen de specs gebruiken REXML, de productiecode niet. De 148 pending wachten op een omgevingsvariabele: 75 RRD_CONFORMANCE (browser-corpus), 42 RRD_ADAPTER_URL, 11 Gotenberg, 12 git-history, 4 echte browser.
- Adapter-specs apart gedraaid tegen een wegwerp-PostgreSQL-DB in slot 4, met ActiveRecord 8.1: **260 examples, 0 failures, 9 pending** (7 alleen MySQL, 1 benchmark, 1 corpus-datum).
- **Chart.js (#44018):** geen probleem. De plugin gebruikt de Chart.js van Redmine niet. Hij levert zelf **Chart.js v4.5.0 UMD** mee (`assets/javascripts/vendor/chart.umd.js`, sha256 vastgelegd in `script/gates/vendor_integrity.sh`), en die zet `window.Chart` *binnen het rapportdocument*. `Charts::Binding` zet `<script src="/plugin_assets/redmine_reporter_dashboards/javascripts/...">` in de body (`lib/.../charts/binding.rb:156`). `Assets::Resolver`/`LocalStore` lost dat op vanaf schijf (de `assets/`-map van de plugin) en inlinet het in een `srcdoc`-iframe met `sandbox="allow-scripts"` zonder netwerk, of in de PDF. De hardgecodeerde prefix `/plugin_assets/` is dus een sleutel voor de resolver, geen URL die de browser ophaalt; die zou onder Propshaft ook niet bestaan. De gewone paginascripts gebruiken `javascript_include_tag ..., plugin:` en zijn Propshaft-proof. **Niet in een echte browser geverifieerd**: de render-smoke van de plugin (RRD_CONFORMANCE=1, Chromium) is hier niet gedraaid.
- `spec_liquid` (echte Liquid 5.14.0, `-r liquid`): 370 examples. Zonder `LANG` geeft dat 4 failures: 3 encoding (`"\xE2" on US-ASCII`), een omgevingskwestie, want CI zet UTF-8. Met `LANG=C.UTF-8` blijft **1 failure**: `spec_liquid/filters_spec.rb:144` "Liquid 5.14.0 has not been reviewed". Dat is een bewuste review-poort, en gemeten zijn de 61 filters van 5.14.0 identiek aan die van de gereviewde 5.13.0.

## 2. Upstream sync?   GEEN UPSTREAM

## 3. Werkt na sync op Redmine 7?   n.v.t.

## 4. Complexiteit en blokkers   score 1
- Blokkers: `Gemfile` - test-gem `rexml` ontbreekt op 7.0, 12 specs falen - gefixt in `4c43d3c`. Runtime-blokkers: geen.
- Stille breuken:
  - **Plugin-overstijgend:** `redmine_issue_todo_lists2` hangt zijn Liquid-methode `todolists_with_positions` alleen aan `RedmineCrm::Liquid::IssueDrop` (redmineup). Op 5.1 had GEOxyz `redmine_reporter` + redmineup; op 7.0 heeft reporter_dashboards een eigen drop-laag zonder todolist-methode (grep: 0 treffers). Een sjabloon dat `todolists_with_positions` gebruikt, rendert dan stil leeg. Of GEOxyz-sjablonen dat doen, is niet geverifieerd.
  - De deprecation van `Template.register_tag` wordt een fout zodra Liquid 6 binnenkomt. Nu niet, door de Gemfile-grens < 6.0.
- Overlap met Redmine 7 core: geen. 7.0 heeft geen rapport-sjablonen, dashboards of geplande rapporten.
- Open werk voor ansif:
  1. Commit `4c43d3c` (rexml in de test-groep, met guard tegen dubbele declaratie op 5.1) overnemen in de dev-branch `claude/next-session-prompt-it4too`. Die branch is niet aangeraakt; de curator beslist.
  2. Beslissing voor de curator: `'5.14.0'` aan `PINNED` in `spec_liquid/filters_spec.rb` toevoegen (zelfde 61 filters als 5.13.0), of Liquid in de Gemfile op `< 5.14` zetten. Niet zelf gedaan: het is een review-poort, geen bug.
  3. Voor Liquid 6: `Liquid::Template.register_tag` vervangen door `Environment#register_tag`, met een pad voor Liquid 4.
  4. Charts in een echte browser op 7.0 bekijken (dashboard met `{% chart %}` en `{% mermaid %}`, scherm én PDF), bv. met de render-smoke van de plugin (`RRD_CONFORMANCE=1`).
  5. Bestaande GEOxyz-rapportsjablonen greppen op `todolists_with_positions`.

## Branch redmine70-migration
- Basis: origin/claude/next-session-prompt-it4too @ 3c75ecc (geen upstream-merge)
- Commits: `4c43d3c` Declare rexml as a test dependency for the SVG chart specs
- Eindresultaat harness (`ROLLBACK=1`, `@redmine70-migration`):
```
OK   eager load (production-like)
OK   plugin migrations (development) / (test)
OK   rollback to 0 and back (redmine_reporter_dashboards)
OK   minitest redmine_reporter_dashboards: 1113 runs, 5763 assertions, 0 failures, 0 errors, 0 skips
OK   smoke: 79/79 pages+actions without server error (19 plugin routes)
```
  plus handmatig: rspec `spec/` **2995 examples, 0 failures, 148 pending**; `spec_liquid` (LANG=C.UTF-8) 370 examples, 1 failure (de Liquid-review-poort hierboven).
- Gecombineerde run met `redmine_issue_todo_lists2@origin/master` (SKIP_TESTS=1): boot, eager load, migraties OK, smoke 84/84.
- Rollback migraties: OK

