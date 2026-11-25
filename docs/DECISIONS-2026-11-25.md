# Decided by Jan, 2026-11-25

Relayed by the coordinating session of GEOxyz's Redmine 7 migration.

## One line: `redmine70-migration`

Jan, 2026-11-25: one line, redmine70-migration.

All work on this plugin lands on `redmine70-migration`, which is what goes live with Redmine 7.
The previous pin, `claude/next-session-prompt-it4too`, held nothing that was not already there:
its only own commit, `86fba98` ("CI: Ruby 4.0 for Redmine 7.0"), is patch-identical to `b4c16a2`
on `redmine70-migration`. The old branch is not deleted; it is merged up to
`redmine70-migration` with a normal merge (no force-push) and no longer receives work.

Changed together, as CLAUDE.md §9 requires: the branch line in `CLAUDE.md` and `PINNED_BRANCH`
in `.claude/hooks/session-start.sh`.

## Option A: restore the base plugin's issue accessors

GEOxyz migrated from RedmineUP's `redmine_reporter` and still runs `redmine_tags`,
`redmine_agile`, `redmine_checklists` and `redmine_contacts_helpdesk`. Its templates use the
accessors this plugin had dropped as vendor coupling (survey of Jan's ten templates: `journals` 4,
`color` 2, `story_points` 1, `tags` 1, `| textilize` 1, and `issue.journals.all`). Jan chose
option A: restore everything the base plugin offered, with the same names and meaning, so the
existing templates keep working: `notes`, `journals`, `relations_from`, `relations_to`, `tags`,
`story_points`, `color`, `day_in_state`, `checklists`, `helpdesk_ticket`, the `tagged_with`
filter, `textilize`. Built on `redmine70-migration`; each accessor answers as the report's actor
and is batched. See `docs/admin-guide.md`, "What the old accessors answer".

## The counting tags follow redmine_issue_field_visibility too

Jan, 2026-11-25: "Ook de teltags afschermen."

After `ef7ac49` the issue drop hides every core field redmine_issue_field_visibility hides from
the report's actor, but `{% sql_aggregate %}` (and its alias `{% geo_aggregate %}`, used by six
of GEOxyz's templates) still grouped by assignee, priority, category and version and summed the
estimated time regardless. Jan explicitly approved changing the frozen aggregation kernel for
this. It is declared as gate G7's second kernel hunk, `field-visibility`
(`spec/golden/kernel_exception.rb`, RATCHET 1 → 2), and its reason names this record. The spec
that checks every hunk names its grant now accepts D-1 or this file, and nothing else.

What was chosen, per project in the report's scope, for a field hidden from the actor there:

- **Group by it**: every issue of that project in one bucket labelled with core's "Hidden"
  wording (`label_reporter_aggregation_hidden`, twelve locales); no drill-down URL on that axis,
  not even for visible values, because an issue list for a visible value would also count it in
  the hidden projects.
- **Measure it** (sum, avg, distinct): those issues read NULL, so the value is the visible
  projects' only. For a mixed scope this is "visible projects' values plus a marker"
  (`hidden_fields` in the result) rather than an empty result: the visible part is data the
  actor can already see, so it cannot leak a hidden value, and an empty result would hide
  information the actor is entitled to.
- **Flags and completeness**: the counters that read it are recomputed over the visible
  projects, lose their drill filters, and are named in `hidden_fields`.
- **A query condition on it**: the issues of the projects where it is hidden are left out (the
  same rule as the drop: no value, so no match), with the diagnostic
  `aggregation_hidden_filter`. Refusing the whole aggregation was the other option; leaving
  out only the affected projects keeps the rest of the report useful.
- **`{% version_rollup %}`** and spent time grouped by version or category: the affected
  projects are left out, with a diagnostic. A per-version row has no place for a hidden bucket.
- Admins, actors with nothing hidden, and installations without the plugin: no extra query and
  byte-identical output.
