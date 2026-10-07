# This plugin together with all 38 GEOxyz plugins: Redmine breaks

Same setup as `../geoxyz-together/`, with every GEOxyz plugin installed. Project > Settings,
the issue list, issue pages and My page answer 500 (`super: no superclass method
'project_settings_tabs'` and `SystemStackError` in `IssueQuery#initialize_available_filters`),
caused by alias chains in redmine_itil_priority, redmine_mail_digest,
redmine_depending_custom_fields and (second run, `run2-without-3/`) redmine_issue_todo_lists2.
Kept: the smoke and core_pages reports and two screenshots of the 500 page.
