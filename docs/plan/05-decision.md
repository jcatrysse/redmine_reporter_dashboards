# 05 — Decision (ADR)

> Architecture Decision Record. Stable and dated. Written by `/decide`.
> Later specs and code reference this record.

- **ADR ID:** ADR-004
- **Status:** accepted
- **Date:** 2026-08-04
- **Deciders:** Jan Catrysse (curator / author-maintainer)

## Context

Two artefacts exist: `redmine_reporter_dashboards` (v0.5.0, 21 140 lines, 989 tests, a
13-job CI matrix) and the `redmine_reporter` fork it depends on (v2.0.5, 6 287 lines,
RedmineUP PRO). One line in the latter blocks Redmine 7; a 2011-era render engine taxes
every template an author writes; and the addon's full-app CI cannot run on a fork PR at all.
Full analysis in `02-analysis.md`, options in `03-options.md`, adversarial pass in
`04-risks.md`.

**Both blocking gates closed on 2026-08-04, and the second closed with a condition that is
decisive:**

- **Audience (OQ-2):** public **open source, GPL-3**, owned by the author and the public;
  explicitly **not** GEOxyz property, built for the community.
- **Agreement scope (OQ-9):** RedmineUP permits reuse and open-sourcing **"as long as I do
  not just loosely copy the whole thing."**

That condition is what settles the decision. The red team's strongest attack was that *if*
redistribution were permitted, then "publish the fork" (Option E+publish) or "absorb it
wholesale" (Option A) would deliver distribution and bus-factor relief at ~3–6 AW with
**zero** silent-regression exposure — dominating an 11–22 AW rewrite. Redistribution **is**
permitted. But **A and E+publish are precisely the wholesale copy the permission excludes.**
The attack was contingent on a scope reading that came back in the one shape that closes it.

So R4 ("do not carry the old code over as is") is no longer the author's design preference,
as `01` recorded it after the first statement. It is a **term of the permission being relied
on** — which makes it the hardest constraint in the dossier, not the softest.

## Decision

**Build a new, independent, GPL-3 Redmine plugin (Option B), reached through Option C's
sequencing and built with Option D's internal structure, scoped to the bounded subset rather
than full parity.**

Concretely, and in this order:

1. **Immediately, independent of everything else:** fix the one-line
   `enum :orientation, {...}` in the fork so Redmine 7 is unblocked today, and **freeze the
   0.5.0 aggregation golden corpus** before any code moves. The corpus is the oracle for
   "the same numbers", and it stops existing the moment the aggregator is re-seamed —
   including by step 2. This is the only time-sensitive item in the dossier.
2. **Ship a standalone plugin first (Option C's first release):** relax the `init.rb` hard
   `raise`, and release project dashboards + aggregation with **no reporter dependency**.
   8 of 10 core widgets already have none. This delivers the public-OSS unlock in week one
   and makes every later increment optional rather than load-bearing.
3. **Own the vertical (Option B, subset):** own Liquid drop layer (~1 240 reference lines,
   R6 — decided), own render path with a pluggable engine, aggregation **kernel** ported
   verbatim, `liquid_aggregate_tag.rb` **re-seamed** (not ported — see `04-risks.md` E2),
   `scope_resolution.rb` deleted.
4. **Internal structure is Option D:** three libraries with explicit contracts —
   aggregation (no Redmine boot), Liquid runtime (drops, filters, tags, execution policy),
   document renderer (engine abstraction, assets, readiness) — plus a thin Redmine glue
   layer. Enforced by the test topology: layers 1–2 specs must never boot Redmine.
5. **Engine chosen by measurement, not argument:** write the conformance fixture corpus
   first (`02` §QA), run it with the engine in a *different network namespace*, and let
   F-07 (async readiness), F-09 (asset resolution) and F-10 (failure semantics) decide.
   One CI-verified reference engine; other adapters documented and explicitly unverified.

**Scope is the bounded subset**, not R3-as-written: Tier 1 use cases are parity-mandatory,
Tier 2 parity-mandatory in *capability* but free in implementation, Tier 3 requires an
explicit keep/drop decision **backed by the production SQL queries** (R-15).

## Rationale

**Why not A or E — the condition, not the cost.** Both are cheaper and both carry lower
silent-regression risk, which the analysis states plainly and which remains true. They are
excluded because they are the "loose copy" the permission does not cover. That is a
constraint, not a preference, and it is the single cleanest reason in this ADR.

**Why B is now cheaper than costed.** Being able to read the old implementation as a
specification removes the clean-room fidelity tax: behaviour is *read*, not inferred. Every
author-week figure in `02`/`03` still includes that removed cost and is therefore an **upper
bound** — flagged as a `[GAP]`, deliberately not re-costed here (see Follow-ups).

**Why C's sequencing rather than a single pass.** R-02 (rewrite stalls, two half-working
systems) scores 20 and is driven by total scope against a working incumbent with no forcing
function. C makes every increment independently shippable *and* valuable, and delivers the
bus-factor mitigation — a fork-runnable suite — first rather than last. The "why this fails"
scenario in `04` is a 9-month stall; sequencing is the only mitigation that attacks it by
structure rather than by willpower.

**Why the subset rather than parity.** Across all three representative templates, **zero**
gem-defined `IssueDrop` accessors are consumed; the reporting model already migrated from
per-issue iteration to SQL aggregation. Parity pulls effort toward the half of the product
the author's own work abandoned, and three parity items have *negative* value (unexpiring
MD5 tokens, `YAML.load_file` + `constantize`, error-as-document). **Caveat, stated honestly:
the subset boundary rests on inference from absence of evidence, and it is the weakest part
of this decision.** See Conditions.

**Why public OSS changes the requirement set.** R9 becomes a hard requirement, not a nicety.
INV-7 ("supported = exercised by CI") becomes a promise to strangers. Bus factor becomes a
community concern — which is exactly what removing the private dependency addresses. And
GPL-3 is coherent: Redmine is GPL-2-**or-later**, so a GPL-3 plugin combines lawfully; the
`redmineup` gem's GPL-2.0 would have been the one friction point, and R6 removes it anyway.

## Rejected options

| Option | Why rejected |
|---|---|
| **A — hard fork + absorb** | **Excluded by the permission's condition**: absorbing 6 287 lines wholesale is the "loose copy" that was not granted. Secondary: inherits `rescue Exception`, unsafe YAML import, MD5 tokens and 9 locale files; and R6-as-decided means it owes the drop layer anyway, so much of its 4–7 AW advantage evaporates. Its genuine merit — risks are *known defects*, not silent regressions — is real and is why it was reopened on 2026-08-04; it loses on the condition, not on engineering. |
| **E — defer: enum fix + engine swap in the fork** | Its *first half is adopted* (step 1). Rejected as a **destination**: publishing the fork is the same excluded wholesale copy, and without publishing it leaves R1, R6, distribution and bus factor unaddressed. Re-scored symmetrically per `04-risks.md` R-14 — its former cons ("solves neither distribution nor bus factor") were false after the licence resolution, so it is rejected on the condition and on R6/R1, **not** on capability. |
| **E' — do nothing at all** | Dominated by E; the enum fix is one line. Never a serious candidate. |
| **C as a destination** | Fails R1 and leaves the compatibility seam to ossify — the classic fate of a "temporary" adapter. Adopted as the *transition*, which is where its value is. |
| **Full parity (R3 as written)** | ~22 AW midpoint against ~11–14 for the subset, for the ~60% of the base plugin that is periphery relative to the stated pain. Reformulated as parity **per use case**, scoped by measured usage. |
| **Rewriting the aggregation kernel** | 2 194 lines of visibility-aware SQL carrying 722 of 884 specs and five hard-won visibility fixes. A wrong number is worse than a crash: it is silently believed and distributed as authoritative. Ported verbatim behind the frozen corpus. |

## Consequences

**Positive**

- A plugin anyone can install, fork, and fully test — the full suite runs on outside PRs for
  the first time, which is the largest structural improvement available (G1).
- Redmine 7 unblocked on day one, before any rewrite risk is taken.
- ~600 lines of pure coupling workaround deleted: `scope_resolution.rb` (303),
  `report_patch.rb` (97), `reporter_list_patch.rb` (89), `pdf_polyfills.rb` (61),
  `reporter_report_content_patch.rb` (35), `issue_drop_patch.rb` (43).
- The wkhtmltopdf tax leaves *template authoring*: flexbox, current Chart.js, no polyfills,
  no `window.status` handshake (G3).
- GPL-3 non-commercial FOSS lands on the **exempt** side of both the PLA and (largely) the
  CRA. `[UNVERIFIED]` residual: the CRA's "open-source software steward" category imposes
  lighter but non-zero duties on maintainers of widely-used FOSS — worth checking when
  adoption is real, not now.

**Negative / accepted trade-offs**

- **The most expensive path of those available**, chosen because the cheaper two are
  excluded by the permission. Accepted knowingly.
- **R-02 (stall) remains the top risk at 20**, mitigated by sequencing rather than removed.
  Hard rule adopted: *the new plugin must be installable and useful alone from release 1.*
- **R-03/R-04 (silent regressions) are specific to this option** — visibility invariants and
  numerical drift. Mitigated by porting the kernel verbatim, freezing the corpus first, and
  porting the security specs *before* the code they test.
- Existing templates will need rework: Chromium's `printBackground: false` default silently
  loses badge and progress-bar colour, and Chart.js 2→4 is a breaking template change. **R10
  ("latest Chart.js") is not a free win** and is budgeted as a work package.
- A5's subset boundary is inference. If the production queries contradict it, scope grows.

**Follow-ups / conditions**

1. **Run the four production SQL queries (R-15).** `SELECT type, count(*) FROM
   report_templates GROUP BY type`; active `report_schedules` count; a `content LIKE` sweep
   per gem drop accessor; a log grep for `/issue_mails` and `?token=`. **A5, C-002 and C-007
   all discriminate on these same unrun queries** — the register looks like three
   independent falsifiers but is one unrun measurement. This ADR's subset scope is
   *provisional until they run.*
2. **Re-cost the work packages** without the clean-room burden. Every AW figure in
   `02`/`03` is an upper bound; C-004's 2-week spike on own-drops + one engine is the
   cheapest way to buy a real number.
3. **Answer OQ-3/OQ-4 before the engine is chosen** — external container acceptable, and how
   the renderer authenticates to fetch assets. Cookie-passing is **disqualified** (INV-8).
4. **Interrogate R5 and R1** (C-011, C-012). The worst security finding (INV-9: template
   authorship is code execution) is a direct consequence of R5, and R1 causes the
   R3-vs-R1+R4+R6 contradiction. Neither was examined before this ADR; both are now
   registered claims. **This ADR proceeds with R5 and R1 as given, and that is a decision
   taken on the author's stated requirements, not on analysis.**
5. **Set a performance baseline** (A11 / OQ-8): measure today's p95 on the three reference
   templates so R7 becomes falsifiable.
6. **Non-negotiable carry-forwards:** INV-1…INV-9. In particular the visibility invariants
   need value-level multi-actor tests, which **do not exist today** (G5), and the render path
   needs a typed-failure contract (G6, INV-5).
7. **Provenance, now lighter but not nil.** The permission allows reuse; it does not make
   attribution optional. Record what was consulted and keep incremental git history — that
   history is the evidence the work is independent rather than a repackage.

**Supersession.** This ADR is superseded if the production queries (1) show the Tier-3
surface in real use, or if the RedmineUP permission is withdrawn or narrowed — either would
reopen the option set, the latter back toward the pre-2026-08-04 state.
