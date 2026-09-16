# Verification — the template JS-escaping finding, tested rather than reasoned

> The security review ranked "data-driven XSS through the documented escaping idiom"
> as its **highest** finding (T2 — reachable by anyone who can name a version or set a
> custom field value), and explicitly flagged it as *derived, not demonstrated*:
> *"It is a one-hour test and it should be run before the analysis is finalised."*
>
> It was run. **The injection is real; the XSS conclusion is not.** This file records
> the test so the severity in `02`/`04` is grounded in an experiment rather than in a
> parse the reviewer and I both did in our heads.

Executed 2026-08-04 with `liquid` **5.13.0** (Ruby) and Node **v22** for JS parsing.
Scratch scripts: `xss_test.rb`, `probe2.rb`, `brute.rb` (session scratchpad, not
committed — the results below are the artefact).

## Step 1 — does `| escape` pass a backslash through? **Yes.**

| Input | `{{ v \| escape }}` |
|---|---|
| `a\` | `a\` — **unchanged** |
| `'` | `&#39;` |
| `"` | `&quot;` |
| `<` | `&lt;` |
| `>` | `&gt;` |
| `&` | `&amp;` |

Liquid's `escape` is HTML-escaping (`CGI.escapeHTML`); **backslash is not in its
character set.** Confirmed.

## Step 2 — do both shipped idioms leak the backslash? **Yes, both.**

The README idiom, `var labels = ["{{ a | escape }}","{{ b | escape }}"];` with
`a = 'x\'`, `b = '-alert(1)//'`, renders:

```js
var labels = ["x\","-alert(1)//"];
```

The example-template idiom (`reference/example-template-version-status.liquid:312`),
whose filter chain is `replace: "'" | replace: '"' | replace: '<' | replace: '>'`,
with the same values renders:

```js
var labels = ['a\','-alert(1)//',];
```

**Neither filter chain strips `\`.** The reviewer's premise is correct and this is a
genuine input-handling defect: a value that an ordinary project member controls
(a version name, a custom-field value) changes the *token structure* of the emitted
JavaScript.

## Step 3 — does it execute? **No. It is a SyntaxError.**

Searched **2 940** candidate payloads (2- and 3-value combinations over 14 crafted
fragments: backslash terminators, `-alert(1)-`, `-alert(1)//`, `,alert(1),`,
`+alert(1)+`, `]-alert(1)-[`, `;alert(1);`, template-literal and `${}` variants,
double backslash, benign filler). Each rendered through the real Liquid idiom, then
parsed and run in Node with `alert` instrumented, in the multi-line context the real
template produces (the array line followed by `var urls = [...]` and further
statements, as at template lines 431–435).

```
EXECUTING payloads found: 0
```

**Why it cannot execute, and this is the load-bearing reason:** breaking out of the
string with `\` succeeds, and an expression *can* be placed in code position — but
**re-synchronising the parse requires emitting a quote**, and both idioms make that
impossible. The replace chain *deletes* `'` and `"`; `escape` converts them to
`&#39;`/`&quot;`, which inside a `<script>` element are inert literal text, not
delimiters (entities are not decoded in script content). The array literal is
therefore left unterminated and the **whole `<script>` block fails to parse**.

Neither idiom permits `</script>` either: `<` and `>` are stripped by the one and
entity-encoded by the other.

## Corrected finding

| | Security review's claim | Verified |
|---|---|---|
| Backslash unfiltered in both idioms | yes | **yes — confirmed** |
| Attacker-controlled input alters JS token structure | yes | **yes — confirmed** |
| Result is executable JavaScript / stored XSS | **High, T2** | **No.** 0/2940 payloads executed |
| Actual impact | — | **Denial of rendering.** The chart's entire `<script>` block dies with a `SyntaxError`; the canvas stays blank and every later statement in that block is lost |

**Reclassified: Medium — availability/correctness, not XSS.** Reachable by the same
low-privilege actor (T2), and worth fixing for the same reason, but it does not steal
an admin session. It fails *closed*, by accident rather than by design.

## Why this still matters, and matters more than "Medium" suggests

1. **The chart vanishes silently.** This is exactly the failure mode the operations
   review ranked worst: no exception, no log line, no visible error — a blank widget
   or a chart-less PDF that looks like "no data". One badly-named version corrupts a
   report and nothing says why.
2. **It is a blast-radius bug, not a one-widget bug.** The dead `<script>` block also
   carries `var urls`, the `geoChartBegin()`/`geoChartEnd()` handshake calls and the
   `new Chart(...)` construction. Losing the block loses drill-through for that widget
   too — and if `geoChartEnd()` never runs, the pending-chart counter never returns to
   zero.
3. **The defence is accidental.** Nothing in either idiom was designed to stop this;
   quote-stripping happens to remove the attacker's re-sync primitive. A future
   template author who writes the "obvious" improvement — `| escape` on a value inside
   a **single**-quoted JS string, or a `| json`-less interpolation into an object
   literal — may well restore executability. **Treat this as one payload-shape away
   from XSS, not as safe.**
4. **It is in the copy-paste surface.** The idiom appears in the README's own snippet
   and in the shipped example templates, so it propagates into every template an
   author writes.

## Consequence for the rewrite

The security review's recommended fix is right and this experiment does not weaken it
— it only re-ranks the severity:

- Ship a real **`| json`** (and `| js`) filter in the own-drops layer (R6). The
  `redmineup` gem already has a `jsonify` filter
  [CITE: reference/redmineup-gem-drop-surface.md], so the *capability* exists today
  and the plugin simply does not expose or use it. That is a one-line-per-template fix
  waiting to be made available.
- Use it in **every** example and every README snippet — the examples are the spec.
- Lint: reject `{{ ... }}` inside `<script>` that is not passed through `json`/`js`.
- Prefer emitting chart data as **one JSON payload** (a `<script type="application/json">`
  block or a `data-` attribute parsed with `JSON.parse`) rather than string-concatenated
  JS array literals. That removes the entire class, including the shapes this test did
  not find.

## Honest limits of this test

- **A negative search is not a proof.** 2 940 payloads over 14 fragments is a bounded
  search of a large space; it establishes that the *obvious* shapes fail, not that no
  shape exists. A payload using a construct I did not enumerate could still work.
- Tested against **Node/V8** parsing. Chromium is V8, so a modern PDF engine matches;
  **wkhtmltopdf's 2011 JavaScriptCore was not tested** and its error recovery may
  differ.
- Tested the **two idioms in this repository**. GEOxyz's production templates are not
  in either repo and may interpolate differently — the LL-01 template supplied in the
  request, for instance, *does* strip backslashes (`replace: '\', ""`), so it is not
  affected at all. `[GAP]` production templates unreviewed.
- The `ch_urls` array is interpolated with **no filter whatsoever**
  [CITE: example-template-version-status.liquid:432]; its value comes from
  Redmine-generated version URLs rather than from free text, so it was not part of
  this test. `[GAP]` not verified as unreachable.
