# Per-task prompt template

Paste one filled-in copy per task. `CLAUDE.md` already carries the roles, phases, gates and forbidden
constructs — **do not repeat them here.** This template exists to say *which* task, and to force the
three things a fresh session cannot know: what already landed, what is deliberately out of scope, and
what is allowed to be assumed.

---

```
Work task T-__ from docs/plan/implementation-plan.md.

CLAUDE.md governs: four roles, phases −1 through 4, gates G1–G12, forbidden constructs.
Follow it. Do not restate it back to me.

STATE — what has already landed:
- merged tasks: T-__, T-__            (verify with git log; do not trust this line)
- current version / tag: v_._._
- Redmine branches available locally: ____
- last full suite result I have seen: ____

SCOPE — this task only:
- Touches / Deps / Accept: as written in the plan. If you believe the Accept list is
  incomplete, say so BEFORE implementing; do not widen it silently.
- Out of scope for this task: ____

ASSUMPTIONS YOU MAY MAKE (and only these):
- ____

WHAT I CANNOT GIVE YOU:
- production data / a running Gotenberg / a real fork-PR run / ____
  If the task needs one, stop at a pause point and tell me what to run.

DELIVER in CLAUDE.md §12's output format, with the gate table filled in from output you
actually saw.
```

---

## Filled example — the first task

```
Work task T-00 from docs/plan/implementation-plan.md (the Rails 8 enum fix).

CLAUDE.md governs. Follow it; do not restate it.

STATE:
- merged tasks: none — this is the first
- current version: v0.5.0
- Redmine branches available locally: none yet; run ./.codex/redmine_clone.sh yourself
- last full suite result I have seen: none

SCOPE — this task only:
- The blocker is redmine_reporter/app/models/report_template.rb:26 —
  `enum orientation: [ORIENTATION_PORTAIT, ORIENTATION_LANDSCAPE]`, the Rails <7 positional
  form, which Rails 8.1 (Redmine 7.0) rejects. Fix it in the fork with an explicit integer
  hash so the existing stored values are preserved exactly.
- Out of scope: anything in the dashboards plugin; any decoupling work; renaming
  ORIENTATION_PORTAIT (the typo is load-bearing — it is a stored constant name).

ALSO CHECK, and report rather than fix (both are candidate EXISTING defects, §11):
- OQ-A: does `serialize :layout, coder: YAML` in reporter_project_tab.rb:9-10 already break on
  Redmine 5.1 / Rails 6.1? If it does, the 5.1 support claim is already false and I need to know
  before T-01, not after.
- OQ-B: is `{{ issue.closed? }}` parseable by Liquid's variable grammar at all (4.x and 5.x)?

ASSUMPTIONS YOU MAY MAKE:
- The 7.0 branch must be added to .codex/redmine_clone.sh — per CLAUDE.md §4 that is part of
  this task, not a later nicety.

WHAT I CANNOT GIVE YOU:
- nothing; everything this task needs is in the repo.

DELIVER in CLAUDE.md §12's format. Note explicitly whether the enum change alters any stored
integer value — that is the one way this "one-line fix" can cause silent data damage.
```

---

## Notes on using this well

- **One task per session where you can.** Context spent on orientation is context not spent on the
  work, and the four-role discipline needs room.
- **T-01 before anything that touches the aggregator or `scope_resolution.rb`.** CLAUDE.md §1 makes
  this a refusal condition; the template's `STATE` block is how the agent learns whether it has landed.
- **Do not paste the `Accept:` list into the prompt.** Make the agent read it from the plan — if it
  cannot find the file, that is a problem worth discovering at the start rather than at the end.
- **Say what you cannot provide.** Most bad output from a strict prompt comes from an agent inventing
  a way around a missing container, database or credential rather than stopping.
- **When the agent reports an `[OQ]` finding, update `claims.json` and the spec before the next
  task.** The plan's value decays quickly once findings accumulate outside it.
