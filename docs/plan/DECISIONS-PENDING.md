# Decisions waiting on the curator

Eleven open items, written for a reader who has not been in the code. Each one says what
the situation is, what the choices are, what each choice costs, and which one I would
take. **Nothing here is decided.** A session that picks one by inference is doing the
thing `CLAUDE.md` §11 forbids.

Answer them by editing the **Decision:** line under each item — `Decision: 2` or
`Decision: leave it` is enough. A session can then implement the lot without asking again.

**STATUS 2026-08-13: ALL ELEVEN ARE SETTLED.** The curator answered "follow the
recommendation everywhere except where I say otherwise", overrode #3 to land in 1.0 rather
than 1.1, and resolved #1's conditional with *"niemand gebruikt dat nog"* — so #1 is
option 2, the full withdrawal.

Ordered by what it costs you to get it wrong, not by effort.

---

## Part 1 — must be settled before 1.0

### 1. Are reports rendered *by the old plugin* still supported?

**The situation.** This plugin's aggregation tags (`{% sql_aggregate %}`,
`{% version_rollup %}`) are registered with Liquid process-wide, so they work in any
template in the installation — including templates the old `redmine_reporter` plugin
renders itself. Until S-30 those renders got their data through a compatibility layer.
That layer is now deleted, so such a template shows **zeros instead of real numbers**
unless it names a saved query explicitly with `query_id:`.

It is not a data leak — nothing shows figures the reader may not see — and it writes a
warning to the log. But a report that looks finished and reads zero is the worst kind of
wrong, and `technical-spec.md` §7 treats "both plugins installed side by side" as a
supported setup.

We also still ship a small patch (`reporter_report_content_patch.rb`) whose only purpose
is to make *that* render path faster. So today we speed up a path we just stopped
supporting. That is incoherent whichever way you decide — it is the clearest signal that
this needs an answer.

**Options.**

1. **Keep supporting them.** Require such templates to name their query with
   `query_id:` and document it. Small change, mostly README. Keeps §7 honest.
2. **Stop supporting them.** Then finish the job in one go: delete the speed-up patch,
   delete the last piece of old-plugin detection, and fix the README sections that still
   tell authors to put these tags in a Reporter template. This is the only option that
   also empties the remaining coupling list (5 files → 2).
3. **Leave it.** Accept zeros-plus-a-log-line, and say so in the README so nobody spends
   a day debugging it.

**My recommendation: option 2**, *if* you can confirm no customer is running both plugins
with shared templates. The whole point of this project was to stop needing the paid
plugin; half-keeping the bridge costs code, a gate exemption, and exactly this kind of
confusion. If you cannot confirm that, take option 1 — it is cheap and honest. **Do not
take option 3**: it is option 2 without the tidying, and the next person will rediscover
it as a bug.

**Decision: 2** (curator, 2026-08-13). The conditional was resolved by the curator directly:
*"niemand gebruikt dat nog"* — nobody is still running templates on that path. So host-plugin
renders are WITHDRAWN, and the tidy-up is part of the change rather than a follow-up.

**One interaction to handle rather than trip over.** S-30's review fix made `query_id:`
resolve on a context-less render, taking its actor from `TagContext`'s ambient fallback.
With host renders withdrawn there is no context-less render left — `ReportRun` builds a
context for every one — so that path and the ambient fallback become unreachable together.
Remove them in the same change or the deletion is half-done again, which is the exact state
S-30 was created to clean up.

---

### 2. MariaDB gets sums and averages wrong (release blocker)

**The situation.** On MariaDB only, grouping by age with `sum`, `average` or `distinct`
returns wrong numbers once you use more than about four age brackets. MariaDB cuts off
long column labels at 256 characters, and the code reads results back by that label. The
counting path was fixed for this in T-08; the three calculating paths were not.

PostgreSQL and MySQL are unaffected. The plan already labels this a release blocker.

**Options.**

1. **Fix it.** Read the results by position instead of by label, the same way the
   counting path already does. Known shape, known fix, well understood.
2. **Ship 1.0 without MariaDB support** and say so in the README.
3. **Leave it and document the limit** ("do not use more than four age brackets on
   MariaDB").

**My recommendation: option 1.** The fix pattern already exists in this codebase and was
measured to be *faster*, not slower. Option 2 throws away a supported database for one
bug; option 3 is a footgun with a note next to it.

**Decision: 1** (curator, 2026-08-13 — "follow the recommendation").

---

### 3. Quoted values in tags mean the wrong thing

**The situation.** Writing `group_by: "user"` in a tag does not mean the word *user* — it
looks up a variable called `user`, which every report already has, so it silently asks for
`group_by: "Jan Catrysse"`. Two of the four spent-time groupings cannot be written at all
because of this. It fails visibly (an error on the page), so nobody gets wrong numbers.

The fix is small. The risk is not: 23 places read parameters this way, so making quotes
mean "literal text" changes the meaning of every quoted value in every template that
already exists.

**Options.**

1. **Fix it properly** — quotes mean literal text everywhere. Cleanest, but any existing
   template that relies on the current behaviour breaks. Needs an upgrade note.
2. **Fix only the affected groupings** — a small allowlist of parameter names that are
   always literal. Narrow, ugly, safe.
3. **Document it** — tell authors those two groupings are unavailable.

**My recommendation: option 1, but in its own release**, not in 1.0. It is the right
answer and it is a breaking change; bundling a breaking change into the release that also
removes the old dependency makes it impossible to tell which change broke somebody. Ship
1.0 with option 3, do option 1 in 1.1 with a note.

**Decision: 1, NOW — in 1.0** (curator, 2026-08-13, overriding the recommended timing).
The fix itself is what I recommended; only the release it lands in changed. Two things
follow and neither is optional: the change needs an **upgrade note** saying quoted tag
parameters now mean literal text, and it needs a test proving an existing template that
relied on the old behaviour fails **visibly** rather than silently reporting different
numbers. 23 call sites go through `str_param`; that is the blast radius to cover.

---

### 4. One permission is labelled as dangerous but cannot do the dangerous thing

**The situation.** The permission "Manage public report templates" is flagged internally
as *code execution*. It is not: a role holding only that permission is refused when it
tries to create a template. Because of the flag, the new admin diagnostic page warns
"check this was intended" about people who cannot actually write templates — crying wolf,
which is the one thing that page must not do.

**Options.**

1. **Change the flag** — it is not a code-execution permission. Risk: the flag also
   forces "members only" on the permission, so removing it would let an admin grant this
   to non-members. Needs the requirement written by hand instead.
2. **Narrow the diagnostic** — keep the flag, teach the page to report only the three
   permissions that genuinely create templates.

**My recommendation: option 2.** It is a one-line change in one place and touches no
permission contract. Option 1 changes what an installed permission means, which is a
migration and an upgrade note for a cosmetic gain.

**Decision: 2** (curator, 2026-08-13 — "follow the recommendation").

---

## Part 2 — should be settled, but will not stop a release

### 5. Two files still name the old plugin, in comments only

**The situation.** Two files mention the old plugin purely in historical comments (what a
method replaced, what a migration used to couple to). They keep the strict coupling check
red. There is a marker that exempts a file permanently; the rules say only you may hand it
out.

**Options.** 1. Mark both permanent. 2. Reword the comments so the name disappears —
loses the searchable name of the thing that was replaced. 3. Leave it.

**My recommendation: option 1.** The comments are worth keeping; that is exactly what the
permanent marker is for.

**Decision: 1** (curator, 2026-08-13 — "follow the recommendation"). This is the marker the
allowlist header reserves to the curator, so this line is the authority for it.

---

### 6. The README lists eleven spent-time groupings; the code has eight

**The situation.** Three were removed during review because they had nothing to click
through to. The README was not updated.

**Options.** 1. Fix the README. 2. Put the three back.

**My recommendation: option 1.** They were removed for a reason that still holds.

**Decision: 1** (curator, 2026-08-13 — "follow the recommendation").

---

### 7. Reports do not declare their language

**The situation.** The generated HTML and PDF carry no language marker. Screen readers and
hyphenation need it. The blocker is deciding *whose* language a scheduled report speaks:
the person who set up the schedule, each recipient, or the installation default.

**Options.** 1. Installation default. 2. The schedule's owner. 3. Per recipient (most
correct, most work — one render per language).

**My recommendation: option 1** for 1.0. It is one line, it is right for most installs,
and it can be refined later without breaking anything.

**Decision: 1** (curator, 2026-08-13 — "follow the recommendation").

---

### 8. A specification number is used for two different things

**The situation.** "FR-50" refers to the engine-selection screen in nine locale files and
to the generated support matrix in the specification. Purely a documentation mix-up.

**Options.** 1. Renumber the locale headers. 2. Renumber the spec.

**My recommendation: option 1.** The specification is the reference; the comments should
follow it.

**Decision: 1** (curator, 2026-08-13 — "follow the recommendation").

---

## Part 3 — already answered, listed so nobody re-opens them

### 9. Hungarian, Polish and Chinese translations were written by a model

You already said: leave it. Recorded here so it is not raised a third time.

### 10. Three accepted security advisories in the PDF container image

Accepted, with a review date of **2026-09-09**. Nothing to do until then.

### 11. The diagnostic table sorts roles alphabetically

The most alarming row (a built-in role holding code execution) lands wherever the alphabet
puts it, though it carries a warning icon. The table only lists roles that can author, so
it is short by construction. Left alphabetical because that is predictable. Worth a second
look only if a real installation shows a long list.

---

## After you answer

A session can implement all of Part 1 and Part 2 in one pass. Suggested order, because
some answers touch the same files:

1. **#2 (MariaDB)** — self-contained, the release blocker, and settled. Start here.
2. **#3 (quoted parameters)** — now in scope for 1.0 by curator decision, and the only
   breaking change in the set. Do it early, while there is room to react to what it breaks.
3. **#4, #5, #6, #7, #8** — small and independent.
4. **#1 (old-plugin renders, option 2)** — largest blast radius, so last. Deletes the
   speed-up patch, the ambient-actor fallback, the context-less `query_id:` path that
   depends on it, and the last of the old-plugin detection; corrects the README. Strict
   coupling list 5 → 2.

Then: run the full test suite, read CI, bump the version from 0.5.0 to 1.0.
