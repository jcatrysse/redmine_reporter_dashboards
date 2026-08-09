#!/usr/bin/env bash
set -euo pipefail

# Gate — T-09 / mechanism E3 (technical-spec.md §1.2).
#
# The plugin's INTERNAL layering, which is a different question from zero_reporter.sh:
# that one asks whether we still name the base plugin or the vendor gem (G8, an outward
# coupling), this one asks whether our own layers have leaked into each other.
#
#   render/**       must contain NO Rails., ActiveRecord, Liquid, Issue, Net::HTTP,
#                   Faraday, cookie, session. The render path is L3 — it takes a
#                   DocumentRequest and gives back bytes. The moment it can reach a
#                   model or a session it can also make a visibility decision, and
#                   visibility decisions belong upstream of it (INV-1/INV-3).
#   aggregation/**  must not name the render layer.
#   liquid/**       must not name the render layer.
#
# --- THE PART THAT MATTERS MOST: this gate must not be silently green ---
#
# `render/` DOES NOT EXIST YET — T-10 creates it. A grep over a directory that is not
# there finds nothing and exits 0, which is indistinguishable from a directory that
# exists and is clean. That is the single failure mode this repository keeps
# rediscovering: the mirrored plugin copy with no git history, the corpus examples
# pending without a reference date, the skipped guard that reads as a passing one.
#
# So an absent layer is REPORTED on its own line, every run, and `LAYER_PURITY_MODE=strict`
# fails on one. T-10 should flip this job to strict in the same PR that creates render/ —
# at which point an absent layer means the layout moved and the gate lost its subject.

MODE="${LAYER_PURITY_MODE:-warn}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BASE='lib/redmine_reporter_dashboards'

# --- ONE NARROWING, ARGUED (T-13) ---
#
# The render layer's pattern says `session([^I]|$)` and not a bare `session`, which
# exempts exactly one spelling: `sessionId`, the Chrome DevTools Protocol's field for
# multiplexing several attached targets down one pipe. It is not an HTTP session and
# has nothing to do with the thing this boundary exists to keep out — a render layer
# that can read a Rack session can make a visibility decision, and visibility decisions
# belong upstream of it (INV-1/INV-3).
#
# Everything that spelling could hide is still caught: `session_id`, `session[`,
# `request.session`, `sessions`, and a bare `session` at end of line all match, because
# the exempted character class is a single `I` immediately after the word. The Ruby side
# of the adapter avoids the collision anyway — `CdpClient` calls it `channel` — so the
# exemption covers only the two lines that have to spell the wire format.
#
# NEGATIVE-TESTED before being trusted, which is this file's own rule: each of
# `session_id`, `request.session` and `cookies` was planted under render/ in turn and
# this gate failed on each; `sessionId` alone passed.
#
# Layer, path, forbidden pattern, and the reason in one line for the failure message.
# --- THE TWO NEUTRAL LAYERS, AND WHY THEY ARE CHECKED AT ALL (T-33, findings F-13/F-13b) ---
#
# `charts/` and `assets/` sit BETWEEN the Liquid layer and the render layer, naming
# neither, so that both may name them. §1.1's tree put both inside `render/` and neither
# can go there: `{% chart %}` has to build a `ChartSpec`, and an asset resolver is made of
# `Net::HTTP` — the first would need `liquid/**` to name the render layer and the second
# would need `render/**` to hold the network. Those are the two patterns above with the
# most security weight, and relaxing either to satisfy a directory listing is exactly what
# CLAUDE.md §7 forbids ("never make a hard gate advisory to get to green").
#
# The curator settled the tree rather than having each task settle it again, and these two
# arms are what stop "a namespace that names neither layer" from decaying into "the place
# where anything is allowed". Without them the boundary would hold TRANSITIVELY only by
# luck: `liquid/` naming `charts/` naming `Render` reaches the render layer in two hops,
# and a per-file grep sees neither hop as a violation.
#
# `assets/**` deliberately does NOT forbid `Net::HTTP` — it is the fetcher, and being the
# one place in the plugin that holds a socket is its entire job. What it may not do is be
# reachable from, or reach into, the render layer.
LAYERS=(
  "render|$BASE/render|Rails\.|ActiveRecord|Liquid|Issue|Net::HTTP|Faraday|cookie|session([^I]|$)|the render path is L3: given a DocumentRequest it returns bytes, and it must not be able to reach a model, a session or the network"
  "aggregation|$BASE/aggregation|(Reporter|RedmineReporter)Dashboards::Render|the aggregation kernel answers numbers; it must not know how they are drawn"
  "liquid|$BASE/liquid|(Reporter|RedmineReporter)Dashboards::Render|the Liquid layer binds a scope and renders tags; it must not reach into the render path"
  "charts|$BASE/charts|(Reporter|RedmineReporter)Dashboards::(Render|Liquid)|the chart layer is named by BOTH the Liquid and the render layer, so it must name neither — or the boundary between them holds only until somebody follows the two hops"
  "assets|$BASE/assets|(Reporter|RedmineReporter)Dashboards::(Render|Liquid)|the asset layer holds the network and runs UPSTREAM of the render layer; Render::AssetBinding is the seam, and it lives in render/ precisely so this directory does not have to name it"
  "archive|$BASE/archive|(Reporter|RedmineReporter)Dashboards::(Render|Liquid)|Net::HTTP|Faraday|cookie|session([^I]|$)|T-29: the archive writer turns entries into bytes and is named by the composition root, so it must name neither layer - and it must not hold HTTP either, because the ONE thing that makes it a streamed archive (no Content-Length) is a header, which belongs to the controller. E-6 says a zip in render/ is the violation this gate exists to catch; this arm is what stops it drifting back"
  "reporting|$BASE/reporting|Net::HTTP|Faraday|cookie|session([^I]|$)|the composition root may name BOTH layers - that is what it is for - but it must not become a third render path or a second place that knows about HTTP; a fetcher belongs in assets/ and request state belongs in a controller"
  "scheduling|$BASE/scheduling|(Reporter|RedmineReporter)Dashboards::(Render|Liquid)|Net::HTTP|Faraday|cookie|session([^I]|$)|the scheduler runs from a rake task with no request behind it, so a cookie or a session here is not a leak across a layer but a value that cannot exist; and it names NEITHER the Liquid layer nor the render layer, which is what the required delivery: port is for - occurrences.rb claims that property in as many words, so it is enforced rather than asserted"
)

# Search, and DIE if the search itself failed.
#
# The first version of this function was `rg -nE "$pattern" "$path" || true`, and it
# reported every layer clean while checking nothing: in ripgrep `-E` is `--encoding`,
# not "extended regex" (rg is always a regex matcher), so rg exited 2 with
# "unknown encoding: Rails\.|ActiveRecord|..." and `|| true` turned that crash into a
# pass. A deliberately planted `Issue.visible` in render/ went undetected.
#
# Hence: exit 0 = matches, 1 = no matches, anything else = the tool failed and this gate
# knows nothing. `|| true` on a search is never safe in a gate — it cannot tell "clean"
# from "did not run", and those are the two states a gate exists to distinguish.
# Whole-line comments are stripped before matching, for the same reason compat_size.sh
# does it: the FIRST run of this gate against a real render/ failed on the two comments
# that explain WHY the boundary exists — "not `Rails.logger`, mechanism E5" and "no field
# a credential could travel in — no `cookies:`". A gate that punishes writing down its own
# rationale teaches people to delete the rationale, so it would damage the codebase in
# precisely the dimension it exists to protect. A trailing comment on a line of code still
# counts; that line is code.
search() {
  local pattern="$1" path="$2" file stripped rc out=''
  while IFS= read -r file; do
    stripped="$(sed 's/^[[:space:]]*#.*$//' "$file" | grep -nE "$pattern")"; rc=$?
    if [ "$rc" -gt 1 ]; then
      echo "layer_purity: FAIL — the search itself failed (exit $rc) on $file" >&2
      exit 2
    fi
    [ -n "$stripped" ] && out="$out$(echo "$stripped" | sed "s|^|$file:|")
"
  done < <(find "$path" -name '*.rb' -type f | sort)
  printf '%s' "$out"
}

STATUS=0
ABSENT=0
CHECKED=0

for entry in "${LAYERS[@]}"; do
  IFS='|' read -r name path rest <<< "$entry"
  # Everything between the path and the final field is the pattern; the last is the reason.
  reason="${rest##*|}"
  pattern="${rest%|*}"

  if [ ! -d "$path" ]; then
    echo "layer_purity: $name — ABSENT ($path). Nothing checked."
    ABSENT=$((ABSENT + 1))
    continue
  fi

  CHECKED=$((CHECKED + 1))
  hits="$(search "$pattern" "$path")"

  files="$(echo "$hits" | sed '/^$/d' | cut -d: -f1 | sort -u)"
  count="$(echo "$files" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ -n "$(echo "$hits" | sed '/^$/d')" ]; then
    echo "layer_purity: $name — FAIL, $count file(s) leak across the boundary:"
    echo "$hits" | sed '/^$/d' | sed 's/^/    /'
    echo "    reason: $reason"
    STATUS=1
  else
    echo "layer_purity: $name — OK ($path)"
  fi
done

echo "layer_purity: mode=$MODE  layers checked=$CHECKED  absent=$ABSENT"

if [ "$ABSENT" -gt 0 ]; then
  if [ "$MODE" = "strict" ]; then
    echo
    echo "FAIL (strict): $ABSENT layer(s) do not exist, so this gate checked nothing for them."
    echo "Either the layout moved and this script has to move with it, or the job was"
    echo "switched to strict before the layer it names was written."
    exit 1
  fi
  echo "              An absent layer is NOT a pass. render/ arrives with T-10, which"
  echo "              should switch this job to LAYER_PURITY_MODE=strict in the same PR."
fi

if [ "$STATUS" -eq 0 ] && [ "$ABSENT" -eq 0 ]; then
  echo "layer_purity: OK — every layer exists and none of them reaches across."
fi

exit "$STATUS"
