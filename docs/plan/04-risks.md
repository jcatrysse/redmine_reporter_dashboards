# 04 — Risks & Open Questions

> Fed by the adversarial red-team pass (`/challenge-analysis`). This file must contain real
> tension — falsified assumptions and the "why this fails" scenario — not just a tidy risk
> table.
>
> Run 2026-08-04, downstream of synthesis and **after** the `/revise` pass that absorbed the
> licence resolution. Per `principles.md` §3 the red team is not smoothed by synthesis: the
> findings below include **two factual errors of mine that it caught**, and both are
> corrected here rather than softened.

## Red-team verdict

**The licence resolution damaged more of the analysis than the Revision section admitted,
and it was applied asymmetrically.** Three of the sharpest findings trace to one root: the
revision reopened **Option A** on the new fact but left **Option E** condemned on a
rationale the same fact destroyed. The analysis anchored on its pre-resolution verdict.

Stated plainly, the strongest case against the recommended sequence:

> If the RedmineUP agreement permits **redistribution** (not merely use), then publishing
> the fork removes the CI token gate, and **Option E + publish solves distribution and bus
> factor at ~3–6 AW** — keeping all 1 161 tests, with *zero* silent-regression exposure
> (R-03/R-04 do not apply to code that is not re-derived) and no greenfield render path.
> What E then forfeits is Liquid 5 (a need nothing in the dossier establishes) and own-drop
> independence (R6, a preference). On that reading the 11–22 AW rewrite is justified mainly
> by R6, and the recommended sequence front-loads a corpus and a conformance-fixture suite
> for a rewrite it claims to still be deciding.

The red team then **falsified its own attack**, and the falsification is the more useful
finding: the agreement's *scope* is unknown. "We treat everything as an open licence" reads
naturally as permitting redistribution, but if it licenses **use and development
collaboration** rather than **redistribution of RedmineUP's code**, then E stays
unpublishable and the analysis's caution holds. **The dossier treated "licence resolved" as
binary when the operative question is scope — use vs redistribute — and that scope is
exactly the hinge.** See OQ-9.

## Corrections — two factual errors in `01`/`02`, verified and fixed

**E1 — The `redmineup` gem does *not* gate fork-PR CI. I claimed it did, twice.**

`01-context.md` A2 said the gem is "the second reason fork PRs cannot run the full suite",
and `02-analysis.md` Operations said "**R6 is the load-bearing requirement for clean CI**".
Both are **wrong**. Verified: the addon's own `Gemfile` requires only `rspec-rails` and
`rails-controller-testing` — the gem arrives transitively through *reporter's* Gemfile, and
it is **public on RubyGems, GPL-2.0**, so `bundle install` succeeds for any fork with no
credential [CITE: redmine_reporter_dashboards/Gemfile; reference/redmineup-gem-drop-surface.md].
The **only** secret gate in CI is `secrets.REPORTER_REPO_TOKEN`, used to
`actions/checkout` the **private reporter repo**
[CITE: redmine_reporter_dashboards/.github/workflows/ci.yml:210,275].

So the gem blocks **Liquid 5** — a feature choice — and not **CI access**. R6 remains a
sound decision (the curator decided it, and the Liquid pin is real), but its *justification*
must drop the CI argument. Corrected in `01` A2 and `02`.

**E2 — "Port AGG-CORE verbatim" overstates what is portable.**

`model.json` defines `AGG-CORE` as `query_aggregator.rb` + `drill_through.rb` +
`liquid_aggregate_tag.rb`, and marks the bundle "TO BE PORTED VERBATIM". But
`liquid_aggregate_tag.rb:106` does `include SqlAggregation::ScopeResolution` and `:135`
calls `resolve_scope(context)` — and `ScopeResolution` is the module the same spine marks
**"TO BE DELETED"** [CITE: verified in the live clone].

**E2 itself undercounted, corrected 2026-08-04 during the technical design:** `liquid_version_rollup_tag.rb:38`
**also** includes `ScopeResolution`. **There are two coupled tags, not one**, and both must be
re-seamed. The wider design pass found **18 coupling sites** where the analysis listed 6 — most
importantly `up_acts_as_list` at `reporter_project_tab.rb:7`, which is defined only in the vendor
gem, so relaxing the hard dependency alone leaves the plugin booting and then 500-ing on its own
core model [CITE: verified — `redmineup-1.1.12/lib/redmineup/acts_as_list/list.rb:33`, absent from
both plugins]. The kernel *is* genuinely portable
(`QueryAggregator.aggregate(scope, …)` takes an AR scope, not a drop, at
`liquid_aggregate_tag.rb:195`), but the tag is soldered to the layer being removed.

**The honest unit is: port the kernel (`query_aggregator.rb` + `drill_through.rb`) verbatim;
re-seam the tag against the new drop layer.** C-003's own `evidence_against` said this; the
spine and the option costings did not reflect it. Corrected.

## Falsified / shaky assumptions

| Assumption (from `01`) | Challenge | Status |
|---|---|---|
| **A2** — dropping the gem is needed for clean CI | The gem is public GPL-2.0; only the private *reporter repo* gates CI (E1) | **refuted in part** — R6 holds as a decision and for Liquid 5; the CI justification is gone |
| **A1** — "licence resolved" | Resolved *binary*, but the operative question is **scope**: use vs redistribute. Everything downstream (Option A reopened, E's cons, R-07 at 3) assumes redistribution rights that were never stated | **shaky — new hinge, OQ-9** |
| **A5** — production templates don't use gem drop accessors | Still pure inference from absence. And it is worse than it looks: **A5, C-002 and C-007 all discriminate on the same four unrun SQL queries** — the register looks like three independent falsifiers but is one unrun measurement wearing three hats | **unfalsified in practice** |
| **A4** — the aggregator can be carried over without drift | Survives, but the risk work is being done by the **golden corpus**, not by the verbatim port. A golden-guided *rewrite* is equally protected — which means "port" also forecloses the one fix a port cannot make (the MariaDB `ONLY_FULL_GROUP_BY` architectural defect) | **holds, but over-claimed** |
| **A11** — R7 unfalsifiable | Holds, unchallenged | **holds** |
| **A12** — modern engine increases attack surface | Holds, unchallenged | **holds** |
| Cost spine (~22 AW midpoint) | Stale: the justification for choosing the pessimistic number over the velocity-derived 10–12 weeks was *"the expensive part is discovering the behaviour you must match"* — which **is** the clean-room fidelity tax the revision removed. The `[GAP]` is flagged in `02` but `03`'s options table and C-009's arithmetic still consume the un-revised 22 | **shaky — must be re-costed** |
| **R5** — Liquid is the right template language | **Never interrogated anywhere in the dossier.** INV-9 (template authorship = code execution), the missing resource limits, `.html_safe` output, the gem's `call_method(input, method_name)` filter and template-supplied `regex_replace` are **all downstream of choosing a server-side-executed, drop-accessing template language.** The most severe security finding is R5's direct consequence, and the trade is never weighed | **unexamined — real gap** |
| **R1** — "one plugin" is desirable | Treated as a hard requirement whose premise is never questioned. The dossier's own "hard contradiction" (R3 vs R1+R4+R6 ⇒ a template-compatibility break by construction) is *caused* by insisting on one-plugin-with-own-drops. Two cleanly separated open plugins with a public contract solve distribution and bus factor equally and dissolve the contradiction. "Option C fails R1" is scored as a defect without ever asking what R1 is worth | **unexamined — real gap** |

## What survived the attack

Stated because a red team that finds everything wrong is as useless as one that finds
nothing.

- **C-006 (the XSS reclassification) survived an independent attempt to break it**, and is
  now the best-defended claim in the register. The red team upgraded the reasoning from
  empirical to **structural**: each version contributes exactly two idiom-supplied quotes,
  a trailing backslash flips delimiter parity to odd so the unit cannot terminate, and
  restoring even parity requires a second backslash that then lands in *code* position as
  an illegal token. There is no route back into balanced string context without emitting a
  quote, and quotes cannot be emitted. That generalises the bounded 0/2940 result.
- **It also closed one of the verification's own `[GAP]`s in C-006's favour:** `ch_urls` is
  interpolated with no filter, but its value is `Setting.protocol://Setting.host_name` plus
  an integer `version.id` [CITE: version_drop.rb:63-64,98-99] — **no low-privilege free text
  reaches it**. Not a project-member vector.
- **C-003's core insight holds**: five one-line visibility fixes that "read like style" are
  exactly what a clean-room rewrite drops silently, and a wrong number is worse than a crash.
- **The R8/R9 tension and render-path containment** were unchallenged and remain the
  dominant technical risks.

**C-006's residual conditions, unchanged and real:** production templates (A5) are
unreviewed and the parity defence is *idiom-specific, not enforced* — a version
**description** (free text, exposed by the drop, used by no example) interpolated into a
single-quoted JS string or an HTML attribute would not be protected; a future "obvious
improvement" restores the re-sync primitive; and **wkhtmltopdf's 2011 JavaScriptCore was
never tested** — which matters more than it sounds, because `02` recommends keeping
wkhtmltopdf as a *compatibility engine*, making the untested parser a shipped path rather
than a legacy one.

## "Why this fails" scenario

The author takes the analysis's lean — Option B, subset, sequenced via C, structured as D.

- **Months 1–3.** Ships the standalone dashboards + aggregation release. It installs without
  a purchase and works. This feels like validation.
- **Months 3–6.** Builds the own-drop layer (~1 240 lines — bounded, fine) and the engine
  seam. **Here the greenfield bites:** not one of the 1 161 existing tests produces or
  inspects a PDF, there is no performance target, and the engine is undecided. Gotenberg is
  chosen, then hits the reverse-network-path failure — the container is healthy but cannot
  reach `Setting.host_name`, so **every PDF silently loses its assets** — discovered only in
  staging. Pivots to ferrum, planting a self-updating Chrome in every Puma worker.
- **Month 7.** The golden corpus was to be frozen "before anything is touched" — but the
  month-1–3 standalone release **already re-seamed the aggregator** to decouple from
  reporter; that was the entire point of shipping standalone. If the freeze lagged the
  re-seam, the oracle drifted, and differential old-vs-new now compares against an already
  modified baseline. **R-04's mitigation failed at the sequencing seam**, silently.
- **Month 9.** Someone finally runs `SELECT type, count(*) FROM report_templates`. GEOxyz
  production uses `TimeEntriesReportTemplate` and per-issue drop accessors — the Tier-3
  "dead weight" that was only ever *inference from absence of evidence*. The shipped subset
  does not render them. **Two systems now run in production.** R-02's mitigation ("the new
  plugin must be useful alone from release 1") is satisfied and **irrelevant**: it
  guarantees the *new* plugin is coherent, not that the *old* one can be retired. The
  incumbent works, the forcing function never arrives, the day job reclaims attention, and
  the rewrite stalls at ~70%.

**The mechanism, and why it indicts the analysis specifically:** R-02 was correctly named
the top risk, but the reframing (C-001) pointed effort at **distribution** — which turned
out to be solved by an e-mail and a public gem. The actual kill came from the **greenfield
render path** plus **one unrun SQL query**. The failure lived exactly where the analysis
said it had the least evidence and the most work.

## Risks (additions and revisions to `02`'s register)

All scores `[UNVERIFIED]` reviewer judgement — **advisory — non-deterministic — not a
correctness guarantee.**

| Risk | L | I | Score | Mitigation |
|---|---|---|---|---|
| **R-13 — The agreement's scope is assumed, not established.** Every post-2026-08-04 simplification (A reopened, R-07 → 3, clean-room removed) assumes **redistribution** rights. If it is use-only, Option A becomes unpublishable again and E stays condemned — i.e. the option set inverts | 3 | 4 | **12** | One question to RedmineUP: does this cover redistributing your code in a plugin we publish? Registered as **C-010** with this as its discriminator |
| **R-14 — Option E was never re-examined on the new fact.** Its stated cons ("no OSS release", "no outside contributors", "needs the gem") are now false or weak. The dossier may be recommending an 11–22 AW path over a 3–6 AW one on stale grounds | 3 | 5 | **15** | Re-score E symmetrically with A before `/decide`. **Mandatory before an ADR** |
| **R-15 — The register's falsifiers collapse to one unrun measurement.** A5, C-002 and C-007 all discriminate on the same four SQL queries. If they are never run, three "live" claims are permanently unfalsifiable and the subset recommendation rests on inference | 4 | 4 | **16** | **Run them.** `SELECT type, count(*) FROM report_templates GROUP BY type`; active `report_schedules` count; `content LIKE` sweep per drop accessor; log grep for `/issue_mails` and `?token=`. The single highest-value action in the dossier and it is not analysis |
| **R-16 — R5 (Liquid) unexamined while its consequences are the worst security findings.** A data-only report spec with server-side rendering, or an evaluator with hard limits by construction, could eliminate the code-execution-privilege class entirely | 3 | 4 | 12 | Interrogate R5 explicitly in the technical spec; if Liquid stays, INV-9 must be a documented privilege boundary, not an implicit one |
| **R-17 — R1 ("one plugin") manufactures the dossier's own contradiction.** Two separated open plugins with a public contract solve distribution and bus factor equally and dissolve the R3-vs-R1+R4+R6 break | 3 | 3 | 9 | Ask what R1 buys. If it is packaging aesthetics, it should not outrank a structural contradiction |
| **R-04 revised** — silent numerical regression | 3 | 5 | 15 | Unchanged in score, but note the corpus must be frozen **before** any re-seaming, not merely "before the rewrite" — the strangler's first release already moves the seam |
| **R-07 revised** — licensing | 1 | 3 | 3 | Holds at 3 **only if** R-13 resolves toward redistribution |

## Discriminator quality audit

`conventions.md` §7 says the presence gate cannot judge quality, and that judging it is the
red team's job. Verdicts:

| Claim | Discriminator | Verdict |
|---|---|---|
| C-001 | the answer to OQ-2 | Good — but **status has drifted**. Its own `bias_watch` ("preferred because it is a better story") is now *vindicated*: the revision eroded both stated remaining components, one of them factually (E1), yet confidence stayed `likely`. **Downgraded to `revised`** |
| C-002 / C-007 | the SQL queries | Good individually, but see R-15 — a shared single point of failure |
| C-003 | port behind the goldens | Good; the **AGG-CORE definition** was the problem, not the discriminator (E2) |
| C-004 | a 2-week spike | Good, honestly `hypothesis` — but the 22-AW input it argues against is stale |
| C-005 | conformance fixtures across a network boundary | Adequate; `evidence_against` is thin (one entry) for a `likely` claim |
| C-006 | find an executing payload | **Excellent.** Attacked independently and survived |
| C-008 | `parked`, with the runnable test preserved | Correct |
| **C-009** | "cost the drop layer and render path independently" | **Partially vacuous — the one real failure.** It tests only the *cost* framing, and can return "yes, they dominate" while the claim's actual weakness stands untouched: A and B are **not commensurable on cost** because they carry different risk classes (A = known defects, B = silent regressions at score 15–20). Reducing that to an AW delta is a category error — precisely the move a non-committal synthesis makes to avoid picking. **Discriminator rewritten to include a risk-class falsifier** |
| C-010 | a written instrument naming redistribution | Good, and now the hinge (R-13) |

## Open questions (must resolve before building)

1. **OQ-9 (new, and it outranks the rest) — does the RedmineUP agreement permit
   *redistribution* of their code in a plugin we publish, or only use and collaboration?**
   This, not "licensing is resolved", selects between Option E-published (~3–6 AW) and a
   rewrite (~11–22 AW). The dossier conflated the two.
2. **OQ-10 (new) — is Liquid 5 actually needed?** R6, the independence argument and much of
   the B-vs-E gap lean on it, and **nothing in the dossier names a required Liquid-5
   feature** (C-008's own `evidence_against` says so). If nothing needs it, the gem
   argument is purely about ownership.
3. **OQ-2 (unchanged, still the audience gate)** — internal / public / co-distributed.
4. **Run the four production SQL queries** (R-15). Not a question — a measurement, and the
   cheapest way to convert three inferred claims into evidence.
5. **Re-cost the work packages** without the clean-room burden, and propagate into `03`'s
   table and C-009 (the `[GAP]` in `02` names this; the numbers still need to move).
6. **Re-examine Option E symmetrically with Option A** (R-14) before `/decide`.
7. **OQ-3 / OQ-4 (unchanged)** — external container acceptable? renderer asset
   authentication? Both still design blockers; the conformance fixtures answer OQ-3.
8. **OQ-11 (new) — what does R1 buy?** If "one plugin" is packaging preference, it should
   not outrank the structural contradiction it creates.
9. **OQ-12 (new) — interrogate R5.** If Liquid stays, INV-9 becomes a documented privilege
   boundary (or admin-gated); if it does not, the code-execution class disappears.
10. **OQ-5 / OQ-6 / OQ-7 / OQ-8 (unchanged)** — aggregator port scope (now sharpened by E2
    to *kernel* vs *tag*), Redmine 5.1 and the Ruby floor, migration vs clean break,
    performance baseline.

## What this pass did *not* do

- It did not resolve OQ-2, and could not.
- It did not re-cost anything. The cost spine is flagged stale; moving the numbers is
  curator work, and inventing new ones here would be worse than leaving them marked.
- It did not test wkhtmltopdf's JavaScriptCore against the C-006 payload set. That remains
  the one untested parser, and `02` recommends shipping it as a compatibility engine.
- It did not review GEOxyz's production templates. Three claims still wait on that.
