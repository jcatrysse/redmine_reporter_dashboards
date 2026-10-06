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
| Complexity (1 trivial .. 5 rewrite) | 1 |
| Measured on | Redmine 7.0.1 (7.0-stable-GEOxyz + latest 7.0-stable), Rails 8.1.3.1, Ruby 3.3.6, PostgreSQL 16 and MariaDB 10.11 |
| Branch head when this file was written | `7404135` |

## Already on this branch

- `4c43d3c` Declare rexml as a test dependency for the SVG chart specs

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

## GEOxyz changes to review or re-apply

Own plugin: all of it is GEOxyz code, so there is nothing to re-apply. While migrating, hold the code you touch to the rules below; list larger quality problems you find in the work list instead of fixing them in passing.

## After the upgrade (production)

Actions the person doing the upgrade must take, or know about, for this plugin:

- None known. Add here what the session finds.

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

