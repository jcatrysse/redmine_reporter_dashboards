# Implementation plan — standalone `redmine_reporter_dashboards`

- **Idea:** 004-redmine-reporter-modern · **Decision:** **ADR-004**
- **Specs:** [`functional-spec.md`](./functional-spec.md) · [`technical-spec.md`](./technical-spec.md) · **Phasing:** [`07-phasing.md`](./07-phasing.md)
- **This is the handoff point.** Writing the code is a separate, explicit step outside this
  workflow. Everything below is a task breakdown, not an implementation.

## How to use this document

Tasks are `T-nn`, grouped by the phase they belong to, ordered so that **every task leaves the
plugin releasable**. Each carries: goal, components touched, dependencies, and **acceptance
criteria that can fail**. Task-level Definition of Done in §5 applies to all of them.

**Read `technical-spec.md` §0 first.** The coupling inventory found 18 sites, not 6, and two of
them — `up_acts_as_list` (C3) and the *second* tag including `ScopeResolution` (C16) — are
load-bearing for the first release and were missing from earlier lists.

**Before starting: five readiness items.** Not bureaucracy — each one is a thing that becomes
impossible or much more expensive later.

> **Who does these, restated 2026-08-04 because it was unclear and that was a drafting failure, not
> a reader's.** Nothing here is homework the curator must finish before work may begin. **DoR-1, 2
> and 3 *are* tasks T-02, T-01 and T-03** — the first three things Claude Code does. They appear as
> readiness items only because of their *ordering*: each one measures something that stops being
> measurable once later code lands, so they must be **first**, not **prior**. **DoR-4 is answered**
> (OQ-3/OQ-4 closed by curator decision 2026-08-04 — `technical-spec.md` §5.1/§5.2). **DoR-5 is now
> specified** in §5's capability vocabulary plus §5.1's three models, so it is a schema to write in
> T-12, not a decision to take. **Net: zero open human prerequisites.** The one thing still worth a
> human minute is the *tolerance* on the p95 comparison (a curator decision, labelled as such in
> `functional-spec.md`), and it is not needed until T-03 has produced a number to set it against.

| # | Item | Why it must precede code |
|---|---|---|
| DoR-1 | Run the four production queries (`SELECT type, count(*) FROM report_templates GROUP BY type`; active `report_schedules` count; a `content LIKE` sweep per drop accessor; a log grep for `/issue_mails` and `?token=`) | Three claims (A5, C-002, C-007) discriminate on this **one** measurement. The subset scope is provisional until it runs. Ships as T-02's `import:plan`, so it is repeatable rather than a one-off |
| DoR-2 | Freeze the goldens + the scope fixture (T-01) | The scope is unrecoverable once `scope_resolution.rb` is deleted |
| DoR-3 | Measure the performance baseline on v0.5.0 | Cannot be measured after the aggregator changes |
| ~~DoR-4~~ | ~~Answer OQ-3/OQ-4~~ — **ANSWERED 2026-08-04.** External container: yes, *as one option*, documented and safe → third CI-verified adapter, default unchanged (T-34). Assets: fetch external references, ship local ones with the request → three models + `asset_policy`, `:bundled` default, allowlist-only above (T-33) | it determined what the asset-resolution test expects; it now does |
| ~~DoR-5~~ | ~~Agree the engine `capabilities.yml` schema~~ — **SPECIFIED**: the closed capability vocabulary in `technical-spec.md` §5 plus the three asset models in §5.1. Written as a file in T-12, no longer a decision | the three-state conformance rule now has something to read |

## Status — what has landed

Kept here so a fresh session can read it rather than reconstruct it. `git log --oneline` is still
the authority; this is a summary, and CLAUDE.md §1 says to verify it.

**Read [`HANDOVER.md`](./HANDOVER.md) alongside this table.** It carries what this table cannot: the
traps that produce a green run meaning nothing, the code that looks like a violation and must be left
alone, and — most importantly — **which configurations have actually been executed**, including the
fact that CI has not yet run on this work at all.

| Task | State |
|---|---|
| T-00 | **VOID** — the fork is out of scope (curator, 2026-08-05). See below. |
| T-01 | **done** — reference date, canonicaliser, baseline commit, the 176-case value corpus, the per-adapter overlay, the 46-triple scope fixture and the `corpus` CI job. **It found defect D-1 on the way in** — see §Findings |
| T-02 | **done** — `rake reporter_dashboards:migrate_from_reporter:plan`, read-only (proven by a no-writes assertion, not by a comment), plus the template linter's first 13 rules. Three of R-15's four queries answered; the fourth is a log grep and is reported as unanswerable **with the command**. It found the G8 tension in §Findings F-3 |
| T-03 | **partly done** — the aggregation baseline is measured and committed (9 workloads × 3 issue counts, 20 warm runs, provenance-stamped) and R7's three *absolute* criteria are now hard assertions on every engine. **The HTML\|PDF half is still unmeasured — but its recorded blocker was FALSE and is now corrected (2026-08-10).** Both of P-2's premises fell: the renderer exists (`ReportRun#call(pdf:)`), and `:chromium_cdp` passes its whole 20-fixture conformance corpus in-container — **20/0/0** — once it is not run as ROOT, which is why it looked unavailable for five sessions. The 12 cells said `owed_by: T-10` for four tasks after T-10 went green; they now name **T-03** and a reason that is true, and two new assertions in `performance_spec.rb` stop either drifting again. What is actually owed is a harness in the BOOTED-Redmine environment: `spec/adapter/` is a synthetic schema with stub models by design, and `ReportRun` needs real templates, users and permissions — see §Findings P-2 |
| T-04 | **done** — `RedmineReporterDashboards::Positioned` replaces `up_acts_as_list` |
| T-05 | **done** — reporter optional; `ReporterPresence`, memoised at `after_plugins_loaded` |
| T-06 | **done** — widgets leave the picker, degrade in place, `report_pdf` 404s |
| T-07 | **done** — `Liquid::ScopeBinding` (two sources) + `Liquid::RenderContext` (an actor is required to construct one); `ScopeResolution` and the thread-local's owner demoted to `glue/legacy/`; new `no_thread_local` gate. **The scope fixture and all 176 corpus cases are byte-identical** |
| T-08 | **done** — both kernel files moved to `aggregation/`, plus the 4-line namespace assignment; `drill_through.rb` is byte-identical to its v0.5.0 blob and `query_aggregator.rb` is that blob **plus exactly ONE declared hunk**, which is D-1's fix. G7 gained the mechanism that can say so (`spec/golden/kernel_exception.rb`, `RATCHET = 1`); the per-adapter overlay is **empty again, `RATCHET = 0`**. **Verified on all three engines by CI run 31036305443 — 17/17 green**, `adapter (MariaDB 11)` included |
| T-09 | **done** — the secret, the probe job and the private checkout were removed earlier (which is what let 5.1 run at all and exposed D-2/D-3); this session added the two gates its `Accept:` list still named, `layer_purity.sh` (E3) and `compat_size.sh` (E4), and moved the one scattered version check into `Compat`. **One item is a human artefact and is NOT done: the dated fork-PR run per release** — see §Findings F-5 |
| T-21 | **done** — `test/unit/multi_actor_visibility_test.rb`: five actors (`all`/`default`/`own`, an outsider, anonymous) over a private project with a private issue, a role-restricted custom field and a private `IssueQuery`; exact totals AND strict inequality; the restricted field's NAME asserted absent from every entry point, not just its values; the two fail-closed `1=0` branches as DB-less unit tests; ordering in both directions plus A/B/A; the monotonicity property with both its limits written into the file. **Mutation-tested**: dropping `Issue.visible` from the scope fails 4 of its 13 tests |
| T-10 | **done** — `render/{capabilities,page_furniture,failure,result,document_request,registry,renderer}.rb`: a frozen `DocumentRequest` with **no field a credential could travel in** (asserted against the constructor's signature, so a future `headers:` has to be argued), `print_backgrounds` defaulting to `true` rather than to Chromium's `false`, `PageFurniture` as slots plus a closed token set, `Result = Success \| Failure` with closed code sets, and `Renderer` enforcing the `%PDF-`/`%%EOF` and minimum-size post-conditions **above every adapter**. 29 DB-less examples; `layer_purity` flipped to **strict** in the same PR, as its own comment asked |
| T-11 | **done** — `render/readiness.rb` and `assets/javascripts/chart_shell.js`: one DOM contract (`window.__rd` with `pending/ready/begin/end/fail`, plus `data-rd-ready` and `window.status`, all set at the same instant), an in-page watchdog firing BEFORE the engine timeout, `Degradation(:readiness_timeout, pending: n)` unless `strict`, and `begin`/`end` owned by the shell. The JS is **executed in node**, not mocked. **F-7 IS CLOSED**: the wall-clock falsifier runs through the real Chromium adapter as conformance fixture `F-13`, 3 of 3 attempts inside 5.9–12 s with the post-readiness marker present, alongside five more (`F-08`…`F-12`) covering the chart-free case, three finishing charts, the page watchdog, the engine timeout and `strict` |
| T-12 | **done** — `spec/conformance/`: 20 fixtures, the harness that applies the three-state rule (G12), the generator that turns a run into `docs/engine-support-matrix.md` (G9), `config/capabilities.yml` (DoR-5) with `Render::EngineCatalogue` validating it, and the `render-smoke` CI job. **Negative-tested**: 23 DB-less examples drive the harness with engines that decline capabilities, that DECLARE one and do not deliver it, that return bytes which are not a PDF, and that raise. Probes are `pdfinfo`/`pdftotext`/`pdftoppm`, and a missing one is an ERROR rather than a skip |
| T-13 | **done, both engines — `:wkhtmltopdf` promoted to `corpus` 2026-08-06** — `render/engines/{cdp_client,chromium_cdp,wkhtmltopdf}.rb` and `render/process_pool.rb`; `pdf_polyfills.rb` → `glue/legacy/wk_legacy_shims.rb` with the payload asserted byte-identical. CDP over a **pipe, not a port**; `--no-sandbox` never set (so the browser itself enforces non-root); pool of 1 with a bounded queue answering `Failure(:engine_unavailable)`. **20 of 20 conformance fixtures green on Chromium 141.** wkhtmltopdf was registered and **had never been executed** when this row was written — its package is gone from Ubuntu 24.04 — so it stayed `verification: pending` and the matrix printed "not verified" rather than cells nobody measured. **It has since run and was PROMOTED to `verification: corpus` on 2026-08-06**: 18 PASS / 0 FAIL / 2 SKIP on the patched-Qt build, both skips naming an undeclared capability, matrix regenerated from that run (~~E-5~~, E-18). **The corpus found three defects on its first run** — see §Findings E-2, E-3, E-4 |
| T-15 | **done as of T-29, 2026-08-09 — the last of §Findings E-6's three owed bullets is paid.** This row read "partly done" because T-15's `Accept:` was written for an HTTP entry point that did not exist when it landed. T-23 paid the first two (a 422 naming the cap, and `assert_no_difference` on `Attachment.count`/`Journal.count`); T-29 paid the third, the streamed archive with no `Content-Length`, and deleted the 501 that stood in for it. What T-15 originally built and still owns: `render/batch_guard.rb` plus `spec/render/chromium_containment_spec.rb`. The cap OWNS the render loop rather than sitting beside it, so "refuse before any render" is a property of the object and not of the caller's discipline; asserted with a double that counts calls (**zero** over the cap), at the cap and one past it. Batch deadline keeps what is finished and refuses the rest, typed, with each undrawn document's own correlation id. Against a real browser: a wedged renderer times out bounded-and-monotonic **and the browser is gone from the process table**, the next render is served from a fresh one, shutdown leaves nothing behind, and concurrency never exceeds one browser. **Two Accept items are blocked on an entry point that does not exist** — see §Findings E-6 |
| T-17 | **done** — `liquid/{execution_policy,template_renderer}.rb` plus gate `single_parse.sh`. **Both mechanisms, because neither alone suffices**: per-CLASS resource limits (widget/report/preview, preview deliberately on the widget's numbers so an author feels the limit at the keyboard) handed to the `Liquid::Context` — the only per-render channel either Liquid 4 or 5 offers, verified on 4.0.4 and 5.13.0 — and a **cooperative monotonic deadline** wired into all three own tags, a no-op where no budget is bound. `Timeout.timeout` is not used and the file says why. **Errors never enter the document**: the spec first DEMONSTRATES Liquid's default of writing `Liquid error:` into the output, then shows the same template becoming a typed failure with no body at all. 36 examples against the real gem; the gate negative-tested |
| T-18 | **done** — the twelve drop classes, the three bases and `liquid/batch.rb`. §3.2's disposition table is implemented accessor by accessor and ASSERTED accessor by accessor: the names kept identical, the `closed_on` timezone defect fixed (all three timestamps now go through the actor, never `User.current`), the four scalars promoted to `NamedRefDrop` with their `*_id` escape hatches, `version` promoted to a string-substitutable `VersionDrop`, `url` absolute by construction, and the **fifteen dropped accessors** — six vendor probes, four OQ-H, five from the addon's own subclass — each pinned UNREACHABLE under `strict_variables` so the negative half cannot rot. `all` is reachable, refused and records `Degradation(:unbounded_collection)`; deleting it would render blank, which is the silent answer INV-4 forbids. **The gating criteria are measured, not argued**: zero `Issue` instantiations for an aggregate-only template at 10 AND 10 000 issues, identical query count across that span, one custom field across 400 issues in **4** queries and a second one for **free**, and the cap asserted AT it and one past it. **Visibility is in the batch, not in the drop**: `IssueCustomField.visible` plus Redmine's per-project `visible_by?`, `TimeEntry.visible`, `Issue.visible` — and the auditor case (holds the role in ANOTHER project) is the leak the four-actor fixture exists to catch. Green on Liquid **4.0.4 and 5.13.0** (185 examples each) and on PostgreSQL 16 (31 adapter examples); the corpus is byte-identical. **CI run 31085742725 is 18/18 green on the first try**, MySQL 8 and MariaDB 11 included, and all four `minitest` branches — which is what actually answers whether `liquid/drops/` boots under Zeitwerk on 5.1 through 7.0. **It found three defects in itself** — §Findings **E-12**, **E-13**, and the `is_closed` attribute sourced from the wrong row — and left two questions for the curator, **F-8** and **F-9** |
| T-14 | **done** — `render/preflight.rb`, `render/pdf_inspector.rb`, `render/preflight_command.rb`, plus the admin page (`ReporterPreflightController` + helper + view, `require_admin` **per action**) and `rake reporter_dashboards:render:preflight` **exiting 0/1/2** (2 = nothing was registered, so nothing was verified — deliberately not 0). Nine document checks, each a ROUND TRIP read back out of the PDF, `:expected_failure` a distinct state from `:fail` so the INV-8 containment result cannot be confused with a defect, and a missing `poppler-utils` a **skip naming the package** with `complete?` false and the headline never a bare OK. `spec/conformance/pdf_probe.rb` is now a **policy over `PdfInspector`**, not a second implementation — same mechanism, opposite policy (hard error there, skip here) — so the corpus and the operator's diagnostic cannot drift apart. **Negative-tested**: the canned single-page PDF drives every one of the six document checks red, one at a time. **Measured against real Chromium 141: 9/9 in 943 ms**, hosted image `expected_failure`. **It found nine defects in itself** — three on its first real run, five more in review, one in CI — including an `inline_asset` check that was a tautology and a missing poppler DELETING the INV-8 check rather than skipping it. See §Findings E-10 |
| T-19 | **done** — `liquid/filters.rb` + six registered modules, `liquid/html_scanner.rb`, four new lint rules, and the examples and README fixed. **21 owned filters**, registered PER RENDER (the default of `TemplateRenderer#render`, never `Template.register_filter`), with `OWNED`/`INHERITED`/`REMOVED`/`DEFERRED` as asserted constants so a security removal cannot come back as a convenience. **`| json` and `| js`** escape `< > & \ ' " ` $` and U+2028/9, in `\uXXXX` form so the output stays valid JSON for §6's `<script type="application/json">` block. **OQ-C is closed by measurement**: `where` and `sort_natural` inherited, `sum` owned for cross-major parity, and the `StandardFilters` name list **pinned per version so an unpinned Liquid fails the build**. The FR-19 lint now **parses** rather than regexes — `HtmlScanner` walks the document's states, and its spec is the argument: a commented-out script, a `>` inside an attribute, a `>` inside a Liquid expression and `<style>` were each answered wrongly before. **E-8's two rules shipped, which was the condition the curator's decision rested on**, plus a warning for `.all` and one error per removed filter carrying §3.6's reason. **The copy-paste surface is fixed and pinned**: both examples and all 25 README snippets are FR-19-clean, the frozen reference copies are asserted STILL defective because the verification cites them, and the other findings are held at a ratchet owned by T-16/T-11. The escaping regression table asserts the assembled block **PARSES** under node — 43 examples, because a "nothing executed" test would have passed the defect. Green on Liquid **4.0.4 and 5.13.0** (276 examples each), 1433 DB-less, 187 adapter, corpus byte-identical. **It found two defects in itself** (§Findings **E-14**) and left **F-10** for the curator |
| T-20 | **done** — `{% geo_version_map %}` is a **deprecation shim**: same behaviour, same map shape, one log line per process (locked, so once means once under Puma), and `Version.visible` was already the scope. The addon's `VersionDrop` (108), `issue_drop_patch.rb` (43) and `custom_field_value_drop.rb` (32) are **deleted**, `register_issue_target_version_drop` with them, and **two `zero_reporter.allowlist` entries went with the files** — the ratchet shrank 18 → 16 rather than going stale. The linter gained `deprecated.geo_version_map` as a **warning, not an error**: the template still works, and `import:plan`'s "which templates need rework" is `errors.any?`. It also gained a counted usage marker, because the finding says *this breaks next minor* and the count says *this many templates must be touched first*. **It found two defects in itself and one gap in its own task definition** — §Findings **E-15** — and left **F-11** (the `issue.target_version` window before T-23) and **F-12** (`TagContext` reading `User.current`) for the curator. Green DB-less (1460, was 1433), Liquid **4.0.4 and 5.13.0** (278 each), and all six gates |
| T-16 | **done** — `charts/` (palette, spec, layout, SVG renderer, Chart.js emitter, collector), `liquid/tags/chart_tag.rb`, `assets/javascripts/chart_boot.js`, **Chart.js 4.5.0 vendored** with its digest in `THIRD_PARTY.md` and a `vendor_integrity` gate that recomputes it. `{% chart %}` **emits no markup** — a placeholder and a `ChartSpec`, and the output binding decides: `<canvas>` + `<script type="application/json">` for HTML, inline `<svg>` for PDF with `<a xlink:href>` per element and no JavaScript at all. **One `ChartLayout` for both paths**, and the claim is MEASURED rather than argued: the falsifier renders a horizontal bar with twelve long labels in a real Chromium and compares `chart.chartArea` with `ChartLayout#plot` — worst edge **1.17%** against T-16's 2% tolerance, with Chart.js using exactly the ticks, min and max it was handed. **It found two defects doing so** (§Findings **E-16**), neither findable in Ruby. Ten SVG goldens as deterministic text; `responsive`/`animation`/`devicePixelRatio` derived from the output binding, never from the author (G3). Left for the curator: **F-13** (where the chart layer lives), **F-14** (a `:responsive_canvas` capability), **F-15** (the two legacy examples' CDN reference) |
| T-33 | **done** — `assets/` (policy, origin, reference, content types, bundled assets, local store, fetcher, document scanner, resolver, resolution) plus `render/asset_binding.rb`, the plugin's first `settings` block and its admin partial, and two new `layer_purity` arms. **Its review found four blockers and they are fixed** — a stylesheet's own `url()`/`@import` reaching the engine live (which made the whole `:bundled` promise false), an `ArgumentError` out of a method documented never to raise, `<style/>` hiding an entire stylesheet from the scanner, and a production transport with no test at all. §Findings **E-17**. **`:bundled` is the default and `:asset_http` is never selected** — not "off wherever the engine supports upload", but off in every mode for every capability shape, asserted against an engine declaring all three. An **empty allowlist collapses any upgraded mode to `:bundled`** and the collapse is asserted as an equality of body, refusals, counts and models — the fail-closed clause T-33 flags as most likely to be got wrong. The fetcher's closed header set is proven by a **recording double**, not by reading the file; the resolved-IP check runs **after** DNS and the connection is made to the checked address via `ipaddr=`, which is the only version that closes the rebinding window; size, time, redirect and inline caps each have an AT-and-one-past test. Containment is `realpath`, tested against a literal `..`, a percent-encoded one, a **double**-encoded one and a **symlink** inside the root pointing out of it. **Structural inlining falls back to base64 on `</style` / `</script`**, which is an injection rather than a rendering bug. 201 new DB-less examples; **1768 total, 0 failures**; all seven gates green, `layer_purity` strict, and both new arms **negative-tested**. It settled **F-13, F-13b, F-14** and answered **F-15**, and left **F-16** and **T-39**. **F-16 IS NOW CLOSED (2026-08-09) — the layer is CALLED.** T-33 built the machinery and no producer, which is the same gap `RenderContext` and the drop layer each had; the difference is that this one shipped as a *promise about the output*, so a URL-referenced image drew blank in every report for four tasks and a commit message claimed otherwise (§Findings ~~S-28~~). `ReportRun` now resolves the engine FIRST, asks it for `#capabilities`, resolves each rendered body through `Assets::Resolver`, and binds the result with `Render::AssetBinding` — so a same-origin image is inlined off disk and anything unresolvable is a typed `Failure(:asset_unresolved)` **naming the URL** instead of a hole in the page. `Reporting::AttachmentMapper` is the `LocalStore#mappers` port T-33 specified and nothing implemented, gated on `Attachment#visible?(**the run's actor**)`. A fourth `Diagnostic` origin `:assets` exists because **no engine ran**. 21 mutations, 21 red, two of them survivors closed with new tests. What is still T-34's is `:asset_upload`: no shipped engine declares it, so `DocumentRequest#assets` remains empty by design |
| T-34 | **done** — `render/engines/gotenberg.rb`, `docker-compose.gotenberg.yml`, `.github/workflows/gotenberg-cve.yml`, a `render-network` arm on `layer_purity.sh`, and the Gotenberg leg of `render-smoke`. **The corpus is 19 pass / 0 fail / 1 skip** against `gotenberg/gotenberg:8@sha256:a16a14e1f18a…` (8.35.0), the skip being `F-14-asset-inline` for an `:asset_inline` this engine does not declare — G12's first arm, working. **F-16's remaining half is CLOSED**: `:asset_upload` is now declared AND delivered, so `DocumentRequest#assets` is consumed end to end and the proof is a PIXEL — a green plate that travelled in the multipart request is read back off the page, because bytes coming back proves nothing (the first version of that probe double-encoded the plate, succeeded, and drew a blank). **Three of the security checks were rewritten after measuring that they COULD NOT FAIL**: `/health` is exempt from Gotenberg's basic auth so a credential probe pointed there answers 200 either way; `waitForExpression` is SILENTLY IGNORED under `--chromium-disable-javascript`, so the readiness contract is void and every chart vanishes with nothing failing (the discriminator is a throwing script plus `failOnConsoleExceptions` — 409 versus 200); and a JS-probe timeout read as a pass. **The corpus caught a real defect no unit assertion could have**: `landscape` rotates whatever dimensions it is given, so swapping the page AND setting the flag produced a portrait page for every landscape report (F-03, `expected 841.89, got 595.92`). `#preflight` fails with a NAMED remediation both when no credential is configured and when one is and the endpoint answers anyway, and the failure is OBSERVED — against a real `TCPServer` in the DB-less suite and a real unauthenticated container in `render-smoke`. **Auto-detection was fixed rather than asserted**: the fallback was `Registry.ids.first`, i.e. alphabetical order, so "never selects `:gotenberg`" was true by luck and untestable; the declared `default:` in `capabilities.yml` is now read, and an engine that `needs_service` is never auto-selected. **30 mutations**, and the harness's own first control run found two environment-dependent tests (`credential: nil` fell through to `ENV`) and one order-dependent one. `verification` moved `documented` → **`pending`**, not `corpus`: the corpus had not been read in CI yet, and claiming otherwise is INV-7's exact sin — promotion is a curator decision on a CI run, exactly as wkhtmltopdf's was. **It happened on 2026-08-11: `verification: corpus`, matrix regenerated from a three-engine run** (E-27 row 1). §Findings **E-27** |
| T-35 | **done, re-scoped** — vendored Mermaid 11.16.1 (3.5 MB, digest in `THIRD_PARTY.md`, byte-identical across THREE independent origins), `liquid/tags/mermaid_tag.rb`, `assets/javascripts/mermaid_boot.js`, `:modern_javascript` in the closed vocabulary, and the regenerated support matrix. **No sanitiser, no `MermaidSpec`, no collector, no `:mermaid` capability** — §Findings F-17 is why, and the tag is 210 lines against `{% chart %}`'s 324 as a result. `{% mermaid %}` inherits `Liquid::Raw` so `B{Choice}` and `-->|yes|` survive; `interpolate: true` substitutes VALUES and escapes them, with no second `Template.parse` (the gate forbids one) and no `{% %}` execution. **The boot script is ES5 and that is load-bearing** — one arrow function and it dies at parse time on the very engine whose fallback it exists to produce, so it is asserted by a real ES5 parse plus 14 node-driven behaviour examples. **MEASURED end to end on both engines**: Chromium draws the diagram (labels present, source gone, interpolated value present, no degradations); wkhtmltopdf leaves the source visible and marks it unsupported. **Three cross-major defects found by running it under both Liquid majors** — §Findings **E-19** |
| T-40 | **done** — `lib/redmine_reporter_dashboards/permissions.rb`, `spec/permissions/permission_map_spec.rb` and `spec/permissions/registration_dsl_spec.rb`, closing `[OQ-F]` the way the curator decided on 2026-08-06: **the `template_authoring` setting is deleted, not defaulted**, and replaced by 13 role permissions in two project modules (`technical-spec.md` §4.1). Three are live and unchanged, and the loop that replaced their three literal `permission` calls is asserted **twice** — once as data, once by a committed recorder that mimics `Redmine::Plugin#project_module`'s `instance_eval` and receives the same three calls argument for argument. Ten are declared as **design and deliberately not registered**, because a permission an administrator can tick that guards nothing is a lie in the interface. **Its review found four blockers and a refuted claim, and all five are fixed** — §Findings **E-20**: the coverage gate could not see a controller in a subdirectory, `authorize` was asserted per controller so `only:` plus `skip_before_action` hollowed it out, `define_method` and a `def` inside a version conditional were invisible, the "no grant" glob never scanned `init.rb` at all, and **`:admins_only` is not a construction guarantee** — core's `DefaultData::Loader` gives Manager every setable permission on a fresh install. `require: :member` is now genuinely **derived** from `authoring: true` rather than typed and asserted to agree; coverage is **per action** and reads `config/routes.rb` too; the reader's answers about `only:`/`except:`/`skip_before_action`/`define_method`/nested `def` are asserted against **fixture controllers**, because the four real ones contain none of those constructs. 81 examples, **1933 total, 0 failures**, 92 pending (no new skips), all seven gates green, and **fourteen negative tests** — the four bypasses the review used, plus a deleted `before_action :authorize`, a missing locale label, an authoring entry that types `requires` instead of deriving it, a label for an unregistered permission, a mapped action that does not exist, a `lands_in` naming a task absent from the plan, and three against §4.1's table (a drifted name, a wrong task, and the heading gone — which must fail loudly rather than extract nothing). **The last of those found a hole in the fix itself**: `actions_guarded_by` returned `nil` for a guard that was *absent*, which reads as "covers every action", so DELETING `before_action :authorize` outright still passed the per-action check. Absent is now `[]` |
| T-22 + T-36 | **done, together, because CLAUDE.md §1 makes shipping them apart a refusal condition** — `db/migrate/002`…`007` (seven tables), six namespaced models under `app/models/redmine_reporter_dashboards/`, `Compat.column_present?`, gate `migration_reversibility.{rb,sh,allowlist}`, `script/migrate_updown.sh` + `script/schema_snapshot.rb`, the `migrate-updown` CI job, `spec/migrations/` (53 examples) and three `test/unit/` files (59 runs). **Both plugins can now be installed at once**, and that is not a slogan: `Object.const_defined?(:Document)` is already **true** on a stock Redmine, so the namespace is load-bearing. §7's security-motivated clauses are each asserted rather than commented — recipients are `user_id` only and **no table this plugin owns has a `to`/`cc`/`bcc`/`from` column**, `[schedule_id, occurrence_date]` is UNIQUE and proven by violating it, versions have no `updated_at` and are `readonly?` once persisted, a document cannot be created without an expiry. **T-36 is two halves that answer different questions**: the gate asks whether a reverse is DECLARED (it PARSES, because a regexp cannot tell `def down` from the word "down" in a comment explaining why there isn't one); `migrate_updown.sh` asks whether the reverse RESTORES the database, in two arms — the literal FR-69 assertion, and an honest statement of what a fresh install leaves behind. **Both were negative-tested before being trusted**: every one of the gate's eight rules has a committed fixture that fires it, and `migrate_updown.sh` was driven red by three plants including a down-migration that drops `reporter_project_tabs`. **Running it found three defects reading it did not** — a 64-character derived index name that aborts on PostgreSQL and would have SUCCEEDED on MySQL, a missing savepoint that let a refused occurrence claim poison the caller's transaction, and an RSpec constant leaking onto `Object` and breaking two of T-16's examples in the randomised full run while passing in isolation. **G11 is PASS on Rails 7.2 only**; 6.1 and 8.1 are the `migrate-updown` job's to answer. It raised **six spec findings, S-1…S-6**, none of them silently fixed |
| T-23 | **done** — `app/controllers/reporter_dashboards/templates_controller.rb` (the plugin's FIRST owned HTTP entry point, 11 actions), `lib/redmine_reporter_dashboards/reporting/{report_run,exchange,diagnostic}.rb`, five views + a helper, `Template.visible` / `#visible?` / `#editable_by?` / `#visibility_editable_by?`, `patches/role_patch.rb`, and **T-40's promotion of five permissions** with their action maps, their `lands_in` dropped and 42 keys × 9 locales. **Every layer built since T-07 acquires its first producer here**: `RenderContext` is constructed from a real actor, the drops from a real scope, `render/` from a real document and `BatchGuard` from a real batch. **`authorize` is per action AND is only the first half** — Redmine's `authorize` passes on ANY mapped permission, so `manage_public_…` (which must map `#create`, because that is where the visibility decision is) would otherwise reach a code-execution endpoint, and *"import requires `add_…` **and** `edit_…`"* is a conjunction the permission model cannot express at all; four second guards close both, and the functional suite holds each permission ALONE and asserts 403 on everything it must not reach. **T-15's two owed acceptance items are paid** (§Findings E-6): a **422 naming the count and the cap** against the SHIPPED default of 50, refused before one Liquid template is parsed and asserted with an `expects(:render).never`, and `assert_no_difference` on `Attachment.count` and `Journal.count` across both failure paths — recorded honestly as regression guards, since nothing on the path writes either today. **Its independent review found two blockers and eight majors and all ten are fixed** — §Findings **E-22** — the worst being that the rendered body was inlined into the viewer's page with no sandbox at all, which made an ordinary member's `<script>` run in an administrator's session. **Three more defects were found by the tests themselves**: the scope and the predicate disagreed for an administrator and again for Anonymous, and the archive refusal raised `NoMethodError` the moment a test stopped shadowing it. Closes **S-4** (prose) and **S-8** (the reciprocal `Role` HABTM, proven by destroying a role). 2042 DB-less examples, **340 minitest runs, 0 failures, 4 skips** (unchanged), all eight gates green plus G11 |
| T-25 | **done — and this row said "in progress, NOTHING DELIVERS YET" long after it stopped being true.** Corrected 2026-08-09 against `git log` and HANDOVER §5, which has recorded *"T-25 IS COMPLETE, AND ITS UI IS WHERE BOTH ESCALATIONS WERE"* since part 4 landed: `SchedulesController` (8 actions), five views, a helper, the mailer, the two rake tasks, FR-44's heartbeat and the two §4.1 permission rows promoted. CLAUDE.md §1 says to verify this table against `git log` rather than trust it, and this row is why. The increments, kept because the ORDER is the interesting part: (1) `lib/redmine_reporter_dashboards/scheduling/occurrences.rb` — the date arithmetic, pure, no clock: `today:` is a required argument, and a spec asserts the module's own source names no `Date.today`. Month CLAMPING is the whole reason it is not a day-number check (a "monthly" schedule started on the 31st that fires seven times a year is a defect an author finds in August), and `next_occurrence` asks the SAME `due_on?` the runner will, so `next_run_on` and the run can never disagree. (2) `scheduling/runner.rb` — the tick: FR-39's claim (an INSERT against the unique index, never a check-then-act), FR-40's bounded catch-up, FR-41's **two** rescues, FR-42's one render per occurrence, and FR-45's render identity, which **refuses** rather than falling back — an anonymous or locked identity renders an empty report that looks like a success. Pays **S-7's inherited obligation**: run state written with `update_columns`, asserted on the emitted SQL rather than on the row (see HANDOVER §1 — reading the row back cannot tell a narrow write from a full one). A DRAFT (`repeat` or `start_date` still nil) is recorded as `skipped` and does **not** make the tick exit non-zero: a non-zero exit that is always non-zero is one nobody reads. **Every guard was negative-tested, twice.** Ten before review (three examples were vacuous under mutation and were rewritten), then a fresh-subagent review **REJECTED** it with one blocker and five majors, each backed by a probe against the live checkout: the render policy fell through an open `else` to the author and reported success (FR-45, in code sitting eleven lines under a comment refusing exactly that); a raise in the outer rescue *body* escaped `#call` and embargoed every later schedule, which is FR-41 broken by the code written for it; the injected `schedules:` scope dropped the `enabled` filter; a westward timezone edit produced two `occurrence_date`s for one wall-clock day and walked `last_run_on` backwards; `next_run_on` was never refreshed for a schedule with nothing to do, so an ended one advertised a past date for ever; and a fourth vacuous example. All eight fixes landed and were themselves mutation-tested (14 mutations, 13 red); the one that stayed green was **deleted** rather than kept. Two comments that asserted something measurement contradicted were corrected, one of them in migration 004. (3) `reporting/scheduled_delivery.rb` + `ReporterDashboardsMailer` + `scheduling/{heartbeat,run_command}.rb` + two rake tasks + 7 keys x 9 locales — FR-42 (one render, N recipients), FR-43 (owner told, recipients told nothing, and the failure mailer has **nowhere to put an attachment**), FR-44 (both halves: the README's cron contract, and a heartbeat that derives rather than storing state), and §7b.5's server-controlled sender, which holds because no column and no argument could set one. **Its review REJECTED it too** — 1 blocker, 5 majors, 6 minors, 3 nits, all probe-backed, all fixed, 16 mutations red. (4) `SchedulesController` + 5 views + a helper + **T-40's promotion of the two schedule permissions**, with §4.1's rows marked live. **Its review was the third REJECT and the only one to find a privilege escalation — two, both reproduced end to end**: `render_as_user_id` was permitted and filtered against nothing, so an ordinary member could have a report rendered with ADMINISTRATOR visibility and mailed to themselves (measured against a private issue they could not see); and `#test_send` coupled FR-45's stored identity to delivery-to-the-presser, which needed no tampering at all. Eight majors, four visible on the first page an operator opens. All 16 findings fixed, 19 mutations red. **T-25 IS COMPLETE.** **One question is REPORTED AND NOT DECIDED** — see §Findings **S-10** |
| T-30 | **done** — `render/minimal_pdf.rb` (an engine-free PDF writer), `reporting/failure_document.rb` (the policy over it), migration 008's `failure_document` opt-in, `Diagnostic#template_name`, and 5 keys x 9 locales. **The failure document is drawn WITHOUT an engine, deliberately**: most of the codes that can reach it are engine codes, so drawing it through the engine that just failed is a coin toss whose losing side is *no document at all* — the outcome FR-59 exists to replace. **Its safety clause is held by construction rather than by a payload list**: the page carries `code`, `origin`, `line`, `engine`, `engine_version`, `duration_ms`, `correlation_id` and the template's name, and there is no path from `#message` or `#detail` to it — so the "no exception class, no SQL, no role/member/project id" assertions hold for payloads nobody thought of. `#document` is the ONLY action that can produce one; `#show` and `#preview` stay pages and are asserted to. The status stays the failure's own (500/422/501), because a 200 carrying "this is not your report" is INV-5 one layer up. **Running it found two defects reading it could not**: poppler rejected the first version's bytes (`endstream` running into `endobj` with no delimiter — *"Missing 'endstream' or incorrect stream length"*, which reads exactly like a wrong `/Length` and is not), and `schema_recorder.rb` had no `add_column` verb, so G11 reported **UNKNOWN** on the first migration in this plugin that grows an existing table. **17 mutations run, 17 red.** Raised **S-11** (the schedule half of §7b.3's opt-in) and **S-12** (E-6's zip, now T-29's alone) |
| T-31 | **DONE — and its second review REJECTED the second attempt too, harder than the first.** Increment 2 built the owned `Aggregation::TimeEntryAggregator` (clauses 4-7): eleven dimensions, `SUM(hours)`, positional grouped reads, an independent Ruby oracle on PostgreSQL 16 and MariaDB 10.11, and **D-1 reproduced live** where the plan had recorded the engine as uninstallable here — `DIVERGES (keys [nil], 0.3 against a real 10.55)` against `agrees` on PostgreSQL. Then a fresh-subagent review found **two BLOCKERS and eight MAJORS while every figure still agreed**, which is the finding worth carrying forward: value agreement proves arithmetic and nothing else. The blockers were a DISCLOSURE — `group_by: issue` printed the subject of an issue the actor may not see, because `time_entries.issue_id` survives the visibility condition core puts in `left_join_issue` — and an UNBOUNDED axis: `limit: 0` meant no cap, so 50 000 buckets came back with `truncated: false`. The majors: ties ordered by engine row order (and past a cap that changes *which* buckets exist), `sort: label` sorting by raw id with a spec whose own name admitted it, the cap folding `(none)` into `(other)`, a project-overridden activity as two identically-labelled buckets, six of eleven drill-through filters naming a filter `TimeEntryQuery` has not got (`author_id` resolving to a plausible WRONG row set), `drill:`/`split_by:`/`period:` dropped in silence against a README that promised them, and **thirteen surviving mutations in the guards the first commit said it had killed**. The dimension set is now core's eight from `time_report.rb`; the corrected version is **34 mutations, 34 red**, with a control run first — because the first harness ran `spec/adapter` and the DB-less specs in one process, where the baseline is already 7 failures, and reported 19 meaningless kills. Recorded rather than absorbed: **S-16** (`SUM` over a duplicating join), **S-18** (no custom-field dimension); **S-17** partially fixed (eight aggregation degradation codes localised in nine languages, mechanism settled for the rest) |
| T-32 | **DONE — and its independent review REJECTED the first attempt, with two blockers that value agreement could never have seen.** Both were the same shape: a *silent fallback to a WIDER scope than the requester asked for*. An unresolvable `query_id` took `ReportScope.build`'s `:ignore` default, so the saved query was dropped, the report was rendered over the whole project, mailed, and audited as `success` **under the query id it had ignored** — §Findings S-15 one caller later, with the `:raise` mode it needed already written and unused. And `filter_map { … if id.match?(/\A\d+\z/) }` discarded every non-numeric issue id *before* the "refused, not silently included" rule ran, under a 12-line comment explaining why dropping is a defect; at the boundary (`issue_ids=abc`) the parsed list came out empty, took the "no set was named" branch, and mailed a report over the requester's **entire visible scope** while the flash said "sent to 1 recipient". Five majors besides: seven of eight refusal codes rendered a **blank form** with no message at all (the reason was computed, written to the audit, and withheld from the person standing in front of it); a dead `||` guard over a locale key that did not exist, hiding an unused key that *was* translated nine times; **two spec files cited as mechanical evidence that had never been written**, one of them load-bearing for S-19's `address` argument; the recipient bound is every active account in the instance (**pinned by a test and recorded as S-20**, not narrowed — §4.1's `require: :loggedin` and FR-61 disagree about what the bound should be); and five surviving mutations. All fixed, `spec/reporting/adhoc_delivery_spec.rb` written, **8 round-2 mutations, 8 red** after one survivor (an unreachable branch) got the delivery-level test it was missing. The review also found a defect in **my own harness**: `tail -3` cut rspec's summary line off and the green check read absent output as a pass, so four mutations were reported as surviving when nothing had been measured — it now fails closed, and two of those four report "1 failure" singular. Original entry: **done** — `app/controllers/reporter_dashboards/mail_controller.rb` (3 actions), `reporting/{mail_policy,adhoc_delivery}.rb`, two mailer actions with a shared body partial, migration 009's two audit tables, two models, two views, four settings, 37 keys × 9 locales, and **T-40's promotion of `mail_reporter_dashboards_reports`** — the first permission promoted with `require: :loggedin` rather than `:member`. **Each clause of §7b.5's indictment is closed by construction rather than by validation**: the issues resolve through `Reporting::ReportScope` (so `Issue.visible(actor)`), the recipients through `MailPolicy` (admin setting + domain allowlist, `false` and empty by default), and the sender through there being **no parameter a sender could travel in** — asserted against the mailer's own parameter list, because Redmine's `Mailer#mail` merges `From` with `reverse_merge!` and a caller-supplied one would win. **An issue the requester cannot see REFUSES the whole send**, which is T-32's `Accept:` word: silently including it is the base plugin's defect and silently dropping it is the plausible-looking fix, so the count is named and nothing is sent. The rate limit **counts attempts off the audit table** rather than a counter column — one source of truth, and the expensive half of a send is the render — while a refusal that happens before any work consumes nothing, because a quota a refused request consumes is one nobody can recover from. §7's table list names neither table: they are derived from FR-61 and recorded as **S-19**, with the `address` guard **tightened** rather than loosened. **Its own tests found four defects**: an address with no local part (`@example.com`) passed the allowlist; `Template` had no `dependent: :nullify` so an audit row lost its subject's name with it; a visibility fixture proved nothing because the role held no `:view_issues`; and a "a failed send counts against the limit" test passed for the wrong reason until the before/after-claim split was made explicit |
| T-24 | **done — `import:run` and `import:status`; `import:verify` is DROPPED with evidence (§Findings S-21), because the corpus discipline needs a frozen fixture AND a pinned date and production has neither.** `import/{runner,import_report}.rb` plus two rake tasks. **COPY, FORWARD-ONLY, NEVER ADOPT** — §7's *Adopt vs copy*: the base plugin's own documented uninstall drops `report_templates`, so adopting those rows would lose them, and *"nothing inside the new plugin can prevent that"*. The no-write claim is asserted on the **statements** rather than on the rows, because a row that still looks right proves the importer did not happen to change it and not that it could not. **Idempotence has FOUR outcomes, not two** — `created`, `unchanged`, `updated` (a safe fast-forward when the source moved and the copy did not) and **`diverged`**, which is the one the `Accept:` line is about: a copy edited here is never overwritten, because an importer that clobbered it would destroy somebody's post-migration work once, quietly, on a re-run triggered for an unrelated reason. Divergence is reported and does NOT make the task exit non-zero — it is the expected state after a migration, not a failure. The type map is `Reporting::Exchange::TYPE_MAP` reused rather than copied, so `constantize` on a database column is refused for the same reason FR-55 refuses it on a file. `import:status` reads OUR templates rather than the source's, so it still answers after the base plugin has been uninstalled — which is exactly when somebody asks what state their migration is in. **Its independent review REJECTED the first attempt with two blockers**: the statement-level "never writes to reporter's tables" assertion was anchored at `\A` and one leading `/* rails */` comment defeated it — a real planted `UPDATE report_templates` survived — and the comment cited `spec/import/runner_spec.rb`, which has never existed, repeating T-32's own rejected defect one task later. The pattern now matches verb+table and its NEGATIVE TEST is committed rather than performed by hand. Four majors besides, all fixed. **`RRD_REWRITE=1` is the `--rewrite` §7a named** and it is not a plain overwrite: the local content is written into the append-only version history FIRST, so taking the source's version loses nothing and the order is asserted by driving the snapshot to fail. A template whose project does not exist here is SKIPPED rather than imported invisibly (every surface is project-scoped, so the row was unreachable). 24 full-app runs against real reporter-shaped tables, **11 mutations, 11 red** across two rounds |
| T-29 | **done** — the exchange bundle AND the streamed archive, which arrived together because §Findings ~~S-12~~ gave the second to T-29 alone. `reporting/{bundle,bundle_import,bundle_report}.rb`, `archive/zip_stream.rb`, `exchange_tasks.rb`, three rake tasks, a ninth `layer_purity` arm, 2 keys x 9 locales and one key deleted. **The bundle WRAPS `Exchange` rather than restating it**: one closed TYPE_MAP, one field list, one version rule, one safe-YAML reader — a second field list is the failure mode that lost `failure_document` once already, and it is silent because a field absent from BOTH ends still round-trips byte-identically. **FR-57 is four decisions, not a hope** — order (by name, then id, so the receiving installation's ids cannot move anything), key order, encoding (raw UTF-8, so `Übersicht` is bytes rather than `\u00dc`) and `exported_at` being an ARGUMENT; the test asserts the payload halves match INDEPENDENTLY of the envelope, because pinning the whole file would also pass if the payload were empty on both sides. **The archive is a dependency-free STORED zip** validated by `unzip -t` and Python's `zipfile` as well as by an independent in-spec reader, and the controller streams it with no `Content-Length` — `@controller.response_body` is asserted to BE the lazy writer, which is the assertion that fails the moment somebody puts `send_data` back. **The documents are rendered before the first byte, on purpose** (E-6). Raised **S-22** (§7b.2's two rake names are already taken by the migration importer, and rake would have run both bodies) |
| T-29 review | **REJECTED on the first pass, and every defect was at a boundary the tests did not cross.** A fresh subagent found 3 BLOCKERs, 3 MAJORs, 5 MINORs, 3 NITs, each with a probe. The blockers: (1) the archive is drained by `Rack::ETag` before the first byte — the middleware, which `ActionController::TestCase` never runs; (2) **a bundle carrying two templates with the same name lost one** under the default policy, because `Template` has no uniqueness validation on `name` and the importer asked the DATABASE per entry, so the second entry collided with the row the first had just written — FR-57 fails on exactly that bundle; (3) **`plan` did not predict `apply`** on the same input, the case the class comment calls "worse than no plan at all". (2) and (3) are one fix: the conflict set is SNAPSHOTTED before the first entry, so a within-bundle duplicate is not a conflict and both entry points decide identically. The majors: a logger raising inside a rescue aborting the bundle (already fixed); the ONE test pinning the overwrite permission was **vacuous** — the fixture project never had the reports module, so `editable_by?` was false for every non-admin and the test would have passed against an arm that refused everything; and the web Import button still read `Exchange.parse`, silently importing the FIRST template of the multi-template bundles the same release taught `export:bundle` to write. All fixed; two of the reviewer's 18 mutations survived and both were the pre-declared redundant guards |
| T-28 | **DONE — three increments, two independent reviews, both of which REJECTED it (§Findings **E-23**, **E-24**). FR-54 and FR-62 were NARROWED by curator decision rather than built (§Findings ~~S-28~~), and the one thing that decision leaves open — reports render a URL-referenced image blank, because nothing calls the asset layer — is **F-16** and belongs to T-33. **F-16 IS NOW CLOSED (2026-08-09) and T-28 has no remaining owed half**: the asset layer is called, so a same-origin image is inlined off disk rather than reaching a share-link recipient as a dead URL. Note this does NOT re-open FR-54, which the curator narrowed to option 2 — a share link still authorises ONE DOCUMENT and grants nothing it points at; what changed is that the document now CONTAINS its images instead of pointing at them, which makes the narrowed promise stronger rather than different.** and its increment-2 review REJECTED the change with two blockers that were both "the test cannot fail" rather than "the code is wrong" (§Findings **E-23**).** **Increment 1** (`d9943ca`): migration 010, `ShareLink`, `ShareLinkAccess`. Only the digest is stored; lookup is by digest with a fixed-length constant-time compare; expiry is NOT NULL in the *schema*; `use!` is one conditional UPDATE whose WHERE clause carries the whole rule. **Increment 2** (`d36ad97`): `Reporting::Snapshot` — the write path `reporter_dashboards_documents` had lacked since T-22 created it — plus the public endpoint at `GET /reporter/s/:token`, outside any project, the only controller here with no permission because *"may whoever holds this token have these bytes"* has no person in it. **Two core measurements changed the design and both are findings**: `Attachment.prune` would have deleted every snapshot after a day (**S-24**), and `attachments.container_type` is `varchar(30)` while every model name here is longer (**S-25**). **Increment 3** (`e50bf6b`): the owner's list with revoke and revoke-all, both permissions promoted, and FR-54. **Revocation is OWNERSHIP, not a permission** — a third party holding every grantable permission cannot revoke somebody else's link, and revoke-all checks per link rather than once for the template, or it would be an escalation with a convenient name. **FR-54 IS NOT MET, and the commit that claimed it was cited a control with no call site** — `Assets::Resolver`/`AssetBinding` are never called, `ReportRun` passes the body straight through, and a real render puts `/attachments/download/1` into the PDF verbatim. Nothing leaks today (INV-8 denies the renderer a credential, so the fetch fails) but that is not what FR-54 asks for. **S-28** puts three options to the curator. **`PLANNED` is now EMPTY** — every permission §4.1 names is registered — which makes four permission-spec examples vacuous, so an example asserts the emptiness and names them. Curator decisions taken along the way: **~~S-26~~** (a public link serves on a `login_required` instance — *"public is public… it's a choice"*) and **S-27** (the token is in every access log; short expiries are the bound). Found and fixed **E-22**, a security assertion in increment 1 that tested nothing, proved wrong in both directions. **Its increment-3 review REJECTED it too (§Findings **E-24**)**: four scoping and identity guards had no test — one mutation made the snapshot render as the TEMPLATE'S AUTHOR while still recording the sharer, a measured escalation — and two ordinary form values wrote a full render, a `Document` row and an `Attachment` to disk on a request that then FAILED, repeatable without bound. All fixed; every field is now checked before the render. Mutations: 21 + 15 + 9 + 10, all killed after three rounds of survivors were closed with tests |
| Curator decisions, 2026-08-11 | **done, and two of the four are deliberately NOT code.** `:gotenberg` promoted to `verification: corpus` with the matrix regenerated from a three-engine run; `:engine_misconfigured` added to the closed `Failure::CODES` set (six sites, three argued non-movers, twelve-row boundary table). The `gotenberg:8.35.0-chromium` switch is **HELD**: its own module banner lists `pdfcpu` and `pdftk`, so the "3 of 4 advisories are absent" premise the YES rested on is refuted and there is no CVE argument left — and the image REFUSES the compose file's `--libreoffice-disable-routes`. The all-deferred exit code stays the curator's, with a re-measured recommendation. **Three independent reviews (reviewer, adversarial QA, UX) and the first attempt was rejected by all three for the same class of defect** — a control that did not hold the boundary it claimed. §Findings **E-29** |
| FR-50 / §5.2 clause 4 | **done** — `render/engine_preference.rb`, the `render_engine` setting, the settings partial's generated one-line-per-engine comparison, `ReportRun`'s precedence (hint → this installation → declared default → any engine needing no service), and `PreflightSuite` no longer deferring the engine an install SELECTED. Locale keys ×9, terminology per file. E-27 row 2 CLOSED |
| T-26 onward | not started |

**Phase 1's promise is met and measured**: the plugin installs and runs with neither
`redmine_reporter` nor the `redmineup` gem. Verified on Redmine 6.1-stable with and without
reporter, and on 7.0-stable standalone, against real PostgreSQL. Not yet verified anywhere: Redmine
5.1 and 6.0, and MySQL/MariaDB — CI covers those, a local run has not.

**This paragraph used to say the workflow still checked out the private reporter plugin with a
secret. It has not since T-09** — `no_secrets.sh` runs on every PR and fails on any `secrets.`
reference but `GITHUB_TOKEN`, and the full-app suite runs standalone on all four Redmine branches.
The plan contradicted itself on this: §Findings D-2 already described T-09 in the past tense. Both
now agree, and the correction is recorded rather than quietly applied, because a status line that
was wrong for a whole phase is the kind of thing that gets believed twice.

**What is genuinely still owed for INV-7** is smaller and is F-5: one dated fork-PR run per release.
A workflow cannot fork itself without reintroducing the very credential G1 removes, so that proof is
a human artefact, and the grep is what keeps it true between artefacts.

## Findings — what the work has turned up, and who owns the fix

**E-29 · THE CURATOR'S FOUR DECISIONS: TWO LANDED, ONE HELD ON A REFUTED PREMISE, ONE
ANSWERED WITH A RECOMMENDATION — AND THREE INDEPENDENT REVIEWS REJECTED THE FIRST ATTEMPT.**
2026-08-11. Everything below was reproduced with a probe or a mutation.

**What landed:** `:gotenberg` promoted to `verification: corpus` with the matrix regenerated
from a run in which all three corpus engines executed (E-27 row 1), and
`:engine_misconfigured` added to the closed `Failure::CODES` set with six emitting sites and
three deliberate non-movers (E-27 row 3). **What did not:** the `-chromium` image, whose CVE
argument was refuted by the image's own module list (§CVE decisions item 2), and the
all-deferred exit code, which is a curator call and now carries a measured recommendation
(E-27 row 7).

**AND THE THREE REVIEWS FOUND THE SAME CLASS OF DEFECT FROM THREE DIRECTIONS, WHICH IS THE
REASON TO BELIEVE THEM: the change's own control did not hold the boundary it claimed.**

| what | measured | fixed |
|---|---|---|
| **The seven-row classification table pinned SEVEN OF TWELVE arms.** Five could be moved across the line with the whole suite green — including one the source comment claims is protected by name | the reviewer's own mutations, then all five applied at once: **2569 examples, 0 failures**, byte-identical to the control | yes — twelve rows now, and each of the five new arms was re-mutated and killed |
| **The new block's double could be made friendly again silently.** Reintroducing the very shape HANDOVER §1 records — an unauthenticated `/version` answering 200-with-the-version, which no locked Gotenberg does — left all seven rows and the control green | `157 examples, 0 failures` under the friendly double | yes — the double's PREMISE is now an example against the script itself (401 unauthenticated, 200 authenticated), and that mutation dies |
| **The discriminator written into the closed set failed its own first example.** It said `:engine_unavailable` is where "nothing an operator TYPES changes the diagnosis" and listed "not installed" — which is fixed by typing `apt-get install` | read, by a UX pass, and confirmed against four spellings of one operator error landing on two codes | yes — the tie-break is now "can this side tell WHOSE problem it is", and `technical-spec.md` §5 carries the same words rather than a paraphrase |
| **"A misconfiguration always names something an operator sets; an unavailability never claims to know which"** — asserted in a new example, and refuted by the shipped 404 message, which names the address and `--api-root-path` | the real message, read off a container behind a wrong root path | yes — the example asserts the narrow claim that is true (an arm that only knows "nothing answered" does not accuse the credential or JavaScript) |
| **`README.md` said "Verified in CI since 2026-08-11"** on a date for which no CI run of this tree exists; the cited runs are 2026-08-10 and predate enforcement | `gh` run list | yes — "measured in CI run 31408759956 (2026-08-10), enforced since 2026-08-11" |
| **The promotion broke HANDOVER §3's own local corpus recipe**, which carries no `RRD_GOTENBERG_*` | that recipe, run as `rrdbench`: **69 examples, 23 failures**, every one "gotenberg claims `verification: corpus` … and its preflight failed" | yes — §3's recipe carries the three variables, `spec/conformance/README.md` carries the container command, and HANDOVER's "the corpus reports gotenberg as unavailable" is corrected: it raises |
| **The consequence was written as CI-only in four places** while `conformance_spec.rb` has never heard of CI | same 23 failures, locally | yes — "wherever the corpus runs" |
| **EVERY `translation missing` ASSERTION IN THE PROJECT WAS BLIND.** Rails renders a missing key as `"Translation missing: en.…"` with a capital T, so `assert_not_includes response.body, 'translation missing'` never matched. Five call sites in four files, the oldest from T-33 — each one a control whose only job is to notice an absent key | found by mutation on my own new test: deleting `label_reporter_render_engine_assets` from `en.yml` left it GREEN. Then measured directly — `l(:no_such_key)` → `"Translation missing: en.no_such_key"` | yes — all five are `assert_no_match(/translation missing/i, …)`, case-insensitive because the casing is Rails' and this plugin spans three Rails majors, and the same mutation now fails both settings tests |
| **THE INSTALLATION'S SELECTED ENGINE REACHED `PreflightSuite` THROUGH A PORT NOTHING ASSERTED.** A port a caller forgets is invisible from outside — the page renders identically and only a deferred engine's skip row moves — and this plugin has already lost `asset_resolver:` to exactly that | mutation: dropping `selected_engine_id:` from the controller left the suite green before the assertion existed | yes — asserted on the CONSTRUCTOR in both directions (a selection is handed over; no selection hands over nil), and dropping the argument is now red |
| **THE SETTINGS SCREEN'S DEGRADED STATES RENDERED AS NOTHING, and one of them deleted the safety sentence.** With `config/capabilities.yml` unreadable the fieldset printed its "generated from capabilities.yml" promise followed by three bare ids — and `needs_service?` cannot know, so an installation that had CHOSEN Gotenberg lost the warning naming the service and the environment credential. `catalogue_readable?` existed for exactly this and the view never called it. The unverified marker was nested inside "is it known", so it was suppressed in the one state where nothing is verified (INV-7 inverted). An empty registry printed an empty list where the preflight page has a sentence in nine languages | driven by a UX pass against `catalogue: nil`, an unregistered-but-offered engine, and `registered_ids: []` | yes — both states have their own sentence in nine locales, the markers moved out, and four view branches are mutation-tested through the real page (each of the five mutants red) |
| **THE COMPARISON WAS A `<ul>` WITH ITS PUNCTUATION IN THE MARKUP**, so German read `… over CDP. benötigt einen Dienst: Nein.` — a sentence beginning lowercase — Chinese got ASCII colons and stops inside CJK text, every field ran into the next with no full stop, seven of nine "cannot do" labels were transitive verbs waiting for an object, and the list hung ~180px left of its own introduction because `.tabular p` indents a paragraph and a bare `<ul>` gets nothing | measured through real `I18n` in all nine locales, and against Redmine 6.1's own `application.css` | yes — `table.list`, which is §9b.3's own word ("table"), Redmine's own chrome, and puts every field name in a `<th>` where a capitalised noun phrase is correct. One change closed five findings |
| **THE TRADE SENTENCE — the one thing §5.2 clause 4 names — was carried on the object and rendered nowhere**, while the view's own comment said it was rendered | `rg 'offer.trade' app/` → no hits | yes, in the first cell, and its removal is a red mutation |
| **"renders offline: Yes" sat beside "needs a service: Yes"** on the one engine where the row could matter, reading as a contradiction | all nine locales | yes — "renders without internet access" in nine languages |
| **The asset model was reported as three ABSENCES**, so the reference engine was shown lacking `:asset_http` — the capability INV-8 exists to keep it from having — and gotenberg as unable to do `:asset_inline` one screen from a README paragraph saying its upload model changes nothing for an author | read off the rendered page | yes — an asset-model column, and the three `asset_*` capabilities are excluded from the absence list |
| **The blank option claimed a stored choice that does not exist** ("This installation's default"), in a second sense of "default" from the neighbouring preflight page's | read | yes — "Chosen by the plugin (chromium_cdp)", one framing for both branches, nine locales |
| **`Gotenberg#preflight` RAISED, and `technical-spec.md` §5 — edited by the same commit — says "Never raises".** `check_credential`'s authenticated `/version` probe was the one transport call in the sequence with no rescue; `send_request` converts only the three timeout classes, so `Errno::ECONNREFUSED`, `EOFError`, `Errno::ECONNRESET` and `SocketError` escaped `#preflight` entirely. **The promotion is what turned it from a skip into a defect**: `spec/conformance` calls `engine.preflight` with no rescue, so at `corpus` one example gets a raw stack trace reading as a plugin bug beside twenty-two with the right message | a real listener that answers the identity probe and then stops listening — a restart, an OOM kill, `--force-recreate`. Reproduced inside the corpus | yes — the same rescue shape `check_reachable` already had, answering `:engine_unavailable` and a message naming more than one remedy. Four classes × one example each, plus three mutations (the rescue narrowed, the wrong code, the class leaking into the user-facing message) all red |
| **`Matrix#cell`'s `'not verified'` branch and the whole `footer_section` became unreachable** the moment no engine was left at `pending`, and one existing example ("makes every unverified engine explain itself") went vacuous | the example iterates an empty collection and passes | yes — a synthetic `pending` entry exercises both branches, two mutations kill it, and the vacuous example says so and asserts the catalogue is non-empty |
| **The generated matrix lost its provenance in the commit that made it a contract.** With no engine left at `pending`, the footer that printed `verification_note` — the paragraph naming Gotenberg 8.35.0, the pinned digest and run 31408759956 — disappeared, leaving 60 PASS cells and no version, digest, run id or date anywhere | `rg '8\.35\|141\.\|0\.12\.6\|patched qt\|digest\|sha256' docs/engine-support-matrix.md` → no matches. And HANDOVER's own worst trap here is a plausible result from the WRONG BINARY: unpatched-Qt wkhtmltopdf gives 17/1/2, patched gives 18/0/2 | partly, and deliberately not by inverting the rule: `matrix.rb`'s header argues at length that the exact build is kept OUT of the file, because a matrix that goes red on a Chromium patch release trains people to regenerate it without reading it. So the generated header now SAYS where provenance lives (`capabilities.yml`'s `verification_note`, per engine, plus the run's own log) rather than pretending it is here |
| **`role: documented` prints in the generated matrix next to measured cells**, and `documented` is ALSO a `verification` value meaning "no adapter ships" | read off the regenerated file | partly — the generator now prints a Role legend that says which meaning is which. **Recommendation below** |
| Two nouns for one check: `CHECK_TITLES[:gotenberg_endpoint]` said "endpoint", its locale key and its failure message say "address" | read | yes — "address" |
| The matrix ended in two blank lines once the footer section disappeared | the regenerated file | yes — `footer_section` returns `''` |
| `ci.yml`'s `continue-on-error` rationale ("a 404 asset must not fail this job") stopped being true at wkhtmltopdf's own promotion | `RRD_WKHTMLTOPDF_BINARY=/nonexistent`: **23 failures** | yes — the comment says what the flag does now |
| The CHANGELOG said "two engines", had no Gotenberg entry at all, and still called wkhtmltopdf "not yet verified" in the same section that announces its results | read | yes, plus entries for FR-50, the promotion and the new code |

**RECORDED, NOT FIXED. Each with what was measured.**

| # | What | Measured | Recommendation |
|---|---|---|---|
| 1 | **`role: documented` collides with `verification: documented`**, and the two mean opposite things — "an option you choose deliberately" versus "no adapter ships" | the generated matrix prints `documented` in Gotenberg's Role column, 315 lines from a README paragraph headed "Measured in CI"; `ROLES` and `VERIFICATIONS` both carry the token | **Recommend renaming the ROLE value to `optional`** — the curator's own words for the decision were *"als een van de opties"*. It changes `EngineCatalogue::ROLES`, one line of `capabilities.yml` and one generated column, so it moves the committed matrix (G9) and is therefore a curator act rather than a cleanup. The interim shipped here is the Role legend |
| 2 | **A name that does not resolve and a socket that refuses get one sentence and one code.** `Socket::ResolutionError` and `Errno::ECONNREFUSED` both produce *"nothing answered at …, Confirm the container is running and that Redmine can reach it at this address"* | both, against a real container and a dead port; the class survives only in `detail`, which the admin page prints in a column headed **Engine version** | **Recommend a named arm** for an unresolvable host — *"the name X does not resolve from Redmine; check the spelling of RRD_GOTENBERG_URL and that Redmine is on the same Docker network"* — which is the one of the three faults whose remedy is unambiguous. Two lines and one example, and it is a diagnostic-message change rather than a code change, so it does not belong in the commit that introduces a code |
| 8 | **FR-50 is the wrong number for this screen, and ten files now carry it.** `functional-spec.md:275` defines FR-50 as *"Documented limitations (per engine, per database) are published and generated from the test run"* — the support MATRIX. The engine-selection UI is `technical-spec.md` §5.2 clause 4 and §9b.3, and FR-74 is the requirement that names a setup surface | read by a UX pass. §5.2 clause 4 itself says "generated from `capabilities.yml`, **per FR-50**, never hand-written", so the spec cites FR-50 for the GENERATION property and E-27 row 2 then used it as the name of the whole clause. The commits, the view comment and nine locale-file headers followed | **Recommend** the curator either renumber (a new FR for the selection, with §5.2 clause 4 pointing at it) or add one sentence to `functional-spec.md` saying FR-50 covers "generated, not hand-maintained" wherever a surface is generated. The prose in this repository has been changed to say "§5.2 clause 4" where it means the screen; the locale-file section headers still say FR-50 and are not worth nine edits before the numbering is decided |
| 9 | **§9b.3 puts the engine comparison on the DIAGNOSTICS surface, and it shipped on the SETTINGS page.** *"Two additions turn it from a debugging tool into the onboarding path: an engine comparison table generated from `capabilities.yml` … and a 'fix this' line per failing check"* | read | Both placements are arguable — the comparison is most useful where the choice is made, and §9b.3 wanted it where a failing check is read — but only one should carry the table, and the preflight page does not link to it. **Recommend** the curator decide; the cheap interim is a link from *Administration → Render preflight* to the settings page |
| 10 | **Half of every engine line is untranslated English for a non-English administrator**, and the argument that it is "data reported by configuration" is weaker here than for `Check#detail` | measured, ru: `chromium_cdp — Headless Chromium over CDP. … установка: one documented package install (chromium), not provided by bundle install` — the English is a subordinate clause of prose this project wrote, in a file it owns, FOR this screen | **Recommend** the option a UX pass costed: `l(:"text_reporter_engine_install_#{offer.id}", default: offer.install)` — six keys for the three shipped engines, an engine another plugin registers keeps its English, and `capabilities.yml` stays the single source because absence falls back to it. Not done here because it puts English prose into nine locale files keyed by engine id, which is a new drift surface, and because the same argument applies to `trade` and `label` — three fields × three engines × nine locales is a curator-sized decision, not a fix |
| 11 | **A dropped setting's REASON can never be localised**, and this one duplicates a sentence already translated nine times | `EnginePreference` emits `reason: 'no render engine is registered under that name. Known: …'` and the view prints it raw, while `text_reporter_preflight_unknown_engine` — *"No render engine is registered under that name. Known engines: %{engines}."* — exists in all nine files, ~320 lines above in the same locale file | Structural, not sloppy: `render/**` may not touch I18n (mechanism E5) and a dropped entry carries prose with no code. **Recommend** adding `code:` beside `reason:` (`:unknown_engine`, `:not_a_single_value`, `:too_long`) and letting the view map code → key with `reason` as the fallback — the mechanism S-17 settled for degradation codes. **The asset and mail sections have the identical defect**, so it is one change across three sections rather than a third of one |
| 12 | **The 20 capability tokens reach an administrator as raw Ruby symbols** (`:modern_javascript`, `:page_furniture_tokens`) | read off the rendered page | Deliberate, and the same argument as engine ids: these are the closed vocabulary the support matrix, the conformance fixtures, the degradation records and `capabilities.yml` all use, and a localised alias would be a second name for a token that has exactly one everywhere else. **Recommend** revisiting only if an operator survey says otherwise; 20 keys × 9 is affordable but a second vocabulary is not |
| 4 | **`spec/render`'s real-container examples are FLAKY, and the promotion makes that job's gotenberg column the contract.** Two examples lose a race with the container's own process pool: `gotenberg_service_spec.rb:214` (readiness settles) and `:127` (the upload-model pixel) | an adversarial QA pass ran `rspec spec/render` with the containers present **seven times: 3 red** (`369 examples, 1 failure` / `2 failures` / `1 failure`), against 0 failures without them. The container's access log names the mechanism — `acquire process lock: context canceled`, 8 s and 22 s waits before a 28 s trivial conversion — and the pool limit was measured directly: **6 concurrent conversions run, the 7th and 8th queue for a full slot** (8.5-8.8 s each, then 16.9 s). Two hypotheses were refuted on the way: an abandoned readiness conversion does NOT block the next one (Gotenberg cancels on client disconnect), and two concurrent conversions do not serialise. My own runs of the same file (12 examples) and three corpus runs were green | **Do not bump the two budgets to make it green** — that is weakening an assertion whose subject is a real bound (CLAUDE.md's working agreement). **Recommend** measuring the flake rate on a GitHub runner first (`rspec spec/render` ×5 in `render-smoke`), because the container there has `--api-timeout=60s`, a read-only rootfs and 256 MB of `/dev/shm` and may not reproduce it at all; and if it does, giving those two examples a container of their own rather than a longer budget. This is E-27 row 4's neighbour — that row watched the abandoned-request path and this is the queue in front of it |
| 5 | **The JavaScript check reads ANY 409 as "JavaScript is live"**, so a WAF, an authenticating proxy or an unrelated `failOn*` policy makes all four configuration checks pass and the run then blames the plugin | measured against a fake answering 409 to every authenticated conversion: four PASS rows, then `Failure(:internal)` — *"the report could not be produced"*, the code whose own comment says "a bug here, not an engine fault". The same file reads 409 two ways: `check_javascript` calls it health, `interpret` routes `Net::HTTPClientError` to `:internal` | **Recommend** discriminating on the 409 BODY, which already carries the answer: a real Gotenberg names the throwing script's own error in it (confirmed in the container's log). One condition and one example. Not done here because it changes a security-adjacent check's verdict, which is its own review — and because the new classification table would then need a row for "409 for the wrong reason" |
| 6 | **The preflight's operator surfaces carry no failure CODE at all**, so the new code cannot be verified through them | `grep -c misconfigured` over the text AND json output of a failing run: **0**. `Report#to_h` has no `code` field, and `preflight.rb` includes one only for the render-probe check. So `script/render_preflight_exit_codes.sh` pins the credential arm on its SENTENCE (which is right, and is what makes the arm non-vacuous — a dead open service correctly fails the arm) and cannot see the code; the only place a moved code is checked against a real service is `gotenberg_service_spec.rb` | **Recommend** adding `code` to `Check`'s published hash and to `Report#to_h`. It is a change to the JSON artefact's shape — an ops interface something may already parse — so it is a curator-visible change rather than a fix |
| 7 | **A saturated Gotenberg is reported as the DOCUMENT's fault.** The 7th concurrent conversion waits a full slot, the wait is charged to `request.timeout_ms`, and the caller gets `Failure(:timeout, "the report took too long to draw")` | the pool measurement in row 4 | `technical-spec.md` §5 makes the OPPOSITE choice for the Chromium pool — a queue wait past `queue_timeout_ms` is `:engine_unavailable`, *"a refusal is operable; a timeout is not"*. **Recommend** aligning them, which needs a way to tell "we waited for a slot" from "the render was slow" — Gotenberg's 503-at-api-timeout does not distinguish them, so this may need the queue bound to be ours (a semaphore around the POST) rather than theirs |
| 3 | **Two pre-existing `:engine_unavailable` sites fail the new discriminator.** `wkhtmltopdf.rb`'s `Errno::EACCES` arm (a binary that exists and is not executable, from an operator-typed `RRD_WKHTMLTOPDF_BINARY`) and `ReportRun#no_engine_diagnostic` ("no render engine is registered") | read, and both are unambiguous under the new rule: an operator's action fixes them and a retry never will | **Recommend moving both**, in their own change with their own tests. Deliberately not done in the commit that adds the code: a vocabulary addition and a re-classification of two unrelated call sites are two reviews, not one, and `no_engine_diagnostic`'s move touches the exit-code surface (`PreflightCommand` already reports that state as `NOTHING_TO_RUN`) |

**E-28 · T-34: THE CVE GATE WENT RED ON ITS FIRST REAL RUN AND ITS OWN REMEDIATION DID NOT
EXIST.** 2026-08-10. Measured, not reasoned.

`gotenberg-cve` was written as `trivy … --exit-code 1` and shipped green-by-assumption — it
had never been run against the pinned image, because the workflow only fires on a change to
the compose file. Its first real execution (run 31410189128) went red, and the DB-download
split did its job: the database fetched, the scan ran, and the finding is a fact about the
image rather than about the network.

| | |
|---|---|
| what the scan found | **5 fixable HIGH across 4 advisories** in `gotenberg/gotenberg:8@sha256:a16a14e1f18a…` (8.35.0). `CVE-2026-19155`, chromium/chromium-common 151.0.7922.71 — sandbox escape via use-after-free, fixed in 151.0.7922.108-1~deb13u1. Three more in `usr/bin/pdfcpu`: `CVE-2026-46602` / `CVE-2026-46604` (golang.org/x/image, TIFF decode) and `CVE-2026-56852` (golang.org/x/text) |
| what the workflow told a human to do | pull `gotenberg/gotenberg:8`, read its digest, move the pin |
| what that would have achieved | **nothing.** `gotenberg/gotenberg:8` and `gotenberg/gotenberg:8.35.0` BOTH resolve to the digest already pinned, and 8.35.0 is the newest tag upstream publishes (registry manifest API, 448 tags enumerated). The Debian fixes exist; a Gotenberg image carrying them does not |

**Why this was a design defect and not just bad luck.** A gate no action can satisfy gets
switched off, and a switched-off gate is worse than none — INV-4. Making it advisory is
forbidden in the other direction (CLAUDE.md §7). So the verdict moved out of Trivy and into
`script/gates/cve_accepted_diff.sh`: Trivy runs with `--exit-code 0` and reports, and the
gate is a set comparison against `script/gates/gotenberg_accepted_cves.allowlist`, where
each acceptance carries a reason and a **valid-through date**. It refuses a finding nobody
named, an acceptance past its date, an acceptance the scan no longer reports, and a
malformed record. The stale arm is what stops the list becoming furniture — the same
assertion `layer_purity.sh` and `zero_reporter.allowlist` already make about their own
exemptions. The workflow also now resolves where the tag points *today*, so a red run says
"move the pin to X" or "there is nowhere to move to" instead of always the first.

**MUTATION TESTING FOUND A REAL DEFECT IN THE GATE, and it is the defect this project keeps
shipping.** Two mutants survived the first pass. One was verdict-equivalent and got an
assertion anyway. The other was not: the gate filtered both sides of the comparison to
`^CVE-`, and **Trivy's `VulnerabilityID` is not always a CVE** — Go and npm advisories with
no CVE assigned arrive as `GHSA-…`, Debian's tracked entries as `TEMP-…`. Such a finding
would have been dropped from the found list and the job would have reported **green with an
unaccepted vulnerability in the image**. Fixed to an uppercase-advisory-prefix shape, which
admits every scheme without an enumeration that would go stale and lock somebody out of
accepting the very id they were told to accept. Final: **16 of 16 mutants killed, 0 survived,
0 unmeasured**, control green before and after, over 18 self-test cases.

**The expiry is enforced on every pull request, not only nightly** — `ci.yml`'s `gates` job
runs the self-test and `--validate-only`. An exemption quietly outliving its date while every
PR stays green is INV-4 again, one level up.

**THEN AN INDEPENDENT REVIEW AND AN ADVERSARIAL QA PASS REJECTED IT, and between them
found six more defects in the gate written to prevent exactly this class.** Recorded
because the pattern is the finding: every one is "the check cannot fail", and four of the
six are the SAME defect displaced by one step.

| # | what shipped | how it was found | what it would have done |
|---|---|---|---|
| 1 | the valid-through date was checked for SHAPE, never for being a real day | review, by running `9999-99-99 \| reason` | a security exemption that never expires — the `Digest::MD5` row of CLAUDE.md §5, in the gate written to forbid it. `2026-13-45` too |
| 2 | no ceiling on the acceptance window | review | `2099-12-31` is well-formed, live, and permanent. Requiring an expiry to be PRESENT does not bound it. Now 90 days, enforced |
| 3 | **an EMPTY found list was green** | QA, walking the whole chain | a broken scan makes every acceptance look stale → the gate prints "Delete them" → a human does → the job is green FOR EVER over an image nobody scans. And the allowlist is *designed* to shrink to zero, so that state is the design's destination, not an edge case. Fixed by stated provenance: `cve_findings_from_trivy.sh` says a scan happened; silence is no longer a clean bill |
| 4 | an unreadable found file was laundered into "the scan no longer reports them" | QA, with `setpriv` | an I/O fault reported as a security verdict, with the remediation that produces #3 |
| 5 | the `jq` extraction lived untested in the workflow | review, in ONE command | the `^CVE-` narrowing that mutation testing had just killed INSIDE the gate, reintroduced one step upstream: green job, unaccepted advisory in the image, self-test still 18/18. Now `cve_findings_from_trivy.sh` + a committed sample report |
| 6 | the accepted-id grammar was stricter than the found side | QA | `pyup.io-38834`, `RHSA-2021:1234`, `openSUSE-SU-2021:0001` are all findable and were UNACCEPTABLE — the gate demands a remedy and then refuses it. INV-4 again. The grammar is now "a token that could have come off the found list"; a typo is caught by the STALE arm, which was always the real safety net |

**AND THE MUTATION CLAIM ITSELF WAS A FINDING.** The first pass reported 16 of 16 killed
from a harness in a scratch directory, and three different figures (14, 16, "six synthetic
inputs") shipped across four files in one commit. A reviewer's point stands: a mutation
score is a function of the mutant set, and the author picks the set — five mutants written
by a reviewer *after* that clean sweep all survived. The harness is now committed as
`script/gates/cve_accepted_diff_mutation.py` with those five in it, and no score is written
into a comment. Today it prints **22 killed, 2 survived, 1 not-applied, 0 unmeasured** over
**53 self-test cases**, control green before and after. Both survivors are EQUIVALENT
MUTANTS on the date-shape pre-filter, established by construction rather than by reading:
`date -u -d X +%F` always emits `YYYY-MM-DD`, so the round-trip equality already forces the
shape, and 36 hand-built candidates run through all three variants gave zero differing
verdicts.

**A DECISION TAKEN, NOT DEFERRED — where the expiry blocks.** Both reviewers independently
argued that a hard expiry in `ci.yml`'s `gates` job (which runs on `push: branches: ['**']`)
means every branch in the repository goes red the morning after a date passes, over a third
party's CVE, and that the cheapest unblock is a date bump nobody thinks about — the
"furniture" outcome the expiry exists to prevent, through the door the expiry opened. The
expiry is therefore HARD in the nightly scan and in any change touching the allowlist, the
compose pin or the gate, and ADVISORY in the every-branch job. Record well-formedness stays
hard everywhere. This is not §7's forbidden reclassification: the arm is still hard wherever
it is the detector and wherever the person seeing it can act. **Curator may reverse it** —
`--expiry-advisory` is one flag in one `ci.yml` step.

**FOR THE CURATOR — four decisions, none taken here.**

1. **Are these four acceptable for 30 days?** The three pdfcpu ones are unreachable as
   documented (`--pdfengines-disable-routes`), which is a mitigation and not a refutation.
   `CVE-2026-19155` is in the render path itself; what stands between it and the host is the
   compose file's containment (`internal: true`, non-root with Chromium's sandbox left ON,
   read-only root, `cap_drop: ALL`, `no-new-privileges`). Recommendation: **accept to
   2026-09-09**, which is what is committed, and re-decide when it expires.
   *2026-08-11: the stale arm fired on its second real run (31468632140) — the scan of the
   SAME digest no longer reports `CVE-2026-46604` (x/image TIFF panic), so the database
   changed under an unchanged image and that acceptance exempted nothing. Deleted per the
   arm's own remediation; **three acceptances remain**, and a dated comment in the
   allowlist says why the fourth is gone so a re-listing reads as the DB's doing.*
2. **`gotenberg/gotenberg:8.35.0-chromium`: the curator said YES on 2026-08-11 and THE
   PREMISE UNDER THAT DECISION IS REFUTED. Measured, not read — do not re-derive it.** The
   image exists (`sha256:d2aa8428406e71ad69b91399eec1546611a3b2a6a6f4f6513754add32cbea286`)
   and is smaller — **500 MB against 697 MB** — and there the agreement ends. Its own startup
   banner enumerates its modules:

       [SYSTEM] modules: api chromium exiftool pdfcpu pdfengines pdftk prometheus qpdf webhook

   **`pdfcpu` and `pdftk` are both in it.** The claim above — "no `pdftk-all.jar`, no
   `pdfcpu`, so 3 of the 4 advisories are not in it at all" — described a build that does not
   exist; what the `-chromium` variant drops is **LibreOffice**, and nothing else. Both
   remaining pdfcpu acceptances (`CVE-2026-46602`, `CVE-2026-56852`) are Go-library findings
   *in pdfcpu*, so the expected benefit is **0 of 3**, not 2 of 3, and `CVE-2026-19155` is
   Chromium itself in every variant. And the second half of the recommendation was right:
   the image **REFUSES the compose file's own command list** — `unknown flag:
   --libreoffice-disable-routes`, container exits 2, nothing listens.
   `--pdfengines-disable-routes` IS accepted (that module is present, which is the same
   evidence from the other side).

   *Not switched, and this is a deviation from the curator's YES, stated rather than
   quietly absorbed.* Switching now would mean (a) editing the documented hardening command
   list — a curator-visible change to what "safe" means, not a pin bump — and (b) pruning
   acceptances whose presence in the new image only a Trivy scan can settle, which this
   environment cannot run (HANDOVER §3: no DNS inside a container). **Recommendation:
   DO NOT switch on the CVE argument, because there is no longer a CVE argument.** If the
   200 MB is wanted for its own sake, that is its own task: new pin, one flag removed from
   the compose file with the reason, a scan read from CI, and a fresh corpus run.
3. ~~**Promotion of `:gotenberg` to `verification: corpus`**~~ **CLOSED 2026-08-11** — taken
   by the curator on the corpus evidence, independently of the image's CVE status, exactly as
   this item said it could be. See E-27 row 1.
4. **An acceptance is keyed on the advisory id ALONE** — no package, no version, no
   severity. Once `CVE-2026-19155` is listed it is accepted for any package at any severity,
   including a future CRITICAL occurrence in a different component. `zero_reporter.allowlist`
   and `layer_purity`'s exemption are both path-scoped; this one is not, and it is the looser
   shape. Not fixed here because binding to package+version makes the list churn on every
   image rebuild, which is its own way of training people to stop reading it.
   Recommendation: leave as is while the list is four entries long, and revisit if it ever
   exceeds ten.

**STILL UNCLOSED, stated rather than implied.** GitHub disables `schedule:` workflows after
60 days of repository inactivity, and the nightly scan is the ONLY detector of a newly
published vulnerability — a quiet repository therefore stops scanning with nothing saying
so. `push:`/`pull_request:` triggers on the pin, the allowlist and the gate now cover the
cases where somebody is editing, but not the case where nobody is. No fix here.

**E-27 · T-34: THREE OF THE FOUR SECURITY CHECKS COULD NOT FAIL WHEN FIRST WRITTEN, AND
THE CORPUS FOUND THE ONE DEFECT NO UNIT ASSERTION COULD SEE.** 2026-08-10. Everything below
was reproduced against `gotenberg/gotenberg:8@sha256:a16a14e1f18a…` (8.35.0) with a probe or
a mutation, never read.

**The measurements, because each one inverted a design that looked obviously right.**

| what looked right | what it measures | what was measured |
|---|---|---|
| probe `/health` unauthenticated to prove the credential is enforced | nothing | `/health` is **EXEMPT** from basic auth: 200 on a locked-down service and on a wide-open one. `/version` and `convert/html` are not. The probe is now an unauthenticated POST to the convert route — the route that matters, no render, 401/403 versus anything else |
| send `waitForExpression` to prove JavaScript is alive | nothing | with `--chromium-disable-javascript` Gotenberg **silently ignores** it: 200 in 0.17 s, against 503-at-the-api-timeout when JS is live. The readiness contract is void, every chart is missing, nothing fails. Discriminator: a script that THROWS plus `failOnConsoleExceptions` — **409 live, 200 disabled**, half a second either way |
| a JS-probe timeout is not a failure | nothing | it made the check unable to fail against the service least worth trusting. A timeout is now its own named failure |
| swap the page for landscape, like the reference adapter | the wrong thing | `landscape` rotates **whatever dimensions it is given**, so swap-and-flag cancels: every landscape report came out PORTRAIT with correct margins and no error. **Conformance fixture F-03 caught it** (`expected 841.89 ± 3, got 595.92`) |
| `Readiness::EXPRESSION` can be sent as-is | breaks every chart | it is `undefined` before the shell runs, and Gotenberg answers **400 "returned an exception or undefined"** in 0.2 s rather than waiting. `!!(…)` — which the reference adapter has always done — makes it a real `false` |

**AND THE MUTATION HARNESS'S OWN FIRST CONTROL RUN FOUND TWO TESTS THAT WOULD HAVE BEEN RED
IN CI AND GREEN EVERYWHERE ELSE.** The harness exports `RRD_GOTENBERG_USERNAME`; the adapter
had `credential: nil` defaulting through `credential || credential_from_env`, so
`Gotenberg.new(credential: nil)` — the exact subject of the security examples — picked the
environment's credential up. Green on a clean laptop, red in `render-smoke`, which exports
those variables. There was also no way to express "explicitly no credential" at all. Fixed
with a `FROM_ENV` sentinel. A third example was order-dependent on `FakeAdapter.behaviour`,
a class-level accessor other examples mutate. **None of the three was findable by reading**,
and the control run is the only reason they were found before CI.

**Auto-detection was FIXED, not asserted.** T-34's Accept says "a test asserts auto-detect
never selects `:gotenberg`". Written directly that is a test that cannot fail: the fallback
was `Registry.ids.first`, `Registry.ids` is `keys.sort`, and `chromium_cdp` sorts before
`gotenberg` — so the property held by alphabetical accident, and a future `:athena` would
have become the default of every install in the release that added it. Meanwhile
`default: true` had sat in `capabilities.yml` since DoR-5, validated to be on exactly one
engine, and was read by nobody. The fallback now reads it, and an engine the catalogue says
`needs_service` is never auto-selectable — a rule whose test registers `:gotenberg` FIRST
so the accident cannot make it pass.

**THE ONE ARCHITECTURAL DECISION, AND IT WEAKENS A GATE ON PURPOSE — CURATOR, THIS IS THE
ROW TO READ.** `layer_purity.sh` forbids `Net::HTTP` under `render/**`. An engine that IS a
service cannot be reached without a socket, so the choice was never "socket or no socket"
but *"a socket the gate can see, or a socket laundered through a neutral directory it
cannot"*. The second is the two-hop evasion the `charts`/`assets` arms were written to stop
— that gate's own comment says a boundary holding transitively holds only by luck. So the
exemption is **named, scoped to one file, and bounded by its own arm**: `render-network`
fails if any OTHER file under `render/` names `Net::HTTP`, fails if the exempt file STOPS
naming it (a stale exemption is how an allowlist silently permits something later), and
asserts Gotenberg's `convert/url` route is absent from every file that could issue a
request. All four arms were negative-tested, including that documentation may still NAME the
forbidden route — the first version failed on the technical spec's own clause forbidding it,
which is HANDOVER's `<script>`-in-prose lint, met again.
**Recommendation:** accept the narrowing as written. INV-8's subject in technical-spec §11 is
the ASSET path — the renderer must not fetch a document's references on the viewer's behalf
— and this adapter fetches nothing; it POSTs a complete document to an operator-configured
endpoint. If the curator disagrees, the alternative is not a tidier adapter, it is dropping
`:gotenberg`, and that reverses OQ-3.

**AND THEN BOTH INDEPENDENT REVIEWS REJECTED IT, FOR THE SAME REASON, AND THEY WERE RIGHT.**
A fresh reviewer briefed to reject and a UX pass ran separately and never saw each other's
output. Each returned the identical blocker first, which is the reason to believe it:

**THE CHECKS WERE HUNG ON A METHOD NOTHING IN THE SHIPPED PRODUCT CALLED.** `#preflight`
returns a `Result` and is called by `spec/` and by the conformance harness. Both operator
surfaces — *Administration → Render preflight* and
`rake reporter_dashboards:render:preflight` — go through `Render::Preflight#run`, which only
ever rendered a probe document. So the credential check, the version floor and the
JavaScript probe — each one rewritten after MEASURING that its first version could not fail
— could not fire where anybody would see them. Measured by the reviewer, running the exact
command the README prints, against a Gotenberg with no authentication whatsoever:

    render preflight: gotenberg 8.35.0 (OK so far …)   >>> exit code = 0, eight PASSes

Three documents — the README, the compose file and `capabilities.yml` — asserted as shipped
fact that an unauthenticated Gotenberg produces a preflight failure. *Fixed:* the adapter
publishes `#configuration_checks` as data (`{id:, title:, state:, detail:}`), `Preflight#run`
turns them into its own `Check`s and ABORTS on a failure rather than printing eight green
document checks under one red one, and the proof is an example that drives
`PreflightSuite` and `PreflightCommand` — not the adapter method — against a real
unauthenticated listener and asserts a non-zero exit. The `id` is deliberately symbolic,
because it is the part that is a contract rather than prose, which is what
`ReporterPreflightHelper::CHECK_LABELS` keys a locale entry off (E-26 #6's own recommendation).

**AND THE OTHER HALF OF IT: EVERY INSTALL'S PREFLIGHT WENT RED.** Registering `:gotenberg`
at boot put it in `Registry.ids`, and `PreflightSuite` runs every registered engine — so the
rake task the README calls a deploy step exited **1** on every install that does not run an
optional container, with a permanent red row on the admin page that no amount of installing
anything would fix. T-34 had added the `needs_service` rule to `ReportRun#resolve_engine`
and not here. *Fixed*, and the engine is DEFERRED rather than hidden: it gets a report
carrying one `:skip` that names it and says `RRD_ENGINE=gotenberg` is how to check it
deliberately.

**FOUR MORE THAT WERE FOUND BY MEASUREMENT AND ARE FIXED.** Each is worth reading, because
none was findable by reading the file:

| what | how it was found | why nothing saw it |
|---|---|---|
| **`Net::HTTP.start` sent the report and the credential to `$http_proxy`.** Its third positional is `p_addr = :ENV`, so keyword-only calls follow the ambient proxy rather than the configured endpoint. The reviewer stood up a fake proxy and read `Authorization: Basic …` plus the whole multipart report out of it | a listening socket | `URI#find_proxy` returns nil for `127.*`, and every spec and both CI containers are loopback. The first replacement test was loopback too and the mutation SURVIVED it — the fix is asserted twice now, on the argument and against TEST-NET-1 |
| **A credential in the endpoint URL was accepted, never used, and printed.** `http://user:pass@host` authenticates nothing here, and `@endpoint` is interpolated into six failure messages — which reach the diagnostics panel, the scheduled-report failure MAIL, and a persisted `Snapshot` row | constructed | nothing tested a URL with userinfo. Now REFUSED rather than redacted: redacting would keep the silent non-authentication |
| **The asset NAME was guarded and its CONTENT TYPE was not**, though both are header values in the same part. A CRLF produced 14 `Content-Disposition` headers for 13 parts | constructed | `SAFE_ASSET_NAME`'s own comment argues that "the only producer is safe" is a property of the current tree — and the identical argument was not made one line below it |
| **`DEFAULT_ENDPOINT` was `http://localhost:3000`, which is Redmine's own port.** An unconfigured adapter POSTed a probe document, and a credential, to Redmine, got a 404, and reported `:internal` — the code whose comment says it means "a bug here, not an engine fault" | the UX pass, reading | there is no safe default. There is now no default: construction stays total and an unconfigured adapter answers a typed Failure naming `RRD_GOTENBERG_URL` |

**AND THREE MISDIAGNOSES OF THE INV-4 SHAPE, all in the new remediation messages, all
fixed.** A service that was DOWN, one that was NOT A GOTENBERG, and one merely ERRORING each
got the same confident sentence — *"answered the conversion route WITHOUT the configured
credential"* or *"has JavaScript disabled"* — and an instruction that could not help. The
ordering was justified on COST (*"each check is cheaper than the one after it"*), which is
the wrong axis for a diagnostic: **identity before verdict**. A `check_reachable` arm now
runs first and only 200 means JavaScript is off. This is the third time this project has
shipped that shape (E-26 #6 and #7 are the others), and the first time it was caught before
the commit.

**THE REVIEWER RAN 17 MUTATIONS OF ITS OWN CHOOSING AND 13 SURVIVED**, against a harness that
had reported 30 of 30 killed. Choosing your own mutations tests the examples you were already
thinking about — HANDOVER §1 says exactly this and it was still worth measuring again. Three
were proved non-equivalent BY CONSTRUCTION and now have examples: the declared-default
preference (the shipped example compared a String to a Symbol and could never fail), the
retry's deadline (every readiness double raised INSTANTLY, so no time passed and the two
branches were indistinguishable), and **the encoding** — not one byte above 0x7F went through
this adapter in any test, in a plugin that ships nine locales and whose HANDOVER has three
entries on that exact bug.

**AND A THIRD PASS — ADVERSARIAL QA ON THE FIXES — REJECTED THOSE.** 36 mutations of its own
choosing, 12 survivors, and it was right about all of them. Reviewing the fixes to a rejected
change turned out to be worth as much as the original review, which is the reusable lesson:

| what | measured | fixed |
|---|---|---|
| **`validate_endpoint!` RAISED, and the comment above it claimed construction stays TOTAL.** `ReportRun#with_pdf` does a bare `adapter.new` with no rescue above it | `RRD_GOTENBERG_URL=gotenberg:3000` — a missing scheme, i.e. what an operator types after reading the compose file — escaped as an uncaught `ArgumentError` and 500'd the preview page. So did a trailing newline from `--env-file`, a stray space, and surrounding quotes. Only `nil` and `''` had been tested, and only those two were total | yes — `resolve_endpoint` never raises, and eleven values are asserted to build AND refuse in the result |
| **`#$&` in a security regexp is GLOBAL INTERPOLATION.** `SAFE_CONTENT_TYPE`'s character class silently compiled to `[A-Za-z0-9!^_.+-]` | `SAFE_CONTENT_TYPE.source` read off the loaded constant. The QA pass then CONSTRUCTED the danger: with `$&` set to `]|.*` the same literal compiles to a class that closes early and matches a CRLF payload. It happened to be stricter than intended, so nothing legitimate was refused and no test could tell | yes — `\#\$&`, and the compiled class is asserted |
| **`check_reachable` sent the credential, while its comment said "unauthenticated" — so a REFUSED credential reported PASS** | with a wrong password: `reachable PASS · credential PASS · version FAIL "did not answer /version with a version"`. The pre-fix render path said *"the render service refused the configured credential"* — the diagnosis got WORSE | yes — the identity probe is genuinely unauthenticated, and a refused credential is now the credential arm's own named finding |
| **Seven new check ids reached the admin page with no locale key, and the control written to catch exactly that still passed** — it hand-wrote `DOCUMENT_CHECKS.keys + %i[engine degradations]` directly under a comment saying "READ OFF THE RENDER LAYER, not typed out here" | `engine_not_selected` is on EVERY install's default page | yes — `PreflightSuite.emittable_check_ids` derives the set from the registry, seven keys added in nine locales, and the control was NEGATIVE-TESTED (removing one key fails it; it could not fail before) |
| **The deferral's only actionable words were truncated off the rake surface.** `RRD_ENGINE=gotenberg` started at index 120 of a detail cut at 90 | the real command's output | yes — the instruction comes first now |
| **`gotenberg_service_spec.rb` still leaked four constants onto the production namespace**, including the live password, after the sibling file's leak was fixed | `Engines::CREDENTIAL => ["rrd", "s3cret"]` | yes, and an example now asserts the absence |
| **The proxy test's behavioural half was vacuous, and its own mutation proved it.** `192.0.2.1` re-entered the trap it was written to escape: `no_proxy` names `::1`, URI reduces that to host `1`, and the rule is `end_with?(".1")` | the mutation was killed by the ARGUMENT assertion alone | yes — `192.0.2.9`, plus `find_proxy` asserted non-nil as a precondition so it cannot go vacuous a third time |
| **`version_within` had no test at all** — four mutations survived | reverting fix 8 wholesale was invisible | yes — four examples |
| **A published check with no `:state` gave `failed? == false`** (a broken check reading as a passing one) and then 500'd the page on `state_class(nil)` | constructed | yes — an unknown state becomes a FAILED check naming what was published |

**AND CI WAS RED FOR FIVE COMMITS AFTERWARDS, WHICH IS THE PART WORTH READING.** T-34 was
reported complete on local evidence — gates, four Redmine branches, three engines, the
corpus, a regenerated matrix — and CI was red on the first push and stayed red through four
more. Twenty-five of twenty-six jobs were green every time; the one that failed was the leg
this task added. Three of the four causes were defects in the change, and one of them would
have reached operators:

| what | how it was found | why local runs could not see it |
|---|---|---|
| `VAR=x docker compose up -d` sets the variable for ONE invocation, and every later `docker compose` call re-parses the file. The container came up; the next call died | CI | nothing locally ran two compose commands in separate shells |
| `aquasecurity/trivy-action@0.28.0` DOES NOT EXIST — I guessed a version tag I could not verify from this environment | CI | the workflow had never run |
| **The compose file's own "if Redmine is not in Docker" advice does not work.** Keeping `internal: true` and adding `ports:` publishes NOTHING — docker accepts it, starts a healthy container, and binds no port (`.NetworkSettings.Ports` is `map[3000/tcp:[]]`) | CI, then reproduced locally | I wrote the advice and never followed it; every local test used a peer container on the same network |
| Chromium could not start in the hardened container on the runner: `chrome_crashpad_handler: --database is required`. `read_only: true` leaves HOME unwritable and docker's `/dev/shm` is 64 MB | CI, after adding a step that dumps the container's own log | green on this machine with the identical file, image and spec — still unexplained, and the fix is correct regardless |

**THE FIRST TWO ATTEMPTS AT THE LAST ONE WERE WRONG, AND THE DIAGNOSTIC IS WHAT SAID SO.**
The `mode=1777` hypothesis looked compelling — a 500 with no access-log line, only on
requests carrying a body, on a read-only container writing uploads to a tmpfs — and the
write probe added alongside it answered `WRITE-OK` against `drwxrwxrwt`. Without that probe
the next step would have been to argue about tmpfs modes. **A diagnostic that can refute
your hypothesis is worth more than one that can only confirm it**, and this one cost four
lines.

**RECORDED, NOT FIXED. Each with what was measured.**

| # | What | Measured | Recommendation |
|---|---|---|---|
| 1 | ~~**`verification` is `pending`, not `corpus`**~~ **CLOSED 2026-08-11 — the curator promoted it.** `config/capabilities.yml` says `corpus`, and the matrix was **regenerated from a run in which all three corpus engines executed**, which is what G9 requires and is also what deleted the *"Columns that are not measurements"* section: with nothing left at `pending`, `Matrix.footer_section` emits nothing. The trade was accepted knowingly and is written into the file it is paid in — a Gotenberg that will not start in `render-smoke` is now a HARD failure, so that job depends on the registry serving the pinned digest | CI run **31408759956** (2026-08-10) and **31469385598** (on `ee22bd6`): `19 pass, 0 fail, 1 skip, 0 harness error`, ZERO occurrences of "gotenberg is not available here", alongside `spec/render` including the real-container spec and the job's own control probes (open 415, authenticated 401). Re-measured locally 2026-08-11 against two real containers: gotenberg **19/0/1**, chromium_cdp **20/0/0**, wkhtmltopdf **18/0/2** (patched qt) — 89 examples, 0 failures | — |
| 2 | ~~**There is no install-wide way to SELECT `:gotenberg`.**~~ **CLOSED 2026-08-11 — FR-50 shipped.** `Render::EnginePreference` + a `render_engine` setting, coerced against the REGISTRY (an id it does not hold is dropped with a log line, never stored, FR-15) and offered from the registry with one generated line per engine — what it needs installed, whether it needs a service, whether it renders offline, what it cannot do — straight out of `capabilities.yml`, per §5.2 clause 4. Precedence: the template's hint, then this installation, then the declared default, then any engine needing no service; the hint wins because a claim about a DOCUMENT is narrower than a claim about an installation, which is also what keeps a template portable. An engine that `needs_service` IS selectable — T-34's rule is that auto-detection never picks one FOR an install, and this is the install picking — and the page says what that costs. **`PreflightSuite` stops deferring the SELECTED engine**, which is the third place that rule has had to be written (E-27's own words) and without it the skip's sentence would be false on exactly the installs that chose one | 27 DB-less examples for the value object, 5 precedence examples in `report_run_spec`, 5 suite examples, 9 full-app examples for the round trip and the partial; **16 mutations, 16 killed** after the first run's two survivors were traced to a redundant sort and a guard with no behavioural signature — both now asserted where the claim is made | — |
| 3 | ~~**A `Failure` code for "the engine is misconfigured" does not exist**~~ **CLOSED 2026-08-11 — the curator added it.** `:engine_misconfigured` is in the closed set with the distinction written where it is decided: the engine is THERE and refuses to be used as configured, so the remedy is an operator's and no retry changes the answer. Six emitting sites, all in the Gotenberg adapter (no endpoint, no credential, a refused credential, a service not enforcing one, the JavaScript-disabled VERDICT, and the render path's 401/403). **Three neighbours deliberately do NOT move** — reachability, transport, and any probe that could not be COMPLETED — because a wrong address and a dead service are not distinguishable from the caller, which is HANDOVER's identity-before-verdict entry. **THE "locale keys ×9" IN THE DECISION WAS BROADER THAN THE TREE, and the measurement is the reason there are none:** no user-facing surface keys a locale entry off a `Render::Failure` code. The diagnostics panel, the failure mail and the failure PDF print the symbol beside a localised `label_reporter_report_diagnostic_code`; `error_reporter_adhoc_*` and `error_reporter_snapshot_*` key off DELIVERY and SNAPSHOT codes, not render ones. Localising the code vocabulary is §Findings **S-17**'s own task — and note that S-17 itself quotes two different counts for its own scope, so no number is repeated here; adding nine keys for one code out of that set would build half a mechanism | `rg` over `app/`, `config/locales/en.yml`: zero per-code keys for `Failure::CODES`. **8 mutations, 8 killed** — each of the six sites reverted individually, plus moving the new code to `preflight_failure`'s DEFAULT (which erases the boundary and kills the three must-not-move rows), plus deleting the code from the closed set. The seven-row classification table is scripted from a MEASURED locked service (401 unauthenticated), not from the friendly `healthy` double that made a memo mutation unkillable on 2026-08-11 | — |
| 4 | **The retry after a readiness timeout abandons a request the container keeps rendering** for up to its own `--api-timeout` | Chromium's concurrency in Gotenberg 8 is 6 | Bounded and self-clearing, and the alternative (waiting out somebody else's flag file) makes the readiness bound a property of their configuration. **Recommend** `--api-timeout=60s` in the example compose, which it now carries, and watching this if a report fleet ever runs readiness-timeout-heavy templates |
| 5 | ~~**The version probe is not bounded by the request's deadline.**~~ **CLOSED** — it is now, and has four examples. This row is struck through rather than deleted because the recommendation it carried ("leave it") was wrong and the adversarial pass is what said so | `timeout_ms: 500` took 3 001 ms | — |
| 6 | ~~**`:gotenberg` cannot be diagnosed from the ADMIN PAGE at all.**~~ **CLOSED 2026-08-11** — the preflight route takes an `engine` parameter and the page a selector built off `Registry.ids`; naming an engine runs its real checks (credential included) exactly as `RRD_ENGINE=<id>` does, an unknown or names-nothing value is a flash error naming the known ids (never a 500, never a silent default run), and the deferral's detail offers the selector as well as the rake variable. This is still FR-50's neighbour, not FR-50: no install-wide default selection exists (row 2 stands) | five functional tests, incl. "an unknown engine name constructs no adapter"; the dropped-selector, ignored-parameter and never-matching-rescue mutations each red | — |
| 7 | **`PreflightCommand` exits 0 when EVERY engine is deferred**, contradicting its own documented `NOTHING_TO_RUN = 2`. **STILL OPEN 2026-08-11 — the curator asked for a recommendation before deciding, and it is below** | **RE-MEASURED 2026-08-11**, not read: `Registry.isolated { register(:gotenberg) }` then `PreflightCommand.new.call` → **exit 0**, and the sentence a human reads is `render preflight: gotenberg not checked (OK so far — 1 check(s) could not run, 0ms)`. So a deploy step is told "fine" and a person is told "OK so far" about a run that verified nothing. Unreachable in the shipped 3-engine tree (two engines need no service), and reachable the moment a tree has only service-backed engines | **Recommend YES, with one condition and one consequence.** *Why yes:* the code's documented meaning is "nothing was verified", that is exactly what happened, and this repository's oldest defect class is a green run that checked nothing (INV-7). The cost is one condition in `#call` and one README bullet. *The condition:* keep the DEFERRED REPORTS in the output. Exit 2 with a blank page would replace one bad answer with another; the skip rows and their `RRD_ENGINE=<id>` remediation are the only actionable thing on that surface. *The consequence to accept:* 2 is non-zero, so an install whose only engines need a service goes from a green deploy step to a red one — which is correct (nothing was verified) and is a behaviour change on a documented interface, hence the curator's call. *And the reason the urgency is lower than it looks:* **FR-50 removes the realistic instance of this**. Once an install can SELECT an engine, the selected one is in the preflight's default set even when it needs a service — selecting it is the decision the deferral was waiting for — so the practical "the engine this install actually renders with was never checked" case is closed by that change rather than by this one. What remains for row 7 is the honest-exit-code argument on a tree nobody ships yet |
| 8 | ~~**`RRD_ENGINE=''`, `'  '` and `','` silently mean "the default set"**~~ **CLOSED 2026-08-11** — a NON-EMPTY selection that parses to no id raises `UnknownEngine`, so the rake task exits 2 and the admin page answers the same flash error as a typo. `nil` and `''` still mean the default set: unset and `VAR=` are how an environment says "nobody selected", and refusing those would turn every deploy script that does not export the variable into exit 2 | six command examples; exit 2 for `','` also read off a real process by `script/render_preflight_exit_codes.sh`; guard-inert and cut-moved mutations both red | — |
| 9 | ~~**A credential in the endpoint's QUERY STRING is still accepted**~~ **CLOSED 2026-08-11, and the first fix was rejected in review for the right reason** — a parsed-URI check (`uri.query`) never fires for `gotenberg:3000/?token=abc`, which parses OPAQUE with `query: nil`, and the value then fell to arms whose messages interpolated it. The shipped rule is stronger than "refuse `?`": the RAW string is tested for `?`/`#` before the parser gets a say, and NO refusal message interpolates the value or the parser's message (which repeats it) — so the schemeless-userinfo spelling stopped leaking too. **Residual, recorded (adversarial QA, held to MINOR and pre-existing):** a percent-encoded `%3F`/`%23` is not decoded, and a secret written into the PATH is preserved and shown — the path is the endpoint's identity (`--api-root-path`), so the refusals cover the slots credentials ride in, not every byte sequence an operator could regret | `hunter2` demonstrated in a preflight message via the opaque parse and via the `InvalidURIError` rescue, then asserted absent for five hostile spellings; guard-inert and `&&`→`\|\|` mutations red | — |
| 10 | ~~**`/version` is fetched twice per preflight**, and configuration checks report `duration_ms: nil` so the page prints "0 ms"~~ **CLOSED 2026-08-11** — a version-shaped body is memoised (token only, not the body) off the identity and credential probes, so a healthy preflight fetches `/version` once per question; every configuration check carries its own measured `duration_ms` | the fetch-count example had to script a REAL locked service (401 to the unauthenticated probe) — under the `healthy` double, which answers that probe 200-with-version as no real locked Gotenberg does, deleting the credential-probe memo SURVIVED; five memo/duration mutations red after the rewrite | — |
| 11 | ~~**No HTTPS coverage anywhere**, and CI never runs the preflight rake task~~ **CLOSED 2026-08-11** — `use_ssl` is pinned by an argument assertion AND a behavioural one (a TLS ClientHello, byte `0x16`, is what reaches a plaintext listener for an https endpoint; both the surviving `use_ssl: false` mutant and its `true` twin now die), and render-smoke runs `script/render_preflight_exit_codes.sh` against the job's two live Gotenbergs: exit 0 (authenticated), 1 (open service, credential configured), 2 (typo) and 2 (row 8's names-nothing) each read off a real process — AND each arm pins the sentence naming its intended cause, because an adversarial QA pass demonstrated the credential arm green with the open service DEAD ("nothing answered" is also exit 1) and green on a crashed driver: a bare exit-code assertion was this project's "cannot fail" defect rebuilt inside the artefact meant to end it. One deviation, recorded: the RAKE task itself still cannot run there (render-smoke has no Redmine, and `:environment` needs one), so the contract runs through `script/render_preflight_standalone.rb` — the same `PreflightCommand.load_engines!` + construction the rake task now shares, with only the `Setting`-derived base URL missing. The rake file's own glue stays covered by `test/unit/render_preflight_rake_test.rb` | measured locally against gotenberg 8.35.0 in two real containers (all four codes as specified); the script negative-tested — swapped topology reports FAIL and exits 1, missing env refuses with exit 3 | — |

**E-26 · F-16's THREE REVIEWS: what was fixed, and the ELEVEN THINGS THAT WERE NOT.**
2026-08-09, three fresh subagents (reviewer, adversarial QA, UX). Two of them independently
found the same two blockers, which is the reason to believe them. **Everything below was
REPRODUCED with a probe or a mutation, not read.** The fixed items are in the commits; this
entry exists for the eleven that are recorded rather than closed, because a curator has to
decide several of them and because an unrecorded measurement is a measurement nobody will
take again.

**Fixed here** (see commits `0202f23`, `84f9a69`): an asset refusal answering **HTTP 500**
because `outcome_status` read a closed set through an `else`; `policy_refusal?` blaming the
asset policy for **five of seven** refusal causes, so an administrator was told to enable
egress for a missing file — with the spec that "covered" it hand-writing a reason string the
resolver cannot emit; **`MAX_REFERENCES` never applied inside a stylesheet** (3 200 nested
references → 3 201 inlines in 11 s, linear, one `find_by` *and* one `binread` each); a
raising `engine#capabilities` **escaping as a 500** from an asset-free report; the **HTML
panel still showing blank images** while its CSP comment claimed otherwise; and four tests
that could not fail.

**THREE OF THE ELEVEN WERE CLOSED IMMEDIATELY AFTERWARDS (rows 1, 2 and 3 below), because
two of them were security-shaped and the third was the only UNVERIFIED gate.** 8 mutations,
8 red, control green — and **two of the eight survived the first round**, both because the
test could not discriminate rather than because the code was wrong: widening the locked-actor
guard to `!active?` survived an example whose only assertion was `assert_nothing_raised`, and
deleting the SIZE from the budget refusal survived a fixture where the size and the limit both
rounded to `0 MB`. Both rewritten. Their rows are struck through and kept, because the
measurement is what the fix rests on.

**NOT FIXED — the curator's, or a later task's. Each with what was measured.**

| # | What | Measured | Recommendation |
|---|---|---|---|
| ~~1~~ | **CLOSED.** ~~A mapper-sourced path gets no containment check.~~ `AttachmentMapper#contained` now realpaths the diskfile against `Attachment.storage_path` — in the MAPPER, not `LocalStore`, because the root is Redmine's and `assets/` may not name it. **A mapper-sourced path gets no containment check.** `LocalStore#real_path` returns immediately for `source == :mapper`, so a symlink inside `Attachment.storage_path` pointing outside it is read and inlined | `symlink outside root => ok=true, OUTSIDE BYTES INLINED = true`. `/etc/passwd` was stopped only by `ContentTypes.for_path` on the realpath — i.e. by "must have a typeable extension", not by containment | Deliberate and documented ("the mapper IS the decision"), and it needs write access inside the attachment store, so it is defence-in-depth rather than a primitive. But `local_store.rb` calls the symlink case "the one nobody remembers" and this is the branch that skips it. **Recommend** containment against `Attachment.storage_path` for mapper results, which costs one `realpath` |
| ~~2~~ | **CLOSED.** ~~A locked user resolves attachments.~~ Refused on `locked?` and deliberately NOT on `!active?`: `AnonymousUser` fails the second, and refusing it would stop a public report embedding a public project's attachments — a regression wearing the shape of a rule. **A LOCKED user's identity still resolves attachments.** `Attachment#visible?` → `attachments_visible?` → `allowed_to?` never consults `User#active?` | `LOCKED dlopper on his own private issue attachment => RESOLVED` | `AttachmentsController#download` is unreachable for a locked account because authentication rejects it first; the report path has no such gate. `ScheduledDelivery` guards `owner&.active?`, but `AdhocDelivery`, `Snapshot` and the controller do not. **Recommend** the liveness check where the actor is chosen, not in the mapper — it is the same shape as T-24's `User.active` finding |
| ~~3~~ | **CLOSED — G6 now has its evidence.** ~~Peak memory is per document.~~ `ReportRun::MAX_RUN_ASSET_BYTES` (128 MiB) bounds the resolved bodies a single run may hold, on both the PDF and HTML paths, refusing with `:resource_limit` and naming both numbers. The shared encode memo was NOT added and is not needed for the bound: each document needs its own copy of the bytes, so a memo saves CPU rather than memory. **Peak memory is per document, not per run.** `bind_assets` builds every `DocumentRequest`, each with its fully inlined body, before `render_all` is called; `Resolver::State` — and so `MAX_TOTAL_BYTES = 32 MiB` — is per `call` | all requests built before the first render: `true`. Worst case at defaults: 50 × 32 MiB = **1.6 GiB resident**, plus the base64 memo, and one logo referenced by 50 per-record documents is encoded 50 times | **Recommend** a per-RUN byte budget in `bind_assets`, and a shared encode memo across sections. G6 currently has no evidence for this path |
| 4 | **`asset_document_cap` is unreachable through `ReportRun`.** Over-cap references are `refuse`d, which makes the resolution `refused?`, which hard-fails the run — so the degradation is never rendered | 600 same-origin refs → `ok=false code=:asset_unresolved` | Either the cap should degrade rather than refuse, or the degradation should be deleted as dead. **A curator decision**, because it is the difference between "your report is too big" and "your report is refused" |
| 5 | **`file:` URLs pass through untouched.** `Reference::IGNORED_SCHEMES` includes `file`, so `<img src="file:///etc/passwd">` stays in the body verbatim and local-file resolution is the engine's business | `file scheme ok=true` | Pre-existing T-33 classification; F-16 is what gives it a call site. wkhtmltopdf's `--enable-local-file-access` behaviour is version-dependent. **Recommend** a conformance fixture rather than a code change |
| 6 | **The user-facing asset message is English in all nine locales.** `AssetBinding#message_for` builds prose in `lib/`, and the failure MAIL prints no headline at all — only `code` and `message` | — | CLAUDE.md §10's letter is kept and its purpose missed. This is the first message whose *content is the remedy*. **Recommend**: `AssetBinding` returns `(key, args)`; minimum, add `reporter_diagnostic_headline` to `scheduled_report_failure.{text,html}.erb` |
| 7 | **The message points somewhere that does not show what it promises.** It says "the reason for each is in the render diagnostics for this correlation id"; `_diagnostics.html.erb`'s own comment says `Diagnostic#detail` is deliberately NOT printed | `from_asset_refusal` puts the per-refusal reasons in `detail`; nothing renders it | **Recommend** rendering `Resolution::Refusal#to_h` in the panel — url/usage/classification/reason are all safe by construction — or changing the sentence. As it stands it is the only route by which an author could learn WHICH of five causes they hit |
| 8 | **Neither screen says a refused asset kills the report.** The settings page describes how assets are *obtained* and never what happens when they cannot be; the template editor has an `em.info` for every field except this | — | The README covers it well and is linked from neither. **Recommend** one sentence on `text_reporter_asset_policy_info` and one `em.info` in `_form.html.erb`, nine locales each |
| 9 | **Asset degradations are dropped on the failure path.** `failed(...)` passes `degradations: diagnostics.degradations`, so a run where section 1 collapsed an `srcset` and section 2 hit a CDN loses the first fact — and the panel renders on the failure page too | read, not probed | One-line fix (`failed` gains a `degradations:` keyword). Left because it touches every `failed` call site and this change has already grown twice |
| 10 | **E-25's fix is proven at the helper only.** The 500 was a VIEW failure through `_degradations.html.erb`; the regression test is an `ActionView::TestCase` calling the helper directly | 12 examples green | HANDOVER §1's own `include_all_helpers` lesson: *"the integration test found it"*. **Recommend** a controller test that renders `#show` for an outcome carrying a `Render::Degradation` |
| 11 | **The wiring test leaks attachment blobs into the Redmine checkout.** Four tests call `Attachment.create!` after `set_fixtures_attachments_directory`; transactional fixtures roll back the ROWS and the bytes stay | `redmine/test/fixtures/files/2026/08` held **227 blobs** | **Recommend** `set_tmp_attachments_directory` for the tests that create attachments, keeping the fixtures directory only for the ones that READ attachment 16 |

**AND ONE PROCESS FAILURE, recorded because it reached the remote.** `d57a744` committed a
reviewer's mutation — `request_geometry` hardcoded to A4/portrait with `margins_mm` dropped —
because a stop hook prompted a commit while three review subagents were mutating the tree and
`git add -A` cannot tell a mutation from an edit. The mutation was already covered; the
verification of the COMMIT was seven greps in two files, reported as "the committed source is
unmutated", which was broader than the evidence. Reverted in `bfc55b9`. **Never stage while a
subagent is live**; if a commit cannot wait, stage explicit paths the agents do not touch, as
`a44c769` did. In HANDOVER §1.

**S-17's INVENTORY IS NOW SHORT BY THE WHOLE RENDER LAYER.** Its "what is left" list names
ten Liquid-side codes. Before E-25 a `Render::Degradation` never reached the lookup — it
raised — so the render vocabulary was never in scope. It is now, and F-16 shipped keys for
`legacy_engine` and the five `asset_*` codes; what remains unlisted is `readiness_timeout`,
`asset_unresolved` as a *degradation*, and the `Capabilities.negotiate` misses.

**E-25 · THE DEGRADATION LIST TOOK TWO VOCABULARIES AND UNDERSTOOD ONE, SO EVERY
`wkhtmltopdf` RENDER 500'd THE PAGE.** Found while wiring F-16, 2026-08-09 — pre-existing,
latent since T-31 added the localisation, and **fixed here** because F-16 puts a second
producer onto the same path.

`ReportRun::Outcome#degradations` is a concatenation of **two classes**, and they are
separate on purpose — `liquid/diagnostics.rb` argues it at length: *"the collection was
truncated at 5 000 issues" and "the browser could not fetch a font" are fixed by different
people*.

| class | interface |
|---|---|
| `Liquid::Diagnostics::Degradation` | `code`, `detail`, `data`, `count` |
| `Render::Degradation` | `capability`, `detail` — **and nothing else** |

`TemplatesHelper#reporter_degradation_text` read `#code`, `#data` and `#count` off both.
Measured rather than read:

    Render::Degradation.new(capability: :legacy_engine).respond_to?(:code)  -> false

`reporter_degradation_sentence`'s rescue lists `I18n::MissingInterpolationArgument` and
`ArgumentError`, so the `NoMethodError` escaped the helper and the view. And
`_degradations.html.erb` is rendered **unconditionally** by both `#show` and `#preview` —
its own comment says *"wkhtmltopdf stamps `legacy_engine` on every render by design"*, which
is exactly the object that has no `#code`. So the one engine the project promoted to
`verification: corpus` on 2026-08-06 could not have its output looked at in the UI.

**Why no test saw it.** There is no DB-less half for a helper, and the Minitest half had no
helper test for this file. `spec/render` proves `Render::Degradation`'s shape and
`spec_liquid` proves the other one's; nothing put them in one list, which is the only place
the two shapes meet.

*Fixed* in the helper, not on `Render::Degradation`: giving the render type a `code`, a `data`
and a `count` it has no use for would merge the two vocabularies the gate and the design keep
apart. The view is the one place that must speak both, so it is the one place that normalises
them. `test/unit/reporter_dashboards_degradation_helper_test.rb` walks both vocabularies, the
mixed list, and every diagnostic origin.

**The general shape, and it is the third time:** a `case` with an `else`, or a duck-typed
call, over a set that is closed somewhere else. The same commit removed the other instance —
`reporter_diagnostic_headline`'s `else` meant "engine", so F-16's new `:assets` origin would
have been headlined *"The render engine could not produce this document"* on the interactive
panel and correctly in the failure PDF. `Diagnostic::ORIGIN_LABEL_KEYS` is now the one map
both readers `fetch` from, and a spec asserts it is the SAME OBJECT rather than a matching
copy.

**E-23 · T-28 INCREMENT 2 WAS REJECTED BY ITS INDEPENDENT REVIEW, AND THE TWO BLOCKERS WERE
BOTH "THE TEST CANNOT FAIL" RATHER THAN "THE CODE IS WRONG".** 2026-08-09, fresh subagent.
Worth recording in full, because the shape recurs: every defect below sat behind a green
suite, and three of them were asserted in comments and sold in the README.

**BLOCKER 1 — the `max_uses` concurrency test could not fail.** Its own comment said it
needed two connections *"because on one connection the second `update_all` simply sees the
first one's write and the test would pass against the broken implementation too"*. Measured,
in that file's configuration:

    use_transactional_tests=true
    distinct_connection_objects=1  backend_pids=[3693]

`use_transactional_tests` PINS the pool to the fixture connection so every thread can see
uncommitted fixture data, so `with_connection` handed back the same session both times. The
review then swapped `use!` for the exact lost update the class exists to prevent and the
suite stayed green.

*Fixed:* `test/unit/reporter_dashboards_share_link_concurrency_test.rb`, a separate class
with `use_transactional_tests = false` (it is a per-class setting), racing `ROUNDS = 10`
independent single-use links through a real two-`Queue` barrier, asserting per round that the
two backends differ. Re-measured against the lost-update implementation: **20 successes where
10 are possible** — every round collided, so the discriminator is decisive rather than
timing-dependent.

**BLOCKER 2 — INV-1 was untested, and the review's own mutation could not show it.** The
review mutated `as(actor)` → `as(::User.current)` and found it survived. **That mutation is
equivalent, and the reason matters:** `as` is NOT what holds INV-1 here. Every visibility
decision is threaded explicitly — `ReportScope.build(actor:)` starts from
`Issue.visible(actor)`, and the drops refuse to resolve without a `RenderContext` rather than
reading `User.current` (`record_drop.rb:14-17`). Swapping the ambient user changes nothing
the render reads.

The mutation that DOES discriminate is the argument: `actor: render_as` → `actor:
created_by`. Under a template emitting `{{ issues.size }}`, with two identities that see a
different number of issues, it now fails loudly — `"COUNT=[7]" not found in … COUNT=[6]`.
**The finding was right and the mutation was wrong**, which is worth knowing: a surviving
mutation is evidence of a coverage gap OR of an equivalent mutant, and the two are told apart
by constructing the observable difference, not by reading.

**MAJOR 3 — a link outlived and served an expired snapshot**, measured at 300 days with a
`200`. `expires_at` on a document was read by a validation and by nothing else, which made
the "mandatory, bounded TTL" the spec insists on **decorative in the very commit that first
created rows** — and the commit message claimed the opposite. Fixed at both ends:
`Document#servable?` refuses an expired snapshot at request time, and
`ShareLink#expiry_within_the_snapshots_own` stops the bad link being created. Both are
needed: the validation cannot help a link made before it existed.

**MAJOR 4 — there was no purge task**, so the TTL had no runtime effect at all. Now
`reporter_dashboards:documents:purge`, with `RRD_DRY_RUN`, and tested through rake rather
than through the model — a purge task's success and its absence look identical from outside,
which is exactly the failure mode a cron entry has.

**MAJOR 6 — a comment claimed a control that does not exist:** *"THE TOKEN IS NOT LOGGED"*,
refuted in one measurement (Rails' request logger has already written the path). This is the
third time this project has shipped a citation stronger than the truth (T-32, T-24, now here),
and it is why the rule is worth restating: **a cited control that does not exist is worse than
no comment.** Rewritten to the narrow true claim — do not make it worse — pointing at S-27.

**MAJOR 7 — a `HEAD` request spent a `max_uses` slot and delivered nothing**
(`head_status=200 body_bytesize=0 use_count=1`), so a mail scanner or a link unfurler burned
a single-use link before its recipient clicked.

**MAJOR 8 — an unbounded filename**: a legal 245-character template name produced
`attachment_failed: File is too long`, which is a nonsense message for "your report has a long
title". **MAJOR 9 — `capture` raised `ActiveRecord::RecordInvalid`** for a bad `expires_at`,
past every caller written against `Result`, including the README's own recipe; a PAST expiry
was accepted and stored a snapshot no link could ever serve. **MAJOR 10 — a revoked link was
still an unauthenticated unbounded write endpoint** (20 requests → 20 rows of attacker-chosen
`User-Agent`); refusals are now collapsed per reason per minute while successes never are.

**What was NOT accepted, with the measurement:**

* **MAJOR 5, the token in the sign-in redirect.** Real, and it opens no surface the design
  does not already have: the token is a bearer credential IN A PATH (S-27), so it was in
  `production.log`, in the browser's address bar and in its history one request earlier. The
  redirect buys the legitimate holder the thing that makes a private link usable. **Pinned by
  a test that asserts the token IS in the `Location`**, so the decision is recorded rather
  than rediscovered.
* **The 1-in-11 `PG::TRDeadlockDetected` flake.** Not reproduced in 10 further seeds after
  the thread test moved out of the transactional file, which is consistent with that test
  having been the cause but is not proof.

**Round-2 mutations: 15, all killed** — including all seven the review found surviving. The
review's own harness note is worth keeping: it ran three kills alongside seven survivals,
which is what made the survivals evidence rather than a broken runner.

**~~S-28~~ · CLOSED by curator decision, 2026-08-09, in three parts.**

1. **FR-54 → NARROWED (option 2).** *"option 2, don't leak info"*. A share link authorises
   ONE DOCUMENT and grants nothing it points at; a referenced attachment stays behind
   Redmine's own permission check. `functional-spec.md` FR-54 and `technical-spec.md` §7b.1
   are edited to say so, and both name the consequence rather than burying it.
2. **FR-62 → AMENDED.** *"no, permissions will do"*. The switch is a role permission plus a
   per-link choice; the per-template veto was considered and declined. `functional-spec.md`
   FR-62 and `technical-spec.md` §7b.6 edited.
3. **THE BLANK-IMAGES GAP IS *NOT* CLOSED, AND THE CURATOR ASKED FOR IT TO BE FIXED** —
   *"but fix the blank images issue"*. That is **F-16**: `Assets::Resolver` and
   `Render::AssetBinding` are complete, correct and tested, and NOTHING CALLS THEM, so a
   report referencing an image by URL renders it blank in every output, shared or not.
   **It is not done here** — wiring it means `ReportRun` must know the resolved engine's
   CAPABILITIES before it builds the `DocumentRequest`, which is an ordering change plus
   its own review round. It is the headline item of the next session, and T-33 owns it.

**The `covers:` string on `publish_…` was also corrected**: it repeated the spec's
"per template" wording, and an administrator reads that line on the roles screen.

The original finding follows, kept because the measurement is what the decisions rest on.

**S-28 · FR-54 IS **NOT** SATISFIED, THE COMMIT THAT SAID IT WAS CITED A CONTROL WITH NO
CALL SITE, AND T-28 IS THEREFORE NOT COMPLETE.** Found by the independent review of
increment 3, 2026-08-09. **This is the retraction of a claim I made twice — in `e50bf6b`'s
message and to the curator in conversation — so it is written out in full rather than
softened.**

**The claim:** *"`Assets::Policy`'s default `:bundled` mode rewrites a same-origin Redmine
URL to disk and NEVER fetches it, so the PDF a recipient receives is self-contained"*, and
therefore FR-54's scoped attachment URLs are unnecessary because no URL is issued.

**The refutation, measured.** `Assets::Resolver` and `Render::AssetBinding` have **no
production call site at all** — only their own definitions, comments and specs:

    $ grep -rn "AssetBinding" --include=*.rb app lib
    lib/…/assets/resolution.rb:9      # a comment
    lib/…/render/asset_binding.rb:37  # the definition
    lib/…/assets.rb:49                # a comment

`ReportRun#document_request` (`reporting/report_run.rb:410-418`) builds
`DocumentRequest.new(body: section.body, …)` directly and passes no `assets:` at all. Through
a real render on the share-link create path the review measured:

    PDF contains '/attachments/': true
    sample: ["src=\"/attachments/download/1/error281.txt", "href=\"/attachments/download/1"]

So a live, unrewritten same-origin reference **does** survive into the bytes a share link
serves. The asset policy is real, correct and tested — and nothing calls it.

**Two separate defects, and only one is new.** The unwired asset layer is PRE-EXISTING and
already recorded as **F-16** (*"nothing consumes `DocumentRequest#assets` yet"*). What T-28
added is a **false citation resting on it**, which is the defect class CLAUDE.md names and
which this project has now shipped **four** times (T-32, T-24, increment 2's *"THE TOKEN IS
NOT LOGGED"*, and this). The rule earns restating: *a cited control that does not exist is
worse than no comment* — and the reason it keeps happening is that the control genuinely
exists as CODE, so a reader checking the citation finds a real file and stops.

**What is actually true today, and it is a much narrower claim.** A referenced attachment
does not reach the recipient, but not for the reason given: the renderer is never handed a
session credential (INV-8), so an `<img src="/attachments/…">` simply fails to load, and an
`<a href>` survives as a relative link annotation that resolves against nothing. **Nothing
leaks.** But "the exposure is nil today because the fetch fails" is not "attachment URLs are
scoped to the link, and expire and revoke with it", which is what FR-54 asks for.

**Two tests were written for FR-54 and neither tests it.** One asserts the endpoint ignores
extra parameters; the other asserts core refuses an anonymous visitor at
`/attachments/:id`. Both are worth keeping and neither is about FR-54. They are relabelled
rather than deleted.

**What the curator owes: a decision, because I cannot close this honestly.** Three options,
and the first is the only one that delivers FR-54 as written:

1. **Wire the asset layer** (F-16's work) and then scope the resulting URLs to the link.
   Real work, and it lands in T-33's territory rather than T-28's.
2. **Narrow FR-54** to what the snapshot arm can honestly promise: *a share link authorises
   one document and grants nothing it points at*, held by INV-8 plus core's own permission
   check. That is a spec edit, not a code change — and it is a genuine weakening, so it is
   the curator's to make and not mine.
3. **Leave FR-54 open** and mark T-28 complete-except-FR-54.

**Until one is taken, T-28's `Accept:` line *"attachment URLs scoped to the link and revoked
with it"* is UNMET, and the status row says so.**

**E-24 · T-28 INCREMENT 3'S REVIEW REJECTED IT: FOUR SCOPING AND IDENTITY GUARDS HAD NO
TEST, AND TWO ORDINARY FORM VALUES LEFT DURABLE STATE BEHIND ON A *FAILED* REQUEST.**
2026-08-09, fresh subagent. Eight mutations, three killed and **five surviving**, each
demonstrated non-equivalent by constructing the observable difference — which is the
discipline E-23 asked for and got.

| what was untested | what the mutation did |
|---|---|
| `render_as: User.current` (INV-1) | rendered as the TEMPLATE'S AUTHOR while still recording the sharer — measured `COUNT=[7]` where the sharer sees 6, so the sharer received private issues **and** the audit column lied |
| `find_template`'s project scope | an actor with `share_…` in project A listed project B's links, `purpose` included |
| `index`'s `for_template` | the list showed another template's links |
| `revoke_all`'s `for_template` | "revoke all for this report" revoked the actor's links **installation-wide** |
| the revoke button's `revocable_by?` | drew a button for everybody; the forged POST is still refused, so this is UX rather than a hole |

**And two ordinary values wrote durable state on a request that then failed.** A `purpose`
of 256 characters — legal on the form, refused by the model — drove a **full PDF render, a
`Document` row and an `Attachment` on disk** before `mint` rejected it: `DOCS delta=1 LINKS
delta=0 ATT delta=1`. With no link, nothing could ever reach those bytes, and
`documents:purge` collects only EXPIRED rows, so they sat for 37 days (357 at the cap),
repeatable without bound by any member holding `share_…`. `max_uses=99999999999` did worse:
an uncaught `ActiveModel::RangeError` — a **500** — and an orphan on the way out.

**All fixed**, and the ordering is the fix rather than a validation: every field is checked
**before** the render, because FR-15's "dropped rather than stored" protects nothing if the
expensive half has already run.

**Three lessons worth keeping, all of them about tests rather than code:**

* **A test can pass because a DIFFERENT guard fired.** My first test for the project scope
  never made the template visible to the actor, so it 404'd on visibility and the scope
  mutation survived it. The precondition is now asserted.
* **A test can miss because the action does not map the permission.** My existence-oracle
  test used `#index`, which `publish_…` does not map, so Redmine's `authorize` refused first
  and the guard order was never reached. Moved to `#new`.
* **THE MIRROR TRAP CAUGHT ME ONCE MORE, AND IT LOOKED LIKE A REAL FAILURE.** After the last
  mutation was reverted I ran the full suite without re-mirroring, so it exercised the
  MUTATED controller and reported one failure. `diff` between the two trees is now part of
  the run: `845 runs, 3705 assertions, 0 failures` only after the mirror was proved in sync.

**MINOR 6, unfixed and reported:** §7b.6 and FR-62 both say a public link is *"enabled per
template"*, and `permissions.rb`'s `covers:` line repeats it. **There is no per-template
flag.** It is off per ROLE and decided per LINK. Either the spec means something this design
does not do, or the sentence is loose — report-and-ask (CLAUDE.md §11.3), not a silent
rewrite in either direction.

**~~F-17~~ · CLOSED by curator decision, 2026-08-09: OPTION 1 — THE LINE NUMBERS ARE GONE
AND THE QUOTES STAY.** *"decision 3: 1"*. **39 citations across 21 files** stripped of their
`:NNN` suffix mechanically; every quoted sentence beside them is untouched, so each is still
findable with one `rg`. The suite is unmoved: `845 runs, 3705 assertions, 0 failures` and
`2362 examples, 0 failures`.

**Citations into CORE were deliberately NOT swept** — `app/models/attachment.rb:375`,
`app/models/query.rb:259-274`, `db/migrate/001_setup.rb:28` and the rest keep their numbers.
They point at a pinned checkout of somebody else's tree that this plugin does not edit, so
they do not drift the way a citation into a living document does — and a core line number is
the only practical way to find one line inside a 400-line method.

**The lint (option 2) was declined**, and the reason is worth keeping: it would have pinned
`technical-spec.md`'s line numbering, making the spec more expensive to edit — a gate that
taxes the document it protects.

The original finding follows.

**F-17 · THE `file:line` CITATIONS INTO `technical-spec.md` HAVE DRIFTED BY ROUGHLY SEVEN
LINES, ACROSS AT LEAST SEVEN FILES, AND NOTHING CHECKS THEM.** Found in T-28 increment 2 while
verifying my own comments. `Document`'s header cited `technical-spec.md:1213-1217` for
*"Persistence is opt-in with a mandatory TTL and a purge task"*; those lines now hold §7b.4's
catch-up paragraph and say nothing about persistence. The real text is at `:1220-1223`.

Spot-checked and drifted the same way (measured 2026-08-09):

| citation | what the line actually says now |
|---|---|
| `007:7` → `technical-spec.md:1203` | `reporter_project_tabs` — the row **above** the intended one |
| `007:60` → `:1215` | §7b.4's `max_catchup_days` sentence |
| `004:7` and `004:48` → `:1200` | **blank** |
| `004:55` → `:1210` | the `reporter_dashboards_documents` row |
| `006:7` → `:1202` | a table separator (`\|---\|---\|`) |
| `002:95` → `:1275` | an export-then-reimport sentence |

**This is the exact class of defect the project has already rejected twice** — T-32 and T-24
each shipped a comment citing a spec file as mechanical evidence, and CLAUDE.md's lesson from
those is that *a cited control that does not exist is worse than no comment*. A citation that
resolves to the wrong paragraph is the same defect with a slower fuse: it reads as verified
and is not.

**Fixed here: only `document.rb`'s three**, because that is the file this task touched and
CLAUDE.md §5's rule is about the file you are in. The rest are named above rather than swept,
because a mass rewrite across seven files is R-02 scope growth and would be stale again the
next time §7 gains a paragraph.

**What the curator owes: a choice between two mechanical answers, not a re-run of the sweep.**

1. **Drop line numbers, quote anchors instead.** Every one of these comments already quotes
   the sentence it cites; the number adds nothing a `rg` cannot do and is the only part that
   can rot. `technical-spec.md` §7's table" beats `technical-spec.md:1203`.
2. **Or add a lint** that resolves each `<spec>.md:<n>` and fails when the quoted string is not
   within a few lines of it. That is a real gate and about thirty lines, but it pins the
   spec's line numbering, which makes editing the spec more expensive.

I recommend (1). The evidence is that six of seven sampled citations were already wrong and no
run, review or gate had noticed.

**~~S-27~~ · CLOSED by curator decision, 2026-08-09: THE TOKEN STAYS IN THE PATH.** Four
shapes were measured on Redmine 6.1 and put to the curator; the answer was *"we stay with
a"* — `/reporter/s/<token>`, unchanged.

**What was measured**, because the decision rests on it and the numbers are not obvious:

| shape | what Rails' `production.log` records |
|---|---|
| `/reporter/s/<token>` (chosen) | `/reporter/s/SECRETTOKEN123` |
| `/reporter/s?t=<token>` | `/reporter/s?t=SECRETTOKEN123` |
| `/reporter/s?t=<token>` **+ the param registered in `filter_parameters`** | `/reporter/s?t=[FILTERED]` |

The mechanism is `ActionDispatch::Http::FilterParameters#filtered_path` —
`query_string.empty? ? path : "#{path}?#{filtered_query_string}"` — so **the path is never
filtered and the query string is**. A plugin *can* register the filter late: appending to
`config.filter_parameters` from `init.rb` is picked up by `env_config`
(`LATE_APPEND_PICKED_UP=true`), so the option was live rather than theoretical.

**Why it was still declined, and this is the part worth keeping.** The query form fixes ONE
log of two: nginx and Apache write the full request line *including the query string*, so
the proxy access log — the one more likely to be shipped to a central service — is
unchanged. It also leaves the address bar and browser history untouched. Against that it
costs a plugin mutating a **global** Rails config that affects core and every other plugin,
and a worse URL for the one artefact that has to be pasteable. Half a fix, with a
whole-application side effect.

The complete fix was option **D**, a fragment (`/reporter/s#<token>`), which is never sent
to the server at all — and it trades away the property that makes a share link a share
link: it needs JavaScript to re-issue the request, so the browser can no longer just render
the PDF. Rejected for that reason, not for effort.

**What actually bounds the exposure is the mandatory expiry**, which is why that control
must never become optional: a token in a log that expired weeks ago is a dead string rather
than a credential. **If the default expiry is ever raised, this finding is the argument
against it.**

The original finding follows, kept because the argument is what the decision rests on.

**S-27 · A SHARE TOKEN IS A BEARER CREDENTIAL IN A URL PATH, SO IT IS IN `production.log`
OF EVERY INSTALLATION. Recorded, not fixed, because §7b.1 specifies the shape.** Found while
building T-28 increment 2. Rails' request logger writes the full path of every request, so
`GET /reporter/s/<token>` puts a working link into the application log, and any reverse
proxy in front of Redmine writes it into an access log as well. `config.filter_parameters`
does **not** apply — it filters params, not path segments — so there is no Rails-side
mitigation at all.

This is inherent to "a link somebody can open", which is what a share link IS: the token
cannot move into a header, because a recipient pastes a URL into a browser. Two consequences
worth knowing rather than discovering:

* the sign-in redirect for a non-public link carries the same token in `back_url`, which adds
  **nothing** — the path it came from was already logged one line earlier. So the redirect is
  not the leak and removing it would not close one;
* what actually bounds the exposure is what T-28 already builds: mandatory expiry, individual
  revocation and optional `max_uses`. A token in a log that expired three weeks ago is not a
  credential. **This is the argument for keeping the default expiry short** when §7b.1's
  proposed 30-day default becomes a setting.

**What the curator owes:** nothing, unless they want it in the README's security notes. It is
recorded here so the next person to notice it finds the reasoning rather than filing it again.

**~~S-26~~ · CLOSED by curator decision, 2026-08-09: RATIFIED. A public link serves on a
`login_required` instance, and the behaviour stands.** The curator's words: *"public is
public… so when public links are enabled we make potentially private information public. I
know. it's a choice."*

That is the right framing and it is worth keeping verbatim, because it names the thing the
control actually protects. `login_required` is not what stops a report reaching the internet
— **`publish_reporter_dashboards_reports` is**, and it is off by default, granted per role,
and then exercised per link. Making the setting win would have moved the decision away from
the person who takes it deliberately and onto a global switch set for an unrelated reason,
and the capability would have been dead on those installations with nothing saying why.

**Nothing to change.** The behaviour, its test
(`test_a_public_link_still_serves_on_an_instance_that_requires_login`), the mutation that
kills it, and the controller's argument all stay as they are. **Do not "fix" this later** —
it is not an oversight, and this entry is here so the next reviewer finds a closed question
rather than an open one. What the README owes it is plain language, which it now has:
*"If that is not what you want for your installation, do not grant anybody the ability to
publish."*

The original finding follows, kept because the argument is what the decision rests on.

**S-26 · A PUBLIC SHARE LINK SERVES ON A `login_required` INSTANCE, AND THAT IS A DECISION
SOMEBODY HAS TO OWN.** T-28 increment 2, `ReporterDashboards::SharesController` runs
`skip_before_action :check_if_login_required`, so an instance closed to anonymous browsing
still answers a public link. Asserted by
`test_a_public_link_still_serves_on_an_instance_that_requires_login`, and killed by a
mutation that removes the skip.

The argument for it: `login_required` closes the instance to anonymous BROWSING, and a public
report link is an administrator having granted one role `publish_reporter_dashboards_reports`
— a per-link decision on top of a per-role grant, taken deliberately, over ONE frozen
document. If the setting silently won instead, the capability would be **dead** on those
installations with nothing anywhere saying why, which is the failure mode §7b.6 exists to
avoid ("so 'public link' stops meaning 'visibility check skipped'" — it still does not: the
bytes were frozen by a named identity inside their own visible scope).

The argument against it: an administrator who set `login_required` may reasonably read it as
"nothing in this instance answers an anonymous request", and this is the one endpoint that
does.

**What the curator owes:** a ratification or a reversal. The reversal is one line
(`return refuse(:not_found) if Setting.login_required?`) plus its test; do not take it
silently, because the two grants T-28 asks for stop differing at all if a public link cannot
reach the public.

**S-25 · `attachments.container_type` IS `varchar(30)` AND EVERY MODEL NAME IN THIS PLUGIN IS
LONGER, SO THE SNAPSHOT STORE NEEDED A SHORT ALIAS.** Measured 2026-08-09 in T-28 increment
2, against core `db/migrate/001_setup.rb:28` and the running schema on Redmine 6.1:

    t.column "container_type", :string, :limit => 30

`RedmineReporterDashboards::Document` is **35 characters**, so the first snapshot ever
captured answered `PG::StringDataRightTruncation` — and on MySQL the same write TRUNCATES
silently, leaving a `container_type` of `RedmineReporterDashboards::Doc` that resolves to
nothing and an attachment whose container can never be found again. **The engine that fails
loudly is the lucky one.**

Answered with Rails' `polymorphic_name` (6.0+) plus one top-level constant,
`RrdReportSnapshot` (`app/models/rrd_report_snapshot.rb`) — one class, one table, reachable
under a name short enough for a column core froze in 2012. **The string is written into every
stored snapshot's row, so renaming it orphans every attachment already on disk.**

Generalisable, and the reason this is a finding rather than a comment: **any future task that
contains a Redmine `Attachment` in a plugin object hits this**, and the namespaced name is
always too long. T-30's failure documents are the next candidate.

**S-24 · THE PROJECT'S OWN `Attachment` STORAGE WOULD HAVE DELETED EVERY SNAPSHOT AFTER ONE
DAY, AND NO TEST IN THIS REPOSITORY COULD HAVE SEEN IT.** Measured 2026-08-09, T-28 increment
2. Migration 007 chose Redmine's `Attachment` for the bytes because *"its storage, permissions
and cleanup are already solved"*. True — and the obvious way to write one,
`Attachment.create(file:, author:, filename:)` with no container, is a snapshot with a
one-day fuse. Core `app/models/attachment.rb:375`:

    Attachment.where("created_on < ? AND (container_type IS NULL OR container_type = '')",
                     Time.now - age).destroy_all

run by `rake redmine:attachments:prune` (`lib/tasks/redmine.rake:22`) — a task Redmine's own
installation documentation tells administrators to cron. Every share link with a 30-day
expiry would have answered "no longer stored" from day two, **on correctly-administered
instances only**, which is the worst possible distribution of a bug.

Fixed by containing the attachment in its `Document`, which takes it out of that WHERE clause
entirely — and the test calls the real `Attachment.prune` rather than asserting the column,
with a **control** asserting an uncontained attachment IS collected, so it cannot pass by the
prune doing nothing. Containing it also makes it reachable at `/attachments/:id`, so
`Document` answers core's three `attachments_*?` questions `false` for everybody: the share
link is the only door.

**Worth generalising:** the plugin's suite never runs core's rake tasks, so *any* assumption
about core housekeeping — prune, `User.prune`, `Watcher.prune`, session cleanup — is unproved
unless a test calls the task itself. This is the first one that mattered.

**E-22 · A SECURITY ASSERTION IN T-28 INCREMENT 1 HAD ITS ARGUMENTS THE WRONG WAY ROUND AND
TESTED NOTHING.** Found in increment 2, by the same mistake failing loudly in a sibling test.
Redmine's helper is `assert_not_include(expected, s)` → `!s.include?(expected)`
(core `test/test_helper.rb:258`), so the **needle comes first**. Written the other way round,
`test_the_token_itself_is_nowhere_in_the_row` asked whether the 43-character token contains a
64-character digest — false for every possible input.

**Measured in both directions**, which is what makes this a finding rather than a tidy-up.
With the plain token planted in a column as `"share:#{token}"` (so the neighbouring
`assert_not_equal` cannot catch it):

| assertion | result |
|---|---|
| corrected (`assert_not_include token, value.to_s`) | `1 runs, 8 assertions, **1 failures**` |
| as shipped (`assert_not_include value.to_s, token`) | `1 runs, 8 assertions, **0 failures**` |

The first attempt at this negative control was **wrong in the other direction** and is worth
recording too: planting the token as the whole column value made the test fail under BOTH
orders, because the `assert_not_equal` on the line above caught it. A negative control that
fires for the wrong reason proves nothing, and it looked like proof.

**The generalisable rule:** Redmine's `assert_include` takes the argument order OPPOSITE to
Minitest's own `assert_includes(collection, obj)`, and this repository uses both helpers.
Both spellings compile and both usually pass; only one of them tests anything.

**The rest of the suite was audited rather than assumed.** Every `assert_include` /
`assert_not_include` / `assert_includes` / `assert_not_includes` call under `test/` was read:
the `assert_includes` family is used collection-first throughout (correct for Minitest's
helper) and the only other `assert_not_include` in the tree —
`test/functional/reporter_dashboards_templates_controller_test.rb:839`,
`assert_not_include template, assigns(:templates)` — is needle-first and correct. **This was
the only one.**

**~~S-23~~ · CLOSED by curator decision, 2026-08-09: THE ARCHIVE IS BUFFERED, and E-6's
third bullet is amended rather than met.** The choice was never streamed-or-buffered — it
was *buffered once, honestly* against *generated twice while calling itself streamed*,
because `Rack::ETag` drains any body Rails will answer `to_ary` for and
`ActionDispatch::Response::Buffer#to_ary` is unconditional. The curator took the first.

**What changed:** `TemplatesController#stream_archive` drains `ZipStream` into a String and
uses `send_data`. The response now HAS a `Content-Length`, which E-6's bullet explicitly
asked not to have — so that bullet is superseded by this decision and should be read with
it. `Render::BatchGuard`'s cap of 50 is now the memory bound as well as the document
bound, and a test says so in one line so the connection cannot be lost.

**What did NOT change:** `Archive::ZipStream` is still lazy, and
`spec/archive/zip_stream_spec.rb` still asserts it yields before its source is exhausted.
That is deliberate rather than leftover: the writer is already the right shape if anyone
later moves this onto `ActionController::Live`, and only the controller method changes.
The measurements that produced the decision are kept below.

**S-23 · CONFIRMED INDEPENDENTLY AND SHARPENED, 2026-08-09.** A fresh-subagent review
reached the same conclusion from its own probe and made it exact: **all 22 chunks are
produced before `Rails.application.call` returns**, i.e. before the status line or any byte
can reach the client, and then produced again for the wire. So the cost is not only a
second pass — TIME-TO-FIRST-BYTE IS THE WHOLE GENERATION, which is what the README used to
deny ("a browser will show the download growing"); that sentence is corrected. One
parenthetical of that review does not hold on this Rack: it suggested `Rack::BodyProxy`
hides `to_ary` from the outer `Rack::ContentLength`, but `rack-3.2.6/lib/rack/body_proxy.rb`
hides only `:to_str` and forwards `:to_ary`. Re-measured WITH the proxy in place, the
`Last-Modified` variant still hands back `content-length="8374"`. The table below therefore
stands.

**S-23 · `Rack::ETag` WALKS THE STREAMED ARCHIVE TO DIGEST IT, so it is generated TWICE.
Both of E-6's stated requirements still hold; the redundant generation has no fix inside
T-29's mechanism, and the two obvious ones are measurably WORSE. Recorded with the
measurement rather than papered over. Owner: whoever is willing to move a download onto
`ActionController::Live`.** Found by probing Redmine's real middleware stack, which
`ActionController::TestCase` never runs — the same blind spot that hid T-23's
`Rack::MethodOverride` defect (HANDOVER §1).

Redmine's stack has `Rack::ContentLength` outermost and `Rack::ETag` inside it. Both gate
on `body.respond_to?(:to_ary)`, and `ActionDispatch::Response::Buffer#to_ary` is defined
**unconditionally** (`actionpack .../http/response.rb:122`) — it answers `@buf.each`, an
Enumerator, when the wrapped body is not an Array. So the response always answers `to_ary`
and a controller cannot opt out of either middleware. And `Rack::ETag`'s `skip_caching?`
in Rack 3.2.6 tests only for `etag` and `last-modified` headers — **not** `no-store`,
which is what a reader would assume from the name.

Measured, three strategies, same request. `generations` counts full passes over the entry
source; the column that carries the requirement is `Content-Length`:

| strategy | generations | `Content-Length` | ETag |
|---|---|---|---|
| **as shipped** | 2 | **absent** | yes |
| + `Last-Modified` (which makes ETag skip) | 2 | **"3286"** | no |
| + an `ETag` header of our own | 2 | **"3286"** | yes |

Both obvious repairs remove the ETag and hand back a `Content-Length`, which is the one
thing E-6's bullet names. **What ships is the best of the three.** The requirements hold:
no `Content-Length` on the wire, and the peak working set is ONE member — measured, the
largest single chunk was 1 000 bytes against a 3 286-byte archive — rather than the whole
file. What is NOT true, and what no comment or CHANGELOG entry may therefore claim, is
that the archive is produced once.

**Why it is not fixed here.** A single generation needs a body that never answers
`to_ary`, which means `ActionController::Live` or a Rack hijack. Live commits the response
as soon as the first byte is written, which would reintroduce precisely the failure T-29
designed against — a `200 OK` already on the wire when document 7 of 50 fails — and it
requires a threaded server. That is a design change with operational consequences rather
than a fix, and CLAUDE.md §11.5 says to split rather than absorb.

**~~S-22~~ · CLOSED by curator decision, 2026-08-09: THE SPEC KEEPS ITS NAMES AND THE
MIGRATION IMPORTER MOVED.** `import:{plan,run}` is the BUNDLE, as §7b.2 always said; the
one-way migration off `redmine_reporter` is now
`reporter_dashboards:migrate_from_reporter:{plan,run,status}`, and the bundle's export is
`reporter_dashboards:export:bundle` — you export on one installation and import on
another. §7b.2 needs no edit. The migration guide in the README does, and has one.
`test/unit/exchange_rake_test.rb` now asserts BOTH namespaces and that no task has two
bodies, because a rake collision appends rather than raising. The original report follows.

**S-22 · `technical-spec.md` §7b.2 NAMES TWO RAKE TASKS THAT ALREADY EXIST AND BELONG TO A
DIFFERENT FEATURE. Reported rather than resolved silently (CLAUDE.md §11.3); T-29 shipped
under `import:`/`export:` and the collision is the curator's to ratify or rename.** §7b.2 specifies
the bundle import as *"`import:plan` … then `import:run`"*. Both names have been taken since
T-02 and T-24:

    reporter_dashboards:migrate_from_reporter:plan     surveys the BASE PLUGIN's tables (T-02, read-only)
    reporter_dashboards:migrate_from_reporter:run      copies rows out of them (T-24, COPY/FORWARD-ONLY)
    reporter_dashboards:migrate_from_reporter:status   reports drift of those copies (T-24)

Those three are the one-way migration off `redmine_reporter`. T-29's two steps read a FILE
and are a different feature with a different input, a different failure mode and a different
audience. Defining `import:plan` twice in one rake file is not an error rake reports — the
second definition ENHANCES the first, so BOTH bodies run, in definition order. **Measured**
(two tasks of the same name in one Rake application):

    FIRST body (the migration survey)
    SECOND body (the bundle planner)
    actions=2

So the collision would not have been caught by a name clash or a warning; it would have
been caught by an operator. `import:plan` exits 2 without `RRD_FILE`
(`test/unit/exchange_rake_test.rb`), so the combined task would have run the migration
survey and then failed the whole command for a reason that has nothing to do with the
migration — while `rake -T` listed one task and showed one description.

T-29 therefore ships `reporter_dashboards:{export:bundle,import:plan,import:run}`: §7b.2's VERBS are
kept and the namespace says which of the two importers it is. `test/unit/exchange_rake_test.rb`
pins both halves — that the three `import:`/`export:` tasks exist, and that `import:plan`/`import:run`
still belong to the migration importer — so a later "fix" back to the spec's literal names
fails a test rather than shadowing a documented command. **What the curator owes:** either a
one-line edit to §7b.2 adopting `import:`/`export:`, or a decision to rename the migration importer
instead.

**S-21 · `import:verify` is DROPPED, with evidence, not deferred. Curator decision,
2026-08-08.** The clause was *"`import:verify` diffs **aggregation result hashes**, not HTML
— the corpus discipline applied to user data."* The instinct is right and the tool is not
buildable, for a reason sharper than the one first recorded here.

**The corpus discipline needs TWO pins and production has neither.** `spec/golden/README.md`
states what makes it work: a frozen fixture *and* a pinned reference date. An operator's
database has live data — issues are created and closed daily — so a hash of an aggregation
result over their templates differs TOMORROW, correctly. A check that goes red every morning
for the right reason is one that is switched off within a week, which is precisely what
CLAUDE.md §5 says about a fixture relative to `Time.now`. Both before/after readings fail on
this, including the one the first version of this finding recommended.

**And the remaining reading needs code we are removing.** Comparing what the BASE plugin's
renderer answers against ours would be a real answer, and it is only possible while both
plugins are installed — but it means calling into private code this whole plan exists to
decouple from, which CI cannot exercise (INV-7) and `zero_reporter` is pointed away from.

**What survives is already built, and it is the half that holds still.** `import:status`
compares CONTENT digests, and content changes only when a human edits it. *"Did my template
survive the migration intact"* is answerable and answered; *"does it produce the same
numbers"* is not, once the data underneath is live.

**T-24's `Accept:` list is otherwise complete**, including the `--rewrite` flag §7a named
(see the status row), which the first version neither built nor reported.

**S-20 · An ad-hoc report could be mailed to ANY active account in the instance, with a
requester-controlled `Subject`. FOUND by the independent review of T-32; DECIDED by the
curator on 2026-08-08 and CLOSED.** Reproduced end to end before the fix
(`to=["admin@somenet.foo"]`, status 302, one delivery).

**What was and was not at stake.** The document never was: it is rendered as the requester,
so naming a recipient with wider access disclosed nothing. The **envelope** was — this
installation's `From`, an arbitrary `Subject`, a PDF attachment, and a recipient who need
not share a project with the sender, at twelve an hour.

**The decision: a recipient must be permitted to open a report in THIS project**, asked as
`User#allowed_to?(:view_reporter_dashboards_reports, project)`.

**It is a permission check and deliberately not a membership check**, which is the part
worth keeping. §4.1 answers every *who may do what, in which project* question with a role
grant, so `Member.where(...)` would be a second and weaker vocabulary for a question the
permission model already answers. Asking `allowed_to?` also lands the edge cases correctly
by construction: a MEMBER whose roles lack the permission is refused, a non-member is
refused unless an administrator deliberately granted it to the Non-member role in a public
project, and an administrator is permitted because they can already read everything. The
REQUESTER needs no special case — `require_view_permission` has already demanded the same
permission of them — so §4.1's *"a logged-in non-member legitimately mails themselves a
report they can already read"* survives with no second rule to keep in step.

**What it does not claim.** Not that the recipient could have produced the report. The
document carries the requester's visibility and the mail says so (FR-47); that is what
sharing a report IS, and a recipient with narrower issue visibility legitimately sees more
than they could query.

**Refused wholesale, not filtered** — the same rule as the issue ids and the external
addresses. Mutation testing is what established that: dropping the ineligible recipients
survived deletion, because a single ineligible recipient leaves the list empty and falls
into `:no_recipients` anyway. The MIXED request is the discriminator, and it now has a test.
So does the picker, which survived deletion for the same reason — every member of the
fixture was entitled, so `select` was a no-op. Six mutations, six red, after two of them
first showed the examples could not tell the two behaviours apart.

**S-19 · `technical-spec.md` §7's table list stops before T-32, and FR-61 cannot be built
without two tables it does not name. DERIVED from stated requirements and RECORDED for the
curator, exactly as `reporter_dashboards_documents`' columns were in T-22. Owner: the
curator, to ratify or correct §7's list. RATIFIED as built by the curator, 2026-08-08 — the
two tables and the single, tightened `address` column stand.** FR-61 asks for two things that are *state* rather
than behaviour — *"every send is **audited**: who, when, which template, which issues, which
recipients — visible to admins"* and *"rate-limited per user"* — and §7b.5 says what the
audit is for in its own words: *"today nothing records what left the building. Now there is
a log you can answer questions from."* Neither is expressible without a row.

Migration 009 therefore adds `reporter_dashboards_mail_sends` and
`reporter_dashboards_mail_send_recipients`. Both are pinned to an EXACT column set in
`spec/migrations/schema_contract_spec.rb` rather than to a minimum, which is stricter than
the treatment §7's own tables get: adding a column to an audit table should cost somebody an
argument, because the reason to add one is almost always to make the audit do a second job.

**The one column that needed an argument is `address`,** and the guard was **tightened**
rather than loosened to take it. `spec/migrations/schema_contract_spec.rb` forbids
`to`/`cc`/`bcc`/`from`/`to_address`/`from_address`/`sender`/`recipients_raw` in every table
this plugin creates; `address` was not on that list, so T-32 could have added one silently.
It is now asserted to exist in **exactly one place** — the audit recipients table — and
nowhere else, and to be **nullable**, so an ordinary Redmine recipient stores no address at
all.

What makes it a different thing from the columns §7 refuses is the DIRECTION of the data.
Those were delivery inputs: a stored string a later run reads and mails to, which is *"a
report over any issue in the instance, mailed anywhere, with a forged sender"*. This one is
written **after** `Reporting::MailPolicy` has accepted the address against the
administrator's setting and the domain allowlist, and nothing reads it back to send
anything. Without it the audit cannot answer the only question an external address makes
anybody ask, which is *where did it go* — and an audit that records that a report left the
building without recording where is not an audit.

**Two things a reader should not mistake for oversights.** A refusal that happens *before*
any work is done — the rate limit, a disallowed address, no recipients — writes **no** audit
row: a refused request is not a send, and consuming the quota it was refused by would mean a
rate-limited user could never recover. A failure that got as far as rendering **is**
audited, because the expensive half of a send is the render. Both halves have a test, and
the first version of one of them passed for the wrong reason until the split was made
explicit.

**S-18 · The time-entry aggregator has no CUSTOM-FIELD dimension, where the issue path has
one. A NAMED GAP, asserted rather than implied. Owner: a task of its own.** Core's
`Redmine::Helpers::TimeReport#load_available_criteria` offers one `cf_<id>` criterion per
visible `TimeEntryCustomField`, `ProjectCustomField` and issue custom field; the issue kernel
offers `group_by: cf_92`; `TimeEntryAggregator::DIMENSIONS` offers none. Measured while
comparing the two sets:

    core (project 1)  activity category cf_1 cf_10 cf_3 cf_7 issue project status tracker user version
    this module       activity category                      issue project status tracker user version

It needs three things this task does not have: `TimeEntryCustomField.visible` (a different
visibility rule from `IssueCustomField`'s), a `custom_values` join whose fan-out the `SUM`
hazard of §Findings S-16 makes dangerous, and a `cf_` filter payload for the drill-through.
`test/unit/reporter_dashboards_time_entry_aggregator_test.rb` excludes `cf_*` from the
set-equality assertion and then asserts the gap directly, so the day somebody adds one the
test says this entry is stale.

**S-17 · The degradation panel printed raw symbols and English prose in every language.
PARTIALLY FIXED in T-31's review round — the eight `aggregation_*` codes are localised and
the MECHANISM is settled; seven codes in three other layers still print raw. Owner: a small
task of its own, before T-26 flips the last gate.** `_degradations.html.erb` localised its
heading and then printed `degradation.to_s`:

    aggregation_dimension_unknown: group_by: "activty" is not a time-entry dimension

Nine locale files held 192 keys each and not one of them was a degradation code. CLAUDE.md §10
forbids a hardcoded user-facing string in a view; that was the letter of the rule kept
(`to_s` is not a literal in the ERB) and its purpose missed. Worse, two Minitest assertions
pinned the raw identifier in the response body, so the untranslated output had become a
*tested contract* — which is what an independent review objected to when T-31 added five more
codes to the pile.

**What is fixed (2026-08-08).** `TemplatesHelper#reporter_degradation_text` looks up
`text_reporter_degradation_<code>`, interpolating the degradation's own `data`, and falls back
to the raw `to_s` when there is no key — so the eight aggregation codes are sentences in nine
languages and every other code prints exactly as it did. The two assertions now assert the
SENTENCE. 192 → 200 keys per file, placeholders identical across all nine (verified by a
script over the parsed YAML).

**What is left.** `asset_document_cap`, `asset_inline_oversize`, `asset_nested_depth`,
`asset_srcset_collapsed`, `asset_structural_fallback`, `chart_label_truncated`,
`chart_palette_wrapped`, `chart_refused`, `collection_truncated`, `wiki_unavailable` — the
asset, chart and batch layers. Each is one key in nine files against the mechanism above; the
reason they are not in this round is R-02 (CLAUDE.md §11.5), not difficulty.

**S-16 · `SUM` over a row-duplicating join over-counts, and no `DISTINCT` can fix it.
KNOWN LIMIT of T-31's time-entry aggregator, recorded rather than left to be found. Not a
blocker today; it becomes one the moment a `has_many` reaches a time-entry scope.** Measured
on PostgreSQL 16 and MariaDB 10.11 (2026-08-08) over the T-31 fixture with a deliberately
tripling join:

    scope.joins('INNER JOIN roles rrd_dup ON 1=1')   # 3 roles -> every row x3
    measure: count  ->  correct        (COUNT(DISTINCT time_entries.id))
    measure: hours  ->  exactly 3x    (SUM(time_entries.hours))

`COUNT(DISTINCT …)` is why the counted measure survives. `SUM` has no equivalent:
`SUM(DISTINCT hours)` would collapse two genuinely separate entries that logged the same
number of hours, which is worse than the over-count. The correct fix is a derived table
(`SUM` over `SELECT DISTINCT id, hours FROM …`), which is a design change and outside T-31's
`Accept:` list — so it is reported, not absorbed (CLAUDE.md §11.5).

**Why it does not bite today, and what would change that.** Every scope reaching the module
comes through `Reporting::ReportScope`: either `TimeEntry.visible` or
`TimeEntryQuery#base_scope`. Redmine's own time-entry filters join `belongs_to`
associations — one row each — and build custom-field conditions as `IN (SELECT …)`
subqueries, so none of them duplicates. **This is reasoning from the core source, not a
measurement of every filter**, which is precisely why the suite now asserts BOTH halves over
the tripling join: the day a `has_many` join arrives, `spec/adapter/time_entry_aggregator_spec.rb`
says which measure moved instead of a report quietly tripling somebody's timesheet.

**Owner:** whoever adds a filter or a dimension that needs a `has_many`. The two examples are
the tripwire, and this entry is the answer they should read.

**S-15 · The scheduler rendered a time-entry report over the ISSUE scope and mailed the
issue count as a success. FIXED in T-31 increment 1's review round; recorded because the
shape is general.** Found by a fresh-subagent review of `289fc71`, measured end to end:

    PROBE-SCHED issues=7 time_entries=3
    PROBE-SCHED ok=true error=nil          <- a success
    PROBE-SCHED direct body="COUNT=[7]"    <- the ISSUE count
    PROBE-SCHED direct scope class=Issue

`TemplatesController` had learned to branch on `template.source`; `ScheduledDelivery` had
not, and kept building `Issue.visible(actor)` for every schedule. A recipient would have got
a mail titled as the hours report containing the issue count, with no diagnostic and nothing
said — §Findings S-13 on the one path that has an audience, in the commit whose subject was
*"the wrong-numbers path is closed first"*. `#test_send` used the same code.

**The lesson is not "remember the other caller".** It is that a decision with two callers
will be made twice and differ. `Reporting::ReportScope` is now the one place that answers
"which rows is this report about", both callers go through it, and a third (T-32's ad-hoc
mail) cannot get it wrong by omission. The one genuine difference between them — an
unresolvable query id is ignored interactively and RAISES for a schedule — is a named
argument rather than two implementations.

**Two more things the same review found, both fixed, both worth knowing:**

* **The guard was on one of TWO kernel entry points.** `{% version_rollup %}` still handed a
  time-entry relation to `QueryAggregator`, and what saved it was an accident: AR emits
  `group(:fixed_version_id)` unqualified so it bound to `issues.fixed_version_id` and
  SUCCEEDED, and the raise came one line later from a `where.not(status_id:)` that AR does
  qualify — landing in the tag's rescue as a log line and an empty list with no degradation.
  The check now lives on `ScopeBinding`, which both tags already include.
* **A degradation nothing displays is not a degradation.** `record_degradation` wrote into a
  per-job `Diagnostics` that `ReportRun` threw away, `Outcome#degradations` was filled only
  from render-engine degradations, and the preview's degradation list sat inside the branch
  that runs only when the PDF succeeded. The author saw `TOTAL=[0]` and nothing else, while
  the code comment claimed the panel showed it. One collector per RUN now, rendered by both
  pages through `_degradations.html.erb` — which also un-silences `unbounded_collection`,
  recorded into the void since T-18.

**S-14 · A time-entry report shows a smaller, entirely plausible number to most of the
people who open it, and nothing says why. RAISED AND SETTLED 2026-08-08.** Nobody had written
this requirement down: `TimeEntry.visible_condition`
(`redmine/app/models/time_entry.rb:82-92`) does not merely check a permission, it branches on
`Role#time_entries_visibility`, which has three states:

| the actor's role | what a "team hours" report gives them |
|---|---|
| `time_entries_visibility == 'all'` | every entry in scope — correct |
| `== 'own'` | **only their own hours, and the report looks fine** |
| no `:view_time_entries` at all | `1=0`, so nothing — fail-closed and correct, but unexplained |

The middle row is the defect. An ordinary member opens the team's hours report, sees a total
that is smaller and completely believable, and has no way to know they are looking at their
own timesheet. **There is no equivalent on the issue path** — `Issue.visible` narrows by
project and by `Role#issues_visibility`, but it has no "your own issues only" mode that a
whole-project report silently collapses into — so no existing test or invariant covers it.

**Curator decision, 2026-08-08:** fail closed on both narrowing states AND **label the
narrowing on the page**, following §9b.2's existing *"Preview of 50 of 1 284 issues"* pattern.
Rejected: refusing the report outright unless the role has full visibility — "my own hours" is
a legitimate report, it simply has to say that is what it is. Also rejected: adding a
time-entry permission to §4.1's thirteen — core's `:view_time_entries` already exists, is
already enforced by `TimeEntry.visible`, and a second permission over the same data is a
second answer to one question. T-31's `Accept:` clause 8 carries it.

**~~S-13~~ · CLOSED by curator decision, 2026-08-08 — and TWO decisions were taken, not one.**

1. **The kernel stays frozen. No second G7 hunk.** Time entries get their own owned
   aggregation module, a SIBLING of `aggregation/query_aggregator.rb` rather than an edit to
   it, so `KERNEL_FILES` is untouched, `RATCHET` stays at 1 and the 176 corpus values keep
   the oracle they were measured against. The curator's reasoning, which is worth keeping
   because it answers the "two implementations" objection: **a time-entry report wants
   different SQL** — `SUM(hours)` grouped by activity, user or an issue attribute — so the
   duplication is smaller than it looks. What the two genuinely share is the RESULT
   VOCABULARY (bucket shape, drill-through filters, caps), and that can be shared without
   sharing the query builder.
2. **The separation is at the QUERY and the CALCULATOR, and nowhere above them.** An issue
   report resolves through `IssueQuery` and a time report through `TimeEntryQuery` — two
   different Redmine core classes with different `base_scope` methods — and `source` is the
   field that picks. Above that line **nothing** is duplicated: one template model, one
   controller, one CRUD, one preview, one permission set. `[OQ-H]`'s closure ("as a `source`
   field, not a branch") therefore still holds, and the base plugin's parallel world of
   controllers, drops, permissions and views is still refused.
3. **Mixing issue data and time data in one template body is DROPPED, not deferred.** It was
   T-31's most-cited benefit and §7b.4 promised it in as many words; both have been corrected
   (`technical-spec.md` §7b.4, FR-60). The reason: an issue report and a time report are two
   different things to their author, and `RenderContext` carries a single `scope`, so
   supporting it meant a second scope slot built for a requirement nobody wanted. A template
   body reports on **one** source.

**CORRECTED 2026-08-08, same day, and the error was mine rather than a change of plan.** This
paragraph first read *"the new module still needs its own frozen corpus — that is the one cost
of route (b)"*. That copied T-01's pattern onto a situation it does not fit. The corpus is a
DRIFT DETECTOR for ported code — `spec/golden/README.md` says so in its own words: *"Nothing
in this directory tests the plugin's behaviour. It tests that the behaviour has not moved."*
There is no "before" for a new module, so snapshotting its answers on day one would freeze
whatever it happens to output, bugs included, and turn fixing one into an apparent gate
breach.

**What the new module needs instead is an INDEPENDENT ORACLE**, and the curator's framing is
the right one: compute each figure twice, once through the module's SQL and once by loading
the rows and adding them up in Ruby. That is a correctness claim rather than a
did-it-change claim, it explains itself, and it is engine-independent — which makes it the
check that catches D-1's still-open `SUM`-on-a-grouped-relation defect. T-31's `Accept:`
clauses 5, 6 and 7 carry it, and **no corpus file is to be added**.

*(The curator also asked whether the new module could be verified against the plugin on
`main`. It cannot: `main` carries no time-entry-sourced reporting — only
`_report_by_spent_time.erb`, which renders a template belonging to the PRIVATE
`redmine_reporter` plugin, and `_timelog.html.erb`, which is core Redmine. What does exist on
`main` is `spent_hours` as a MEASURE over an issue scope, and that is already frozen in
T-01's 176-case corpus, so that comparison has effectively already been made.)*

The measurement that forced the decision follows, kept in full because it is also the
regression this project would want to notice if anyone ever points the issue kernel at a
time-entry scope again.

**T-31's central premise was FALSE, and the kernel does not raise — it answers ISSUE
counts under time-entry labels. MEASURED 2026-08-08.** `technical-spec.md:1411` (§7b.4) and
`implementation-plan.md`'s T-31 entry both say *"the aggregation core already takes a scope
— so `{% sql_aggregate from: time_entries %}` works with every dimension that applies, and
`spent_hours` measures stop being a special case"*. It was checked by handing
`TimeEntryQuery#base_scope` to the frozen kernel on a real Redmine 6.1 / PostgreSQL 16, as
`User.current = admin` over project 1:

    time entries in scope: 4          (over 2 distinct issues)

    author     -> {"buckets"=>[{"label"=>"Redmine Admin", "count"=>2, ...
    tracker    -> {"buckets"=>[{"label"=>"Bug",           "count"=>2, ...
    status     -> {"buckets"=>[{"label"=>"New",           "count"=>2, ...
    priority   -> {"buckets"=>[{"label"=>"Low",           "count"=>2, ...
    project    -> nil
    activity   -> nil
    user       -> nil
    dimension_breakdown(scope, group_by: 'project', measure: 'spent_hours') -> nil

    COUNT(DISTINCT issues.id) over that scope = 2
    COUNT(time_entries.id)                    = 4
    SUM(time_entries.hours)                   = 162.9

Three separate facts, and the first is the dangerous one.

1. **It does not raise. It answers the wrong number, plausibly.** `QueryAggregator`'s unit
   of count is the constant `DISTINCT_ISSUES = 'DISTINCT issues.id'`
   (`aggregation/query_aggregator.rb:100`), so every bucket above counts ISSUES. A
   time-entry report grouped by author would print *"Redmine Admin: 2"* where the truth is
   four entries and 162.9 hours. `TimeEntryQuery#base_scope` calls `.left_join_issue`
   (`redmine/app/models/time_entry_query.rb:166`), which is exactly why the issue columns
   resolve rather than erroring — the join makes the wrong answer available.
2. **The time-entry-native dimensions do not exist.** `activity` and `user` are not in
   `DIMENSION_COLUMNS` (`:184-188`), and `project` — which IS in it, as
   `issues.project_id` — also came back nil, because the time-entry scope already joins
   `projects` on its own terms. Each of those is the aggregator logging and degrading
   (HANDOVER §1: *"every aggregator entry point LOGS AND DEGRADES on an argument it cannot
   use"*), so a template asking for them renders empty rather than failing.
3. **`spent_hours` answers nothing at all** on this scope, which is the one measure the
   spec singles out as the point of the change.

**Why this cannot simply be fixed here.** The fix is to the counted unit, the dimension
table and the measure resolution — all inside `query_aggregator.rb`, which gate **G7** holds
byte-identical to its `v0.5.0` blob **plus exactly ONE declared hunk** (D-1's), through
`spec/golden/kernel_exception.rb`. Generalising `DISTINCT_ISSUES` is a second declared hunk
in the one file this plan freezes hardest, and it would move the oracle the 176-case corpus
is measured against. **That is a curator decision, not a task decision** (CLAUDE.md §11.3,
and §1's deletion/ordering guard is the same instinct).

**Two routes, and the choice is the curator's:**

* **A declared G7 hunk** generalising the counted unit and the dimension table. Smallest
  code, largest blast radius: every one of the 176 corpus values is computed by the method
  that would change, so the regeneration argument has to be made and the exception written
  by hand with its reason.
* **A second, OWNED aggregator** — `aggregation/time_entry_aggregator.rb`, a new file and
  therefore outside `KERNEL_FILES` — reproducing the vocabulary for the dimensions that
  apply to a time entry. No G7 exposure at all, and the corpus does not move. The cost is a
  second implementation of the same shapes, which §5's *"no second way of doing something
  that already has a way"* is against, and it needs its own golden corpus or it becomes the
  untested half.

**What T-31 can deliver without either decision** is the rest of its acceptance list, which
does not depend on the kernel: `source` accepted end to end, ONE controller/CRUD/preview
serving both sources, a `TimeEntryQuery`-backed scope bound to the render, the existing
`Drops::TimeEntriesDrop` (built in T-18 and still without a producer) getting one, and a
template that puts issue data and time data side by side. **Recorded rather than decided,
and nothing was silently built against the false premise** — in particular, nothing hands a
time-entry scope to `QueryAggregator`, because the measurement above is what that produces.

**~~S-11~~ · CLOSED by curator decision, 2026-08-08: the opt-in is PER TEMPLATE, and §7b.3
was narrowed to say so.** The schedule half is not deferred, it is dropped — a schedule
renders a template, so the template flag already governs every render, and the reason there
was nothing to build is recorded below. `technical-spec.md:1393` now reads "per template"
with the decision and its date inline. Nothing else changes: no column on
`reporter_dashboards_schedules`, and if T-28 later wants a per-schedule override it adds one
then, with a destination to point at. The original finding follows, kept because the
argument is what the decision rests on.

**§7b.3 said the failure-document opt-in is "per template/schedule", and T-30 built
only the template half.** `technical-spec.md:1393` reads *"Optional
failure document (per template/schedule, default off)"*. Migration 008 puts
`failure_document` on `reporter_dashboards_templates` and nowhere else, and the reason is
that the schedule half has **nowhere to deliver a document to**:

* T-30's own `Accept:` requires the scheduled failure to notify the owner *"with the
  correlation id and **no attachment**"*, and FR-43 says the same. So the owner's mail is
  closed to it by a requirement, not by an omission.
* §7b.3 level 3 gives recipients *"nothing by default, or a configurable 'this report is
  unavailable' notice"* — a notice, not a document.
* The only remaining destination is `reporter_dashboards_documents`, whose **write path is
  T-28's** (migration 007's own comment says so in as many words: *"the column is nullable
  because T-30 owns the write path and may resolve it differently — nothing in T-22 creates
  a row"*). Building a document store here to hold an artefact nobody has asked to store
  would be R-02's scope growth, and it would be the second place documents are persisted
  once T-28 lands.

Since a schedule renders a template, the template flag already governs **every** render
including scheduled ones — there is simply no scheduled *consumer* of the bytes today. A
`failure_document` column on `reporter_dashboards_schedules` that nothing reads is worse
than an absent one, and §7 rule 6 does not force it (it pins `lock_version` and unique
indexes, and this is neither), so it can be added later if T-28 gives it a destination.

**What the curator owes:** either a one-line edit to §7b.3 narrowing it to the template, or
a decision that the schedule half is T-28's to finish. Nothing was silently rewritten.

**~~S-12~~ · CLOSED by curator decision, 2026-08-08, and DELIVERED by T-29 on 2026-08-09 —
`TemplatesController#send_document` streams a zip and the 501 is gone. See E-6 below for
what was built and for the one thing the word "streamed" does NOT claim.** E-6's third bullet named "T-29 or T-30"; it is now T-29 alone,
which is also where the packaging machinery will already exist. T-29's `Accept:` carries it
and the 501 refusal in `TemplatesController#send_document` is what T-29 deletes. The
argument follows.

**E-6's third bullet was still owed after T-30, and T-30 was one of its two named
owners.** §Findings E-6 says of streamed archives: *"Whoever builds it (T-29 or T-30)
deletes the refusal."* T-30 did not, and the reason is that a zip is not a failure report:
it shares no code, no requirement (FR-59 is about one document that says a report failed)
and no test with anything in this task, and absorbing it would be the second purpose
CLAUDE.md §11.5 says to split rather than absorb. The 501 refusal in
`TemplatesController#send_document` therefore stands, and **T-29 is now its sole owner** —
which is also the better fit, since T-29's whole subject is a bundle format.

T-30 did touch that path: a per-record export over the cap now answers the 501 **with a
failure document** when the template asks for one, so the refusal is a document rather than
only a page. The zip is still absent and still named.

**E-21 · Two of T-33's own tests have never asserted anything, and nothing could have told you.**
Found by T-36, by the simple act of running the full-application suite locally for the first time.
`test/functional/asset_policy_settings_test.rb:30` declares
`class AssetPolicySettingsTest < ActionController::TestCase` and calls `l(:label_reporter_asset_policy)`
in two tests — without including `Redmine::I18n`, which is what defines `l`. Both errored with
`NoMethodError: undefined method 'l'`.

One of the two is `test_the_partial_uses_locale_keys_and_not_hardcoded_english`, whose whole job is
to catch a `translation missing` on the settings page in a locale nobody reads. It has been in the
tree since T-33 landed and has never run. `docs/plan/HANDOVER.md` records that T-33's Minitest half
had not been executed anywhere — this is what that was hiding, and it is the same shape as
§Findings E-14 and the Minitest `private` trap: a test that does not exist and a test that passes
look identical in a summary line.

**Fixed here rather than filed**, because it is one line (`include Redmine::I18n`) and because
CLAUDE.md's working agreement is that a locally red suite gets fixed. With the include, the file
runs **14 tests, 46 assertions, 0 failures** — so the assertions were right all along and only
unreachable. Worth generalising: any `ActionController::TestCase` in this plugin that calls a
Redmine view helper needs the module, and no CI run would have said so, because those two errors
were inside a suite nobody had executed.

**S-1 · `plugin_schema_info` does not exist on any supported Redmine, and four documents assert
against it.** Named by **FR-69** (`functional-spec.md:259`), `technical-spec.md:1232` and `:1241`,
`implementation-plan.md:2133` (T-36's `Accept:`) and **CLAUDE.md gate G11**. Measured on the two
branches whose source is on disk: the only occurrence of that name in Redmine 5.1-stable or
6.1-stable is `lib/tasks/redmine.rake:88`, where it appears in a list of table names to **exclude**
from a dump. Nothing writes it. The real bookkeeping is a `schema_migrations` row of the form
`<version>-<plugin_id>` — here `1-redmine_reporter_dashboards` — written and deleted by
`Redmine::Plugin::Migrator#record_version_state_after_migrating` (`lib/redmine/plugin.rb:553-555`,
identical on 5.1, 6.0, 6.1 and 7.0).

**Why this is not a nit.** A `migrate-updown` check written literally against FR-69 would assert
that a table which never exists is empty, pass, and prove nothing — this repository's own favourite
failure mode, and the exact thing HANDOVER §1 warns about. T-36 therefore asserts the requirement's
INTENT ("no bookkeeping row survives `VERSION=0`") against the mechanism that exists, and
`test/unit/reporter_dashboards_schema_test.rb` carries a tripwire that goes red if a future Redmine
reintroduces `plugin_schema_info`, so the discrepancy cannot be forgotten. **The curator owes a
one-word edit to four documents.** Nothing was silently rewritten.

**S-2 · `technical-spec.md` §7 says the templates table has an `STI type`, and four other places
forbid exactly that.** §7's cell (`:1198`) reads *"new. STI `type`, …"*. Against it:
`implementation-plan.md:1979` (T-23's `Accept:`) — *"template types by `source` field (T-31),
**not a subclass tree**"*; `technical-spec.md:1392` (§7b.4) — *"Do not reproduce the branch. Make
the data source a field"*; **FR-60**; and **`[OQ-H]`, which is CLOSED** with *"as a `source` field,
not a branch"* (`technical-spec.md:1657`). §7's cell is the older text — its three `type` values are
inherited from the base plugin's own `ReportTemplate.available_types`
(`docs/plan/reference/source-inventory.md:99`).

There is a second problem underneath the first: reporter's three values conflate **two orthogonal
axes**. *Output cardinality* — one document per issue versus one for the set (**FR-36**) — and
*data source* — issues versus time entries (**FR-60**). One three-valued column cannot express a
per-record report over time entries, and §7b.2's closed import map (`:1351`) collapses both into
one field.

**T-22 built `source` + `output` and no `type`**, because a column literally named `type` **is**
Rails' STI discriminator whether or not anyone wants it to be, so writing one would build the
subclass tree those four documents forbid.

**~~S-2~~ CLOSED by the curator, 2026-08-07: `source` + `output` are approved and §7's cell is
corrected.** `output` was the name most likely to be sent back — no document used it — and it
stands. The cell now lists the real column set and says why `type` is absent, so the next reader
meets one answer instead of two.

**S-3 · §7's table list has no roles join table, and `visibility` has a value that cannot work
without one.** T-40 assigned `visibility` to T-22 (`technical-spec.md:613-618`) with Redmine's own
three values. Redmine's `Query` backs `VISIBILITY_ROLES` with `has_and_belongs_to_many :roles`
(`app/models/query.rb:265`) and validates that the list is non-blank (`:277`); without an equivalent
table, an administrator can select a value the code can never honour. §7 rule 6 forbids adding it in
a later migration than its column. T-22 therefore ships `reporter_dashboards_templates_roles`
alongside the column, `id: false`, following core's `queries_roles`
(`db/migrate/20130602092539_create_queries_roles.rb`). Note §7 rejects `id: false` for
`report_schedules_users` — for a reason that does not reach a visibility pair, since a *recipient*
row is a thing an operator wants to address and revoke. **Recorded so the curator can disagree in
one place.**

**S-4 · The specs call the three visibility values "private / roles / project" and claim they are
"the three values Redmine's saved queries already use".** Both `technical-spec.md:617-618` and
`implementation-plan.md:1974` say it. Redmine's third value is `VISIBILITY_PUBLIC`
(`app/models/query.rb:261`), labelled *"to any users"* (`config/locales/en.yml:1076`). T-22 uses
core's names and integers, and a Minitest asserts them **against `Query`'s own constants** rather
than against literals — because the stated goal, *"an administrator meets one concept rather than
two"*, is only met by core's. The prose needs correcting; the behaviour does not.

**~~S-4~~ CORRECTED by T-23, 2026-08-07.** Both sentences now read **private / roles /
public**, and the correction went one step further than the prose: T-23's form renders core's
own `label_visibility_private` / `_roles` / `_public` rather than adding three keys of its own,
so the words an administrator reads on the template form are byte-identical to the ones on the
saved-query form and are already translated in every locale Redmine ships. A plugin key would
have satisfied the letter of "one concept" while producing two vocabularies the first time
somebody translated it differently. Nothing in the code changed, which is what the finding said
would be the case.

**S-5 · §7 rule 5 names three columns "added after 0.6", and there is no 0.6 schema for them to be
added after.** `engine_hint`, `next_run_on` and `consecutive_failures` (`technical-spec.md:1247`)
all arrive in T-22's own migrations, in one release, because rule 6 requires it. The *guard* is
still right and costs nothing — `Compat.column_present?` plus four model readers that degrade rather
than raise — so it is built as specified and exercised by taking the column away in a test. Only
rule 5's premise is stale.

**S-7 · Only `reporter_dashboards_templates` carries `lock_version`, and the concurrently-written
table is the OTHER one.** §7 lists `lock_version` on the templates row and on no other, so T-22
followed it exactly. The review of T-36 pointed out what that costs: `reporter_dashboards_schedules`
is the one table in this schema with two writers — an administrator editing the form while T-25's
runner writes `last_status`, `consecutive_failures`, `last_run_on` and `next_run_on` — and a lost
update there silently re-enables a schedule somebody just disabled.

**Deliberately not added, and this is the entry that says why.** Optimistic locking on a row the
runner writes from a background task means the runner raises `StaleObjectError` whenever an admin
happened to be editing, and T-25's per-schedule rescue would then record a failure that is not one.
The right shape is probably run-state columns written with `update_columns` and a `lock_version`
guarding only the form — which is T-25's design to make, not T-22's.

**~~S-7~~ CLOSED by the curator, 2026-08-07: NO `lock_version` on schedules.** The cost of adding
one is worse than the defect it prevents — the runner would raise `StaleObjectError` whenever an
administrator happened to have the form open, and T-25's per-schedule rescue would record a failure
that is not one: a scheduler that reports errors because a human was looking at it. **T-25 inherits
the obligation**: write run state with `update_columns` (or an equivalent that does not carry the
whole row), so the runner and the form cannot overwrite each other's columns. §7's Reversibility
section records the decision next to rule 6, because rule 6 is what makes it irreversible.

**~~S-10~~ CLOSED by the curator, 2026-08-08: A PERMISSION,
`render_reporter_dashboards_reports_as_others`.** T-25's UI shipped `render_as_user_id` permitted and unfiltered, and
an independent review turned that into a working privilege escalation: a member holding
`manage_reporter_dashboards_schedules` posted an administrator's id, pressed "Send a test",
and received an admin-visibility report containing a private issue they could not see.

**The hole is closed** with the narrowest rule that closes it: the identity must be
`User.current`, unless the actor is an administrator, in which case any active project
member. §7b.5 states the principle this follows — *"you can only mail what you can see"* —
and `#test_send` is bounded the same way, because FR-45 fixes the identity and so the
delivery target is what gives way.

**What is NOT decided is whether that is the intended model.** §4.1 gives
`manage_…_schedules` no impersonation power and FR-45 speaks only about the identity being
*explicit, stored and auditable*, never about who may choose it. Two questions for the
curator:

1. Should a non-administrator ever be able to schedule a report as somebody else — a team
   lead as a service account, say? If yes, the mechanism is a **delegation** (the target
   consents) rather than a permission, because any permission-based answer re-opens the
   escalation for every member with wider visibility than the setter.
2. Should `#test_send` be usable at all on a schedule you do not render as? The current
   answer is no. The alternative — deliver to the *stored identity's* address instead of the
   presser's — preserves the button for more people and turns it into a way to send mail to
   somebody else, which is why it was not chosen unilaterally.

**THE ANSWER, and what it does and does not change.** A role permission, granted per role
per project, registered in §4.1 and live. Without it you may render as yourself; with it, as
any active member of that project. The project bound survives the grant — the permission
authorises borrowing a colleague's visibility, not naming an arbitrary account — and an
administrator needs no grant, because `User#allowed_to?` answers `return true if admin?`
(`user.rb:378`), so that exemption now falls out of Redmine's own model instead of a
hand-written `|| User.current.admin?` that could drift from it.

**Question 2 is answered by the same permission**, at the curator's request, and that is the
stronger shape rather than merely the tidier one: binding a schedule to another identity and
reading that identity's report on demand are ONE capability exercised twice, so they are one
grant. Two would let an administrator hand out half of it and believe they had withheld the
other half.

**It maps NO action, and that is load-bearing.** Every other entry in `permissions.rb` opens
a door; this one widens a FIELD behind `manage_…_schedules`. Mapping it would make it
*sufficient* for `authorize` on actions it is not sufficient for, so a role holding only it
could reach `#create` and be stopped by nothing but the second guard. `{}` says the truth:
holding it alone lets you do nothing at all, and an example asserts that.

**The label was the condition attached to choosing this model.** The permission does not
relocate the escalation, it AUTHORISES it — anyone holding it can bind a schedule to a
colleague with wider visibility and read the result. That is only acceptable if the checkbox
tells the truth, because the roles screen is the one place an administrator reads about it.
So it is *"Render reports as another user — grants access to everything that user can see"*
in all nine locales, not the milder "choose a render identity" that would describe the
mechanism while hiding the consequence.

Six negative tests: the permission ignored, the permission not required, the project bound
removed, the test-send guard opened, the test-send guard ignoring the grant, and the
permission given actions. All six red.

**S-8 · Deleting a `Role`, a `Project` or a `User` orphans plugin rows, and the roles join table is
NOT the same shape as Redmine's.** Core's `Role` declares the reciprocal
`has_and_belongs_to_many :queries` (`app/models/role.rb`), which is what deletes `queries_roles`
rows when a role goes. Nothing outside this plugin knows about
`reporter_dashboards_templates_roles`, so its rows survive. The consequence is bounded — the
association INNER-JOINs `roles`, so an orphan contributes nothing on read, and a ROLES-visible
template with no surviving roles becomes invalid on its next save, which is a visible degradation
rather than a silent grant — and Redmine does not reuse role ids. **Owed by T-23**, which builds the
UI and can carry the reciprocal declaration; recorded here so it is a known gap rather than a
discovery.

**~~S-8~~ CLOSED by T-23, 2026-08-07.** `lib/redmine_reporter_dashboards/patches/role_patch.rb`
declares `Role has_and_belongs_to_many :reporter_dashboards_templates`, which is what installs
the join-row `before_destroy` — Rails puts it on the class being DESTROYED, so the `Template`
side could never have done it. Proven by destroying a role and counting the rows, not by reading
the association. A second test asserts the association EXISTS, separately, because `load_patches`
rescues and only logs a warning: a patch that failed to load would otherwise leave no failure
anywhere except the first test, and the two say different things about what broke. The template
itself survives its role, deliberately — its author has to choose again, which is a visible
degradation rather than a deletion. **The `Project` and `User` halves of this finding are NOT
closed**: those are ordinary columns rather than a join table, and nothing in T-23 needed them.

**E-22 · T-23's review found two blockers, and the first one had been true of every report
this plugin would ever have shown.** The rendered template body was inlined into the Redmine
page — `<div class="reporter-report-body"><%= body.html_safe %></div>` — in the viewer's origin,
with the viewer's session. `technical-spec.md` §4 names the opaque-origin sandbox as a mechanism
SEPARATE from the permission label, and §10's INV-9 row names *"a functional test asserting the
CSP `sandbox` header"*; neither existed, and §4's *"No `html_safe` anywhere"* was breached in the
same three lines. The escalation is one sentence: an ordinary member holding `edit_own_…`
(`require: :member`) writes `<script>fetch('/users/1/memberships', …)</script>`, and the next
administrator to open the report runs it. **Fixed** — the body goes into an `srcdoc` ATTRIBUTE
(escaped by Rails on the way in, so the parent document never contains author markup at all)
inside a frame carrying `sandbox="allow-scripts"` without `allow-same-origin`. `html_safe` is
gone from the change entirely. **One deviation from §4's wording is reported rather than
absorbed**: §4 puts the CSP on "the content endpoint", and a PREVIEW renders content that has no
URL — so the sandbox comes from the attribute (CSP's `sandbox` DIRECTIVE is header-only and is
ignored in a `<meta>`, so putting it there would be a policy that does not exist) and the rest of
the directives from a `<meta>` inside the document. One mechanism for both cases; the curator may
want the header, which needs a content endpoint and a way to address unsaved content.

The second blocker was smaller and would have been found by the first person to press the button:
the editor's Preview submit returned **404 for every user, always**. Its form is a PATCH, which
Rails implements as a POST carrying a hidden `_method=patch`; `formmethod="post"` changes the verb
and not the body, so `Rack::MethodOverride` rewrote the request back to PATCH before routing and
only a POST route existed. No controller test could see it — `post :preview` never renders a form
— so `test/integration/reporter_dashboards_preview_flow_test.rb` submits it the way a browser
does. **The same file found a second real defect on its first run**: Redmine sets
`include_all_helpers = false`, so a controller sees only its OWN helper, and the views 500'd on
`reporter_dashboard_icon` until the controller declared `helper :reporter_project_pages`.

Eight majors went with them, and three are worth recording because of what they say about the
tests rather than the code. **`Template.visible`'s roles arm was two clauses short of core's** —
no `projects` join and no `templates.project_id = m.project_id` — so a Manager in an unrelated
project satisfied a ROLES template here: the index listed a row whose page then 404'd, which is
both a disclosure and exactly the scope/predicate divergence the agreement matrix claims to
prevent. **The matrix could not catch it**, because its `Auditors` role was granted to nobody in
any project, so both answers were "no" for a reason unrelated to the bug. **Two assertions were
tautologies**: `assert_include @project.name` against a page whose title, breadcrumb and menu all
carry it, and `assert_include '1'` against a full HTML page — the second was T-23's headline
`Accept:` item. Both are sentinels now, and the query test asserts the SAME request without the
query answers differently.

**And three defects were found by the new tests themselves, not by the review.** The scope and the
predicate disagreed for an ADMINISTRATOR (core has the same split; here it would have let an
admin edit and delete a template their own index did not list) and again for ANONYMOUS
(`author_id == user.id` matches `User.anonymous`, which is a real row with a real id). The archive
refusal raised `NoMethodError` — `Render::Success` has no `correlation_id` — the moment the test
for it stopped being shadowed by "no engine registered". All three were invisible while a test was
weak, and each became a one-line fix the moment the test was not.

**~~S-9~~ · CLOSED by curator decision, 2026-08-09: the `migrate-updown` job gained a
DATABASE AXIS.** Eight cells rather than four — every Redmine branch still on PostgreSQL,
plus MySQL 8 and MariaDB 11 on 6.1-stable and 7.0-stable. The two axes answer different
questions (Rails' DDL changing under us; the database's own semantics), so the full
4x3 cross-product buys little for triple the cost.

**Measured before it was wired, not pushed and hoped for.** `script/migrate_updown.sh` was
run locally against **MariaDB 10.11** and passed BOTH arms — which also confirmed the
premise the axis rests on: `script/schema_snapshot.rb` uses ActiveRecord's `columns` and
`indexes`, so it records ENGINE-NATIVE types (`int(11)`, `varchar(255)` where PostgreSQL
says `integer`, `character varying`) and the comparison is before-against-after on ONE
engine. Nothing compares two engines to each other, which is what would have broken.
**MySQL 8 is CI's first look** — that cell is honestly unverified until it runs (INV-7).
The original report follows.

**S-9 · G11's engine coverage is PostgreSQL only, and the CI comment first claimed otherwise.**
The `migrate-updown` job runs four Redmine branches on PostgreSQL. The engine-dependent properties —
identifier length limits (the defect that aborted migration 002 on PostgreSQL and would have
SUCCEEDED on MySQL), a unique index over a nullable column, `date` round-tripping — live in
`test/unit/reporter_dashboards_schema_test.rb`, which runs in the `minitest` job, which is also
PostgreSQL only. Closing it means a database axis on one of those jobs or moving those assertions
into `spec/adapter`, which already runs all three engines. **Owed, and named rather than implied.**

**S-6 · `reporter_dashboards_documents` is marked "required" and no document states a single column
of it.** `technical-spec.md:1203` requires the table; `:1213-1217` gives the policy (opt-in, a
mandatory TTL, a purge task); `functional-spec.md:348` says in as many words that **"No retention
model has an owner yet."** T-22 created it because §7 requires it, deriving every column from a
stated requirement and naming that requirement in the migration.

**~~S-6~~ CLOSED by the curator, 2026-08-07: the derived columns are approved and §7 now lists
them.** The table stays in T-22 rather than moving to T-28. Rule 6 means a consumer that needs a
different column cannot add one later, so T-28 and T-30 should read §7's row before designing
against it — and if either finds it genuinely short, that is an argument to make BEFORE 1.0 ships,
not after.

**D-1 · `group_by: age` reported everything as `(none)` on MariaDB — FIXED 2026-08-05, in T-08.**
Found by T-01's corpus on MariaDB 10.11, confirmed by the first CI run on MariaDB 11, and **measured
absent on MySQL 8.0.46 and PostgreSQL 16**. The age dimension grouped on a generated `CASE`;
ActiveRecord reads the group key back out of the row **by the expression's own text**, and MariaDB
truncates a returned column label at 256 characters (measured: 261 works, 262 does not). Past it
every key came back `NULL`, the chart collapsed into the empty bucket, and the total was taken from
whichever group the server returned last — so an issue could vanish from the count as well. **Four
boundaries cross the limit and `DEFAULT_AGE_BUCKETS` is four**, so this was the DEFAULT behaviour on
MariaDB, in production. Every existing adapter example used three boundaries or fewer, which is the
only reason CI had been green.

*First written up as affecting "the whole MySQL family" — an inference from one engine, and the
first CI run refuted it.* MySQL 8.0 answers correctly, so the overlay has a **`mariadb` family of
its own**, separate from `mysql`; the adapter name cannot tell them apart (mysql2 reports "Mysql2"
for both), so the family is asked of the server version. That distinction outlives the defect and is
kept.

**The mechanism, measured 2026-08-05 — and it corrected this entry's own original prescription**
("alias the group expression or group on a short one"). Two facts, both probed against the running
stack rather than read off the source:

1. **The alias is already truncated on the engine that WORKS.** ActiveRecord derives the result-column
   name from the group expression's text (`calculations.rb#execute_grouped_calculation` →
   `ColumnAliasTracker#column_alias_for` → `table_alias_for`, which slices at `table_alias_length`).
   On PostgreSQL that limit is **63**, so the age CASE's alias is cut at 63 for three, four and five
   boundaries alike — measured expression lengths 242 / 305 / 368, aliases 218 / 274 / 330 — and
   PostgreSQL answers correctly at every one of them, because AR asks for the same truncated name it
   sent. The mysql2 adapter hardcodes **256** (`mysql/schema_statements.rb:130`), so AR emits a
   256-character alias there and MariaDB hands back a shorter one; MySQL 8 does not. So "the alias is
   too long" was never the defect — *the two ends disagreeing about the truncation* is — and
   shortening the expression only moves the cliff. `MAX_AGE_BUCKETS` is 24, and 24 branches cannot fit
   in 256 characters at ~60 characters a branch.
2. **A select alias cannot be introduced without leaving AR's grouped-calculation path.**
   `execute_grouped_calculation` does `select_values += self.select_values` **`unless
   having_clause.empty?`** — with no HAVING it *overwrites* the relation's select list. Measured:
   `.select("CASE … AS rrd_short").group("rrd_short").count(…)` raises
   `PG::UndefinedColumn: column "rrd_short" does not exist`, because the SELECT that defined the alias
   was discarded.

**So the fix does not change the SQL at all — it changes how the result is READ.**
`SELECT <group expression>, COUNT(DISTINCT issues.id) … GROUP BY <same expression>`, taken back
**by position** with `pluck`, carries no alias for the two ends to disagree about. Same statement,
same GROUP BY, same query count; one method, `measure_groups`, dispatches to `grouped_counts` for
the counting measures. It covers every dimension and crosstabs too, not just `age` — any long
group expression was exposed to the same truncation.

**The first attempt was different, was pushed, and was MEASURED WORSE — this is the finding that
matters most here.** It gave the age dimension `bucket_conditions` and dropped the GROUP BY
entirely, counting each bucket with its own `COUNT(DISTINCT CASE WHEN … THEN issues.id END)` —
the shape `completeness` uses. That is correct, and it is *the plan's own prescription above*.
It is also **dramatically slower on MariaDB, the engine the defect is on**: in the same CI job,
`completeness.seven` (seven conditional aggregates) costs **25-50 s per call** at 10 000 issues
where the grouped age read costs **0.02 s** — and the `adapter (MariaDB 11)` cell went from 5 m 39 s
to over 35 minutes without finishing. The plan checked query COUNT, which is unchanged either way,
and R7 sets no timing gate, so **nothing in the acceptance criteria could have caught this**. It was
found by reading the CI cell rather than by a red test. Recorded here because the same trap is
waiting for anyone who reaches for conditional aggregates to avoid a GROUP BY.

*Deliberately NOT covered, and documented in the README rather than left silent:* an age axis with
a **measure** (`sum`, `avg`, `distinct`) still goes through `.sum` / `.average` / `.count`, each of
which keys its result by the same alias, so it stays exposed on MariaDB past ~4 boundaries. A
**crosstab in count mode IS covered** — it groups on two expressions and is read positionally like
any other counted axis, which the first attempt did not manage. No corpus case and no surveyed
production template reaches a measured age axis (every real template is count mode, and the non-cap
age cases use three boundaries). Covering it means reimplementing three more grouped calculations —
a bigger change than the defect justifies today.

**Verification — and D-1 is now measured fixed on the engine it lives on.** All 176 recorded corpus
values are byte-identical on PostgreSQL with the fix in place (217 corpus examples, 0 failures), the
DB-less kernel suite is green (1 127 examples), and `spec/golden` run from the plugin checkout — where
gate G7 has its git history — is 166 examples, 0 failures, **0 pending**. MariaDB cannot be run in this
container, so **CI run 31036305443 is the measurement: 17 of 17 jobs green**, including
`adapter (MariaDB 11)` and `corpus (MariaDB 11)` with the overlay EMPTY and its exhaustiveness
assertion live.

**The wall clock is part of that measurement, and it is the half a green tick does not show.** The
MariaDB adapter specs ran in **4 m 16 s**, against **5 m 39 s** before the fix — no regression, a small
improvement. That is the number the first attempt failed: the same cell ran over 35 minutes without
finishing. Read it, not just the colour, on any change to how the kernel reads a grouped result.

**Two things a later session should not have to rediscover.** `measure.nil?` alone is the WRONG guard
and it fails SILENTLY — `resolve_measure(nil, nil)` returns `Measure.new(kind: :count)`, not nil, so a
dispatch written that way never fires while every number still agrees. The guard is `measure.nil? ||
measure.kind == :count`. And **no assertion about the numbers can see this fix at all**: on a stub, and
on PostgreSQL, the alias-keyed read answers correctly too. Only assertions about HOW the answer is
fetched can — "reads its groups positionally, never through a column alias", "still groups, in a single
query", and at the adapter level "selects the group expression with no alias, and still groups".
**Write those first.** Note also what did NOT have to change: the kernel still folds whatever keys the
database returned, so the defensive example *"keeps counts for a value outside the expected bucket list
rather than dropping them"* survives untouched. The first attempt had to delete it, which was a signal
about that attempt rather than about the assertion.

**It is also evidence on C-003** (`claims.json`, updated 2026-08-05): the defect was fixed *inside the
ported kernel* under a declared exception, not by the rewrite that claim's `evidence_against`
supposed would be needed. Status and confidence left for the curator.

**A note for T-03's artefact.** The performance baseline was measured against the pre-fix aggregator,
which is exactly why §1's ordering guard put D-1 after it. The R7 *invariants* are hard assertions and
they still pass, query counts included; the *timings* in the recorded artefact now describe an
aggregator one hunk older. No timing is a gate (finding P-3), so nothing is red — but the artefact is
not re-measured, and that is deliberate rather than overlooked.


**D-2 · the plugin could not run on Redmine 5.1 at all — FIXED 2026-08-05.**
`app/models/reporter_project_tab.rb:3` read `class ReporterProjectTab < ApplicationRecord`, and
Redmine 5.1 has no `ApplicationRecord`: that class arrived in 6.0. Every dashboard page and every
plugin test on 5.1 raised `NameError: uninitialized constant ApplicationRecord`. The line shipped in
v0.5.0; the README listed 5.1 as tested. Nothing caught it because the full-application suite could
not run in CI until T-09 removed the private-plugin secret — **its first 5.1 run reported 92 errors,
all this one line.** That is INV-7's failure mode exactly, and the sharpest possible argument for
T-09 having been worth doing.

Fixed here rather than deferred: `app/models` is not the frozen kernel and no ordering guard covers
it. `RedmineReporterDashboards::Compat.base_record` returns `ApplicationRecord` where it exists and
`ActiveRecord::Base` where it does not — the two are behaviourally equivalent for a plugin model,
verified against 5.1-stable's `config/initializers/10-patches.rb`, which monkey-patches the identical
`human_attribute_name` body onto `ActiveRecord::Base` that 6.x moved into `ApplicationRecord`. This
is the **first entry in `compat/`**, and it lives in `lib/redmine_reporter_dashboards/compat.rb`
rather than `compat/base_record.rb` because Redmine puts a plugin's `lib/` on the autoload paths and
Zeitwerk requires the path to match the constant.

**D-3 · `sprite_icon` does not exist on Redmine 5.1 either — FIXED 2026-08-05.** With D-2 fixed, the
same 5.1 job went from 92 errors to 27, all of them
`ActionView::Template::Error: undefined method 'sprite_icon'`. `IconsHelper` arrived in Redmine 6.0;
13 call sites in 9 files called it unguarded. The interesting part is that the *design* was already
right — every one of those links already carries Redmine 5's CSS icon classes
(`class: 'icon icon-settings'`) and `_report.html.erb` even documents "on Redmine 5 it renders no
`<svg>`, so the label gives the link a body". Only the belief underneath was wrong: on 5.1 the method
does not render nothing, it does not exist. So the fix is one helper —
`ReporterProjectPagesHelper#reporter_dashboard_icon`, branching on the `reporter_dashboard_svg_icons?`
predicate that was already there for the move controls — and no icon-name mapping at all, because the
class on each link already IS the 5.1 icon. Both branches are asserted by stubbing the predicate, so
the 5.1 path is testable on a machine that cannot run 5.1.

**The corpus had a gap, and T-02's data found it.** The production survey showed every template
writes `age_buckets: "30;60;90;180"` — the STRING form. `normalize_age_buckets` accepts a string or an
Array, and the corpus only ever asked for the Array, so the branch every real caller goes through was
unfrozen. Two cases added (`;` and `,` separated), plus an assertion that the string and Array
spellings answer identically. Three boundaries, not production's four: four was defect D-1's trigger
and belongs in `cap/age.*`, not in a parser case. That reasoning is spent now D-1 is fixed, but the
case stays where it is — a parser case should test the parser, and `cap/age.*` is where boundary
counts are exercised.

**E-1 · an environment fact worth not rediscovering: MySQL 8 ignores a `projects`-keyed subquery in a
LEFT JOIN's ON clause.** Measured on 8.0.46 while fixing the above: `projects.id IN (SELECT …)`
inside a `LEFT OUTER JOIN … ON` is evaluated as TRUE — an entitlement check written that way passes
for everyone. `issues.project_id IN (SELECT …)` and a literal `projects.id IN (1,2,3)` are both
correct, and PostgreSQL and MariaDB get all three right. **No production path is affected**, and that
is checked rather than assumed: `TimeEntry.visible_condition` reaches `projects` but emits literal id
lists (`Project.allowed_to_condition`), and `IssueCustomField#visibility_by_project_condition` does
emit a subquery but keys it on `issues.project_id` (`custom_field.rb:262`). The adapter harness had
invented the one shape Redmine never produces, so MySQL made the *harness* lie about visibility —
caught by the first CI run, and now the stub emits what Redmine emits.

**P-1 · the query-count control was a guess, and the measurement said so.** T-03's first draft
asserted one global ceiling — "no workload issues more than 12 queries" — and `version_rollup` issues
**18**. The interesting part is which of the two possible explanations it was. It issues 18 at 100
issues and 18 at 10 000: eleven grouped aggregates, the closed-status lookup, the cost-field
resolution and one grouped sum per cost field, none of which scale with rows *or* with the number of
versions. So the finding was the ceiling, not an N+1 — and a guessed ceiling cannot tell you that,
which is the whole argument for T-03 existing. The control is now
`PerformanceCases::QUERY_BUDGET`: one **measured** figure per workload, asserted as a ratchet
(`<=`), so a kernel that gets tighter passes and a kernel that adds a query fails with the workload
named. Every figure is also carried per cell in the artefact, so a later reader can see what was
true when.

*The same measurement caught a second thing, and this one was mine.* `completeness.seven` asked for
`assigned_to` and `done_ratio`. Neither is a completeness field — `assignee` is the alias and
`done_ratio` is not offered — so the kernel warned, dropped both, and the cell measured a **five**
field panel under a seven-field name. Every entry point logs-and-degrades on an unusable argument,
which is right for a template author and silent for a benchmark. `EXPECTED_RESULT_SIZE` now pins
what each workload must give back, asserted on every engine: a workload that quietly answers a
smaller question gets faster and reads as an improvement.

**P-2 · T-03's HTML|PDF half cannot be measured here, and the artefact says so rather than omitting
it.** The Accept list's axis is (reference template × issue count × **HTML|PDF**). The aggregation
axis is measured — 9 workloads × 3 issue counts, 20 warm runs after 3 discarded, provenance-stamped.
The render axis is not, for two reasons that are facts about the tree rather than decisions: **the only
Liquid renderer today is `redmine_reporter`'s**, a separate private plugin (T-10…T-15 build the
owned one), and **there is no PDF engine reachable from this session** — the curator has said a
running Gotenberg is not something they can provide. So all 12 render cells are written into
`spec/golden/performance/baseline.json` as `blocked`, each naming **T-10** as the task that owes it,
and a DB-less spec asserts they are all still declared blocked. An unmeasured cell written down as
unmeasured is a pause point; an unmeasured cell that is simply absent is a baseline quietly claiming
coverage it does not have — INV-7's rule applied to performance instead of to versions.

**P-2 IS NOW FULLY FALSE, measured 2026-08-10 — both premises, and the cells were still
blaming T-10 four tasks after T-10 closed.** The entry below records the half-retraction of
2026-08-05; this is the rest of it, and the reason it matters is that a blocked cell naming a
completed task reads as coverage that is coming rather than coverage that is owed. That is the
INV-7 failure this artefact exists to avoid, committed *into* the artefact.

| P-2's premise | status |
|---|---|
| "the only Liquid renderer today is `redmine_reporter`'s" | **false.** T-10…T-19 are done; `Reporting::ReportRun#call(pdf:)` takes (template, actor, scope) to HTML and to PDF |
| "there is no PDF engine reachable from this session" | **false, and it was a `uid` problem.** `:chromium_cdp` runs the whole 20-fixture conformance corpus in this container — **20 pass / 0 fail / 0 skip** — once it is not run as ROOT. Chromium refuses its own sandbox under uid 0 and the preflight reports `engine_crashed`; CI never saw it because runners are unprivileged. `wkhtmltopdf` runs 18/0/2 as root, so the failure looks engine-specific and is not. HANDOVER §3 carries the command |

**WHAT ACTUALLY BLOCKS THE 12 CELLS NOW is a harness, and it is a different one rather than a
bigger one.** The aggregation cells are measured in `spec/adapter/`, which is deliberately NOT a
booted Redmine: it builds a synthetic schema with stub models because what it tests is the
aggregator's SQL, not Redmine's authorization (`adapter_helper.rb:17-27`). `ReportRun` needs the
real thing — templates, users, permissions, drops over Redmine's own models — so the render axis
belongs in the minitest environment, which has no bulk seeding at 1 000/10 000/100 000. The cells
are re-pointed at **T-03**, whose row already reads *partly done*, rather than at an invented id,
and `performance_spec.rb` now asserts both that the owner has moved and that the reason does not
name a completed task.

**P-2's premise WAS HALF FALSE, measured 2026-08-05 — and it changed what T-11…T-13 could attempt.**
P-2 gives two reasons the render axis is unmeasurable here. The first still holds: the only Liquid
renderer today is `redmine_reporter`'s. **The second does not.** "There is no PDF engine reachable
from this session" is true of Gotenberg, which the curator said they cannot provide — but
**Chromium 141.0.7390.37 is installed in this container** (`/opt/pw-browsers/chromium`, with
Playwright configured to find it), and `:chromium_cdp` is the plan's own *reference, CI-verified,
default* adapter. So the engine half of T-13 is attemptable locally, and the 12 `blocked` render
cells are blocked on the RENDERER, not on the absence of an engine.

Two things follow, and neither is a licence to declare the axis measured. **A local Chromium is not
a CI-verified engine** — INV-7 forbids claiming an untested configuration, and CI runners would need
their own install step, which is T-12's `render-smoke` job rather than a footnote here. And a
measurement taken against a browser this container happens to ship is not a measurement of the
engine a deployment will use. What it does mean: T-11's readiness protocol and T-13's Chromium
adapter can be **developed and exercised** rather than written blind, which is a different position
from the one P-2 describes.

**P-3 · the timings are noisier than any tolerance anyone would set, measured.** Two consecutive runs
of the identical matrix on the identical machine, minutes apart, moved p95 by up to **×1.26** — and
`version_rollup.costs@100000` came back **invalid** (dispersion 0.417) in the first and valid (0.090)
in the second. The committed artefact therefore has zero invalid cells and that is an accident of when
it was measured, not a property of the kernel. This is the concrete argument for the `[GAP]` in
`functional-spec.md` §R7 being real: a relative p95 gate with any tolerance under ~30% would be red on
a quiet machine's bad minute. So the drift report is labelled **ADVISORY — non-deterministic — not a
correctness guarantee** (`CLAUDE.md` §7), and what carries the weight is the three *absolute* criteria,
which are exact integers and cannot be noisy. **DECIDED by the curator, 2026-08-05: no timing ever fails the build.** The drift report stays
informational. What carries the weight is the three *absolute* criteria, which are exact integers,
cannot be noisy, and already fail on a real regression. A tolerance would need a dedicated runner to
mean anything; the artefact records the CPU model, core count and image digest so that remains
possible if performance ever becomes a real problem, but it is not being set now. **Do not add a
timing assertion without re-opening this.**

*One deliberate widening, labelled as such:* the two reference templates between them reach exactly
two of the kernel's six entry points (`.breakdown` and `.version_rollup`). T-07 and T-08 re-seam all
six, and a baseline over two of them would go stale the moment the re-seam touched the other four —
with no way back to it, which is the reason this task precedes them. So a third pseudo-template,
`production-shapes`, carries seven more workloads drawn from **T-02's survey of the 26 real
templates**, each naming the survey line it comes from. It measures more than the Accept list's axis,
never less.

**D-1's fix as built — the entry above is the current record; this is what the attempt cost.**
The design was written, run, and backed out once on 2026-08-05 before landing. Three measurements came
out of that and all three are folded into the entry above: the fix is behaviour-preserving on
PostgreSQL (all 217 corpus examples passed with it in place), `measure.nil?` is the wrong guard and
fails silently, and the remaining work was 11 named unit examples of which one was a decision about
defensive behaviour rather than a mechanical edit. It was reverted rather than pushed with 11 red
examples because they sit in the *frozen kernel's* unit suite, and rewriting 11 assertions in a
2 800-line file at the end of a session is how a suite starts lying — see §1b: local red is fixed or
reverted, only an engine that cannot be run here is left to CI.

**F-7 · CLOSED 2026-08-06 by T-13.** T-11's falsifier was owed because it is a statement about
WALL CLOCK THROUGH A REAL ENGINE and no engine existed. It now runs as conformance fixture
`F-13-readiness-late-signal`: one chart signals at 6 s and writes a marker into the DOM immediately
before calling `end()`, and the harness measures monotonically. **3 of 3 attempts, 5.9–12 s, marker
present, on Chromium 141.** The three implementations it exists to tell apart are told apart: a
fixed 3-second delay prints before the marker exists; waiting out the timeout costs 20 s and fails
the upper bound (the timeout is 20 s and not the default 10 for exactly this reason — at 10 both
wrong implementations land inside a 12 s bound and the fixture stops discriminating); honouring the
signal costs about 6.3 s.

Five more fixtures came with it and are worth naming, because between them they cover the arms the
original three could not: `F-08` the chart-free document (under 2.5 s), `F-09` three finishing
charts (0.55–2.9 s), `F-10` a never-ending chart cut short by the PAGE's watchdog at 2 s carrying
`client_watchdog`, `F-11` a page with **no readiness component at all** rendered anyway with
`Degradation(:readiness_timeout)`, and `F-12` that same page under `strict` refused with
`Failure(:readiness_timeout)` and no bytes anywhere. F-10 and F-11 are different arms and the
distinction is easy to miss: when the page CAN answer, the in-page watchdog is what answers, and the
engine's timeout is only ever reached by a page whose readiness component is broken or absent.

**E-2 · egress denial was half a control, and only an outside observer could see it.** Found by
`F-15` on the first real conformance run. `--host-resolver-rules=MAP * 0.0.0.0` rewrites **name
resolution**, and a URL carrying a literal IP address never asks the resolver anything — so a
stylesheet, an image, an XHR and a `fetch` at `http://127.0.0.1:<port>/` all reached the harness's
own listening socket. Four hits, from an engine documented as having no network.

Two things follow. The fix: every network scheme is also pointed at a proxy that does not exist, and
the implicit localhost bypass is removed (`--proxy-bypass-list=<-loopback>`) — because localhost is
where a Redmine host keeps everything worth stealing. Four hits became zero. And the method: the
fixture asserts what arrived **at the harness**, not what the page reported. A page reporting an
error about a connection the engine happily opened is precisely the posture INV-8 forbids, and every
version of this check that asks the page instead would have passed.

**E-3 · Chromium prints "Page1of3", and the pixels agree with the extractor.** Found by `F-04`.
Header and footer are their own document in Chromium, and a whitespace-only text node next to an
inline element is collapsed away there — so `Page {{page}} of {{pages}}` loses every space. Fixed
with non-breaking spaces in the literal segments. The rewrite exposed a second defect nobody had
asked about: slot text was being interpolated into that document **raw**, so an unescaped `<` from a
template author would silently break the footer on every page of every report. Authoring is already
a code-execution privilege (INV-9), which is a reason to escape it rather than a licence not to.

**E-11 · the repaired `inline_asset` check went red on wkhtmltopdf on its first CI run — and the
defect was MINE, not the engine's. CLOSED.** Measured in `render-smoke`, run 31078637086.

```
wkhtmltopdf: an inline (data:) image decodes to the right colour — rgb[0, 170, 255], wanted rgb[0, 255, 0]
```

The sampled pixel is the PAGE BACKGROUND where the plate should be. **The previous version of this
check would have reported PASS**, because the probe image was that same colour — which is E-10's
tautology, caught in review, going straight on to earn its keep.

**What was not known at first, and what the NEXT run settled.** Two explanations fit one pixel:
wkhtmltopdf does not decode the `data:` URI at all, or it lays the plate out somewhere other than
`y: 0.12` — it is an old engine and `display: block; height: 20mm` in flow lands wherever its
default `<h1>` margins happen to end. One sample could not tell them apart, and the engine
**cannot be installed in this container**, so guessing at a repair was refused.

**The full report, once the per-check three-state rule made it visible, supplied the discriminator
for free.** wkhtmltopdf passes 8 of 9: `page_breaks` 2 pages, `footer` `Page 1 of 2`, and crucially
`background` reading `page rgb[0, 170, 255], badge rgb[204, 0, 0]` — the badge is
`position: absolute; top: 55%`, sampled at `y: 0.60`, and it is exactly right. So backgrounds print
and absolute positioning works on that engine, in that document.

That is not an argument, it is a technique that is already proven there. The plate is now
positioned the same way — `position: absolute; top: 8%; height: 8%`, sampled at `y: 0.12` — so the
check asks about DECODING and no longer about flow layout.

**CLOSED, run 31079493206. The engine was fine; my document was wrong.**

```
render preflight: wkhtmltopdf 0.12.6.1 (with patched qt) (OK, 380ms)
  PASS  an inline (data:) image decodes to the right colour  rgb[0, 255, 0], wanted rgb[0, 255, 0]
```

Exact. **wkhtmltopdf decodes inline `data:` images correctly** — the failure was the plate sitting
in normal flow, where its position depended on that engine's default `<h1>` margins. Nothing about
wkhtmltopdf needs recording in the support matrix, and the sentence that was nearly written into it
would have been false.

**Do not read this as a case for promoting wkhtmltopdf.** It now passes the preflight 9 of 9 with no
informational skips, which is one document. `verification: corpus` is about T-12's twenty fixtures
and E-5's two open curator items, and neither moved.

The general point: the fix was not to sweep more pixels until something matched. It was to change
the document so one sample can only mean one thing — and doing that turned a finding I was about to
publish about an engine into a finding about my own probe.

**So the three-state rule now applies per check, not just per engine.** `spec/render/preflight_spec.rb`
matches what `conformance_spec.rb` has always done per fixture: an engine the catalogue calls
`verification: corpus` is held to its results, and one it calls `pending` has them **reported and
not enforced** — warned line by line and repeated in the skip reason. That is the E-5 policy, and
its own comment states the limit: this must never become a way to keep a red engine green, and
promotion to `corpus` is the moment every failure has to be fixed, expressed as an undeclared
capability, or argued. **This finding is now one of the things blocking that promotion.**

**E-10 · the preflight's FIRST REAL RUN found three defects, and all three were in the
diagnostic rather than in the engine.** Chromium 141, non-root so the sandbox initialises.

**One: the probe document waited out the readiness watchdog.** 17.5 s, and a degradation reading
`readiness_timeout: 0 chart(s) had not finished after 8000ms`. The probe carried no
`chart_shell.js`, so nothing ever set the ready signal and the engine sat out its full timeout —
the chart-free case, which is precisely the failure `settle()` exists to prevent and which the
shell's own comment calls out ("a page with nothing to draw would be the SLOWEST one to render").
Fixed by inlining the **shipped** shell into `<head>`, so the preflight exercises the file every
real report gets rather than a signal invented for the occasion. **943 ms afterwards**, and the
`readiness` check now reads a `SHELL present` marker back out of the PDF, so the shell failing to
load is a named check rather than a mysterious eight-second pause.

**Two: `File.read` on a host with a POSIX locale killed the whole diagnostic.** The shell came back
tagged US-ASCII — the default external encoding when `LANG` is unset — and interpolating it into a
UTF-8 heredoc raised `Encoding::CompatibilityError`. So the preflight would have died on exactly the
hosts most likely to need one. `spec/conformance/fixture.rb` had already learned this and reads with
`encoding: 'UTF-8'` everywhere; the lesson is now in both places. `PdfInspector.run` was fixed for
the same class of bug in the other direction: `pdftotext` emits UTF-8, and left at the default
external encoding the first accented character in a French report turns a regexp match into
`ArgumentError: invalid byte sequence`.

**Three: two checks reported details that contradicted their own verdict.** The `readiness` check
had two branches for three outcomes, so a document with no marker at all FAILED while its detail
said `loaded`. The hosted-asset check had the same shape and it was worse: a fetch that had not
resolved yet was reported as *"the renderer REACHED <url> — it has network access it is not supposed
to have (INV-8)"*, which would send an operator hunting for a firewall hole that does not exist.
Both now enumerate all three outcomes and say what they actually saw. The underlying race is closed
too — the hosted image is wrapped in `__rd.begin()`/`end()`, which is the shell's documented idiom
and the only place the probe exercises that half of the contract.

**What this says about the preflight rather than about these three bugs:** every one of them
produced a diagnostic that still *looked* like a working diagnostic. Bytes came back, the PDF
opened, the run went green in the places nobody was reading. That is the same shape as the failure
T-14 exists to catch, one level up, and it is why the spec drives all six document checks RED
against a canned single-page PDF before anything is believed about a run where they pass.

**AND THEN REVIEW AND CI FOUND SIX MORE, INCLUDING THE WORST ONE.** A fresh-subagent review plus
the first CI run turned up defects the local green run could not see. The two that matter:

**The `inline_asset` check was a TAUTOLOGY and could never fail for its stated reason.** The probe
PNG was `#00aaff` — *which is also the page background*. The `<img>` has a fixed height, so a
data: URI that failed to decode showed the page through it, the sampled pixel matched, and the check
returned PASS for exactly the defect its own comment says it exists to catch ("an engine can accept
a data: URI, fail to decode it, and draw the broken-image glyph"). Confirmed by decoding the IDAT:
the first scanline is `[0,170,255]`. The negative test could not see it either — it failed that
check against a blank white page, which is not the discriminating case. The plate is now `#00ff00`,
`PLATE_RGB` is its own constant, and two specs assert the colours differ and that a right background
with a missing plate FAILS. **Three documents — the README, HANDOVER and this file — had already
published "9/9 measured" with this check among them.**

**A missing poppler DELETED checks rather than skipping them.** `document_checks` returned one
umbrella `:document` skip and returned early, so on a host without poppler the INV-8 containment
check — the one T-14's Accept list singles out — was **absent from the report**, not unanswered. The
artefact also changed shape between installs, so two JSON reports could not be diffed. Found by
review and independently by CI on all four Redmine branches, where a spec asserting `hosted_asset`
skips found it missing entirely. Every document check is now emitted by name from one
`DOCUMENT_CHECKS` table that drives both the run path and the skip path.

**CI found a third, on wkhtmltopdf: the `degradations` check could never pass on that engine.** It
stamps `legacy_engine` on every render *by design*, and the blocked hosted image produces
`asset_unresolved` — the degradation this probe deliberately provokes, and which `hosted_asset`
already reports as an `expected_failure`. So one report contained two states contradicting each
other. Expected degradations are now named, still printed in the detail, and carry
`:expected_failure`; the asset one only counts as expected when the probe actually asked for a
blocked asset.

Three smaller ones, each real: `Registry::UnknownEngine` escaped `PreflightCommand#call`, so a typo
in `RRD_ENGINE` exited **1** — "render is broken" — instead of 2; `to_text` promised one line per
check and interpolated multi-line engine stderr raw, with a length assertion that could not fail
because every detail it exercised was single-line; and `PdfProbe`'s "hard error, never a skip"
policy stopped applying to the probes themselves once they delegated, leaving two exception classes
for one condition in the file that says why that must not happen.

`PreflightSuite` was extracted in the same pass. The controller and the command had near-identical
copies of "resolve the engines, construct, run, shut down" — which is why the browser-leak fix had
to be made twice on the same day, and is CLAUDE.md hard rule 6 in its concrete form.

**E-9 · the two engines disagreed about whether a blocked asset destroys a report, and the
abstraction is the thing that must not.** Measured across two CI runs on fixture F-15.

Chromium treats a subresource it cannot fetch as ordinary: the image is missing, the report renders.
wkhtmltopdf exits **1** with `Exit with code 1 due to network error: ConnectionRefusedError` — and
writes a perfectly good PDF beside it. Under this adapter's egress denial that is not an edge case,
it is THE EXPECTED CASE: every http reference is pointed at a proxy that does not exist, so any
document naming one takes that path.

Left alone, the two engines would have disagreed about whether a missing image is a failure, which
is the abstraction failing at exactly the point it exists for. So the rule is now the same on both:
**a blocked asset is a Degradation, not a Failure** — `Degradation(:asset_unresolved)`, recorded,
logged and stamped, with the document delivered.

**The guard is the OUTPUT, not the stderr text.** If the bytes are a plausible PDF then a render
happened and something it referenced did not arrive; if they are not, the engine genuinely failed
and the typed Failure stands. Deciding from stderr would be guessing at message strings across
builds, and wkhtmltopdf's exit codes are approximate enough already — it exits 1 for a broken
install and for a missing image alike, which is why the adapter's own comment says the difference
lives in stderr and this one does not use it.

Three DB-less regression tests cover it without the engine, using `/bin/sh` stubs that honour
`build_argv`'s contract (argv.last is the output path): a non-zero exit with a plausible PDF is a
Success carrying the degradation, a non-zero exit with nothing usable is still a Failure, and the
flag does not leak from one render into the next.

**E-14 · the FR-19 lint answered the right question about the wrong text, twice, and both
times because something MENTIONED a `<script>`.** Found by running T-19's own work over
the files it had just edited.

**First: a `{% comment %}` body.** The `HtmlScanner`'s first version skipped the
`{% comment %}` TAG but not its body, so a comment explaining *why* chart data must not be
built by string concatenation — prose containing the word `<script>` — opened a raw-text
region that ran to the next real `</script>` several hundred lines away. The linter then
reported **72 escaping findings in a template that had none**, every interpolation in
between having become "inside a script". Fixed by skipping `{% comment %}` and `{% raw %}`
bodies whole, which is also the right semantics: a comment body is not rendered, and a raw
body is rendered literally so `{{ x }}` in it is text rather than interpolation.

**Second: the README's own prose.** Linting `README.md` as one document produced **23
findings in Markdown**, because the sentence describing this very rule contains a backticked
`` `<script>` `` — which the scanner correctly reads as an element, because in a Markdown
file it has no way not to. The fix is the UNIT, not the scanner: T-19's Accept list says "the
README's own snippets", and a snippet is a fenced block. `spec/shipped_templates_lint_spec.rb`
extracts the 25 ```liquid blocks and lints each.

**Both are the same lesson and it is worth stating once.** A linter that reports findings in
the wrong place is worse than one that misses them: the author checks the line, finds
nothing wrong, and learns to skim. Neither of these would have been found by reading the
scanner — they were found by pointing it at real files and disbelieving the count. The
scanner's spec now carries a case for each.

**A third, smaller one, in the spec rather than the code:** the assertion "no example builds
a JS string by appending a quote" fired on the `{% comment %}` that QUOTES the old idiom for
the next author. Same shape as `layer_purity.sh`'s own note — "a gate that punishes writing
down its own rationale teaches people to delete the rationale" — so the assertion strips
comments and says why.

**E-15 · T-20's `Touches:` list missed a live consumer, and the linter it added was
confidently wrong about a template that had already been migrated.** Two defects, both
found by running the work rather than reading it.

**The consumer.** T-20's acceptance list names three files to delete and says nothing about
`{% version_rollup %}`, which built one addon `VersionDrop` per row. Deleting the class
broke the tag's spec on the first run — a load error, so it was loud — but the underlying
question was not: the owned `Drops::VersionDrop` is the obvious replacement and it
**refuses to be constructed without a `RenderContext`** (INV-1), which no host-plugin render
has. See **F-12**.

**The lint.** `deprecated.geo_version_map` fired on the example template's own header
comment, which explains the migration and therefore names the retired tag. The `:liquid`
scope searched every `{{ … }}` / `{% … %}` in the document, **including the bodies of
`{% comment %}` and `{% raw %}`** — text Liquid never renders and renders literally
respectively, so neither can be the construct a rule is about. `HtmlScanner` already made
this exact decision for `<script>` (E-14); the `:liquid` scope had not. It does now, it
fails OPEN on an unterminated comment, and six examples pin cases the previous version got
wrong. Neither defect was findable by reading; the first needed the suite, the second needed
the linter pointed at a real file.

**E-16 · T-16's falsifier fired on its first run, twice, and both were real.** The
shared-layout claim — "identical in HTML and PDF is a construction" — was measured in a
real Chromium against the vendored Chart.js, comparing `chart.chartArea` with
`ChartLayout#plot` on a horizontal bar with twelve long labels.

**Round 1: right edge 21.88%.** With `responsive: true` Chart.js ignores the canvas's
width/height ATTRIBUTES and sizes itself to its parent's content box, so a chart laid out
for 640px was drawn 768px wide in an 800px document. The two paths were not disagreeing
about a rectangle; they were drawing different-sized charts. Fixed by sizing the frame
(`max-width` so §9b's "responsive down to a phone" still holds below the authored width).

**Round 2: top edge 4.94%.** Chart.js's title box is `lineHeight + padding.top +
padding.bottom` and its defaults are 1.2 and 10/10 — 36.8px against `ChartLayout`'s 19.
The whole plot sat 18px lower in HTML than in its SVG twin. Fixed by pinning the title
font's `lineHeight` and `padding` explicitly, which is the SAME mechanism §6 already
applies to the tick array rather than a tuned constant: both sides now compute the height
from `LINE_HEIGHT_RATIO`.

**Final, measured: left 0.86%, right 0.00%, top 0.22%, bottom 1.17%** — worst edge 1.17%
against a 2% tolerance, and Chart.js used exactly the ticks, min and max it was handed.
Neither defect was findable in Ruby: both paths read the same `ChartLayout`, so a Ruby
test would have compared a number with itself and passed for ever. The bottom edge at
1.17% is the legend box, which is NOT pinned — inside tolerance today, and the reason the
falsifier is wired into the `render-smoke` job rather than run once.

**F-13 / F-13b · CLOSED 2026-08-06 by the curator, in T-33. The tree was wrong; the mechanism
is right; both files stay in neutral namespaces and the gate now enforces it.**

The conflict, restated once so nobody re-derives it. §1.1's tree put `charts/**` and
`asset_resolver.rb` under `render/`. §3.5 puts `charts` on `RenderContext`, which is the
**Liquid** layer. §5.1 requires that "resolution happens **in the plugin, never in the
engine**". And mechanism E3 (`layer_purity.sh`) forbids `liquid/**` from naming
`…Dashboards::Render` and forbids `render/**` from naming `Net::HTTP`, `Faraday`, `cookie`
and `session`. Those cannot all hold: `{% chart %}` has to build a `ChartSpec`, and an asset
resolver is made of the four things `render/` may not contain.

**The decision, and the reasoning rather than the verdict:**

1. **E3 is not an accident of wording; it is §5.1 and INV-8 in executable form.** The whole
   content of the asset inversion is that *the renderer is never the thing holding the
   network*. A fetcher inside `render/` would contradict the invariant that directory exists
   to protect. This is not a gate being awkward about a file's address — it is the gate
   agreeing with the specification against the tree.
2. **The render layer's own contract already places resolution upstream of it.**
   `document_request.rb` says `body` is "a COMPLETE, already-asset-resolved document
   precisely so the engine never fetches anything on the viewer's behalf". By the time
   anything in `render/` runs, resolution is *over*. So the resolver is not merely allowed to
   live outside `render/`; it is required to, or that sentence is false.
3. **When a listing and a mechanism disagree, the mechanism wins — and the listing gets
   corrected.** The mechanism has a test and a negative test. §1.1 has neither. The tree is
   now amended (`charts/` and `assets/` as siblings of `render/`), so the next task reads a
   tree that matches the repository.
4. **A neutral namespace says something true rather than dodging the question.** `ChartSpec`
   is a value object the Liquid layer builds and the render layer draws; `AssetResolver`
   produces the render layer's *input*. Both are upstream of, or shared between, the two
   layers E3 separates. Putting a shared value object inside one of the two is what created
   the conflict.
5. **The cost of the alternative is the reason it was rejected.** Moving both under `render/`
   requires deleting E3's `Liquid` pattern and its `Net::HTTP` pattern — the two with the most
   security weight in the gate. CLAUDE.md §7: "never make a hard gate advisory to get to
   green".

**And a hole was closed while settling it.** "Names neither layer" was, until now, a property
nothing checked, so the boundary held only until somebody followed two hops — `liquid/` names
`charts/`, `charts/` names `Render`, and a per-file grep sees no violation in either file.
`layer_purity.sh` now has an arm for `charts/**` and one for `assets/**`, each forbidding
**both** `…Dashboards::Render` and `…Dashboards::Liquid`, and both were **negative-tested**
(a planted constant in each direction fails the gate; a comment naming the same constant does
not, which is the gate's existing comment-stripping rule). `assets/**` is deliberately *not*
forbidden `Net::HTTP`: being the one place in the plugin that holds a socket is its whole job.

What sits at the address the tree used to give `asset_resolver.rb` is
**`render/asset_binding.rb`** — the render layer's statement of how an `Assets::Resolution`
becomes a `DocumentRequest` or a `Failure(:asset_unresolved)`. It constructs render types and
does no resolving: no socket, no file, no model. A spec asserts that by reading the file's own
non-comment lines, so the claim is not only a grep in CI.

**F-14 · CLOSED 2026-08-06 by the curator, in T-33: the derivation stays, and NO
`:responsive_canvas` capability is added. The clause means "not from the author".**

The question was whether §6's "emits it from the **engine's capabilities**, not the author's
choice" requires a formal entry in `Render::Capabilities::ALL`. It does not, and the reason is
not that adding one is expensive — it is that responsiveness is not the kind of fact a
capability can hold.

1. **A capability answers "can the engine do X?" and feeds a negotiation with three
   outcomes** — refuse (essential and missing), degrade-and-record, proceed
   (`Capabilities.negotiate`). Responsiveness has none of them. There is no engine that
   "cannot do responsive": every engine in the matrix draws a fixed page of known size, and
   reflowing is a property of a live browser window rather than of an adapter. A capability
   nobody can fail is a capability that does nothing.
2. **The `:html` binding has no engine at all — and that is the binding that wants
   `responsive: true`.** `{% chart %}` renders into a live Redmine page with no
   `DocumentRequest` and no adapter. A capability set is a property of an engine adapter, so
   on the very path where the answer is "yes", there is nothing to ask. **A capability whose
   value must be known where no engine exists is not a capability.** This is the argument that
   settles it; the rest is cost.
3. **The cost, for completeness.** Not one matrix regeneration: a row in `capabilities.yml`
   for all three engines, the per-adapter equality assertion `conformance_spec.rb` makes
   between `CAPABILITIES` and the YAML, and a G9 matrix change — to add a column reading "no"
   three times and "n/a" for the binding that wanted it. An operator learns nothing from that
   cell.

**What the clause is FOR was hardened instead.** G3/FR-34 wants a template to need no
engine-specific workaround, i.e. the author cannot set it. That was true only because nothing
happened to read a `responsive:` parameter. `spec/charts/charts_spec.rb` now asserts that
`ChartSpec` has no `responsive`, `animation`, `devicePixelRatio` or `device_pixel_ratio`
parameter — a future field with one of those names has to break a test — and that the derived
values do not move for anything an author can write into a spec. The mechanism is in the
emitter's own comment and in §6.

**If it is ever revisited:** the honest shape is not a capability but an explicit `binding:`
on the render request (`:screen` / `:print`), which is what `output` already is. The
`ChartjsEmitter` comment says so.

**F-15 · ANSWERED 2026-08-06 in T-33. The absolute URL exists; it is the WRONG TOOL; and the
blocker is not the URL. Split out as T-39, which is the only honest disposition.**

The curator asked where the absolute plugin-asset URL should come from. Checked, and there are
three separate answers, of which only the third matters.

**1. Where it comes from, for the record.** `Setting.protocol` + `Setting.host_name` — which is
what Redmine itself uses everywhere it must build a URL with no request to hang one off (mail,
notifications). `Liquid::Drops::AbsoluteUrl` already wraps that pair for the drop layer;
`Assets::Origin.from_settings` now parses it for the asset layer, which has to COMPARE hosts
rather than concatenate them. Both preserve a sub-path prefix, which is the install a hand-built
URL goes wrong on. So there was never a missing mechanism.

**2. Why it must not be used here.** `<script src="https://redmine.example/plugin_assets/…">`
turns a file sitting on the same disk as the renderer into an **egress requirement**. It fails
on every install where the application cannot reach itself by its public name — internal DNS, a
reverse proxy terminating TLS, a container with no route back — and it is precisely what
`asset_policy: :bundled` exists to refuse. T-33's resolver runs the opposite direction: a
same-origin URL is mapped BACK to the file on disk and inlined (§5.1's `:bundled` row). Building
the URL would be work whose only purpose is to be undone.

**3. The actual blocker, which is NOT the URL.** `{% chart %}` returns
`placeholder(refused: 'no_render_context')` when there is no owned `RenderContext`
(`chart_tag.rb:63`), and a Reporter-rendered template has none — so the two legacy examples
cannot migrate to `{% chart %}` at all until the owned render path exists (T-23 onward). That is
the real reason T-16 could not touch them, and it is deeper than the sentence this finding used
to carry.

**What that leaves, and why it is a task and not a line in this one.** The correct fix for the
two examples is to stop naming the library by URL and let the plugin put the vendored bytes in
the document — for which T-33 supplies the reader (`Assets::BundledAssets` +
`Assets::LocalStore`, digest-checked against `THIRD_PARTY.md` by a spec). But inlining Chart.js
**4** under configs written for **2.8** breaks the charts, so the migration is inseparable from
the 2→4 config rewrite §6 enumerates (`scales.xAxes[]`→`scales.x`, `options.legend`→
`options.plugins.legend`, `horizontalBar`→`bar`+`indexAxis:'y'`, `getElementAtEvent`→
`getElementsAtEventForMode`, `ticks.fontSize`→`ticks.font.size`). And verifying THAT needs a
host-plugin render of those templates in a browser, which this repository cannot perform — the
host plugin is private (CLAUDE.md §11.6, "something you cannot reach").

So: **T-39**, with its verification obligation stated rather than assumed.
`VENDOR_INTEGRITY_MODE` stays **warn** for exactly the two lines
(`sample_report_template.liquid:82`, `version_status_dashboard.liquid:147`), the gate's own
comment now names T-39 instead of "whoever retires them", and the ratchets in
`shipped_templates_lint_spec.rb` are unchanged. Flipping to strict is T-39's deliverable, and
it is 2 lines of gate configuration behind a real body of verified work — not the other way
round.

**F-11 · `issue.target_version` has a WINDOW with no implementation, and it is T-20's doing.**
The prepend into the host plugin's issue drop is deleted, as T-20 requires. The accessor did
not vanish from the vocabulary — `Drops::IssueDrop` carries `target_version` (alias of
`version`) and `custom_field_value` — but **nothing constructs a `Drops::IssueDrop` yet**, so
between this task and **T-23** a Reporter-rendered template gets Reporter's drop and both
accessors resolve to nothing. Liquid renders that as empty rather than as an error, which is
the silent shape INV-4 dislikes.

This is a consequence of the plan's own ordering (T-20 depends only on T-18; the producer
arrives with T-23), not a mistake in the implementation, and it was **not** resolved by
inventing a producer — HANDOVER §6 forbids exactly that. It is recorded because the honest
options are a curator's: ship the window and say so in the CHANGELOG (**what was done** —
the entry states it plainly, and the deprecated `{% geo_version_map %}` reaches the same
version metadata meanwhile), or hold the deletion until T-23 lands. The second costs an
allowlist entry and a monkey-patch for one more release; the first costs a feature gap in
templates that use it.

**CLOSED 2026-08-06 by the curator: ship the window.** The first option, which is what T-20
already did — so nothing changes in the code. What the decision buys is that the CHANGELOG
entry is now the AGREED disposition rather than an implementer's default, and T-23 inherits
the obligation to close the window rather than the option of noticing it. The deprecated
`{% geo_version_map %}` remains the interim route to the same version metadata, and that is
the sentence a template author needs; it is in the CHANGELOG in those words.

**F-12 · `Liquid::TagContext` reads `User.current`, and whether that is INV-1 kept or INV-1
bent is a curator call.** F-11's consumer needed answering: `{% version_rollup %}` must hand
templates a version object, `Drops::VersionDrop` requires a `RenderContext`, and a
host-plugin render has none. Three options were on the table.

| Option | Cost |
|---|---|
| Refuse without a context | 100% of live installs lose the version links in every dashboard built on the tag |
| Return a plain Hash | EAGER, so `completed_percent` runs a query per version whether or not the template prints it; and `{{ v.version }}` stops substituting for the name |
| Read `User.current` once, at the tag boundary, into an explicit context | one named module, one branch, `owned?` so a spec can tell the two apart |

The third was built (`liquid/tag_context.rb`, 12 examples). The argument for it: INV-1 is not
"never touch `User.current`" — Redmine has no other answer to *who is this request for* — it
is "never touch it AMBIENTLY, three frames deep, where nobody can see it happened". The
argument against it: HANDOVER §6 says not to have the glue synthesise a `RenderContext`, and
a reader who remembers that sentence and not its reason will read this as the thing it
forbids. **It is not: the fallback carries an actor and nothing else — `scope` and `query`
are nil — so no scope archaeology happens behind a new name, and `TagContext.owned?` keeps
the owned path distinguishable rather than laundered.** Recorded so the decision is
reviewable rather than discovered.

**F-10 · `| inline` is deferred to T-33, and the curator may want it sooner.** §3.6 lists it
among the filters T-19 reimplements, and T-19 shipped without it. The reason is an ordering
fact rather than a preference: `| inline` embeds asset bytes in the document, and WHICH
mechanism it may use — `data:` URI, request upload, or refuse — is `asset_policy`, which
**T-33** builds (§5.1: three models, one policy, `:bundled` by default). A filter that
embeds bytes without consulting that policy is a second embedding path, and T-33's
acceptance list explicitly requires that "an author **cannot** widen egress from template
content". It would also be rewritten by T-33.

**Nothing loses a capability by waiting**: the owned render path is not wired up, and the
`file_url` that `| inline` replaces was never registered by this plugin — it is the vendor
gem's, and the gem is what this plan removes. Recorded rather than decided because it is a
scope call: if a real template needs to embed an attachment before T-33 lands, that is worth
knowing. `Filters::DEFERRED` names the task, and a spec asserts the filter is absent so it
cannot be added here by accident.

**STILL DEFERRED after T-33, and the reason has changed — so it is worth reading rather than
assuming.** T-33 built `asset_policy`, which was the stated blocker, and did **not** add
`| inline`. What T-33 also established is that the filter is no longer needed for the case it
was wanted for: `Assets::Resolver` walks the finished document and inlines every local
reference, so an author writing `<img src="/attachments/download/7/plan.png">` on the owned
path gets the bytes embedded **without any filter at all** — provided the caller supplies the
attachment mapper (`LocalStore#mappers`, the port that keeps the visibility decision with the
actor, INV-1).

So `| inline` has narrowed from "the embedding mechanism" to "an explicit override of it", and
the remaining question is whether a template needs one. That is a real question and it belongs
with the producer that first has a document to resolve — **T-23** — not with the layer
underneath it. `Filters::DEFERRED` should be repointed from T-33 to T-23 when that lands; it is
left naming T-33 today because moving it now would claim a decision T-23 has not made. The
security property is unchanged either way: any `| inline` must go through
`Assets::Policy`/`LocalStore`, or it is the second embedding path this finding exists to
prevent.

**F-17 · RESOLVED 2026-08-06 BY THE CURATOR, and the answer reframes the product rather than
picking one of my three options.** Read this before F-17's original text below, which is kept because
its measurements are still the evidence base.

**The curator's statement of intent, which was not in any spec document:** *"the whole idea was that
we want a modern system accepting most modern forms of javascript to be used in reports. This way
managers can create fantastic reports with chart.js, use mermaid charts and also support any other
reasonable or new javascript script to improve the templates. We didn't want a specific management of
specific javascript libraries. We just used chart.js and mermaid as examples."*

**That makes the SVG sanitiser theatre, and the reasoning is worth keeping.** The sanitiser exists to
strip `<script>` from Mermaid's output — in a document where the author may write `<script>` directly,
because that is the product. INV-9 already says so in as many words: template authorship IS code
execution, and T-27 ships the permission label *"Author report templates (executes server-side
code)"*. A control that stops a library doing what the author is explicitly allowed to do himself is
not a control; it is a cost with a security-shaped name. **Dropped.** `securityLevel: 'strict'` and
`htmlLabels: false` stay as Mermaid *defaults* — they cost nothing and they are one less thing an
author has to know — but nothing downstream depends on them being honoured, because nothing needs to.

**WHAT THE REAL CONTROL IS, and it is already built.** The threat that survives the reframing is not
the author; it is **Redmine content flowing into a document**. Issue subjects, custom field values and
version names are written by every user, not only by template authors — so the curator's *"the content
will be content from redmine"* is the one part of the framing that is not automatically safe, and it
is precisely the boundary FR-19 already guards: `| json` / `| js`, the `HtmlScanner` lint, and T-19's
43-payload regression table. That boundary gets **tighter** under this decision, not looser, because
it is now the only one. Same for `{% mermaid interpolate: true %}`: interpolating issue text into a
diagram is the one Mermaid-specific path where a non-author's bytes reach the output, so `interpolate:`
must escape or refuse rather than pass through.

**WHAT IS NOT RELAXED, stated so a later reader does not over-read this decision.** Two server-side
controls have nothing to do with author-written JavaScript and stay exactly as they are:

* **T-33's asset policy.** It stops the RENDERER fetching arbitrary URLs — SSRF originating on the
  server, under no author's control and outside the browser's own sandbox. INV-8 is untouched.
* **The Liquid execution policy** (T-17) — resource limits and the deadline. A runaway template is a
  denial of service whoever wrote it.

**AND ONE CONSEQUENCE THE CURATOR SHOULD OWN KNOWINGLY.** For the PDF path this is genuinely safe: the
engine has no network (INV-8, measured by `F-15-egress-denial`) and the output is a document. For the
**live HTML** path, author-written JavaScript runs in the *viewer's* browser with the viewer's
session — so "may author templates" becomes operationally equivalent to "may run code as any user who
views a report, including an administrator". That is not an argument for a sanitiser (a sanitiser on
Mermaid's SVG would not touch it). It is an argument that the permission must be treated as
administrator-adjacent — so the answer to the curator's *"I hope this is more or less safe"* is:
**yes for PDFs; for on-screen reports it is as safe as the trust placed in whoever holds the
authoring permission, and that permission is the control.** That made `[OQ-F]` the load-bearing
decision of this whole area rather than a naming question, and **it is now settled**: the curator
rejected the `template_authoring` setting outright on 2026-08-06 in favour of role permissions
granted the normal Redmine way. See **T-40** and `technical-spec.md` §4.1 — four authoring
permissions, `require: :member` derived from the fact that they execute code, and nothing in this
plugin granting any of them. **With one honest limit T-40's review established:** core's
`DefaultData::Loader` hands the **Manager** role every setable permission on a fresh install, so
`:admins_only` is not a construction guarantee — which is why the upgrade diagnostic has to list the
roles holding *our* authoring permissions, not only the base plugin's.

**T-35 IS RE-SCOPED, because as specified it is exactly the "specific management of specific
libraries" the curator does not want.** A `{% mermaid %}` tag, a vendored Mermaid, a `:mermaid`
capability and a Mermaid-specific degradation are four pieces of per-library plumbing. What the stated
intent asks for is generic, and **most of it already exists**:

| what a template needs | what already provides it |
|---|---|
| include any JS library, offline, no CDN | T-33's resolver inlines any local reference; `{% chart %}`'s vendored Chart.js is the pattern |
| tell the renderer "wait for my script" | T-11's `window.__rd.begin()/end()` — already engine-independent and already documented as the contract |
| know whether the engine can run it | `:javascript` — plus the new capability below |

So T-35 shrinks to: **vendor Mermaid as a convenience** (so it works offline like Chart.js), a thin
block tag for the ergonomics, and no sanitiser. The `MermaidSpec`/collector machinery mirroring
`{% chart %}` is no longer justified — `{% chart %}` needs it because the PLUGIN computes the layout;
Mermaid computes its own, so the tag can emit a `<pre class="mermaid">` and the shell can run it.

**REPLACE `:mermaid` WITH A CAPABILITY ABOUT MODERN JAVASCRIPT, which is the generic form of OQ-L's
answer and strictly more useful.** The measurement (E-18, §6.1) found that wkhtmltopdf does not fail
at *Mermaid* — it fails to **parse** `||=`, and `globalThis` is undefined. That is true of every
modern library, not one of them: Chart.js 4 today, whatever a manager reaches for tomorrow. A
`:mermaid` capability would answer one question and lie by omission about all the others. A capability
meaning *"this engine runs post-ES5 JavaScript"* tells an author the truth once, satisfies F-14's test
(an engine either does or does not; absence degrades and is recorded), and needs no new entry when the
next library arrives. Suggested name `:modern_javascript`; wkhtmltopdf declares `:javascript` and not
this.

**F-17 · T-35's "one sanitiser, two producers" CANNOT hold as written, and the measurements to
settle it are done. CURATOR DECISION NEEDED before the task is built.**

Started T-35 on 2026-08-06 and stopped at its foundation, because the first decision determines the
whole task and §6.1 contradicts itself about it. Everything below is measured, so the decision is a
choice between named options rather than an investigation.

**THE CONTRADICTION.** §6.1 says *"the rendered SVG is sanitised by the plugin after Mermaid produces
it, not trusted because Mermaid was configured"*, and T-35's `Accept:` says *"one sanitiser shared
with `SvgRenderer`"*. But the same section's own design has **Mermaid running inside the browser** —
`startOnLoad: false`, rendered by the chart shell, on both the `:html` and the `:pdf` path. So:

* on the **`:html`** path the SVG exists only in the viewer's browser. The plugin never sees it, and
  there is no server-side moment in which to sanitise anything. This is also the path where the
  threat is worst: a `<script>` in the SVG runs with the *viewer's* session, which is XSS.
* on the **`:pdf`** path the SVG exists inside the render engine. The plugin could fetch it back
  (`Runtime.evaluate` → `outerHTML`), sanitise in Ruby, write it back, then print — one extra round
  trip per diagram, and only on engines it drives over CDP. Not Gotenberg, which is handed a document.
* `SvgRenderer`'s output is the only one that is genuinely server-side.

So "one sanitiser" is satisfiable for two of the three producers and impossible for the one that
needs it most. Same shape as F-13: three statements, all reasonable, that cannot all hold.

**THE OPTIONS, with what each costs.**

| | shape | cost |
|---|---|---|
| **A** | One **allowlist** in Ruby as the single source of truth, emitted into the page as a `<script type="application/json">` data block (the mechanism `{% chart %}` already uses); one Ruby sanitiser for `SvgRenderer` and the PDF round trip; one JS enforcer reading the same allowlist for the live page. Shared test set runs the same payloads through both, Ruby directly and JS under node (T-19 already runs node) | two enforcers. `ScriptSafeJson` exists precisely because "two copies of a security-bearing escaper" is bad — mitigated by there being one allowlist and one test set, not one of each |
| **B** | Ruby only. Accept that the live HTML page is unsanitised and rely on `securityLevel: 'strict'` there | §6.1's own rule is "not trusted because Mermaid was configured", and this is exactly that. Leaves XSS on the path where a viewer's session is present |
| **C** | Sanitise nothing client-side and drop the `:html` path for Mermaid — diagrams in PDFs only | loses the authoring preview, which §9b.2 requires |

**Recommendation: A**, and amend §6.1 from "one sanitiser" to *"one allowlist, enforced at every
point where SVG the plugin did not compute reaches a document"*.

**THE SECOND DECISION, smaller: what parses the SVG.** Nokogiri is a Rails dependency so it is
present in every Redmine install, but it is **not** in the bare Ruby `spec/` runs under (mechanism
E2) and this repository has deliberately avoided it before (`liquid/html_scanner.rb:22` explains
why — no byte offsets). For a *sanitiser* byte offsets are irrelevant and parser correctness is the
whole product, so Nokogiri is the safer choice and hand-rolling is the consistent one. My
recommendation is **Nokogiri**, with the reason written down: T-33's `DocumentScanner` hand-rolls a
tokenizer and the review still found three parsing defects in it, and that one only had to *find*
references rather than decide what is safe.

**WHAT IS ALREADY MEASURED, so neither decision needs new work to evaluate.** All figures from real
renders on 2026-08-06 (Mermaid 11.16.1 through Chromium 141; `SvgRenderer` through its own path):

* **Mermaid renders all six diagram families** — flowchart, sequence, gantt, pie, class, state — with
  `securityLevel: 'strict'`, `htmlLabels: false`, `flowchart.htmlLabels: false`, and **no errors**.
* Its output uses **15 distinct elements** (`circle defs feDropShadow filter g line marker path
  polygon rect style svg symbol text tspan`) and **61 distinct attributes**.
* **Zero `<foreignObject>` and zero `<script>`** in any of the six. So the two constructs §6.1 names
  are not things Mermaid emits in this configuration — dropping them costs nothing and is pure
  defence against a configuration that stops being honoured, which is the point.
* **Every diagram emits exactly one `<style>` element**, 5.5 KB of it. **Dropping `<style>` would
  strip all diagram styling**, so the allowlist has to keep it — and its content was checked for
  every CSS vector: `@import`, `url(`, `expression(`, `javascript:`, `behavior:`, `-moz-binding`,
  `@font-face` are **all absent**. So "keep `<style>`, refuse any CSS containing those" costs
  legitimate output nothing. Inline `style` attributes are only `stroke-width`/`stroke-dasharray`.
* Mermaid emits **no `href` or `xlink:href` at all** (only `xmlns:xlink`), so the drill-through
  exception in §6.1's rule is `SvgRenderer`'s alone.
* **`SvgRenderer` emits 10 elements** (`a circle desc line path polyline rect svg text title`) and
  **33 attributes**, including `href`, `xlink:href` and `target`. The union of the two producers is
  **19 elements**, which is the allowlist's real size — and note that routing `SvgRenderer` through a
  sanitiser is NEW: it does not pass through one today, so the allowlist must be proven not to mangle
  our own charts, which is a test the acceptance list implies and does not name.

**Also worth knowing before the task starts:** `:mermaid` has to join `Render::Capabilities::ALL`,
which is a CLOSED vocabulary — and it qualifies under F-14's test where `:responsive_canvas` did not:
an engine either runs Mermaid or it does not (measured: Chromium yes, wkhtmltopdf no), absence
produces `Degradation(:mermaid_unsupported)`, and that is a real three-outcome negotiation. It costs
`config/capabilities.yml` for three engines, the adapters' `CAPABILITIES` constants, and a G9 matrix
regeneration — all of which can now be run locally (§Findings E-18).

**~~F-16~~ · CLOSED 2026-08-09 — THE ASSET LAYER IS CALLED, AND URL-REFERENCED IMAGES ARE NO
LONGER BLANK.** The curator asked for this by name (*"but fix the blank images issue"*,
§Findings ~~S-28~~ part 3). What was wrong is worth keeping in one sentence, because it is
this project's favourite failure mode: `Assets::Resolver` and `Render::AssetBinding` were
complete, correct and covered by ~200 examples, and **had no production call site at all** —
`ReportRun#document_request` built `DocumentRequest.new(body: section.body, …)` and passed no
`assets:`, so every referenced image reached the engine as a live URL and INV-8 (which denies
the renderer a credential) made it draw nothing.

**THE ORDERING WAS THE WHOLE DIFFICULTY, and it turned out to be one local variable.** The
resolver picks, per reference, the most restrictive asset model **the engine declares**, so it
cannot be built until the adapter is known. `with_pdf` already resolved the adapter — but it
instantiated it as an ARGUMENT to `Renderer.new`, so nothing held the instance and nothing
could ask it for `#capabilities`. It reads as already-ordered and is not. `engine = adapter.new`
first, then bind, then render.

**As built:**

| piece | what it is |
|---|---|
| `RedmineReporterDashboards.asset_resolver` | the production factory, next to `asset_policy`/`asset_origin`/`asset_store` — the composition root's existing Redmine-facing half. **It is NOT in `reporting/`**: `Assets::Fetcher` is the plugin's only egress, and `layer_purity`'s `reporting` arm exists to stop that layer becoming "a second place that knows about HTTP". Constructing one there would pass the gate's literal patterns and defeat its sentence |
| `Reporting::AttachmentMapper` | the `LocalStore#mappers` port, which T-33 specified and nothing implemented. `/attachments/download/:id[/:filename]` → `Attachment#diskfile`, gated on `Attachment#visible?(actor)` — the **run's** actor, never `User.current` (INV-1) |
| `ReportRun#bind_assets` | one resolver per RUN (not per section), first refusal stops the run |
| `Diagnostic` origin `:assets` | a fourth origin, because **no engine ran**. Reporting it as `:engine` would send the reader to check a binary that was never started |

**THE REFUSAL IS THE POINT, not a side effect.** A same-origin URL that maps to no file, and
any third-party URL under the default `:bundled`, now fail the report with a message NAMING
the URL — T-33's own words: *"a report with a silently missing logo is one a reader cannot
tell from a report that never had one"*. That is a real behaviour change for any template
that referenced an unresolvable image: it used to render with a hole and now refuses. INV-4,
and deliberate.

**KNOWN LIMITATION, recorded rather than guessed at.** The mapper claims only the two
`download` routes. `/attachments/:id/:filename` is `attachments#show`, an HTML *page* about
the file; `/attachments/thumbnail/:id(/:size)` names a *derived, resized* image that
`Attachment#thumbnail` generates through ImageMagick. Answering the original's bytes for
either would put something other than what the URL asked for into the document, silently —
so both become named refusals. If a curator wants thumbnails embedded, that is a decision
about invoking ImageMagick inside a render, not a bug fix.

**Verification.** 21 mutations, **21 red** — and two of them SURVIVED the first round and
were closed with new tests rather than argued away. *M03* ("the factory ignores the mode the
operator configured") is the one worth remembering: an install set to `:external` would have
silently had `:bundled` behaviour, and every other example in the file passed, because
`:bundled` is what the other examples assert. *M01* ("build a fetcher even when the policy
forbids one") was proved **equivalent by construction** — the same document carrying all five
reference classifications resolved byte-identically with and without a fetcher, because
`Resolver#fetched` consults `policy.fetch_allowed?` before it ever looks at `@fetcher`. The
guard was kept and made testable the way HANDOVER's `update_columns` entry says to: the claim
is about the CONSTRUCTOR, so the assertion is `Assets::Fetcher.expects(:new).never`.

*Still open, and unchanged by this:* `:asset_upload` is still declared by neither shipped
engine, so the resolver always chooses `:inline` and `DocumentRequest#assets` is still always
empty. That half belongs to **T-34** and the original text is kept below because it is still
the accurate statement of it.

**CLOSED 2026-08-10 BY T-34 — `:asset_upload` IS NOW DECLARED AND DELIVERED.** The two
paragraphs below are kept because they are the accurate statement of what was owed and of
why it was not paid in T-33; read them as history. What discharged them is the Gotenberg
adapter, whose ONLY asset model is upload: `Assets::Resolver` now chooses `:upload` for a
real engine, `Resolver#upload!` rewrites each reference to its content-addressed name, and
the adapter sends every one as a sibling multipart part beside `index.html`. **The proof is a
pixel, not a byte count** — a green plate that travelled in the request is read back off the
rendered page (`spec/render/gotenberg_service_spec.rb`), because the first version of that
probe double-encoded the plate, got a plausible PDF back, and drew a blank image. Declaring
and delivering landed together, which is what G12's three-state rule requires and what INV-7
is about. **The CDP `Fetch.enable` interceptor is NOT built and `:chromium_cdp` still does
not declare `:asset_upload`** — that is a capability change to the DEFAULT engine, needing
its own conformance fixture and a matrix regeneration, and absorbing it here would have been
CLAUDE.md §11.5's second purpose. It is no longer blocking anything: the upload branch is
exercised end to end by a shipped engine.

**F-16 · nothing consumes `DocumentRequest#assets` yet, so T-33's upload model is proven at the
resolver and NOT end to end.** §5.1 says "the CDP interceptor makes the reference engine
implement it too" — `Fetch.enable` request interception serving `request.assets` from memory.
That interceptor is unbuilt, and neither `:chromium_cdp` nor `:wkhtmltopdf` declares
`:asset_upload` in `config/capabilities.yml`. The resolver therefore always chooses `:inline`
for both shipped engines, which is correct and fully exercised; the upload branch is tested
against a capability set that declares it.

**It was NOT added in T-33, deliberately.** Declaring `:asset_upload` on `:chromium_cdp` is a
capability change, and a capability this project declares and does not deliver is INV-7's exact
sin — G12's three-state rule turns it from a skip into a hard failure. Honouring it means a CDP
interceptor, a conformance fixture that proves an intercepted request is actually served, and a
matrix regeneration under G9. The natural owner is **T-34**, whose engine's only asset model IS
upload, and which therefore cannot be written without it. Until then `DocumentRequest#assets` is
carried and unread — the same status it has had since T-10, now with a producer that can fill
it.

**T-39 · migrate the two legacy examples off the CDN, and flip `vendor_integrity` to strict.**
The work F-15 could not do, with the verification obligation it needs, kept as a task so it is
schedulable rather than a sentence in a finding. *Touches:* `examples/sample_report_template.liquid`,
`examples/version_status_dashboard.liquid`, `script/gates/vendor_integrity.sh`,
`spec/shipped_templates_lint_spec.rb`. *Accept:* both examples load Chart.js from the plugin's
vendored copy with **no network reference of any kind** — asserted by `vendor_integrity.sh` in
**strict** mode, which is the gate this task exists to flip; the 2→4 config rewrite §6 enumerates
is complete in both files; **each example is rendered in a real browser and the charts are
asserted to have drawn**, because inlining Chart.js 4 under a 2.8 config produces a document that
looks fine and contains no charts; and the per-file ratchets in `shipped_templates_lint_spec.rb`
are **lowered**, never raised. *Blocked on:* a host-plugin render, which needs the private
`redmine_reporter` plugin (CLAUDE.md §11.6) — so the browser assertion has to run either against
a checkout that has it or against the owned render path once T-23 lands. State that choice in the
PR rather than skipping the assertion.

**E-17 · T-33's review found four blockers, and the worst of them made the whole `:bundled`
promise false.** Twenty-eight agents over the diff — four independent lenses, then one skeptic per
finding told to refute it, each required to REPRODUCE the failure rather than reason about it. 44
raw findings, 20 confirmed, 4 refuted, and the confirmations came with running scripts. The four
that mattered, and what each says about the shape of the mistake:

**1. A STYLESHEET IS A DOCUMENT, and inlining one embedded its own references verbatim.** CSS
carries `url()` and `@import`. `<link rel=stylesheet href="/plugin_assets/…/b.css">` where `b.css`
contains `url(https://evil.example/track.png)` produced `ok? == true`, no refusal, and both
`evil.example` URLs live in the body for the engine to fetch. Under `:bundled` that is exactly the
egress §5.1 refuses; under `:external` it is a **complete allowlist bypass**, because one
allowlisted host then chooses arbitrary further egress. The resolver walked the DOCUMENT and never
the content of what it embedded. Fixed by resolving CSS before embedding it, by the same rules, to
a bounded depth — and JavaScript deliberately NOT, because a URL in a program is a string rather
than a subresource, a script can mint one at runtime, and only the engine's own egress denial
closes that (which is what `F-15-egress-denial` is for). Rewriting URLs inside JS would corrupt
programs while closing nothing.

**2. `Resolver#call` raised `ArgumentError` on ordinary author markup.** `<link rel=stylesheet
href="/a.css" style="background:url(/logo.png)">` — two references with disjoint VALUE spans, but
the `url()` span sits inside the `<link>`'s element span, so the structural replacement contained
the attribute one and `assert_disjoint!` fired. Out of a method documented "never raises for
anything a document can do". Fixed by suppressing the element span when anything is nested inside
it, so the assertion is now about this file's own arithmetic — which is what it should always have
been. Its message no longer blames `DocumentScanner`, whose spans were provably disjoint in every
reproducing case: pointing a maintainer at the wrong file is its own defect.

**3. `<style/>` MADE AN ENTIRE STYLESHEET INVISIBLE TO THE SCANNER.** HTML has no self-closing
syntax: `<style/>` is an OPEN style element and every engine applies the CSS after it. The scanner
honoured the slash, skipped the body, and every `url()` in it went unseen — an egress hole. The
same test made a `<script/>` body get scanned as markup, which is the corruption the class comment
claims to have closed. Fixed, with foreign content (`<svg>`/`<math>`) tracked as the one real
exception rather than ignored in either direction, because this plugin emits inline SVG itself.

**4. THE PRODUCTION TRANSPORT HAD NO TEST AT ALL.** `NetHttpTransport` is where every
security-bearing line lives — `ipaddr=` (the whole rebinding fix), `use_ssl`, the two timeouts, the
streamed size cap — and deleting any of them was invisible to the suite. Now driven against a
`Net::HTTP` instance double: no socket, and the setters are asserted. The same pass found that
§5.1's "5 s total" was **not enforced**: the deadline seeded a per-read timeout, which every chunk
resets, so a server dripping one byte at a time held the connection for as long as `asset_max_bytes`
allowed — measured at 16 s against a 5 s documented cap. The deadline is now checked inside the read
loop.

**Two more worth naming, because both are shapes rather than instances.** A CR or LF in a path
reached `Net::HTTP`, which answers with a bare `ArgumentError` — refused now at classification AND
at the fetcher, because a fetcher must not depend on its caller having checked. And a structural
rewrite DISCARDED the element's attributes: `media=print` silently became all-media, `type=module`
became a classic script, `disabled` started applying. Rather than replicate HTML's semantics, the
rewrite is now allowed only for a closed safe set (with `media` carried through) and everything else
falls back to a `data:` URI, which keeps the element intact.

**And the generalisation that is worth more than any of them:** every one of the four was found by
RUNNING a document through the layer. None was visible in review of the source, and two of them
(the CSS hole and the `<style/>` slash) were in code whose comments explained at length why the
opposite hazard had been closed. A comment describing a defence is not the defence.

**E-20 · T-40's review found four ways past its own gate, and refuted the claim the whole design
rested on.** One fresh subagent over the diff, told to reject it and to reproduce every finding. The
four bypasses were each two lines of ordinary controller code, and each left the suite **green**:

**1. A controller in a subdirectory was invisible.** `Dir[app/controllers/*_controller.rb]` is not
recursive, so `app/controllers/reporter_dashboards/templates_controller.rb` with two unguarded actions
passed the coverage gate — while `#exist?` resolved the same namespaced key happily, meaning such a
controller could be permission-**mapped** and invisible to coverage at once. T-23, T-25, T-28 and T-32
are the four tasks that add controllers, and a namespace is the obvious shape for them. **The shape of
the mistake:** the gate's one job is to see every controller, and it was written against the four that
exist rather than against the ones it exists to judge.

**2. `authorize` was asserted per controller, so `only:` plus `skip_before_action` hollowed it out.**
`before_action :authorize, only: [:create]` and `skip_before_action :authorize, only: [:order]` left
three of four mapped actions unauthorized, and *the AST meta-test stayed green too* because `authorize`
was still in position 3 of the guard list. It matters concretely: T-28 ships
`publish_reporter_dashboards_reports` — *reachable without a Redmine account* — which is precisely the
controller that will carry a `skip_before_action`. Now per action, honouring all three keywords.

**3. `define_method` and a `def` inside a version conditional were both unseen.** The first is an
`FCALL` (an `ITER` wrapping one, in fact — the first fix missed that too); the second is a `DEFN`
nested inside an `IF`, never a direct statement of the class body. A version-conditional `def` is a
construct a plugin spanning three Rails majors is *likely* to write. Nesting is now searched, and
`define_method` is **refused** rather than ignored: its name can be computed, so no parser can promise
to know the action it creates, and reporting full coverage over a construct you cannot read is worse
than refusing it.

**4. The "nothing grants a permission" glob never scanned `init.rb`.** `{app,lib,db,init.rb}/**/*.rb`
expands to `init.rb/**/*.rb`, which matches nothing — so the one file where a plugin would actually
call `add_permission!` was the one file unchecked, and a planted grant in it passed. **A glob that
matches nothing looks exactly like a glob that matches nothing offending**, which is the same
failure class as E-14's scanner: an assertion that cannot see its subject reports success.

**And the refutation, which changed the design and not only the wording.** §4.1 claimed *"no role
holds an authoring permission until an administrator grants it — which is `:admins_only` by
construction"*, in five places including the README and the CHANGELOG. It is false. Redmine's own
`lib/redmine/default_data/loader.rb:51` runs
`manager.permissions = manager.setable_permissions.collect {|p| p.name}`, identically on 5.1 → 7.0, and
`Role#setable_permissions` subtracts only `public_permissions` for a givable role. So *Load the default
configuration* on a fresh install with this plugin present grants **Manager** every setable permission
of ours, `require: :member` included — which, once T-23 lands, is literally `:project_managers`, the
`[OQ-F]` value the curator rejected, arriving by a path the spec said could not exist. The spec example
that claimed to assert the property greps *this repository*, and the grant is made in core.

**It is still not an argument for restoring the setting** — the setting would have produced the same
grant on *every* install rather than on one ordering, and silently. It is an argument that T-27's
diagnostic must list the roles holding **our** authoring permissions and not only the base plugin's,
which is now in T-27's `Accept:`, and that a claim no test in this repository can reach should not be
written as though a test reached it.

Eight further findings were confirmed and fixed: `require: :member` was hand-typed while four
documents called it *derived* (now genuinely derived from `authoring: true`); the boot hook had **no
test at all** and could be silent on both branches when `Rails.logger` is absent; the plan said T-40
*"blocks nothing"* while T-27's `Deps:` named it, and assigned the `visibility` column to T-22 and T-23
in different sentences; the recorder proving the registration loop was run out of band and discarded
(now committed); *"Redmine removes a `:member` permission on upgrade"* was the wrong mechanism (it
stops **offering** it, and the active grant disappears at the next unrelated save); the new project
module's nine `project_module_*` labels were absent from the promotion checklist and from the gate; the
roles screen sorts modules alphabetically rather than by declaration order; and `.freeze` on the arrays
was shallow while every comment called the model frozen data.

**And one hole in the FIX, found by re-running the negative tests against it.** `actions_guarded_by`
returned `nil` — meaning "runs for every action" — for a guard that was **absent**, so a controller that
had simply DELETED its `before_action :authorize` answered "everything is covered" and the shiny new
per-action assertion skipped it. The review's finding, restored in a new shape by its own remedy, and
caught only because the old negative tests were re-run against the new code rather than assumed to still
hold. Absent is now `[]`, with its own example. **The lesson is about process, not about `nil`:** a fix
for a finding needs the finding's own negative test re-run, and CLAUDE.md's "never declare a result you
did not observe" applies as much to a repair as to the original.

**What the episode says about the gate rather than about the bugs.** Every one of the four bypasses was
a construct the reader had never been shown. The meta-test was described — in this file and in
`HANDOVER.md` — as making a silent-empty extraction *impossible*, and it did protect against that for
the four controllers in the tree; it could not protect against a construct nobody had written down. The
fix is not more comments: it is `spec/permissions/fixtures/controllers/`, two files containing every
construct `app/controllers/` happens not to contain, so the reader's answers about them are behaviour
rather than reading.

**E-19 · T-35's three defects were all cross-major, and none was visible by reading.** Found by
`spec_liquid/mermaid_tag_spec.rb`, which runs the same 23 examples under Liquid 4.0.4 and 5.13.0 —
the reason that directory exists.

**1. The second render of a cached template emitted NO library.** `context.registers` belongs to
the **Template** on Liquid 4 and survives every render; on 5.13.0 it does not. So a boolean
"already emitted" flag meant that on 4.0.4 the first report got its 3.5 MB Mermaid and every
subsequent report rendered from the same parsed template got none — every diagram silently
undrawn, nothing in any log. Fixed by keying the register on the **Context's identity**: a
`Context` is fresh per render on both majors, so it is the one thing that reliably answers "same
render". A boolean read correctly and was wrong on half the supported versions.

**2. An empty diagram rendered to NOTHING on Liquid 4.** Liquid 4 skips a tag whose `blank?` is
true, and `Raw#blank?` answers *"is the body empty"* — so `{% mermaid %}{% endmermaid %}` produced
a refusal element on 5.13.0 and an empty string on 4.0.4. A refused diagram has to stay an element
(INV-4): a reader looking at a gap cannot tell one from a diagram nobody wrote. Fixed by overriding
`blank?` to `false`.

**3. `mermaid_max_bytes` meant a different number for every diagram.** The cap was applied to the
ESCAPED source, and escaping costs three bytes for every `>` — so a diagram made of arrows, which
is what Mermaid diagrams are, got a smaller allowance than one without. Caught by the AT-the-limit
example, which is what those are for; fixed by capping the author's source before escaping.

**And one more the specs caught in themselves.** The ES5 scan started with a "shorthand method"
pattern, `/^\s*\w+\s*\([^)]*\)\s*\{/`, which cannot tell `{ foo() {} }` from `if (x) {` and
flagged nine lines of ordinary ES5. Deleted, with the reason in the file: the `vm.Script` example
asks a real ES5 parser the same question, and §Findings E-14 is the third instance of this lesson.

**Worth keeping generally:** every one of the three was a difference between two versions of a
dependency, not a mistake in logic. `spec_liquid/` running twice is the only thing that could have
found any of them, and the register-lifetime one is the kind of defect that would have reached a
user as "diagrams work in the first report of the day".

**E-18 · wkhtmltopdf runs locally, there are TWO builds of it, and the first version of this
finding blamed the plugin for something the build was doing. Corrected 2026-08-06, same day.**

**What I got wrong, first, because a wrong finding is worse than none.** This entry originally
reported `F-04-page-furniture` as a real, unaccounted-for failure and said page 1 "carries neither
the compiled tokens nor the literal slot", so it read as "the footer did not render". It is not a
defect in this plugin. **Ubuntu's `wkhtmltopdf` package is built against UNPATCHED Qt, which cannot
do headers or footers at all** — run by hand it says so on stderr, three times:

    The switch --footer-left, is not support using unpatched qt, and will be ignored.
    The switch --footer-right, is not support using unpatched qt, and will be ignored.
    The switch --footer-font-size, is not support using unpatched qt, and will be ignored.

`wkhtmltopdf.rb` emits exactly the right flags; that binary discards them. The correct conclusion
is the one I should have reached before writing the finding down: **verify which build you are
measuring before attributing its behaviour to the code.** It cost a wrong claim in a pushed commit.

**THE TWO BUILDS, and the distinction is the load-bearing part.**

| build | source | footers (what was MEASURED) |
|---|---|---|
| `wkhtmltopdf 0.12.6` | `noble/universe`, `apt install wkhtmltopdf` | **NO** — unpatched Qt |
| `wkhtmltopdf 0.12.6.1 (with patched qt)` | the release `.deb`, which is what CI installs | yes |

**Footers is what was measured, and the row says only that on purpose.** Upstream documents
unpatched Qt as lacking headers too, and the binary carries an advisory string ("These versions are
missing some features") without enumerating them — but `F-04-page-furniture` is the corpus's only
page-furniture fixture and it sets `footer:` alone, so a 17/1/2 result says nothing about headers.
Do not widen this row without a fixture behind it.

So HANDOVER's old "cannot be installed here" was *nearly* right and for the right reason — the
usable engine is only in a release `.deb` — and wrong in its conclusion, because **that `.deb`
installs fine on noble**. The jammy asset (`wkhtmltox_0.12.6.1-3.jammy_amd64.deb` — byte-for-byte
the URL `ci.yml:750` already uses) installs with `apt-get install ./wkhtmltox.deb`; the equivalent
`…noble_amd64.deb` URL **404s**, which is the observation rather than a claim about the release page.
Two commands, and `:wkhtmltopdf` stops being CI-only:

    curl -fsSL -o /tmp/wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb
    sudo apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb

Do NOT `apt install wkhtmltopdf` and think you have measured the engine. The distro build passes 17
of 20 and the difference is entirely the footer fixture — a plausible-looking result from the wrong
binary, which is this repository's favourite failure mode wearing new clothes. The flags are
discarded with a message on stderr ("is not support using unpatched qt, and will be ignored") —
loud enough to read, quiet enough to miss in a corpus run.

**THE MEASUREMENT, on the build CI uses, both engines, run as the non-root user:**

| engine | result |
|---|---|
| `chromium_cdp` Chrome/141.0.7390.37 | **20 pass, 0 fail, 0 skip** |
| `wkhtmltopdf` 0.12.6.1 (patched qt) | **18 pass, 0 fail, 2 skip** |

67 examples, 0 failures. The two skips are `F-11`/`F-12` on `:readiness_expression`, which E-5
already accounted for as a genuine capability difference — an engine you cannot poll cannot "give up
waiting and render anyway".

**SO E-5'S PROMOTION CONDITION IS MET, AND THE DECISION IS THE CURATOR'S.** E-5 defines `pending` as
"results are REPORTED, not enforced" and promotion to `corpus` as "the moment somebody accounts for
every one of them". Every one is now accounted for: four fixture bugs fixed, one egress defect fixed,
two weakened by curator decision, two skipping on a declared-absent capability. **18 + 2 = 20, with
nothing unexplained.**

What promotion costs, so it is a one-line decision rather than an investigation: `verification:
corpus` in `config/capabilities.yml`, twenty cells appear in `docs/engine-support-matrix.md`, and G9
requires the regenerated matrix in the same PR. **Not done here.** HANDOVER's rule is "promote it in
the commit that reads a green CI run, not before", and what exists is a green LOCAL run on the same
build — which is better evidence than this project has ever had for that engine, and still not the
thing the rule names. One CI run settles it.

**E-12 · `@context` belongs to `Liquid::Drop`, and a drop that stores its own there breaks
Liquid's internals.** Found by T-18's first spec run, three frames from the cause. `RecordDrop`
stored the `RenderContext` in `@context`; `Liquid::Drop` declares `attr_writer :context` and
ASSIGNS that ivar to the `Liquid::Context` every time a template touches the drop, then reads it
back in its own `liquid_method_missing` to decide whether `strict_variables` is on. The symptom was
`NoMethodError: undefined method 'actor' for an instance of Liquid::Context` from
`RecordDrop#in_actor_zone` — which reads as a bug in the timezone code and is not. It is the same
class of defect as `key?` in E-8: a name that looks free and is not, invisible to reading and
obvious to a test. Both bases now use `@render_context`, and both carry the comment.

**The generalisation worth keeping:** every name `Liquid::Drop` itself uses — `@context`, `key?`,
`invoke_drop`, `[]`, `to_liquid`, `liquid_method_missing` — is reserved surface on every subclass in
this layer. Two of the six have already cost a session.

**E-13 · `RenderContext#batch_for` compared scopes with `equal?`, and `IssueQuery#base_scope`
returns a new object every call.** Found by T-18's cap test, which deliberately passes two separate
`bench(21)` relations because that is the production shape. The collection drop therefore got a
SECOND `Batch` instead of the context's: two id plucks, two custom-value queries, and — the part
that actually bit — the collection running under the DEFAULT 5 000 cap rather than the configured
one. Nothing raised; 21 records rendered where 20 were asked for. Now compared by `to_sql`, which is
what a Batch's answers actually depend on. **The lesson is about the test, not the fix:** the
example only found it because it built the two relations separately. An example that reused one
object would have passed the broken code, and a cap that silently does not apply is exactly the
class of failure INV-4 exists to make visible.

**F-8 · CLOSED by the curator, 2026-08-06: not for now.** `UserDrop` ships without `mail` and stays
that way; revisit only if a real template needs it.

**The scope of the question was confirmed before it was answered, because the name invites the wrong
one.** This is *only* about printing an address inside a template body — `{{ issue.author.mail }}`.
It has nothing to do with mail SENDING: §7b.5's ad-hoc report mail does not exist in the tree yet,
and when it does it resolves recipients as **Redmine users** server-side, with `From`
server-controlled and external addresses behind an admin toggle plus a domain allowlist. It reads
`User#mail` on the model, never through a drop. So the absent accessor costs that capability
nothing, which is what made "not for now" a cheap answer rather than a deferred risk.

The original question, kept because the reasoning is what a future session needs: Redmine lets a user hide their address (`UserPreference#hide_mail`). Honouring it per
row means reading `user.pref` for every person a report prints, and `preference` is not among the
associations `IssuesDrop` preloads — an issue list showing 500 authors' addresses would be 500
queries, and preloading it for every issue list to serve the one template that wants addresses is
the opposite trade. Ignoring the preference instead is worse than an N+1: it publishes addresses
their owners asked to hide, into a document that gets mailed and archived. **T-18 shipped the
accessor absent rather than wrong**, with the reason in the class comment and a spec asserting it is
unreachable. What the curator owes is whether reports need addresses at all; if they do, the answer
is a purpose-built accessor that preloads `:preference` and honours the flag, not a line added to
`UserDrop`.

**F-9 · DEFERRED by the curator, 2026-08-06: to be settled while testing the plugin and the real
templates**, which is the only place the answer can come from — a thirteenth class is worth having
only if a template wants it. `Liquid::Drops::CLASSES` is the inventory in the meantime and the spec
holds it, so adding one later is a deliberate edit rather than a drift.

The discrepancy, kept for whoever settles it: The list is
the specific one, so T-18 built the list — plus `CustomFieldValuesDrop`, the bracket-lookup sibling
that carries the addon's `issue.custom_field_value[20]` surface across T-20's deletion of
`issue_drop_patch.rb`. Twelve concrete classes and three bases, held as
`Liquid::Drops::CLASSES` / `BASES` and asserted by spec, with the seven the gem had and §3.1 drops
asserted ABSENT by name and reason. Recorded rather than resolved: if the heading's thirteenth was
meant to be something specific — `VersionsDrop` and `AttachmentsDrop` are the obvious candidates,
neither of which any accessor needs today — that is the curator's to say. §3.1 now carries the
discrepancy inline.

**E-8 · `NamedRefDrop` is proven, and the proof found TWO gaps in §3.3's table plus one defect the
table could not have predicted. CURATOR DECISION on the first two.** `technical-spec.md` §3.3 marks
the class `[UNVERIFIED]` until its five substitutability claims are proven "under both Liquid 4.0.x
and 5.x", and says why: *"Every one is a claim about Liquid's internals and must be proven by test,
not by reasoning."* It is now green on 4.0.4 and 5.13.0, 28 examples each, every one comparing the
drop's rendering against the **String's** rather than against a literal somebody typed.

**The defect the proof found, and it was mine.** The first draft also defined `key?` and
`attributes` as ordinary conveniences, and `key?` broke the drop protocol outright — `{{ status.id }}`
rendered **empty**. Liquid's `VariableLookup` asks `respond_to?(:key?)` to decide whether a value is
hash-like; having answered yes, it asked `key?('id')`, got false from the attributes hash, and
returned nil without ever trying the method. A method named `key?` was enough to make every accessor
on the class unreachable from a template, and nothing about writing it suggests that. This is the
single best argument for §3.3's insistence on proof: no amount of reading would have found it.

**TWO GAPS IN THE TABLE, both measured, both now asserted AS THEY ARE so a future change reports
itself rather than going quietly green:**

1. **The reversed comparison.** `{% if issue.status == "Closed" %}` works — it is what the table
   protects. `{% if "Closed" == issue.status %}` **does not**: it renders `no` through the drop and
   `yes` through the String. Ruby asks the LEFT operand, so this is `String#==(drop)`, which answers
   false for anything that is not a String.
2. **`{{ status | size }}`** answers `0` through the drop and `6` through the String. `size` asks the
   object, not its string form, and a Drop has no size.

**The first one is not fixable within the design, and that is the finding.** The only two fixes are
monkey-patching `String` (forbidden) or making `NamedRefDrop` a **subclass of String** — which would
make it substitutable everywhere, including both comparison orders and `| size`, and would forfeit
the `Liquid::Drop` protocol and with it `{{ status.id }}`, `{{ status.url }}` and the caller-supplied
attributes. **You cannot have both in one Liquid value:** Drop buys you the new accessors, String
buys you substitutability, and §3.3 chose Drop without recording that the choice costs these two
idioms.

**DECIDED by the curator, 2026-08-06: keep the Drop, and have the linter flag the two idioms.**
The class stays as §3.3 specifies, `{{ status.id }}` and `{{ status.url }}` are kept, and the path
that dissolves `{% geo_version_map %}`'s 295 lines stays open. The two gaps stay pinned by tests
that fail if the behaviour moves in either direction.

**This puts an obligation on T-19, and it is not optional — it is the other half of this decision.**
The linter must flag both idioms, at authoring time, on any expression that resolves to a reference:

* `{% if "literal" == x %}` — the reversed comparison. Suggest the working order, `x == "literal"`.
* `{{ x | size }}` — suggest `{{ x.name | size }}`, which is what the author meant.

Without those two rules the decision is only half taken: a template that uses either one gets a
silently wrong branch instead of an error, and the whole reason for choosing the Drop was that a
visible authoring error beats a silent wrong answer. Whoever builds T-19 should treat these as
acceptance criteria for T-19, not as a nice-to-have inherited from another task.

The rejected alternatives, recorded so the reasoning survives: a **String subclass** would be
substitutable everywhere and forfeits the Drop protocol, reopening ADR-004's rejected "keep Strings,
add `*_id` only" and leaving those 295 lines alive; **shipping both shapes** loses nothing
technically and doubles the vocabulary every template author has to hold, which is a cost paid by
people rather than by code.

**E-7 · the Liquid stub and the real gem cannot share a process, and 200+ specs are written
against the stub.** Found while building T-17, by trying it. The plugin has never loaded Liquid
itself — it registers tags into whatever Liquid the host plugin already loaded — so `spec_helper.rb`
defines a minimal stub and every tag spec is written against it. Declaring `gem 'liquid'` and having
`spec_helper` prefer the real gem produced **218 failures out of 1332**: `Liquid::Tag.new` is public
on the stub and PRIVATE on Liquid 5, and the constructor signatures differ.

Two things were separated, and the separation is what made T-17 possible without a 218-example
rewrite:

* **Declaring the gem is harmless.** `gem 'liquid', '>= 4.0', '< 6.0'` in the plugin Gemfile with
  `spec_helper` left alone: 1332 examples, 0 failures. Nothing requires the gem automatically, so
  the stub still wins in the default suite.
* **Loading it in the same process is not.** A spec file that requires the real gem pulls it in for
  everything, and which one wins depends on FILENAME ORDER — the worst kind of ordering failure.

So `spec_liquid/` is a directory of its own, run as `rspec -r liquid spec_liquid`, with `-r` making
the gem win before any spec file loads. `spec_liquid/README.md` says why, because a reader who finds
one spec directory outside `spec/` will otherwise assume it was a mistake.

**This is a workaround for a migration nobody has done, not a design.** Moving the tag specs onto
the real gem belongs with **T-18/T-19**, which rewrite those tags anyway; doing it inside T-17 would
be a task growing a second purpose (CLAUDE.md §11.5). When it lands, `spec_liquid/` folds back into
`spec/` and the stub can be deleted outright.

**E-6 · T-15's two app-layer assertions have no caller to make them against, and inventing one
would be another task's work.** T-15's `Accept:` list is written for an HTTP entry point: a **422**
whose message names the cap, and `assert_no_difference` on **both** `Attachment.count` and
`Journal.count`. Neither can be written today, and the reason is a fact about the tree rather than a
choice:

**The only PDF entry point in the plugin is `reporter_project_pages_controller#report_pdf`, and it
404s standalone.** It resolves a reporter report template, so on an install without the base plugin
— which is the configuration CI runs and the one this project exists to reach — the action declines
before it renders anything. There is nothing there to refuse a batch from, and no attachment for an
`assert_no_difference` to count. The owned entry point arrives with **T-23** (template CRUD and
preview) and the owned attachment write with **T-30** (failure reports).

What was built instead is the half that is real now: the cap and the deadline as a `BatchGuard` that
cannot be bypassed, and the containment properties asserted **against a live browser and the process
table**. What is owed, precisely, so it is not mistaken for done:

* the 422 itself — status, and a message naming the cap and the count, from a controller;
* `assert_no_difference` on `Attachment.count` and `Journal.count` across a failed render;
* **streamed archives with no `Content-Length`**, which is entirely an HTTP concern — a zip built in
  `render/` would be the layer violation `layer_purity.sh` exists to catch, and building it anywhere
  else means building the controller that serves it.

Whoever picks up T-23 or T-30 should finish T-15 in the same PR rather than after it. A cap with no
caller is a cap nobody has seen refuse anything.

**~~E-6~~ TWO OF THREE PAID by T-23, 2026-08-07; the third is still owed.**

* **The 422 — done.** `reporter_dashboards/templates#document`, against the SHIPPED
  `DEFAULT_MAX_DOCUMENTS` of 50 rather than a cap lowered to two for the test: the fixture builds
  51 issues and the assertion reads both numbers out of the response body. It refuses before one
  Liquid template is parsed, which is asserted with `TemplateRenderer.any_instance.expects(:render)
  .never` — the count alone would pass against a refusal that happened after the work.
  `BatchGuard#cap_refusal` became public and grew `#cap_refusal_for_count` for this: the caller
  has a pipeline of its OWN in front of the renderer, and a per-record report would otherwise have
  rendered 4 000 bodies before the guard saw a list.
* **`assert_no_difference` on both counts — done**, across the template-failure path AND the
  refusal path, plus a `never` expectation on `Attachment.create`. **Said honestly: nothing on
  this path writes either row today, so these are REGRESSION GUARDS rather than discoveries.**
  That is what they were asked for — the base plugin's failure path called `create_attachment` on
  the exception message — and it is what they will catch.
* **Streamed archives — PAID by T-29, 2026-08-09. E-6 is now closed in all three bullets.**
  A per-record export of more than one document streams a zip with **no `Content-Length`**;
  the 501, its diagnostic code (`archive_not_available`) and its nine locale strings are all
  deleted, and the download button is drawn for the archive with its own label and the count
  in it. `Archive::ZipStream` is a sibling of `render/` naming neither layer — E-6's own
  sentence says a zip inside `render/` is the violation `layer_purity.sh` exists to catch —
  and the gate grew an `archive` arm, negative-tested in three directions.

  **What "streamed" means here is stated exactly rather than implied**, because the
  overclaim was available and would have passed every test: the ARCHIVE is never
  materialised (`ZipStream#each` yields, and `spec/archive/zip_stream_spec.rb` asserts a
  chunk is emitted before the last entry is pulled from its source), while the rendered PDFs
  ARE all in memory before the first byte goes out. That is deliberate and is the
  correctness argument, not a limitation: the status line is sent with the first byte, so
  rendering lazily would mean a failure at document 7 of 50 arriving after `200 OK` — INV-5
  one layer up, a truncated archive that unpacks cleanly and is missing 44 reports. The
  set held in memory is bounded by `BatchGuard`'s cap, which is still asked off a
  `COUNT(*)` before anything is rendered (asserted: the renderer is never called).

**~~E-5~~ · CLOSED 2026-08-06. `:wkhtmltopdf` is PROMOTED to `verification: corpus`, and the matrix
carries its cells.** The promotion condition this finding set — *every failure accounted for* — was
met by E-18's measurement, and the curator took the decision. Regenerated from a real run of both
engines in this container (patched-Qt `0.12.6.1`, Chromium 141, as the non-root `rrd` user):
**18 PASS / 0 FAIL / 2 SKIP**, and both skips are `F-11`/`F-12` naming `:readiness_expression`,
an **undeclared** capability — which is G12's three-state rule working, not an exemption. What
changes in practice: `pending` meant *reported and not enforced, no cells in the matrix*; `corpus`
means those twenty cells are real and a regression in any of them is a build failure. The rest of
this entry is the history, kept because the shape of it is the argument for INV-7.

CI run 31059574558 executed the corpus against wkhtmltopdf for the first
time: 13 of 20 pass, and the 7 failures split three ways.

**Four were mine and are fixed.** Two fixtures asserted "no degradations at all" when what they
meant was "no READINESS degradation" — a compatibility engine stamps `:legacy_engine` on everything
it draws, by design, and a readiness fixture has no business failing over it. Two more (`F-11`,
`F-12`) asked for a behaviour only a POLLABLE engine can perform: "on timeout, give up waiting and
render anyway" needs an engine you can ask "are you ready?" and then tell to stop. wkhtmltopdf takes
a status to wait for and has no such move — it waits, or it is killed, and a killed process has no
document. That is a capability difference with a name already in the vocabulary, so both fixtures now
require `:readiness_expression` and skip with it named.

**One was a real defect, and it is the same defect as E-2 one engine later.**
`--disable-local-file-access` stops wkhtmltopdf reading the filesystem and does nothing about the
network: `F-15` watched three subresources arrive at the harness's socket. Fixed with a proxy to
nowhere, the same shape as the Chromium fix. Worth noting how much cheaper the second instance was —
the corpus found it in one run, where the first had needed the fixture to be invented.

**TWO WERE THE CURATOR'S, AND WERE DECIDED ON 2026-08-06: WEAKEN THE FIXTURES.** The
two differences, and what each cost:

* `F-07-flexbox` — wkhtmltopdf's 2011 WebKit stacks a flex row instead of laying it out. Correct
  behaviour for that engine and a genuine capability difference.
* `F-18-fonts` — the text band renders blank under the pixel probe, where Chromium inks it.

**Neither difference could be expressed.** `technical-spec.md` §5 defines the capability vocabulary
as CLOSED, and it contains no `:flexbox` and nothing about font rendering — so the three-state rule
had no capability to skip on. Three options were put to the curator: open the vocabulary (a spec
change, and the closure is deliberate), weaken the fixtures, or leave wkhtmltopdf unpromotable
forever. **Decision: weaken the fixtures.**

As built, with the cost of each written into the fixture itself so it is found by whoever next
reads the file rather than by whoever next trusts it:

* `F-07-flexbox` becomes `F-07-column-layout` and draws its two columns with a TABLE, which every
  engine in the matrix does including the 2011 one. It still catches a layout engine that stacks
  what should sit side by side, and it is now a floor rather than a frontier. **Nothing in the
  corpus covers flexbox any more** — an engine that cannot lay out a flex row passes this suite.
* `F-18-fonts` loses its single pixel-inking check. The four extraction checks stay, and between
  them they still catch missing glyphs, wrong encodings and mangled punctuation, which is most of
  what goes wrong with fonts. **What is now uncovered is white-on-white**: a report whose text
  extracts perfectly and prints blank passes this suite. T-14's preflight probe is the right home
  for that check, because it runs against ONE engine an operator actually installed rather than
  against every engine in the matrix.

If the vocabulary is ever opened, both belong back as they were; `git log` has them and this entry
has the reasoning.

**`pending` was given a precise meaning along the way, and keeps it:** a non-`corpus` engine's
results are REPORTED, not enforced. Each failure is printed and the summary line carries the counts.
Promotion to `corpus` is the moment somebody accounts for every one of them — which is exactly what
just happened here.

**E-4 · `Registry.reset!` with no restore is a random-seed defect.** Two adapter examples failed on
one seed and passed on the next. T-10's contract spec resets the registry; the adapters register
when their files are required; `config.order = :random` decides which fact wins. It reads as a
registration bug and is a test-isolation one. `Registry.isolated` is the same reset with the restore
attached, and the lesson is the one CLAUDE.md §6 already states — a spec that depends on another
spec's global state is a defect waiting for a seed, not a flake.

**One thing the protocol work already found**, which the falsifier's first fixture would have
caught later and more expensively: the shell as first written never signalled ready for a
CHART-FREE document. Nothing called `end()`, so `pending` never reached zero from above it, and a
page with nothing to draw would have been the slowest to render — waiting out the watchdog. Fixed
by `settle()` on `DOMContentLoaded`, and asserted.

**F-6 · FR-23 and FR-24 are owned by no task, and T-21's `Accept:` list depends on one of them.**
Found 2026-08-05 while building T-21. `functional-spec.md` FR-23 says "Every aggregation result
carries a `degraded` flag with reasons; a refusal is distinguishable from a true zero", and FR-24
says a cap that truncates or refuses must set the same flag. The spec itself marks this as **new** —
"today's contract is" the older one — and **no task in this plan mentions FR-23 or FR-24 at all**
(`grep -n 'FR-23\|FR-24' implementation-plan.md` returns nothing). So an aggregation result has no
`degraded` field today and nothing is scheduled to give it one.

T-21's `Accept:` line asks for "a zero-with-`degraded: false` case (a correctly-applied filter
yielding zero is *not* a refusal)". The DISTINCTION is testable today and is tested: a refusal
answers `nil`, a filter that legitimately matches nothing answers a result whose numbers are zero.
The FLAG is not, because it does not exist. Both halves are written into the test with a pointer
here, so the day FR-23 lands the test says what it should become rather than quietly passing on a
weaker contract.

For the curator: FR-23 wants an owning task. It is not a small one — "every result" spans all six
aggregator entry points plus the render path's `Failure`, and the aggregator today signals refusal
by returning `nil` from six different methods, which is exactly the shape FR-23 exists to replace.

**F-4 · `CLAUDE.md` and `technical-spec.md` disagree about the `compat/` budget, and the number is
a curator decision.** CLAUDE.md §4 says "There is a committed LOC budget on that directory and a gate
that enforces it." There is not, and there never was: **no number is committed anywhere in
`docs/plan/`**, and technical-spec E4 — the specification, which is the contract — says the job
**prints** the LOC, not that it caps it. T-09's `Accept:` line agrees with the spec.

So `compat_size.sh` implements the spec: it PRINTS the number on every PR, and it hard-fails on the
half E4 does specify as a rule — `Rails::VERSION` / `Redmine::VERSION` may appear only under compat.
It reads `COMPAT_LOC_BUDGET` and becomes a ratchet the moment one is set, so adopting a cap is a
one-line change once someone has argued for the number.

**Why the number was not invented here.** Picking it IS the decision: too high and it is decoration,
too low and the next legitimate divergence is refused by a threshold nobody argued for. Today compat
is **10 code lines** in one file (`base_record`, `svg_icons?`). Two divergences the plan already
anticipates — `compat/serialize.rb` and `compat/enum.rb` — are not written yet. A recommendation, for
whatever it is worth: set it after those land, not before, and set it at what they actually cost plus
one method's headroom. Either way, CLAUDE.md §4's sentence should be corrected to match whichever
answer is taken, because it currently describes a gate that did not exist.

**F-5 · INV-7's last unproved claim is a human artefact: the dated fork-PR run.** T-09's `Accept:`
list ends with "**G1**, plus one dated fork-PR run recorded per release — *a workflow cannot fork
itself without reintroducing the very credential G1 removes, so that end-to-end proof is a human
artefact and the grep is what keeps it true between artefacts.*" Everything mechanical is in place:
`no_secrets.sh` fails on any `secrets.` but `GITHUB_TOKEN` and runs on every PR, and the full-app
suite runs standalone on 5.1 / 6.0 / 6.1 / 7.0. What no job can do is prove that an **outside
contributor's** fork PR gets the same run, because arranging one requires a second account.

It is recorded as owed rather than quietly counted as done. Concretely: before tagging 0.6.0, open a
pull request from a fork of this repository, let CI run, and record the date and the run id here. If
it goes red for want of a credential, that is G1 failing and the release does not ship.

**F-3 · gate G8's "empty allowlist at 1.0" target cannot survive shipping an importer, and that
is a curator question.** `script/gates/zero_reporter.allowlist` opens with "At 1.0 it should be
empty: the goal is a plugin that names neither upstream anywhere in `app/`, `lib/`, `db/`, `config/`
or `init.rb`." T-02 adds four files that name `redmine_reporter` **because reading reporter's data is
what they are for** — and that is the opposite of coupling: the survey reads *tables*, never
reporter's classes, and `spec/adapter/import_survey_spec.rb` runs it against bare tables with no
reporter code loaded at all. So the gate is matching a string here, not a dependency.

Removing the mentions would make the tool worse rather than purer: `rake -T` has to say whose data
`import:plan` surveys, the report has to name the tables it looked for, and the usage groups have to
say that six of the accessors come from *paid* RedmineUP plugins — which is precisely the fact an
operator needs in order to decide what can be dropped. So the four files are on the allowlist, in
their own section, with that reason.

**DECIDED by the curator, 2026-08-05: the importer ships permanently, and G8's 1.0 target becomes
"empty except the importer."** The reasoning was that a migration path is worth having for anyone who
installs this plugin next to the base one, not only for the curator's own one-time migration. So the
four importer files stay on the allowlist for good and the allowlist header now says so; every other
entry must still reach zero. The gate itself is unchanged.

**F-2's decision is taken, 2026-08-05: close it by construction in the owned path, and leave the
legacy module alone.** T-07 owns this decision and the argument is in `HANDOVER.md` §6, with the
design. In short: the owned path has no registers source at all — both of `ScopeBinding`'s two
sources start from `Issue.visible` — so the leak is closed by design rather than by a patch, and the
legacy module keeps its behaviour, which means **the frozen scope-fixture triple does not move.**
That last point is the reason to prefer this over patching the legacy path: the scope fixture is the
one artefact in this repository that cannot be regenerated.

**F-2 · the registers relation path is not visibility-scoped.** `resolve_scope` returns
`registers[:container]` as-is when it is an AR relation, intersecting only the DROP path with
`Issue.visible`. The documented grounds are that every registers path is `IssueQuery#base_scope` and
therefore already visible — true of what reporter passes today, not true of the type. Not reachable
from a template (only the host plugin writes registers), so it is a finding rather than an
emergency, and the scope fixture **freezes the leak explicitly** (a triple in which every actor
resolves an issue from a project they are not a member of). **T-07 owns the decision**; when
`ScopeBinding` closes it, that triple changes and the change has to be argued for rather than
noticed later.

## 1. Work breakdown

### Phase 0 — unblock and freeze

**~~T-00~~ · VOID — the fork is out of scope** *(closed 2026-08-05 by curator decision)*

The task was "fix `enum orientation: [...]` in `redmine_reporter/app/models/report_template.rb:26`".
The curator has ruled that **`redmine_reporter` is not to be modified**: the goal is to merge and
improve its capabilities *into this plugin*, not to maintain the fork. T-00 therefore has no
deliverable and **must not be attempted**.

What replaced it, and why nothing is lost:

- **Redmine 7 was unblocked from the other end.** Since T-05 made reporter optional, the enum
  defect stops the two report widgets instead of the whole plugin. Redmine 7.0-stable was then run
  standalone and is green — 900 specs, 86 adapter specs, 114 full-application tests, 0 failures.
  The blocker was never in this plugin.
- **The `skip_unless_reporter_report_templates_load` helper stays.** T-00 would have deleted it;
  it is now load-bearing for a supported configuration, so it remains, with its message corrected
  to distinguish "reporter absent" (normal) from "reporter installed but broken" (a defect).
- **The tooling half of T-00 is done** and was mostly a false premise — see `CLAUDE.md` §4.
  `.codex/ruby_version.sh` fixes the real gap; `redmine_clone.sh` and `test_setup.sh` were also
  fixed so the standalone configuration can be set up and switched to at all.
- **The enum divergence is still owed to `compat/enum.rb`** for this plugin's own models, if any
  ever need an enum. Measured: `enum :name, {...}` raises `ArgumentError` on Rails 6.1, and
  `enum name: [...]` raises on Rails 8.1, so neither form spans 5.1→7.0 alone. Stored integers are
  identical either way.

*If reporter is ever fixed upstream*, the four skipping tests begin asserting on their own; nothing
here needs changing to allow that.

**T-01 · Freeze the oracle** *(the only time-sensitive task)*
*Goal:* capture what "the same numbers" means, before anything moves.
*Touches:* new `spec/golden/**` (`reference_date.rb`, `corpus_canonicaliser.rb`, `baseline.rb` and
the `aggregation/` fixtures) and a generator extending `spec/adapter/adapter_helper.rb` —
**extend, do not write a parallel harness**. **Corrected 2026-08-05:** the value corpus can be
generated from that harness, but **the scope fixture cannot** — `ScopeResolution#resolve_scope`
reaches `Issue.visible`, `IssueQuery.visible` and a thread-local, none of which exist in a harness
whose whole point is not booting Redmine. The scope fixture therefore also touches `test/` (the
full-app suite), where real roles and a real `IssueQuery` exist. Budget it as two pieces, not one.
*Deps:* none. **Corrected 2026-08-05:** was `T-00 (the generator must be able to boot)`. T-00 is
void, and the premise was wrong anyway — the generator boots on any Redmine whose Rails accepts
reporter's enum, and standalone it does not need reporter at all.
*Accept:*
- Generated against the **`v0.5.0` tag**, not a working tree.
- **A pinned reference date** is required and the verifier **refuses to run without it**. The
  existing fixture is `Time.zone.today`-relative (a 400-day sweep), so an unpinned corpus changes
  daily, goes red for the wrong reason, and gets switched off within a week.
- Canonicalisation per `technical-spec.md` §2: keys sorted recursively, **array order preserved**,
  floats as `(v*10_000).round` **plus** a `%.4f` string (4 dp is the declared contract — PostgreSQL
  `numeric` and MySQL `DECIMAL(20,4)` disagree beyond it), per-adapter overlay **with a written
  reason** instead of a tolerance.
- Covers: `.aggregate`, `.breakdown` (legacy), `.dimension_breakdown`, `.completeness`, `.flags`,
  `.version_rollup`; cap boundaries at 200 / 24 / 12 / 5 000; **and ≥3 actors with different roles
  including one role-restricted custom field** — absent from the fixture today, and the thing that
  makes INV-1/INV-2 testable at value level.
- **A scope fixture:** ~40 `(template, query, actor)` triples recording `to_sql` **and** the sorted
  issue-id set. *This is the genuinely irrecoverable artefact* — the numbers are regenerable from
  the tag; the scope is not, once `scope_resolution.rb` is gone.
- SQL strings in a **sibling** tree, not the value corpus (SQL is expected to change at the
  re-seam; the numbers are not, and a differential that fails for the wrong reason gets disabled).
- **Bit-reproducible across two independent runs** on all three engines. A corpus that is not
  reproducible is not an oracle.
- New CI job `corpus`, green, and **it stays green through every later task**.

*Done (2026-08-05).* What landed, and where to read it: `spec/golden/README.md` is the page for
anyone touching these artefacts.

- **Reference date** — `spec/golden/reference_date.rb`, default `2025-12-29`; the verifier refuses
  to run unpinned. Pinning the fixture is not enough on its own: the **clock must be frozen to the
  same date** or every period window comes back empty. The aggregator's only clock read is
  Ruby-side, so freezing Ruby is sufficient.
- **Canonicaliser** — `spec/golden/corpus_canonicaliser.rb`, per §2 Step 0.
- **Baseline** — `spec/golden/baseline.rb`: commit `eddb8fa`, not a tag, because this repository has
  none. See that file for the one way the reference can still be lost (a squash merge).
- **The value corpus** — `spec/golden/corpus_cases.rb` declares **176 cases** over the six entry
  points; `spec/golden/aggregation/values.jsonl` holds the answers with a manifest carrying the
  baseline commit, the pin, the zone and two digests (the file's, and the CASE LIST's, so a matrix
  that has moved on from its answers fails rather than passes). Caps covered **at** the boundary and
  **one past** it: 200 dimension keys, 24 age buckets, 24 periods, 12 completeness fields, 5 000
  crosstab cells. **Four actors, three roles, one role-restricted custom field** — the value-level
  INV-1/INV-2 evidence: the same call is refused for two actors, answers with values for a third,
  and hides the values while keeping the issues for the fourth.
- **The per-adapter overlay** — `spec/golden/adapter_overlay.rb`, file-backed, ratcheted, and
  **exhaustive by assertion**: the cases that differ on an engine must be exactly the cases it
  names. It held two entries, both defect D-1 below; **both are gone and `RATCHET` is 0** now that
  D-1 is fixed, which is the mechanism working as specified rather than the entries being wrong.
- **The scope fixture** — `test/unit/golden_scope_fixture_test.rb` + `spec/golden/scope/scope.jsonl`,
  **46 (template, query, actor) triples** over all eleven documented resolution paths, four actors
  with three `issues_visibility` rules, private issues, an archived project and a project with no
  membership. `resolve_query`'s answer is recorded beside `resolve_scope`'s: the drill-through half
  is lost with the same file. SQL in the sibling tree `spec/golden/sql/`.
- **The `corpus` CI job** — all three engines, twice each, with the pinned date, and it runs the
  baseline checks **from the plugin checkout** (the mirror has no `.git`, so there they would skip
  and report green). It also fails if a run modified the corpus it was verifying.

*Two deviations from the wording above, both deliberate and both to serve it:* the scope fixture
records the issue set **by a stable per-issue key as well as by id**, because a fixture created
inside a rolled-back transaction has no stable ids and Redmine's own fixture sets differ between
5.1 and 7.0 — recording keys is what lets the fixture be verified on all four branches instead of
one pinned branch (ids are recorded too; the test assigns them explicitly from a reserved range).
And the 5 000-cell boundary is built from a `period` split rather than an `age` split, because a
24-boundary age CASE was exactly the shape defect D-1 broke, and a cell-count boundary built on a
broken dimension would have measured the defect instead of the cap. It stays a `period` split now
that D-1 is fixed: a crosstab still groups on the age CASE, so an age split is still the wrong
substrate for that boundary — for a smaller reason than before, but the same one.

*One constraint on that job, found the hard way:* `redmine_clone.sh` rsyncs the plugin into
`redmine/plugins/<name>/` with `--exclude .git/`, so the copy the suite normally runs from has no
history. `spec/golden/baseline_spec.rb` therefore **skips** there — correctly, but a skipped guard
reads exactly like a passing one. The `corpus` job must run the baseline checks **from the plugin
checkout**, not from inside the Redmine clone, or G7 has no reference check and stays green forever.

**T-02 · `import:plan` — the read-only survey**
*Goal:* make DoR-1 repeatable, and give the operator the blast radius before anything lands.
*Touches:* new rake task; the template linter's first rules.
*Deps:* none (can run in parallel with T-01).
*Accept:* writes nothing; reports counts by template type, active schedules and recipients, and
per-template lint findings (Chart.js 2 idioms, `window.status`, `geoChartBegin`,
`GEO_CHARTJS_SRC`, `setLineDash`, `[page]`, un-`json`-ed `{{ }}` inside `<script>`, gem-only drop
accessors, `new Chart(` occurrences and their `type:` values); exits 0 with a summary table.

**T-03 · Measure the performance baseline**
*Goal:* convert R7 from unfalsifiable to relative.
*Deps:* none *(corrected 2026-08-05: was T-00, which is void)*. *Must precede T-10.*
*Accept:* p50/p95/max/stddev over ≥20 warm runs (3 discarded) per (reference template × issue
count 1 000/10 000/100 000 × HTML|PDF), with a **recorded seed**, the runner image digest and the
CPU model captured; committed as a provenance-stamped artefact; a cell with `stddev/p50 > 0.35`
reported **invalid**, not averaged away.

### Phase 1 — standalone *(ships 0.6.0; delivers G1)*

**T-04 · Own the list behaviour — replace `up_acts_as_list`**
*Goal:* remove the plugin's own core-model dependency on the vendor gem.
*Touches:* new `glue/positioned.rb`; `app/models/reporter_project_tab.rb:7`.
*Deps:* none. **This is the first code task and it must not be reordered.**
*Accept:* `position` defaults to `max+1` scoped to `project_id`; `move_higher`/`move_lower`/`<=>`;
`before_destroy` reflow; the model has **zero** vendor-gem references; existing tab-ordering tests
pass unchanged. **Rationale: without this the plugin boots and then 500s on
`ReporterProjectTab` — verified, `up_acts_as_list` is defined only in the gem.**

**T-05 · Soft dependency detection**
*Touches:* `init.rb:12-16`, `:33`; a memoised `ReporterDashboards.reporter_present?`.
*Deps:* T-04.
*Accept:* the `raise` becomes a soft detect; `requires_redmine_plugin` deleted; the flag is
computed **once** at `after_plugins_loaded`; a boot spec passes with
`Redmine::Plugin.installed?` stubbed false. **Do not use `rescue NameError` for detection** —
`redmine_reporter_dashboards.rb:135` already swallows `NameError` silently, which is exactly why
C3 went unnoticed for a release line.

**T-06 · Report widgets leave the picker; already-placed widgets degrade**
*Touches:* move the two report partials to `blocks/optional/`; `project_page.rb:55-62`;
`show.html.erb`; `reporter_project_pages_controller.rb:85-91`.
*Deps:* T-05.
*Accept:* with reporter absent the two widgets are **absent from the picker**; a dashboard that
**already has one placed** returns 200 with an inline "widget unavailable" cell carrying
`degraded: true` and one log line — **not a 500**; `report_pdf` returns **404** (not 500) when
reporter is absent, both branches asserted. *A 500 in a monitored install is an alert about a
broken thing; a 404 is a correct statement about an uninstalled capability.*

**T-07 · `ScopeBinding` replaces `ScopeResolution`; re-seam **both** tags**
*Goal:* the render context carries the `IssueQuery` explicitly.
*Touches:* new `liquid/scope_binding.rb` (~60 lines) + `liquid/render_context.rb`;
`liquid_aggregate_tag.rb:106` **and `liquid_version_rollup_tag.rb:38`** — **there are two, not
one**; `scope_resolution.rb` demoted to `glue/legacy/`.
*Deps:* T-05. **T-01 is complete** — the scope fixture in `test/unit/golden_scope_fixture_test.rb`
is the oracle this task is measured against, and finding **F-2** (§Findings) is the decision it has
to take deliberately rather than by accident.
*Accept:* two resolution sources only (`IssueQuery.visible(actor).find_by(id:)` → `base_scope`;
`RenderContext#scope`); the `drop.instance_variables` walk, the `:container`/`:controller` ivar
archaeology, the `Issue.where(id: ids)` reconstruction, the thread-local **and the fail-open
`enforce_visibility` rescue** are all gone from the owned path; a gate asserts `Thread.current` is
absent from `lib/`/`app/` outside `glue/legacy/`; **`corpus` still green** — *this is the single
most important assertion in the whole plan*; drill-through still works for installs that still
have reporter (via `glue/legacy/`).

**T-08 · Port the aggregation kernel, byte-identically**
*Touches:* `aggregation/query_aggregator.rb`, `aggregation/drill_through.rb`, plus a 4-line
namespace assignment.
*Deps:* T-01 (complete). **This task owns the fix for defect D-1** (§Findings) — the only place the
kernel may legitimately change a byte. Fixing it deletes the overlay's two entries and lowers its
ratchet in the same commit. **Both halves are done.**
*Accept:* both files are **byte-identical** to their `v0.5.0` blobs — `git diff --no-index` output
**empty**, not "ignoring whitespace"; they still open `module SqlAggregation`; namespacing is a
separate assignment file; the `corpus` job enforces this on every PR. *As built, "byte-identical"
reads "byte-identical to the blob with every DECLARED hunk applied" — three of them, all D-1's,
each with a written reason and a ratchet (`spec/golden/kernel_exception.rb`). `drill_through.rb`
carries none and is held to the plain form. That is the exception this `Deps:` line grants, made
mechanical: a fourth hunk fails the gate as loudly as an undeclared byte does.* *Re-indentation is a separate
mechanical commit, only after `corpus` has been green a full release cycle, and reverted rather
than fixed if it goes red.*

**T-09 · The G1 CI change**
*Touches:* `.github/workflows/ci.yml`; `test/test_helper.rb:45-54`; `script/gates/*`.
*Deps:* T-06, T-07.
*Accept:* the `reporter-secret` probe job, the `needs:`/`if:` gate and the private checkout step are
**deleted**; a new `minitest-standalone` job runs the full-app suite on 4 Redmine branches **with
no secret**; a `lint` check fails on any `secrets.` reference other than `GITHUB_TOKEN`;
`zero_reporter.sh` runs in **warn** mode with a committed allowlist that may only shrink;
`layer_purity.sh` green; the `compat/` LOC is printed on every PR. **G1**, plus one dated fork-PR
run recorded per release — *a workflow cannot fork itself without reintroducing the very credential
G1 removes, so that end-to-end proof is a human artefact and the grep is what keeps it true
between artefacts.*

*As built.* The secret, probe job and private checkout went in the earlier CI rewrite — which is what
let 5.1 run at all, and immediately exposed D-2 and D-3. `no_secrets.sh`, `zero_reporter.sh` (warn,
shrinking allowlist) and the standalone `minitest` matrix on all four branches followed. **The two
gates this line names by filename were still missing and landed 2026-08-05:** `layer_purity.sh` (E3)
and `compat_size.sh` (E4). `layer_purity` runs in **warn** mode and reports `render/` as ABSENT on its
own line, because T-10 creates that directory — **T-10 should switch it to
`LAYER_PURITY_MODE=strict` in the same PR**, at which point an absent layer means the layout moved.
`compat_size` hard-fails on a version constant outside compat, and PRINTS the LOC rather than capping
it, which is what E4 specifies; the disagreement with CLAUDE.md §4 about a "committed budget" is
**F-4** and the number is the curator's. Building it found one real violation — a bare
`Redmine::VERSION::MAJOR >= 6` in `ReporterProjectPagesHelper`, from D-3's fix — now
`Compat.svg_icons?`, with the helper predicate kept as the name both icon branches are stubbed
through. **The fork-PR artefact is NOT done and is F-5.**

### Phase 3 — own the render path *(ships 0.7.0; runs in parallel with Phase 2)*

**T-10 · The document-request interface**
*Touches:* `render/{document_request,page_furniture,result,failure,capabilities,registry,renderer}.rb`.
*Deps:* T-03 (baseline first). Independent of Phase 2.
*Accept:* `DocumentRequest` carries page geometry, orientation, margins, `PageFurniture`, media,
**`print_backgrounds` defaulting to `true`** (not to the engine's default — Chromium's is `false`
and a naive swap silently loses every badge colour), page breaks, readiness, timeout, metadata,
correlation id; **it has no field a credential could travel in** — no `cookies:`, `headers:`,
`auth:`, so cookie-passing is *unrepresentable*, not merely discouraged; `PageFurniture` slots take
literal text plus a **closed token set**; `Result` is a `Success | Failure` sum type with a closed
failure-code set; `Renderer` enforces the `%PDF-`/`%%EOF` and minimum-size post-conditions **above
every adapter**, so no adapter can violate INV-5 by accident; `layer_purity.sh` proves `render/**`
contains no `Rails.`, `ActiveRecord`, `Liquid`, `Issue`, `Net::HTTP`, `cookie` or `session`.

**T-11 · Readiness protocol + chart shell**
*Touches:* `render/readiness.rb`; `assets/javascripts/chart_shell.js`.
*Deps:* T-10.
*Accept:* one DOM contract (`window.__rd` with `pending/ready/begin/end/fail`, plus
`data-rd-ready` and `window.status`) emitted by the plugin's own shell, mapped per engine; an
in-page watchdog; on timeout the engine **still renders** and returns `Success` with
`Degradation(:readiness_timeout, pending: n)` unless `strict` — *a chart-less-but-correct document
beats no document*; **`begin`/`end` are never the template author's job.**
**The falsifier:** three fixtures — 0 charts, 3 charts that finish, 1 chart that never calls
`end()` — with expected durations <1 s / <3 s / ≈timeout. **A fixture signalling at ~6 s must
produce a document containing the post-readiness marker, and the harness's own monotonic
measurement must be ≥5.9 s and ≤12 s.** An implementation using today's fixed 3-second delay fails
this *by construction*; one that just waits out the timeout fails the upper bound. Run 3/3 attempts
on the gate with deliberately generous bounds — a tight wall-clock bound gets loosened after the
first flake and then proves nothing.

**T-12 · Engine conformance corpus + `render-smoke`**
*Touches:* `spec/conformance/F-nn-*/`; a new CI job.
*Deps:* T-10, T-11, DoR-5.
*Accept:* fixtures for page geometry, orientation+margins, per-page footer with page numbers,
page breaks, **background printing** (fails if `printBackground` defaults false), flexbox layout,
readiness (T-11's three), readiness timeout, **asset resolution with the engine in a different
network namespace**, failure semantics (typed error, zero bytes, no attachment, no journal),
resource envelope, egress denial, fonts, pathological input, and the escaping payload set under
**this engine's** JS parser. Three-state rule: an **undeclared** capability **skips with a reason**;
a **declared** capability that fails is a **hard failure**; and the support matrix is **generated
from the run**, with a lint check failing if the committed file differs.

**T-13 · Two adapters**
*Touches:* `render/engines/{chromium_cdp,wkhtmltopdf}.rb`; `pdf_polyfills.rb` → `glue/legacy/wk_legacy_shims.rb`.
*Deps:* T-12.
*Accept:* Chromium in a **separate process, never inside a Puma worker**, inline-only assets, name
resolution denied, non-root, `--no-sandbox` **not** set, a **process pool of size 1 by default**
with a bounded queue returning `Failure(:engine_unavailable)` rather than hanging;
wkhtmltopdf retained as a CI-verified **compatibility** engine with
`no_stop_slow_scripts` set back to **`false`** (today it is `true`, i.e. the engine's own
runaway-script guard is off with nothing replacing it), carrying the relocated shims plus a
`Degradation(:legacy_engine)` stamped into metadata, and **declared deprecated on arrival** with an
INV-7-shaped removal condition. Both pass T-12.
**Note the correction to ADR-004's consequence list:** the 61 polyfill lines are *not* deleted
here — they move, and are only recoverable when wkhtmltopdf is dropped.

**T-14 · Preflight / diagnostics**
*Deps:* T-13.
*Accept:* a **round trip, never `File.exist?`** — renders a probe document with a canvas, an inline
image, a Redmine-hosted image, a `{{page}}/{{pages}}` footer and a coloured background, and reports
per-check pass/fail/skip with timings; available as an admin page **and** a rake task exiting
non-zero; **it reports the renderer's actual fetch back to the Redmine host**, which is what
catches the "container is healthy but every PDF silently loses its assets" failure *at install
time* instead of in a quarterly report; output is structured (JSON) so it is asserted on rather
than log-scraped.

**T-15 · Render-path containment**
*Deps:* T-13.
*Accept:* a hard cap with **refusal before any render happens** (422, message naming the cap and
the actual count, and the render adapter double received **zero** calls — a refusal that first
renders 200 PDFs is not a refusal); a boundary test at exactly the cap; per-render timeout with a
bounded monotonic measurement **and the engine child process gone afterwards** (a timeout that
returns while the browser keeps burning CPU is the 504-with-a-burning-worker failure); a batch
timeout; concurrency observably bounded; archives **streamed** (no `Content-Length`); INV-5 asserted
— no `.pdf` containing an exception, `assert_no_difference` on **both** `Attachment.count` and
`Journal.count`.

**T-16 · Hybrid charts**
*Touches:* `render/charts/*`; `liquid/tags/chart_tag.rb`; vendored Chart.js 4.
*Deps:* T-11; needs T-19 for the tag itself.
*Accept:* `{% chart %}` emits **no markup** — it records a `ChartSpec` and a placeholder, and the
**output binding** decides: HTML → `<canvas>` plus a `<script type="application/json">` data block
(**never** a string-concatenated JS array literal, which is the entire class of the escaping
defect); PDF → server-side inline `<svg>`, vector and deterministic, with `<a xlink:href>` for
drill-through. **One shared `ChartLayout` computed server-side in Ruby for both paths**, and
Chart.js is handed explicit bounds and ticks and **not allowed to auto-scale** — that is what makes
"identical in HTML and PDF" a construction rather than an aspiration. Chart.js **vendored with a
recorded sha256, no CDN, ever**. `responsive: false` is emitted from the **engine's capabilities**,
not the author's choice — the concrete mechanism for G3. Six chart types; anything else degrades to
the JS path with a reason.
*Verify:* SVG goldens are **deterministic text**; the Chart.js visual diff is **advisory, never a
gate**. Plus the falsifier for the shared-layout claim: render a horizontal bar with 12 long labels
in both paths and compare plot-area bounding boxes — **>2% and "by construction" collapses to "by
careful tuning"**, with server-side SVG for *both* outputs as the fallback.

### Phase 2 — own the Liquid layer *(ships 0.8.0)*

**T-17 · Execution policy + the single parse entry point**
*Touches:* `liquid/{execution_policy,template_renderer}.rb`.
*Deps:* T-07.
*Accept:* **no `Liquid::Template.parse` anywhere outside `liquid/`** (gated); resource limits per
output class; a **cooperative wall-clock deadline** checked at every own tag's `render`, every
collection batch boundary and every prefetch — because resource limits bound *work units*, not
time, and a 90-second query costs one render-score point; `Timeout.timeout` **not** used
(interrupting ActiveRecord mid-statement trades a slow render for a poisoned pool); per-parse
`:strict` error mode; `strict_filters: true`, `strict_variables: false`; **errors never enter the
document** — they go to the diagnostics channel with correlation id, template id, project id, actor
and duration. *Both mechanisms are required; neither alone suffices, and the spec says so.*

**T-18 · Own drops**
*Touches:* `liquid/drops/*`, `liquid/batch.rb`.
*Deps:* T-17.
*Accept:* the disposition table in `technical-spec.md` §3.2 implemented exactly — field names kept
identical where they are just field names (the cheapest possible compatibility decision);
`closed_on` timezone-converted like its two siblings (today it is not); reference objects are
`NamedRefDrop` **plus** `*_id` accessors; `url` **always absolute**, which is what makes the base
plugin's 38-line Nokogiri-or-regexp URL rewriting unnecessary; the six other-plugin `respond_to?`
probes dropped; `all` **not implemented** on collections.
**Required spec before this task is done:** each of `to_s`, `==`, `eql?`/`hash`, `include?`,
`to_liquid` on `NamedRefDrop` renders **byte-identically to the String it replaces** under
**both Liquid 4.x and 5.x**. *Every one of those five is a claim about Liquid's internals and must
be proven by test, not by reasoning.*
*Absolute performance criteria, gating:* **zero `Issue` instantiations** for an aggregate-only
template, and **identical query count** at 10 vs 10 000 issues.

**T-19 · Own filters, incl. `| json`, + the lint**
*Deps:* T-18.
*Accept:* ~28 filters; **registration is per-render, never global** (the gem registers four modules
globally at require time and monkey-patches `Liquid::StandardFilters` unconditionally — never do
this, other plugins share the process); `call_method`, template-supplied regexes, `md5` and
`file_url` **removed, each for a stated security reason**; `| json` escapes `< > &` and
U+2028/2029; a lint rejects `{{ }}` inside `<script>` without `| json`/`| js`, **parses rather than
regexes** the HTML, and runs over the shipped examples **and the README's own snippets** — the
examples are the spec, and today the copy-paste surface carries the defective idiom. A regression
table from the escaping experiment including a **backslash-terminated** value, asserting the
assembled `<script>` block **parses** — because the actual finding was *denial of rendering via
`SyntaxError`*, so a test asserting only "no execution" would have passed the buggy code.
Plus a `StandardFilters` enumeration spec so a Liquid upgrade adding a filter is a **CI failure**
rather than a silent capability grant.

**T-20 · Retire the two compensating tags**
*Deps:* T-18.
*Accept:* `{% geo_version_map %}` (144), the addon's `VersionDrop` (108) and `issue_drop_patch.rb`
(43) deleted — **295 lines on top of the ~600 ADR-004 counts**; the tag **name** retained one minor
version as a deprecation shim that logs once and builds its map from **`Version.visible`, never
`Version.all`** (that was one of the five 0.5.0 visibility leaks); `lint_templates` flags templates
using it.

**T-21 · The multi-actor visibility suite** *(can start any time after T-07; do not defer)*
*Deps:* T-07.
*Accept:* a shared fixture with actors at `all`/`default`/`own` visibility, one without the
restricted-CF role, one without time-entry permission, an outsider and anonymous; a private issue;
a role-restricted custom field; a private saved query. Tests asserting **exact** per-actor totals
**and** strict inequality; that a restricted CF's **name appears nowhere** in the output for an
unentitled viewer (values-only assertions pass a leaky implementation); the fail-closed `'1=0'`
branch as a unit test; a zero-with-`degraded: false` case (a correctly-applied filter yielding zero
is *not* a refusal); **and an ordering test running two actors in one process in both orders, plus
an A/B/A** — a memoised `User.current` or a cached visibility condition passes one order and fails
the other, and the aggregator already memoises adapter family on the class, so this is not
paranoia.
Plus the **monotonicity property**: for actors u1 ⊆ u2, every count for u1 ≤ u2. ~40 lines, no
expected values to maintain, and it constrains every parameter combination — but **one-sided**
(a both-see-too-much regression passes by equality, so it must be paired with the strict case) and
**not applicable to `avg`/`distinct`** (removing rows can raise an average). Both limits written
into the file, or it produces false failures and gets deleted.

### Phase 4 — absorb the reporting surface *(ships 1.0.0)*

**T-22 · Own tables** — per `technical-spec.md` §7. *Accept:* namespaced classes and new table
names so **both plugins can be installed simultaneously** (which turns the riskiest event in the
project from a leap of faith into a comparison); schedule dates as `date` not `datetime`; run-state
columns; **a unique index on `(schedule_id, occurrence_date)`**; recipients are `user_id` only —
no free-text `to`/`cc`/`bcc`/`from`, a security-motivated schema decision; an append-only
template-versions table. **Plus a `visibility` column on the template table (T-40):** private /
roles / project, the three values Redmine's saved queries already use, because
`manage_public_reporter_dashboards_templates` governs nothing without it and adding the column later
is a migration this plan does not need. `lock_version` and every unique index are created **in the
same migration as their table** — see `technical-spec.md` §7 rule 6.

**T-23 · Template model, CRUD, preview.** *Accept:* template types by `source` field (T-31), not a subclass tree; the
template resolves through the same scope its picker offers; import uses a **closed type map** and
`safe_load` — never `YAML.load_file` + `constantize`, and never `rescue Exception`; export is a
plain Hash. **Plus T-40's promotion of FIVE permissions** (this sentence said "six" and listed
`manage_public_…` twice — corrected 2026-08-07; §4.1's table has five T-23 rows) —
`view_reporter_dashboards_reports` and the four authoring ones, of which
`manage_public_reporter_dashboards_templates` is one: each gets its action map, loses its `lands_in`, and
gains labels in **all nine** locales, with `add_…`'s label reading *"Author report templates
(executes server-side code)"*. Import requires `add_…` **and** `edit_…` — it authors code from a
file — and export requires whichever permission shows the content in the editor; neither gets a
permission of its own (`technical-spec.md` §4.1). A permission test **per action**, not per
controller, and `edit_own_…` tested with a template somebody else authored, which is the case that
looks right until it is tried.

**T-24 · `import:run` / `import:verify`.** *Accept:* copy-only, forward-only, **never writes to
reporter's tables**, idempotent, stamping `source_template_id` + digest; `import_status` reports
divergence so drift is **visible rather than silent**; `import:verify` diffs **aggregation result
hashes**, not HTML — the corpus discipline applied to user data.
**Adopt is rejected**: an operator following Redmine's documented uninstall
(`migrate NAME=redmine_reporter VERSION=0`) would run reporter's own down-migrations and **drop the
tables the new plugin is live on**. Nothing inside the new plugin can prevent that.

**T-25 · Scheduler.** *Accept:* the runner **claims the occurrence first** by inserting the run row,
so a duplicate is caught by the unique index and skipped; **one render per occurrence, not per
recipient**; per-schedule rescue so one failure does not embargo later schedules, and the task exits
non-zero; bounded catch-up (`max_catchup_days` default 7 — a schedule dormant for a year must not
emit 365 e-mails), and a **plain run does not silently backfill**; a failure notifies the owner
**with no attachment**; the render identity is explicit, stored and auditable, and a test send uses
the **same** identity as the real run; the cron requirement is **documented** and preflight warns
when the task has never run. **Plus T-40's promotion of `view_reporter_dashboards_schedules`
(`read: true`) and `manage_reporter_dashboards_schedules`** — the split exists so an operator can
answer *"did it run"* without being able to change who receives it.

**T-28 · Share links** *(deps: T-22, T-23)*
*Accept:* two tables (links + access log); **only the token digest stored**, constant-time
comparison; **mandatory expiry**, individually revocable, optional max-uses; **snapshot mode serves
frozen bytes so no visibility decision happens at request time**; live-query mode opt-in per template
and recording `render_as_user_id`; attachment URLs scoped to the link and revoked with it; owner/admin
UI listing active links with revoke and revoke-all. Tests: an expired link is refused; a revoked link
is refused; a link over `max_uses` is refused; a snapshot link returns identical bytes regardless of
who opens it; **a database dump contains no usable token**; every access appears in the log.
**Plus T-40's promotion of `share_reporter_dashboards_reports` and
`publish_reporter_dashboards_reports`** — two grants and not one, because *"anyone holding this
URL"* and *"anyone on the internet"* are different decisions; revocation stays with the link's
creator, the template's owner and admins (FR-53), which is ownership rather than a permission, and a
test asserts a third party holding **both** permissions still cannot revoke somebody else's link.

**T-29 · Template exchange bundle — AND the streamed archive** *(deps: T-23)*

**The zip is T-29's alone as of 2026-08-08** (curator decision, closing §Findings S-12 and
E-6's third bullet, which used to read "T-29 or T-30"). *Accept, added:* a per-record export of
more than one document streams a **zip with no `Content-Length`**; the 501 refusal in
`TemplatesController#send_document` and the un-drawn download button both go with it; the cap
(`BatchGuard`) is still asked BEFORE anything is rendered, so a refused 40 000-document export
still costs one `COUNT(*)`; and a test asserts the response is streamed rather than buffered,
because the whole point of the missing `Content-Length` is that the worker does not hold the
archive in memory.

*Accept:* canonical **JSON** export with `format_version`; YAML accepted for reading via `safe_load`
with `permitted_classes` and `aliases: false`; type resolved through a **closed map** —
`constantize` appears nowhere; `import:plan` writes nothing and reports per-template new/updated/
skipped plus lint findings; `import:run` is transactional **per template** so one bad template does
not abort the bundle, each failure reported with a reason; `--on-conflict skip|rename|overwrite`;
**export → import → export is byte-identical** (a test).

**T-30 · Failure reports** *(deps: T-13, T-15)*
*Accept:* a diagnostics view naming template, Liquid line where applicable, engine + version,
duration and a **correlation id**; an **optional** failure document that is a real valid PDF titled as
a failure, filename `report-FAILED-<id>.pdf`, carrying the correlation id and a **safe** summary —
tests assert it contains **no** exception class name, no SQL fragment, no role/member/project ids;
default off; never persisted as an attachment unless requested; scheduled failure notifies the owner
with the correlation id and **no attachment**.

**T-31 · Time-entry reporting as a `source` field** *(deps: T-23; replaces a third template type)*

**UNBLOCKED 2026-08-08 — the curator took S-13's two decisions and this entry is rewritten to
match them.** Read §Findings **S-13** before starting: the clause this task used to rest on
(*"a `TimeEntryQuery`-backed scope feeds the same aggregation core"*) was measured and is
false, and the answer is a second owned calculator rather than an edit to the frozen kernel.

*Accept, as revised 2026-08-08 (second revision — the corpus clause below replaced one that
overstated it; see §Findings S-13's closing note):*

1. **`source` ∈ `issues | time_entries` on the template model, and the column already
   exists** (migration 002, T-22). Nothing new in the schema.
2. **ONE of everything above the query.** One controller, one CRUD, one preview, one
   permission set, one template model — `[OQ-H]` closed this and it stays closed. A test
   asserts no second controller and no second template class appears.
3. **Two queries, and `source` is the switch.** `source: issues` resolves through
   `IssueQuery#base_scope` (as today); `source: time_entries` resolves through
   `TimeEntryQuery#base_scope`. Both start from their model's `visible` scope, so INV-1/INV-3
   are held by construction on both paths.
4. **A NEW owned aggregation module for time entries** — a sibling of
   `aggregation/query_aggregator.rb`, never an edit to it. `KERNEL_FILES` unchanged, `RATCHET`
   stays 1, G7 untouched. It shares the RESULT VOCABULARY (bucket shape, `filter` payloads for
   drill-through, caps, the `(none)` bucket) and not the query builder. `SUM(hours)` is its
   defining measure, and `activity` and `user` are dimensions the issue kernel does not have.
5. **EVERY GROUPED AGGREGATE IS READ POSITIONALLY. This is a correctness clause, not a style
   one, and it is the single most important line in this task.** The MariaDB
   column-label-truncation defect (§Findings D-1, HANDOVER §1) was fixed for the COUNT path
   only: `grouped_counts` does `relation.pluck(*group_values, Arel.sql("COUNT(…)"))` and reads
   the row by POSITION, while `raw_measure` still does `relation.sum(Arel.sql(expression))` on
   a grouped relation — and ActiveRecord keys that Hash by the group expression's own TEXT,
   which MariaDB truncates at 256 characters. Past that every key returns `NULL`, the buckets
   collapse into one and the total is taken from whichever group the server returned last.
   **`SUM(hours)` grouped by a dimension is this module's entire purpose, so it walks straight
   into the one defect class this project has documented as still open and ungated** — the
   handover says of it, in as many words, *"no gate in this project can catch it"*. Copy
   `grouped_counts`' shape for sums and averages too; a `.sum`/`.average`/`.count` on a
   grouped relation anywhere in the new module is a defect, and a test asserts the module's
   source contains none.
6. **CORRECTNESS IS PROVEN BY AN INDEPENDENT RUBY-SIDE ORACLE, NOT BY A SNAPSHOT.** For each
   case the expected figure is computed TWICE: once by the module (SQL, `GROUP BY`, `SUM`) and
   once by loading the rows and adding them up **in Ruby**. Two independent computations
   agreeing is a stronger claim than a recorded file, it explains itself to a reader, and Ruby
   arithmetic does not vary by engine — which is exactly what makes it the check that catches
   clause 5's defect. **No golden-corpus file is required** and none should be added: T-01's
   corpus exists to prove *ported* behaviour has not MOVED, and its own README says "nothing in
   this directory tests the plugin's behaviour". Snapshotting new code on day one freezes
   whatever it happens to answer, bugs included, and makes fixing one look like a gate breach.
7. **IT RUNS ON ALL THREE ENGINES, AND THAT IS A HARD REQUIREMENT.** The oracle comparison
   lives in `spec/adapter/`, which the `adapter` CI job already executes against PostgreSQL,
   MySQL 8 and MariaDB 11. PostgreSQL-only would be finding **S-9**'s shape all over again, and
   it would specifically miss clause 5.

   **The parenthetical that used to close this clause — *"the engine the defect lives on is the
   one a local run in this container cannot install"* — was FALSE and is deleted.** MariaDB
   installs here in one apt command and D-1 reproduces on it in seconds; HANDOVER §1 now
   carries the recipe and the measurement. Delivered 2026-08-08 against **PostgreSQL 16 and
   MariaDB 10.11 locally**, both green on the whole of `spec/adapter` and on the pinned corpus.
   **MySQL 8 remains CI's** — the two Debian packages conflict (HANDOVER §4) — so that third
   cell is `UNVERIFIED` locally and verified by the `adapter (MySQL 8)` job, which runs this
   directory unchanged.
8. **Time-entry VISIBILITY is a different rule from issue visibility, and the narrowing is
   VISIBLE rather than silent** — see §Findings **S-14**, which the curator settled on
   2026-08-08. `TimeEntry.visible_condition` reads `Role#time_entries_visibility`, so an actor
   whose role says `own` gets only their own hours and an actor without `view_time_entries`
   gets `1=0`. Fail closed on both, and **say so on the page** when the actor's role narrowed
   the data — the pattern is §9b.2's *"Preview of 50 of 1 284 issues"*. A multi-actor test on
   the time-entry path, mirroring `test/unit/multi_actor_visibility_test.rb`, covers all three
   role states; it is the test most likely to be skipped and the one that matters most.
9. **`ReportRun` stops refusing `source: time_entries`.** Its `unsupported_source`
   diagnostic and the message naming T-31 both go, and `Drops::TimeEntriesDrop` — built in
   T-18 and still without a producer — gets one.
10. **A template body reports on ONE source.** Mixing issue data and time data in one template
    was **dropped by curator decision, not deferred** (S-13 clause 3), so there is no second
    scope slot on `RenderContext` and no test for a mixed template. §7b.4's promise of it and
    FR-60 have both been corrected; do not reintroduce it as a convenience.

**T-32 · Ad-hoc report mail, controlled** *(deps: T-23, T-30)*
*Accept:* issues resolved through **`Issue.visible(User.current)`** — a test asserts an issue the
requester cannot see is refused, not silently included; **`From` is server-controlled** with the
requester in `Reply-To`; recipients are Redmine users unless an admin enables external addresses,
then against a **domain allowlist**; every send audited (who, when, template, issues, recipients) and
visible to admins; rate-limited per user; a render failure produces a failure notice, never a mail
with a broken attachment. **Plus T-40's promotion of `mail_reporter_dashboards_reports`**, which
carries `require: :loggedin` and not `:member`: it must never reach the Anonymous role, and a
logged-in non-member legitimately mails themselves a report they can already read. The external-address
switch stays an **admin setting plus a domain allowlist** and does *not* become a role permission —
it is a policy about the installation (§4.1).

**T-26 · My-page widgets, locales, and the final gate flip.** *(deps: T-30, T-31, T-32 — **added
2026-08-08**, see below; the original entry had none and three of its four items are downstream of
Phase 4.)*

*Accept, as revised 2026-08-08 after the four items were checked against the tree:*

1. **`zero_reporter.sh` flips from warn to hard gate — PARTLY DONE, and the rest is blocked.**
   *Done:* the ratchet now only tightens — a STALE allowlist entry is a failure rather than a note,
   so an entry that permits nothing today cannot silently permit something tomorrow. And `strict`
   was made **reachable**: it used to mean *"ANY reference fails, allowlist or not"*, described as
   "what 1.0 must pass", which **could never pass** — the curator decided on 2026-08-05 that the 1.0
   target is *empty except the importer*, because reading the base plugin's data by name is what the
   importer is FOR. Strict now exempts entries whose reason begins `[permanent]`, which is only the
   four importer entries, and refuses everything else on the list. Measured: strict fails on 12 files
   today and passes when nothing is debt.
   *Blocked:* actually switching CI to strict. Five of those twelve are the reporting-surface
   integration, which the allowlist has always said *"goes away with Phase 4, when the reporting
   surface is owned (T-30..T-35)"* — and T-34 is not started. **T-30, T-31 and T-32 have
   since landed**, so this clause is now blocked on T-34 alone; the five files have not been
   re-checked against the tree since.
2. **`glue/legacy/` deleted — BLOCKED, and the original entry was wrong to call it dead.**
   `Liquid::ScopeBinding#bind` (`scope_binding.rb:67`) routes to it on **every render with no owned
   render context**: *"No render context means no owned renderer produced this render, so this is a
   host-plugin install and the legacy glue is what knows how to read it."* That is the path every
   `{% sql_aggregate %}` inside a **reporter-hosted** template takes today. Deleting it degrades
   cleanly rather than crashing — `legacy_available?` is a real `const_defined?` check, not a
   swallowed `NameError` — but it degrades to *no scope resolved*, so those tags would silently start
   reporting nothing on exactly the installs the integration exists for. It goes when T-30..T-32 own
   the surface, not before. **All three have now landed** — which makes this item checkable rather
   than done: owning the surface is what removes the NEED for the legacy path, and whether any
   install still takes it is a question about `scope_binding.rb:67`'s branch, not about this table.
3. **The secret-gated job deleted — ALREADY DONE**, in T-09. `ci.yml:3-9` records it, and
   `script/gates/no_secrets.sh` is what stops it coming back.
4. **`scope_resolution.rb` deleted — BLOCKED, same reason as 2**, plus one of its own:
   `scope_binding.rb:118` records that *"its behaviour is frozen by the scope fixture in
   `test/unit/golden_scope_fixture_test.rb` and a change to it would move an oracle that cannot be
   regenerated"*. CLAUDE.md §1's deletion guard has formally expired — the fixture is committed at
   `ff3406c` — but deleting the module deletes the subject the oracle tests, so the two must move
   together and deliberately.

**Still owed by T-26:** the my-page widgets and locales its title names, and the CI flip to strict
once Phase 4 lands.

**T-33 · The asset-resolution triple + `asset_policy`** *(deps: T-12; blocks nothing after T-13)*
**DONE 2026-08-06.** *Touches (as built, and the address moved — findings F-13/F-13b):*
`assets/{policy,origin,reference,content_types,bundled_assets,local_store,fetcher,document_scanner,resolver,resolution}.rb`;
`render/asset_binding.rb`; `script/gates/layer_purity.sh` (two new arms); `init.rb` +
`app/views/settings/_reporter_dashboards.html.erb` + nine locale files. **No engine capability set
changed** — see finding **F-16** for why declaring `:asset_upload` on `:chromium_cdp` is T-34's
work and not a line here.
*Accept:* one `AssetResolver` walk choosing the **most restrictive model the engine declares**;
`:bundled` default proves a correct PDF with the engine's name resolution denied; a third-party URL
under `:bundled` yields `Failure(:asset_unresolved)` **naming the URL**, not a blank image; an empty
`asset_allowlist` under `:external` behaves **identically** to `:bundled` (the fail-closed test, and
the one most likely to be got wrong); a fetch carries **no** cookie/session/API-key/`Authorization`
header — asserted by a request-recording double, not by reading the code; a DNS name resolving to
`127.0.0.1`/`169.254.0.0/16`/RFC1918 is refused **after** resolution; size, time and redirect caps
each have a boundary test; and `:asset_http` is proven **off** in `:external` mode wherever the
engine supports `:asset_upload` — the inversion that keeps INV-8 true. A test asserts an author
**cannot** widen egress from template content.

**T-34 · The Gotenberg adapter** *(deps: T-13; parallel with T-14/T-15)*
**DONE 2026-08-10.** Every Accept clause below is met and the evidence is in §Findings
**E-27**; the corpus is **19 pass / 0 fail / 1 skip**, the one skip being `F-14-asset-inline`
against an `:asset_inline` this engine does not declare, which is G12's first arm rather
than a gap. `verification` moved `documented` → **`pending`**, not `corpus`: the run has not
been read in CI, and the promotion is a curator act on that run (E-27 row 1).
*Touches (as built — three additions to the stated list, each argued in E-27):*
`render/engines/gotenberg.rb`; `docker-compose.gotenberg.yml`; a third `render-smoke` leg;
**plus** `.github/workflows/gotenberg-cve.yml` (the nightly scan the Accept requires had no
home — `ci.yml` runs on push, and a schedule there would run the whole matrix nightly),
`script/gates/layer_purity.sh` (the `render-network` arm that BOUNDS this file's one
`Net::HTTP` exemption and carries the boundary grep), and
`render/engine_catalogue.rb` + `reporting/report_run.rb` (the "auto-detect never selects
`:gotenberg`" clause was true by ALPHABETICAL ACCIDENT and therefore untestable; the
declared `default:` is now read and a `needs_service` engine is never auto-selected).
*Accept:* `convert/html` with `:asset_upload` only, and the boundary grep asserts
`forms/chromium/convert/url` **absent from the whole tree**; passes T-12's corpus unmodified — the
proof that the interface, not the adapter, is the contract; `#preflight` **fails with a named
remediation** when the endpoint answers without the configured credential, and a test stands up an
unauthenticated instance to prove the failure fires (a security check that is never observed failing
is not a check); the container is pinned **by digest** and the CVE scan runs nightly against that
digest; the example compose file carries `internal: true`, non-root and a read-only root filesystem.
**Default engine unchanged** — a test asserts auto-detect never selects `:gotenberg`.

**T-35 · Mermaid** *(deps: T-16, T-33 — BOTH LANDED, so this is startable)*
**`[OQ-L]` IS SETTLED — measured 2026-08-06, the answer is NO** (§Findings E-18, technical-spec §6.1
and §12). Mermaid 11.16.1 does not run under wkhtmltopdf's Qt WebKit: its bundle never defines its
global, because it is an esbuild IIFE using `||=` — and that cause is established by a
discriminator (two three-line documents differing only in `x.a = x.a || 1` versus `x.a ||= 1`; the
second fails to PARSE, so the statement before it never runs), not inferred from the bundle's shape.
So this task builds with `:mermaid` **absent** for
wkhtmltopdf as a measured fact rather than an expectation, and the "settles `[OQ-L]` by measurement"
clause below is already satisfied — the conformance fixture confirms it rather than discovering it.
Two more things the measurement handed over. Of the required fallback, only the **"source emitted,
not blank"** half is free — an untouched `<pre class="mermaid">` stays visible in the PDF — and the
**label and the `Degradation(:mermaid_unsupported)` are still yours to write**; nothing in the
measurement produces either, so do not read this as "the fallback already works". And the bundle is
**3,566,058 bytes**, nearly 7× `inline_max_bytes` —
§6 says a bundled library is always inline and unaffected by `asset_policy`, and that is the answer,
but decide it deliberately rather than discovering it in a degradation list.
**STARTED AND STOPPED AT ITS FOUNDATION, 2026-08-06 — see §Findings F-17.** "One sanitiser shared
with `SvgRenderer`" cannot hold as written: Mermaid runs in the BROWSER on both bindings, so on the
`:html` path the plugin never sees the SVG at all — and that is the path where a `<script>` would run
with the viewer's session. Three options are written up with costs, a recommendation, and every
measurement needed to choose (all six diagram families render clean; 15 elements / 61 attributes;
zero `<foreignObject>`, zero `<script>`; one 5.5 KB `<style>` per diagram carrying none of the CSS
vectors; `SvgRenderer`'s own 10 elements / 33 attributes, and the fact that it does not pass through
a sanitiser today). Nothing was built, so the tree is clean.
*Touches (as specified — and `render/svg_sanitizer.rb` is the wrong address for the same reason
F-13b moved `asset_resolver.rb`: `charts/svg_renderer.rb` must use it, and `charts/**` may not name
`Dashboards::Render`. The precedent is `script_safe_json.rb`, top-level, belonging to no layer):*
`liquid/tags/mermaid_tag.rb`; `render/svg_sanitizer.rb`; vendored Mermaid 11.x.
*Accept:* block tag, body **not** Liquid-interpolated unless `interpolate: true`; readiness covered
by the existing `begin()`/`end()` contract with **no new handshake**; **one sanitiser shared with
`SvgRenderer`** — asserted by both producers running the same allowlist test set, including
`<script>`, `<foreignObject>`, `on*` and a non-drill `xlink:href`; on an engine without `:javascript`
the source is emitted, labelled, with `Degradation(:mermaid_unsupported)` — and the test asserts the
output is **not blank**; `mermaid_max_bytes` boundary; wkhtmltopdf declares `:mermaid` **absent**
even though it declares `:javascript` (settles `[OQ-L]` by measurement).

**T-36 · Reversible migrations + the `migrate-updown` job** *(deps: T-22; must land in the same
release as T-22, not after it)*
*Accept:* no `up`/`down` pair and no `execute` in a `change` block anywhere — a grep gate; a new CI
job per Rails branch that migrates up from empty, dumps the schema, migrates `VERSION=0`, and
asserts the dump **equals the pre-install dump** including `plugin_schema_info` **and** that
`reporter_project_tabs` still exists (the mirror of the hazard this dossier criticised in the base
plugin); up again is idempotent; a `column_present?` guard test for the three post-0.6 columns; and a
test asserting **no migration touches template content**. Failing this job blocks a release —
a plugin that cannot be uninstalled cleanly cannot honestly be offered for a trial install, and the
trial install is the entire A/B argument for copy-not-adopt.

**T-37 · The authoring experience** *(deps: T-19 for the linter, T-23 for the editor host; the
starter gallery additionally needs T-16 and T-35 to render its thumbnails)*
*Touches:* `app/views/…/templates/`; vendored CodeMirror 6; `render/drop_reference.rb`.
*Accept:* the editor's findings panel is fed by **the same linter object** the rake task calls —
asserted by a test that runs both over one fixture and compares the finding lists, so the two can
never diverge; findings carry line and column and are shown in the gutter; the editor degrades to a
`<textarea>` with server-side lint intact when JS is off; preview renders **HTML and PDF**, is
bounded and says *"preview of N of M"* rather than truncating silently; a failed preview shows
FR-58's diagnostics **in the editor**; the drop reference is **generated from the declared
surfaces** with a `drop_reference_parity` gate asserting both directions; a starter gallery whose
every entry lints clean and renders on every engine in the matrix, thumbnails generated in CI; a
chart form that **inserts the tag** and stores no hidden state. `[OQ-M]` — verify the CodeMirror
bundle against §6's no-build-step rule on a real Redmine 7.0 **before** vendoring it; the fallback
if it fails is a plain textarea plus the server-side lint panel, which already satisfies FR-71.

**T-38 · One stylesheet, two outputs** *(deps: T-16; parallel with T-37)*
*Accept:* one print-first stylesheet and one type scale used by the HTML view and the PDF body;
`thead` repeats across pages in a ≥3-page table fixture; `break-inside: avoid` holds for cards and
chart blocks; the palette is **read from `ChartLayout`**, not duplicated in CSS — a test asserts a
single source; every `SvgRenderer` and Mermaid output carries `<title>`/`<desc>`; a chart whose
meaning rests on colour alone fails a lint; drill-through links in the PDF are real links, asserted
by extracting the link annotations from the produced PDF. Chrome uses Redmine's own classes and icon
set per branch — a grep gate forbids a plugin-local design token in chrome CSS.

**T-27 · INV-9 as an enforced boundary.** *(deps: T-26, T-40)* *Accept:* the permission label reads
*"Author report templates (executes server-side code)"* with an inline warning and a README section;
**the `template_authoring` setting this line used to require is GONE** — T-40 replaced it with
§4.1's role permissions, so what T-27 owes here instead is the **upgrade diagnostic** that made the
setting unnecessary: the preflight page lists every role holding the base plugin's authoring
permission **beside every role holding ours**, with a test for the case where the base plugin is absent
(the list is empty, not an error) **and a test for a role that holds ours and not theirs** — which is
not a hypothetical, because core's `DefaultData::Loader` grants Manager every setable permission on a
fresh install, so on that path the diagnostic is the *only* thing that surfaces a code-execution grant
nobody chose (§4.1, T-40 finding 2); the widget iframe carries
`sandbox="allow-scripts"` **without** `allow-same-origin` plus a restrictive CSP, so template
JavaScript can neither read the session cookie nor call the API as the viewer; **the named
regression handled rather than discovered** — the height-fit script reads
`frame.contentWindow.document` and **breaks** under an opaque origin, so the shell posts its height
via `postMessage` with an `event.source` check and a numeric-range guard; `no_html_safe` gate allows
`raw(` in ≤2 files.

**Curator decisions, 2026-08-06 — three, all taken, none outstanding.**

1. **The permission set is FROZEN at 13.** *"13 permissions is already very very fine grained, I
   wouldn't expand unless really necessary."* So §4.1's table is the contract, not a starting point:
   a task that wants a fourteenth must argue for it against that sentence, and "it would be tidier"
   is not the argument. The seven entries under *Deliberately not permissions* stay rejected —
   import keeps requiring `add_` **and** `edit_`, share-link revocation stays ownership, external
   mail addresses stay an installation setting. **Splitting or renaming one after T-23 registers it
   is a migration plus an upgrade note**, because permission names are a public contract (§1), so the
   cheap moment to disagree was before this line and it has passed.
2. **`:wkhtmltopdf` is promoted to `verification: corpus`** — see ~~E-5~~, closed above.
3. **`CLAUDE.md`'s `[OQ]` count is corrected**: it claimed 11 open, which was stale by four. Six are
   closed (A, B, C, I, L, F) and seven are open (D, E, G, H, J, K, M), and §11.1 now lists them by
   name so the next drift is visible rather than arithmetic.

**T-40 · The permission model, and the parity gate that keeps it honest** *(no deps; **blocks T-27**,
constrains T-22, T-23, T-25, T-28, T-32)*
*Touches:* `lib/redmine_reporter_dashboards/permissions.rb`, `init.rb`,
`lib/redmine_reporter_dashboards.rb`, `spec/permissions/permission_map_spec.rb`,
`spec/permissions/registration_dsl_spec.rb`, `spec/permissions/fixtures/controllers/`,
`technical-spec.md` §4.1, `functional-spec.md` FR-21b.
*Accept:* the `template_authoring` setting is **deleted from the specs**, not given a default, and
`[OQ-F]` is closed with it — the curator's decision of 2026-08-06 is that roles get permissions the
normal Redmine way; the permission set is **data** so that a DB-less spec can assert it, and `init.rb`
holds the only loop that turns it into a registration, with that loop asserted **twice** — as data,
and by a committed recorder mimicking `Redmine::Plugin#project_module`'s `instance_eval`, which must
receive the same three calls the literals made, argument for argument, and which fails if `init.rb`
stops containing the loop it copies; `require: :member` is **derived** from `authoring: true` — not
written on the entry at all, with an example asserting no authoring entry writes one, because a
consistency check between two hand-typed fields cannot catch both being wrong together; every
registered permission is labelled in **all nine** locales, **its project module too**, and every
*planned* one in none, so promotion cannot happen one locale at a time; the spec **parses** each
controller rather than grepping it (§Findings E-14 is why) and fails on a mapped action that does not
exist or is private, on `authorize` not running **for a mapped action** — honouring `only:`, `except:`
and `skip_before_action`, not merely appearing in the file — on **any public action** that is neither
mapped nor recorded in `NON_PERMISSION_GUARDS`, on a **routed** endpoint the reader cannot see, on a
route written in a form it does not recognise, and on a `define_method` in a controller body; the
controller search is **recursive**, so a namespaced controller counts; each `NON_PERMISSION_GUARDS`
entry names the guard it really uses and the spec checks that claim against the controller **for that
action**; a boot-time collision check logs at **error** when another plugin has registered one of our
names, with its message built by a tested method rather than inline in the boot hook, and reaching
stderr when there is no logger rather than nothing; §4.1's table is asserted to list exactly the
permissions in the map, in order, with the right task beside each unregistered one; and the AST reader
has its own examples against **fixture controllers** carrying every construct `app/controllers/` does
not — because an extraction broken by a newer Ruby, or by a construct it never learned, returns
**nothing** and turns every assertion above green for the wrong reason.

**What T-40 does NOT do, and must not be read as having done.**

1. **It registers no reporting permission.** The ten in §4.1's table are design until the task named
   beside each one ships the controller it guards. Each of those tasks owes the promotion (action map,
   drop the task id, nine `permission_*` labels, and for the first one the nine `project_module_*`
   labels) and a permission test **per entry point** rather than per controller (G5). **T-22** owes
   the template model's `visibility` column — T-22 and not T-23, because §7 rule 6 requires a column
   in the same migration as its table, and `manage_public_reporter_dashboards_templates` governs
   nothing without it.
2. **It does not make a fresh install `:admins_only`.** T-40's review refuted that claim, which this
   section made in its first version. This plugin grants nothing, but core's `DefaultData::Loader`
   runs `manager.permissions = manager.setable_permissions.collect(&:name)` on a fresh install
   (identically on 5.1 → 7.0), and `setable_permissions` subtracts only `public_permissions` for a
   givable role — so an install that loads the default configuration with the plugin present hands
   **Manager** every setable permission of ours, `require: :member` included. **T-27's diagnostic must
   therefore list the roles holding OUR authoring permissions, not only the base plugin's**, and its
   `Accept:` says so. That is the one thing that surfaces this, and no spec in this repository can:
   the grant is made in code this repository does not contain.
3. **It does not prove Redmine accepts the registration.** Only the `minitest` CI jobs do, through
   `test/functional/reporter_project_{pages,tabs}_controller_test.rb`, which grant and withhold these
   permissions and assert 200/403. Those were **not run for T-40** — no Redmine checkout in the
   container — so CI is their first execution against the loop.

## 2. Sequencing

```mermaid
graph LR
  T00[T-00 enum] --> T01[T-01 freeze]
  T00 --> T03[T-03 baseline]
  T02[T-02 import:plan]
  T04[T-04 positioned] --> T05[T-05 soft detect] --> T06[T-06 widgets]
  T01 --> T07[T-07 ScopeBinding]
  T05 --> T07
  T01 --> T08[T-08 kernel port]
  T06 --> T09[T-09 G1 CI]
  T07 --> T09
  T07 --> T21[T-21 visibility suite]
  T03 --> T10[T-10 doc request]
  T10 --> T11 --> T12 --> T13 --> T14
  T13 --> T15
  T07 --> T17[T-17 policy] --> T18[T-18 drops] --> T19[T-19 filters]
  T18 --> T20
  T11 --> T16[T-16 charts]
  T19 --> T16
  T13 --> T22[T-22 tables] --> T23 --> T24 --> T25 --> T26
  T19 --> T23
  T26 --> T27
  T12 --> T33[T-33 asset policy]
  T13 --> T34[T-34 gotenberg]
  T16 --> T35[T-35 mermaid]
  T33 --> T35
  T22 --> T36[T-36 migrate updown]
  T19 --> T37[T-37 authoring UX]
  T23 --> T37
  T16 --> T38[T-38 one stylesheet]
```

**Critical path:** T-00 → T-01 → T-07 → T-17 → T-18 → T-19 → T-23 → T-25 → T-26. **T-33…T-38 are
off it** — none of the six is a prerequisite of another task, which is why they could be omitted for
this long without the plan noticing. That is a property of the plan worth distrusting, not
celebrating: *off the critical path* and *optional* are not the same thing, and T-36 in particular
must ship **with** T-22 rather than after it.

**T-40 is not on the graph, but it is not dependency-free in both directions: it has no dependencies
and it BLOCKS T-27**, whose `Deps:` line names it, because T-27's upgrade diagnostic is what replaced
the deleted setting. For everything else it is a *constraint* rather than a prerequisite — T-22, T-23,
T-25, T-28 and T-32 each promote permissions out of its table or owe a column to it, and its parity
spec is what fails if one of them ships an action nobody guards. Landing it early was the cheap move:
the gate exists before the controllers it will judge, so no task has to be re-reviewed for
authorization after the fact.

**T-28…T-32 (the six carried-forward capabilities, `technical-spec.md` §7b) hang off T-23** and
parallelise with each other and with T-25. T-30 additionally needs T-13/T-15 (the render path), and
T-31 *reduces* work relative to a third template type because it generalises rather than branches.

**Parallelisable:** T-02 and T-03 with T-01. **T-10…T-15 (the whole render path) with T-17…T-20
(the Liquid layer)** — the document-request interface takes HTML and does not care whether the
drops are owned yet. That is the only real compression available and it is worth taking, because
the render path carries the most uncertainty and starting early converts unknowns into
measurements. T-21 can start as soon as T-07 lands and **should not be deferred** — the drops are
where per-viewer scoping is easiest to lose silently.

**Hard ordering constraints:**
- T-01 **before** T-07 and T-08. The scope is unrecoverable after `scope_resolution.rb` goes.
- T-03 **before** T-10. The baseline cannot be measured after the aggregator changes.
- T-04 **before** T-05. Otherwise the plugin boots and 500s.
- T-07 **before** T-17. The tags need an owned context before an owned renderer can use them.
- T-11 **before** T-13. An engine cannot be conformance-tested against a contract that does not
  exist.

## 3. Verification strategy

| Layer | Runs | Proves |
|---|---|---|
| `lint` / `gates` | every PR, seconds | zero-reporter grep (with a lookahead — the plugin's own name is a substring of the forbidden one), no-secrets grep, layer purity, `no_html_safe`, `compat/` LOC, cap-table meta-test, golden-manifest check, support-matrix-is-generated, skip-has-a-reason |
| `rspec` (L1–L3) | every PR, 4 branches | library code, no DB, no Redmine boot |
| `adapter` | every PR, 3 engines | the aggregator's real SQL — **`corpus` folds in as a second invocation, 0 new jobs**, because the job cost is dominated by `bundle install` and folding is *how* the matrix stays additive |
| `minitest-standalone` | every PR, 4 branches, **no secret** | full-app, fork-runnable — G1 |
| `render-smoke` | every PR, **per engine (3)**, one branch | preflight round trip, conformance corpus, INV-5's forced failures, the readiness triple, the three asset models incl. the allowlist-refusal case, Mermaid's per-engine disposition |
| `migrate-updown` | every PR, 3 Rails branches | up → `VERSION=0` → schema equals the pre-install dump → up again idempotently |
| nightly | — | extra engines (advisory), perceptual diff (advisory), perf baseline (fails on breach), ZIP memory, engine CVE scan on the pinned digest, dependency audit |

**Target 17 jobs (today 13): additive, not multiplicative.** `render-smoke` is per **engine on one
branch**, never engine × branch — the naive 4 × 3 × 3 = 36 must be refused. `migrate-updown` is the
one unavoidably per-branch addition, because reversibility across three Rails majors is precisely
what is in doubt. **The earlier "~16" figure predates the Gotenberg adapter and the reversibility
requirement and is superseded.**

**Rules written into the files, not merely intended.** A bare `skip` fails — two mechanisms,
because one is insufficient: a grep for argument-less `skip`, **plus** a run-level check that every
skipped example has a non-empty message and that the total is ≤ a committed inventory. The
run-level one is what matters; the grep is defeated by `skip ''` and by a skip inside a helper.
`fail-fast: false` on every matrix, or you cannot see which engine broke.

**PDF verification never byte-diffs** (timestamps, object ids). Page count, extracted text,
structural metadata, targeted **scalar probes over named rectangles** (robust to font hinting,
which is precisely why full-page diffing cannot gate), and the SVG chart source as deterministic
text. Perceptual full-page diffs are nightly and advisory. Goldens **never auto-accept**: a changed
golden requires a manifest line with a reason in the same commit, and review means **looking at the
diff artefact**, not trusting the hash.

## 4. Risks and rollback

| Risk | Mitigation in this plan | Rollback |
|---|---|---|
| **Silent numerical drift** (R-04, 15) | T-01 first; byte-identical port; `corpus` on every PR; pinned reference date; per-adapter overlay **with reasons** instead of a tolerance | revert the offending commit; `corpus` names the failing case, the parameters, expected and actual |
| **Visibility invariant lost** (R-03, 15) | two-source `ScopeBinding`; the fail-open rescue **deleted rather than carried**; T-21 before the drop work; the five historical fixes as named, counted tests | `glue/legacy/` keeps the old path available while reporter is installed |
| **Stall with two half-working systems** (R-02, 20) | every task leaves the plugin releasable; Phase 1 ships standalone value in week one; `glue/legacy/` means an install is never mid-migration | stop after any phase; **stopping after Phase 3 is a success, not a failure** |
| **PDF fidelity regression** (R-05) | wkhtmltopdf retained as a CI-verified compatibility engine; `lint_templates` shows the blast radius **before** the default changes | switch the engine setting back; it is configuration, not a deploy |
| **No engine passes T-12** | the interface is the deliverable, the engine is replaceable — **keep wkhtmltopdf as the reference engine behind the new interface**. This is why the interface is specified before the engine is chosen | no rollback needed; the off-ramp *is* the plan |
| **Migration data loss** | copy-only, forward-only, never writing to reporter's tables; `import:plan` dry run; mandatory backup documented; the `VERSION=0` footgun documented and designed around | reporter's tables are untouched, so reinstalling it restores the old world |
| **Chart layout diverges between HTML and PDF** | the shared server-side `ChartLayout`; the >2% bounding-box falsifier in T-16 | server-side SVG for **both** outputs, forfeiting tooltips and legend-toggling — drill-through survives via `<a xlink:href>`, which is the only interaction the templates actually use |
| **Scope grows because DoR-1 contradicts the subset** | ADR-004 records this as a **supersession trigger**, so it is a planned branch | absorb the extra surface as Phase 4b |

## 5. Definition of done

**Per task.** A test that **failed before** the change, linked in the PR. Every new cap constant in
the cap table (a meta-test requires it, so a new cap cannot be added without a test). Every new
empty-safe path carries `degraded` **and** has both a refusal test and a true-zero test. Every new
skip carries a reason and is in the inventory. `zero_reporter` allowlist shrank or held — **never
grew**. Any golden change has a manifest line with a reason and a reviewed diff artefact. A declared
capability has a passing fixture; an undeclared one skips with a reason and the regenerated support
matrix is committed. The PR body names which of G1–G7 and INV-1…INV-9 the change touches.

**Whole idea**, against `01-context.md`'s goals:

| Goal | Done when | Not mechanised |
|---|---|---|
| **G1** | no-secrets check green; no secret-gated job conditions; a dated fork-PR run recorded | the fork-PR run itself — self-testing it would reintroduce the credential |
| **G2** | the dependency-skip helper deleted, its call sites asserting, newest branch in every job, no skip-inventory entry for it | — |
| **G3** | no polyfill / readiness-handshake / float-layout in the reference template (grep); layout and background fixtures pass | "renders equivalently" is a perceptual judgement |
| **G4** | `corpus` green on three engines over the **enumerated** space; the case set a superset of the frozen one; every overlay entry reasoned | the corpus is a bounded sample — the word *enumerated* is load-bearing and must stay |
| **G5** | T-21 green incl. the ordering and A/B/A tests; the monotonicity property green; the five historical fixes present and counted | the property is one-sided; it needs the strict case beside it |
| **G6** | failure fixtures green; no attachment, no journal, no bytes; `rescue Exception` absent by grep | — |
| **G7** | the install job green on a **bare** image executing only the README's tagged block; preflight returns structured output with every check true | **restate honestly: "≈3 commands plus one documented package install"** if the Chromium engine is the default — the clean-image job will find this immediately, so say it in the README rather than being caught by it |

**Explicitly not covered by any of this:** whether the subset is the *right* subset. No test
settles that; DoR-1's four queries do, and they are unrun. If this plan's verification section is
read as coverage of the scope decision, it will mislead.
