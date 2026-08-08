# Functional spec — `redmine_reporter_dashboards` as a standalone plugin

- **Idea:** 004-redmine-reporter-modern
- **Decision:** **ADR-004** ([`05-decision.md`](./05-decision.md), accepted 2026-08-04)
- **Sequencing:** [`07-phasing.md`](./07-phasing.md) — phase numbers below refer to it
- **Describes:** *what* the plugin does. The *how* is [`technical-spec.md`](./technical-spec.md).

## Scope

### In scope

The plugin becomes **self-sufficient**: installable, runnable and fully testable with no other
plugin present, while keeping everything it does today and absorbing the reporting features it
currently borrows.

| Area | Phase |
|---|---|
| Project dashboards: tabs, row layout, block add/move/remove, per-project and per-role config | already exists — must keep working standalone (1) |
| Core widgets: issues, activity, calendar, news, documents, time log, issue-query selection | already exists — 8 of 10 have no external dependency (1) |
| `{% sql_aggregate %}` in every mode: time series, categorical breakdown, crosstab, measures, flags, completeness, age buckets | 1 |
| Drill-through URLs with documented degradation under a length cap | 1 |
| `{% version_rollup %}` — per-target-version rollup incl. summed numeric custom fields | 1 |
| Own Liquid drop layer and filter set, replacing the vendor gem's | 2 |
| Liquid execution policy: resource limits, wall-clock timeout, filter allowlist, output-safety | 2 |
| `\| json` filter and a template lint that requires it inside `<script>` | 2 |
| Report rendering to **HTML** and **PDF** through a pluggable engine | 3 |
| Preflight / self-test diagnostics (page + rake task) | 3 |
| Report template CRUD, preview, import/export | 4 |
| Template types: one-PDF-per-issue and one-PDF-for-a-set | 4 |
| Scheduled e-mail reports, with run state, idempotency and per-schedule isolation | 4 |
| My-page report widgets | 4 |
| Localisation: the existing 9 locales | 4 |
| **Share links** — expiring, revocable, audited, snapshot-based (replaces unexpiring MD5 tokens) | 4 |
| **Template exchange** — versioned JSON/YAML bundle, safe by construction, two-step import | 4 |
| **Failure reports** — diagnostics panel, optional honest failure document, traceable | 3 |
| **Time-entry reporting** — as a `source` field, not a third template branch | 4 |
| **Ad-hoc report mail** — visibility-scoped, server-controlled sender, audited | 4 |
| **Public report links** — on the share-link mechanism, snapshot-served | 4 |
| **Three asset models + `asset_policy`** — inline / upload / fetch, `:bundled` by default, allowlist-only above that | 3 |
| **A third engine adapter** — an external renderer service as a CI-verified *option*, never the default | 3 |
| **Mermaid diagrams** — bundled, output-sanitised, with an honest per-engine degradation | 3 |
| **Reversible migrations** — up → `VERSION=0` → up, tested per Rails branch | 1 |
| **Authoring experience** — lint-in-editor, dual-binding preview, generated drop reference, starter gallery, chart form | 4 |
| **One print-first stylesheet** shared by HTML and PDF, plus accessible-by-construction charts | 3 |

### Out of scope (non-goals carried forward from `01-context.md`)

- **Not** a port of the base plugin's implementation. Reuse as *specification*, not as
  repackaged code.
- **Not** dependent on the `redmineup` gem.
- **Not** reproducing three *defects*, while keeping the capabilities they belonged to:
  unexpiring MD5 capability tokens, `YAML.load_file` + `constantize` on import, and
  `rescue Exception => e; e.message` returning the failure text as the document body. **The
  capabilities are in scope in improved form** — see FR-51…FR-62 and `technical-spec.md` §7b.
  *Revised 2026-08-04: these were listed as excluded; the curator requires them.*
- **Not** support for Redmine versions absent from the CI matrix (INV-7).
- **Not** governed by `principles.md` §5.

## Actors

| Actor | Holds | Cares about |
|---|---|---|
| **Report author** | `add_reporter_dashboards_templates` + `edit_own_…` / `edit_…` (`technical-spec.md` §4.1) | Writing a Liquid template once and having it render correctly in HTML *and* PDF. **These permissions are a code-execution privilege (INV-9) and the spec must say so.** They carry `require: :member`, so Redmine will not offer them to the Anonymous or Non-member role, and no role holds one until an administrator grants it |
| **Report consumer** | `view_reporter_dashboards_reports` | Opening a report somebody else wrote, and downloading what it produces — without being able to change what it does |
| **Report distributor** | `manage_reporter_dashboards_schedules`, `share_…`, `publish_…`, `mail_…` | Getting a correct report to the right people on time. Three of the four reach **outside** Redmine's permission model, which is why each is its own grant rather than part of authoring |
| **Dashboard viewer** | `view_reporter_project_page` | Numbers they can trust, and drill-through that matches the chart element |
| **Dashboard curator** | `manage_reporter_project_page`, `manage_reporter_project_tabs` | Arranging widgets; removing a broken one |
| **Report recipient** | none in Redmine | Receiving a scheduled report that is correct, or being told it failed |
| **Redmine administrator** | admin | Installing in ≈3 commands; diagnosing "why is this empty / wrong / slow" without shell access |
| **Operator** | shell | A scheduler they can reason about: did it run, what failed, can it be re-run |

## Use cases

### UC-1 — Install and verify (Phase 1, hardened in 3)

1. Clone into `plugins/`, `bundle install`, `rake redmine:plugins:migrate`, restart.
2. Enable the module on a project; assign permissions; the dashboard link appears.
3. **Administration → Plugins → diagnostics** reports engine identity and version, runs a probe
   render, and states whether the chart came out non-blank, whether an image resolved, and
   whether the renderer could reach back to the Redmine host.

**Unhappy paths.** No other plugin installed → everything works (this is the point of Phase 1).
PDF engine missing or misconfigured → a **named** diagnostic saying which engine and what to
fix; never a stack trace, never a `.pdf` containing an error. Renderer cannot reach the Redmine
host → the diagnostic says so *at install time* rather than the user discovering chart-less
PDFs in a quarterly report.

### UC-2 — Build a dashboard (Phase 1)

Curator adds widgets, moves them up/down/left/right, creates and renames tabs. Settings are
validated before storage; an invalid setting is dropped with a log line naming the widget and
the key, not persisted.

**Unhappy paths.** A widget whose data source fails renders a **placeholder that keeps its own
controls**, so an administrator can still remove it, and the rest of the page is unaffected. A
widget bound to a saved query the viewer may not see is not rendered for them. **A dashboard
page view performs no database write** (INV-6).

### UC-3 — Author a template and see it in HTML (Phases 1–2)

Author writes Liquid using aggregation tags and drops; preview shows the rendered result.

**Unhappy paths.** Unknown drop path → a visible inline marker plus a render-level warning
list, *not* a blank area and *not* an exception string in the document. Template exceeds a
resource limit or the wall-clock budget → refused with a typed error naming which limit;
partial output is discarded. An unusable dimension, an invalid enum value, a failed
drill-through, an oversized crosstab → **empty-safe result carrying an explicit `degraded` flag
and a reason** (INV-4), so "empty because refused" is distinguishable from a true zero.

### UC-4 — Export a report to PDF (Phase 3)

Author or viewer exports; the plugin builds a document request and hands it to the configured
engine; bytes come back and are streamed to the user.

**Unhappy paths.** Engine unavailable → typed failure, HTTP error with a clear message, one log
line. Render exceeds its timeout → typed timeout within a bounded wall clock, **and the engine
child process is gone**. Template never signals readiness → timeout, logged degradation, never
an indefinite hang. Batch over the configured cap → **refused before any render happens**, with
a message naming the cap and the actual count. **A failure never produces a file named `.pdf`,
and is never persisted as an attachment** (INV-5).

### UC-5 — Receive a scheduled report (Phase 4)

A schedule fires once per occurrence; recipients receive one rendered report.

**Unhappy paths — all of these are current defects being fixed, not hypotheticals.** The task
runs twice in a day → **exactly one** delivery. The task does not run for three days → the
missed occurrences are **visible and recoverable**, and a normal run does *not* silently
backfill them. One schedule's template raises → the other schedules still deliver; the failure
is recorded with a reason and the task exits non-zero. A render fails → the owner receives an
**explicit failure notice with no attachment**, never a green-looking e-mail containing an
exception. Five recipients → **one** render, not five.

### UC-6 — Two people read the same dashboard (Phases 1–2)

Two viewers with different permissions open the same dashboard and **legitimately see different
numbers**, because aggregation runs through each viewer's own visibility.

**This is a designed control, not a bug**, and the output must say so: a shared document carries
an "as seen by …" marker. Where one authoritative figure is required, that is an explicit,
permissioned, visibly-labelled mode — not a silent default.

### UC-7 — Migrate from the plugin pair (Phase 4→5)

An administrator running both plugins moves to the single plugin: existing dashboards, tabs,
report templates and schedules survive.

**Unhappy paths.** A dry-run reports the blast radius — how many templates, schedules and tabs,
and which templates use constructs that will render differently — **without writing**. Rollback
is documented, and a database backup is stated as mandatory. **The uninstall footgun is
documented and guarded:** following Redmine's normal uninstall procedure on the old plugin must
not destroy templates the new plugin depends on.

## Functional requirements

Numbered and testable. **Inv** links to `model.json`; **G** links to `01-context.md`'s goals.

### Independence (Phase 1)

| # | Requirement | G |
|---|---|---|
| FR-01 | The plugin installs, boots, and serves every dashboard feature with the base plugin **absent**. | G1 |
| FR-02 | The source tree contains **zero references** to the base plugin or the vendor gem, enforced mechanically in CI. During the transition a shrinking allowlist is permitted; each entry carries a reason. | G1 |
| FR-03 | No workflow reads a repository secret, so the **complete** suite — including the full-application tests — runs on a pull request from a fork. | G1 |
| FR-04 | Every Liquid tag and drop registers when the base plugin is absent, and a failure in one registration does not prevent the others. | — |
| FR-05 | The plugin runs on every Redmine version in its CI matrix, and claims no version absent from it. | INV-7 |
| FR-06 | Aggregation returns **the same numbers** as v0.5.0 for every case in the frozen corpus, on PostgreSQL, MySQL and MariaDB. | G4 |

### Visibility and access (Phases 1–2)

| # | Requirement | Inv |
|---|---|---|
| FR-07 | Every aggregation starts from the **viewer's** visible issue scope; a permission grant does not imply private issues or hidden trackers. | INV-1 |
| FR-08 | Saved queries resolve through visibility; an invisible query is indistinguishable from a missing one and yields an empty-safe `degraded` result — never another user's numbers. | INV-1 |
| FR-09 | A role-restricted custom field is refused as dimension, split, measure and completeness field, and **its name does not appear anywhere in the output** for a viewer not entitled to it. | INV-2 |
| FR-10 | Visibility conditions are applied in join conditions and **fail closed** when they cannot be constructed. | INV-3 |
| FR-11 | Time-entry measures count only entries the viewer may see. | INV-3 |
| FR-12 | Two aggregations in one process for different viewers do not leak the first viewer's scope into the second, **in either order**. | INV-1 |
| FR-13 | A drill-through URL built for one viewer does not widen scope when opened by another. | INV-1 |
| FR-14 | A dashboard page view performs **no** database write. | INV-6 |
| FR-15 | Persisted widget settings are typed and bounded; over-limit input is dropped with a log line, never stored. | — |

### Templates and Liquid (Phase 2)

| # | Requirement | Inv |
|---|---|---|
| FR-16 | The plugin provides its **own** drop layer. Reference objects expose an **id as well as a name**, so a template can build links without a lookup tag. | — |
| FR-17 | Rendering enforces resource limits **and** a wall-clock timeout; a breach is a typed error and partial output is discarded. | INV-9 |
| FR-18 | Only allowlisted filters are registered. Filters that invoke an arbitrary named method, or that accept a template-supplied regular expression, are **not** provided. | INV-9 |
| FR-19 | A `\| json` filter is provided and used in **every** shipped example and documentation snippet; a lint rejects interpolation inside `<script>` that does not use it. | — |
| FR-20 | A drop exposes only its declared surface; an undeclared key returns nothing rather than dispatching. | INV-9 |
| FR-21 | Authoring a report template is documented as a **code-execution privilege**, and the permission model reflects that. | INV-9 |
| FR-21b | **Who may do what is a role permission, never a plugin setting.** Every surface is guarded, and every guard is either a **named Redmine role permission** granted per role and per project the way core does it, or a recorded non-permission guard (`require_admin` for an installation-wide diagnostic, a core permission for core data) that CI checks against the controller. **No capability of the reporting surface is switched on by a global plugin setting** — the two settings the plugin does have, `asset_policy` (FR-64) and external mail addresses (FR-61), are installation policy about egress and delivery, not about what a role may do. Authoring permissions carry `require: :member` **derived from the fact that they execute code**, so Redmine never *offers* one to the Anonymous or Non-member role, and the plugin itself grants nothing. CI asserts, by parsing the controllers and `config/routes.rb`, that every public and every routed action is accounted for, and that `authorize` runs **for each mapped action** rather than merely appearing in the file *(added 2026-08-06; replaces the rejected `template_authoring` setting — `technical-spec.md` §4.1)* | INV-9 |
| FR-21c | The **upgrade and fresh-install situation is named, not defaulted**: a diagnostic lists every role holding an authoring permission — the base plugin's *and* this plugin's — because "the plugin grants nothing" does not mean "nothing is granted". Redmine's own default-data loader gives the Manager role every setable permission on a fresh install, so an installation-wide `:admins_only` cannot be claimed by construction and is not claimed *(added 2026-08-06 — `technical-spec.md` §4.1; owner T-27)* | INV-7 |
| FR-22 | A template referencing an unknown drop path produces a visible marker plus a warning list, and a **linter** reports unknown paths ahead of rendering. | — |
| FR-23 | Every aggregation result carries a `degraded` flag with reasons; a refusal is distinguishable from a true zero. | INV-4 |
| FR-24 | Every documented cap is enforced, and exceeding it truncates or refuses **with `degraded` set** and one log line — never silently. | INV-4 |

### Rendering (Phase 3)

| # | Requirement | Inv |
|---|---|---|
| FR-25 | PDF rendering goes through a **document-request** interface: page geometry, orientation, margins, a footer model with page numbers, media type, background printing, page breaks, readiness policy, timeout. | — |
| FR-26 | Each engine adapter **declares its capabilities**. The plugin degrades on an undeclared capability and **says so**; a declared capability that fails is a defect. | INV-7 |
| FR-27 | The engine is selected by configuration with an auto-detect default; the resolved engine, its version and the render duration are **logged once at boot and stamped into every produced document**. | — |
| FR-28 | Rendering completion is determined by an **explicit readiness signal** produced by the plugin's own chart helpers, with a hard timeout — not a fixed delay. | — |
| FR-29 | A render failure returns a **typed** failure: never an exception to the user, never HTML-as-PDF, never a `.pdf` containing an error, never persisted as an attachment. | INV-5 |
| FR-30 | The renderer is never given a session credential or API key. Assets are supplied to it rather than fetched with the user's authority. | INV-8 |
| FR-31 | Chart and diagram libraries are served from the plugin's own assets by default, not a third-party CDN. | INV-8 |
| FR-32 | Multi-document requests are **capped**, with a refusal before any render; renders have a per-render timeout, a batch timeout, and a bounded concurrency limit; archives are streamed, not buffered in memory. | — |
| FR-33 | A **diagnostics/self-test** surface exists as both a page and a rake task, exercising a real round trip and exiting non-zero on failure. | — |
| FR-34 | A template needs **no** engine-specific workaround: modern layout works, a current chart library works, no polyfills, no hand-rolled readiness handshake. | G3 |

### Reporting surface (Phase 4)

| # | Requirement | Inv |
|---|---|---|
| FR-35 | Report templates can be created, edited, previewed, exported and imported. Import is **safe by construction** — no arbitrary class instantiation from file content, independent of Ruby version. | — |
| FR-36 | Two template types are supported: one document per issue, and one document for a set. | — |
| FR-37 | A report template resolves through the same scope its picker offers. | — |
| FR-38 | Schedules record run state: last run, status, error and duration. | — |
| FR-39 | A schedule occurrence delivers **at most once**, enforced by a database constraint, not only by application logic. | — |
| FR-40 | A missed occurrence is visible and explicitly recoverable; a normal run does not silently backfill. | — |
| FR-41 | One failing schedule does not prevent later schedules from delivering; the run exits non-zero. | — |
| FR-42 | A scheduled report renders **once per occurrence**, not once per recipient. | — |
| FR-43 | A failed scheduled render notifies the owner with **no attachment**; recipients never receive a green-looking e-mail containing a failure. | INV-5 |
| FR-44 | The scheduler's operator contract — that it requires a periodic external invocation — is **documented**, and diagnostics warn when it has never run. | — |
| FR-45 | The render identity of a scheduled report is explicit, stored and auditable, and a test send uses the **same** identity as the real run. | — |
| FR-46 | Existing dashboards, tabs, templates and schedules survive migration; a **dry-run** reports the blast radius without writing; the old plugin's normal uninstall cannot destroy data the new plugin needs. | — |

### The six carried-forward capabilities *(added 2026-08-04)*

| # | Requirement | Inv |
|---|---|---|
| FR-51 | A **share link** carries a mandatory expiry, is individually revocable, and optionally limits total uses. Only the token's **digest** is stored, and comparison is constant-time | — |
| FR-52 | A share link authorises **one pre-computed document** (snapshot), not a live query, so **no visibility decision is made at request time**. Live-query links are opt-in per template and record the identity they render as | INV-1 |
| FR-53 | Every share-link access is recorded (timestamp, address, agent). Owners and admins can list active links and revoke them, individually or all for a template | — |
| FR-54 | Attachment URLs are scoped to the share link that produced them, and expire and revoke with it | INV-8 |
| FR-55 | Template export produces a **versioned bundle**; import resolves the template type through a **closed map** and never instantiates a class named in the file, independent of Ruby version | — |
| FR-56 | Import is two-step: a **plan** that writes nothing and reports per-template new/updated/skipped plus lint findings, then an apply that is transactional **per template**, so one bad template does not abort the bundle. Conflict policy is explicit | — |
| FR-57 | Export → import → export is **byte-identical** | — |
| FR-58 | A render failure produces a diagnostics view naming what failed, the template, the Liquid line where applicable, engine and version, and a **correlation id** | INV-5 |
| FR-59 | An **optional** failure document may be produced: a real, valid PDF clearly titled as a failure, named so it cannot be mistaken for the report, carrying the correlation id and a **safe** summary — never a raw exception, never SQL. Default off | INV-5 |
| FR-60 | Reporting over **time entries** is supported through a `source` field on the template, sharing one controller, one CRUD, one preview, one permission set and one **result** vocabulary with issue reporting — not a parallel branch. **Narrowed 2026-08-08 (S-13):** the shared vocabulary is the SHAPE of a result (buckets, drill-through filters, caps), **not the query builder** — the two sources resolve through different Redmine query classes and are computed by different modules, because `QueryAggregator` counts issues by construction. A template body reports on **one** source; mixing both in one template was dropped by curator decision, not deferred. **As built (T-31, 2026-08-08):** `Aggregation::TimeEntryAggregator`, answering `SUM(hours)` or a distinct entry count over eleven dimensions and emitting `QueryAggregator`'s `single_result` keys exactly — asserted against a real call, not a copied list. **One capability the issue path has and this one does not: a time series.** A time entry is not opened and closed, so `{% sql_aggregate %}` with no `group_by` over a time-entry scope is refused and degrades `aggregation_group_by_required` rather than inventing a created/closed flow | — |
| FR-61 | Ad-hoc report mail resolves issues through the **requester's visible scope**; the sender is **server-controlled** with the requester in `Reply-To`; recipients are Redmine users unless an admin enables external addresses against a **domain allowlist**; every send is audited and rate-limited | INV-1 |
| FR-62 | Public report links are available, **off by default**, enabled per template, and serve a snapshot — so "public link" never means "visibility check skipped" | INV-1 |

### Assets, Mermaid, reversibility and the authoring experience *(added 2026-08-04 — OQ-3/OQ-4 answered; three specification gaps closed)*

| # | Requirement | Inv / G |
|---|---|---|
| FR-63 | Asset resolution supports **three models** — inline, request-borne upload, and HTTP fetch — and each engine **declares** which it supports. The resolver picks the **most restrictive model the engine offers** for each reference | INV-8 |
| FR-64 | `asset_policy` defaults to **`:bundled`**: no egress, third-party URLs **refused with the URL named**. `:redmine` and `:external` are **per-install** settings, never per template, and are **allowlist-only** — an empty allowlist behaves exactly as `:bundled` | INV-8 |
| FR-65 | When policy permits a fetch, **the plugin fetches and the engine receives bytes**. Fetches are anonymous — never a cookie, session, API key or `Authorization` header — `https`-only, size- and time-capped, redirect-free, and refused for addresses resolving into private or link-local ranges | INV-8 |
| FR-66 | Chart and diagram libraries and fonts are **always inline** and unaffected by `asset_policy`; no policy value can make a chart depend on egress | INV-8 |
| FR-67 | An **external renderer service is a supported option, not the default**. It is exercised in CI against a pinned version, and its preflight **fails** — with a named remediation — when the service is reachable without the configured credential | INV-7 |
| FR-68 | **AMENDED 2026-08-06 (§Findings F-17).** A template may use **any** modern JavaScript library, offline, with no per-library plumbing: it is included like any other asset, and `window.__rd.begin()/end()` is the one contract that tells the renderer to wait for it. **Mermaid is vendored as a convenience, not as a mechanism**, with a block tag for ergonomics. The SVG sanitiser this row used to require is **dropped**: an author may write `<script>` directly (INV-9), so sanitising a library's output is a cost with a security-shaped name. The control that matters is FR-19 — **Redmine content** entering a document stays escaped, `interpolate:` included. On an engine that cannot run the library the **source** is emitted, labelled, with a `Degradation` — never a blank space | INV-9 |
| FR-68b | An engine declares whether it runs **post-ES5 JavaScript**, not whether it runs a named library. Measured: wkhtmltopdf declares `:javascript` and fails to *parse* `\|\|=`, so it cannot run Chart.js 4, Mermaid 11 or anything else modern — one capability tells an author that truth once, where a per-library one would lie by omission about every library it does not name | INV-7 |
| FR-69 | Every plugin migration is **reversible**. Migrating to `VERSION=0` leaves no plugin table, index or `plugin_schema_info` row, **and does not drop the pre-existing `reporter_project_tabs`**. Up → down → up is tested per Rails branch in CI and is idempotent | — |
| FR-70 | No schema migration reads or writes template content; data import is a rake task, so a schema rollback never destroys imported data. Rolling the **plugin** back one minor version without rolling back the schema does not raise | — |
| FR-71 | The template editor shows **linter findings with line numbers from the same linter the rake task runs**, and preview renders in **both** bindings — HTML **and** PDF through the configured engine | G3 |
| FR-72 | The **drop reference is generated from the drops' declared surfaces**, and CI asserts parity in both directions: every documented accessor exists at runtime and every runtime accessor is documented | — |
| FR-73 | *New template* offers a **starter gallery** of lint-clean examples that render on every engine in the matrix; `{% chart %}` can be produced by a form that **inserts the tag** rather than storing hidden structured state | G7 |
| FR-74 | Every diagnostics check has a **remediation string** naming the command or setting to change, asserted for the closed check list, and the setup surface shows an engine comparison **generated from `capabilities.yml`** | G7 |
| FR-75 | The admin and authoring chrome uses **Redmine's own markup, classes and icon set per version** and ships no design language of its own; HTML and PDF share **one print-first stylesheet and one type scale** | G3 |
| FR-76 | Chart and diagram output is **accessible by construction**: `<title>`/`<desc>` on every SVG, meaning never carried by colour alone, drill-through as real links — so PDF charts stay selectable and clickable | — |

### Cross-cutting

| # | Requirement | G |
|---|---|---|
| FR-47 | Viewer-relative numbers are preserved as a **documented control**, and shared output is labelled with the identity it was rendered as. | — |
| FR-48 | Query count is **independent of issue count**, and an aggregate-only template instantiates **zero** issue objects. | G3 |
| FR-49 | Aggregation output is bounded regardless of input size. | INV-4 |
| FR-50 | Documented limitations (per engine, per database) are published and **generated from the test run**, not hand-maintained. | INV-7 |

## Behaviour rules and edge cases

**Degradation ladder — the same shape everywhere.** (1) Succeed. (2) Succeed with `degraded`
set, a reason, and one log line. (3) Refuse with a typed error and a message naming the cause.
(4) Never: silent wrong output, an exception reaching the user, or a failure disguised as a
document. Rule (4) is the one the current code breaks in three places.

**Empty vs refused.** An empty result and a refused result are **different states**. Every
aggregation and render result carries `degraded` + reasons. This is new — today's contract is
empty-safe only — so every existing empty-result expectation is *amended*, not merely carried.

**Drill-through under the URL cap.** Degrade in a fixed order: shed columns and totals, then
grouping and sort, then emit no URL and log why. **The filter set parsed out of a degraded URL
must be identical to the un-degraded one** — the point is that the issue list still matches the
chart element. A degradation that quietly drops a filter is a wrong-number bug wearing a
cosmetic costume.

**Reference-object identity.** Where the vendor drop exposed only a display name, the own drop
exposes id and name. Two existing lookup tags become unnecessary and are retired with a
migration note rather than reimplemented.

**Known limitations stay visible.** A documented database-specific limitation remains
documented and skipped-with-reason in the suite rather than silently broken. If it is fixed,
the skip becomes an assertion and the published matrix row changes.

## Acceptance criteria

Per goal, with the honest split between what is mechanised and what is not:

| Goal | Mechanised | Human |
|---|---|---|
| **G1** full suite on a fork PR | no-secret check in CI; no secret-gated job conditions | one dated fork-PR run per release — a workflow cannot fork itself without reintroducing the credential G1 removes |
| **G2** newest Redmine, no hidden skips | the dependency-skip helper deleted and its call sites assert; newest branch in every job; skip inventory contains no entry for it | — |
| **G3** no engine workaround | greps for polyfill / readiness-handshake / float-layout in the reference template; layout and background-printing fixtures pass | "renders equivalently" is a perceptual judgement |
| **G4** same numbers | differential old-vs-new green on three engines over the **enumerated** corpus | the corpus is a bounded sample of a very large space — the word *enumerated* is load-bearing |
| **G5** visibility invariants | the multi-actor suite; monotonicity property; one test per historical visibility fix | the property is one-sided and must be paired with a strict-inequality case |
| **G6** typed failure | failure fixtures; no attachment, no journal, no bytes; `rescue Exception` absent | — |
| **G7** install ≈3 commands | install test on a bare image executing **only** the README's tagged block; diagnostics returns structured output with every check true; **every diagnostics check has a remediation string**; every starter template lints clean and renders on every engine; the drop reference matches runtime in both directions | R9 beyond install is now specified (`technical-spec.md` §9b) but its top criterion — *a first template without opening documentation* — stays a **3-participant walkthrough: advisory — non-deterministic — not a correctness guarantee** |

**R7 ("fast, efficient, good-looking") is converted rather than accepted as written**, because
no performance target has been given:

- *Relative:* p95 render time per reference template at stated issue counts is no worse than a
  baseline measured on v0.5.0 **before** the aggregator is touched, within a stated tolerance.
  The tolerance is a curator decision, labelled as such.
- *Absolute, needing no target:* query count independent of issue count; zero issue-object
  instantiation for aggregate-only templates; bounded output regardless of input.
- *Human:* "good-looking" is a dated sign-off against a fixed checklist — the checklist is now
  written (`technical-spec.md` §9b.4: one shared type scale, table headers repeating, no orphan
  breaks in cards or chart blocks, palette shared between the Chart.js and SVG paths, accessible
  SVG). `[GAP]` remains on the **performance** side: no numeric target exists; inventing one here
  would be worse than naming its absence.

## Open questions carried from `04-risks.md`

1. **Usage data (R-15, ADR-004 follow-up 1).** Four production queries decide the Tier-3
   keep/drop. **Three separate claims discriminate on this one unrun measurement**, so the
   subset scope in this spec is *provisional*, not settled.
2. **OQ-3 / OQ-4** — is an external service acceptable in the target deployments, and how does
   the renderer obtain assets? These determine the asset model, and therefore what the
   asset-resolution acceptance test even expects.
3. **OQ-6** — Redmine 5.1 in or out, and the language floor. Decide together; it removes a
   bespoke CI check and unlocks the newer template engine.
4. **OQ-8** — the performance baseline, which must be measured before the aggregator changes.
5. **OQ-10** — is the newer Liquid version actually *needed*? The independence decision stands
   regardless, but nothing has yet named a required feature.
6. **OQ-11 / OQ-12 (C-011, C-012)** — ADR-004 proceeds with "Liquid as the template language"
   and "one plugin" **as given**. Both remain open claims: the most severe security finding is a
   direct consequence of the first, and the second causes the parity-vs-independence
   contradiction the analysis flagged. This spec implements the decision; it does not claim the
   questions are settled.
7. **Retention of generated documents.** Generated PDFs are frozen snapshots that
   correction and erasure never reach. No retention model has an owner yet.
