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
#
# --- THE SECOND NARROWING, ARGUED, AND UNLIKE THE FIRST IT IS A WHOLE FILE (T-34) ---
#
# `Net::HTTP` has been TAKEN OUT of the render arm's pattern and moved into
# `render_network_boundary` below, which checks the same thing with one named exemption:
# `render/engines/gotenberg.rb`. Read that function before concluding the boundary was
# weakened — it is stricter about the exempt file than this arm can be, and it fails when
# the exemption stops being needed as loudly as when it is exceeded.
#
# The reason it exists: `:gotenberg` is an engine that IS a service. There is no version
# of that adapter which does not open a socket, so the choice was never "socket or no
# socket" but "a socket this gate can see, or a socket laundered through a neutral
# directory it cannot" — and the charts/assets arms below exist precisely because a
# boundary that holds only transitively holds only by luck. Hiding the socket one hop away
# would have been that evasion wearing a port's clothes.
#
# Everything else the render arm forbids still applies to gotenberg.rb, and this is not
# INV-8 being relaxed: INV-8's subject is the ASSET path — the renderer must never fetch a
# document's references on the viewer's behalf. That adapter fetches nothing. It POSTs a
# document it was handed to an endpoint an OPERATOR configured.
LAYERS=(
  "render|$BASE/render|Rails\.|ActiveRecord|Liquid|Issue|Faraday|cookie|session([^I]|$)|the render path is L3: given a DocumentRequest it returns bytes, and it must not be able to reach a model or a session"
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

# --- THE RENDER LAYER'S NETWORK BOUNDARY, WITH ITS ONE EXEMPTION -------------------
#
# Three assertions, and the third is the one T-34's Accept list names.
#
#   1. EXACTLY the exempt file names `Net::HTTP` under render/. A second one is a
#      failure — the exemption is for an engine that is a service, not a licence for the
#      layer.
#   2. The exemption is NOT STALE. If the exempt file stops naming `Net::HTTP` the gate
#      fails and says to delete this block. `zero_reporter.sh` learned the same lesson:
#      an allowlist entry that permits nothing today is what silently permits something
#      tomorrow.
#   3. Gotenberg's `convert/url` route is ABSENT FROM EVERY FILE THAT COULD REQUEST IT.
#      That route hands Gotenberg a URL and has it fetch it, which is SSRF with a PDF
#      attached (technical-spec.md §5.2 clause 1). It is a forbidden CODE PATH rather
#      than a discouraged one, so the check is over the whole tree and not over the
#      adapter alone — somebody adding the route would also be editing the file that
#      forbids it.
#
#      TWO THINGS THIS GETS RIGHT THAT THE FIRST VERSION DID NOT, both of them HANDOVER
#      §1 entries met head-on.
#
#      PROSE IS NOT A CODE PATH. The first version grepped every tracked file and failed
#      on five: the technical spec's own clause forbidding the route, the generated
#      support matrix, `capabilities.yml`'s verification note, and this script twice.
#      That is the `<script>`-in-a-comment lint finding 72 escaping defects in a template
#      that had none. Documentation MUST be able to name what it forbids, so the subject
#      is narrowed to the file types that can actually issue a request, and Ruby and
#      shell comments inside them are stripped exactly as `search()` strips them.
#
#      AND THE GATE DOES NOT EXEMPT ITSELF. Self-exclusion would be a hole shaped like a
#      file somebody can edit. Instead the needle is ASSEMBLED from two halves, so the
#      forbidden string never appears contiguously in this file and no exemption is
#      needed to keep the gate green — which is also why the comments above write it as
#      `convert/url` rather than in full.
RENDER_HTTP_EXEMPT="$BASE/render/engines/gotenberg.rb"
FORBIDDEN_ROUTE="forms/chromium/convert/""url"

render_network_boundary() {
  local rc=0 http_files unexpected

  http_files="$(search 'Net::HTTP' "$BASE/render" | sed '/^$/d' | cut -d: -f1 | sort -u)"

  unexpected="$(echo "$http_files" | sed '/^$/d' | grep -vx "$RENDER_HTTP_EXEMPT" || true)"
  if [ -n "$unexpected" ]; then
    echo "layer_purity: render-network — FAIL, Net::HTTP under render/ outside the one exemption:"
    echo "$unexpected" | sed 's/^/    /'
    echo "    reason: the render path may not hold the network. The single exemption is"
    echo "            $RENDER_HTTP_EXEMPT, an engine that IS a service."
    rc=1
  fi

  if ! echo "$http_files" | grep -qx "$RENDER_HTTP_EXEMPT"; then
    echo "layer_purity: render-network — FAIL, the exemption is STALE."
    echo "    $RENDER_HTTP_EXEMPT no longer names Net::HTTP, so this exemption now permits"
    echo "    nothing — which is exactly how an allowlist entry silently permits something"
    echo "    later. Delete RENDER_HTTP_EXEMPT and put Net::HTTP back in the render arm."
    rc=1
  fi

  # `git ls-files` rather than `find`: the subject is what this repository SHIPS, and a
  # stray file in a working tree is not that. Restricted to the types that can issue a
  # request — see the long comment above for why documentation is out of scope — and
  # whole-line comments are stripped so that a file may explain the rule it obeys.
  # `grep_rc` AND NOT `rc`. A second `local rc` here re-declares the one this function
  # opened with, so the two failures above were wiped and the final `[ "$rc" -eq 0 ]`
  # compared against an unset variable — the gate returned FAILURE and printed NOTHING,
  # which is the one outcome this file exists to make impossible. Caught by running it.
  local route_hits='' file stripped grep_rc
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    stripped="$(sed 's/^[[:space:]]*#.*$//' "$file" | grep -nE "$FORBIDDEN_ROUTE")"; grep_rc=$?
    if [ "$grep_rc" -gt 1 ]; then
      echo "layer_purity: FAIL — the route search itself failed (exit $grep_rc) on $file" >&2
      exit 2
    fi
    [ -n "$stripped" ] && route_hits="$route_hits$(echo "$stripped" | sed "s|^|$file:|")
"
  #
  # `--cached --others --exclude-standard` AND NOT A BARE `git ls-files`, WHICH LISTS ONLY
  # TRACKED FILES. The bare form is what this was first written as, and a mutation caught
  # it: setting `CONVERT_PATH` to the forbidden route left the gate GREEN, because
  # `render/engines/gotenberg.rb` was a new file nobody had `git add`ed yet — so the one
  # file in the tree most likely to contain that route was the one file the check could
  # not see. A gate that only inspects what is already committed cannot stop anything
  # from being committed. `--exclude-standard` keeps `.gitignore`d build output out.
  done < <(git ls-files --cached --others --exclude-standard \
                        -- '*.rb' '*.rake' '*.sh' '*.js' '*.erb' '*.yaml' \
                           '.github/workflows/*.yml' 'docker-compose*.yml' 2>/dev/null | sort -u)

  route_hits="$(echo "$route_hits" | sed '/^$/d')"
  if [ -n "$route_hits" ]; then
    echo "layer_purity: render-network — FAIL, the forbidden Gotenberg route is present:"
    echo "$route_hits" | sed 's/^/    /'
    echo "    reason: /$FORBIDDEN_ROUTE makes the render service fetch a URL you name."
    echo "            Only $FORBIDDEN_ROUTE's sibling convert/html, with the upload model."
    rc=1
  fi

  [ "$rc" -eq 0 ] && echo "layer_purity: render-network — OK (one named exemption, and no $FORBIDDEN_ROUTE)"
  return "$rc"
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

if [ -d "$BASE/render" ]; then
  render_network_boundary || STATUS=1
  CHECKED=$((CHECKED + 1))
else
  echo "layer_purity: render-network — ABSENT ($BASE/render). Nothing checked."
  ABSENT=$((ABSENT + 1))
fi

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
