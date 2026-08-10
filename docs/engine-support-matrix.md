<!-- GENERATED FILE — do not edit by hand.

     Written by the render-smoke job from an actual conformance run:

         RRD_CONFORMANCE=1 RRD_MATRIX_WRITE=1 rspec spec/conformance

     Gate G9 fails if the committed file and a fresh run disagree, so editing
     this by hand does not make a claim true — it makes the build red. If a
     cell here is wrong, the fixture or the adapter is what has to change.
-->

# Engine support matrix

This is what each render engine **did**, not what it was hoped to do. Every cell
below comes from `spec/conformance/`, run against the engine named in the column.

Three states, and the difference between the second and the third is the whole
design (gate G12):

| Cell | Means |
|---|---|
| `PASS` | the engine declares the capability the fixture needs, and the fixture passed |
| `SKIP` | the engine **does not declare** the capability — the fixture does not apply, and the reason names it |
| `FAIL` | the engine **declares** the capability and the fixture failed. A declaration is a promise |

## The engines

| Engine | Role | Default | Needs a service | Renders offline | Install cost |
|---|---|---|---|---|---|
| `chromium_cdp` | reference | yes | no | yes | one documented package install (chromium), not provided by bundle install |
| `gotenberg` | documented | no | yes | yes | an operator-run container; the plugin never ships one |
| `wkhtmltopdf` | compatibility | no | no | yes | provided by bundle install; no service, no configuration |

* **`chromium_cdp`** — the reference engine and the default. Modern CSS (flexbox, grid), a current JavaScript engine, tagged PDF and document outlines. Costs one package install that `bundle install` does not perform — G7's "≈3 commands" is honestly "≈3 commands plus one documented package install", and pretending otherwise is how an operator finds out at the wrong moment.
* **`gotenberg`** — the same Chromium, in somebody else's container. Buys a render path that is already isolated at the network level; costs a service to run, monitor and patch, and a default configuration that is unauthenticated.
* **`wkhtmltopdf`** — the migration engine. Every existing install and template keeps rendering, on shared hosting and air-gapped, with zero configuration. The cost is a 2011 WebKit: no flexbox, no grid, a JavaScript engine old enough to need shims, and no tagged PDF. Choose it to migrate, not to build on.

## Declared capabilities

What each engine **claims**. `spec/conformance/conformance_spec.rb` asserts that a
registered adapter's own `#capabilities` equals its row here, so the declaration and
the code cannot drift apart — the file is not documentation of the adapter, it is the
same fact written where an operator can read it (`config/capabilities.yml`).

| Capability | `chromium_cdp` | `gotenberg` | `wkhtmltopdf` |
|---|---|---|---|
| `:javascript` | yes | yes | yes |
| `:modern_javascript` | yes | yes | — |
| `:readiness_expression` | yes | yes | — |
| `:print_backgrounds` | yes | yes | yes |
| `:header` | yes | yes | yes |
| `:footer` | yes | yes | yes |
| `:page_furniture_tokens` | yes | yes | yes |
| `:custom_page_size` | yes | yes | yes |
| `:landscape` | yes | yes | yes |
| `:margins` | yes | yes | yes |
| `:scale` | yes | yes | — |
| `:page_break_css` | yes | yes | yes |
| `:media_print` | yes | yes | yes |
| `:outline` | yes | — | — |
| `:tagged_pdf` | yes | — | — |
| `:pdf_metadata` | yes | yes | yes |
| `:asset_inline` | yes | — | yes |
| `:asset_upload` | — | yes | — |
| `:asset_http` | — | — | — |
| `:timeout` | yes | yes | yes |

## Conformance corpus

| Fixture | What it asserts | `chromium_cdp` | `gotenberg` | `wkhtmltopdf` |
|---|---|---|---|---|
| `F-01-page-geometry` | A4 portrait is 595 x 842 pt | PASS | not verified | PASS |
| `F-02-custom-page-size` | Letter is honoured over the engine default | PASS | not verified | PASS |
| `F-03-orientation-margins` | landscape A4 with 25 mm margins | PASS | not verified | PASS |
| `F-04-page-furniture` | per-page footer with page numbers | PASS | not verified | PASS |
| `F-05-page-breaks` | three explicit breaks make four pages | PASS | not verified | PASS |
| `F-06-background-printing` | backgrounds print by default | PASS | not verified | PASS |
| `F-07-column-layout` | a two-column layout stays side by side | PASS | not verified | PASS |
| `F-08-readiness-none` | a chart-free document is ready immediately | PASS | not verified | PASS |
| `F-09-readiness-charts` | three charts that finish, and the wait is theirs | PASS | not verified | PASS |
| `F-10-readiness-watchdog` | a chart that never ends is cut short by the page, not the engine | PASS | not verified | PASS |
| `F-11-readiness-timeout` | a page that never signals is rendered anyway, and degraded | PASS | not verified | SKIP — wkhtmltopdf does not declare :readiness_expression |
| `F-12-readiness-strict` | strict turns the same timeout into a typed failure | PASS | not verified | SKIP — wkhtmltopdf does not declare :readiness_expression |
| `F-13-readiness-late-signal` | a chart signalling at 6 s is waited for, and only for that | PASS | not verified | PASS |
| `F-14-asset-inline` | a data: URI image resolves without any fetch | PASS | not verified | PASS |
| `F-15-egress-denial` | the engine reaches nothing on the network | PASS | not verified | PASS |
| `F-16-failure-semantics` | an unsupported capability is refused, in type | PASS | not verified | PASS |
| `F-17-resource-envelope` | 2 000 rows render inside a stated envelope | PASS | not verified | PASS |
| `F-18-fonts` | text goes onto the page and comes back off it | PASS | not verified | PASS |
| `F-19-pathological-input` | malformed and oversized input is bounded, either way | PASS | not verified | PASS |
| `F-20-escaping-payloads` | the escaping payload set under this engine's JS parser | PASS | not verified | PASS |

## Columns that are not measurements

INV-7's rule, applied to engines: a configuration nobody ran is unsupported, and
saying so is cheaper than finding out from a user.

* **`gotenberg`** — MEASURED IN CI 2026-08-10 against Gotenberg 8.35.0, at the digest pinned in `docker-compose.gotenberg.yml` — which is the ONE place that digest is written, so that the nightly CVE scan and this note cannot come to disagree. Run 31408759956: 19 pass, 0 fail, 1 skip, the skip being `F-14-asset-inline` against an `:asset_inline` this engine does not declare, which is G12's first arm rather than a gap. Still `pending` rather than `corpus` because promotion is a curator act on a run somebody has read — the same act, on the same kind of evidence, as wkhtmltopdf's on 2026-08-06 — and until it happens the cells below are deliberately not measurements. The security conditions hold as designed: convert/url is a forbidden code path asserted absent from every file that could request it, only `convert/html` with the upload model, and an endpoint reachable without the configured credential is a preflight FAILURE with a named remediation. Two of those checks were rewritten after measuring that they could not fail — Gotenberg exempts `/health` from basic auth, and it silently ignores `waitForExpression` when JavaScript is disabled.
