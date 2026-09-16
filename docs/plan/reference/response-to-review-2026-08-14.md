# Response to the independent release review of 2026-08-14

**Reviewed commit:** `60ee3e8` on `claude/next-session-prompt-it4too`
**This response:** `28e6b93` on the same branch
**Written:** 2026-08-15

This document is addressed back to the review that produced it. It states, per finding, what was
verified, what was done, what was deliberately *not* done and why, and where the review was wrong.
It is not a summary of the review — it assumes the review is at hand.

Method: every claim below was reproduced against the working tree at `60ee3e8` before being acted
on. Where a number is given it was measured on that tree, not quoted from the review.

---

## 1. Corrections to the review

These matter more than the individual findings, because they affect how much of the review's
self-reported state can be trusted.

### 1.1 The documentation restructuring described as already done does not exist

The review states, twice, as settled fact:

> The original 2,600-line README has since been replaced by a concise entry point plus separate
> user, administrator and authoring guides.

> The root README is now a short entry point, with separate user, administrator and
> template-authoring guides. The changelog retains upgrade, security and behavioural information
> without reproducing the implementation diary.

Measured at `60ee3e8`:

```
$ wc -l README.md CHANGELOG.md
  2623 README.md
  1416 CHANGELOG.md
$ ls docs/
drop-reference.md  engine-support-matrix.md  plan/
```

There are no user, administrator or authoring guides. `README.md` is 2,623 lines. On the strength
of that non-existent restructuring the review closed the documentation half of **R-03** and
softened its conclusion in §9. **That half of R-03 is open**, and this response treats it as open.

### 1.2 R-06 is reported as CLOSED and is not

> **Resolution.** `CONTRIBUTING.md` now opens with the standalone-Bundler warning, links the three
> bootstrap scripts and describes the test suites in operational rather than historical terms.

The middle clause was true. The other two were not. `CONTRIBUTING.md` opened with:

> The plugin has two hard dependencies:
> - **Redmine** — a checkout is needed to run the minitest suite
> - **redmine_reporter** — a private plugin; see below for how to make it available

— which is not merely missing the warning, it is stale in the opposite direction, and it
contradicts §"The `redmine_reporter` dependency — optional" at line 109 of the same file.
`grep -in "bundler|bundle exec rspec|will fail"` over the file returned nothing.

The symptom was also mis-described. It is not a generic Bundler error:

```
$ bundle exec rspec spec spec_liquid
bundler: command not found: rspec
$ bundle install
Could not find gem 'liquid (>= 4.0, < 6.0)' in locally installed gems.
```

A source-less Gemfile resolves against installed gems only. Both are now fixed (§2.4).

### 1.3 The prescribed fix for C-01 does not work

This is the most consequential correction, because following the review's instruction would have
produced a change that looks correct and fixes nothing.

> **Required change:** make delivery errors explicit per message/delivery call, without changing a
> global class attribute.

`ReporterDashboardsMailer` inherits Redmine's `Mailer`. Redmine's `Mailer.deliver_mail` — fetched
from `5.1-stable` and `7.0-stable` and **byte-identical on both** — is:

```ruby
def self.deliver_mail(mail)
  return false if mail.to.blank? && mail.cc.blank? && mail.bcc.blank?
  begin
    # Log errors when raise_delivery_errors is set to false, Rails does not
    mail.raise_delivery_errors = true
    super
  rescue => e
    if ActionMailer::Base.raise_delivery_errors
      raise e
    else
      Rails.logger.error "Email delivery error: #{e.message}"
    end
  end
end
```

Redmine already sets the per-message flag on every message, and then consults the **global** to
decide whether to re-raise. A per-message setting is therefore inert here: the message-level flag
makes `Mail` raise, and Redmine's own `rescue` swallows it anyway based on the class attribute. The
fix had to move the decision onto the mailer **class** instead (§2.1).

A thread-local was also not available: `script/gates/no_thread_local.sh` forbids `Thread.current`
under `app/` and `lib/`, and the review did not account for that constraint.

### 1.4 R-04 understates itself

The review says to "make `VENDOR_INTEGRITY_MODE=strict` part of the main gate afterwards", which
implies the gate ran in warn mode in CI. It did not run in CI at all:

```
$ grep -rn "vendor_integrity" .github/
$ echo $?
1
```

The gate existed, was correct, named both real violations, and exited 0 — and nothing anywhere
called it. That is why the two CDN examples survived: not a lenient mode, an unwired gate.

### 1.5 Minor factual drift

Immaterial, listed for calibration: repository size is 14 MB excluding `.git`, not ~18 MB; the test
tree is 67,131 lines, not ~64,000. Ruby under `app/` + `lib/` is 39,211 lines, matching the
review's ~39,000. Ten migrations, nine locales, GET-only share links: all confirmed as stated.

---

## 2. Findings acted on

All work is on `claude/next-session-prompt-it4too`. Five commits: `9a10a42`, `6b784dd`, `3af91c4`,
`0cd5305`, `28e6b93`.

### 2.1 C-01 — process-global mail mutation — FIXED (`9a10a42`)

**Confirmed as described**, and the codebase had already documented why it was wrong. The helper in
`adhoc_delivery.rb:302-308` was a copy of the one in `scheduled_delivery.rb:311-317`, whose comment
reads:

> It is a class attribute, so this is process-global for the duration. Acceptable here and stated
> rather than hidden: the scheduler is a rake-task component, and the window is one occurrence's
> sends.

The ad-hoc path is reached from `MailController#create` — a web request — and inherited the
mechanism without the justification.

**Fix.** `ReporterDashboardsMailer.deliver_mail` is now Redmine's method with the `rescue` deleted,
reaching Rails' own implementation past Redmine's override through a captured `UnboundMethod` rather
than reimplementing it. `with_delivery_errors_raised` is deleted from both delivery paths. Errors
from a report mail are now a property of the mailer class rather than of a moment in time; nothing
else in the process is affected because nothing else delivers through that class. Redmine's
blank-recipient guard is preserved and still returns `false`.

**Evidence.** New file `test/unit/reporter_dashboards_mail_delivery_errors_test.rb`, 6 tests. It
drives `.deliver_mail` directly — the seam being changed — so the delivery block can raise
`Net::SMTPFatalError` without an SMTP server and, for the concurrency case, hold the delivery window
open on a latch. **The concurrency test is therefore deterministic, not a provoked race**: an
unrelated Redmine mail is delivered at the exact instant the old implementation had the flag set
process-wide. This is a stronger construction than the "barrier-based concurrency regression test"
the review asked for, which would still have been probabilistic.

Mutation-tested. Reinstating the window kills exactly three tests and leaves green the three that
assert unchanged behaviour:

| test | clean | mutated |
|---|---|---|
| `…does_not_touch_the_global_flag` | `false` | `true` |
| `…unrelated_mail_keeps_its_own_error_policy…` | `:swallowed` | `:raised` |
| `…two_concurrent_report_sends_cannot_corrupt_the_flag…` | `false` | `true` |

The middle row is the review's stated harm, reproduced.

The two pre-existing tests that asserted the global was *restored* now assert it is never written.

### 2.2 C-03 — timezone-blind attachment date — FIXED (`9a10a42`, tests in `0cd5305`)

**Confirmed**, and it was the only ambient-clock call in a business path: `query_aggregator.rb:1213`
already reaches for `Time.zone.today` and `scheduling/occurrences.rb:29` carries a comment forbidding
`Date.today` outright. Now `actor.today` — Redmine's `User#today`, which reads the zone from
`UserPreference`.

Severity dissent: the review rates this SHOULD. It is an attachment filename. It was fixed because
it is three lines and an internal inconsistency, not because it gates anything.

**Evidence.** Two functional tests on the same instant seen from two zones — `2026-08-14 22:30 UTC`
is already the 15th in Tokyo and still the 14th in New York, so **no server clock setting can satisfy
both**. Mutating back to `Date.today` kills the Tokyo half (`2026-08-15` → `2026-08-14`) and leaves
New York green, which is the point of the pair.

### 2.3 C-04 / R-04 — CDN examples — RETIRED (`6b784dd`)

**Confirmed**, and worse than reported (§1.4).

**Retired rather than migrated**, which the review offered as an equal option. Pointing them at the
vendored library was never available: it is Chart.js **4.5.0** and these are Chart.js **2.8**
configurations, so a URL swap produces two examples that load and draw nothing. Rewriting meant
converting 800 lines of a third party's dashboard to `{% chart %}`, and the result would still be an
800-line dashboard — which `starter_gallery.rb` already argues at length is the worst possible first
template. They taught a third obsolete thing the review did not name: a `window.status` readiness
handshake for wkhtmltopdf. `starters/chart-report.liquid` and `starters/version-status.liquid` cover
the same two reports on the supported surface.

The frozen copies under `docs/plan/reference/example-template-*.liquid` are untouched and remain
outside the gate's scan roots — `verification-liquid-js-escaping.md` cites line numbers into them.

`spec/shipped_templates_lint_spec.rb` loses its ratchet (the debt is gone, not reduced) and gains an
absence assertion per retired file. 19 examples → 13: the 8 over the deleted files become 2. README's
four pointers now go to the starters.

### 2.4 C-08 / R-07 and R-06 — stale metadata — FIXED (`3af91c4`)

`init.rb`'s registration description no longer calls this an extension of another plugin.
`CONTRIBUTING.md`'s opening no longer contradicts its own §109, and now carries the
standalone-Bundler warning with the measured symptom rather than a paraphrase.

### 2.5 R-08 — warn-mode gates — FIXED (`6b784dd`)

**Confirmed exactly.** `script/gates/release.sh` is new: every gate at its release configuration in
one command, not stopping at the first failure. It differs from `ci.yml`'s `gates` job in exactly one
place, stated in both files: the CVE expiry is advisory on every push (a hard one turns every branch
red on a date rollover, and the cheapest unblock is an unexamined date bump) and hard in the release
wrapper, because a release is the one moment an unexamined acceptance must stop the build.

`vendor_integrity` was added to CI at `VENDOR_INTEGRITY_MODE=strict` — the actual hole.

The individual gates stay individual CI steps so a failure names itself in the Actions UI.
`release.sh --coverage-only` is a new CI step that runs no gate and asserts the wrapper accounts for
every script under `script/gates/`; that is what stops the two lists drifting, which is precisely
what happened to `vendor_integrity`. Negative-tested: an unaccounted-for gate makes it exit 1 naming
the file. It caught a real omission on first run.

Measured on the current tree: **11 gates, all passing at release configuration.**

---

## 3. R-01 — Gotenberg — CLOSED BY CURATOR DECISION, AGAINST THE REVIEW'S RECOMMENDATION (`28e6b93`)

The review's factual account is correct and was reproduced: the scan is red on every commit of the
branch, 41 advisories found, 38 on no list, and the pin cannot move because `gotenberg/gotenberg:8`
and `:8.35.0` resolve to the already-pinned digest. The review's boundary analysis is also correct
and well argued.

**The recommendation was not taken.** The review proposed three options — move the pin, remove
Gotenberg from the supported surface, or accept the 38 findings individually — and recommended the
second, with "GO for a controlled pilot with Gotenberg explicitly excluded".

The curator's decision is a fourth option, and it is a **scope** argument rather than a security one:

> Gotenberg is an external component. This repository does not bundle it, does not start it, and
> never auto-selects it. Which PDF renderer to run, and what vulnerability posture to accept in it,
> is the deploying administrator's decision on their own estate. A red cell here made a third
> party's Chromium CVE read as a defect in a plugin that ships none of the bytes and can fix none of
> them.

**Gotenberg therefore remains a supported renderer.** The nightly scan now carries
`continue-on-error: true` on its gate step: it reports, it does not block.

This is a deliberate departure from `CLAUDE.md` §7 ("never make a hard gate advisory to get to
green"), and it is recorded **in §7 itself** so a later session reads the decision rather than the
rule and reverts it. It is explicitly not a precedent — the argument is specific to a component this
repository does not ship.

What did not change, because the reason for each survives the decision:

* the scan still runs nightly and still says exactly what it found, addressed to the operator who
  will decide whether to deploy the image;
* the allowlist keeps its per-CVE reasons and dates — the only place the reachability argument for
  each finding is written down;
* `cve_accepted_diff_selftest.sh` still **hard**-fails. "The gate can still say no" is a property of
  the script, and a broken script would silently report a clean image;
* `ci.yml`'s `gotenberg_accepted_cves` step is untouched and still **hard**. It validates the shape
  of *our* allowlist — a malformed record, a date that is not a day, an unbounded acceptance — which
  are mistakes in this repository's own file rather than facts about somebody else's image.

Two conditionals had to move with the change, and both would have failed silently. `Say what was
clean` was `if: success()`; `continue-on-error` masks the gate's failure from the job, so it would
have announced "no fixable HIGH/CRITICAL findings" over a scan that found forty. `What a red run
means` was `if: failure() && …`; `failure()` is now permanently false for this job, so the step
would have become unreachable dead code. Both are now conditioned on `steps.gate.outcome`, which is
the result before `continue-on-error` is applied.

**For the review engine:** treat R-01 as a closed product decision, not an open blocker. A future
review may reasonably note the residual risk to an operator who deploys the pinned image; it should
not re-raise it as a release blocker for the plugin, and it should not recommend making the workflow
hard again.

---

## 4. Findings not acted on, with reasons

### 4.1 C-02 — unbounded operator lists — DEFERRED, severity disputed

Confirmed as code facts: `templates_controller#index`, `schedules_controller#index`,
`share_links_controller#index` and `revoke_all` (which loads all unrevoked links, filters in Ruby via
`.select`, then issues one `UPDATE` per link).

The review rates all four SHOULD. Two of them are not risks: templates and schedules per project are
authored by humans and bounded in practice at dozens. Share-link *history* is the one that genuinely
accumulates — every mint is a row — and `revoke_all`'s O(n) writes ride on it.
`ShareLink#revocable_by?` (`share_link.rb:312-320`) is trivially expressible in SQL (admin → all;
otherwise `created_by_id = :id OR templates.author_id = :id`), so the bulk update is available when
this is picked up.

Deferred rather than done: it is not a correctness defect, and it was outside the scope agreed for
this pass.

### 4.2 C-05 — hotspot files — NOT SCHEDULED

Agreed as an observation, rejected as scheduled work. The review's own instruction ("do not launch a
generic service-object rewrite", "extract one stable policy on the next real change") is the correct
handling, and that is opportunistic by definition. Listing it under "should have for a maintainable
1.x" invites exactly the speculative refactor the same paragraph forbids.

### 4.3 C-06 — incident history in comments — REJECTED as scheduled work

This is a taste call presented as a defect, and acting on it would have cost this pass its best
evidence. The comment in `scheduled_delivery.rb` explaining *why* the process-global window was
acceptable in a rake process is what proved C-01 was a copy-paste of a justified pattern into an
unjustified place. A reviewer with only "the current contract" would have had to re-derive that.

The comment volume is real and the cognitive cost is real. It is not release work, and a future
review should not carry it as a maintainability finding with a priority label attached.

### 4.4 G1 "FAIL for broad production readiness" — DISPUTED

C-01 was a genuine defect and is fixed. C-03 was an attachment filename. Rating correctness FAIL on
those two overstated it, and the review's own §13 sequence ("Do not enable ad-hoc mail in a
multi-threaded production web process until C-01 is fixed") is the accurate and actionable form of
the same statement. A green single-threaded suite indeed did not close C-01 — a deterministic
two-threaded one now does.

---

## 5. Still open

| # | Item | State |
|---|---|---|
| R-02 / C-07 | Browser-driven suite for the primary journeys | **open — in progress** |
| R-03a | README split (still 2,623 lines; no user/admin/authoring guides) | **open** — the review closed this in error, see §1.1 |
| R-03b | Recorded keyboard / screen-reader / theme / zoom walkthrough | **open** — needs a human; cannot be automated and must stay advisory |
| R-05 | Production-like load, retention and rollback measurement | **open** — needs an environment this repository does not have |
| C-02 | Bounded operator lists, SQL bulk revoke | **deferred**, see §4.1 |

---

## 6. Verification of this response

Everything asserted above was run, not inferred.

**Full plugin suite**, Redmine `6.1-stable`, PostgreSQL, **standalone** (no `redmine_reporter`
present, which is the configuration that proves the dependency has not returned):

```
1050 runs, 4917 assertions, 0 failures, 0 errors, 4 skips
```

The 4 skips are the report-widget tests that skip with a reason when reporter is absent, matching
the documented inventory — G10 holds.

**DB-less RSpec**, before and after, to establish that no new failure was introduced:

```
60ee3e8   3253 examples, 271 failures, 161 pending
this tree 3247 examples, 271 failures, 151 pending
```

The 271 are pre-existing environment failures in this container (no ActiveRecord, no Redmine); the
count is identical, so the change introduces none. The example delta is accounted for exactly: 8
examples over the two retired files become 2 absence assertions.

**Gates:** 11 of 11 pass at release configuration via `script/gates/release.sh`.

**CI** on `0cd5305`: 27 jobs, 0 not green, including the two new steps (`vendor_integrity` strict,
`release wrapper covers every gate`).

Both fixes were mutation-tested, and the mutation results are in §2.1 and §2.2 rather than being
summarised as "tests pass".

One defect in this work was found only by running it: the new test file's private helper was named
`message`, which overrides `Minitest::Assertions#message(msg = nil, ending = nil, &default)` and
turned every assertion in the file into `ArgumentError: wrong number of arguments (given 2, expected
1)` — five errors whose backtrace pointed at the helper and said nothing about the collision. It is
recorded in the file, because it is the kind of thing static review cannot see.
