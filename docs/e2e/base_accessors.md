# base_accessors

Run 2026-11-25T17:21:42.508Z against http://127.0.0.1:3000.

| screenshot | user | URL | shows |
|---|---|---|---|
| ![](base_accessors-manager.png) | manager | `/projects/e2e-project/reporter/templates/6` | Manager (every permission): both notes, the private one too; both relations; tags, story points, colour, checklist and helpdesk ticket where those plugins are installed |
| ![](base_accessors-notesless.png) | notesless | `/projects/e2e-project/reporter/templates/6` | Member without "View private notes", checklists or helpdesk: the public note only, no relation into the private project, no checklist, no ticket |
| ![](base_accessors-closed.png) | closed | `/projects/e2e-project/reporter/templates/6` | Member who may see but not open the issue (redmine_view_issue_description): no description and no journals |
| ![](base_accessors-reporter-refused.png) | reporter | `/projects/e2e-project/reporter/templates/6` | Reporter without the report permissions: the template is refused (403) |
