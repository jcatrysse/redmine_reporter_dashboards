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
