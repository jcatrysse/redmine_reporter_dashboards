# Third-party code shipped inside this plugin

Everything below is **vendored**: it ships in the repository, is served from the plugin's
own assets, and is **never fetched at render time from anywhere**.

That is not a packaging preference. `technical-spec.md` §6:

> **Bundled, never CDN.** Today Chart.js **2.8.0 (2019)** loads from
> `cdnjs.cloudflare.com` **from inside the template body**, with no SRI. […] **No network
> fetch, ever** — simultaneously the SRI fix, the reproducibility fix, and the
> prerequisite for INV-8's zero-egress posture. *Rejected: CDN with SRI* — SRI does not
> remove the **egress requirement**, and denying egress is the single control that most
> cheaply kills SSRF value. You cannot have both.

`script/gates/vendor_integrity.sh` is what keeps this file true: it recomputes every
digest below and fails on a mismatch, and it fails on any CDN reference in the shipped
assets or examples. Run it before trusting this table.

---

## Mermaid

| | |
|---|---|
| **Version** | 11.16.1 |
| **File** | `assets/javascripts/vendor/mermaid.min.js` |
| **sha256** | `18327bef70d96fb505fe7287d9f6a7362ebf07ff6576ddfaffb1a06f3e1a2954` |
| **Bytes** | 3 566 058 |
| **Licence** | MIT — `assets/javascripts/vendor/mermaid.LICENSE.md` |
| **Upstream** | <https://mermaid.js.org> · <https://github.com/mermaid-js/mermaid> |
| **Obtained from** | `https://registry.npmjs.org/mermaid/-/mermaid-11.16.1.tgz` → `package/dist/mermaid.min.js` |
| **Verified against** | `https://cdn.jsdelivr.net/npm/mermaid@11.16.1/dist/mermaid.min.js` **and** `https://unpkg.com/mermaid@11.16.1/dist/mermaid.min.js` — all three byte-identical |

**Three origins rather than two**, for one reason: this file is 3.5 MB, seventeen times the
size of Chart.js, and it is the largest single artefact in the repository. The npm tarball,
jsdelivr and unpkg are independently operated and all three agree on the digest above.

**It is big, and that is a real cost stated rather than buried.** §6 requires bundling
("no network fetch, ever"), and Mermaid 11 has no smaller distribution that keeps the
no-build-step rule: the modular build needs a loader and several files, which is exactly the
pipeline §6 avoids. So a report with a diagram carries 3.5 MB of library. Two consequences
worth knowing: it is 6.8× `Assets::Policy::DEFAULT_INLINE_MAX_BYTES`, so on the owned render
path it inlines with `Degradation(:asset_inline_oversize)` recorded on an engine with no
upload model; and it is `<script src>`-referenced rather than inlined by the tag, so a
document with no diagram pays nothing.

**`mermaid.min.js` is an esbuild IIFE and requires post-ES5 JavaScript.** It opens with
`(__esbuild_esm_mermaid_nm||={})` and closes by assigning `globalThis["mermaid"]`. That is
why `:modern_javascript` exists as a capability and why wkhtmltopdf declares `:javascript`
without it — measured, with the discriminator, in `technical-spec.md` §6.1.

---

## Chart.js

| | |
|---|---|
| **Version** | 4.5.0 |
| **File** | `assets/javascripts/vendor/chart.umd.js` |
| **sha256** | `b7929ad4d5323b8244f85d79bba0b3d1495e66f79a2f0023be7f4de5ba4fbac8` |
| **Bytes** | 208 337 |
| **Licence** | MIT — `assets/javascripts/vendor/chart.js.LICENSE.md` |
| **Upstream** | <https://www.chartjs.org> · <https://github.com/chartjs/Chart.js> |
| **Obtained from** | `https://cdn.jsdelivr.net/npm/chart.js@4.5.0/dist/chart.umd.js` |
| **Verified against** | `https://unpkg.com/chart.js@4.5.0/dist/chart.umd.js` — byte-identical |

**Two origins, on purpose.** A digest recorded from the same place the file came from
proves the download did not corrupt; it does not prove the file is the one upstream
published. Fetching the same version from a second, independently operated mirror and
comparing bytes is the cheapest available check that both are serving the same artefact.
It is not a signature — Chart.js does not publish one — and this row says what it is
rather than implying more.

**Why 4.x and not the 2.8.0 already in the templates.** `technical-spec.md` §6 lists the
2→4 migration as a work package with six named items, all of which this plugin now
performs on the author's behalf in `ChartjsEmitter`: `scales.xAxes[]`→`scales.x`,
`options.legend`→`options.plugins.legend`, `type:'horizontalBar'`→`type:'bar'` +
`indexAxis:'y'`, `getElementAtEvent`→`getElementsAtEventForMode`,
`ticks.fontSize`→`ticks.font.size`, and `ticks.max`/`beginAtZero`→the scale object.

**The UMD build, not the ESM one.** It is self-contained — `@kurkle/color` is bundled
into it — so there is one file, one digest and no module resolution. A PDF engine reads
this file off disk and inlines it; an import map would be a second thing to get right in
an environment with no network.

**What is NOT vendored, and why that is not an omission.** Chart.js 4 needs no date
adapter unless a chart uses a time scale, and none of the six families this plugin draws
does — every axis is linear or categorical, both computed server-side by `ChartLayout`.
Adding `chartjs-adapter-date-fns` would ship a second library and its transitive `date-fns`
for a capability nothing uses.

---

## Fonts

None. Charts and documents use the platform font stack
(`Helvetica, Arial, sans-serif`). `technical-spec.md` §9b anticipates vendored fonts under
the same rule as this table; when one ships, it gets a row here with a digest before it
gets a `@font-face`.

## Mermaid

Not shipped. §6.1 specifies it and **T-35** builds it. When it arrives it gets a row here
with its version, digest and licence — the same rule, stated now so the absence is a
decision rather than an oversight.
