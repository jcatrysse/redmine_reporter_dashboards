#!/usr/bin/env bash
set -euo pipefail

# Gate — T-38 (technical-spec.md §9b, CLAUDE.md §4's last bullet).
#
# "The plugin adopts Redmine's own markup, classes and icon set per version and ships
# NO design language of its own for chrome. Rejected: a bespoke UI skin — it would look
# current on one Redmine version and wrong on the other three, and it is the reliable
# way to make a plugin feel bolted on."
#
# That sentence has been in the spec since §9b was written and nothing enforced it, so
# the chrome stylesheet had quietly acquired six colours, a font size and a font weight.
# None of them was a skin; all of them were the first step of one, and each was a value
# that could only be right on some of the four Redmine versions this plugin supports —
# `.box` is `#f6f6f6`/`#e4e4e4` on 5.1 and 6.1 and `var(--oc-gray-0)`/`var(--oc-gray-2)`
# on 7.0, so a hex of ours matches at most one branch.
#
# --- WHAT A DESIGN TOKEN IS, MECHANICALLY, AND WHY THERE IS NO EXEMPTION -------------
#
# A gate with an exception is a gate somebody applies inconsistently, so this one has
# none. Chrome CSS may declare **layout** — box model, flow, position, flex, size — and
# may not declare anything that decides how the product LOOKS:
#
#   colour        any hex, any rgb()/hsl()/color-mix(), and the properties that carry
#                 one (color, background*, border*, outline*, fill, stroke, box-shadow)
#   type          font-family, font-size, font-weight, line-height, @font-face
#   tokens        a custom property DECLARATION (`--name:`), which is the literal
#                 definition of a design token
#
# The remedy is never "declare a nicer value" — it is to put the element in the Redmine
# class that already carries the right one for the branch it is running on. `ReportFrame`
# does exactly that: its frame is `box reporter-report-frame`, where `box` is Redmine's
# and `reporter-report-frame` is three layout properties of ours.
#
# THE REPORT BODY IS NOT CHROME and is not scanned. `ReportStylesheet` is where the
# plugin's design language belongs and is spent — §9b: "'beautiful' is spent entirely on
# the report output, where it is ours to control". It is Ruby, not CSS, precisely so its
# palette can be READ from `Charts::Palette` rather than restated (T-38's single-source
# clause), and `spec/report_stylesheet_spec.rb` holds it to that.
#
# --- AN ABSENT SUBJECT IS A FAILURE, NOT A PASS --------------------------------------
#
# `layer_purity.sh` shipped a version that reported every layer clean while checking
# nothing. A grep over a directory that has been renamed finds nothing and exits 0, which
# is indistinguishable from a directory that is clean. So: no CSS files found is a hard
# failure that names the directory.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

CHROME_DIR='assets/stylesheets'

# Comments are stripped before matching, for the reason layer_purity.sh and
# compat_size.sh both record: this gate's subject file explains in its own header which
# constructs are forbidden and why, and a gate that punishes writing down its rationale
# teaches people to delete the rationale.
#
# RUBY AND NOT SED, AND THE FIRST DRAFT WAS SED. A CSS comment spans lines, so the strip
# has to be multi-line — and the sed version of that (`tr '\n' '\f'`, then
# `s|/\*.*\*/||g`) is GREEDY across the joined stream: it deleted everything between the
# FIRST `/*` and the LAST `*/`, which in this repository's only chrome stylesheet is
# every rule in the file. The gate passed, and it passed because it was looking at almost
# nothing. Caught by planting a violation in the MIDDLE of the file rather than at the
# end, which is the difference between negative-testing a gate and watching it agree with
# you. `.*?` non-greedy with `/m` is the fix, and Ruby has it; POSIX sed does not.
#
# THE ENCODING IS NAMED, and that is the second thing the first draft got wrong. A bare
# container has no `LANG`, so Ruby's `Encoding.default_external` is US-ASCII and
# `File.read` + `gsub` raises `invalid byte sequence` on the em dashes in this
# repository's own comments — HANDOVER §3 records the same root cause costing three
# `spec_liquid` examples. The strip then failed on every file while the gate still
# printed OK, because the failure arrived as an empty pipe and an empty pipe is
# indistinguishable from a clean file. Both halves are fixed: the encoding here, and the
# empty-strip check in `scan` below.
#
# COMMENT BODIES BECOME SPACES RATHER THAN DISAPPEARING, so the line numbers this gate
# reports are the line numbers in the file. A strip that deletes lines reports a finding
# at a line that does not contain it, which is worse than no line number.
strip_comments() {
  ruby -e '
    text = File.read(ARGV[0], encoding: "UTF-8")
    print text.gsub(%r{/\*.*?\*/}m) { |span| span.gsub(/[^\n]/, " ") }
  ' "$1"
}

# Exit status is three-valued: 0 = matches, 1 = no matches, anything else = the search
# itself failed and this gate knows nothing, which must be loud. `|| true` on a search
# can never tell "clean" from "did not run".
#
# IT SEARCHES A PRE-STRIPPED COPY, and it does not check anything itself. The version this
# replaced did both here, and BOTH of its guards were unreachable: `scan` is called as
# `report 'a colour value' "$(scan …)"`, and an `exit 2` inside a command substitution exits
# the SUBSHELL. The status of a substitution used as a word is discarded, so `set -e` never
# fires either — the guard printed its message to stderr and the gate went on to report
# `OK … none` for every arm and exit 0. Found by an independent review, which is the second
# time this gate has had this exact defect and the reason it now has a committed self-test.
#
# So the checking happens ONCE, at top level, in `prepare`, where an `exit` is an exit.
scan() {
  local pattern="$1" file hits rc out=''
  while IFS= read -r file; do
    hits="$(grep -nEi "$pattern" "$(stripped_path "$file")")"; rc=$?
    if [ "$rc" -gt 1 ]; then
      echo "chrome_no_design_tokens: FAIL — the search itself failed (exit $rc) on $file" >&2
      exit 2
    fi
    [ -n "$hits" ] && out="$out$(echo "$hits" | sed "s|^|$file:|")
"
  done < <(printf '%s\n' "$FILES")
  printf '%s' "$out"
}

FILES="$(find "$CHROME_DIR" -name '*.css' -type f 2>/dev/null | sort)"
if [ -z "$FILES" ]; then
  echo "chrome_no_design_tokens: FAIL — no .css files under $CHROME_DIR/."
  echo "    Either the chrome stylesheet moved, in which case this gate has lost its"
  echo "    subject and must be pointed at the new one, or it was deleted. A gate whose"
  echo "    search finds no files reports PASS for a rule nobody is checking."
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

stripped_path() {
  printf '%s/%s' "$WORK" "$(printf '%s' "$1" | tr '/' '_')"
}

# EVERY FILE IS STRIPPED AND CHECKED HERE, at top level, BEFORE any arm runs — because an
# `exit` inside the command substitution the arms use is an exit from a subshell and nothing
# more. Two conditions stop the gate dead, and both are things that make it read nothing:
#
#   the strip FAILS            a crashed reader is not a clean file. The first version of
#                              this gate met it for real — no `LANG` in the container, so
#                              Ruby read the file as US-ASCII and raised on an em dash.
#   the strip EATS the file    a non-empty stylesheet that is all whitespace afterwards is
#                              either entirely comments or a strip that swallowed the rules.
#                              The second version met that one: a greedy multi-line pattern
#                              deleted everything between the first `/*` and the last `*/`.
prepare() {
  local file
  while IFS= read -r file; do
    if ! strip_comments "$file" > "$(stripped_path "$file")"; then
      echo "chrome_no_design_tokens: FAIL — could not strip comments from $file; this gate" >&2
      echo "                         has read nothing and knows nothing." >&2
      exit 2
    fi
    if [ -s "$file" ] &&
       [ -z "$(tr -d '[:space:]' < "$(stripped_path "$file")")" ]; then
      echo "chrome_no_design_tokens: FAIL — $file is not empty but nothing survived the" >&2
      echo "                         comment strip, so no rule in it was examined." >&2
      exit 2
    fi
  done < <(printf '%s\n' "$FILES")
}

prepare

STATUS=0

report() {
  local label="$1" hits="$2" remedy="$3"
  if [ -n "$(echo "$hits" | sed '/^$/d')" ]; then
    echo "chrome_no_design_tokens: FAIL — $label:"
    echo "$hits" | sed '/^$/d' | sed 's/^/    /'
    echo "    $remedy"
    STATUS=1
  else
    echo "chrome_no_design_tokens: OK — $label: none"
  fi
}

# ---- 1. colour, in any spelling ---------------------------------------------------
report 'a colour value' \
  "$(scan '#[0-9a-f]{3,8}\b|\b(rgba?|hsla?|hwb|lab|lch|oklch|color-mix)\s*\(')" \
  'Put the element in the Redmine class that already carries the right colour for the branch it runs on (`box`, `mypage-box`, `icon`, `contextual`, `nodata`).'

# ---- 2. the properties that decide the look --------------------------------------
#
# Matched at the start of a declaration — after `{`, after `;`, or at line start — so a
# CLASS NAME containing one of these words is not a finding. `.reporter-border-box` is a
# name; `border: …` is a declaration.
#
# `(-[a-z]+-)?` CATCHES THE VENDOR PREFIXES, and a review found the two-character evasion
# that made it necessary: `-webkit-text-fill-color:` begins with `-`, which is not in the
# leading character class, so it walked past a gate whose header says it has no exemptions.
# `text-fill-color` and `font-feature-settings` are named because neither ends in a word this
# list already had.
report 'a colour- or type-bearing property' \
  "$(scan '(^|[{;[:space:]])(-[a-z]+-)?(color|background|background-[a-z-]+|border|border-[a-z-]+|outline|outline-[a-z-]+|box-shadow|text-shadow|fill|stroke|font|font-[a-z-]+|line-height|text-fill-color)[[:space:]]*:')" \
  'Chrome declares layout only. If an element needs to look like part of Redmine, give it the Redmine class that does — do not restate its values here.'

# ---- 3. a custom property declaration, which IS a token --------------------------
#
# DECLARATIONS only. Reading one Redmine defines — `var(--oc-gray-2)` — would be a
# different question, and a worse idea for a different reason: those names exist only on
# 7.0, so a rule depending on one is invalid CSS on the three older branches and the
# declaration is dropped with no error. Arm 1 already forbids the fallback colour such a
# rule would need, so this arm does not have to argue about it.
report 'a custom property declaration' \
  "$(scan '(^|[{;[:space:]])--[a-z0-9-]+[[:space:]]*:')" \
  'A locally-defined custom property is a design token by definition. There is no plugin token layer for chrome; there is one for the report body, in Ruby, in ReportStylesheet.'

# ---- 4. a bundled typeface -------------------------------------------------------
report 'an @font-face rule' \
  "$(scan '@font-face')" \
  'Shipping a typeface is the loudest possible design language. The report body uses the same stack SvgRenderer draws with; chrome uses whatever Redmine uses.'

COUNT="$(echo "$FILES" | wc -l | tr -d ' ')"
echo "chrome_no_design_tokens: scanned $COUNT stylesheet(s) under $CHROME_DIR/"

exit "$STATUS"
