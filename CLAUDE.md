# CLAUDE.md — `redmine_reporter_dashboards`

**Working language: English.** Code, comments, commit messages, specs and locale keys are English;
locale *values* are in their own language (§10).

## What this repository is becoming

Today this plugin is an **addon** that hard-requires `redmine_reporter`, which in turn requires the
`redmineup` gem. The plan (`docs/plan/05-decision.md`, ADR-004) turns it into **one standalone
plugin** that owns its Liquid layer, its drops, its render path and its reporting surface, runs on
**Redmine 5.1 → 7.0**, and needs neither the base plugin nor the vendor gem.

The work order is `docs/plan/implementation-plan.md`, tasks **T-00 … T-38**. Do one task per branch.

**The specs are the contract.** If the code and the spec disagree, that is a finding to report — not
a licence to follow whichever is more convenient. If a spec is *wrong*, say so with evidence and
stop; do not quietly build the better idea.

---

## Roles — all four, every task

You operate as **four people in sequence**, and you are not finished until all four have run:

1. **Implementer** — writes the change and its tests.
2. **Independent Reviewer** — a strict senior reviewer *paid to reject the PR*.
3. **QA Engineer** — adversarial; paid to break it.
4. **UX / Product Consistency Reviewer** — labels, copy, I18n, flows, empty and error states.

**Use a fresh subagent for role 2 where one is available.** Self-review inside the same context is
measurably weaker — you will defend your own reasoning. If no subagent is available, run the review
anyway and **say in the output that it was self-review**, so the weaker evidence is visible rather
than implied.

## Hard rules

1. **No final answer until all four roles have run.** A completion claim without a review report and
   a QA report is not a completion claim.
2. **Never declare a test or lint result you did not observe.** Run it, or paste the exact command and
   stop at a pause point. "Should pass" is a forbidden phrase.
3. **Never claim a Redmine version works if CI did not run it.** This is INV-7 and it is the project's
   oldest broken promise. An untested configuration is unsupported — say so in the README rather than
   widening a claim.
4. **A failing test, lint offence, gate, or UI regression is a blocker.** Fix and re-review; do not
   defer, do not annotate, and never make a hard gate advisory to get to green (§7).
5. **Uncertain → look it up, then ask.** In this repo you *can* read the Redmine source (§4). Ask the
   human only for things you genuinely cannot reach: production data, a running container, a
   credential, or a judgement the specs leave open (§11).
6. **Small, reversible, readable, consistent with what is already here.** No half-finished refactor
   left in the tree. No second way of doing something that already has a way.
7. **Never resolve an open question silently.** `technical-spec.md` §12 lists 13 `[OQ]` items — **5
   still open** as of 2026-08-12; see §11.1 for which — and
   `claims.json` holds the open beliefs with their discriminators. Hitting one is a **report-and-ask**
   event (§11).
8. **Ordering constraints outrank task attractiveness** (§2).

---

## 1. Phase −1 — ordering guard (before anything else)

Read the task's `Deps:` line in `implementation-plan.md`. Then **refuse to start** if any of these
holds, and say which:

| Condition | Why it is a refusal, not a warning |
|---|---|
| The task touches `lib/sql_aggregation/**` or `scope_resolution.rb` and **T-01 has not landed** | T-01 freezes the golden corpus **and the scope fixture**. The numbers are regenerable from the `v0.5.0` tag; **the scope is not**, once `scope_resolution.rb` is deleted. Recovery would depend on a private repository |
| The task changes the aggregator and **T-03 has not landed** | the performance baseline cannot be measured after the aggregator changes. There is no way back to it |
| The task adds a table and is not shipping **T-36** (reversible migrations) in the same release | an unremovable schema is what the base plugin is criticised for in `technical-spec.md` §7 |
| A dependency in `Deps:` is unmerged | the plan's dependencies are ordering facts, not preferences |

`git log --oneline` and the presence of the fixture files are how you check this — not memory.

**Never delete `scope_resolution.rb`, `lib/sql_aggregation/*`, or any fixture until its replacement
and its frozen fixtures are committed and pushed.** Deletion is the one irreversible action in this
plan.

## 2. Phase 0 — context acquisition (mandatory)

Do this *per task*, scoped to the task. Do not front-load 1 500 lines of spec.

0. **Read `docs/plan/HANDOVER.md` first — it is short.** It records what was learned by
   *running* the plan rather than reading it: traps that produce a green run meaning
   nothing, code that looks like a violation and is deliberately untouched, environment
   quirks, and **which configurations have actually been executed**. Skipping it is how a
   session re-discovers the same trap or "fixes" work that is about to be deleted.
1. **Read the task** in `implementation-plan.md`: `Touches:`, `Deps:`, `Accept:`.
2. **Read the referenced spec sections** in `technical-spec.md`, and the FR numbers in
   `functional-spec.md`. Those FRs are your acceptance vocabulary.
3. **Find the real code** — do not assume the tree matches the spec's target layout; the spec
   describes where things are *going*.
   ```bash
   rg --files | rg 'sql_aggregation|liquid|report|dashboard' | head -50
   rg -n 'ScopeResolution|up_acts_as_list|redmineup|redmine_reporter' --stats
   ```
4. **Find the specs that already cover it**: `rg -n '<thing>' spec/ test/`.
5. **Check permissions, routes and views** for anything with a UI or controller entry point:
   `init.rb` (the `Redmine::Plugin.register` block), `config/routes.rb`, `app/views/`.
6. **Consult the Redmine source when the core API behaviour matters** (§4). `Query#as_params`,
   `Issue.visible`, `IssueQuery#base_scope` and the plugin-asset mirror all have undocumented
   semantics that differ across branches. Read them; do not infer them.

Proceed only when you could explain the change to the reviewer role without the word "presumably".

## 3. Phases 1–4

**Phase 1 — Implement.** The change, plus tests (unit and integration/system as appropriate), plus
docs and locales if behaviour changed. Minimal diff, existing patterns.

**Phase 2 — Independent Review.** Fresh subagent if available. Try to reject it. Concrete issues
only, each with a file and line. Look specifically for:
- missing `nil` handling, and *assumed* presence of a version, a query, a custom field, a role;
- wrong assumptions about the actor — `User.current` used ambiently where `RenderContext#actor`
  should be explicit (this is INV-1 and it is the easiest thing in the project to lose silently);
- **passes locally, fails in CI**: ordering, timezone, locale, random seed, DB cleanup, a fixture
  that is relative to *today*, a test that depends on another test having run;
- a control that was specified as mechanical and implemented as a comment.

**Phase 3 — QA, adversarial.** Write the failure-mode checklist first, then confirm each line is
covered by a test. Minimum: **one regression test per bug being fixed**, and **two edge/failure
cases** per behaviour added. With a UI: permissions, error messages, empty states, and the flow a
confused user takes. For anything with a limit, test **at** the limit and **one past** it.

**Phase 4 — UX / Product Consistency.** Labels and copy, I18n (§10), accessibility basics, view
consistency with existing partials, and whether the behaviour matches the FR text — including the
odd flows. For report output specifically, `technical-spec.md` §9b is the standard: **native chrome,
beautiful output**; one type scale shared by HTML and PDF.

---

## 4. Redmine and Rails specifics

**Version span: Redmine 5.1 (Rails 6.1) / 6.0 (7.2) / 6.1 (7.2) / 7.0 (8.1) — three Rails majors.**

- **Read the core source when in doubt**, at the branch you are targeting:
  <https://github.com/jcatrysse/redmine/tree/5.1-stable> ·
  <https://github.com/jcatrysse/redmine/tree/6.1-stable> — and the corresponding `6.0-stable` /
  `7.0-stable` branches. `.codex/redmine_clone.sh` clones from **upstream**
  `redmine/redmine.git`; the fork links above are for reading, not for building against.
- **This bullet's premise was checked on 2026-08-04 and was stale.** `.codex/redmine_clone.sh`
  accepts *any* branch that exists on the remote, `7.0-stable` included, and `ci.yml:51`/`:236`
  have carried `{ redmine: '7.0-stable', ruby: '3.4' }` all along. The real gap was elsewhere and
  is now fixed: `detect_ruby_version` derived the Ruby version by decrementing the Gemfile's upper
  bound, so Redmine 7.0's `ruby '>= 3.2.0', '< 4.1.0'` produced **Ruby 4.0** and local setup died.
  See `.codex/ruby_version.sh`. Verify a premise like this before acting on it.
- **Version divergence lives in `compat/`** — one module, one method per divergence, a comment naming
  the versions. Never a scattered `if Rails::VERSION`. There is a committed LOC budget on that
  directory and a gate that enforces it.
- **Permissions and authorization on every controller action and every UI entry point.** Not "the
  parent view already checks" — the action checks.
- **Strong params everywhere; no mass assignment.** Widget settings are typed and bounded, and
  over-limit input is dropped with a log line rather than stored (FR-15).
- **ActiveRecord:** no N+1 — `includes`/`preload` deliberately; transactional integrity where a
  multi-row write must not half-apply; **query count must not scale with issue count** (FR-48).
- **Visibility is not optional and not inherited from a parent scope.** Every aggregation starts from
  the *viewer's* visible scope. A permission grant never implies private issues or hidden trackers.
  When a visibility condition cannot be constructed, **fail closed** (INV-1/INV-3).
- **View partials follow the existing structure.** No duplicated markup; no plugin-local design
  tokens in chrome CSS — use Redmine's own classes and icon set per branch (`sprite_icon` on 6+).

## 5. Forbidden constructs

Each of these exists in the current or base code and is a **named defect** in the plan. Introducing
one — or leaving one in a file you touched — fails review.

| Construct | Why | Instead |
|---|---|---|
| `rescue Exception` | swallows `SignalException`, `NoMemoryError`; the base plugin returns `e.message` *as document content* | rescue the specific class; return a typed `Failure` |
| an error rendered *as* the document | INV-5. A recipient gets a green-looking mail containing a broken report | `Failure{code, message, correlation_id}`; optional, clearly-labelled failure PDF (FR-59) |
| `Digest::MD5` for anything security-bearing | the base plugin's share tokens never expire and are MD5 | store the token **digest**, compare in constant time, mandatory expiry (FR-51) |
| `YAML.load_file` + `constantize` | arbitrary class instantiation from file content | closed type map (FR-55) |
| `html_safe` outside the ≤2 files the gate allows | INV-9 | escape; `\| json` inside `<script>` (FR-19) |
| a JS array literal built by string concatenation | the whole class behind the escaping finding | `<script type="application/json">` data block (§6) |
| a fixed `javascript_delay` / `no_stop_slow_scripts: true` | a guessed delay with the engine's own runaway guard switched off | the readiness protocol (§5 *Readiness*) |
| `up_acts_as_list` or any `redmineup`/`Redmineup` reference | defined only in the vendor gem | the owned `Positioned` concern (T-04) |
| a bare `skip` | hides an unsupported configuration behind a green run | `skip "reason"`, and the total must stay ≤ the committed inventory |
| a fixture relative to `Time.now` / `Date.today` | the corpus changes daily, goes red for the wrong reason, and gets switched off within a week | a pinned reference date (T-01) |
| `serialize :attr, coder: X` **relying on the keyword being read** | **MEASURED 2026-08-04, and the original reason was wrong: Rails 6.1 accepts this line and round-trips identically** (`docs/plan/reference/verification-oq-a-serialize-oq-b-liquid.md`). Its signature is `serialize(attr_name, class_name_or_coder = Object, **options)`, so `coder:` is **silently discarded** and the `Object` default happens to select YAML anyway. The trap is therefore any coder that is *not* YAML: `coder: JSON` stores YAML on 6.1 with no error | the `compat/serialize.rb` shim — for this reason, not the retracted one. `reporter_project_tab.rb:9-10` is **not** a defect and OQ-A does **not** falsify the 5.1 claim |
| a swallowed `NameError` / `rescue nil` around a registration | this is precisely how the `up_acts_as_list` coupling stayed invisible | let it raise, or log and degrade *visibly* |

Greps worth running before you open a PR:

```bash
rg -n 'rescue Exception|rescue nil|html_safe|Digest::MD5|constantize|YAML\.load' app lib
rg -n 'redmineup|up_acts_as_list' app lib db config init.rb
rg -n '^\s*skip\s*$|skip\s*$' spec test
rg -n 'Time\.now|Date\.today|Time\.zone\.now' spec test | rg -v 'travel_to|freeze_time'
```

Note: a grep for `redmine_reporter` matches this plugin's **own** name. Use a negative lookahead —
`redmine_reporter(?!_dashboards)` — or you will chase 400 false positives, which is why the
`zero_reporter` gate is written that way.

## 6. Determinism

The suite must be reproducible on someone else's machine in another timezone with a different random
seed.

- **Time:** `travel_to` / `freeze_time`, never a bare `Time.now` in an expectation. The aggregation
  corpus is **pinned to a reference date** (T-01).
- **Ordering:** every collection assertion has an explicit `order`. Postgres, MySQL and MariaDB do
  not agree on unordered row order, and this project runs all three.
- **Locale and timezone:** set them in the test, do not inherit them.
- **Random:** no `rand`/`sample` in a fixture. Covering arrays are generated deterministically.
- **DB cleanup:** never depend on another test having run, or on the order they run in.
- **`fail-fast: false` on every CI matrix**, or you cannot see which engine broke.

## 7. Quality gates

**G1–G6 are the general gates. G7–G12 are this project's, and they are not tests** — a green suite
tells you nothing about them.

| # | Gate | Evidence required |
|---|---|---|
| **G1** | Correctness: requirements and edge cases handled; failure modes safe and typed | the FR numbers, each with the test that covers it |
| **G2** | Tests green | pasted output of the real command (§8) |
| **G3** | Lint/style clean, consistent with the repo | pasted output, or a stated "no linter configured for this path" |
| **G4** | UX: flows work, copy consistent, empty and error states handled, I18n used | §9b's checklist plus the locale diff |
| **G5** | Security: authorization per action, no secret logged, no injection, visibility fail-closed | the permission test per entry point; the multi-actor case |
| **G6** | Performance: no N+1, no query count scaling with issue count, no unbounded output | query-count assertion, not an eyeball |
| **G7** | **Byte-identity** of the ported aggregation kernel — `git diff --no-index` against the `v0.5.0` blob is **empty**, not "whitespace-only" | the `corpus` job output |
| **G8** | **Zero-reporter / layer purity** — no reference to the base plugin or the vendor gem outside a shrinking allowlist, each entry carrying a reason | the `gates` job output |
| **G9** | **Support matrix is generated from the run**, and the committed file matches | the lint that diffs them |
| **G10** | **No bare `skip`, and the skip total is ≤ the committed inventory** | the run-level check, not the grep alone |
| **G11** | **Migrations reverse** — up → `VERSION=0` → schema equals the pre-install dump (`plugin_schema_info` included, `reporter_project_tabs` still present) → up again idempotently | the `migrate-updown` job |
| **G12** | **Capability three-state rule** — an *undeclared* capability **skips with a reason**; a *declared* capability that fails is a **hard failure** | the `render-smoke` output |

**Advisory is not a gate, and a gate is not advisory.** The perceptual/pixel diff, the build-readiness
score, and the usability walkthrough are **advisory — non-deterministic — not a correctness
guarantee**: never report them as PASS/FAIL. Conversely, never reclassify G7–G12 as advisory to reach
green. If a hard gate cannot pass, that is the finding.

**If you cannot verify a gate, you must stop at a pause point** — state which gate, the exact command,
and what output would satisfy it. A gate you could not check is reported as `UNVERIFIED`, never as
PASS.

## 8. Commands — the repo's own scripts, no invented steps

```bash
# 1. clone Redmine and mirror the plugin into it (per branch)
./.codex/redmine_clone.sh 5.1-stable       # also: 6.0-stable, 6.1-stable
                                           # 7.0 branch: see §4, must be added
# 2. install gems and prepare the test database
./.codex/test_setup.sh
# 3. run the plugin's suite
./.codex/test_plugin.sh
```

- **Edit the plugin repo, never `redmine/plugins/<name>/`.** Step 1 does
  `rsync -a --delete` into the clone; anything edited there is destroyed on the next run. Re-run
  step 1 to propagate.
- **The standalone run is the point of the project.** `redmine_clone.sh` copies a sibling
  `redmine_reporter` in to satisfy today's hard dependency. After T-05 lands, prove G1 by running
  **without** it: no `REPORTER_PLUGIN_PATH`, and `REQUIRE_REPORTER_PLUGIN=0`. A suite that only ever
  runs *with* reporter present cannot detect that the dependency came back.
- If a script fails, paste the **full** output and fix the code. Do not work around the script, and
  do not invent setup steps it does not perform.
- `bundle exec rspec` / `bundle exec rubocop` / `bundle exec rspec spec/system` where they apply;
  `.codex/check_ruby_floor.sh` exists today and is **deleted** by the floor decision
  (`technical-spec.md` §8) — do not extend it.

## 9. Commit and PR discipline

- **Work lands on the integration branch this project actually runs in**, currently
  `claude/plugin-repo-docs-setup-8u9k17`. Do **not** open a per-task branch or a pull request unless
  the curator asks.

  **This line used to read "One task per branch", and it cost a session.** That session read it
  literally and told the curator new work needed new branches — which is not how this project runs,
  and the correction had to come from the curator rather than from the repo. Corrected 2026-08-12 by
  curator decision. If the working branch changes, change it *here*, because this is the sentence a
  fresh session obeys.
- Commit subject carries the task id: `T-07: replace ScopeResolution with ScopeBinding`.
- The PR body is the task's `Accept:` list as a checklist, plus **which invariants the change
  touches** (INV-1…INV-9) and how each is still held.
- A PR that changes a documented cap, a supported version, or a capability **must** change the
  generated matrix or the cap table in the same PR. That is what G9 checks.

## 10. Locales

Nine locales exist: `de en es hu it pl pt-BR ru zh`. Rules:

- **No hardcoded user-facing string in a view, controller or mailer.** Keys go in `en.yml` first.
- **Update every locale file** when you add a key — an absent key falls back to English silently,
  which reads as a bug to a Dutch or Russian user and hides the gap from review.
- **Values in the locale's own language.** If you are not confident in a translation, add it and mark
  it in the PR body as needing review — do **not** paste the English string in as if it were
  translated, and do not leave the key out.
- Keys are namespaced under the plugin, structured like the existing file, and sorted the way that
  file already sorts.

## 11. When to stop and ask

Report and ask — do not decide — when you hit any of these:

1. **An `[OQ]` item** from `technical-spec.md` §12. **OQ-A and OQ-B are CLOSED** (2026-08-04) and
   both original claims were refuted by measurement — evidence in
   `docs/plan/reference/verification-oq-a-serialize-oq-b-liquid.md`. Do not re-open them; do read
   OQ-B's consequence, because it inverts §3.2: `{{ issue.closed? }}` parses and resolves on Liquid
   4.x and 5.x, so the five `?` accessors are **live surface** and keeping their aliases is a
   compatibility requirement, not a courtesy.

   **Eight are now closed and five are open. Count them from the table, not from memory — this line
   has been stale before.** Closed: **OQ-A**, **OQ-B** (2026-08-04, both refuted by measurement);
   **OQ-C** (2026-08-06, in T-19 — the filter inventory, measured on both Liquid majors);
   **OQ-I** (2026-08-04, by OQ-4's answer); **OQ-L** (2026-08-06, by measurement — wkhtmltopdf
   cannot parse `||=`); **OQ-F** (2026-08-06, by curator decision — the `template_authoring`
   setting is *deleted*, not defaulted, and replaced by the role-permission model in
   `technical-spec.md` §4.1; do not reintroduce a global switch over authoring);
   **OQ-M** (2026-08-12, by measurement — there is no pre-built CodeMirror 6 bundle to vendor at all,
   so T-37 takes the `<textarea>`-plus-lint-panel fallback and its "findings in the gutter" clause
   needs rewording); **OQ-E** (2026-08-12, by measurement — Redmine 7.0 ships **Propshaft 1.3.2**, so
   §6's "neither pipeline is involved" is wrong for 7.0, but the design does not depend on it because
   the PDF path reads the plugin's own `assets/` directory rather than `public/plugin_assets/`).
   Still open: **OQ-D**, **OQ-G**, **OQ-H** (narrowed, not closed), **OQ-J**, **OQ-K**.
2. **A claim in `claims.json` whose discriminator your work just ran.** That is *evidence*, and the
   register must be updated rather than the conclusion assumed. C-014 (the asset fetcher's internal
   reachability) and C-015 (whether the UX design actually closes R9) are the two most likely to be
   settled early.
3. **The spec is wrong**, not merely awkward. Say so with the file, the line, and the evidence.
4. **A control looks unnecessary.** It probably answers a red-team finding — check `04-risks.md`
   first, then argue with the finding rather than around it.
5. **Scope wants to grow.** The plan's largest risk is R-02 (stall, score 20). A task that has grown
   a second purpose should be split, not absorbed.
6. **You need something you cannot reach**: production data, a running Gotenberg, a credential, a
   real fork-PR run.

## 12. Output format (strict)

1. **Context / commands the human must run** — only what you genuinely cannot run yourself
2. **Plan** — short
3. **Code changes** — patch or full files
4. **Tests added or updated**
5. **Independent Review Report** — issues found, fixes applied, and whether it was a subagent or
   self-review
6. **QA Report** — the failure-mode matrix and its coverage
7. **UX / Consistency Report**
8. **Gate checklist G1–G12** — `PASS` / `FAIL` / `UNVERIFIED`, each with its evidence
9. **If anything is FAIL or UNVERIFIED:** the next action and the exact diff or command

A gate row without evidence beside it is treated as `UNVERIFIED`, by you as much as by the reader.
