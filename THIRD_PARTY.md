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
