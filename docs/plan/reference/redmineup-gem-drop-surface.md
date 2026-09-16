# Reference — the `redmineup` gem's Liquid surface, measured

> Captured 2026-08-04. **Why this file exists:** the cost/risk review named the size of
> the gem's drop vocabulary as *"the single largest unmeasurable in the estimate"*,
> because the gem is not vendored into either plugin repo. It is publicly installable,
> so the gap is closable by measurement rather than by estimate. Measured by
> `gem fetch redmineup -v 1.1.12 && gem unpack`.
>
> **Read-only observation.** Judgement belongs in `02`/`04`.

## Provenance and licence

| Fact | Value |
|---|---|
| Gem | `redmineup` **1.1.12** (latest at capture; released 2026-07-23) |
| Declared licence | `spec.license = "GPL-2.0"` [CITE: redmineup-1.1.12/redmineup.gemspec:15] |
| Downloads | 4 298 689 [CITE: https://rubygems.org/api/v1/gems/redmineup.json] |
| `required_ruby_version` | `>= 2.0.0` [CITE: gemspec:20] |
| Runtime deps | `rails`; **`liquid` `> 4.0`, `< 5.0`**; `rubyzip` [CITE: gemspec:22-24] |

**The gem is public and GPL-2.0** — the same licence as Redmine itself. It is *not*
the closed part of the stack. The closed part is the RedmineUP EULA's carve-out for
CSS/JS/images inside the *plugin* (see `source-inventory.md` §1).

## The hard forcing function: Liquid is pinned below 5.0

`spec.add_runtime_dependency 'liquid', '> 4.0', '< 5.0'` [CITE: gemspec:23].

Shopify's Liquid **5.x** is the current major line. So for as long as the plugin
depends on this gem, **the plugin cannot run Liquid 5** — the constraint is in the
dependency graph, not a preference. Anything Liquid 5 offers (including its resource
limits and error-mode surface, which matter for the sandboxing questions raised
elsewhere in this analysis) is unreachable while the gem is a runtime dependency.

This is a **technical** reason to own the drops (R6) that is independent of any
licensing argument, and it is stronger than the licensing one, because it is
verifiable from the gemspec alone. `[GAP]` Not verified: whether the gem *actually*
breaks on Liquid 5 or merely declines to declare it, and whether 1.1.12 loads under
Rails 8.1 / Redmine 7.0.

## Size — what "own drops" (R6) actually costs

| Component | LOC |
|---|---|
| `lib/redmineup/liquid/drops/*.rb` (9 files) | **625** |
| `lib/redmineup/liquid/filters/*.rb` (4 files) | **579** |
| `lib/redmineup/patches/liquid_patch.rb` | 33 |
| **Total Liquid layer** | **1 237** |

Plus the plugin's own extensions on top: 102 LOC of subclassing in
`redmine_reporter/lib/redmine_reporter/liquid/drops/` and 186 LOC of plugin filters.

**So the R6 surface is ~1 240 LOC of readable, GPL-2.0 Ruby — bounded and small.**
It is not an unbounded reverse-engineering exercise. The design question ("which of
these accessors should a modern drop API even have?") is the real work; the
transcription is not.

## The 17 drop classes

`AttachmentDrop`, `CustomFieldEnumerationDrop`, `IssueRelationsDrop`,
`IssueRelationDrop`, `IssuesDrop`, `IssueDrop`, `JournalsDrop`, `JournalDrop`,
`NewssDrop` *(sic — double s)*, `NewsDrop`, `ProjectsDrop`, `ProjectDrop`,
`TimeEntriesDrop`, `TimeEntryDrop`, `UsersDrop`, `UserDrop`, `VersionDrop`.

### `IssueDrop` — the one that matters (the template-compatibility contract)

**19 delegated attributes:** `id subject description visible? closed? start_date
due_date overdue? done_ratio estimated_hours spent_hours total_spent_hours
total_estimated_hours is_private? closed_on updated_on created_on`
[CITE: drops/issues_drop.rb:36-53].

**24 defined methods:** `link url author assignee attachments tracker status priority
category version time_entries parent project subtasks relations_from relations_to
notes journals tags story_points color day_in_state checklists helpdesk_ticket
custom_field_values` [CITE: drops/issues_drop.rb:59-160].

Two observations that bear on the rewrite:

1. **Scalars where objects are needed.** `tracker`, `status`, `priority`, `category`
   and **`version`** each return **only `.name`** — no id
   [CITE: drops/issues_drop.rb:79-97]. This is precisely the defect the addon works
   around with `{% geo_version_map %}` and its own `VersionDrop`/`target_version`
   patch, as its README states. A purpose-built drop layer fixes this by design, and
   two of the addon's tags then have no reason to exist.
2. **Six accessors are soft hooks into *other* RedmineUP paid plugins** —
   `tags`, `story_points`, `color`, `day_in_state`, `checklists` are all
   `@issue.respond_to?(…) && …`, and `helpdesk_ticket` is guarded by
   `defined?(::HelpdeskTicketDrop)` [CITE: drops/issues_drop.rb:131-157]. They are
   dead weight in any deployment that does not own those plugins, and they are a
   vendor-ecosystem coupling the new plugin has no reason to reproduce.

### `IssuesDrop` (the collection) — 5 methods

`before_method(id)` (lookup by id), `all`, `visible`, `each`, `size`
[CITE: drops/issues_drop.rb:3-30]. Note `all` **maps every record into a drop
object** — this is the O(n)-object-materialisation the addon's
`reporter_report_content_patch` and `{% sql_aggregate %}` exist to avoid.

### `VersionDrop` — 27 delegated attributes, no methods

Includes `visible_fixed_issues`, `issues_count`, `open_issues_count`,
`closed_issues_count`, `completed_percent`, `spent_hours`
[CITE: drops/version_drop.rb:4-31]. Relevant because the addon reimplemented its own
`VersionDrop` (108 LOC) to add **absolute URLs** that survive PDF export — so the
gem's version support was insufficient in practice, not merely inelegant.

## The filter surface — 55 filters in 4 auto-registered modules

All four call `::Liquid::Template.register_filter` at load time, i.e. they are
**global** once the gem is required [CITE: filters/base.rb:261, additional.rb:28,
arrays.rb:253, colors.rb:28].

`args_to_options as_liquid attachment call_method ceil concat container
container_currency contrasting_text_color convert_to_brightness_value currency
custom_field custom_fields darken_color dasherize date_range default encode first
floor group_by groupable? hex_color inline_options item_property jsonify
lighten_color ljust md5 modulo multi_line parse_binary_comparison parse_comparison
parse_condition parse_inline_attachments plus_days pop push random regex_replace
regex_replace_once rjust round shift shuffle sort sort_input tagged_with textile
textilize time underscore unshift utc where where_exp`

Two of these deserve flagging as observations for the security lens:

- **`call_method(input, method_name)`** [CITE: filters/base.rb] — a filter that
  invokes a named method on an arbitrary object from inside a template.
- **`regex_replace` / `regex_replace_once`** — template-supplied regexes.

Plus `Redmineup::Patches::LiquidPatch::StandardFilters` monkey-patches a private
`to_number` into **`Liquid::StandardFilters`** globally, unconditionally, at require
time [CITE: patches/liquid_patch.rb:29-31].

## Consequence for the estimate

The R6 work package is **measurable and bounded** at ~1 240 LOC of reference material
plus a design pass, not an open-ended discovery exercise against unreadable code. That
removes the largest single variance the cost review flagged.

The three representative templates in `reference/` consume **none** of the gem's
`IssueDrop`-specific accessors (the business review established this independently),
so the *migration* exposure of replacing this layer is far smaller than its API size
suggests. `[GAP]` still open: what GEOxyz's **production** templates use — a
`SELECT content FROM report_templates` grep settles it, and nothing in these
repositories can.
