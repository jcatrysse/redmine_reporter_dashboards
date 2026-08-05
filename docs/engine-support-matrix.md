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
| `F-01-page-geometry` | A4 portrait is 595 x 842 pt | no adapter | no adapter | no adapter |
| `F-02-custom-page-size` | Letter is honoured over the engine default | no adapter | no adapter | no adapter |
| `F-03-orientation-margins` | landscape A4 with 25 mm margins | no adapter | no adapter | no adapter |
| `F-04-page-furniture` | per-page footer with page numbers | no adapter | no adapter | no adapter |
| `F-05-page-breaks` | three explicit breaks make four pages | no adapter | no adapter | no adapter |
| `F-06-background-printing` | backgrounds print by default | no adapter | no adapter | no adapter |
| `F-07-flexbox` | a flex row lays out side by side | no adapter | no adapter | no adapter |
| `F-08-readiness-none` | a chart-free document is ready immediately | no adapter | no adapter | no adapter |
| `F-09-readiness-charts` | three charts that finish, and the wait is theirs | no adapter | no adapter | no adapter |
| `F-10-readiness-watchdog` | a chart that never ends is cut short by the page, not the engine | no adapter | no adapter | no adapter |
| `F-11-readiness-timeout` | a page that never signals is rendered anyway, and degraded | no adapter | no adapter | no adapter |
| `F-12-readiness-strict` | strict turns the same timeout into a typed failure | no adapter | no adapter | no adapter |
| `F-13-readiness-late-signal` | a chart signalling at 6 s is waited for, and only for that | no adapter | no adapter | no adapter |
| `F-14-asset-inline` | a data: URI image resolves without any fetch | no adapter | no adapter | no adapter |
| `F-15-egress-denial` | the engine reaches nothing on the network | no adapter | no adapter | no adapter |
| `F-16-failure-semantics` | an unsupported capability is refused, in type | no adapter | no adapter | no adapter |
| `F-17-resource-envelope` | 2 000 rows render inside a stated envelope | no adapter | no adapter | no adapter |
| `F-18-fonts` | text goes onto the page and comes back off it | no adapter | no adapter | no adapter |
| `F-19-pathological-input` | malformed and oversized input is bounded, either way | no adapter | no adapter | no adapter |
| `F-20-escaping-payloads` | the escaping payload set under this engine's JS parser | no adapter | no adapter | no adapter |

## Columns that are not measurements

INV-7's rule, applied to engines: a configuration nobody ran is unsupported, and
saying so is cheaper than finding out from a user.

* **`chromium_cdp`** — the corpus and the contract exist (T-12); the adapter does not yet (T-13). This column carries no measurements and says so rather than being left out — an absent column reads as "nothing to report" and means "nobody checked".
* **`gotenberg`** — no adapter in the tree yet (T-34). Declared here because the capability shape and the security conditions were decided with it in view — `/forms/chromium/convert/url` is a forbidden code path (SSRF), only `convert/html` with the upload model, and a Gotenberg reachable without its configured credential is a preflight FAILURE with a named remediation rather than a warning.
* **`wkhtmltopdf`** — as above — the adapter arrives with T-13. wkhtmltopdf is additionally the engine this container cannot install, so its cells will come from CI rather than from a developer machine, which is the normal case for this project and not a weakness of the result.
