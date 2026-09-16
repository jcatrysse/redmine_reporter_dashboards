# Report template drop reference

<!-- GENERATED — do not edit. Written by `rake reporter_dashboards:drop_reference`
from `lib/redmine_reporter_dashboards/liquid/drop_reference.rb`, whose accessor
names come from the drops themselves at runtime. `script/gates/drop_reference_parity.sh`
fails the build if this file and the code disagree in either direction. -->

## IssueDrop

Reached from: assigned to a per-issue template; one issue of `issues`.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `id` | integer |  | `{{ issue.id }}` |  |
| `subject` | string |  | `{{ issue.subject }}` |  |
| `description` | text |  | `{{ issue.description }}` |  |
| `start_date` | date |  | `{{ issue.start_date }}` |  |
| `due_date` | date |  | `{{ issue.due_date }}` |  |
| `done_ratio` | integer |  | `{{ issue.done_ratio }}` |  |
| `estimated_hours` | decimal |  | `{{ issue.estimated_hours }}` |  |
| `total_estimated_hours` | decimal |  | `{{ issue.total_estimated_hours }}` | this issue and its descendants |
| `spent_hours` | decimal | yes | `{{ issue.spent_hours }}` | only the hours your role may see |
| `total_spent_hours` | decimal |  | `{{ issue.total_spent_hours }}` | this issue and its descendants |
| `created_on` | time |  | `{{ issue.created_on }}` | in the report actor's own time zone |
| `updated_on` | time |  | `{{ issue.updated_on }}` | in the report actor's own time zone |
| `closed_on` | time |  | `{{ issue.closed_on }}` | in the report actor's own time zone |
| `status` | ref |  | `{{ issue.status }}` | prints its name; compares with a string |
| `tracker` | ref |  | `{{ issue.tracker }}` |  |
| `priority` | ref |  | `{{ issue.priority }}` |  |
| `category` | ref |  | `{{ issue.category }}` |  |
| `author` | drop (UserDrop) |  | `{{ issue.author }}` |  |
| `assignee` | drop (UserDrop) |  | `{{ issue.assignee }}` |  |
| `project` | drop (ProjectDrop) |  | `{{ issue.project }}` |  |
| `parent` | drop (IssueDrop) |  | `{{ issue.parent }}` |  |
| `version` | drop (VersionDrop) |  | `{{ issue.version }}` |  |
| `target_version` | drop (VersionDrop) |  | `{{ issue.target_version }}` | the same object as `version` |
| `attachments` | collection (AttachmentDrop) | yes | `{{ issue.attachments }}` |  |
| `time_entries` | collection (TimeEntryDrop) | yes | `{{ issue.time_entries }}` |  |
| `subtasks` | collection (IssueDrop) | yes | `{{ issue.subtasks }}` |  |
| `custom_field_values` | lookup (CustomFieldValuesDrop) | yes | `{{ issue.custom_field_values[42] }}` | by field id or by field name |
| `custom_field_value` | lookup (CustomFieldValuesDrop) | yes | `{{ issue.custom_field_value[42] }}` | the same object as `custom_field_values` |
| `status_id` | integer |  | `{{ issue.status_id }}` |  |
| `tracker_id` | integer |  | `{{ issue.tracker_id }}` |  |
| `priority_id` | integer |  | `{{ issue.priority_id }}` |  |
| `category_id` | integer |  | `{{ issue.category_id }}` |  |
| `author_id` | integer |  | `{{ issue.author_id }}` |  |
| `assigned_to_id` | integer |  | `{{ issue.assigned_to_id }}` |  |
| `project_id` | integer |  | `{{ issue.project_id }}` |  |
| `parent_id` | integer |  | `{{ issue.parent_id }}` |  |
| `fixed_version_id` | integer |  | `{{ issue.fixed_version_id }}` |  |
| `closed` | boolean |  | `{{ issue.closed }}` |  |
| `closed?` | boolean |  | `{{ issue.closed? }}` | the same as `closed` |
| `overdue` | boolean |  | `{{ issue.overdue }}` |  |
| `overdue?` | boolean |  | `{{ issue.overdue? }}` | the same as `overdue` |
| `private` | boolean |  | `{{ issue.private }}` |  |
| `is_private?` | boolean |  | `{{ issue.is_private? }}` | the same as `private` |
| `visible` | boolean |  | `{{ issue.visible }}` | to the actor this report is rendered as |
| `visible?` | boolean |  | `{{ issue.visible? }}` | the same as `visible` |
| `url` | url |  | `{{ issue.url }}` | absolute, so it survives a PDF and an e-mail |
| `link` | html |  | `{{ issue.link }}` | an `<a>` element; already escaped |

## IssuesDrop

Reached from: assigned to a combined template.

Iterate it with `{% for issue in issues %}`; every accessor above is then available on `issue`, and the loop is what preloads the associations.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `size` | integer |  | `{{ issues.size }}` | counts in SQL; does not load the records |
| `first` | drop (IssueDrop) |  | `{{ issues.first }}` | or `first: 5` for the first five |
| `visible` | collection (IssueDrop) |  | `{{ issues.visible }}` | already the actor's visible scope; kept for readability |
| `all` | collection (IssueDrop) |  | `{{ issues.all }}` | REFUSED and recorded as a degradation — iterate instead |

## TimeEntryDrop

Reached from: assigned to a per-entry template; one entry of `time_entries`.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `id` | integer |  | `{{ time_entry.id }}` |  |
| `spent_on` | date |  | `{{ time_entry.spent_on }}` |  |
| `hours` | decimal |  | `{{ time_entry.hours }}` |  |
| `comments` | string |  | `{{ time_entry.comments }}` |  |
| `user` | drop (UserDrop) |  | `{{ time_entry.user }}` |  |
| `activity` | ref |  | `{{ time_entry.activity }}` |  |
| `activity_id` | integer |  | `{{ time_entry.activity_id }}` |  |
| `project` | drop (ProjectDrop) |  | `{{ time_entry.project }}` |  |
| `project_id` | integer |  | `{{ time_entry.project_id }}` |  |
| `issue_id` | integer |  | `{{ time_entry.issue_id }}` | nil for an entry booked on the project |
| `created_on` | time |  | `{{ time_entry.created_on }}` |  |
| `updated_on` | time |  | `{{ time_entry.updated_on }}` |  |
| `url` | url |  | `{{ time_entry.url }}` |  |

## TimeEntriesDrop

Reached from: assigned to a combined spent-time template.

Iterate it with `{% for time_entry in time_entries %}`.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `size` | integer |  | `{{ time_entries.size }}` | counts in SQL; does not load the records |
| `first` | drop (TimeEntryDrop) |  | `{{ time_entries.first }}` | or `first: 5` for the first five |
| `visible` | collection (TimeEntryDrop) |  | `{{ time_entries.visible }}` | already the actor's visible scope; kept for readability |
| `all` | collection (TimeEntryDrop) |  | `{{ time_entries.all }}` | REFUSED and recorded as a degradation — iterate instead |

## ProjectDrop

Reached from: always assigned — the template's own project.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `id` | integer |  | `{{ project.id }}` |  |
| `name` | string |  | `{{ project.name }}` |  |
| `identifier` | string |  | `{{ project.identifier }}` |  |
| `description` | text |  | `{{ project.description }}` |  |
| `status` | integer |  | `{{ project.status }}` | 1 active, 5 closed, 9 archived |
| `url` | url |  | `{{ project.url }}` |  |

## UserDrop

Reached from: always assigned — the actor this report is rendered as.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `id` | integer |  | `{{ user.id }}` |  |
| `login` | string |  | `{{ user.login }}` |  |
| `firstname` | string |  | `{{ user.firstname }}` |  |
| `lastname` | string |  | `{{ user.lastname }}` |  |
| `name` | string |  | `{{ user.name }}` | Redmine's own display order |
| `url` | url |  | `{{ user.url }}` |  |

## VersionDrop

Reached from: `issue.version`, and `{% version_rollup %}`.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `name` | string |  | `{{ version.name }}` | prints its name; compares with a string |
| `description` | text |  | `{{ version.description }}` |  |
| `effective_date` | date |  | `{{ version.effective_date }}` | the due date of the version |
| `status` | string |  | `{{ version.status }}` | open, locked or closed |
| `sharing` | string |  | `{{ version.sharing }}` |  |
| `completed_percent` | decimal |  | `{{ version.completed_percent }}` |  |
| `project` | drop (ProjectDrop) |  | `{{ version.project }}` |  |
| `project_id` | integer |  | `{{ version.project_id }}` |  |
| `project_identifier` | string |  | `{{ version.project_identifier }}` |  |
| `project_name` | string |  | `{{ version.project_name }}` |  |
| `id` | integer |  | `{{ version.id }}` |  |
| `include?` | boolean |  | `{{ version.include? }}` | substring of the name, so `contains` works |
| `url` | url |  | `{{ version.url }}` |  |
| `roadmap_url` | url |  | `{{ version.roadmap_url }}` |  |
| `issues_url` | url |  | `{{ version.issues_url }}` |  |
| `open_issues_url` | url |  | `{{ version.open_issues_url }}` |  |
| `closed_issues_url` | url |  | `{{ version.closed_issues_url }}` |  |
| `time_url` | url |  | `{{ version.time_url }}` | the spent-time report for this version |

## AttachmentDrop

Reached from: `issue.attachments`.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `id` | integer |  | `{{ attachment.id }}` |  |
| `filename` | string |  | `{{ attachment.filename }}` |  |
| `filesize` | integer |  | `{{ attachment.filesize }}` |  |
| `content_type` | string |  | `{{ attachment.content_type }}` |  |
| `description` | string |  | `{{ attachment.description }}` |  |
| `created_on` | time |  | `{{ attachment.created_on }}` |  |
| `author` | drop (UserDrop) |  | `{{ attachment.author }}` |  |
| `url` | url |  | `{{ attachment.url }}` |  |
| `download_url` | url |  | `{{ attachment.download_url }}` | a report can only show it if the asset policy resolves it |

## CustomFieldValueDrop

Reached from: `issue.custom_field_values[42]`.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `id` | integer |  | `{{ field.id }}` |  |
| `name` | string |  | `{{ field.name }}` |  |
| `value` | string |  | `{{ field.value }}` | an array for a multiple-value field |

## CustomFieldValuesDrop

Reached from: `issue.custom_field_values` / `issue.custom_field_value`.

A BRACKET LOOKUP rather than a set of accessors: `{{ issue.custom_field_values[42] }}` by field id, or by field name. A field your role may not see resolves to nothing at all — not to a blank value, and not to the field name with an empty cell.

_No accessors of its own._

## NamedRefDrop

Reached from: `issue.status`, `.tracker`, `.priority`, `.category`, `time_entry.activity`.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `id` | integer |  | `{{ status.id }}` |  |
| `name` | string |  | `{{ status.name }}` |  |
| `include?` | boolean |  | `{{ status.include? }}` | substring of the name, so `contains` works |
| `url` | url |  | `{{ status.url }}` | nil where Redmine has no page for it |

## RecordDrop

Reached from: the base of every single-record drop.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `id` | integer |  | `{{ record.id }}` |  |

## CollectionDrop

Reached from: the base of every collection drop.

A collection is also indexable by id — `{{ issues[42] }}` — and iterating it is what preloads the associations, which is why `all` is refused.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `size` | integer |  | `{{ issues.size }}` | counts in SQL; does not load the records |
| `first` | drop |  | `{{ issues.first }}` | or `first: 5` for the first five |
| `visible` | collection |  | `{{ issues.visible }}` | already the actor's visible scope; kept for readability |
| `all` | collection |  | `{{ issues.all }}` | REFUSED and recorded as a degradation — iterate instead |

## UsersDrop

Reached from: not assigned by any surface today.

Shipped for completeness; nothing hands one to a template, so this row exists to make its absence from the vocabulary deliberate.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `size` | integer |  | `{{ users.size }}` | counts in SQL; does not load the records |
| `first` | drop (UserDrop) |  | `{{ users.first }}` | or `first: 5` for the first five |
| `visible` | collection (UserDrop) |  | `{{ users.visible }}` | already the actor's visible scope; kept for readability |
| `all` | collection (UserDrop) |  | `{{ users.all }}` | REFUSED and recorded as a degradation — iterate instead |

## ProjectsDrop

Reached from: not assigned by any surface today.

Shipped for completeness; nothing hands one to a template.

| Accessor | Type | Batch | Snippet | Notes |
|---|---|---|---|---|
| `size` | integer |  | `{{ projects.size }}` | counts in SQL; does not load the records |
| `first` | drop (ProjectDrop) |  | `{{ projects.first }}` | or `first: 5` for the first five |
| `visible` | collection (ProjectDrop) |  | `{{ projects.visible }}` | already the actor's visible scope; kept for readability |
| `all` | collection (ProjectDrop) |  | `{{ projects.all }}` | REFUSED and recorded as a degradation — iterate instead |
