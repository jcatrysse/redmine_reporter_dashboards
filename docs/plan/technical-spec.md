# Technical spec — standalone `redmine_reporter_dashboards`

- **Idea:** 004-redmine-reporter-modern · **Decision:** **ADR-004** ([`05-decision.md`](./05-decision.md))
- **Functional spec:** [`functional-spec.md`](./functional-spec.md) · **Sequencing:** [`07-phasing.md`](./07-phasing.md)
- **Invariants:** INV-1…INV-9 in `model.json`. §10 maps every one to a mechanism.
- Still a spec: interfaces, contracts, file trees, decisions. **No implementations.**

## 0. Coupling inventory — the dossier undercounted, and two findings are new

The analysis listed 6 coupling files. Measured in the live clone there are **18 coupling
sites**. Two were in no earlier list and both are load-bearing for step 1 — **verified
directly, not taken on report**:

| # | Site | Couples to | Note |
|---|---|---|---|
| **C3** | `app/models/reporter_project_tab.rb:7` — `up_acts_as_list scope: :project_id` | the **`redmineup` gem** | **Verified:** defined only at `redmineup-1.1.12/lib/redmineup/acts_as_list/list.rb:33`; absent from both plugins. It arrives transitively via `redmine_reporter/Gemfile` + `init.rb:1`. **Relaxing the hard `raise` alone leaves the plugin booting and then 500-ing on its own core model.** The most easily-missed item in the whole sequence. |
| **C16** | `liquid_aggregate_tag.rb:106` **and** `liquid_version_rollup_tag.rb:38` | `include SqlAggregation::ScopeResolution` | **Verified: there are two, not one.** `04-risks.md` E2 named only the aggregate tag. Both must be re-seamed. |
| C1/C2 | `init.rb:12-16`, `:33` | the hard gate + `requires_redmine_plugin` | |
| C4 | `redmine_reporter_dashboards.rb:96-118`, `liquid/issue_drop_patch.rb` | reporter's `IssueDrop` | |
| C5 | `:124-127`, `reporter_list_patch.rb` | `IssueListReportTemplate`, `Report`, a thread-local | |
| C6 | `reporter_report_content_patch.rb` | `ReportTemplatesController#report_content` | |
| C7 | `patches/report_patch.rb:31-96` | `Report`, `ReportTemplate::ORIENTATION_LANDSCAPE`, `WickedPdf` | |
| C8 | `pdf_polyfills.rb` | wkhtmltopdf (not reporter) | consumed only by C7 |
| C9–C13 | the two report-widget partials, the my-page partial, `reporter_report_for` (`:137-154`), and `report_content_report_template_path` — **reporter's route** | | |
| C14 | `_report_settings.html.erb:16-17` | *nothing* — takes locals | **reusable as-is** |
| C15 | `scope_resolution.rb` (303) | drop archaeology + `Thread.current[:rrd_issue_query]` | to be deleted |
| C17 | `ci.yml:202-228, 271-276` | `secrets.REPORTER_REPO_TOKEN` | the G1 blocker |
| C18 | `test/functional/*` | full app boot with reporter | |

**Do not rely on `rescue NameError` to find these.** `redmine_reporter_dashboards.rb:135`
already swallows `NameError` silently, which is exactly why C3 survived undetected for a
release line.

## 1. Architecture

Four layers plus a compatibility module. The layering is not decoration: it is what makes the
Redmine version span testable, because layers 1–3 never boot Redmine.

```mermaid
graph TD
  L4["L4 · glue — app/, controllers, models, views, mailers<br/>the ONLY layer that touches Redmine"]
  L3["L3 · render — DocumentRequest, engines, assets, readiness, charts<br/>no ActiveRecord, no Liquid, no Rails"]
  L2["L2 · liquid — drops, filters, tags, RenderContext, ExecutionPolicy"]
  L1["L1 · aggregation — query_aggregator + drill_through (PORTED VERBATIM)"]
  L0["L0 · compat — the only place Rails::VERSION may appear"]
  L4 --> L3
  L4 --> L2
  L2 --> L1
  L4 --> L0
  L2 --> L0
  L3 --> L0
```

| Layer | Namespace | May reference |
|---|---|---|
| 0 | `ReporterDashboards::Compat` | `Rails::VERSION`, `Redmine::VERSION` — **exclusively** |
| 1 | `ReporterDashboards::Aggregation` | ActiveRecord, Redmine models |
| 2 | `ReporterDashboards::Liquid` | L1, the `liquid` gem, Redmine models |
| 3 | `ReporterDashboards::Render` | **nothing** Redmine / ActiveRecord / Liquid. Logger and config are injected ports |
| 4 | `ReporterDashboards` + `app/` | everything |

**Plugin id stays `redmine_reporter_dashboards`, permanently.** It keys `plugin_schema_info`;
route helpers and permission names are a public contract; and third-party widget contribution is
a *filesystem* contract — `ProjectPage.additional_blocks` globs
`#{Redmine::Plugin.directory}/*/app/views/reporter_project_pages/blocks/_*`
(`project_page.rb:55-62`), so renaming the view path breaks every other plugin's widget.

### 1.1 File tree

```
lib/reporter_dashboards/
  compat/        enum.rb serialize.rb icons.rb assets.rb query_params.rb autoload.rb
  aggregation/   query_aggregator.rb  drill_through.rb        ← BYTE-IDENTICAL, see §1.3
  liquid/        render_context.rb execution_policy.rb template_renderer.rb
                 scope_binding.rb batch.rb linter.rb
                 drops/{record,collection,named_ref,issue,issues,user,users,project,
                        projects,version,time_entry,time_entries,attachment,
                        custom_field_value}_drop.rb
                 filters/{numeric,text,colour,array,custom_field,serialisation}.rb
                 tags/{aggregate,version_rollup,chart}_tag.rb
  render/        document_request.rb page_furniture.rb result.rb failure.rb
                 capabilities.rb registry.rb renderer.rb
                 asset_binding.rb readiness.rb preflight.rb
                 engines/{chromium_cdp,wkhtmltopdf}.rb
  charts/        chart_spec.rb chart_layout.rb svg_renderer.rb chartjs_emitter.rb
                 palette.rb collector.rb                       ← names NEITHER layer
  assets/        policy.rb origin.rb reference.rb local_store.rb fetcher.rb
                 document_scanner.rb resolver.rb resolution.rb  ← names NEITHER layer
  glue/          project_page.rb row_layout.rb block_settings.rb positioned.rb
                 legacy/  ← loaded ONLY when reporter is present; deleted at 1.0
spec/            L1–L3 only. Never boots Redmine.
test/            L4 only. Boots the full app.
script/gates/    layer_purity.sh zero_reporter.sh no_html_safe.sh compat_size.sh support_matrix.rb
```

**`charts/` and `assets/` were inside `render/` in this tree until 2026-08-06, and could not
be — findings F-13 and F-13b, settled by the curator rather than per task.** Both are named by
the Liquid layer *and* by the render layer, and mechanism E3 keeps those two apart:

* `{% chart %}` has to build a `ChartSpec`. Under `render/` it could not, because E3 forbids
  `liquid/**` from naming `…Dashboards::Render`.
* an asset resolver is made of `Net::HTTP`, and E3 forbids that under `render/**` — not as a
  wording accident but because §5.1 requires resolution to happen "in the plugin, never in the
  engine", and `document_request.rb`'s own contract says `body` arrives "already
  asset-resolved". Resolution is *finished* before anything in `render/` runs.

So both sit between the two layers, naming neither, and `layer_purity.sh` grew an arm for each
so that "a neutral namespace" is enforced rather than asserted — otherwise the boundary would
hold only until somebody followed the two hops `liquid/` → `charts/` → `Render`. What remains at
the address this tree used to give `asset_resolver.rb` is **`render/asset_binding.rb`**: the
render layer's statement of how a `Assets::Resolution` becomes a `DocumentRequest` or a
`Failure(:asset_unresolved)`. It constructs render types and does no resolving.

The general rule this settles: **when the tree and a mechanism disagree, the mechanism wins and
the tree is corrected.** The mechanism is the half with a test, and relaxing E3's `Net::HTTP` or
`Liquid` pattern to satisfy a directory listing is exactly what CLAUDE.md §7 forbids.

### 1.2 Boundary enforcement — five mechanisms, one CI job

| # | Mechanism |
|---|---|
| E1 | `spec/` may not `require` from `app/` or `config/` |
| E2 | `spec_helper.rb` **aborts** if `::Rails.application` or `::Redmine::Plugin` is defined at load |
| E3 | `layer_purity.sh`: `render/**` must contain zero `Rails\.`, `ActiveRecord`, `Liquid`, `Issue`, `Net::HTTP`, `Faraday`, `cookie`, `session`; `aggregation/**` and `liquid/**` zero `ReporterDashboards::Render`; **`charts/**` and `assets/**` zero `ReporterDashboards::Render` AND zero `ReporterDashboards::Liquid`** — they are named by both, so they may name neither (§1.1, findings F-13/F-13b). `assets/**` is deliberately **not** forbidden `Net::HTTP`: being the one place in the plugin that holds a socket is its whole job |
| E4 | `Rails::VERSION` / `Redmine::VERSION` only under `compat/`. The job **prints `compat/` LOC as a PR comment** — compatibility debt as a visible number is the only real defence against the "temporary adapter ossifies" fate ADR-004 names |
| E5 | L3 takes `logger:` and `config:` as constructor ports |

### 1.3 The verbatim-port rule — two phases, and why it is not fastidiousness

Re-indenting 2 774 lines into a new module changes every line, destroying the ability to diff
against v0.5.0 — the exact "corpus drift at the sequencing seam" of the month-7 failure.

- **Phase A — byte-identical.** Both files copied with **zero changes**; they still open
  `module SqlAggregation`. Namespacing is one assignment in a separate file:
  `ReporterDashboards::Aggregation = SqlAggregation`. CI job `corpus` runs
  `git diff --no-index` against each file's `v0.5.0` blob and requires **empty** output — not
  "ignoring whitespace".
- **Phase B — re-indent.** Only after `corpus` has been green for a full release cycle *and* the
  goldens are signed off. One mechanical commit; if `corpus` goes red it is **reverted, not
  fixed**.

**Which code this applies to, spelled out because it looks like the opposite of "nothing copied
as-is" and is not** *(added 2026-08-04 in answer to the curator's question)*. Exactly **two files**
are copied byte-identically, and both are the curator's own: `lib/sql_aggregation/aggregator.rb` and
the two tags in `redmine_reporter_dashboards` — code this project wrote, whose *numbers* are the
thing being preserved. Copying them is not a shortcut; it is the only way to prove with a diff that
the aggregation did not change while everything around it did, and Phase B removes even that.
**Nothing from the base plugin or the vendor gem is copied at all** — the drop layer, the filter
set, the render path, the templates, the scheduler, the import path, the mail path and the share
links are each rebuilt from the *behaviour*, which is why `technical-spec.md` carries a disposition
per drop and per filter rather than a file list. The mechanical guarantee is `zero_reporter.sh`
plus the `layer_purity` gate: at 1.0 a grep for either upstream's identifiers must return nothing.
*So the honest summary is not "fresh except two files" but "**fresh, plus a temporary, CI-enforced,
diff-provable copy of our own arithmetic**."*

## 2. The decoupling sequence

Six individually-shippable steps. Two ordering constraints are load-bearing: **the corpus is
frozen before anything is re-seamed**, and **the render path is owned before the Liquid layer**
(§2.7).

### Step 0 — the `enum` fix + freeze the oracle *(hours; no prerequisites)*

`redmine_reporter/app/models/report_template.rb:26` → the Rails-8 positional form with an
**explicit integer hash** `{ portrait: 0, landscape: 1 }`, not `%i[…]`. The column is
`integer default 0` (`db/migrate/003`), so stating the mapping makes the on-disk contract
explicit instead of positional. The misspelled `ORIENTATION_PORTAIT` stays in the fork and is
**not** carried forward.

**Freeze** (run against the `v0.5.0` **tag**, not a working tree): goldens for
`.aggregate` × period/periods/closed_statuses; `.breakdown` (legacy) × 7 core fields;
`.dimension_breakdown` × group_by/split_by/sort/limit/measure/of/user_label/age_*/date_field;
`.completeness` × field-list sizes; `.flags`; `.version_rollup` × cost fields. Plus cap
boundaries at 200 / 24 / 12 / 5 000, **plus ≥3 actors with different roles including one
role-restricted custom field** — which does not exist in the fixture today and is what makes
INV-1/INV-2 testable at value level.

Two blockers to clear first, both mechanical:

1. **Pin a reference date.** The existing adapter fixture is deliberately `Time.zone.today`-relative
   (a 400-day sweep so ISO-week turns are always exercised). Excellent for a self-consistent spec,
   **fatal for a golden corpus** — every expected value changes daily. The generator pins the date
   and the verifier **refuses to run** without it. Otherwise the differential goes red daily for
   the wrong reason and is switched off within a week, which is how this mitigation actually fails.
2. **Canonicalise.** JSON Lines; keys sorted recursively; **array order preserved** (`buckets`,
   `labels`, `rows`, `series` are ordering contracts); sentinel symbols round-tripped as literal
   strings; `nil`/`0`/`""` kept distinct; floats stored as `(value*10_000).round` **plus** a
   `%.4f` string — because PostgreSQL's `CAST(x AS numeric)` and MySQL's
   `CAST(x AS DECIMAL(20,4))` do not agree beyond the fourth decimal. **4 dp is the declared
   contract.** Cases that cannot agree at 4 dp go in a per-adapter overlay **with a written
   reason**; an empty overlay passes, a *growing* overlay is a ratchet failure. No floating
   tolerance — a tolerance hides drift, an overlay names it.

SQL strings live in a **sibling** tree, not the value corpus: SQL is *expected* to change at the
re-seam, the numbers are not, and a differential that fails for the wrong reason gets disabled.

**What is actually irrecoverable.** The kernel signature is unchanged and v0.5.0 stays in git,
so the *numbers* corpus is in principle regenerable. What cannot be reconstructed once
`scope_resolution.rb` is gone is **the scope** — "the AR relation 0.5.0's `resolve_scope`
produced for template T, query Q, actor U". So a small **scope fixture** (~40 triples recording
`to_sql` **and** the sorted issue-id set) plus the tag-level corpus are the genuinely
time-critical artefacts. Freeze everything anyway: the marginal cost is one CI run and the
recovery path depends on a private repository staying reachable *and* on reporter's `enum`
defect not blocking the generator.

### Step 1 — boot without reporter *(ships 0.6.0 — the standalone unlock, G1)*

**Prerequisites, in this order:**

1. **Replace `up_acts_as_list` (C3)** with an owned `Glue::Positioned` concern: `position`
   defaulting to `max+1` scoped to `project_id`, `move_higher`/`move_lower`, `<=>`, and a
   `before_destroy` reflow. ~35 lines. **Without this the plugin boots and then 500s on
   `ReporterProjectTab`.**
2. `ReporterDashboards.reporter_present?` — computed **once** at `after_plugins_loaded`,
   memoised, and every reporter-touching site guarded by it.

**Changes.** `init.rb:12-16` raise → soft detect; `:33` `requires_redmine_plugin` deleted;
`register_issue_target_version_drop` and `apply_reporter_patches` gated on the flag.

**The two report widgets leave the picker, they do not render a placeholder.** `ProjectPage.blocks`
is `CORE_BLOCKS.merge(additional_blocks)` and `additional_blocks` globs partial files
(`project_page.rb:55-62`), so move `blocks/_report_by_issues.erb` and `_report_by_spent_time.erb`
into `blocks/optional/` and include that directory only when `reporter_present?`. **Handle the
already-placed case explicitly:** `find_block` returns nil, so `show.html.erb` must skip unknown
blocks, log one line, and render an inline *"widget unavailable"* cell carrying
`degraded: true` (INV-4) — a dashboard that already has the widget must not 500.

**`report_pdf`** returns **404** when `reporter_present?` is false. Today the analogous path
returns 500 (`:85-91`). In a monitored install a 500 is an alert about a broken thing; a 404 is a
correct statement about a capability that is not installed. Both branches asserted.

**Proof.** A boot spec with `Redmine::Plugin.installed?` stubbed false; a **new
`minitest-standalone` CI job** — full-app, 4 Redmine branches, **no secret** (this is the G1
proof and it lands here, not later); a functional test placing a report widget with reporter
absent → 200 + degraded marker; and `zero_reporter.sh` in **warn** mode so the remaining sites
become a burn-down number.

### Step 2 — own the render path *(ships 0.7.0)*

Introduce L3 in full (§5) plus **two** adapters. `report_pdf` stops calling `Report#to_pdf` and
builds a `DocumentRequest`. `patches/report_patch.rb` (97) is **deleted**.

**Correction to ADR-004's consequence list:** `pdf_polyfills.rb` (61) is **not** deleted here —
it moves to `glue/legacy/wk_legacy_shims.rb` behind the wkhtmltopdf adapter, and is only
recoverable when that engine is dropped.

**Prerequisite:** the `render-smoke` job and the conformance fixture corpus exist *before* either
adapter is trusted, and the job runs the engine **in a different network namespace** so asset
resolution is genuinely tested rather than accidentally passing over localhost.

### Step 3 — own the Liquid layer, re-seam **both** tags *(ships 0.8.0)*

**The ordering constraint the dossier did not state:** today the *only* thing that parses and
renders a Liquid template is reporter (`issue_list_report_template.rb:25`). The tags therefore
cannot be re-seamed until something **we own** creates the render context. So step 3 must include
a **minimal own `TemplateRenderer`** — parse + render one stored body against a `RenderContext`.
Template **CRUD/UI** waits for step 4; the **renderer** cannot.

Replace `include SqlAggregation::ScopeResolution` at **both** `liquid_aggregate_tag.rb:106`
**and** `liquid_version_rollup_tag.rb:38` with `include Liquid::ScopeBinding`.
`{% geo_version_map %}` (144) + the addon's `VersionDrop` (108) + `issue_drop_patch.rb` (43)
**dissolve** — **295 lines of pure workaround on top of the ~600 ADR-004 counts.**

**`scope_resolution.rb` is not deleted here.** It is demoted to
`glue/legacy/reporter_scope_binding.rb`, loaded only when `reporter_present?`, so an install still
running reporter keeps its drill-through. Deleted at 1.0. Deleting it in step 3 would break every
existing install mid-sequence, violating "every increment independently shippable **and**
valuable".

**Proof.** The `corpus` job stays green across the re-seam — **the single most important assertion
in the sequence.** Gate: `Thread.current` absent from `lib/`/`app/` outside `glue/legacy/`.

### Step 4 — absorb the bounded reporting subset *(ships 1.0.0)*

Own tables and models (§7), template types, scheduler with run state, my-page widgets, CRUD +
preview + safe import/export. Deletes C4–C13, all of `glue/legacy/`, the CI secret, the
`reporter-secret` probe job and the secret-gated `minitest` job. `zero_reporter.sh` flips from
warn to **hard gate**.

### Step 5 — retire wkhtmltopdf *(post-1.0, condition-triggered)*

Removed when its `render-smoke` job can no longer be kept green on supported distro images —
INV-7 applied to an engine. Only then do the 61 shim lines disappear.

### 2.7 Why render before Liquid

1. `04-risks.md`'s failure scenario is explicit: the kill came from the **greenfield render
   path** plus one unrun query — not from distribution. Front-load the greenfield while the
   incumbent still works and the corpus is fresh.
2. Step 2 needs nothing from step 3: `DocumentRequest` takes HTML. Step 3 needs an owned render
   entry point, and step 2's `report_pdf` rework is where it lives.
3. Step 2 is where the engine measurement happens, and it gates the chart architecture (§6),
   which gates the `{% chart %}` tag in step 3. Reversing means designing the chart tag before
   knowing whether `:javascript` is an essential capability.

## 3. The own-drop layer (R6)

Goals in order: **template-body compatibility** (keeping field names identical is R-10's cheapest
mitigation), **fix the scalar defect**, **kill the N+1 by construction**, **shrink the privilege
surface**.

### 3.1 Classes — 13 + 3 bases (the gem has 17)

Bases: `RecordDrop` (one record + a `Batch` handle), `CollectionDrop` (a scope), `NamedRefDrop`.
Keep: `Issue`, `Issues`, `User`, `Users`, `Project`, `Projects`, `Version`, `TimeEntry`,
`TimeEntries`, `Attachment`, `CustomFieldValue`.

> **The heading and the list disagree, and T-18 built the list.** The heading says thirteen; the
> line above enumerates **eleven**. T-18 shipped those eleven plus `CustomFieldValues`, the
> bracket-lookup sibling that carries the addon's existing `issue.custom_field_value[20]` surface
> across T-20's deletion of `issue_drop_patch.rb` — **twelve**, held as
> `Liquid::Drops::CLASSES` and asserted by spec. Recorded as §Findings **F-9** rather than
> resolved by picking whichever number reads better.
Drop: `IssueRelation(s)`, `Journal(s)` `[OQ-H — narrowed: not part of the six required capabilities]`, `News(s)` (the double-`s` typo is itself
disqualifying; the dashboard has a native news widget), `CustomFieldEnumeration` (folded in).

### 3.2 `IssueDrop` — explicit disposition

**Keep, identical names** (zero-cost compatibility): `id subject description start_date due_date
done_ratio estimated_hours spent_hours total_spent_hours total_estimated_hours created_on
updated_on`.

**Keep + fix:** `closed_on` — reporter converts `created_on`/`updated_on` to the user timezone
but **not `closed_on`** (`issues_drop.rb:22-28`), i.e. three date accessors in two timezones. All
three go through `RenderContext#actor`.

**Rename + alias:** `visible? closed? overdue? is_private?` → `visible closed overdue private`,
with the `?` names retained as aliases — **mandatory, not optional**. OQ-B was measured on
2026-08-04 and the guess below is **wrong**: `{{ issue.closed? }}` parses and resolves on Liquid
4.x and 5.x (the lexer permits a trailing `?` by design), so the `?` spellings are reachable and may
be in real templates. Dropping them would be a breaking change. A linter rule that flags them as
unparseable would be wrong. Retained for the record, struck through: ~~`[OQ-B]` `{{ issue.closed? }}` is very likely not
parseable by Liquid's variable grammar, which would make these accessors **dead surface in the
gem**; one 5-line spec against 4.x and 5.x settles it.~~ It did.

**Keep name, fix type** → `NamedRefDrop`: `tracker status priority category`; `version` →
`VersionDrop`. Plus new `tracker_id status_id priority_id category_id fixed_version_id`.

**Keep + fix:** `url` — **always absolute**, built from `Setting.protocol`/`host_name`. This is
what makes `Report#build_content`'s Nokogiri-or-regexp URL rewriting (38 lines plus a regexp
fallback, `report.rb:59-96`) unnecessary: absolute-by-construction beats rewriting-after-the-fact.

**Keep:** `link author assignee project parent custom_field_values`; `attachments time_entries
subtasks` **batched** (§3.4).

**Drop:** `notes journals relations_from relations_to` `[OQ-H]`; and **all six**
`respond_to?`/`defined?` probes into other RedmineUP paid plugins — `tags story_points color
day_in_state checklists helpdesk_ticket` (`issues_drop.rb:131-157`). Vendor-ecosystem coupling
with no reason to be reproduced and dead weight everywhere else.

**Drop from reporter's own subclass:** `project_name` (fold into `project.name`); `images`
(returns a drop whose `file_url` mints unexpiring token URLs — an explicit non-goal; replaced by
`| inline`); `available_statuses spent_time_by_date total_spent_time_by_date watchers` (each an
unbatched N+1, superseded by the aggregator). `time_in_status`/`total_time_in_status` are the only
per-issue analytics with a plausible constituency — `[OQ-H]`.

**`IssuesDrop`:** `[]`/`before_method(id)`, `each`, `size`, `visible`, `first(n)`. **`all` is not
implemented** — the gem's `all` maps every record into a drop, which is the O(n) materialisation
`reporter_report_content_patch.rb` exists to avoid. A template calling it gets a parse-time lint
warning and a render-time `Degradation(:unbounded_collection)`.

### 3.3 `NamedRefDrop` — the scalar fix, and the 295 lines it deletes

Wraps `(id, name, url)` and implements the five methods that make it **substitutable for the
String it replaces**:

| Method | Behaviour | Protects |
|---|---|---|
| `to_s` | `name` | `{{ issue.status }}` |
| `==(other)` | `name == other` for a String | `{% if issue.status == "Closed" %}` |
| `eql?` / `hash` | delegate to `name` | hash-keyed grouping filters |
| `include?(s)` | `name.include?(s)` | `{% if issue.status contains "Clo" %}` |
| `to_liquid` | `self` | drop protocol |

**Every one is a claim about Liquid's internals and must be proven by test, not by reasoning** —
a required spec renders each idiom under **both Liquid 4.0.x and 5.x** and asserts byte-equality
with the String behaviour. ~~`[UNVERIFIED]` until green.~~ **VERIFIED 2026-08-06** on Liquid
**4.0.4 and 5.13.0**, `spec_liquid/named_ref_drop_spec.rb`; the five methods now live in
`Drops::StringSubstitutable` and `VersionDrop` includes them too, so `spec_liquid/drops_spec.rb`
runs the same battery a second time — a shared module is not evidence that the sharing worked.
The proof found a protocol-breaking defect and **two gaps in this table**, both recorded as
§Findings **E-8** and decided by the curator: the comparison only works with the drop on the LEFT,
and `{{ status | size }}` answers `0` where the String answered its length. Both are pinned by
tests that assert them AS THEY ARE, and T-19's linter owes a rule for each.

Belt and braces deliberately: the `*_id` accessors ship **as well**. Five one-line methods, and
they are the escape hatch if the Drop-vs-String semantics bite in a shape the spec did not
enumerate.

*Rejected — keep Strings, add `*_id` only.* Steelman: zero compatibility risk, satisfies R-10
perfectly. Critique: it hard-codes the vocabulary (no `status.url`) and does **not** dissolve
`{% geo_version_map %}`, which needs `{id, effective_date, status, project}` per version name
(`liquid_version_map_tag.rb:56-60`). Two tags and 295 lines would survive for nothing.

The `{% geo_version_map %}` **name** is retained for one minor version as a deprecation shim that
logs once and builds its map from `Version.visible` — **never `Version.all`**, which was one of
the five 0.5.0 visibility leaks.

### 3.4 Batch registry — killing the N+1 by construction

Two mechanisms, **both required**:

**M1 — association preload.** `CollectionDrop#each` iterates
`scope.preload(:status, :tracker, :priority, :category, :fixed_version, :assigned_to, :author,
:project).find_each(batch_size: 500)`. Bounded memory *and* bounded queries — and simultaneously
the fix for the "10 000 loaded `Issue` objects" problem that C5/C6 exist to work around.

**M2 — first-touch batch resolution.** `Batch` is a per-render object on `RenderContext`, holding
the full id set. The *first* `{{ issue.custom_field_value[20] }}` inside a 500-issue loop triggers
**one** query for all 500 and memoises; the other 499 are hash lookups.

| Key | One query | Feeds |
|---|---|---|
| `:custom_field_values` | `CustomValue.where(customized_type:'Issue', customized_id: ids)` | `custom_field_value(s)`, `\| custom_field` |
| `:spent_hours` | `TimeEntry.where(issue_id: ids).group(:issue_id).sum(:hours)` | `spent_hours`, `total_spent_hours` |
| `:attachments` / `:time_entries` / `:subtasks` | one query each | the matching accessors |
| `:named_refs` | `IssueStatus/Tracker/… .where(id: ids).pluck(:id,:name)` | every `NamedRefDrop` |

**Cap** mirroring the aggregator's discipline: `MAX_MATERIALISED_RECORDS` default **5 000**; past
it `each` stops, logs one line, and sets `Degradation(:collection_truncated, seen: n)` — visible,
never silent (INV-4).

**Absolute performance criteria** (converting A11/R7 from unfalsifiable to testable, with no
target needed): **zero `Issue` instantiations** for an aggregate-only template (subscribe to
`instantiation.active_record`, require 0) and **query count identical** at 10 vs 10 000 issues.

### 3.5 `RenderContext` — the IssueQuery carried explicitly

Frozen value object: `actor` (never an ambient `User.current` read — INV-1), `scope` (always
derived from `IssueQuery#base_scope` by the glue), `issue_query`, `scopes` (named scopes `from:`
may reference), `batch`, `charts`, `assets`, `diagnostics`, `limits`, `budget`, `output`
(`:html|:pdf`), `correlation_id`.

Passed as **exactly one** Liquid register, `registers[:reporter_dashboards]` — one grep-able
surface that cannot be half-populated, and the resolution order collapses from six sources to two.

`ScopeBinding` (303 → ~60 lines): `resolve_scope` = (1) `query_id:` →
`IssueQuery.visible(actor).find_by(id:)` → `base_scope`, retaining `scope_resolution.rb:148-163`'s
exact semantics; (2) `scopes[from]`; (3) `context.scope`; (4) nil. `resolve_query` = `query_id:`,
then `context.issue_query`, then nil, through the single `#visible?` gate ported verbatim from
`:196-207`.

**Deleted with it:** the `drop.instance_variables` walk (`:256-297`), the `:container`/`:controller`
ivar archaeology (`:100-134`), the `Issue.where(id: ids)` reconstruction from a loaded Array
(`:279-282`), the thread-local `QUERY_THREAD_KEY` (`:47`) and `reporter_list_patch.rb`'s
`rrd_with_issue_query` (`:81-88`) — **and `#enforce_visibility` (`:80-90`), whose `rescue` fails
open by design** precisely because the drop path's provenance could not be vouched for. Once every
source is `base_scope`, there is nothing left for it to protect, and the fail-open rescue goes
rather than being carried forward as a hedge nobody re-audits.

### 3.6 Filters — 55 gem + 12 reporter → ~28 owned

> **OQ-C is CLOSED (2026-08-06, measured in T-19) and it changes this list.** `where` and
> `sort_natural` are **inherited** — provided identically by 4.0.4 and 5.13.0 and already
> working on the owned drops. `sum` is **owned** because only 5.x has it. `| inline` is
> **deferred to T-33**, which owns `asset_policy`: a filter that embeds asset bytes without
> consulting that policy is the "an author widens egress by editing a document" shape T-33's
> acceptance list forbids, and it would be rewritten by T-33 anyway. That leaves **21 owned
> filters**, held as `Liquid::Filters::OWNED` and asserted by spec, with `INHERITED`,
> `REMOVED` and `DEFERRED` beside it carrying the reason for each. §Findings **F-10**.
>
> `replace_all` needs no code: §3.6 gives it as the replacement for the removed
> `regex_replace`, and Liquid's own `replace` already replaces all.

**Reimplement:** `avg median min max sum` (property forms; **subtract whatever Liquid 5's
`StandardFilters` already provides** — ~~`[OQ-C]`~~ closed, see above), `currency duration wiki hex_color
contrasting_text_color darken lighten group_by group_by_custom_field where where_custom_field
custom_field custom_field_by_id custom_fields sort_natural utc`, **`json`**, **`js`**, **`inline`**.

**`| json` is mandatory.** `JSON.generate` plus script-context escaping — `<` → `<`, `>` →
`>`, `&` → `&`, U+2028/U+2029 escaped. Safe inside `<script>` *and* inside
`<script type="application/json">`, which is where §6 puts chart data. `| js` is the scalar form.
Both used in **every** example and README snippet — the examples are the spec, and today the
copy-paste surface carries the defective idiom (`sample_report_template.liquid:139-141`,
`version_status_dashboard.liquid:514-524`).

**Drop for security, with the reason:**

| Filter | Why |
|---|---|
| `call_method(input, method_name)` | invokes an arbitrary named method on an arbitrary object from inside a template — the sharpest single instance of INV-9. Removal is a security requirement, not scope |
| `regex_replace` / `_once` | template-supplied regexes are a ReDoS primitive against a renderer with a wall-clock budget. Replaced by literal `replace_all`/`replace_first` |
| `md5` | exists to mint the unexpiring capability token |
| `file_url` | resolves to the anonymous unexpiring-token attachment URL (`filters.rb:151-153`). Replaced by `\| inline` |

**Drop as cleanup:** Liquid-core duplicates (`ceil floor round modulo`), cosmetics
(`dasherize underscore ljust rjust multi_line encode`), **mutating** filters (`push pop shift
unshift` — a correctness hazard over a shared object mid-render), **`random shuffle`**
(non-deterministic output defeats golden testing outright and has no place in a document that may
be an audit record), `jsonify`, the attachment plumbing, the internal helpers, `tagged_with`.

**Registration is per-render, never global.** The gem registers four filter modules globally at
require time and monkey-patches `to_number` into `Liquid::StandardFilters` unconditionally
(`patches/liquid_patch.rb:29-31`); reporter does the same (`filters.rb:184`). **Never do this** —
other plugins share the process.

## 4. Liquid execution policy

Today: `parse(content).render(...)` with **no resource limits**, output `.html_safe`, errors
returned **as the document** (`issue_list_report_template.rb:25-27`).

**Scoping.** Never `Template.register_filter`. Construct the `Liquid::Context` and call
`context.add_filters([...])` — works on 4 and 5. Where `Liquid::Environment` exists, scope **tags**
too. Tag registration on Liquid 4 is irreducibly global: accept it, keep the existing
rescue-per-registration discipline so one failure cannot take the others down, and namespace the
names. `{% include %}`/`{% render %}` rejected **at parse time by the linter**, because a raise
mid-render is a diagnostic problem while a lint failure is an authoring problem.

**Resource limits** (`render_length_limit`, `render_score_limit`, `assign_score_limit`) per output
class — widget 2 000 000 / 200 000 / 500 000; report 16 000 000 / 2 000 000 / 4 000 000; preview
= widget, **deliberately**, so an author feels the limit while authoring rather than in a 06:00
scheduled run. `[OQ-J]` **The mechanism is the decision; the constants are a starting
calibration** — set them at ~10× the reference corpus's measured p95.

**Wall-clock timeout, because resource limits bound *work units* not *time*** — a
`{% sql_aggregate %}` running a 90-second query costs one render-score point. A **cooperative
deadline** on `RenderContext#budget`, checked at the top of every own tag's `render`, every
`CollectionDrop#each` batch boundary, and every `Batch#prefetch`. Defaults 5 s widget / 30 s
report / 10 s preview. **Honest limitation: cooperative means bounded only where we cooperate** —
an adversarial `{% for %}` using only core filters can still burn CPU, which is what
`render_score_limit` is for. Neither mechanism alone suffices; both are required.
**`Timeout.timeout` is rejected** — interrupting ActiveRecord mid-statement trades a slow render
for a poisoned connection pool.

**Error mode.** Parse `error_mode: :strict` **per parse**, never the global setting; a parse error
is a model validation failure *and* a typed render failure. Render collecting, with
`strict_filters: true` (an unknown filter is an error) and `strict_variables: false` (every
existing template relies on an undefined variable rendering empty). **Errors never enter the
document:** `template.errors` non-empty → `degraded` + the list into the diagnostics channel with
correlation id, template id, project id, actor and duration, while the document gets a neutral
placeholder. The reason is concrete: an `ActiveRecord::StatementInvalid` from `{% sql_aggregate %}`
puts the full SQL — role ids, member ids, project ids — into the document, which
`create_attachment` then persists.

**Output safety.** **No `html_safe` anywhere.** The renderer returns a `Render::Document` value
object; the view uses `raw` at **exactly one** call site, which is the documented trust boundary.
Gate `no_html_safe.sh` allows `html_safe|\braw\(` in ≤2 files.

**Opaque-origin sandbox.** Widget HTML is served into an iframe from a **same-origin** Redmine
route today (`_report.html.erb:28`), so template JavaScript has the viewer's session. Change: the
content endpoint sets `Content-Security-Policy: sandbox allow-scripts; default-src 'none';
img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'` and the element carries
`sandbox="allow-scripts"` — **without** `allow-same-origin`, putting the frame in an opaque
origin. **Named regression to handle rather than discover:** the height-fit script reads
`frame.contentWindow.document` (`:37-46`) and **breaks** under an opaque origin. Replacement: the
shell posts its height via `postMessage`; the parent listens with an
`event.source === frame.contentWindow` check and a numeric-range guard.

**INV-9 as an enforced boundary — five mechanisms + three reductions.** Permission label reads
*"Author report templates (executes server-side code)"* with an inline warning on the permissions
screen and a README section; **the granular role-permission model of §4.1**, which replaced the
`template_authoring: :admins_only | :project_managers` setting this paragraph used to name
(`[OQ-F]` **CLOSED 2026-08-06 by curator decision** — the setting is deleted, not defaulted); the
opaque-origin iframe; zero renderer egress; and an **append-only `template_versions` table** — *a
code-execution privilege without an audit trail is not a boundary*, and it gives authors rollback
they want anyway. Reductions: no `call_method`, no template regexes, no token-minting filters.

### 4.1 The permission model — INV-9's boundary is a role grant, not a plugin setting

**Curator decision, 2026-08-06, verbatim in substance:** *the plugin must provide permissions in
the normal Redmine way, so that roles can be given exactly what they may and may not do; there
will need to be a fairly extensive permission system.* The `template_authoring` setting is
**deleted**, and `[OQ-F]` — which asked only which of its two values should be the default — is
closed with it.

**The rejection was right, and for a reason worth recording rather than merely obeying.** The
recommended value for upgraded installs, `:project_managers`, would have **widened a
code-execution privilege on upgrade, silently, installation-wide**, to whatever set of roles an
operator thinks of as managers. That is the failure this project keeps naming, pointed the other
way — and it is worse than the break it was avoiding, because a break is visible. The other value,
`:admins_only`, would have put the feature out of reach of the person it is for. Neither is
recoverable by picking better, because the *shape* is wrong: a setting cannot say *"this role, in
this project"*, and that is the only sentence that answers the question.

**Where the model lives.** `lib/redmine_reporter_dashboards/permissions.rb` — as **data**, not as
a list of calls inside `Redmine::Plugin.register`, so that
`spec/permissions/permission_map_spec.rb` can assert it. `init.rb` reads the same data and is the
only place it becomes a registration.

#### The set — 13 permissions in two modules

`Module`: `D` = `:reporter_project_dashboards` (**pre-exists**; the name cannot change, an
installation has it enabled per project). `R` = `:reporter_dashboards_reports` (**new** — *"we
want dashboards, not the reporting surface"* is a real answer, and a project module is how Redmine
asks that question). `Req` is Redmine's `require:`; `read` is Redmine's `read: true`, meaning
*permitted in a **closed** project*.

| Permission | Mod | read | Req | Covers | Lands in |
|---|---|---|---|---|---|
| `view_reporter_project_page` | D | ✓ | — | Open a project dashboard, and export it as a PDF | **live** |
| `manage_reporter_project_page` | D | — | — | Add, remove, move and configure dashboard widgets | **live** |
| `manage_reporter_project_tabs` | D | — | — | Create, rename, reorder and delete dashboard tabs | **live** |
| `view_reporter_dashboards_reports` | R | ✓ | — | See the templates a project offers; open or download the document one produces | **live** |
| `view_reporter_dashboards_schedules` | R | ✓ | — | See a schedule and its run state — last run, status, duration, error — without changing it | **live** |
| **`add_reporter_dashboards_templates`** | R | — | `member` | **Create a report template. Code execution (INV-9)** | **live** |
| **`edit_own_reporter_dashboards_templates`** | R | — | `member` | **Edit and delete the templates you authored** | **live** |
| **`edit_reporter_dashboards_templates`** | R | — | `member` | **Edit and delete any template in the project** | **live** |
| **`manage_public_reporter_dashboards_templates`** | R | — | `member` | **Give a template a visibility wider than its author** — Redmine's `manage_public_queries` decision, for templates | **live** |
| `manage_reporter_dashboards_schedules` | R | — | `member` | **See**, create, edit, disable and delete schedules, choose recipients, send a test run. It maps `#index`/`#show` as well as the writing actions — a permission that can change a thing it cannot look at is broken rather than milder, and leaving them out made a role holding this one alone get a 403 on the redirect after its own successful create | **live** |
| `render_reporter_dashboards_reports_as_others` | R | — | `member` | **Bind a schedule to another user's render identity, and test-send one. Grants access to everything that user can see** — added 2026-08-08 by the curator's answer to S-10, after T-25's UI review turned an unfiltered `render_as_user_id` into a working privilege escalation. It maps NO action: it widens a field behind `manage_…_schedules` rather than opening a door, so holding it alone lets you do nothing | **live** |
| `mail_reporter_dashboards_reports` | R | — | `loggedin` | Send a report by e-mail on demand, to Redmine users | T-32 |
| `share_reporter_dashboards_reports` | R | — | `member` | Create a share link: an expiring, revocable URL serving a snapshot to whoever holds it | T-28 |
| `publish_reporter_dashboards_reports` | R | — | `member` | Turn a share link into a **public** link, reachable without a Redmine account (FR-62) | T-28 |

The four in bold are the code-execution class, and their `require: :member` is **derived** from
that fact rather than typed on each row (`Entry#requires`), so the two cannot come apart.

**This table is FROZEN at 13 by curator decision, 2026-08-06** — *"already very very fine grained, I
wouldn't expand unless really necessary"*. It is the contract, not a starting point: a later task
wanting a fourteenth argues for it against that sentence, and after T-23 registers these, splitting
or renaming one costs a migration and an upgrade note because permission names are a public contract
(§1). The cheap moment to disagree was before this line.

**A `visibility` column on the template model is a consequence of row 9** and belongs to **T-22**,
the tables task — not to T-23 and not to a later retrofit. `manage_public_…` has nothing to govern
without it, and §7 rule 6 requires a column to be created in the same migration as its table, so
assigning it anywhere else licenses exactly the second migration that rule forbids.
**Private / roles / public** — corrected 2026-08-07, finding **S-4**: this line said
*"private / roles / project"*, and Redmine's third value is `VISIBILITY_PUBLIC`, labelled *"to any
users"* (`app/models/query.rb:261`, `config/locales/en.yml:1076`). The three values Redmine's saved
queries already use, so an administrator meets one concept rather than two — which is only true if
the words are core's as well as the integers, so T-23's form renders core's own
`label_visibility_private` / `_roles` / `_public` rather than adding a key of its own. Only the
prose was ever wrong; T-22's constants were core's from the start.

**`read: true` on `view_reporter_dashboards_reports` is a decision, recorded rather than left
implicit.** It means the permission still applies in a **closed** project, and opening a report runs
a template and may start a PDF engine — more expensive than any `read: true` in Redmine core, all of
which are cheap reads. Kept deliberately: reading last quarter's report out of a project the
organisation has since frozen is most of what a closed project's reports are *for*, and the cost is
bounded by §4's execution policy and FR-32's caps rather than by this flag. The authoring
permissions are **not** `read: true`, which is where the closed-project line actually matters.

**The three live permissions are unchanged, including the absence of `require: :member` on the two
`manage_` ones.** Neither is a code-execution privilege, so the derivation does not reach them — and
adding it by hand would do something worse than warn. **Stated precisely, because the first draft of
this paragraph got the mechanism wrong:** nothing is revoked. `Role#permissions=` writes whatever it
is given, unfiltered and unvalidated, and `Role#allowed_to?` keeps honouring an existing grant; what
changes is that `roles/_form` renders only `setable_permissions`, so the grant becomes **invisible on
the roles screen while still active** and is dropped the next time anybody saves that role for an
unrelated reason. An active-but-unmanageable permission that vanishes later without a trace is worse
than either revoking it or leaving it. Left alone deliberately.

**And the cost of leaving them, said out loud:** a permission with neither `require:` nor `public:`
**is** offerable to the Anonymous and Non-member roles, so an administrator can grant *Manage project
dashboard widgets* to Anonymous today. Pre-existing behaviour, not a new decision — written down so
the next person weighs it rather than rediscovers it.

**Nothing planned is registered until its controller exists.** A permission an administrator can
tick that guards nothing is a lie in the interface. Promotion is one move with four parts — fill in
the action map, drop the task id, add the nine `permission_<name>` labels, and (for the first entry
promoted) the nine `project_module_reporter_dashboards_reports` labels, because the reports module is
new and both `roles/_form` and `projects/settings/_modules` render its legend through
`l_or_humanize(mod, prefix: 'project_module_')`. The parity spec asserts all four.

#### Deliberately *not* permissions

An unused checkbox costs an administrator attention every time they read the roles screen, so each
of these was considered and rejected with a reason:

| Considered | Instead | Why |
|---|---|---|
| Exporting a document, separately from viewing one | `view_…_reports` | Redmine does not separate "see the issue list" from "export it as CSV". Render cost is bounded by FR-32's caps and the engine's own limits, not by a role grant |
| Importing a bundle | `add_…` **and** `edit_…` | Import **is** authoring: it creates templates whose content is code. A weaker permission of its own would be a way around the authoring one |
| Exporting a bundle | whichever permission shows the content in the editor | The bundle **is** the content |
| Reading version history, rolling back | the same permission that edits that template | FR-21's audit trail is for whoever can change the thing |
| Revoking a share link | the link's creator, the template's owner, admins | FR-53 makes it ownership, which a permission cannot express |
| Sending to an external address | admin setting + domain allowlist | FR-61 already puts it there: a policy about the installation, not a capability of a role |
| Authoring a template with no project | admin | Redmine has no role grant outside a project, so `project_id IS NULL` is admin-only by construction |

#### How `[OQ-F]`'s two worries are answered without a default

* *A fresh install must not hand out code execution.* **This plugin grants nothing** — it can
  declare a permission, it has no way to tick one — so on any install that already has roles,
  authoring starts nowhere and only administrators (whose flag bypasses the check) can author.
  Asserted mechanically: nothing in `app/`, `lib/`, `db/` or `init.rb` calls `add_permission` or
  writes `roles_permissions`.

  **THE ABSOLUTE FORM OF THAT CLAIM IS FALSE, and this section said it before the review of T-40
  refuted it.** Redmine's own default-data loader runs, identically on 5.1 → 7.0
  (`lib/redmine/default_data/loader.rb:51`):

  ```ruby
  manager.permissions = manager.setable_permissions.collect {|p| p.name}
  ```

  and `Role#setable_permissions` subtracts only `public_permissions` for a givable role. So on a
  **brand-new** install — `Role.where(builtin: 0)` empty, which is the loader's own precondition —
  *Load the default configuration* with this plugin already present grants the **Manager** role
  every setable permission of ours, `require: :member` included. Once T-23 registers the authoring
  four, that is literally `:project_managers`, arriving from core rather than from a setting.

  **This is not a reason to restore the setting.** The setting would have produced the same grant on
  *every* install rather than on one ordering, and silently. It is a reason the diagnostic below must
  report **our** roles rather than only the base plugin's, and a reason a grep of this repository is
  not evidence for the absolute claim — the grant is made in code this repository does not contain.
* *An upgraded install must not break silently.* Not answered by a default either, because the
  default would have closed the gap by *granting* code execution to roles nobody re-examined.
  Answered by naming it: **the preflight page and `import:plan` list every role holding the base
  plugin's authoring permission and every role holding ours**, so the administrator reads the
  situation instead of discovering it (T-24, T-27) — and, per the paragraph above, that list is also
  the only thing that surfaces a Manager role seeded by core.

#### Four mechanisms, so the model is enforcement and not prose

1. **`require: :member` on every authoring permission, DERIVED from `authoring: true`** — the field
   is not written on the entry at all, `Entry#requires` reads it from the flag, and an example
   asserts no authoring entry writes one. It is Redmine's own machinery refusing to *offer* a
   code-execution privilege to the Anonymous or Non-member role (`Role#setable_permissions`
   subtracts `members_only_permissions` for Non-member and `loggedin_only_permissions`, a superset,
   for Anonymous). The label is a warning; this is the control. **Precisely: "never offered" is not
   "never granted"** — `add_permission!`, a rake task or a hand-crafted POST all bypass the roles
   screen, because `Role#permissions=` does no filtering.
2. **`authorize` is checked, per ACTION.** The parity spec parses each controller with
   `RubyVM::AbstractSyntaxTree` and fails if `authorize` does not run for a mapped action —
   honouring `only:`, `except:` and `skip_before_action`. Per *controller* was the first version and
   the review of T-40 hollowed it out with two lines: `before_action :authorize, only: [:create]`
   plus `skip_before_action :authorize, only: [:order]` left three of four mapped actions
   unauthorized with the suite green.
3. **No action is unaccounted for, and reachability is checked from the routes as well.** Every
   public action of every controller — **searched recursively, so a namespaced controller counts**,
   and including a `def` nested inside a version conditional — is either mapped by a declared
   permission or listed in `NON_PERMISSION_GUARDS` **with the guard it really uses**, which the spec
   verifies against the controller *for that action*. `config/routes.rb` is read too, so a route to
   an action the reader cannot see is a failure rather than a silent gap, and a route written in a
   form the reader does not recognise fails instead of being skipped. `define_method` in a controller
   body is **refused**: its name can be computed, so no parser can promise to know the action it
   creates. Today three actions are listed (`reporter_preflight#show`, `#run` → `require_admin`;
   `sql_stats#monthly_flow` → `require_login` plus core `:view_issues` over `Issue.visible`). An
   allowlist nobody verifies is how an unguarded action gets written down as a decision.
4. **A permission-name collision is checked at boot.** §7 makes simultaneous installation with the
   base plugin a *design goal*, and `Redmine::AccessControl` keeps permissions in a flat array with
   no uniqueness check: two plugins registering one name give two identical rows on the roles
   screen and an action map that is the union of both. Every name added here is prefixed to make
   that implausible, and `after_plugins_loaded` logs at **error** if it happens anyway — because
   "implausible" is not a mechanism. Loud, not fatal (INV-4): refusing to boot over another
   plugin's registration would take the dashboards down for something the operator cannot fix from
   here. The message is built by a tested method rather than inline in the boot hook, and reaches
   stderr when there is no logger rather than reaching nobody.

**Liquid 5 deltas that matter:** `Strainer` → `StrainerFactory`/`StrainerTemplate` (which is *why*
per-render scoping is a portability decision, not only hygiene); `Drop#invokable_methods`
memoisation moved — **the addon's memo-clearing hack disappears**, a concrete R6 payoff;
`ResourceLimits` field names and the raised class; `Context.new` signature; the per-parse/render
option names; core `sum`/`where`/`sort` coverage widened. Plus a mandatory **`StandardFilters`
enumeration spec** asserting the exact public-method set, so a Liquid upgrade that adds a filter
is a **CI failure** rather than a silent capability grant — INV-7 applied to a dependency.

## 5. The PDF engine abstraction

**Not "HTML in, bytes out."** A document request.

**`DocumentRequest`** (frozen): `body` (a complete, already-asset-resolved HTML document);
`assets` (for upload-model engines); `page` (`size`, `orientation`, `margins`, `scale`);
`header`/`footer` as **`PageFurniture`, not HTML**; `media` (`:print` default);
**`print_backgrounds` default `true`**; `page_breaks`; `readiness`; `timeout_ms`; `pdf_metadata`
incl. the mandatory engine/version/plugin/duration stamp; `tagged`/`outline`; `correlation_id`.

`print_backgrounds` defaults **true, not to the engine's default**, because Chromium's
`printToPDF` defaults it to `false` and a naive swap silently loses every badge and progress-bar
colour in the existing templates. **Overriding engine defaults that differ across engines is part
of the abstraction's job**, not the caller's.

**`PageFurniture`** — `{left, center, right, font_size_pt, height_mm, separator}`, each slot
literal text plus tokens from a **closed set**: `{{page}} {{pages}} {{title}} {{date}} {{time}}
{{datetime}} {{project}} {{template}} {{plugin_version}} {{engine}} {{render_duration_ms}}`.
Compiled per engine: Chromium → `<span class="pageNumber">` in a standalone document;
wkhtmltopdf → `[page]`/`[topage]`; WeasyPrint → `@page { @bottom-right { content: counter(page) }}`.
The last four tokens exist so a PDF someone e-mails you six months later says which engine drew
it. **Templates may never emit engine-native footer markup** — the linter rejects `[page]`,
`[topage]`, `class="pageNumber"`, `class="totalPages"`, `@bottom-`, `@top-`.

**Engine interface — four methods.** `.id`; `.version` **probed from the binary/container, never
a constant**; `.capabilities → Set<Symbol>` from a closed vocabulary (`:javascript
:readiness_expression :print_backgrounds :header :footer :page_furniture_tokens
:custom_page_size :landscape :margins :scale :page_break_css :media_print :outline :tagged_pdf
:pdf_metadata :asset_inline :asset_upload :asset_http :timeout`); `#preflight` — a **round trip**,
never `File.exist?`; `#render(request) → Result`.

`Result = Success{bytes, page_count, duration_ms, engine, engine_version, degradations}` |
`Failure{code, message, engine, engine_version, duration_ms, detail, correlation_id}` with a
closed code set (`:engine_unavailable :engine_version_unsupported :timeout :readiness_timeout
:resource_limit :asset_unresolved :capability_unsupported :engine_crashed :output_not_pdf
:output_empty :internal`). **Never raises. Never returns HTML.**

**INV-5 becomes mechanical** via two post-conditions enforced by `Render::Renderer`, the wrapper
**above** every adapter: bytes must start `%PDF-` and contain `%%EOF`, else rewritten to
`Failure(:output_not_pdf)`; bytes must exceed `MIN_PDF_BYTES`, else `Failure(:output_empty)`. **No
adapter can violate INV-5 even by accident**, and `create_attachment` accepts only a `Success` —
type-driven, not nil-driven as today. **Falsification stated up front: the byte check kills
"exception as document" and does nothing about a *valid* PDF whose content is wrong** — a blank
canvas, a lost background. That class is addressed only by the preflight pixel/text probes and the
degradation list. Never let the byte check stand in for the whole invariant.

**Capability negotiation.** `missing = request.required - engine.capabilities`; missing
**essential** → `Failure(:capability_unsupported)` naming it; missing **degradable** → proceed,
append a `Degradation`, log it, surface it in diagnostics, **and stamp it into the PDF metadata**.
`:javascript`/`:readiness_expression` are essential **iff** `ChartCollector` recorded a JS-path
chart — generalising `PdfPolyfills.charts?`'s `<canvas>` regexp (`pdf_polyfills.rb:45-47`) into a
fact the renderer knows.

### Two adapters

**`:chromium_cdp` — reference, CI-verified, default.** Headless Chromium over CDP in a **separate
process, never inside a Puma worker.** Asset model **inline-only, zero egress**: `data:` URIs for
images and fonts, bundled Chart.js and CSS inlined; launch flags deny name resolution
(`--host-resolver-rules=MAP * 0.0.0.0`), downloads denied, non-root, and `--no-sandbox` **not**
set (run in a sandbox-capable container instead). Preflight reports the Redmine-hosted `<img>`
check as an **expected failure**, so the operator learns at install time that HTTP assets are
unsupported in this mode. Readiness by `Runtime.evaluate` polled at 50 ms.
**Concurrency: a process pool of size 1 by default**, a bounded queue, a global cap; no slot
within `queue_timeout_ms` → `Failure(:engine_unavailable)`. *A refusal is operable; a timeout is
not.* **Install cost, stated honestly: Chromium is not installed by `bundle install`, so G7 must
be restated as "≈3 commands plus one documented package install."** The clean-image CI job will
find this immediately; do not pretend otherwise.

**`:wkhtmltopdf` — compatibility, CI-verified, not the default.** Its existence is what makes the
migration survivable: every existing install and template keeps rendering, and it is the **only**
engine `bundle install` provisions (republished 2025-08-20, 70M+ downloads, zero configuration, no
services, no egress, works on shared hosting and air-gapped). Same inline-first resolver;
absolute HTTP only on explicit opt-in — and because our drops emit absolute URLs by construction,
`Report#build_content`'s rewriting is **not** reimplemented. Capabilities: `:javascript`
yes-but-2011; readiness → `--window-status`; no `:tagged_pdf`. Carries the relocated legacy shims,
gated on a chart having been recorded, plus a `Degradation(:legacy_engine)` stamped into metadata.
**`no_stop_slow_scripts` goes back to `false`** — today it is `true`, i.e. the engine's own
runaway-script guard is off with nothing replacing it; with a real readiness signal there is no
reason to keep it off. **Declared deprecated on arrival**, removal condition INV-7-shaped.

*Documented-unverified:* **Gotenberg** — `/forms/chromium/convert/url` is a **forbidden code
path** (SSRF); only `convert/html` upload; docs must require network isolation and an
authenticating proxy given its 2026 unauthenticated-critical cluster and no-auth default.
**WeasyPrint** — the slot stays open and becomes attractive **only** under §6's SVG split, which
is the strongest single argument for that split. *Rejected:* **ferrum-in-Puma** — a resident,
self-updating browser in every worker, where a Chrome major bump between two `apt upgrade` runs
changes rendering with no plugin release involved.

### 5.1 Asset resolution — three models, one policy *(OQ-4 closed 2026-08-04 by curator decision)*

**Curator decision:** *"externe entities zou ik laten downloaden en andere assets eventueel mee
sturen"* — external references may be fetched; local assets travel with the request.

**There is no standard for this, and the assumption that one exists must be corrected before it
becomes a design premise.** `[CITE: HTML has no packaging format in general use for this purpose —
MHTML (RFC 2557) is not accepted by any of the four candidate engines, and each engine exposes its
own mechanism]`. What *is* standard is the **shape**: every HTML-to-PDF engine offers some subset
of exactly three asset models, and nothing else. So the abstraction is not "adopt the standard", it
is **the capability triple already declared in §5** — now given a policy, a default, and a test:

| Model | Capability | Mechanism per engine | Egress |
|---|---|---|---|
| **inline** | `:asset_inline` | `data:` URIs for images and fonts; CSS, JS and SVG inlined into the single document body | none |
| **upload** | `:asset_upload` | the request carries named asset bytes: Gotenberg `multipart/form-data` (`index.html` + sibling files); Chromium/CDP `Fetch.enable` request interception serving `request.assets` from memory; WeasyPrint the `url_fetcher` callback | none |
| **fetch** | `:asset_http` | the engine resolves absolute URLs itself over the network | **yes** |

**`DocumentRequest#assets`** is therefore not a Gotenberg accommodation — it is the portable middle
model, and the CDP interceptor makes the reference engine implement it too. `AssetResolver` walks
the document once and, per reference, chooses the **most restrictive model the engine declares**:
inline if it can, upload if the bytes are local but too large to inline (default threshold
`inline_max_bytes` 512 KiB, above which base64 growth costs more than a second round trip), fetch
only if the reference is remote **and** policy permits.

**Policy — `asset_policy`, three values, `:bundled` the default.**

| Value | Local files | Same-origin Redmine URLs | Third-party URLs |
|---|---|---|---|
| `:bundled` (default) | inline / upload | **rewritten to the on-disk file** and inlined; never fetched | **refused** → `Failure(:asset_unresolved)` naming the URL |
| `:redmine` | inline / upload | fetched from an **allowlisted** internal base URL over `:asset_http` | refused |
| `:external` | inline / upload | as `:redmine` | fetched, **allowlist-only** |

`:bundled` is what R9 depends on: the default install renders correctly with the renderer's
name resolution denied, which is also §9's cheapest SSRF control. **The two upgraded modes are
opt-in per install, never per template** — an author must not be able to widen egress by editing a
document, or template authoring (already a code-execution privilege, INV-9) would additionally
become a network privilege.

**Conditions on `:external`, all mechanical, none advisory.** `asset_allowlist` is a list of
**hosts, not patterns**, empty by default, and an empty allowlist makes `:external` behave exactly
as `:bundled` — misconfiguration fails closed. Resolution happens **in the plugin, never in the
engine**: the plugin fetches, validates and hands over bytes via `:asset_upload`, so
`:asset_http` stays off even in `:external` mode wherever the engine supports upload. That single
inversion is what keeps INV-8 true — *the renderer is never the thing holding the network* — and
it is also why "let it download" does not mean "give Chromium the internet". Fetches are
`https` only, size-capped (`asset_max_bytes` 8 MiB), time-capped (2 s connect, 5 s total), redirect
count 0, content-type-checked against the reference's use, resolved-IP-checked against private and
link-local ranges **after** DNS resolution (the rebinding case), and never carry a cookie, session,
API key or `Authorization` header — **assets are fetched anonymously or not at all**. A reference
that needs the viewer's credentials to resolve is a reference the report may not contain; it is
refused with the URL named, which is FR-30 restated as a mechanism.

**Vendored libraries are not affected by any of this.** Chart.js, Mermaid and fonts ship in the
plugin (§6) and are always inline. No asset policy value can make a chart depend on egress. That
separation is deliberate: the thing that must never break offline is not the thing an author points
at.

**AS BUILT (T-33, 2026-08-06) — two places where the implementation is stronger than the text, and
one where it is narrower.**

1. **`:asset_http` is never selected, in any mode, by any engine.** The table above gives
   `:redmine`/`:external` as "fetched … over `:asset_http`". `Assets::Resolver` does not do that:
   wherever a fetch is permitted, the PLUGIN fetches under the `Fetcher`'s caps and the engine
   receives bytes — inline if it can, upload if it declares it. The paragraph above already
   demands this ("Resolution happens in the plugin, never in the engine … so `:asset_http` stays
   off even in `:external` mode wherever the engine supports upload"); the implementation drops
   the qualifier, because an engine that supports only `asset_inline` can be handed a `data:` URI
   just as easily and there is no case left where giving the renderer the network buys anything.
   The capability stays in the vocabulary — an engine may still declare it, and an operator has
   to be able to read that the model exists.
2. **An empty allowlist collapses `:redmine` as well as `:external`.** The text says it of
   `:external`. Extending it costs nothing: under `:bundled` a same-origin reference is rewritten
   to the file on disk, which is better than fetching it. `Policy#collapsed?` exists so the
   settings page can say the switch did nothing, rather than leaving an operator to believe it.
3. **A stylesheet's OWN references are resolved before it is embedded.** §5.1's table is about
   references in the document; CSS carries its own (`url()`, `@import`), and embedding a
   stylesheet verbatim hands every one of them to the engine as a live URL — which under
   `:bundled` is the egress this section refuses and under `:external` is a complete allowlist
   bypass. So CSS is resolved recursively, to a depth cap, and a refusal inside a stylesheet
   fails the document closed naming the inner URL. **JavaScript deliberately is not**: a URL in a
   program is a string rather than a subresource, a script can mint one at runtime, and only the
   engine's own egress denial answers that — which is what INV-8's `--host-resolver-rules` and
   conformance fixture `F-15-egress-denial` are for.
4. **A structural rewrite is refused when it would change what the element means.** Replacing
   `<link rel=stylesheet media=print href=…>` with a bare `<style>` block promotes a print-only
   stylesheet to all media; `<script type=module src=…>` becomes a classic script. The rewrite is
   allowed only for a closed safe attribute set, with `media` carried through, and anything else
   keeps the element and takes a `data:` URI.
5. **Structural inlining falls back to a `data:` URI when the bytes contain the element
   terminator.** "CSS, JS and SVG inlined into the single document body" is done as a `<style>` /
   `<script>` block — the form a 2011 WebKit certainly accepts — except where the file contains
   `</style` or `</script`, which would close the block early and have everything after it parsed
   as markup. That is an injection, not a rendering bug, so those fall back to base64, which
   contains no `<`. Recorded as `Degradation(:asset_structural_fallback)`.

**What T-33 did NOT do:** no shipped adapter consumes `DocumentRequest#assets` yet, because
neither `:chromium_cdp` nor `:wkhtmltopdf` declares `:asset_upload` — the CDP `Fetch.enable`
interceptor §5.1 describes is unbuilt. The upload branch is therefore proven at the resolver and
not end to end, and the honest place for the interceptor is with the engine whose only model is
upload (T-34) or a task of its own. Finding **F-16**.

### 5.2 Gotenberg becomes a shipped adapter *(OQ-3 closed 2026-08-04 by curator decision)*

**Curator decision:** *"zeker, als een van de opties, goed gedocumenteerd en veilig"* — an
external container is acceptable **as one option among several**, documented and safe.

Gotenberg therefore moves from *documented-unverified* to a **third first-class adapter,
`:gotenberg`, CI-verified against a pinned container, and not the default.** "One of the options"
is the whole content of the decision: the default stays `:chromium_cdp` because G7 (≈3 commands)
cannot be met by a design that requires an operator to run a service, and INV-7 forbids claiming
a configuration CI does not exercise — so the *only* way "as an option" can be honoured honestly
is by testing it.

Consequences, each a task-level obligation rather than a sentence in a README:

1. **`/forms/chromium/convert/url` stays a forbidden code path** and is asserted absent by the
   boundary grep. Only `convert/html` with the `:asset_upload` model — which §5.1 now makes the
   normal path rather than a special case.
2. **"Safe" is a configuration, so the plugin must be able to refuse an unsafe one.** Gotenberg
   defaults to no authentication `[CITE: 2026 unauthenticated-critical CVE cluster, 02-analysis.md
   §Security]`. `#preflight` therefore additionally asserts: the endpoint is **not** reachable
   without the configured credential (if a credential is configured), the container version is
   within a supported floor, and `chromium.disableJavaScript`/route restrictions match what the
   adapter assumes. A Gotenberg reachable **unauthenticated** produces a preflight **failure with a
   named remediation**, not a warning — an SSRF-capable PDF service on an internal network is the
   finding, and diagnostics is where an operator will actually see it.
3. **The plugin never ships a container.** `docker-compose.gotenberg.yml` is a documented example
   carrying the network isolation (`internal: true`), the non-root user, the read-only root
   filesystem and the pinned digest. It is documentation with a CI job attached, not a dependency.
4. **The engine-selection UI states the trade in one line per engine** (§10): what it needs
   installed, whether it needs a service, whether it can render offline, and which capabilities it
   lacks — generated from `capabilities.yml`, per FR-50, never hand-written.

`:ferrum_pdf` remains **rejected as an in-Puma engine** for the reason already given (a resident
self-updating browser inside a worker), but the curator's R8 named it, so the honest disposition
is recorded rather than silently dropped: ferrum is the *library* our `:chromium_cdp` adapter's
role is filled by. If a fourth adapter is ever wanted, `:ferrum_pdf` as a **separate process**
driven by ferrum is a 100-line adapter over the same interface — `[OQ-K]` whether that is worth
maintaining alongside a raw-CDP adapter that already works, which is a duplication question, not a
capability one.

### Readiness protocol

Today's `window.status` handshake in every template is **dead code** — nothing reads it, and the
PDF path uses a flat `javascript_delay: 3000` with the runaway guard off.

Engine-independent DOM contract, emitted once per document by the plugin's own bundled chart
shell: `window.__rd = { pending, ready, degraded, begin(), end(), fail(reason) }`. `end()`
decrements; at zero it sets `ready`, sets `document.documentElement.dataset.rdReady = '1'`, and
sets `window.status = 'rd-ready'`. An in-page watchdog forces `ready` after `client_timeout_ms`
and records `degraded: ['client_watchdog']`. Three signals for one contract because the mapping
targets differ: Chromium reads the JS expression, wkhtmltopdf `--window-status` plus a 250 ms
floor, Gotenberg `waitForExpression`, WeasyPrint nothing → `Degradation(:no_javascript)` unless
the document is chart-free, any DOM-only engine the `data-rd-ready` attribute.

**`begin`/`end` are never the author's job** — every chart goes through `{% chart %}`. That is
what deletes the hand-rolled `geoChartBegin`/`geoChartEnd`/`__geoChartsPending` handshake from all
three example templates.

**On timeout** (default 10 000 ms) the engine **still renders** and returns `Success` with
`Degradation(:readiness_timeout, pending: n)` — a chart-less-but-otherwise-correct document beats
no document — **unless** `readiness.strict`. Either way, one log line with correlation id, pending
count and duration.

## 6. Assets and charts

**Bundled, never CDN.** Today Chart.js **2.8.0 (2019)** loads from `cdnjs.cloudflare.com` **from
inside the template body**, with no SRI. Vendor Chart.js **4.x** into
`assets/javascripts/vendor/` with upstream version + sha256 in `THIRD_PARTY.md`. **No network
fetch, ever** — simultaneously the SRI fix, the reproducibility fix, and the prerequisite for
INV-8's zero-egress posture. *Rejected: CDN with SRI* — SRI does not remove the **egress
requirement**, and denying egress is the single control that most cheaply kills SSRF value. You
cannot have both.

**Sprockets ↔ Propshaft, made irrelevant.** Ship **pre-built, non-digested** files; rely on
Redmine's plugin-asset mirror; reference with `javascript_include_tag …, plugin: '…'`. **No
Sprockets directives, no ERB in assets, no SCSS** — then neither pipeline is involved. One shim
for the mirror behaviour. This matters twice: the **PDF path reads the same files off disk and
inlines them**, and a digested asset would have no stable on-disk path. `[OQ-E]` Redmine 7.0's
pipeline is unconfirmed; this design does not depend on the answer.

**The hybrid split — one aggregator, two renderers, one authoring act.** The author writes
`{% chart id: v1, type: bar, from: stats, x: label, y: count, drill: true, … %}` once. The tag
**emits no markup**: it appends a `ChartSpec` to `RenderContext#charts` and a placeholder
`<div data-rd-chart="v1">`. At the end of the render the **output binding** decides:

| `output` | Emitter | Properties |
|---|---|---|
| `:html` | `ChartjsEmitter` | `<canvas>` + a `<script type="application/json">` data block — **never** a string-concatenated JS array literal, which is the entire class of the escaping defect — plus the shell's `begin`/`end` |
| `:pdf` | `SvgRenderer` | inline `<svg>` computed server-side: **vector, selectable, deterministic, no JS, no readiness handshake, no polyfills**, with `<a xlink:href>` per element for drill-through |

Consequence: **`:javascript` stops being an essential capability for the common case**, which puts
WeasyPrint back on the table and substantially de-risks the engine decision.

**Six chart types** from measured use: `bar` (v/h), `stacked_bar`, `diverging_stacked_bar` (the
LL-01 widget), `line`, `pie`/`doughnut`, `progress`. Anything else →
`Degradation(:chart_type_unsupported)` and the Chart.js path, which re-adds `:javascript` as
essential.

**The mechanism that makes "identical in HTML and PDF" a construction:** one shared
`ChartLayout` computed **server-side in Ruby for both paths** — scales, tick arrays, palette,
label truncation. Chart.js is handed explicit bounds and ticks and is **not** allowed to
auto-scale. Testing: SVG goldens are **deterministic diffable text**; the Chart.js visual diff is
**advisory only, never a hard gate**.

**Chart.js 2→4 is a work package, not a free win.** Present in the shipped examples:
`scales.xAxes[]`→`scales.x`; `options.legend`→`options.plugins.legend`;
`type:'horizontalBar'`→`type:'bar'` + `indexAxis:'y'` (**all three** charts);
`getElementAtEvent`→`getElementsAtEventForMode` (the drill-through handler);
`ticks.fontSize`→`ticks.font.size`; `ticks.max`/`beginAtZero` → the scale object.
`responsive: false` + a fixed canvas is still needed **on the wkhtmltopdf path**, so `{% chart %}`
emits it from the **engine's capabilities**, not the author's choice — that is the concrete
mechanism for G3.

**F-14, DECIDED (2026-08-06): read "from the engine's capabilities" as "not from the author", and
add no `:responsive_canvas` capability.** The clause's job is that the author cannot set it, and
`ChartjsEmitter` derives it from the OUTPUT BINDING instead (`:html` → responsive, `:pdf` → fixed
canvas, `devicePixelRatio: 1`, no animation). Three reasons a formal capability is the wrong shape
rather than merely a cost:

* a capability in this design answers *can the engine do X?* and feeds `Capabilities.negotiate`,
  which has three outcomes — refuse, degrade-and-record, proceed. Responsiveness has none of them.
  There is no engine that "cannot do responsive": every engine in the matrix draws a fixed page,
  and reflowing is a property of a live browser window, not of an adapter.
* **the `:html` binding has no engine at all.** `{% chart %}` renders into a live Redmine page with
  no `DocumentRequest` and no adapter, and that is precisely the path where `responsive: true` is
  the right answer. A capability whose value must be known where no engine exists is not a
  capability.
* the cost is not one matrix regeneration: it is a row in `capabilities.yml` for all three engines,
  the per-adapter equality assertion the conformance suite makes, and a G9 matrix change — to add a
  column that reads "no" three times and "n/a" for the binding that wants it.

Hardened instead: `spec/charts/charts_spec.rb` asserts that `ChartSpec` has no `responsive`,
`animation` or `devicePixelRatio` parameter and that the derived values do not move for anything an
author can write. That makes G3's clause mechanical, which is what it was asking for.

### 6.1 Mermaid — R10's third library, previously analysed but never specified

**Gap acknowledged:** R10 named Chart.js, **Mermaid** and SVG. Chart.js and SVG have a design; until
now Mermaid had a security *posture* (`02-analysis.md` §245-249: render server-side to a static
image) and no requirement, no FR and no task — an unbuilt requirement hiding as a paragraph. It is
specified here.

**The posture in §245-249 was right about the risk and wrong about the mechanism.** "Render
server-side to a static image" reads as *rasterise it in Ruby*, which for Mermaid means a Node
toolchain (`mermaid-cli` → Puppeteer → a second browser) or an external service (Kroki). Both
violate G7 far worse than Gotenberg does, and neither is needed, because **the plugin already runs
a headless browser for the PDF path**. So:

`{% mermaid %} … {% endmermaid %}` — a **block tag**, not a filter, and the body is **not**
Liquid-interpolated by default (`{% mermaid interpolate: true %}` opts in, and the linter then
requires `| json`-free plain-text values only). Emission mirrors `{% chart %}`: the tag records a
`MermaidSpec` and emits `<div data-rd-mermaid="id">`; the output binding decides.

| `output` | Path | Result |
|---|---|---|
| `:html` | bundled Mermaid 11.x, `startOnLoad: false`, rendered by the chart shell, `begin()`/`end()` around it so **readiness already covers it** | live SVG in the DOM |
| `:pdf`, engine has `:javascript` | same code path inside the engine; the readiness contract holds the render open until Mermaid resolves | vector SVG in the PDF |
| `:pdf`, engine lacks `:javascript` (WeasyPrint) | `Degradation(:mermaid_unsupported)` + the diagram **source** in a `<pre>`, clearly labelled | honest, readable, not blank |

**Security — AMENDED 2026-08-06 by curator decision (§Findings F-17). The SVG sanitiser is
DROPPED, and the reason is the product's purpose.**

This section used to require that *"the rendered SVG is sanitised by the plugin after Mermaid
produces it, not trusted because Mermaid was configured"*, against the same allowlist `SvgRenderer`
output passes through — one sanitiser, two producers. It cannot earn its keep. **The plugin exists to
let a report author use modern JavaScript**, Chart.js and Mermaid being examples rather than the
feature; an author may write `<script>` directly, and INV-9 says so — template authorship *is* code
execution, which is why T-27 ships the label *"Author report templates (executes server-side code)"*.
Stripping `<script>` from a library's output inside a document whose author may write one is a cost
with a security-shaped name.

`securityLevel: 'strict'`, `htmlLabels: false` and `flowchart.htmlLabels: false` **stay as defaults** —
they cost nothing and spare an author from knowing about them — but nothing downstream depends on them
being honoured, because nothing needs to.

**What replaces it is not weaker; it is aimed at the threat that survives.** The dangerous bytes are
not the author's — they are **Redmine's content**, written by every user rather than by the template
author, and that boundary is FR-19's: `| json` / `| js`, the `HtmlScanner` lint and T-19's payload
table. Under this decision that becomes the *only* control on that path, so it tightens rather than
relaxes. `{% mermaid interpolate: true %}` is the one Mermaid-specific instance of it and must escape
or refuse rather than pass through.

**Unchanged, because neither is about author-written JavaScript:** T-33's `asset_policy` (SSRF
originating on the *server*, INV-8) and T-17's execution policy (a runaway template is a denial of
service whoever wrote it).

**And the residual risk, stated rather than implied:** on the `:pdf` path this is safe by construction
— the engine has no network and the output is a document. On the `:html` path author-written script
runs in the *viewer's* browser with the viewer's session, so the authoring permission is
administrator-adjacent and **the permission is the control**. That made `[OQ-F]` the load-bearing
decision of this area rather than a naming question — and **it is now answered** (§4.1, 2026-08-06):
not by defaulting a setting, but by four authoring permissions that this plugin never grants and that
Redmine's own `require: :member` refuses to offer to the Anonymous or Non-member role. With one limit
stated there rather than glossed: core's default-data loader can hand them to Manager on a fresh
install, which is why the diagnostic lists the roles holding them.

**Diagram types are not enumerated and deliberately so** — unlike charts, where six types are
enumerated because *we* compute the layout. Mermaid computes its own; the allowlist is on the
*output*, so a new diagram type in Mermaid 12 needs no plugin change. `mermaid_max_bytes` (default
16 KiB of source) and the render timeout bound the cost.

**~~`[OQ-L]`~~ CLOSED 2026-08-06 BY MEASUREMENT. The answer is NO, and the expected disposition
stands: wkhtmltopdf declares `:mermaid` absent despite declaring `:javascript`.**

Measured rather than argued, with both engines rendering the SAME probe document — Mermaid 11.16.1's
`dist/mermaid.min.js`, a two-node `graph LR` whose node labels are distinctive strings, and an
in-page probe that reports which of four things happened (no global, threw, run resolved, run
rejected):

| engine | probe said | the diagram |
|---|---|---|
| `chromium_cdp` Chrome/141.0.7390.37 | `PROBE-RUN-RESOLVED` | **drawn** — both node labels extract from the PDF as SVG text, and the literal source is gone |
| `wkhtmltopdf` 0.12.6.1 (patched qt) | `PROBE-NO-MERMAID-GLOBAL` | **not drawn** — the literal source remains as text |

The bundle does not merely fail to draw; it **never defines its global**. Mermaid 11 ships as an
esbuild IIFE opening with `(__esbuild_esm_mermaid_nm||={})` — logical assignment, ES2021.

**And the cause is established by a discriminator rather than inferred from the shape of the
bundle**, because "modern syntax, therefore this" is exactly the kind of plausible story that turns
out to be a timeout or a file-size limit. Two three-line documents, identical but for one statement,
each setting a probe div BEFORE the statement under test:

| script | wkhtmltopdf printed |
|---|---|
| `x.a = x.a \|\| 1;` | `ES5-OK-1` |
| `x.a \|\|= 1;` | `INIT` |

The second never reached the assignment *before* it, so the whole `<script>` block failed to
**parse** — not to run. `wkhtmltopdf --debug-javascript` names it outright, once, at the bundle's
own `<script>` line: `SyntaxError: Parse error`. And the alternatives are excluded by measurement
rather than by argument: a document of the same 3.5 MB with an **ES5-only** script of the same size
runs fine under the same 8 s delay, so size is not it; the bundle is a synchronous IIFE reported at
parse time, so "hadn't finished" is not available; the probe's own JavaScript is ES5 and
demonstrably ran, since it printed its own verdict.

**`||=` is sufficient but not the only barrier, and that matters more than it looks.** This build
also has no `globalThis`, and the bundle's *final* line is
`globalThis["mermaid"] = globalThis.__esbuild_esm_mermaid_nm["mermaid"].default;`. So a reader must
not conclude "transpile the `||=` and it works": there are at least two independent blockers, and
the honest position is that Mermaid 11 is not a target for this engine. There is no shim short of
transpiling somebody else's bundle, which is not a thing this plugin will do.

**Two facts for T-35 that fell out of the same measurement.** Of the required fallback — "on an
engine without `:javascript` the source is emitted, labelled, with `Degradation(:mermaid_unsupported)`,
and the output is not blank" — the **"emitted and not blank" half is free**: `pdftotext` returns the
`<pre class="mermaid">` body verbatim, because Mermaid never touched it. The **label and the
`Degradation` are still T-35's to write**; nothing in this measurement produces either, and reading
this paragraph as "the fallback already works" would skip them. And **the bundle is 3,566,058
bytes**, nearly seven times `inline_max_bytes` (512 KiB) and inside
`asset_max_bytes` (8 MiB), so under T-33's resolver it inlines with
`Degradation(:asset_inline_oversize)` on any engine with no upload model — which is both shipped
engines. T-35 should decide deliberately whether Mermaid is an asset-policy asset at all or a
bundled library like Chart.js (§6 says libraries "are always inline" and unaffected by the policy,
which is the answer, but the size is worth knowing).

**Migration aid, shipped before the engine default changes:**
`rake reporter_dashboards:lint_templates` scans **stored** bodies for every row above plus
`window.status`, `geoChartBegin`, `GEO_CHARTJS_SRC`, `setLineDash`, `[page]`, and un-`json`-ed
`{{ }}` inside `<script>`. Non-writing. The operator sees the blast radius before it lands.

## 7. Data model and migrations

| Table | Status |
|---|---|
| `reporter_project_tabs` | **exists**; keep as-is, unprefixed name included |
| `reporter_dashboards_templates` | new. `name description content project_id author_id source output visibility orientation page_size margins engine_hint enabled source_template_id source_digest lock_version`. **This row said "STI `type`" until 2026-08-07 and the curator corrected it** — four other places forbid a subclass tree (T-23's `Accept:`, §7b.4, FR-60, and `[OQ-H]` closed "as a `source` field, not a branch"), and a column literally named `type` IS Rails' STI discriminator whether or not anyone wants it to be. Reporter's three type values also conflated **two axes**, so there are two columns: `source` ∈ `issues \| time_entries` (FR-60) and `output` ∈ `per_record \| combined` (FR-36). One three-valued column cannot express a per-record report over time entries |
| `reporter_dashboards_templates_roles` | new, **added 2026-08-07**: `id: false`, `template_id role_id`, unique index on the pair. `visibility = VISIBILITY_ROLES` cannot work without it — Redmine's own `Query` backs the value with `has_and_belongs_to_many :roles` and validates the list is non-blank (`app/models/query.rb:265,277`) — and §7 rule 6 forbids adding it in a later migration than its column. `id: false` follows core's `queries_roles`; the objection this section makes to `id: false` is about a RECIPIENT row, which is a thing an operator addresses and revokes, and does not reach a visibility pair |
| `reporter_dashboards_template_versions` | new, **append-only**: `template_id author_id content content_digest created_at`. INV-9 audit + author rollback |
| `reporter_dashboards_schedules` | new. `project_id template_id query_id query_type repeat start_date(**date**) end_date(**date**) email_subject email_template render_as timezone enabled` **+ run state** `last_run_on last_attempted_at last_status last_error last_duration_ms consecutive_failures next_run_on`. Reporter stores these dates as `datetime` while every comparison is date-based — fixed |
| `reporter_dashboards_schedule_runs` | new. `schedule_id occurrence_date started_at finished_at status error duration_ms recipients_count document_count bytes_total correlation_id`, **`add_index [:schedule_id, :occurrence_date], unique: true`** |
| `reporter_dashboards_schedule_recipients` | replaces `report_schedules_users` (which is `id: false`, so a join row is unaddressable). Gains `id`; **`user_id` only** — no free-text `to`/`cc`/`bcc`/`from`, which is the exfiltration-and-spoofing-relay finding. A security-motivated schema decision |
| `reporter_dashboards_documents` | **required** — it is the snapshot store the share links serve from (§7b.1), no longer optional. **Columns approved by the curator 2026-08-07**, having been derived in T-22 from stated requirements rather than specified here: `template_id project_id schedule_run_id created_by_id rendered_as_user_id` (FR-45/FR-47 — a snapshot makes no visibility decision when served, so the identity it was rendered as is the only record of whose numbers it holds), `correlation_id engine engine_version render_duration_ms` (FR-27's stamp, queryable without opening the file), `content_type byte_size page_count digest`, `attachment_id` (nullable — the bytes live in Redmine's own `Attachment`, whose storage and cleanup are already solved), and `expires_at` **NOT NULL** with `purged_at`. The mandatory TTL is additionally **bounded** by the model at one year: presence alone permits `9999-12-31`, which is an immortal row wearing a TTL |

**The unique index is the whole scheduler fix.** The runner **claims the occurrence first** by
inserting the run row; a duplicate insert is caught and skipped. That makes three findings
structurally impossible: running twice sends twice; a missed day is unknowable (enumerate
occurrences between `last_run_on` and today, bounded by `max_catchup_days` default 7 — a schedule
dormant for a year must not emit 365 e-mails); and the first failing template aborting the rest (a
per-schedule rescue writes `last_status = failed` and continues; `consecutive_failures` drives an
operator-visible warning rather than silence).

`reporter_dashboards_documents` exists only to bound the generated-PDF retention gap.
**Recommendation: do not persist by default** — scheduled reports attach to the mail, ad-hoc
export streams. Persistence is opt-in with a mandatory TTL and a purge task. That converts an
unmanaged indefinite store into "off by default, bounded when on", which is the most a plugin
author can honestly offer.

### Reversibility — every migration goes down as well as up

**Gap acknowledged:** the dossier treated migrations only as a hazard *coming from the other
plugin* (reporter's `VERSION=0` dropping tables we live on). It never stated a requirement for
**our own** migrations. Stated now, because "it installed fine" and "it uninstalls without
wrecking the database" are different claims and only the first was being tested.

**Rules.**

1. **No `up`/`down` pairs and no `execute` in a `change` block.** Every migration is a reversible
   `change`, or it declares `reversible do |dir|` explicitly. `irreversible` is not permitted for
   any migration in the 0.x line — there is nothing in this schema that justifies it.
2. **Down means down to zero.** `rake redmine:plugins:migrate NAME=redmine_reporter_dashboards
   VERSION=0` must leave a database with **no plugin table, no plugin index, no plugin row in
   `plugin_schema_info`**, and must leave `reporter_project_tabs` — which **pre-exists this work** —
   in the state its own migration created, not dropped. That last clause is the one a naive
   down-migration gets wrong, and it is the mirror image of the hazard we criticised reporter for.
3. **Data-bearing migrations are `up`-only in effect but reversible in form.** The importer is a
   rake task, never a migration `[INV]`, precisely so that "roll the schema back" never means "lose
   imported templates". A schema migration may not read or write template content.
4. **The down path is tested, not asserted.** New CI job **`migrate-updown`**, one per Rails branch:
   migrate up from empty → assert the full schema → migrate `VERSION=0` → **assert the schema is
   byte-comparable to the pre-install dump** (`plugin_schema_info` included) → migrate up again →
   assert idempotent. A plugin that cannot be uninstalled cleanly cannot honestly be recommended
   for a trial install, and a trial install is the whole A/B argument below.
5. **Forward-compatibility of a rolled-back column.** Between 0.6 and 1.0 the schema grows. A user
   who rolls **the plugin** back one minor version while keeping the schema must not crash: models
   never `SELECT *`-depend on a column's presence, and `compat/` carries a
   `column_present?(:table, :col)` guard for the three columns added after 0.6
   (`engine_hint`, `next_run_on`, `consecutive_failures`). Cheap, and it converts a support incident
   into a degraded feature.
6. **`lock_version` and the unique index are created in the same migration as their table**, never
   added later — an index added in a later migration is an index a partially-migrated install does
   not have, and the scheduler's at-most-once guarantee is only as strong as that index.

**`lock_version` is on `reporter_dashboards_templates` and on nothing else — curator decision,
2026-08-07.** T-22's review argued for one on `reporter_dashboards_schedules` too, and the argument
was good: it is the one table with two writers, an administrator editing the form while T-25's runner
writes `last_status`, `consecutive_failures`, `last_run_on` and `next_run_on`. **It was decided
against, for the reason optimistic locking would cost there:** the runner would raise
`StaleObjectError` whenever somebody happened to have the form open, and T-25's per-schedule rescue
would record a failure that is not one — a scheduler that reports errors because a human was
looking at it. The run-state columns are written by the runner and the form is written by a person;
those are different concerns on one row, and the right shape is `update_columns` for the former
rather than a lock over both. Because rule 6 means the column cannot arrive later, this is recorded
as a decision rather than left open.

**Not claimed:** reversibility does **not** mean a downgrade path *between plugin minor versions
with data already written in the newer shape*. That is a data-migration question, and the honest
answer is a documented export-then-reimport, not a `down` block. Saying so is the difference
between a supported path and a hoped-for one.

### Adopt vs copy — **COPY. Forward-only. Never adopt.**

1. **The footgun is mechanical and undefendable.** If the new plugin adopts `report_templates`, an
   operator following Redmine's documented uninstall —
   `rake redmine:plugins:migrate NAME=redmine_reporter VERSION=0` — runs reporter's own
   down-migrations and **drops the tables the new plugin is live on**. Nothing inside the new
   plugin can prevent that.
2. **Adopt forecloses A/B; copy enables it.** Both plugins define `Report`, `ReportTemplate`,
   `ReportSchedule` at **top level**, so there is no "install alongside and compare" path today.
   Namespaced classes + new tables mean **both plugins can be installed simultaneously**, which
   turns the riskiest single event in the project from a leap of faith into a comparison.
   Decisive.

*Steelman for adopt, honestly:* zero import step, no double storage, no drift, and existing
template ids keep working in bookmarks. The drift objection is real — a user editing the old
template after import gets a silently stale copy. *Counter-mitigation:* the importer records
`source_template_id` + `source_digest`, and `rake reporter_dashboards:import_status` reports
divergence. Drift becomes **visible** rather than silent, which is the standard applied everywhere
else in this dossier.

**Three rake tasks, strict order.** `import:plan` — **read-only dry run**, reporting counts by
type, per-template lint findings, active schedules, and which templates need rework. **This task
is also the vehicle for the four R-15 production queries**: shipping them as a repeatable tool
rather than a one-off SQL session is the cheapest way to guarantee they actually run.
`import:run [--only] [--rewrite]` — one transaction per template, idempotent, stamping source id
and digest, **never writing to reporter's tables**, and **never** `YAML.load_file` +
`constantize` (a closed Hash type map instead) nor `rescue Exception`. `import:verify` — renders
each imported template under both stacks and diffs the **aggregation result hashes**, not the
HTML: the corpus discipline applied to user data.

**INV-6 as a gate:** a Minitest helper `assert_no_writes { get … }` subscribing to
`sql.active_record`, applied to **every** read action — far broader than today's single
`assert_no_difference 'ReporterProjectTab.count'`. Deliberate exception: the schedule-run claim
row *is* a write, but it lives in the rake path, not a page view.


## 7b. The six carried-forward capabilities — improved, not dropped

**Curator decision, 2026-08-04.** All six items the earlier specs excluded are **required**, in
improved form. The exclusions are withdrawn. This section is the design for each; §7c states what
the scope change costs, because it is not free.

Nothing here is "reproduce the old behaviour". Each item is redesigned so the *capability* survives
and the *defect* does not — and in four of the six the result is strictly more useful than the
original, not merely safer.

### 7b.1 Share links — replaces unexpiring MD5 tokens

Today: `Digest::MD5.hexdigest("Object#1…ReportTemplate#3:#{secret_key_base}")`. No expiry, no
revocation short of rotating the app secret, and — the real defect — **the token bypasses the
visibility check entirely** rather than authorising a specific thing.

**The design inverts that: a link authorises one pre-computed document, not a live query.**

New table `reporter_dashboards_share_links`:

| Column | Purpose |
|---|---|
| `token_digest` | **only the digest is stored**, never the token — a database leak yields no working links |
| `report_template_id`, `scope_kind` (`snapshot`\|`query`\|`issue_ids`), `scope_payload` | what it points at |
| `rendered_document_id` | for `snapshot` — the frozen artefact |
| `render_as_user_id` | **the identity the content was rendered as, stored explicitly** |
| `created_by_id`, `purpose` | provenance |
| `expires_at` | **mandatory**, default from a setting (proposal: 30 days) |
| `max_uses`, `use_count` | optional single-use or N-use links |
| `revoked_at` | individually revocable |
| `last_used_at` | so a stale link is visible |

Plus `reporter_dashboards_share_link_accesses` — one row per access: timestamp, IP, user agent.

Mechanics: token is 32 random urlsafe bytes; lookup by digest with a **constant-time** comparison;
`snapshot` mode serves frozen bytes so **no visibility decision is made at request time at all**;
`query` mode re-renders as `render_as_user_id` and is opt-in per template. Attachment URLs are
scoped to the share link that produced them, expire with it and are revoked with it — and `| inline`
means most reports need no external asset URL in the first place.

UI: the template owner and admins see active links with created-by, expiry, use count, last use, and
a one-click revoke; plus "revoke all for this template".

**Better than the original, not just safer:** you can see what you have shared, to whom it is
reaching, and take it back. Today none of that exists.

### 7b.2 Template exchange — replaces the unsafe YAML import

Today: `YAML.load_file(file)` then `attributes['type'].constantize`, wrapped in `rescue Exception`.

**Canonical format is JSON**, which has no class-instantiation surface at all. YAML is still
*accepted for reading* so existing exports keep working, via
`YAML.safe_load(permitted_classes: [Date, Time], aliases: false)`.

A **versioned bundle**: `{format_version, exported_at, plugin_version, templates: [...]}`, optionally
zipped with referenced assets. Template type resolves through a **closed map**
(`{'issue' => …, 'issue_list' => …, 'time_entries' => …}`) — `constantize` never appears.

Import is **two steps**: `import:plan` reports per template whether it is new, updated or skipped,
plus lint findings and unknown drop paths, **writing nothing**; then `import:run` applies it, one
transaction per template, so **one bad template does not abort the bundle** — each failure is
reported with a reason (`rescue StandardError`, never `Exception`). Conflicts are explicit:
`--on-conflict skip|rename|overwrite`.

Round-trip test: export → import → export produces **identical bytes**.

**Better than the original:** the old import was all-or-nothing and silent on failure. This one
tells you what it will do before it does it, and what went wrong when something does.

### 7b.3 Failure reports — replaces errors-as-document

Today the exception message *is* the PDF bytes, and `create_attachment` persists it. The problem was
never that the user got information — it is that they got a **lie**: a file named `.pdf` that is not
a PDF, and which leaks SQL, role ids and project ids to whoever the report reaches.

Three levels, and the user keeps getting information at every one:

1. **Interactive:** a diagnostics panel — what failed, which template, the Liquid line number where
   applicable, engine and version, duration, and a **correlation id** to quote in a bug report.
2. **Optional failure document** (**per template**, default off — *narrowed from "per template/schedule" by curator decision 2026-08-08, closing §Findings S-11*: a schedule renders a template, so the template flag already governs every render, and the schedule half had nowhere to deliver to, since clause 3 below and FR-43 both require the owner's notice to carry no attachment and the document store is T-28's): a **real, valid PDF** titled
   *"Report could not be generated"*, containing the correlation id, timestamp, template name,
   requester, and a **safe** summary — never the raw exception, never SQL. Filename
   `report-FAILED-<correlation-id>.pdf` so it can never be mistaken for the report.
3. **Scheduled runs:** the schedule owner gets a failure notice carrying the correlation id;
   recipients get nothing by default, or a configurable *"this report is unavailable"* notice.

Never persisted as an attachment unless explicitly requested.

**Better than the original:** today an operator gets an e-mail that looks successful and has to open
the attachment to discover it is broken, with no way to correlate it to a log line. Now the failure
is loud, traceable and safe.

### 7b.4 Time-entry reporting — generalised instead of a third branch

Today `TimeEntriesReportTemplate` is a parallel world: its own controller, drop, permissions and
views, disjoint from issue reporting.

**Do not reproduce the branch. Make the data source a field.** `source` ∈
`issues | time_entries` (extensible), so one controller, one CRUD, one preview and one template model
serve both. Time entries get a `TimeEntryQuery`-backed scope.

**CORRECTED 2026-08-08 — this paragraph used to continue *"and the aggregation core already takes a
scope, so `{% sql_aggregate from: time_entries %}` works with every dimension that applies, and
`spent_hours` measures stop being a special case"*. That was measured and is FALSE**, in the way that
matters most: `QueryAggregator` does not raise on a time-entry scope, it answers ISSUE counts under
time-entry labels, because its unit of count is `DISTINCT_ISSUES = 'DISTINCT issues.id'` and
`TimeEntryQuery#base_scope` calls `.left_join_issue`, which makes the wrong answer available instead
of an error. Four time entries over two issues came back as `2` in every bucket; `spent_hours`
answered `nil`; `activity`, `user` and `project` degraded to nil. Evidence in
`implementation-plan.md` §Findings **S-13**.

**Curator decision, 2026-08-08 (S-13 closed):** the kernel stays frozen — **no second G7 hunk** — and
time entries get their own owned aggregation module, a sibling of `aggregation/query_aggregator.rb`
rather than an edit to it. The two share the RESULT VOCABULARY (bucket shape, drill-through filters,
caps) and not the query builder, because a time-entry report wants different SQL — `SUM(hours)`
grouped by activity, user or an issue attribute — so the reusable part was never the SQL. What stays
single is everything above the query: one template model, one controller, one CRUD, one preview, one
set of permissions. **The separation is at the query and the calculator, not at the template**, which
is what keeps `[OQ-H]`'s closure intact.

**Better than the original — and the claim is narrower than it was.** This paragraph used to promise
that *"today you cannot put issue data and time data in one template or on one dashboard. Once the
source is a field, you can"*. **Withdrawn by curator decision, 2026-08-08:** an issue report and a
time report are two different things to their author, they resolve through two different Redmine query
classes (`IssueQuery` and `TimeEntryQuery`), and mixing them in one template body was a capability
nobody asked for. `RenderContext` carries one scope, so supporting it would have meant a second scope
slot built for a requirement that is now dropped rather than deferred.

What remains, and is still materially better than the base plugin: **one** template model, controller,
CRUD, preview and permission set instead of a parallel world of each, and one result vocabulary —
crosstabs, drill-through, completeness, caps — over both sources. The vocabulary is shared; the
queries and the calculators are not (see the correction above).

**AS BUILT (T-31, 2026-08-08).** `Aggregation::TimeEntryAggregator` is the owned calculator. One
entry point, `breakdown`, answering `QueryAggregator`'s `single_result` keys exactly — verified
against a real call rather than against a copied list, so the vocabulary claim above is a test and
not a promise.

| | |
|---|---|
| **Unit of count** | `COUNT(DISTINCT time_entries.id)`, named as a constant so the difference from the kernel's `DISTINCT issues.id` is greppable |
| **Measures** | `hours` → `SUM(time_entries.hours)` (default) · `count` → the distinct entry count |
| **Dimensions** | four on `time_entries` — `activity`, `user`, `project`, `issue`, of which the first two the issue kernel does not have at all — and seven on `issues`: `tracker`, `status`, `priority`, `author`, `assignee`, `version`, `category` |
| **The issues join is ASKED ABOUT** | the seven issue dimensions need `TimeEntryQuery#base_scope`'s `left_join_issue`. `applicable?` reads the statement rather than assuming, and refuses **before issuing anything** — the `rescue` behind it is a backstop, not the mechanism (HANDOVER §1: forcing the guard true left every example green) |
| **Every grouped aggregate is read POSITIONALLY** | `Accept:` clause 5. One `group`, one `pluck`, no `.sum`/`.average`/`.count` on a grouped relation anywhere — `spec/aggregation/time_entry_aggregator_source_spec.rb` asserts it of the module's own source and a double asserts the positions are not swapped |
| **Refusals are VISIBLE** | a `diagnostics:` port, duck-typed on `#degrade` so the aggregation layer names no Liquid class. `aggregation_dimension_unknown`, `aggregation_measure_unknown`, `aggregation_dimension_unavailable`, plus the tag's `aggregation_group_by_required` and `aggregation_source_unsupported` |
| **Statement count is fixed** | three per hours breakdown (grouped read, one label lookup for all buckets, the scalar total), two per count breakdown — a counted axis is totalled from its buckets exactly as `QueryAggregator.result_total` does it. Independent of the bucket count (FR-48) |
| **Known limit** | `SUM` over a row-duplicating join over-counts and no `DISTINCT` fixes it — §Findings **S-16**, asserted in both directions over a deliberately tripling join |

**No `group_by`, no aggregation.** There is no time-entry equivalent of `aggregate`'s
created/closed flow — a time entry is not opened and closed — so `{% sql_aggregate %}` with no
dimension over a time-entry scope answers the empty result and degrades
`aggregation_group_by_required`. That is a refusal of the ARGUMENT, and it is deliberately narrower
than increment 1's refusal of the whole SOURCE.

### 7b.5 Ad-hoc report mail — same capability, controlled

Today `find_issues` is `Issue.where(id: params[:issue_ids])` with **no visibility check**, and
`to`/`cc`/`bcc`/**`from`** are free text. That is a report over any issue in the instance, mailed
anywhere, with a forged sender.

Redesign:

- Issues resolve through **`Issue.visible(User.current)`** — you can only mail what you can see.
- **`From` is server-controlled** (Redmine's own sender). The requester's address goes in `Reply-To`,
  which is what people actually wanted from the field.
- Recipients are **Redmine users** by default. External addresses require an admin to enable them
  *and* pass a **domain allowlist**.
- Every send is **audited**: who, when, which template, which issues, which recipients — visible to
  admins.
- Rate-limited per user.
- It goes through the same render path, so a failure is a failure (7b.3) rather than a mail with a
  broken attachment.

**Better than the original:** today nothing records what left the building. Now there is a log you
can answer questions from.

### 7b.6 Public report links — the capability, on 7b.1's mechanism

Kept as a feature, built entirely on 7b.1. Off by default, enabled per template, mandatory expiry,
revocable, audited, and — the important part — a public link serves a **snapshot** rather than
running a live query as nobody. So "public link" stops meaning "visibility check skipped".

## 7c. What the scope change costs — stated, not buried

Adding these back is the right call given they are needed, and it is not free. Three honest
consequences:

1. **Phase 4 grows** by roughly the share-link subsystem (two tables, a UI, an access log), the
   bundle importer, the failure-report path, the mail controls and the audit log. The `source`-field
   generalisation is *cheaper* than the third template type would have been, so it partly offsets.
2. **Two claims are settled by decision rather than by evidence.** C-002's Tier-3 exclusion rested on
   inference from absence; the curator has answered directly for these six items. The four production
   queries are still worth running — they now inform *sizing and defaults*, not keep-or-drop.
3. **The security surface returns, deliberately.** Share links and outbound mail are the two paths
   that reach outside Redmine's permission model. They are the reason 7b.1 stores only digests, keeps
   snapshots instead of live queries, and audits every access — those controls are load-bearing, not
   decoration, and cutting them later would restore the original defects.

## 8. Compatibility span

Redmine 5.1 (Rails 6.1) / 6.0 (7.2) / 6.1 (7.2) / 7.0 (8.1) — **three** Rails majors.

**Redmine 5.1: keep through the 0.x standalone line; drop at 1.0.** Dropping now would land a
second breaking change in the same release as the standalone unlock; 5.1 costs almost nothing
while the code is unchanged; and 1.0 already breaks templates, so the breakage concentrates into
one migration event. 5.1 has been EOL since 2026-06-30, so this is a schedule, not a defence.

**Ruby floor 3.1 now; delete `check_ruby_floor.sh` (69 lines).** Measured justification: **CI
already runs Redmine 5.1 on Ruby 3.2**, because 5.1's Gemfile allows `>= 2.7.0, < 3.3.0`.
*"Support 5.1" has never meant "write Ruby 2.7" in any environment this project tests* — and per
INV-7 an untested configuration is not supported. Declaring 3.1 makes the declared floor match the
tested floor, removes three of the checker's four rules' reason to exist (endless methods,
`Hash#except`, hash-value omission), and clears Liquid 5's ≥3.0 requirement with margin. README
honesty: a deployer on 5.1 + Ruby 2.7 becomes unsupported — which is **already** true, and the
grep script has been implying otherwise. If 5.1 is dropped at 1.0, raise to **3.2** (matches the
6.1/7.0 floor; enables `Regexp.timeout`).

**`compat/`: one module, one method per divergence, a comment naming the versions. Never scattered
`if Rails::VERSION`.** Shims: `enum` (~6 lines, always an explicit integer hash);
`serialize` — **`[OQ-A]`, and possibly an existing defect**: `serialize :layout, coder: YAML`
(`reporter_project_tab.rb:9-10`) is the Rails 7.1+ keyword form, which Rails 6.1 does not accept.
**Verify whether Redmine 5.1 support is already broken here before anything else in this
section**; `icons` (`sprite_icon` R6+); `assets` (the plugin-asset mirror); **`query_params`** —
`Query#as_params` has undocumented semantics and is the sharpest single core-API dependency
(`drill_through.rb`), so wrap it and add a per-branch spec asserting the shape; `autoload` (the
Zeitwerk ignore dance). New migrations target `ActiveRecord::Migration[6.1]`.

### CI matrix — additive, **17 jobs** (today 13)

| Job | Count | Proves |
|---|---|---|
| `rspec` (L1–L3, no boot) | 4 | library code passes on every branch |
| `adapter` | 3 | the aggregator's real SQL on PG16/MySQL8/MariaDB11 |
| **`corpus`** | 1 | the frozen goldens still reproduce **and the ported bodies are byte-identical** — the R-04 gate |
| **`minitest-standalone`** | 4 | full-app, **no secret**, fork-runnable — **G1** |
| `minitest-with-reporter` | 1 | the legacy shim; **deleted at 1.0** |
| **`render-smoke`** | **3** | one per engine — `:chromium_cdp`, `:wkhtmltopdf`, **`:gotenberg`** (pinned container) — **engine in a separate network namespace**: preflight round trip, conformance corpus, INV-5's forced failures, the readiness triple, **the three asset models incl. an allowlist-refusal case**, and Mermaid's per-engine disposition |
| **`migrate-updown`** | 3 | one per Rails branch: up from empty → `VERSION=0` → schema equals the pre-install dump → up again idempotently (§7 Reversibility) |
| `gates` | 1 | `layer_purity` + `zero_reporter` + `no_html_safe` + `compat_size` + `support_matrix` + **`drop_reference_parity`** (§9b.1) |
| ~~`ruby-floor`~~ | **0** | deleted with the floor decision |

**Additive, not multiplicative:** `render-smoke` is per **engine on one branch**, never engine ×
branch — 4 × 3 × 3 = 36 must be refused. `migrate-updown` is the one place a **per-branch** count is
unavoidable, because the reversibility of `ActiveRecord::Migration[6.1]` under Rails 8.1 is exactly
what is in doubt. Net **+4 jobs** (was +2 before OQ-3's answer and the reversibility requirement),
−1 deleted, −1 secret — **17 jobs**, and the "~16" figure above is superseded.

**PDF comparison never byte-diffs** (timestamps, object ids). Page count, extracted text, and the
**SVG chart source** (deterministic text). A coarse pixel histogram is **advisory only**.
`support_matrix.rb` cross-checks `requires_redmine`, the Ruby floor and the README table against
the matrix, so widening a claim without adding a cell fails CI — INV-7 mechanised.

## 9. Security and operations, made concrete

Covered above at their point of use; collected here for review:

| Concern | Mechanism |
|---|---|
| Template authorship = code execution | §4 INV-9: label + docs, **§4.1's granular role permissions** (`require: :member` derived from `authoring: true`; the plugin grants nothing itself, though core's default-data loader gives Manager every setable permission on a fresh install — which is why the upgrade diagnostic lists **our** roles; per-action `authorize` and route/action coverage asserted by parsing the controllers; boot-time name-collision check), opaque-origin sandbox, zero egress, append-only version audit, three filter reductions |
| Renderer credential exposure | **`DocumentRequest` has no field a credential could travel in** — no `cookies:`, `headers:`, `auth:`. Cookie-passing is not discouraged, it is *unrepresentable* |
| SSRF / egress | inline-only asset default; Chromium name resolution denied; Gotenberg's URL-conversion endpoint a forbidden code path; a `render-smoke` variant in a route-less namespace that must still produce a correct PDF |
| Supply chain | vendored Chart.js with a recorded sha256; no CDN; `StandardFilters` enumeration spec catching dependency capability drift |
| Wrong-number disclosure | errors never enter the document; SQL never reaches a rendered artefact |
| Render-path containment | request cap with a **refusal before any render**, per-render + batch timeouts, process pool of 1 with a bounded queue, streamed archives |
| Scheduler | the unique occurrence index; per-schedule rescue; bounded catch-up; explicit stored render identity so the "scheduled as anonymous vs test-send as current user" split cannot recur |
| Diagnosability | correlation id on every log line; engine id + version + duration stamped into **the artefact**; the preflight round trip |
| Retention | documents not persisted by default; opt-in with a mandatory TTL and a purge task |

## 9b. The authoring and viewing experience (R7, R9)

**Gap acknowledged, and it was the largest one in this dossier.** R9 ("easy for new users") had
exactly one mechanised criterion — *install in ≈3 commands* — and `functional-spec.md:284` admitted
it in a parenthesis: *"'easy for new users' beyond install is a usability question."* R7's
"beautiful" had two absolute criteria about *rendering*. Between them, nothing described what a
person actually does with this plugin. An install-only reading of R9 would let us ship something
easy to install and unusable, and pass every gate. Specified now.

**One design rule above the details: look native, not branded.** The plugin adopts Redmine's own
markup, classes and icon set per version (`compat/icons.rb`, `sprite_icon` on R6+) and ships **no
design language of its own** for chrome. *Rejected: a bespoke UI skin* — it would look current on
one Redmine version and wrong on the other three, and it is the reliable way to make a plugin feel
bolted on. "Beautiful" is spent entirely on the **report output**, where it is ours to control, and
"native" is spent on the **admin and authoring chrome**, where it is not. `[ASSUMPTION]` that
Redmine 7.0 does not change host markup enough to break this; `[OQ-E]`-adjacent, and cheap to fix
in one shim if wrong.

### 9b.1 Four authoring surfaces

**1. The editor — a lint panel, not a blank box.** A vendored, pre-built **CodeMirror 6** bundle
(`assets/javascripts/vendor/`, upstream version + sha256 in `THIRD_PARTY.md`, same rule as Chart.js
— pre-built and non-digested, so §6's "neither asset pipeline is involved" still holds). Liquid
syntax highlighting, bracket matching, and a **findings panel below the editor fed by the same
linter that runs in `rake reporter_dashboards:lint_templates`** — one implementation, two surfaces.
Findings are `{line, column, severity, code, message}`; the editor gutter marks them. Degrades to a
plain `<textarea>` if JS is unavailable, and the lint panel still works because linting is
server-side.

**2. The drop reference — generated from the declarations, so it cannot drift.** FR-20 already
requires every drop to expose *only its declared surface*. That declaration is therefore a
machine-readable API description, and the reference sidebar is **rendered from it at runtime**: every
drop, every accessor, its type, whether it is a batch accessor, and a copyable
`{{ … }}` snippet. Consequence worth stating plainly: **documentation drift for the drop layer
becomes structurally impossible**, and the alternative — a hand-written wiki page — is exactly the
artefact that is stale in every Redmine plugin. Same generator emits the Markdown reference in
`doc/`, per FR-50's "generated, not hand-maintained".

**3. Start from an example, never from empty.** *New template* offers a **starter gallery**: the
three existing example templates (cleaned, Chart.js 4, no handshake, `| json` throughout) plus a
minimal issue document and a minimal aggregate report — each with a one-line description and a
thumbnail rendered by the plugin itself in CI, so the thumbnail cannot show something the code no
longer produces. This is the single largest onboarding lever available and it costs almost nothing,
because the examples must exist as fixtures anyway. `[CITE: the two templates the curator supplied
in 00-idea.md are 747 lines of Liquid; nobody writes that from a blank textarea]`.

**4. A chart form that writes the tag.** `{% chart %}` has ~8 parameters. A small dialogue — type,
source variable, x, y, series, drill on/off — that **inserts the tag** rather than storing hidden
state. The author keeps a text template they can read, diff, export and paste into an issue; the
beginner never types the syntax. *Rejected: a GUI report builder storing structured JSON* — it
would fork the model (R1's "one plugin" applies to the authoring path too), break `git`-style
review of templates, and make FR-57's byte-identical export round trip meaningless.

### 9b.2 Preview, and the failure a preview must show

Preview renders in **both** bindings — HTML inline, and a **PDF preview through the configured
engine** — because "it looked fine in the browser and broke in the PDF" is the defect class this
whole dossier exists to remove; a preview that only proves the easy path is a false signal. Preview
is bounded (`preview_max_issues`, default 50, shown in the UI as *"preview of 50 of 1 284"* — never
silently truncated, per INV-4's spirit) and carries the `degraded` reasons and the render duration.
On failure it shows FR-58's diagnostics view: what failed, the Liquid line, engine and version, and
the correlation id — **in the editor, next to the code**, which is the only place it is actionable.

### 9b.3 The setup surface — R9's real content

Diagnostics (FR-33) already exists as a page and a rake task. Two additions turn it from a debugging
tool into the onboarding path: an **engine comparison table generated from `capabilities.yml`** (what
each engine needs installed, whether it needs a service, whether it renders offline, what it cannot
do — per §5.2.4), and a **"fix this" line per failing check** naming the command or setting. An
operator who lands on a red check must never have to search the source to learn what to type.

### 9b.4 The viewing surface — where "beautiful" is actually spent

One **print-first stylesheet with a single shared type scale**, used by the HTML view and the PDF
body alike, so the two are the same document at two sizes rather than two designs. Concretely:
`@page` geometry from `DocumentRequest#page`; `thead { display: table-header-group }` so long tables
repeat headers across pages; `break-inside: avoid` on cards, chart blocks and table rows;
`orphans`/`widows` 3; tabular figures for numbers; the chart palette shared with `ChartLayout`
(§6) so an HTML chart and its SVG twin are the same colours. Responsive down to a phone for the HTML
view; the dashboard widgets keep Redmine's own grid. Accessibility as a hard property of the SVG
path, not an aspiration: every `SvgRenderer` output carries `<title>`/`<desc>`, chart colour is never
the sole carrier of meaning (pattern or label as well), and the drill-through `<a>` elements are
real links — which also happens to make the PDF's charts clickable and its text selectable, the two
things a rasterised chart loses.

### 9b.5 How this is judged — falsifiably, and advisory where it must be

| Criterion | Mechanised? |
|---|---|
| A new template can be created, previewed and rendered to PDF **without opening documentation** | **advisory — non-deterministic — not a correctness guarantee**: a 3-participant walkthrough, recorded, on a clean install |
| Every drop accessor in the reference exists at runtime, and every runtime accessor appears in the reference | **yes** — the reference is generated from the declaration; a diff test asserts both directions |
| Every starter template lints clean and renders on **every** engine in the matrix | **yes** — CI |
| Every diagnostics failure state has a remediation string | **yes** — a test enumerates the closed check list and asserts a non-empty remediation for each |
| Time-to-first-report on a clean install | **advisory**, recorded as a number in the release notes so it can get worse visibly |
| HTML and PDF of the same template agree on layout | partially — SVG goldens are deterministic; the visual diff stays **advisory, never a hard gate** (§6) |

**Stated risk of this section:** it is the newest and least-reviewed part of the dossier, written
after the red-team pass rather than before it, so it has not been attacked. The two claims most
likely to be wrong are that a vendored CodeMirror bundle stays inside §6's no-build-step rule
(`[OQ-M]` — verify against a real Redmine 7.0 install before T-34 commits to it) and that the
generated drop reference is genuinely sufficient documentation rather than an API dump wearing a
sidebar. Neither is load-bearing for phases 0–2.

## 10. Invariant traceability

| Inv | Mechanism | Gate |
|---|---|---|
| **INV-1** | `ScopeBinding` has exactly **two** sources, both visibility-scoped by construction. The drop-archaeology path — the only one whose provenance could not be vouched for — is deleted, **and with it the fail-open `enforce_visibility` rescue**. `RenderContext#actor` is explicit, so `User.current` is never ambiently assumed | `corpus` multi-actor cases |
| **INV-2** | unchanged verbatim kernel + a role-restricted-CF case per actor in the corpus (does not exist today) | `corpus` |
| **INV-3** | verbatim kernel, protected by the **byte-identity rule** | `corpus` + `adapter` |
| **INV-4** | every tag and drop writes to `RenderContext#diagnostics`; `empty_result` gains `degraded` + reasons; the widget shows a "reduced" marker and the PDF stamps it into metadata. Also covers unknown placed blocks and truncated collections | one spec per refusal path |
| **INV-5** | `Result` sum type + the `%PDF-`/`%%EOF` post-condition **in the wrapper above every adapter** + `create_attachment` accepting only `Success`. Limit stated in §5 | `render-smoke`, forced failures per engine |
| **INV-6** | unsaved-default-tab pattern retained + `assert_no_writes` on every read action | `minitest` |
| **INV-7** | the matrix + `support_matrix.rb` + the `StandardFilters` spec + the wkhtmltopdf removal being a *CI* condition | `gates` |
| **INV-8** | `AssetResolver` reaches the network in **no** code path under the default `asset_policy: :bundled`; Chromium denies name resolution; `DocumentRequest` cannot carry a credential. **Amended 2026-08-04 (§5.1):** an HTTP client now exists for `:redmine`/`:external`, so the gate is no longer "no client in the tree" — it is that the client is unreachable under `:bundled`, that it is anonymous by construction (the request builder has no parameter for a credential), and that `:asset_http` stays off wherever the engine supports `:asset_upload`. **A weaker gate than before, and named as such** | `layer_purity` grep + the route-less-namespace render + T-33's negative tests (empty allowlist ≡ `:bundled`; post-DNS private-range refusal; no credential header) |
| **INV-9** | §4's five mechanisms + three privilege reductions | `no_html_safe`; a functional test asserting the CSP `sandbox` header **without** `allow-same-origin` |

## 11. Risks carried from `04-risks.md`

| Risk | Technical mitigation here |
|---|---|
| R-04 silent numerical drift (15) | Phase-A byte-identity + the `corpus` job + the pinned reference date + the per-adapter overlay instead of a tolerance |
| R-03 visibility invariants lost (15) | two-source `ScopeBinding`; the fail-open rescue deleted rather than carried; multi-actor corpus cases; the five 0.5.0 fixes as named tests |
| R-02 stall (20) | every step ships; `glue/legacy/` keeps existing installs working mid-sequence |
| R-05 PDF fidelity vs 747 lines of templates | wkhtmltopdf retained as a CI-verified compatibility engine; `lint_templates` shows the blast radius before the default changes |
| R-08 external service vs R9 | in-process Chromium as default, Gotenberg documented-unverified; **G7 restated honestly as "≈3 commands plus one package install"** |
| R-12 R7 unfalsifiable | the two absolute criteria (§3.4) plus a p95 baseline measured **before** step 2 |
| R-16 R5 unexamined | `[OQ-12]`/C-011 stays open; §4 makes INV-9 enforced rather than implicit, which is the mitigation available *without* re-opening R5 |

## 12. Open questions

| # | Question | Blocks |
|---|---|---|
| ~~**OQ-A**~~ | **CLOSED 2026-08-04 by measurement — claim REFUTED.** It does not break: Rails 6.1, 7.2 and 8.1 all round-trip it to byte-identical YAML. 6.1's signature is `serialize(attr_name, class_name_or_coder = Object, **options)`, so `coder:` is silently discarded and the `Object` default selects YAML anyway. `reporter_project_tab.rb:9-10` is **not** a defect and the 5.1 support claim stands. The shim is still wanted, for the inverse risk: a non-YAML coder would be silently ignored on 6.1. Evidence: `reference/verification-oq-a-serialize-oq-b-liquid.md` | §8 |
| ~~**OQ-B**~~ | **CLOSED 2026-08-04 by measurement — claim REFUTED, and the consequence inverts.** It parses *and* resolves on Liquid 4.0.4 and 5.13.0, in all three error modes, bare, inside `{% if %}` and through a filter. The lexer allows a trailing `?` explicitly: `VariableParser = /…|#{VariableSegment}+\?\?/`. So the five `?` accessors were **always reachable** — live surface, not dead — and §3.2's aliases are a **backward-compatibility requirement**, not a courtesy. Evidence: `reference/verification-oq-a-serialize-oq-b-liquid.md` | §3.2 |
| ~~**OQ-C**~~ | **CLOSED 2026-08-06 by measurement, in T-19.** Enumerated on both majors: 4.0.4 provides **49** filters, 5.13.0 provides **61**. Of §3.6's list, `where` and `sort_natural` are provided by BOTH, behave identically, and already work on the owned drops (Liquid's `where` reads through `Drop#[]`) — so they are **inherited, not reimplemented**. `sum` is provided by **5.x only**, which is a cross-major divergence a plugin supporting both cannot leave in place, so it **is** owned and reproduces Liquid 5's semantics exactly. Everything else on the list is absent from both. `spec_liquid/filters_spec.rb` **pins the full name list per version and FAILS on an unpinned one**, so a `bundle update` that adds a filter is a decision rather than a silent capability grant — Liquid 5 added twelve since 4.0.4, every one of which became template surface without anybody choosing it | §3.6 |
| **OQ-D** | Liquid floor `>= 5.5` or `>= 5.6` (`Liquid::Environment` for scoped **tag** registration) | §4 |
| **OQ-E** | Redmine 7.0's asset pipeline | §6 (design does not depend on it) |
| ~~**OQ-F**~~ | **CLOSED 2026-08-06 by curator decision — the question is void because the SETTING is deleted.** It asked which default `template_authoring` should take, and both answers were wrong for the same reason: a global switch cannot say *"this role, in this project"*. `:project_managers` would have **widened a code-execution privilege on upgrade, silently and installation-wide**, which is worse than the break it avoided because a break is visible. Replaced by §4.1's 13 role permissions in two modules, with `require: :member` **derived** from `authoring: true`, the upgrade situation **named** by preflight and `import:plan` instead of papered over by a default, and a parity spec that parses the controllers so an unguarded action cannot ship. **One claim in the first version of this row was refuted by T-40's review and is corrected in §4.1:** the plugin grants nothing, but *"no role holds one until an administrator grants it"* is not true in general — core's `DefaultData::Loader` gives the **Manager** role every setable permission on a fresh install, ours included, so `:admins_only` is not a construction guarantee and the diagnostic has to list our roles too. T-40 | §4.1 |
| **OQ-G** | The 19-vs-17 delegated-accessor count in `reference/redmineup-gem-drop-surface.md` | §3.2 |
| ~~**OQ-H**~~ | **CLOSED 2026-08-04 by curator decision.** The third template type is built — as a `source` field, not a branch (§7b.4). Still `[OQ]` and *scoped narrowly*: whether `JournalDrop` and `time_in_status` are built. Those two were never part of the six required capabilities, and `import:plan`'s usage counts now inform that one remaining call | §3.1 |
| ~~**OQ-I**~~ | **CLOSED 2026-08-04 by OQ-4's answer.** Yes — `asset_policy: :redmine` / `:external`, allowlist-only, empty allowlist fails closed, and **the plugin fetches, not the engine** (§5.1). Now a supported, CI-tested mode rather than a documented-unverified one | §5.1 |
| **OQ-J** | The concrete `resource_limits` constants — calibration, not design | §4 |
| **OQ-K** | Is a separate-process `:ferrum_pdf` adapter worth maintaining beside a raw-CDP adapter that already works? A duplication question, not a capability one | §5.2 |
| ~~**OQ-L**~~ | **CLOSED 2026-08-06 BY MEASUREMENT: no.** Both engines rendered one probe document. Chromium 141 draws the diagram (`mermaid.run()` resolves, node labels extract as SVG text); wkhtmltopdf 0.12.6.1 *with patched qt* answers `PROBE-NO-MERMAID-GLOBAL` — the bundle never defines its global, because Mermaid 11 is an esbuild IIFE using `\|\|=` (ES2021) that Qt WebKit cannot parse. So `:mermaid` is declared **absent** for wkhtmltopdf despite `:javascript` being present, which is the case the per-feature vocabulary exists for | §6.1 |
| **OQ-M** | Does a pre-built CodeMirror 6 bundle stay inside §6's no-build-step / non-digested asset rule on Redmine 7.0? | §9b.1 |
| ~~OQ-3~~ | **CLOSED 2026-08-04 by curator decision**: external container acceptable *as one option*, documented and safe → Gotenberg becomes a **third CI-verified adapter**, default unchanged (§5.2) | §5.2 |
| ~~OQ-4~~ | **CLOSED 2026-08-04 by curator decision**: fetch external references, ship local assets with the request → the three-model resolver + `asset_policy` (§5.1). The premise *"there will be a standard for this"* is **corrected**: there is no packaging standard, only three recurring mechanisms | §5.1 |
| OQ-6/OQ-8 | carried from `04-risks.md`: Redmine 5.1 + Ruby floor; the performance baseline | §8 |
