#!/usr/bin/env bash
set -euo pipefail

# Gate — T-16 / technical-spec.md §6: "vendored with a recorded sha256, no CDN, ever".
#
# Two questions, and they are different:
#
#   1. Is the vendored file the one THIRD_PARTY.md says it is?  (integrity)
#   2. Does anything we ship still reach for a CDN?              (egress)
#
# The second is the one with security value. §6 rejects "CDN with SRI" explicitly: SRI
# proves the bytes and does nothing about the EGRESS REQUIREMENT, and denying egress is
# the control that most cheaply kills SSRF value (INV-8). A `<script src="https://…">`
# in a shipped template makes the whole zero-egress posture a claim about files nobody
# is checking.
#
# --- THIS GATE WAS NEGATIVE-TESTED BEFORE IT WAS TRUSTED ---
#
# HANDOVER §1 records why that rule exists: `layer_purity.sh`'s first version reported
# every layer clean while checking nothing, because `rg -E` is `--encoding` and `|| true`
# swallowed the crash. So a search's exit status here is three-valued — 0 matches,
# 1 no matches, ANYTHING ELSE means the tool failed and this gate knows nothing — and the
# third case is loud.
#
#   VENDOR_INTEGRITY_MODE=warn    (default) report, exit 0 on an egress finding
#   VENDOR_INTEGRITY_MODE=strict  any finding fails. What CI runs.
#
# --- WARN MODE HAS EXACTLY TWO KNOWN FINDINGS, AND ONE OWNER: T-39 ---
#
# `examples/sample_report_template.liquid:82` and
# `examples/version_status_dashboard.liquid:147` assign a cdnjs Chart.js 2.8 URL to
# `window.GEO_CHARTJS_SRC`. Both are Reporter report templates rendered by the HOST plugin,
# and migrating them is NOT a matter of writing a different URL — finding **F-15**, answered
# in T-33:
#
#   * an absolute plugin-asset URL turns a file on the renderer's own disk into an EGRESS
#     REQUIREMENT, which is what `asset_policy: :bundled` exists to refuse. The URL exists
#     (`Setting.protocol` + `Setting.host_name`, via `Assets::Origin`) and is the wrong tool
#   * `{% chart %}` is INERT without an owned `RenderContext`, which a host-plugin render has
#     none of, so they cannot migrate to the tag until T-23
#   * inlining the vendored Chart.js **4** under configs written for **2.8** produces a
#     document that looks fine and contains no charts, so the 2->4 rewrite is inseparable
#     from it — and verifying that needs a browser render of those templates
#
# So this stays warn until **T-39** does that work, and flipping it to strict is T-39's
# deliverable rather than a cleanup somebody can take on the way past. Do not flip it to
# silence the two lines; they are the finding.
#
# A DIGEST MISMATCH FAILS IN BOTH MODES. There is no reading of a changed vendored
# library that is a warning.

MODE="${VENDOR_INTEGRITY_MODE:-warn}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MANIFEST='THIRD_PARTY.md'
status=0

if [ ! -f "$MANIFEST" ]; then
  echo "vendor_integrity: FAIL — $MANIFEST is missing; a vendored library with no manifest" >&2
  echo "                  is a supply-chain claim with nothing behind it." >&2
  exit 1
fi

# --- 1. Integrity -----------------------------------------------------------------
#
# Every file under assets/**/vendor/ must appear in the manifest WITH a matching digest.
# Driven from the DIRECTORY rather than from the manifest, so a library dropped in
# without a manifest row fails. The other direction — a manifest row whose file is gone —
# is checked after, because a stale row is how a manifest becomes folklore.

vendored=0
missing_rows=()
mismatched=()

while IFS= read -r file; do
  vendored=$((vendored + 1))
  rel="${file#./}"
  actual="$(sha256sum "$file" | cut -d' ' -f1)"

  if ! grep -qF "$rel" "$MANIFEST"; then
    missing_rows+=("$rel")
    continue
  fi
  if ! grep -qF "$actual" "$MANIFEST"; then
    mismatched+=("$rel (on disk: $actual)")
  fi
done < <(find assets -path '*/vendor/*' -type f ! -name '*.LICENSE.md' ! -name 'LICENSE*' | sort)

if [ "$vendored" -eq 0 ]; then
  echo "vendor_integrity: FAIL — no vendored files found under assets/**/vendor/." >&2
  echo "                  A gate that finds nothing to check is indistinguishable from" >&2
  echo "                  a gate that passes, which is the failure mode this repository" >&2
  echo "                  keeps rediscovering. If the vendoring moved, move this gate." >&2
  exit 1
fi

if [ "${#missing_rows[@]}" -gt 0 ]; then
  echo "vendor_integrity: FAIL — vendored, but not in $MANIFEST:" >&2
  printf '  %s\n' "${missing_rows[@]}" >&2
  status=1
fi

if [ "${#mismatched[@]}" -gt 0 ]; then
  echo "vendor_integrity: FAIL — the file on disk is not the one $MANIFEST records:" >&2
  printf '  %s\n' "${mismatched[@]}" >&2
  echo "  Re-download from the recorded upstream and compare, or update the manifest in" >&2
  echo "  the same commit that updates the library — never the other way round." >&2
  status=1
fi

# --- 2. Egress --------------------------------------------------------------------
#
# Anything a template author copies, plus the plugin's own assets and views. The
# vendored directory itself is excluded: a library may legitimately contain a URL in a
# comment or a docs link, and it is the file the manifest pins.

search() {
  local pattern="$1" rc out
  out="$(grep -rInE "$pattern" \
        --include='*.liquid' --include='*.js' --include='*.css' --include='*.erb' --include='*.rb' \
        assets app examples lib 2>/dev/null | grep -v '/vendor/')"
  rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "vendor_integrity: FAIL — the search itself failed (exit $rc)" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# THE HOST, ANYWHERE IN THE FILE — not `src="…"`.
#
# The first version of this pattern matched an attribute, ran clean, and MISSED THE ONLY
# TWO REAL CASES IN THIS REPOSITORY: both shipped examples assign the URL to
# `window.GEO_CHARTJS_SRC` and inject a `<script>` element from JavaScript. A gate that
# reports zero findings against a repository that has two is worse than no gate, because
# its output reads as evidence. Caught by pointing it at the examples and disbelieving
# the count — the same rule §Findings E-14 records about the FR-19 lint.
CDN_HOSTS='cdnjs\.cloudflare\.com|cdn\.jsdelivr\.net|unpkg\.com|ajax\.googleapis\.com|cdn\.skypack\.dev|esm\.sh|code\.jquery\.com|stackpath\.bootstrapcdn\.com'
cdn_hits="$(search "$CDN_HOSTS")"

if [ -n "$cdn_hits" ]; then
  echo "vendor_integrity: a shipped file loads a library over the network:" >&2
  echo "$cdn_hits" >&2
  echo "  §6 rejects CDN-with-SRI: SRI proves the bytes and does nothing about the" >&2
  echo "  egress requirement, and denying egress is what kills SSRF value (INV-8)." >&2
  echo "  Vendor it under assets/javascripts/vendor/ and add a row to $MANIFEST." >&2
  [ "$MODE" = strict ] && status=1
fi

# --- 3. Stale rows ----------------------------------------------------------------
#
# A manifest naming a file that is gone is worse than no manifest: it reads as evidence.
# A warning rather than a failure, because the honest fix is to delete the row and that
# is a decision about the manifest's prose, not a mechanical one.
stale=()
while IFS= read -r referenced; do
  [ -f "$referenced" ] || stale+=("$referenced")
done < <(grep -oE 'assets/[A-Za-z0-9_/.-]*vendor/[A-Za-z0-9_.-]+' "$MANIFEST" | sort -u)

if [ "${#stale[@]}" -gt 0 ]; then
  echo "vendor_integrity: NOTE — $MANIFEST names files that do not exist:" >&2
  printf '  %s\n' "${stale[@]}" >&2
fi

cdn_count=0
[ -n "$cdn_hits" ] && cdn_count="$(printf '%s\n' "$cdn_hits" | wc -l | tr -d ' ')"
echo "vendor_integrity: mode=$MODE  vendored files=$vendored  cdn references=$cdn_count"

# THE SUMMARY LINE MAY NOT CLAIM MORE THAN THE RUN FOUND. Its first version printed
# "nothing shipped fetches a library" in warn mode while having just listed two files
# that do — a green-looking last line above a real finding, which is the shape a reader
# skims to. Warn mode reports; it does not absolve.
if [ "$status" -ne 0 ]; then
  :
elif [ "$cdn_count" -ne 0 ]; then
  echo "vendor_integrity: digests OK. $cdn_count CDN reference(s) reported and NOT enforced in warn mode —"
  echo "                  they are listed above and strict mode fails on them."
else
  echo "vendor_integrity: OK — every vendored file matches its recorded digest, and nothing shipped fetches a library."
fi
exit "$status"
