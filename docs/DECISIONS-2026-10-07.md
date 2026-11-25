# Decided by Jan, 2026-10-07

Jan Catrysse answered the open questions of this plugin on 2026-10-07, one at a time, with the
options, an explanation and the recommendation in front of him, in the coordinating session that
started the migration sessions (https://claude.ai/code/session_01GiSsYPm3bxvqrpZkdCxNoi).
This file records his answers as given; his free-text notes are quoted verbatim. The migration
session moves each into docs/REDMINE7-MIGRATION.md as decided and builds what it requires.

General decisions by Jan (2026-10-07), for every GEOxyz plugin:
- GEOxyz goes straight to Redmine 7: no backports to 5.1. Nothing is cherry-picked to the default branch or to the branch production runs today; `redmine70-migration` is what goes live with Redmine 7. Redmine 5.1 compatibility is no longer a requirement; drop that rule from the plan and do not add code paths that exist only for 5.1.
- GEOxyz does not use MariaDB or MySQL; production runs PostgreSQL 16. Run the tests and the e2e set on PostgreSQL only. Keep SQL portable where that costs nothing, but MariaDB runs are no longer required and a MariaDB-only problem is a note in the plan, not a blocker.
- A plugin that depends on deface requires it without a version constraint (change it when the Gemfile is touched anyway).
- A Redmine core method that other installed plugins also patch is patched with `prepend`, never with `alias_method`. Mixing both on one method recurses; that is what made Project > Settings return HTTP 500 with all GEOxyz plugins installed. Check this plugin: if it patches such a method with `alias_method`, switch it to `prepend` with a test, and confirm Project > Settings, the issue list and an issue page answer 200 with the other GEOxyz plugins installed (`RMP_EXTRA_PLUGINS`).
- GitHub Actions stay manual only (`workflow_dispatch`).

Decisions for this plugin:
1. redmine_reporter_dashboards-q1: Wat doen we met rapportsjablonen groter dan 64 KB als productie op MariaDB draait?
   No option chosen; follow Jan's note.
   Jan's note: "we gebruiken geen mariadb (Jan); geen kolomwijziging, nette melding laten staan"

For q1 Jan answered that GEOxyz does not use MariaDB: no column change, keep the clean error message; record it.

What to do:
1. `git fetch && git checkout redmine70-migration && git pull`.
2. Record every decision above in docs/REDMINE7-MIGRATION.md: move it from open to decided, with the choice, the date 2026-10-07 and Jan's note verbatim where there is one. Update the plan's rules for the general decisions (no 5.1, PostgreSQL only).
3. Carry out each decision that needs a change: one commit per decision, each with a test that fails without it. A choice that says "later" or "separate change" is built now, in its own commit. A choice that says it happens after the upgrade goes under "After the upgrade". A decision that needs no code (not reporting to a vendor, accepting a loss, a role setting) is only recorded.
4. Plugin tests green on Redmine 7.0-stable-GEOxyz with PostgreSQL, alone and with the other GEOxyz plugins installed. Quote the numbers.
5. `./.codex/start_server.sh` and `./.codex/e2e.sh`: a scenario for every function a decision touches, as admin, manager, reporter and outsider, including the refusal paths. Open every screenshot, commit them in docs/e2e/ and list them in the inventory.
6. Your own adversarial review of the new commits, then `./.codex/openai_review.sh` when OPENAI_API_KEY is set; every finding gets a Resolution line. Without the key, say the review was skipped.
7. Update Status, the inventory, the work list and "After the upgrade". Push `redmine70-migration` after every commit.
8. These decisions are final; do not stop to ask about them. If one turns out to be impossible, write down why in the plan and carry on with the rest.
9. End with a short report in Dutch: per decision what you did (commit), test numbers, e2e numbers (scenarios, screenshots, problems), the review result, what is left for Jan.

## Round 2, decided by Jan on 2026-10-07 (evening)

Jan answered these follow-up questions from the migration report the same way, one at a time, in the coordinating session.

- redmine_issue_todo_lists2-n2-1 (todo_lists 2): issue to-do lists in report templates were only usable through RedmineUP. The redmine_issue_todo_lists2 session read Jan's earlier request as option (a): reporter_dashboards offers the to-do items itself, with the permissions of whoever views the report; redmine_issue_todo_lists2 stays as it is.
  Jan chose: "Ja, in reporter_dashboards" and added: "ja in reporter dashboards maar in de nieuwe branch (laatste versie) niet die van main". Carry this out here, on `redmine70-migration` (the newest version), not on main.

## Round 3, decided by Jan on 2026-10-08

- reporter 9 (Q9): the accepted Gotenberg CVE-2026-56852 (pdfcpu, golang.org/x/text) expired on 2026-09-09; release.sh reports NOT RELEASABLE.
  Jan chose: "Bijwerken, anders verlengen": look for a Gotenberg version that contains the fix and update to it; only if none exists, extend the acceptance by 3 months with the reason written down. Carry this out.
- reporter 10 (Q10): a GitHub job that tests this plugin together with redmine_issue_todo_lists2?
  Jan chose: "Alleen lokaal": no extra job; record it.

## Round 6, 2026-10-12: the follow-up points of the plan

Jan answered the open points this session recorded in docs/REDMINE7-MIGRATION.md after the earlier rounds, one by one in the coordinating session.

- **Q11, 136 fixable HIGH/CRITICAL advisories in Gotenberg 8.37.0: (b), accept them all for a limited time.** Jan chose this over the recommendation. Accept each one in `script/gates/gotenberg_accepted_cves.allowlist` (or the file the gate reads) with an expiry of 60 days (2026-12-11) and the containment as reason (no network, non-root, Chromium sandbox on, PDF-engine routes off). Re-check and move the pin as soon as Gotenberg publishes a release with Chromium 154. `release.sh` and the manual `gotenberg-cve` workflow must accept the file; prove it by running both locally.
- **Q5, admin menu icon: `stats`** (exists in Redmine 7's sprite) instead of `checked`. Check the menu in a real browser and replace the screenshot.
- **Q8, CLAUDE.md: update the two out-of-date points** (Jan's go-ahead): §4/§9 no longer describe a 5.1 to 7.0 span (Redmine 7 only, Jan 2026-10-07), and §7 says the Gotenberg CVE scan runs by hand only. Change only those passages.
- **Q6, alias_method in other plugins:** resolved meanwhile. The combined run of 2026-10-08 on all 44 `redmine70-migration` branches found 0 risky alias/prepend combinations; Project > Settings, the issue list, an issue page and My page answer 200. Record it; nothing to build here.
- **Q7, redmine_people and view_customize:** fixed in those plugins (Jan: "oplossen in die 2 plugins"); their sessions get the work. Keep this plugin's two tests strict; re-run them with both plugins installed once their branches carry the fix.

Build Q11, Q5 and Q8 now, one commit each, with tests where code changes; your own review and `./.codex/openai_review.sh` when OPENAI_API_KEY is set; push after every commit; end with a short Dutch report.
