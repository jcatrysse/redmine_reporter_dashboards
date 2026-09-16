# Reference — source inventory of the two existing plugins

> Captured 2026-08-04 by direct read of both repositories at the commits below.
> This file exists so the analysis stays grounded after the working clones are gone.
> **Read-only observation. No judgement here** — judgement belongs in `02`/`04`.

| Repo | Commit read | Version declared | LOC, code-ish | LOC, all tracked files | Files |
|------|-------------|------------------|---------------|------------------------|-------|
| `jcatrysse/redmine_reporter` (fork of RedmineUP PRO) | `b1d1736` | `2.0.5` | **5 775** | **6 287** | 126 |
| `jcatrysse/redmine_reporter_dashboards` | `eddb8fa` | `0.5.0` | **19 997** | **21 140** | 92 |

> **Reconciliation (added 2026-08-04).** Two figure sets circulate in this dossier and
> **both are correct — they differ only in scope.** "code-ish" counts
> `*.rb *.erb *.js *.liquid *.md *.yml`; "all tracked files" counts everything
> `git ls-files` reports. Cite the scope whenever quoting a figure. Verified by
> re-measurement, not reconciled by preference.
>
> **Test counts, same discipline:** the addon has **884** RSpec examples + **105**
> Minitest tests = **989 addon tests**; the base plugin adds **172** Minitest tests, for
> **1 161 combined**. So "989" (addon only), "884" (addon RSpec only) and "1 161"
> (combined) are all valid and refer to different sets — a figure quoted without its scope
> is ambiguous, which is how three numbers for "the tests" ended up in circulation.

---

## 1. `redmine_reporter` (the base plugin) — what it is

`init.rb` self-describes as **`name 'Redmine Reporter plugin (PRO version)'`,
`author 'RedmineUP'`, `url https://www.redmineup.com/pages/plugins/reporter`**
[CITE: redmine_reporter/init.rb:8-13]. `doc/CHANGELOG` runs 2011 → **v2.0.5,
2025-03-03** ("Added svg icons for compatibility with Redmine 6")
[CITE: redmine_reporter/doc/CHANGELOG:1-13].

### Licence facts — read them precisely, they are not uniform

> **Correction (2026-08-04):** an earlier revision of this file summarised this as
> "GPL-3 headers" and described the `redmineup` gem as "proprietary". Both were
> imprecise. The record is as follows, and it is **internally inconsistent** — that
> inconsistency is itself the finding. Full legal reasoning belongs to the
> legal-regulatory reviewer; this section records only what the files say.

| Artefact | What it actually says |
|---|---|
| `doc/COPYING` | **GNU GPL version 2**, verbatim [CITE: redmine_reporter/doc/COPYING:1-2] |
| `doc/LICENSE` | A **RedmineUP EULA**. "All Redmine Extensions produced by RedmineUP are released under the GNU General Public License, **version 2**… Specifically, the **Ruby code portions** are distributed under the GPL license." |
| `doc/LICENSE`, same paragraph | "If not otherwise stated, all **images, manuals, cascading style sheets, and included JavaScript are NOT GPL**, and are released under the **RedmineUP Proprietary Use License v1.0**… may not be redistributed or repackaged" |
| `extra/version.rb` | Stamps a **GPL-3** header ("either version 3 of the License, or (at your option) any later version") onto every `.rb` at release time [CITE: redmine_reporter/extra/version.rb] |
| `redmineup` gem | **Public on RubyGems, licence `GPL-2.0`**, latest **1.1.12** (4.29M downloads) [CITE: https://rubygems.org/api/v1/gems/redmineup.json, fetched 2026-08-04] |

Three consequences worth carrying forward, stated as observations:

1. **GPL-2 (`doc/COPYING`, EULA, gem) vs GPL-3 (the stamped `.rb` headers) is a
   genuine contradiction in the shipped artefact.** Redmine itself is GPL-2, which is
   why the distinction is not academic.
2. **The split is by file type, not by file.** Ruby code is GPL'd; the plugin's
   `assets/stylesheets/redmine_reporter.css`, `assets/javascripts/redmine_reporter.js`,
   `assets/images/*.png` and `assets/images/icons.svg` fall in the class the EULA
   marks **non-redistributable**. A "combine everything into one plugin" plan touches
   those files differently from the Ruby.
3. **The `redmineup` gem is *not* the closed component.** It is publicly installable
   and GPL-2.0-declared. So "own drops" (R6) is **not** forced by the gem's
   availability. *(Updated 2026-08-04: it **is** forced by two other things established
   since — the gemspec pins `liquid > 4.0, < 5.0`, so the gem is what keeps Liquid 5
   unreachable [CITE: reference/redmineup-gem-drop-surface.md]; and the author has since
   decided on independence from the gem outright [CITE: 00-idea.md curator statement]. The
   `[OQ]` this line opened is therefore closed.)*

### Declared dependencies

- `requires_redmine version_or_higher: '4.0'` [CITE: redmine_reporter/init.rb:17]
- `requires_redmineup version_or_higher: '1.0.10'` — hard dependency on the
  **`redmineup` gem**, checked at the very first line of `init.rb`
  [CITE: redmine_reporter/init.rb:1]
- `Gemfile`: `redmineup`, **`wicked_pdf ~> 1.1.0`**, **`wkhtmltopdf-binary`**
  [CITE: redmine_reporter/Gemfile]
- `require 'redmineup/patches/compatibility_patch'` [CITE: redmine_reporter/init.rb:40]
- `require 'zip'` for multi-report bundles [CITE: redmine_reporter/lib/redmine_reporter.rb:1]

**How scheduled reports actually fire:** there is no in-app scheduler. A rake task
`redmine:plugins:reporter:schedule` iterates `ReportSchedule.actual_for_today` inside
`Mailer.with_synched_deliveries` and calls `ReportScheduleMailer` per row
[CITE: redmine_reporter/lib/tasks/resources.rake:12-18]. So the feature depends on an
**external cron entry the operator must create**, and nothing in the plugin states
that. Running it twice in a day sends twice; not running it skips that day silently.

The Liquid drops **inherit from the gem**, not from plugin code:
`class IssuesDrop < ::Redmineup::Liquid::IssuesDrop`,
`class IssueDrop < ::Redmineup::Liquid::IssueDrop`, plus
`Redmineup::Liquid::UserDrop`, `UsersDrop`, `AttachmentDrop`
[CITE: redmine_reporter/lib/redmine_reporter/liquid/drops/issues_drop.rb:4,21,88;
.../attachment_images_drop.rb:40]. So the drop *vocabulary a template depends on* is
largely defined inside the `redmineup` gem, outside this repository.

### Feature surface (what a rewrite must match or beat)

| Area | Where |
|------|-------|
| Template CRUD + YAML import/export + preview + orientation | `report_templates_controller.rb`, `app/models/report_template.rb` |
| Three template types: `IssueReportTemplate` (one PDF per issue), `IssueListReportTemplate` (one PDF for a set), `TimeEntriesReportTemplate` | `ReportTemplate.available_types` [CITE: .../report_template.rb:28-30] |
| Liquid rendering + PDF via wicked_pdf/wkhtmltopdf | `app/models/report.rb` |
| Scheduled reports by e-mail (daily/weekly/monthly/quarterly/yearly) | `report_schedule.rb`, `report_schedule_mailer.rb` |
| Ad-hoc "send issue report by mail" | `issue_mails_controller.rb` |
| My-page report widgets | `my_page_patch.rb`, `app/views/my/blocks/*` |
| Context-menu + issue-view entry points | `hooks/views_context_menus_hook.rb`, `hooks/view_issues_hook.rb` |
| Public (token) links to reports + public attachment URLs | `RedmineReporter.token`, `reporter_attachment_images_controller.rb` |
| Custom Liquid filters: `sum avg median max min sort duration where_custom_field group_by_custom_field with_formatting file_url` | `lib/redmine_reporter/liquid/filters.rb` |
| ZIP bundling of many reports | `RedmineReporter.build_zip` |
| 9 locales (de, en, es, hu, it, pl, pt-BR, ru, zh) | `config/locales/` |
| 3 migrations only | `db/migrate/001..003` |

### Observed implementation properties (verbatim, no judgement)

- **PDF engine is hard-wired.** `Report#to_pdf` instantiates `WickedPdf.new` directly
  and reads `Redmine::Configuration['wkhtmltopdf_exe_path']`; page size `A4`,
  fixed 20mm margins, footer `[page]/[topage]`, and
  `lowquality: wicked_pdf.binary_version.to_s == "0.12.4"`
  [CITE: redmine_reporter/app/models/report.rb:12-25]. There is **no engine
  abstraction, no configuration hook, and no other backend**.
- **Errors become the document.** `to_pdf` ends `rescue Exception => e; e.message`
  — the failure text is returned in place of PDF bytes
  [CITE: .../report.rb:26-27]. Both `liquidize` methods do the same:
  `rescue => e; e.message` returns the exception string as the rendered report body
  [CITE: .../issue_list_report_template.rb:26-27; .../issue_report_template.rb:41-42].
- **`rescue Exception`** (not `StandardError`) also wraps `ReportTemplate.import`
  [CITE: .../report_template.rb:43-44].
- **YAML import** uses `YAML.load_file(file)` then `attributes['type'].constantize`
  [CITE: .../report_template.rb:33-34].
- **Public-link token is `Digest::MD5.hexdigest("#{str}:#{secret}")`** over
  concatenated object ids + template ids, with no expiry and no per-use scoping
  [CITE: redmine_reporter/lib/redmine_reporter.rb:15-20].
- **Absolute-URL rewriting** for `<img src>` / `<a href>` is done by Nokogiri when
  available and by **regexp on the raw HTML otherwise**
  [CITE: .../report.rb:59-96] — needed because wkhtmltopdf fetches assets over HTTP.
- **Rails 8 blocker:** `enum orientation: [ORIENTATION_PORTAIT, ORIENTATION_LANDSCAPE]`
  — the keyword form, removed in Rails 8
  [CITE: .../report_template.rb:26]. Note also the misspelled constant
  `ORIENTATION_PORTAIT`, which is part of the public-ish surface.
- **Liquid is rendered then marked `.html_safe`** with no resource limits set on
  `Liquid::Template.parse` [CITE: .../issue_list_report_template.rb:25].
- CI (`.gitlab-ci.yml`) targets RedmineUP's own private runner image
  `registry.redminecrm.com/docker/redmineup_ci`, matrixed over Redmine
  **4.0 / 4.2 / 5.0 / 5.1 / trunk** and Ruby **2.3.8 → 3.2.2**
  [CITE: redmine_reporter/.gitlab-ci.yml]. It cannot run outside RedmineUP.
- Tests are Minitest: 6 functional, 1 integration, 9 unit files.

---

## 2. `redmine_reporter_dashboards` (the addon) — what it is

`requires_redmine version_or_higher: '5.1'` **and**
`requires_redmine_plugin :redmine_reporter, version_or_higher: '2.0.5'`; `init.rb`
raises outright when reporter is absent
[CITE: redmine_reporter_dashboards/init.rb:14-18,38-40]. Patch + Liquid-tag loading
is deferred to an `after_plugins_loaded` hook listener, with each `register_*`
rescuing its own errors so tag registration cannot be lost to an unrelated failure
[CITE: .../init.rb:66-84].

### Capability surface

| Capability | Where | Size |
|---|---|---|
| Per-project dashboard pages with tabs, row layout, up/down/left/right block moves (no drag-drop; works on RM5 and RM6) | `project_page.rb`, `row_layout.rb`, `reporter_project_pages_controller.rb` | 70 + 142 + 215 |
| Typed/bounded widget settings (two-tier sanitisation, 64 KB column cap) | `block_settings.rb` | 233 |
| `{% sql_aggregate %}` — time series, categorical breakdown, crosstab, measures, flags, completeness, age buckets, drill-through | `liquid_aggregate_tag.rb` + `query_aggregator.rb` | 536 + **2 194** |
| Drill-through URL construction with graceful degradation under a length cap | `drill_through.rb` | 580 |
| `{% version_rollup %}` — one SQL row per target version incl. summed numeric CFs | `liquid_version_rollup_tag.rb` | 117 |
| `{% geo_version_map %}` — version name → id/metadata lookup | `version_mapping/liquid_version_map_tag.rb` | 144 |
| `VersionDrop`, `CustomFieldValueDrop`, issue-drop `target_version` patch | `liquid/*.rb` | 108 + 32 + 43 |
| Scope resolution from a Liquid drop / `query_id` to an AR scope | `scope_resolution.rb` | 303 |
| `/sql_stats` JSON endpoint | `sql_stats_controller.rb` | 40 |
| **wkhtmltopdf ES5 polyfill injection** + chart-wait handshake | `pdf_polyfills.rb`, `report_patch.rb` | 61 |
| Lazy-scope patch avoiding materialising all `Issue` objects | `reporter_report_content_patch.rb` | 35 |

### Observed implementation properties

- **The addon exists partly to work around the base plugin.**
  `pdf_polyfills.rb` injects hand-written ES5.1/ES2015 shims
  (`Function.prototype.bind`, `requestAnimationFrame`, `Object.assign`,
  `Array#find/findIndex/fill/includes`, `Array.from`, `Number.isNaN/isFinite/isInteger`,
  `Math.sign/log10`, `String#startsWith/includes/repeat`) because "wkhtmltopdf renders
  with a very old QtWebKit (AppleWebKit 534.x, ~2011)" and Chart.js 2.8 throws
  without them [CITE: .../pdf_polyfills.rb:6-15]. Injection is gated on the HTML
  containing a `<canvas>` [CITE: .../pdf_polyfills.rb:45-47].
- **`reporter_report_content_patch`** overrides reporter's `report_content` to pass
  `IssueQuery#base_scope` instead of `@query.issues`, so a `{% sql_aggregate %}`-only
  template loads **no** `Issue` objects; it falls through to `super` on any exception
  [CITE: .../reporter_report_content_patch.rb:17-34].
- **Redmine 7.0 is blocked on the base plugin, not on the addon.** Merely referencing
  reporter's `ReportTemplate` raises on Rails 8.1
  (`ArgumentError: wrong number of arguments (given 0, expected 1..2)` at
  `report_template.rb:26`). The addon deliberately does **not** patch it — "reporter is
  a third-party plugin, and carrying a patch for it would have to be re-applied at
  every reporter upgrade" — and instead degrades: the two report widgets show a
  placeholder, PDF export answers a clean error, and the touching functional tests
  **skip** on 7.0 [CITE: redmine_reporter_dashboards/README.md, "Redmine 7.0" section].
- **Database support is explicit and narrow:** PostgreSQL / MySQL / MariaDB only; the
  aggregation tags "refuse to guess" at date formatting elsewhere — **SQLite is not
  supported** [CITE: .../README.md, Requirements]. One documented limitation:
  `group_by: age` fails on MariaDB with `ONLY_FULL_GROUP_BY` because a `CASE` in the
  select list is not matched to the `CASE` in `GROUP BY`.
- **Viewer-relative numbers are a documented design decision**, not an accident:
  aggregation runs through `Issue.visible` → `User.current`, so two viewers can
  legitimately see different totals; the README argues the alternative leaks and
  recommends a one-off PDF when one shared number is required
  [CITE: .../README.md, "Who sees what"].
- **Never-raise discipline throughout the tags:** an unusable dimension, an invalid
  enum-ish value, a failed drill-through, an oversized crosstab — each logs one line
  and yields an empty-safe result rather than taking down a dashboard or a PDF export
  [CITE: .../README.md; `liquid_aggregate_tag.rb` logging sites].
- **Caps are explicit:** `MAX_DIMENSION_KEYS = 200`, `MAX_AGE_BUCKETS = 24`,
  `MAX_COMPLETENESS_FIELDS = 12`, per-period caps 90/52/24/10, `drill_max_url` 2000
  [CITE: .../query_aggregator.rb:139,148,210; README parameter table].
- **`0.5.0` was largely a security release** — five separate visibility leaks fixed
  (`/sql_stats` aggregating over `Issue.where(project_id:)` instead of
  `Issue.visible`; `query_id:` resolved with a bare `find_by`; `{% geo_version_map %}`
  built from `Version.all`; unbounded YAML-serialised widget settings; report template
  resolved outside the picker's scope) plus "a page view no longer writes to the
  database" [CITE: redmine_reporter_dashboards/CHANGELOG.md, 0.5.0].

### CI — this is the addon's strongest asset

`.github/workflows/ci.yml` runs on every push and PR, split so that fork PRs are not
red [CITE: .../.github/workflows/ci.yml]:

| Job | What it proves | Matrix |
|---|---|---|
| `rspec` | plugin specs, Redmine stubbed away, no DB, no reporter needed | Redmine 5.1 / 6.0 / 6.1 / **7.0**-stable × Ruby 3.2 / 3.3 / 3.4 / 3.4 |
| `adapter` | the aggregator's **real SQL against a real server** | PostgreSQL 16, MySQL 8.0, MariaDB 11 |
| `minitest` | full-app functional tests | same 4 Redmine branches — **gated on `secrets.REPORTER_REPO_TOKEN`**, skipped on fork PRs |
| `ruby-floor` | code stays inside Ruby 2.7 syntax (Redmine 5.1's floor) | `.codex/check_ruby_floor.sh` |

The support matrix is stated as *"Supported means: exercised by CI on every push and
pull request"* — and the plugin declines to claim Redmine 5.0 or earlier because it
does not test them.

**The `minitest` gating is the dependency made visible in CI:** the functional tests
need the **private** `redmine_reporter` checkout, so a token was introduced purely to
reach it, and outside contributors cannot run that job at all.

---

## 3. The two Liquid templates kept alongside this file

| File | Origin | What it demonstrates |
|---|---|---|
| `example-template-version-status.liquid` | verbatim copy of `redmine_reporter_dashboards/examples/version_status_dashboard.liquid` (577 lines) | `{% version_rollup %}`, per-version cards, KPI row, 2–3 Chart.js charts, optional cost via two numeric CF ids, schedule/budget badges |
| `example-template-sample-report.liquid` | verbatim copy of the repo's `examples/sample_report_template.liquid` (170 lines) | the smaller `{% sql_aggregate %}` starting point |

The user additionally supplied an **LL-01 "lessons by department × lesson type"**
widget template in the request (diverging stacked bar, `{% sql_aggregate %}` with
`split_by`, `drill: true`, cell-level URLs). It is not in either repo.

**What all three have in common, and what it costs (observation):** every one of them
carries a large inline `<style>` + `<script>` preamble whose comments state, in the
templates' own words, that the layout uses **floats and `inline-block`, not flexbox**,
because "the PDF export runs through wkhtmltopdf's WebKit (~2011), which has no
flexbox, so a flex layout collapses into a single column in the PDF"; that charts must
use `responsive: false` with an explicitly sized canvas because "wkhtmltopdf's old
WebKit fires no resize events, so Chart.js `responsive: true` reads a container width
of 0 and draws nothing"; that a `setLineDash` patch is needed for old QtWebKit builds;
and that Chart.js is loaded **from `cdnjs.cloudflare.com`** by default
(`GEO_CHARTJS_SRC`), with a comment recommending a local plugin asset "for PDF
stability" [CITE: `example-template-version-status.liquid` header comments and inline
`<script>`; identical preamble in the user-supplied LL-01 template].

They also hand-roll a **`window.status` "loading"/"done" handshake**
(`geoChartBegin` / `geoChartEnd` / `__geoChartsPending`) for wkhtmltopdf's
`--window-status` flag, and Chart.js is pinned at **2.8.0** (2019).

So the engine constraint has propagated out of the plugin and **into every template a
report author writes** — the templates are the third place, after the base plugin and
the addon's polyfills, where wkhtmltopdf's age is paid for.
