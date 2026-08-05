# The engine conformance corpus (T-12)

**What any engine has to do to be one of ours, written executably.**

An interface with one implementation is a class with extra steps. This directory is
what makes `lib/redmine_reporter_dashboards/render/` an abstraction rather than a
wrapper around whichever browser happened to be installed when it was written.

It was built **before** the adapters, on purpose. An engine conformance-tested against
a contract written afterwards is tested against itself.

---

## Running it

```bash
gem install rspec
sudo apt-get install -y poppler-utils          # pdfinfo, pdftotext, pdftoppm

# the harness's own tests — no browser, no database, always runnable
rspec spec/conformance/conformance_harness_spec.rb

# the corpus, against every registered adapter
RRD_CONFORMANCE=1 rspec spec/conformance

# one engine only
RRD_CONFORMANCE=1 RRD_ENGINE=chromium_cdp rspec spec/conformance

# regenerate the support matrix (gate G9 compares the committed file with a fresh run)
RRD_CONFORMANCE=1 RRD_MATRIX_WRITE=1 rspec spec/conformance
```

**The browser must not run as root.** The Chromium adapter deliberately does not set
`--no-sandbox`, and Chromium refuses to run as root without it. On a container where
you are root, run the suite as somebody else:

```bash
useradd -m rrd && su rrd -c 'RRD_CONFORMANCE=1 rspec spec/conformance'
```

That is not a workaround for the test; it is the supported deployment posture, and the
suite failing as root is the posture telling you so.

---

## The three-state rule (gate G12)

Every fixture declares the capabilities an engine must have **claimed** for the fixture
to apply. That declaration, not the fixture's subject, is what decides the cell:

| The engine… | …and the fixture | Cell | Why |
|---|---|---|---|
| does **not** declare it | not run | `SKIP`, reason names the capability | the engine never promised this |
| declares it, fixture passes | ran | `PASS` | |
| **declares it**, fixture fails | ran | `FAIL` — hard | a declaration is a promise |

The two-state version of this is what makes support matrices lie. An engine that cannot
draw a footer and never said so gets a red cell it did not earn; an engine that said it
could and cannot gets a green one it did not earn either. Asking the engine first and
then holding it to its own answer fixes both.

---

## Why the document computes its own answer

Several fixtures need to know what **the engine's own JavaScript parser** did with an
input. The harness cannot ask an arbitrary engine to evaluate an expression — only some
declare `:readiness_expression` — so instead the document writes its findings into the
DOM, and the harness reads them back out of the rendered PDF's text.

One mechanism, every engine, and it exercises the path that actually ships rather than
a control channel nothing uses in production.

---

## What the harness is allowed to know about a PDF

Three external tools, and no hand-rolled parser:

| Tool | Answers |
|---|---|
| `pdfinfo` | page count, page geometry in points |
| `pdftotext` | the text a reader can select — which is also the accessibility surface |
| `pdftoppm` | pixels, as a raw P6 bitmap |

A reader for object streams, Flate, subset fonts and `ToUnicode` CMaps would be several
hundred lines of untested code whose bugs look exactly like engine defects. A wrong
answer from *our* reader must never be confusable with a wrong answer from the engine.

**A missing tool is an error, never a skip.** `PdfProbe.require_tools!` raises and names
the package. This repository keeps rediscovering the same failure mode — a check that
did not run looks exactly like a check that passed — and a matrix generated without the
probes would still print `PASS`.

**The pixel checks are not perceptual diffs.** They read one pixel of a flat fill and
compare it to an exact RGB triple with a ±8 tolerance for rasteriser rounding. A flat
fill has a right answer; that is what separates this from the visual-diff work
`CLAUDE.md` §7 keeps advisory.

---

## The fixtures

Each `F-nn-*/` holds `fixture.rb` (declaration and checks) and `document.html` (what
gets rendered). Two placeholders are substituted before rendering:

* `@@CHART_SHELL@@` — the **shipped** `assets/javascripts/chart_shell.js`, inlined. A
  fixture exercising a copy would pass while the file everyone loads was broken.
* `@@EGRESS_URL@@` — a URL on a socket the harness itself is listening on.

| Fixture | The failure it exists to catch |
|---|---|
| `F-01`, `F-02` | an engine that draws Letter when asked for A4 — the classic "right on my machine" report |
| `F-03` | margins applied in the wrong unit, or `landscape` ignored. The 17.8 mm sample is the falsifier: inside a 25 mm margin, outside the 12 mm default |
| `F-04` | engine-native footer markup soldering a template to one engine |
| `F-05` | `page-break-before` honoured and `break-before` not, or the reverse |
| `F-06` | Chromium's `printBackground: false` default, which silently costs every badge colour |
| `F-07` | a 2011 WebKit stacking a flex row instead of laying it out |
| `F-08`–`F-13` | the readiness protocol, end to end. See below |
| `F-14` | a `data:` URI accepted and not decoded — same document size, no error, wrong report |
| `F-15` | the engine holding the network. Asserted from **outside**: zero connections to our socket |
| `F-16` | a refusal that is not typed — INV-5's "error as document" in its quietest form |
| `F-17` | an engine that truncates a long table, which makes it look *faster* |
| `F-18` | text that is on the page and cannot be selected, searched or read aloud |
| `F-19` | a runaway template that hangs the renderer at 3 a.m. under the scheduler |
| `F-20` | the escaping payload set, under **this engine's** JS parser rather than under Node's |

### The readiness six

`F-08`…`F-13` are T-11's contract, measured. They replace a flat
`javascript_delay: 3000` with the engine's runaway-script guard switched off — a guess
that is wrong in both directions at once.

| Fixture | Page | Expected |
|---|---|---|
| `F-08` | no charts | ready at once, under 2.5 s |
| `F-09` | three charts, 600 ms each | 0.55–2.9 s. A fixed 3-second delay fails the upper bound |
| `F-10` | one chart that never ends | the **page's** watchdog answers at ~2 s, carrying `client_watchdog` |
| `F-11` | no readiness component at all | the **engine's** timeout answers, still renders, `Degradation(:readiness_timeout)` |
| `F-12` | the same page, `strict` | `Failure(:readiness_timeout)` and no bytes anywhere |
| `F-13` | one chart signalling at 6 s | **the falsifier.** 5.9–12 s, 3 attempts, with a marker written just before `end()` |

`F-13`'s timeout is 20 s and not the default 10 s, and that is deliberate: at 10 s an
implementation that simply waited out the timeout would also land inside a 12 s bound
and the fixture would stop discriminating. Three attempts with generous bounds rather
than one with tight ones — a tight wall-clock bound gets loosened after its first flake
and then proves nothing.

---

## Negative-tested

`conformance_harness_spec.rb` drives the harness with engines built to break it: one
that declines capabilities, one that **declares a capability and does not deliver it**,
one that returns bytes which are not a PDF, one that raises. Each must produce the cell
it deserves.

That file exists because of `layer_purity.sh`, which shipped a version reporting every
layer clean while checking nothing — caught only because somebody planted the violation
before trusting the gate. A check nobody has watched fail is not yet a check.
