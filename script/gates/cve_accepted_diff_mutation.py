#!/usr/bin/env python3
"""Mutation harness for the CVE gate — T-34.

    python3 script/gates/cve_accepted_diff_mutation.py

COMMITTED ON PURPOSE. The first version of this change claimed "16 of 16 mutants killed"
from a harness that lived in a scratch directory, and by the time it reached a reviewer
the artefacts around it disagreed about whether the number was 14 or 16. An unreproducible
mutation score in a repository whose hard rule 2 is "never declare a test or lint result
you did not observe" is not evidence — it is a number. This file makes it re-runnable, and
the score is whatever it prints today rather than whatever a comment remembers.

Adversarial QA then made the sharper point: a mutation score is a function of the mutant
SET, and the author picks the set. So the set is here to be read and argued with, and five
of the mutants below (Mb, Md, Mh, Mj, Mn) are ones a reviewer wrote after the author's
own pass reported a clean sweep — every one of them survived at the time.

HOW IT WORKS. Each mutation is a (needle, replacement) pair applied to the gate source.
The file is re-read and compared, so a mutation that did not apply is reported NOT-APPLIED
and never as a survivor — the harness's own first version silently applied nothing (a
`< /dev/null` after a heredoc) and reported 12 of 12 survivors, including one that deleted
the verdict entirely. The self-test's summary line is parsed; its absence is UNMEASURED,
never green. The source is restored on every path, including exceptions.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "cve_accepted_diff.sh")
TEST = os.path.join(HERE, "cve_accepted_diff_selftest.sh")

# (id, description, needle, replacement)
MUTATIONS = [
    # --- the four refusals, deleted one at a time ------------------------------------
    ("M01", "delete the unaccepted-finding arm",
     'if [ -s "$WORK/new-ids" ]; then', 'if false; then'),
    ("M02", "delete the stale-acceptance arm",
     'if [ -s "$WORK/stale-ids" ]; then', 'if false; then'),
    ("M03", "delete the expiry check",
     'if [ "$TODAY" \\> "$exp" ]; then', 'if false; then'),
    ("M04", "off-by-one: an acceptance expires ON its valid-through date",
     'if [ "$TODAY" \\> "$exp" ]; then', 'if [ ! "$TODAY" \\< "$exp" ]; then'),
    ("M05", "delete the date-shape check",
     "printf '%s' \"$candidate\" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || return 1",
     "true"),
    ("M06", "delete the empty-reason validation",
     'if [ -z "$(printf \'%s\' "$why" | tr -d \'[:space:]\')" ]; then', 'if false; then'),
    ("M07", "delete the id validation",
     "    ''|*[[:space:]]*|*'|'*)", "    'never-matches-this')"),
    ("M08", "delete the missing/unreadable-input check",
     '[ -r "$f" ] || { echo', '[ -r "$f" ] || true || { echo'),
    ("M09", "never fail: swallow the verdict",
     '[ "$bad" -eq 0 ] || exit 1', 'bad=0'),
    ("M10", "swap the two comm arms",
     'comm -13 "$WORK/accepted-ids"', 'comm -23 "$WORK/accepted-ids"'),

    # --- the date is a SHAPE, not a DAY: the blocker an independent review found ------
    ("M11", "accept any date-shaped string as a real day",
     'parsed="$(date -u -d "$candidate" +%F 2>/dev/null)" || return 1\n  [ "$parsed" = "$candidate" ]',
     'return 0'),
    ("M12", "remove the upper bound on the acceptance window",
     'if [ "$window" -gt "$MAX_ACCEPTANCE_DAYS" ]; then', 'if false; then'),
    ("M13", "off-by-one on the window: reject AT the limit",
     'if [ "$window" -gt "$MAX_ACCEPTANCE_DAYS" ]; then',
     'if [ "$window" -ge "$MAX_ACCEPTANCE_DAYS" ]; then'),

    # --- provenance: the critical defect adversarial QA walked end to end -------------
    ("M14", "an empty found list is clean again",
     'if [ ! -s "$WORK/found-ids" ] && [ "$HAS_PROVENANCE" -eq 0 ]; then', 'if false; then'),
    ("M15", "provenance is assumed rather than read",
     "grep -q '^#scan' \"$WORK/found-raw\" && HAS_PROVENANCE=1 || HAS_PROVENANCE=0",
     "HAS_PROVENANCE=1"),

    # --- the clock override -----------------------------------------------------------
    ("M16", "stop validating the injected clock",
     'is_a_date "$CVE_GATE_TODAY" || {', 'false && {'),
    ("M17", "stop announcing the injected clock",
     '  echo "cve_accepted_diff: NOTE — running against an INJECTED clock of $TODAY, not today." >&2',
     '  :'),

    # --- --expiry-advisory: scoped, and only scoped -----------------------------------
    ("M18", "--expiry-advisory also softens record validation",
     '    if ! is_a_date "$exp"; then', '    if false; then'),
    ("M19", "--expiry-advisory is allowed on the comparison too",
     '  [ "$EXPIRY_MODE" = hard ] || {', '  false && {'),
    ("M20", "--expiry-advisory becomes the default",
     'EXPIRY_MODE=hard', 'EXPIRY_MODE=advisory'),

    # --- five a reviewer wrote after the author's own pass reported a clean sweep -----
    ("Mb", "existence check applied to the accepted file only",
     'for f in "$ACCEPTED_FILE" ${FOUND_FILE:+"$FOUND_FILE"}; do',
     'for f in "$ACCEPTED_FILE"; do'),
    ("Mj", "drop the no-trailing-newline handling",
     'while IFS= read -r raw || [ -n "$raw" ]; do', 'while IFS= read -r raw; do'),
    ("Md", "stop de-duplicating the accepted ids",
     'sort -u -o "$WORK/accepted-ids" "$WORK/accepted-ids"',
     'sort -o "$WORK/accepted-ids" "$WORK/accepted-ids"'),
    ("Mh", "the date shape loses its end anchor",
     "'^[0-9]{4}-[0-9]{2}-[0-9]{2}$'", "'^[0-9]{4}-[0-9]{2}-[0-9]{2}'"),
    ("Mn", "interior whitespace in an id is squeezed away again",
     "cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'",
     "cut -d'|' -f1 | tr -d '[:space:]'"),
]


def read(path):
    with open(path) as handle:
        return handle.read()


def write(path, text):
    with open(path, "w") as handle:
        handle.write(text)


def run_selftest():
    proc = subprocess.run(["bash", TEST], capture_output=True, text=True, timeout=600)
    return proc.returncode, proc.stdout + proc.stderr


def summary_of(output):
    lines = [line for line in output.splitlines() if "self-test:" in line]
    return lines[-1] if lines else None


def main():
    original = read(SRC)
    tally = {"KILLED": 0, "SURVIVED": 0, "NOT-APPLIED": 0, "UNMEASURED": 0}
    survivors = []

    try:
        rc, out = run_selftest()
        summary = summary_of(out)
        if rc != 0 or summary is None or "FAILED" in summary:
            print("CONTROL IS NOT GREEN — every result below would be meaningless.")
            print(out)
            return 1
        print(f"control: {summary}\n")

        for mid, desc, needle, repl in MUTATIONS:
            write(SRC, original)
            if needle not in original:
                print(f"{mid:4}  NOT-APPLIED  {desc}")
                print("                   the needle is not in the source — this mutant "
                      "no longer describes the code")
                tally["NOT-APPLIED"] += 1
                continue

            write(SRC, original.replace(needle, repl, 1))
            if read(SRC) == original:
                print(f"{mid:4}  NOT-APPLIED  {desc}  (file unchanged after write)")
                tally["NOT-APPLIED"] += 1
                continue

            rc, out = run_selftest()
            summary = summary_of(out)
            if summary is None:
                print(f"{mid:4}  UNMEASURED   {desc}  (no summary line, rc={rc})")
                tally["UNMEASURED"] += 1
                continue
            if "FAILED" in summary:
                by = [line.replace("FAIL  ", "").split(":")[0]
                      for line in out.splitlines() if line.startswith("FAIL ")]
                print(f"{mid:4}  KILLED       {desc}")
                print(f"                   by: {'; '.join(by[:4])}"
                      + (f" (+{len(by) - 4} more)" if len(by) > 4 else ""))
                tally["KILLED"] += 1
            else:
                print(f"{mid:4}  SURVIVED     {desc}")
                survivors.append((mid, desc))
                tally["SURVIVED"] += 1
    finally:
        write(SRC, original)

    rc, out = run_selftest()
    summary = summary_of(out)
    print(f"\nrestored control: {summary or 'NO SUMMARY LINE'} (rc={rc})")
    print("  ".join(f"{k}={v}" for k, v in tally.items()))

    if survivors:
        print("\nSURVIVORS — each is a coverage gap or an equivalent mutant, and the two")
        print("are told apart by CONSTRUCTING the observable difference, never by reading:")
        for mid, desc in survivors:
            print(f"  {mid}  {desc}")

    # A surviving mutant is a finding, not a failure of this harness: exit 0 so the score
    # can be read. The self-test is what gates CI.
    return 0 if (rc == 0 and summary and "FAILED" not in summary) else 1


if __name__ == "__main__":
    sys.exit(main())
