# Run together with redmine_issue_todo_lists2

Redmine 7.0-stable-GEOxyz (PostgreSQL 16, production mode) with `redmine_issue_todo_lists2`
(branch `redmine70-migration` at d65e4ad) installed next to this plugin, on a
reset database: smoke 30 pages, core flows 6, all eight plugin scenarios, 0 problems
(`*.md` here). The screenshots of that run are not kept: they are the same pages as
`../postgresql/`. Kept: `todolists-with-positions-preview.png`, the cross-plugin finding
(work item 7): `issue.todolists_with_positions` renders empty in this plugin's templates.
