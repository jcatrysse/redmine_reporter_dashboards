# Prompt for the next session

Copy everything below the line into a fresh session.

---

Work on `jcatrysse/redmine_reporter_dashboards`, on the branch
**`claude/plugin-repo-docs-setup-8u9k17`**, which is the integration branch this project
actually works in. Its HEAD is **`cf693b7`**. Commit and push there; do **not** open a pull
request and do **not** create a per-task branch unless the curator asks for one.

Read `CLAUDE.md` first, then `docs/plan/HANDOVER.md` §1 and §3 — both are short and both record
traps that produce a green run meaning nothing. Then read this brief twice.

**One correction to carry, because `CLAUDE.md` will mislead you the way it misled the last
session.** §9 says *"One task per branch: `feat/T-07-scope-binding`"*. That is **not** how this
project is being run — everything lands on the integration branch above. The last session read
§9 literally and told the curator that new work needed new branches, which was wrong. **Ask the
curator whether §9 should be corrected**, and until they answer, follow the branch instruction
above rather than §9. The rest of §9 still holds: the commit subject carries the task id, and the
body lists the `Accept:` items and which invariants (INV-1…INV-9) the change touches.

## Where the work stands

`cf693b7` on the integration branch carries the curator's four T-34 decisions, FR-50 (the
install-wide engine selector), and eleven commits of corrections from ten independent review
rounds (§Findings **E-27 row 7**, **E-29** … **E-38** in `docs/plan/implementation-plan.md`). CI
was green on every commit in that series.

**33 of 37 tasks are done.** What remains: **T-26**, **T-27**, **T-37**, **T-38**, and T-03's
twelve render performance cells (the curator said leave those).

Verified at this HEAD, in a working directory with `.git` present: rspec **2682 examples, 0
failures, 127 pending**; minitest **923 runs, 0 failures, 0 errors, 4 skips**; the nine
argument-free gate scripts and the Ruby 2.7 floor all OK.

## THE ENVIRONMENT THIS HAS TO WORK ON: Redmine 7.0 + MariaDB

That is the curator's actual deployment, and it reorders the plan's priorities. Three things are
known about it, all measured, all in the README:

1. **On Redmine 7.0 the two *Report* widgets do not work** — the ones that embed a
   `redmine_reporter` template — because of an upstream change in Redmine 7. They degrade
   cleanly (placeholder, controls still work, clean error on the PDF export, reason in the log)
   and their functional tests `skip` with that explanation; those are the 4 skips above. Those
   two widgets also require the commercial Reporter plugin at all. **Ask the curator whether they
   run that plugin.** If they do, this is their biggest real gap and it outranks T-37 and T-38.
   If they do not, it is irrelevant to them and should not be worked on.
2. **On MariaDB, an `age` grouping WITH `measure: sum|avg|distinct` is still wrong past about
   four boundaries** (README's "One case is deliberately not covered"). Plain counts are correct
   at any boundary count. The fix means reimplementing three grouped calculations, which the plan
   judged larger than the defect justified — **that judgement was made without knowing the
   curator runs MariaDB, so re-ask it.**
3. **T-37 opens with `[OQ-M]`**, which says in as many words: verify the CodeMirror 6 bundle
   against §6's no-build-step rule **on a real Redmine 7.0 before vendoring it**. That is an open
   question (CLAUDE.md §11 rule 1) and a report-and-ask event. Do not vendor first.

## What to do, in this order

1. **Phase −1, the ordering guard** (CLAUDE.md §1). Read each task's `Deps:` line and refuse to
   start anything whose dependency is unmerged. Check with `git log --oneline` and the presence of
   the fixture files, not memory.
2. **Ask the curator the three questions above** (the Reporter plugin; the MariaDB measured-age
   fix; OQ-M's verification), plus the §9 question. They change what is worth building. Ask them
   together, early, and do not block on them for work that does not depend on the answers.
3. Then take the remaining tasks in dependency order. **T-38 is independent of T-37 and
   smaller.** T-26 gates T-27.

### T-26 needs an explicit permission the last session did not have

Two of its four accept clauses are **deleting `glue/legacy/`** and **flipping `zero_reporter` to
a hard strict gate**. The previous session was forbidden both. Its own status entry says the
`glue/legacy/` deletion was BLOCKED because `Liquid::ScopeBinding#bind` routes to it on every
render with no owned render context — that is every `{% sql_aggregate %}` in a
**reporter-hosted** template — and deleting it degrades to *no scope resolved*, i.e. those tags
silently start reporting nothing on exactly the installs the integration exists for. It also says
the five reporting-surface allowlist entries "have not been re-checked against the tree since"
T-34 landed. **Re-check them, then get explicit permission before deleting anything.** Deletion
is the one irreversible action in this plan.

## How to run things here (learned the hard way — do not rediscover)

- **rspec, from any copy of the plugin, no mirror needed:**
  `LANG=C.UTF-8 BUNDLE_GEMFILE=$PWD/redmine/Gemfile bundle exec rspec -I spec spec`
- **THE G7 TRAP, and it devalues most numbers you will read in older logs:** a suite run from a
  copy with **no `.git`** silently skips the ten `spec/golden` byte-identity examples — that is
  gate **G7**, the byte-identity of the ported aggregation kernel. Such a run reports the same
  example total and **ten more pending**. `127 pending` means G7 ran; `137` means it did not. A
  `git worktree` behaves like a copy. `rspec spec/golden` is 167 examples in half a second.
- **THE MIRROR TRAP:** `rspec`/`rake` run from `redmine/` read
  `redmine/plugins/redmine_reporter_dashboards/`, which is a COPY. Re-mirror first:
  `rsync -a --delete --exclude redmine/ --exclude .git/ ./ redmine/plugins/redmine_reporter_dashboards/`
  Never edit inside the mirror; step 1 of `.codex/redmine_clone.sh` destroys it.
- **minitest:** re-mirror, then
  `cd redmine && LANG=C.UTF-8 RAILS_ENV=test bundle exec rake redmine:plugins:test NAME=redmine_reporter_dashboards`
  (~90 s). A single file: `bundle exec ruby -Itest plugins/redmine_reporter_dashboards/test/...`.
- **PostgreSQL dies in this container, repeatedly.** `service postgresql start` and check
  `pg_isready -h 127.0.0.1` before concluding anything from a database error. It is not your
  change.
- **Gates:** the nine argument-free `script/gates/*.sh` all exit 0 today, plus
  `.codex/check_ruby_floor.sh`. Two more need arguments and are driven by CI. There is **no
  RuboCop** in this repo — G3 is "no linter configured for this path", not a pass.
- **Chromium** is at `/opt/pw-browsers/chromium-1194/chrome-linux/chrome` and **refuses to run as
  root** — that is the security posture working, not a bug. Run engine work as a non-root user
  (see `HANDOVER` §3).
- **Gotenberg**, if you need it: `docker-compose.gotenberg.yml`, and its JavaScript preflight
  check **fails against a container started less than ~10 s ago** (Chromium cold start, 10.011 s
  measured against a 10 s timeout). Warm it with one conversion first. Known open finding
  (§Findings E-29 row 16), not yours.

## Discipline this project actually enforces

All four CLAUDE.md roles, every task. **Use a fresh subagent for the review and brief it to
REJECT.** In the last session ten consecutive reviews each found something real, and the pattern
is worth knowing before you start:

> **The code settled early. The false statements were in the comments, the README and the plan.**
> "This message appears on the PDF" (it does not), "this field is admin-facing" (it is printed
> nowhere), "the nine locales are pinned" (one was), "`rake -T` is what an operator reads" (it
> truncates at 35 characters). Twice, the fix to a false claim contained a new false claim.

Two habits closed that class of defect, and they are cheap:

- **Assert the sentence a human reads, on the surface they read it on.** Not the object behind it.
  A `Check#title` corrected while the page renders a locale key is not a fix.
- **Pin any sentence this project has been wrong about by EQUALITY, not by keyword.** Keyword
  guards pass rewordings of the same lie. Three sentences and all nine locale values are pinned
  that way now; keep it.

And on mutation testing, which is the standard here: control green first; mutate the SOURCE;
re-mirror; parse the real summary line (`\d+ examples?, \d+ failures?`). A run with **no summary
line, an `error occurred outside of examples`, or 0 examples is UNMEASURED, not a pass** — that
mistake was made and corrected in the last session. Restore mutants **from a copy, never
`git checkout <path>`**, which destroyed uncommitted work here once. Snapshot the tree before
launching review agents and diff the whole tree afterwards. **Never `git add -A` while a subagent
is live** — and note that the integration-branch workflow makes this sharper, not softer: a
mistaken `git add -A` here lands on the branch everyone works from.

Expect the reviewer to find a guard your own mutation set had no mutant for. That happened in
nine of ten rounds. It is not a failure of the round; it is what the round is for.

## Forbidden

No deleting `glue/legacy/`, `scope_resolution.rb`, `lib/sql_aggregation/*` or any fixture without
explicit permission (see T-26 above). No `ZERO_REPORTER_MODE=strict` without the same. No
force-push. No committing `redmine/` (it is gitignored; Redmine's own test run dirties it, which
is expected). No hand-editing `docs/engine-support-matrix.md` — it is generated from the run, and
that is gate G9. No global authoring switch: OQ-F is closed and the role-permission model won.

## Still open for the curator, carried forward

- **`CLAUDE.md` §9's "one task per branch"** versus the integration-branch workflow (above).
- **Seven `[OQ]` items**: D, E, G, H, J, K, M. Hitting one is report-and-ask.
- **`hu`, `pl`, `zh`** deferral translations were reviewed by a second model, not a human native
  speaker, and `hu` was wrong twice before it was right (§Findings E-36). A wrong value now fails
  a test, which is the only reason they are safe to ship.
- **The admin preflight page** shows a green tick on an install where every engine needs a service
  and none is selected — the same defect the rake task was just fixed for, on a second surface,
  unreachable on the shipped three-engine tree (§Findings E-37).
- **Three accepted CVEs** in the pinned Gotenberg image, review date **2026-09-09**.
- **FR numbering**: the engine-selection screen is cited as FR-50 in nine locale-file headers,
  though `functional-spec.md` defines FR-50 as the generated support matrix. Prose now says
  "§5.2 clause 4"; the headers await a decision (§Findings E-29 row 8).

Finish with CLAUDE.md §12's output format, and G1–G12 each with the evidence you actually saw.
`UNVERIFIED` is an acceptable answer; a fabricated `PASS` is not.
