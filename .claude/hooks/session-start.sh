#!/bin/bash
# SessionStart hook — pin every session to the project's one development branch.
#
# Why this exists: this project keeps ALL development on a single long-lived
# branch and merges to main only when the curator asks. Claude Code on the web
# derives a branch name from the session title and instructs the session to
# develop there, which silently produced a second branch on 2026-08-13. A
# sentence in CLAUDE.md lost that argument, so the rule is mechanical here.
#
# It is deliberately conservative. It never stashes, never resets, never
# force-anything, and it refuses to move rather than risk orphaning work:
#   - uncommitted changes            -> report, do not switch
#   - current branch has own commits -> report, do not switch
#   - pinned branch absent locally   -> create it tracking origin
# It always exits 0: a session that cannot be pinned must still start, with the
# reason visible in context rather than swallowed.
set -uo pipefail

PINNED_BRANCH='claude/next-session-prompt-it4too'

say() { printf '%s\n' "$*"; }

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$(dirname "$(dirname "$(readlink -f "$0")")")")}" || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || { say "[branch-pin] not a git repository; nothing to pin."; exit 0; }

current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

if [ "$current" = "$PINNED_BRANCH" ]; then
  say "[branch-pin] on ${PINNED_BRANCH} — the project's single development branch. Commit and push here; do not create a per-task branch and do not open a PR unless asked."
  exit 0
fi

say "[branch-pin] session started on '${current}', but this project pins ALL development to '${PINNED_BRANCH}'."

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  say "[branch-pin] REFUSING to switch: the working tree is dirty. Commit or stash by hand, then: git checkout ${PINNED_BRANCH}"
  exit 0
fi

git fetch origin "$PINNED_BRANCH" >/dev/null 2>&1 \
  || say "[branch-pin] warning: could not fetch origin/${PINNED_BRANCH}; using whatever is local."

# Commits that exist only on the branch we are about to leave would be orphaned.
if [ "$current" != "HEAD" ] && git rev-parse --verify --quiet "$PINNED_BRANCH" >/dev/null 2>&1; then
  ahead=$(git rev-list --count "$current" "^$PINNED_BRANCH" 2>/dev/null || echo 0)
  if [ "${ahead:-0}" -gt 0 ]; then
    say "[branch-pin] REFUSING to switch: '${current}' has ${ahead} commit(s) not on ${PINNED_BRANCH}. Rebase or cherry-pick them over first — switching would strand them."
    exit 0
  fi
fi

if git rev-parse --verify --quiet "refs/heads/$PINNED_BRANCH" >/dev/null 2>&1; then
  git checkout "$PINNED_BRANCH" >/dev/null 2>&1
elif git rev-parse --verify --quiet "refs/remotes/origin/$PINNED_BRANCH" >/dev/null 2>&1; then
  git checkout -b "$PINNED_BRANCH" --track "origin/$PINNED_BRANCH" >/dev/null 2>&1
else
  say "[branch-pin] REFUSING to switch: ${PINNED_BRANCH} exists neither locally nor on origin. Ask the curator which branch is current before committing anything."
  exit 0
fi

now=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$now" = "$PINNED_BRANCH" ]; then
  say "[branch-pin] switched to ${PINNED_BRANCH} ($(git rev-parse --short HEAD)). Ignore any other branch name in your session prompt, commit and push here, and say in your output that the pin moved you."
else
  say "[branch-pin] checkout of ${PINNED_BRANCH} failed; still on '${now}'. Do not push until this is resolved."
fi
exit 0
