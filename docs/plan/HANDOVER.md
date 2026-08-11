# Handover — what a fresh session cannot work out from the code

Everything else in `docs/plan/` describes the *plan*. This file records what was learned
by **running** it: traps that cost a session real time, work that looks broken and is
not, and what has actually been executed versus merely claimed.

It is not a diary. If something here stops being true, delete the entry — a stale
handover is worse than none.

**Where the rest of the state lives:** `implementation-plan.md` §Status (what landed),
`CLAUDE.md` (how to work), `reference/verification-*.md` (measurements), and the commit
messages, which carry the reasoning for every non-obvious decision.

---

## 1. Traps in this codebase

Each of these produced a green run that meant nothing. They are ordered by how easily
they fool you.

**NEVER `git add -A` WHILE A SUBAGENT IS LIVE. A MUTATION HARNESS EDITS THE TREE BY DESIGN,
AND A COMMIT CANNOT TELL A MUTATION FROM AN EDIT.** This reached the remote on 2026-08-09:
`d57a744` shipped `request_geometry` hardcoded to A4/portrait with `margins_mm` dropped —
every report would have ignored its template's page geometry — because a stop hook prompted a
commit while three review subagents were running. The mutation was ALREADY COVERED; two
existing examples fail against it, which is how the reviewer's own harness scored it red.
Coverage was never the gap. What failed was verification of the COMMIT: seven lines were
grepped in two files, `request_geometry` was not one of them, and the result was reported as
"the committed source is unmutated" — a claim broader than its evidence. Two rules. Snapshot
the intended tree BEFORE launching review agents and diff the whole thing against that
snapshot, never spot-check lines. And if a commit genuinely cannot wait, stage EXPLICIT PATHS
the agents do not touch (docs, locales) rather than everything.

**A SUITE RUN FROM A COPY WITH NO `.git` SILENTLY SKIPS GATE G7, AND THE PENDING COUNT IS THE
ONLY PLACE IT SHOWS.** The ten `spec/golden` byte-identity examples (`RrdGolden::Baseline`,
`RrdGolden::KernelException`) resolve the `v0.5.0` baseline **through git**, so in a `git archive`
extract — or any copy made with `rsync --exclude .git/`, which is the isolation recipe §3
recommends and which most measurement in this project uses — they skip with a reason and the run
still says *0 failures*. That is **G7, the byte-identity gate**, the one irreversible thing in this
plan. Measured 2026-08-11 on the same tree: the real working directory gives `2671 examples, 0
failures, 127 pending` and a `git archive` extract gives `2670 examples, 0 failures, 137 pending`,
differing by exactly those ten. **A `137 pending` number in this file or in a session log is a run
that did not check G7** — several earlier ones are exactly that. Two rules. Report G7 from a run in
a directory with `.git` present (`rspec spec/golden` is 71 examples and takes 0.2 s, so there is no
excuse), and when a pending count moves, diff the pending LISTS before attributing it to your
change — that is how this was found, after first assuming the change had caused it.

**A PLANTED LOCALE KEY LOSES TO A SHIPPED ONE, AND IT HAS NOW COST TWO ROUNDS IN ONE TASK.**
`I18n.backend.store_translations` over a key this plugin already ships gives back the SHIPPED
value, so an example asserting the plant fails against a sentence nobody in the test wrote —
and it fails at the moment somebody adds the real translation, which reads as a regression in
unrelated work. Both instances were the same shape: `text_reporter_degradation_*`. **Plant an
invented key** (`…_rrd_probe`) and assert the shipped ones separately, against their real
values.

**A COLLECTION THAT HOLDS TWO CLASSES IS A DUCK-TYPING BUG WAITING FOR THE SECOND ONE TO
ARRIVE, AND `Outcome#degradations` HOLDS TWO.** `Liquid::Diagnostics::Degradation` answers
`code`/`detail`/`data`/`count`; `Render::Degradation` answers `capability`/`detail` and
**nothing else**. They are separate deliberately (`liquid/diagnostics.rb` argues it), and
`ReportRun` concatenates them into one list that one ERB loop renders.
`reporter_degradation_text` read `#code` off both for a whole generation, so **every
`wkhtmltopdf` render 500'd the preview and show pages** — that adapter stamps
`Degradation(:legacy_engine)` into every `Success` by design, and the partial's own comment
says so. §Findings **E-25**. Two rules. When you concatenate, ask what the OTHER element type
answers — `respond_to?` in a console beats reading two class definitions. And a rescue list
(`I18n::MissingInterpolationArgument, ArgumentError`) is not a safety net: the exception that
actually happened was `NoMethodError` and it went straight past.

**A PERMISSION GRANT IS NOT A VISIBILITY SETTING, AND FIXTURE ROLE 1 IS `issues_visibility:
all`.** Cost F-16 one round. The `grant` pattern (`role.permissions = [...]`) is the readable
way to say "holds ONE permission" — and it leaves `issues_visibility` alone. Role 1 is
Manager and ships `all`, so jsmith sees every private issue in every project he is a member
of, and two tests whose entire subject was *an attachment the actor may NOT see* were
vacuous. They were caught only because each asserted its precondition
(`assert_not attachment.visible?(@actor)`) rather than trusting the fixture — which is the
habit, not the luck. Pin `role.issues_visibility` whenever the test is about who can see
what.

**`I18n.backend.store_translations` DOES NOT OVERRIDE A KEY THIS PLUGIN ALREADY SHIPS.**
Planting `text_reporter_degradation_aggregation_dimension_unknown` to test interpolation gave
back the shipped Dutch-neutral sentence, not the plant, and the example failed against a
string nobody in the test had written. A plant that competes with a real translation is
testing the backend's precedence rules. **Plant an invented key** (`…_rrd_probe`) and assert
the shipped ones separately.

**A GUARD WHOSE ONLY EFFECT IS "DO NOT CONSTRUCT THIS OBJECT" HAS NO BEHAVIOURAL SIGNATURE,
so mutating it always survives.** F-16's factory skips building `Assets::Fetcher` unless the
policy could use one. Mutating that to "always build it" was GREEN — and it is a genuinely
equivalent mutant, proved by CONSTRUCTING the difference rather than reading for it: the same
document carrying all five reference classifications resolved byte-identically
(`Resolution#to_h` equal) with a fetcher and without one, because `Resolver#fetched` consults
`policy.fetch_allowed?` before it ever looks at `@fetcher`. The guard is still worth having
(INV-8: the thing that holds the network should not exist under the default policy), so it
was made testable the way the `update_columns` entry below says to — **the claim is about the
CONSTRUCTOR, so assert on the constructor**: `Assets::Fetcher.expects(:new).never`, plus the
positive half, or `never` also passes against a factory that builds one nowhere.

**AN OBJECT INSTANTIATED AS AN ARGUMENT CANNOT BE INTERROGATED, AND THE CODE READS AS THOUGH
IT IS ALREADY ORDERED.** F-16's stated difficulty was "the asset binding needs the resolved
engine's CAPABILITIES, and the engine is chosen downstream". It was not downstream:
`with_pdf` already called `resolve_engine`. What it did was
`Renderer.new(engine: adapter.new, …)` — so the instance existed for exactly the length of
that expression and no variable held it. One local (`engine = adapter.new`) was the entire
"ordering change". Before planning work around a dependency that looks structural, check
whether it is only a missing binding.

**REDMINE SETS `include_all_helpers = false`, so a controller sees its OWN helper and nothing
else.** `config/application.rb:73`. Every core controller lists what it needs (`helper :journals`,
`helper :projects`, …) and this plugin's own `ReporterPreflightController` does too — which reads
as boilerplate until a view calls a helper from a different controller and 500s in production.
T-23's views used `reporter_dashboard_icon` (the D-3 `sprite_icon` shim, which lives in
`ReporterProjectPagesHelper`) and were fine in every controller test that had not been re-run,
because a controller test renders with the same helper set. **The integration test found it.** If
a view uses a helper the controller does not own, declare it.

**A `formmethod="post"` SUBMIT DOES NOT REMOVE THE FORM'S HIDDEN `_method`, and `Rack::MethodOverride`
reads the body.** A Rails form with `method: :patch` is a POST carrying `<input type="hidden"
name="_method" value="patch">`. A second submit button with `formaction`/`formmethod: 'post'`
changes the HTTP verb of the request and leaves that field where it is, so the middleware rewrites
`REQUEST_METHOD` back to PATCH before routing and a POST-only route 404s — for every user, every
time. T-23's Preview button did exactly this. **No `ActionController::TestCase` can see it**:
`post :preview` calls the action directly and never renders the form, sends its hidden fields or
passes through middleware. Route both verbs, and test a two-button form at the INTEGRATION level.

**A CONSTANT ASSIGNED INSIDE AN `RSpec.describe` BLOCK IS A GLOBAL, and the collision passes in
isolation.** The block is a closure whose lexical scope is the file's top level, so
`FIXTURES = File.join(__dir__, 'fixtures')` inside `describe` defines **`Object::FIXTURES`** for the
whole process. `spec/charts/golden_svg_spec.rb:50` already defines `FIXTURES` (a Hash of chart
fixtures) and `spec/shipped_templates_lint_spec.rb:36` already defines `ROOT`. T-36's first draft
added both names, and two of T-16's examples went red in the randomised full run for a reason that
had nothing to do with charts — `rspec spec/charts/golden_svg_spec.rb` on its own passed, every
time. Ruby prints no "already initialized constant" warning because the assignment happens in a
different file at load time and the values differ in type, not in constancy.

Use methods (`def fixtures_dir`) or `let`. And when a spec fails only in the full run, suspect a
constant before suspecting an ordering bug in the code.

**Minitest silently does not run test methods defined after `private`.**
`test/functional/reporter_project_pages_controller_test.rb` has a `private` section
partway down. Ten tests appended below it were never executed, and the file reported
44 runs while defining 53 test methods. Nothing failed; the tests simply did not exist
as far as the runner was concerned. **Check that the run count moved** after adding
tests — `grep -c '^  def test_'` against the reported `N runs`.

**The mirrored plugin copy has no git history.** `.codex/redmine_clone.sh` rsyncs into
`redmine/plugins/<name>/` with `--exclude .git/`. Anything that inspects history —
`spec/golden/baseline_spec.rb`, and the future `corpus` job — *skips* there, and a
skipped guard is indistinguishable from a passing one. Those checks must be run **from
the plugin checkout**. The `baseline` CI job does this and fails if they report pending.

**Editing inside `redmine/` is destroyed on the next run.** Same rsync, `--delete`. Edit
the plugin repo and re-run the script.

**The aggregator reads the clock, so a pinned fixture is not enough.**
`lib/redmine_reporter_dashboards/aggregation/query_aggregator.rb:1135` is its single clock read. Pin the corpus
reference date without freezing time and every period window comes back **0** — which
looks like a broken aggregator and is not. `RrdAdapterHarness.freeze_to_reference_date!`
does both, and must run before `seed!`. Good news for the corpus: that one read is
Ruby-side, and `:2099` records that the SQL deliberately carries no `CURRENT_DATE`
arithmetic, so freezing Ruby is sufficient — there is no database clock to keep in step.

**Byte-identity comparisons need byte reads.** `git show` hands back bytes;
`File.read` applies an encoding. Compared directly, one em-dash reads as a three-byte
difference that is not a difference. Use `File.binread` against raw git output.

**`File.read` on a UTF-8 source file fails where `LANG` is unset.** Ruby's default
external encoding follows the locale, and a bare container has none — so reading any
file in this repo that contains an em-dash raises `invalid byte sequence in US-ASCII`.
It passes on a developer machine and fails in a minimal container. Name the encoding:
`File.read(path, encoding: 'UTF-8')`.

**And it has a SECOND symptom that does not look like an encoding bug at all.** Hit
again in T-14: `Preflight` interpolated `File.read(chart_shell.js)` into a UTF-8 heredoc
and got `Encoding::CompatibilityError: incompatible character encodings: UTF-8 and
US-ASCII` — a different exception class, from a line that does no reading. **The same
applies to subprocess output**: `Open3.capture3` tags stdout with the default external
encoding too, so `pdftotext` output on a POSIX-locale host is US-ASCII and the first
accented character in a French document turns a regexp match into `ArgumentError`.
`PdfInspector.run` force-encodes to UTF-8 for exactly that reason. Rule: anything
crossing into this process from a file or a pipe gets its encoding named.

**Rails inserts every fixture set ANY test class in the process declares.** A class
that declares no `:issues` still finds Redmine's fixture issues in the database,
because another plugin test class declared them — and whether it does depends on the
order the classes ran in. Two of the scope-fixture tests were order-dependent on their
first run for exactly this reason, one passing and one failing in the same run. Do not
build a fixture on the ABSENCE of rows; restrict every query and every scope to the
records the test created, and assert that nothing resolved reaches outside them.

**A generating run writes into the MIRROR.** `RRD_CORPUS_WRITE=1` and
`RRD_SCOPE_WRITE=1` are executed from inside `redmine/`, so the files land in
`redmine/plugins/<name>/spec/golden/` and the next `redmine_clone.sh` deletes them.
Copy them back out before committing — `spec/golden/README.md` has the command.

**MariaDB truncates a returned column label at 256 characters, and ActiveRecord reads
grouped results back BY THE GROUP EXPRESSION'S TEXT.** Group on anything longer and
every key comes back nil, the result collapses into one bucket and the count is silently
wrong. This was defect D-1 (`implementation-plan.md` §Findings), and the COUNTING path is
**fixed** — `measure_groups` reads a counted axis positionally (`SELECT <expr>, COUNT(...)
... GROUP BY <expr>` through `pluck`) instead of through ActiveRecord's alias-keyed
`.count`. **The trap is not fixed for anything that still uses `.count`/`.sum`/`.average`
on a grouped relation**, which is every `measure:` — those key their results by the same
alias, and are still exposed past ~4 age boundaries. Deliberate, and in the README's
database section.

Note that shortening or aliasing the expression does NOT save you: the alias is derived
from the expression's text and is ALREADY truncated on PostgreSQL, which answers
correctly. The defect is the two ends *disagreeing* about the truncation, not the length.
**MySQL 8.0 does NOT do this** — it was written up as a MySQL-family defect and the first
CI run refuted that, which is why the overlay has a `mariadb` family separate from
`mysql`. That family survives the fix; the reason it exists is a property of the engines.

**Do NOT "fix" a long group expression by replacing the GROUP BY with one conditional
aggregate per bucket.** That was D-1's first attempt: it is correct, it removes the alias,
and it is dramatically SLOWER on MariaDB — the engine the defect is on. Measured in the
same CI job: `completeness.seven` (seven `COUNT(DISTINCT CASE …)` in one statement) costs
**25-50 s per call** at 10 000 issues where the grouped read costs **0.02 s**, and the
`adapter (MariaDB 11)` cell went from 5 m 39 s to over 35 minutes without finishing.
Query COUNT is identical either way, which is the only thing R7 measures — so **no gate in
this project can catch it**. Read the CI cell's wall clock.

**`|| true` on a search inside a gate cannot tell "clean" from "did not run", and one
of them is a lie.** Written fresh on 2026-08-05 while building `layer_purity.sh`: the
first version used `rg -nE "$pattern" "$path" || true`. **In ripgrep `-E` is
`--encoding`, not "extended regex"** — rg is always a regex matcher — so it exited 2
with `unknown encoding: Rails\.|ActiveRecord|...`, `|| true` swallowed the crash, and
the gate reported every layer clean. A deliberately planted `Issue.visible` in
`render/` went undetected. It was caught only because the gate was negative-tested
before it was wired up; nothing else would have found it, because the gate's normal
output looked perfect.

Two rules follow. **Negative-test a gate before trusting it** — plant the violation it
exists to catch and watch it fail. And in a gate, treat a search's exit status as
three-valued: 0 = matches, 1 = no matches, **anything else = the tool failed and the
gate knows nothing**, which must be loud. `layer_purity.sh`'s `search()` does this.
`no_thread_local.sh` and `zero_reporter.sh` still use `|| true`; their rg invocations
are valid so they do not fail today, but the hazard is the same shape and is worth
closing the next time either is touched.

**A LINT THAT LOCATES `<script>` WILL FIND ONE IN PROSE, and then it is confidently wrong
about hundreds of lines.** Cost T-19 two rounds (§Findings E-14). `HtmlScanner` skipped the
`{% comment %}` tag but not its BODY, so a comment explaining why chart data must not be
concatenated — prose containing the word `<script>` — opened a raw-text region running to the
next real `</script>`: **72 escaping findings in a template that had none.** And linting
`README.md` as one document produced **23 findings in Markdown**, because the sentence
describing the rule contains a backticked `` `<script>` ``.

Two rules follow. The scanner skips `{% comment %}` and `{% raw %}` bodies (also the correct
semantics — one is not rendered, the other is rendered literally). And **a README is linted
per fenced snippet, never as a document** — prose talks ABOUT tags and no scanner can tell
that from markup. Neither bug was findable by reading the scanner; both were found by
pointing it at real files and disbelieving the count.

**Every name `Liquid::Drop` uses is reserved on every subclass, and two of them have now cost a
session each.** `key?` (E-8) made every accessor on `NamedRefDrop` render EMPTY, because Liquid's
`VariableLookup` asks `respond_to?(:key?)` to decide whether a value is hash-like. `@context`
(E-12) is worse, because it is an IVAR rather than a method: `Liquid::Drop` declares
`attr_writer :context` and assigns it on every touch, so a drop storing its own object there both
loses it mid-render and breaks Liquid's `strict_variables` check. The symptom was
`NoMethodError: undefined method 'actor' for an instance of Liquid::Context`, raised from the
timezone helper — three frames from the cause, and reading like a bug in the wrong file. The
reserved set is `@context`, `key?`, `invoke_drop`, `[]`, `to_liquid`, `liquid_method_missing`, and
`context=`. Neither of these is findable by reading; both were found by rendering a real template.

**A relation is not the same object twice, and `equal?` on one is a cap that silently does not
apply.** `IssueQuery#base_scope` builds a fresh `ActiveRecord::Relation` every call.
`RenderContext#batch_for` compared with `equal?`, so a caller that passed one relation to the
context and another to the collection drop got a SECOND `Batch` — with the default 5 000 cap
instead of the configured one, and duplicate queries for every key. Nothing raised. Compare by
`to_sql` (E-13). The test only caught it because it deliberately built the two relations
separately; write cap tests that way.

**Ruby's `IO.pipe` hands the CHILD a non-blocking descriptor, and Chromium hangs up on it.**
`O_NONBLOCK` lives on the open file description, so a child inherits it — and Chromium's
`--remote-debugging-pipe` reader treats the resulting `EAGAIN` as a closed connection. It answers
**exactly one command**, logs "Connection terminated while reading from pipe", and exits. The
symptom is a browser that replies to `Browser.getVersion` and dies on whatever you send second,
which reads as a CDP protocol error, a version incompatibility, or a message-framing bug — it is
none of those. Clear the flag on both child-facing ends before `Process.spawn`
(`CdpClient#blocking!`). Cost: about an hour, most of it spent suspecting the protocol.

**Chromium will not run as root, and that is the design working.** `--no-sandbox` is deliberately
never set, so the browser itself enforces "render as a non-root user". In this container you ARE
root, so the conformance corpus and anything else that draws a PDF has to be run as somebody else:

    useradd -m rrd && chmod -R a+rX . && su rrd -s /bin/bash -c '… rspec spec/conformance'

Two consequences worth knowing before you lose ten minutes to each. The repository must be
world-readable (`chmod -R a+rX`) or the run fails on a file it cannot open, and **`RRD_MATRIX_WRITE=1`
needs `docs/` writable by that user** — otherwise the matrix regeneration fails with `EACCES` from
inside an rspec example, which reads as a spec bug.

**The conformance harness needs poppler, and says so rather than skipping.** `pdfinfo`,
`pdftotext` and `pdftoppm` (`apt-get install -y poppler-utils`). A missing probe is an ERROR: a
matrix generated without them would still print PASS for every check that never ran.

**A poppler-less run is a DIFFERENT run, and the four `rspec` CI jobs are one.** Two preflight
examples passed locally and failed on all four branches because they inherited whether poppler
happened to be on PATH. Reproduce the CI environment before pushing:

    env PATH="$(python3 -c "import os;print(os.pathsep.join(d for d in os.environ['PATH'].split(os.pathsep) if not os.path.exists(os.path.join(d,'pdfinfo'))))")" \
      ruby -e "require 'rspec/core'; exit RSpec::Core::Runner.run(['spec/render','-I','spec'])"

The rule is CLAUDE.md §6: an example about a check's *reasoning* stubs `PdfInspector.available?`
rather than inheriting it. Only examples that genuinely need real probes may skip on their absence.

**CORRECTED 2026-08-06 — wkhtmltopdf IS installable here, but there are TWO BUILDS and only one
of them is the engine.** This entry used to say the package "is gone from Ubuntu 24.04's archive and
only exists as a release `.deb`", concluding `:wkhtmltopdf` was CI-only. The premise is nearly right
and the conclusion is wrong.

| build | how you get it | footers (what was MEASURED) |
|---|---|---|
| `wkhtmltopdf 0.12.6` | `apt install wkhtmltopdf` (noble/universe) | **NO** — built against unpatched Qt |
| `wkhtmltopdf 0.12.6.1 (with patched qt)` | the release `.deb` — what `ci.yml:750` installs | yes |

Footers only. Upstream documents unpatched Qt as lacking headers too, but the corpus has no header
fixture, so do not widen that row without one.

**Install the release `.deb`. The jammy asset works on noble, and there is no noble asset:**

    curl -fsSL -o /tmp/wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb
    sudo apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb
    sudo apt-get install -y poppler-utils    # the corpus needs pdfinfo/pdftotext/pdftoppm

**THE TRAP, and it cost a wrong finding in a pushed commit.** `apt install wkhtmltopdf` succeeds and
gives you a binary that passes **17 of 20** conformance fixtures. The one failure is the footer
fixture, and it looks exactly like a defect in `wkhtmltopdf.rb` — page 1 with no footer. It is not:
that build discards every `--footer-*` flag and says so on stderr ("is not support using unpatched
qt, and will be ignored") — loud enough to read, quiet enough to miss in a corpus run. A plausible result from the wrong binary is this repository's
favourite failure mode; **check `wkhtmltopdf --version` says `(with patched qt)` before attributing
anything to the code.**

With the right build: `chromium_cdp` **20 pass / 0 fail / 0 skip**, `wkhtmltopdf` **18 pass / 0 fail
/ 2 skip** (the two are `:readiness_expression`, accounted for by §Findings E-5). **The curator
promoted it to `verification: corpus` on 2026-08-06** on exactly that evidence, and the matrix was
regenerated from the run. So the build you have decides whether the corpus is green: on the DISTRO
build it is 17/1/2 and the footer fixture fails, which is now a HARD failure rather than an
unenforced report. Check `wkhtmltopdf --version` says **"with patched qt"** before believing a red
run.

**And a second stale-index trap underneath the first:** the container's apt index is old, so the
first `apt-get install` of anything large fails with a wall of `404 Not Found` on unrelated
dependencies (`libinput10`, `udev`, `avahi`). That reads as "the archive no longer carries this" and
means `apt-get update`.

**MySQL 8 evaluates `projects.<col> IN (SELECT …)` inside a LEFT JOIN's ON clause as
TRUE.** Measured on 8.0.46 (E-1 in §Findings). An entitlement check written that way
passes for everyone, silently, on that engine only. `issues.project_id IN (SELECT …)` and
a literal `projects.id IN (1,2,3)` are both correct everywhere — and both are what
Redmine actually emits, so no production path is affected. If you are writing a stubbed
visibility condition, copy Redmine's shape rather than inventing an equivalent one; the
harness did, and MySQL then made the harness lie about visibility.

**CORRECTED 2026-08-05 — a plugin's `lib/` is NOT autoloaded, so path-to-constant
agreement is not required there.** This entry used to say the opposite, and T-08's kernel
move measured it: the two kernel files now live at
`lib/redmine_reporter_dashboards/aggregation/` while still declaring
`module SqlAggregation`, and the full application boots (139 minitest runs, 0 errors).
Measured inside the booted app:

    Rails.configuration.respond_to?(:autoloader)                -> false  (Rails 7.2)
    plugin lib/ in ActiveSupport::Dependencies.autoload_paths    -> false
    plugin lib/ in Rails.application.config.eager_load_paths     -> false

Two things follow. `init.rb:20-21`, which tells Zeitwerk to `ignore` this plugin's `lib/`,
is **dead code on Rails 7+** — the `respond_to?` guard is false, so the ignore never runs
— and it does not matter, because Redmine does not put a plugin's `lib/` on either path in
the first place. Only `app/` is autoloaded, and THERE the constraint is real.

An earlier session did record a genuine `Zeitwerk::NameError` from
`lib/redmine_reporter_dashboards/compat/base_record.rb`, and this correction did not explain
it — it only showed the stated mechanism could not be it. **T-10 reproduced it cleanly on
2026-08-05 and it is REAL:** `render/result.rb` defined only `Success` and `Degradation`, and
the full application refused to boot with

    expected file .../render/result.rb to define constant
    RedmineReporterDashboards::Render::Result, but didn't (Zeitwerk::NameError)

So **path-to-constant agreement IS enforced for this plugin's `lib/`**, whatever the three
`false` measurements above say about autoload paths — they were taken from inside a booted
app and evidently do not describe what Zeitwerk scans at boot. Do not resolve the
contradiction by trusting either half: **name every file under `lib/` after the constant it
defines** and the question never arises. `compat.rb` is one file for this reason, and
`result.rb` now defines a `Result` module as well as the two classes.

**AND A THIRD MEASUREMENT ON THE SAME QUESTION, 2026-08-09: A CONSTANT UNDER THIS
PLUGIN'S `lib/` RESOLVES BY AUTOLOAD.** The entry above has been corrected twice and still
left a reader unsure what is true. T-29 measured the remaining half directly, in a booted
application that had touched nothing:

    loaded before touch? false
    resolved            : RedmineReporterDashboards::Reporting::BundleReport
    loaded after touch?  true

`reporting/bundle_report.rb` is required at boot by nothing — deliberately, it is a rake
formatter — and naming the constant loads the file. So the practical rule is unchanged and
now has a reason on both sides: **name every file under `lib/` after the constant it
defines**, because the loader will both ENFORCE that (T-10's `Zeitwerk::NameError` on
`result.rb`) and USE it. Two consequences worth knowing. A missing `require` in a test can
hide behind the autoloader, so "it passes alone" does not prove the requires are right —
T-29 wrote a finding claiming the opposite and negative-testing refuted it. And a
load-time reference to an autoloaded constant from a file being `require`d is still a real
hazard, which is why `bundle_import.rb` reaches its model through a method rather than a
class-body constant.

**Redmine 6.0 is where BOTH `ApplicationRecord` and `IconsHelper#sprite_icon` arrived.**
Neither exists on 5.1, and calling either raises rather than degrading. Both were in this
plugin from v0.5.0 (D-2, D-3). If you add anything that touches a Redmine core class or
helper, check when it appeared — `git -C redmine ls-tree origin/5.1-stable <path>` answers
it in one line, and the 5.1 minitest job answers it for real.

**Every aggregator entry point LOGS AND DEGRADES on an argument it cannot use.** An unknown
completeness field, a custom field the viewer may not see, a `group_by` that does not resolve — all
produce `Rails.logger.warn` and a smaller answer, never an exception. That is right for a template
author and silent for anything that measures. T-03's `completeness.seven` asked for two field names
the kernel does not accept and measured a five-field panel under a seven-field name for a whole
generation of the baseline artefact. **If you write anything that runs the kernel and reads a number
off it, pin the SIZE of the answer as well as the number** — `PerformanceCases::EXPECTED_RESULT_SIZE`
is that control, and the reason it exists.

**`.flags` returns `'buckets' => []` on purpose.** Its shape is `stages`; the empty array is there so
a template looping over buckets renders nothing rather than raising. Anything that measures "how big
was the answer" off `result['buckets'].length` therefore reports the flag funnel as **zero** and the
period series (which has no buckets at all) as its hash key count. `Performance.result_size` is
shape-aware for this reason; copy it rather than re-deriving it.

**Timings are measured with `CLOCK_MONOTONIC`, and they have to be.** The bench runs under the
corpus's frozen clock (`travel_to`), which stubs `Time.now` — a wall-clock timing there measures
**zero** for everything. The same applies to the artefact's `measured_at`, which reads
`CLOCK_REALTIME`: `Time.now` under the pin would stamp it with the reference date, a plausible-looking
lie about when the measurement happened.

**`rails` is `null` in the performance artefact's provenance, and that is correct.** The adapter
harness boots ActiveRecord *without* Rails and defines a stub `Rails` module carrying only `.logger`,
so `Rails::VERSION::STRING` genuinely does not exist in that process. `active_record` is the
load-bearing figure there.

**A SHALLOW CLONE makes gate G7's baseline specs FAIL, and the failure reads as a real
G7 violation.** Cost 20 minutes on 2026-08-06. A cloud session starts from
`git clone --depth 1` with no tags, so `Baseline::COMMIT` (`eddb8fa…`) is unreachable and
nine examples in `spec/golden/` go red with *"lib/sql_aggregation/drill_through.rb is
unreadable at the baseline commit"* — which is precisely what a genuine byte-identity
breach would say. The fix is one command, and it should be the FIRST thing tried:

    git fetch --unshallow origin

Note the difference from the mirror case above: inside `redmine/plugins/<name>/` there is
no `.git` at all and the examples *skip*. Here `.git` exists and is incomplete, so they
FAIL. Two environments, two symptoms, one cause. Do **not** "fix" it by editing the SHA —
`baseline.rb` says why in as many words.

**RAILS' PARTIAL WRITES MAKE "IT WROTE ONLY THESE COLUMNS" UNTESTABLE BY READING THE ROW
BACK.** Found by mutation testing on 2026-08-07, while paying S-7's inherited obligation in
T-25's runner ("write run state with `update_columns` … so the runner and the form cannot
overwrite each other's columns"). The behavioural example looked right: an administrator
disables the schedule mid-delivery, and afterwards it is still disabled. It passes with
`update_columns` — **and it also passes with `assign_attributes` + `save`**, because Rails
only writes CHANGED attributes, so the runner never names `enabled` either way. A full-row
write and a two-column write leave an identical row behind whenever nobody edited it in
between, which is every test run.

The claim has to be made about the STATEMENT, not the row. Subscribe to
`sql.active_record`, find the UPDATE, and assert which columns it names — `updated_at` is
the tell, because `update_columns` does not touch it and every `save`-shaped write does.
Generalises past S-7: any claim of the form *"this write is narrow"* needs the SQL.

**AN "INVALID RECORD" PRECONDITION IS VACUOUS WHEN THE CODE UNDER TEST OVERWRITES THE
INVALID COLUMN.** Same afternoon, same file. To show `update_columns` records a failure on a
row that can no longer be saved, the first version made `last_status` invalid — the column
the runner *writes*. `update!` assigns the new valid value before validating, so the record
saves and the example proves nothing. Pick a column the code does not touch.

**`update_columns` DOES NOT RAISE FOR A COLUMN OMITTED FROM A `select`, so that is not a way
to simulate §7 rule 5's absent column.** Measured on Rails 7.2:
`Schedule.select(column_names - %w[next_run_on]).first.update_columns(next_run_on: …)`
**succeeds** — the attribute is missing from the row but its type is still known to the
class. Drop the column for real and `reset_column_information`, and the true failure mode
appears: `ActiveModel::MissingAttributeError: can't write unknown attribute`. But DDL inside
a test transaction is rolled back by PostgreSQL and **implicitly committed by MySQL**, so
doing that in a test wrecks the schema for everything after it on one of the two supported
engines. Assert on the emitted UPDATE instead.

**AN EXCEPTION RAISED IN A RESCUE CLAUSE IS NOT CAUGHT BY THAT CLAUSE, and the obvious
per-item rescue therefore does not survive its own error path.** T-25's runner had a
12-line comment explaining why FR-41 needed a guard around the state write in its rescue
body, and still shipped a hole: the rescue body was two statements, `record_failure` then
the guarded write, and only the second was covered. `record_failure` does I/O — it logs,
including a whole backtrace. The independent review measured it with a logger whose `warn`
raised `Errno::EPIPE` (a closed log pipe, a full log volume): the raise left `#call`
entirely and the next schedule never ran. **The guard's own rescue logged too.** If a loop
must continue past an item's failure, every statement in the rescue body has to be
non-throwing, and the cheapest way to get there is to make the LOGGER non-throwing at its
one choke point rather than wrapping six call sites.

**AN INJECTED SCOPE MADE THE ALTERNATIVE TO A FILTER SILENTLY DROPS THE FILTER.**
`(@schedules || Schedule.where(enabled: true))` reads as "the caller's scope, or all the
enabled ones" and means "the caller's scope, unfiltered". The test that looked like it
covered this only ever ran the default branch. Write `(@injected || Model.all).where(...)`
so the constraint is on both, and add the example that injects a row the filter should
reject.

**A LOCAL DATE CAN MOVE BACKWARDS, AND A UNIQUE INDEX ON IT CANNOT SEE THAT.** T-25 keys
its at-most-once guarantee on `(schedule_id, occurrence_date)` where the date is the
schedule's own timezone-local date. Retimezone a schedule westward — or step the clock
back across local midnight, or restore a snapshot — and the same wall-clock day produces a
DIFFERENT `occurrence_date`, which the index has no grounds to refuse. Measured:
Auckland → America/Los_Angeles between two ticks one UTC hour apart produced run rows for
both 10 and 11 March and walked `last_run_on` backwards, which also drops the catch-up
floor. A uniqueness constraint is only as strong as the stability of the value it is on.

**A DIAGNOSTIC BUILT ON A COLUMN THE HAPPY PATH DOES NOT WRITE IS RED ON A HEALTHY
INSTALL.** T-25's FR-44 heartbeat asked `last_attempted_at IS NULL` to mean "no tick has
run". The runner writes that column only when it CLAIMS an occurrence — a monthly schedule
is claimable one day in thirty — so a correctly configured installation printed *"it looks
like nothing is calling it"* every morning for a month, and `schedules:status` exited 1 the
whole time. Caught as a BLOCKER by an independent review, measured over four consecutive
daily ticks. Before deriving a health signal from a column, ask which code paths write it
and how often; the right column here was `next_run_on`, which every tick refreshes whether
it delivers or not. And when the derivation has known blind spots, enumerate them as
conditions rather than describing them in a comment: this one needed three, and each removes
a false positive that was measured.

**AN OPTIONAL LOG LINE IS A RESCUE PATH.** The same review found `warn_line` raising
(`Errno::EPIPE` from a closed pipe, `ENOSPC` from a full log volume) escaping a rescue
clause and embargoing every later schedule. That is the second time in one task the pattern
bit: **anything a rescue body calls is part of the rescue's correctness**, including
logging, including a second rescue's own logging. The fix is one non-throwing choke point,
not six `begin`s.

**A FIELD THAT NAMES A USER IS A PRIVILEGE FIELD, AND `permit` IS NOT A FILTER.** T-25's
schedule form put `render_as_user_id` — the column that decides **whose visibility the SQL
runs under** — straight into `params.permit`, next to `apply_template` and `apply_query`,
which exist precisely because permitting an id lets a request name something the actor may
not have. An independent review posted `render_as_user_id=1`, pressed "Send a test", and
received an ADMINISTRATOR-visibility report containing a private issue the attacker could
not see. It was also plantable in two steps, because the id was stored even while the policy
said `author`.

Two things generalise. **The picker is not the check** — a `select` narrowed to project
members proves nothing about what the controller accepts. And **"a project member" is not a
safe bound for an identity field**: every member with wider visibility than yours is an
escalation target, so the first test written for this passed with the bound widened to the
whole project, because it happened to target an administrator (who is not a member). Pick a
target inside the wrong bound when testing one.

**TWO SAFE HALVES CAN BE AN EXFILTRATION PRIMITIVE TOGETHER.** The same review found a
second escalation needing NO parameter tampering: `#test_send` rendered as the schedule's
stored identity (FR-45, correct) and delivered to whoever pressed the button (convenient,
correct in isolation). Any schedule authored by an administrator could therefore be
test-sent by any schedule manager, and the output landed in their mailbox. When an action
couples "act as X" with "deliver to Y", the requirement that fixes it is whichever of the
two is written down — here FR-45 — and the other half gives way.

**A GATE FLAG THAT CAN NEVER BE SWITCHED ON IS A COMMENT, NOT A TARGET.**
`ZERO_REPORTER_MODE=strict` meant *"ANY reference fails, allowlist or not"* and was described in the
script as "what 1.0 must pass" — while the curator had decided months earlier that the 1.0 target is
*empty except the importer*, because reading the base plugin's data by name is what the importer is
FOR. So the mode could not pass, ever, and T-26's `Accept:` said to switch it on. Fixed in T-26 by
making the exemption explicit and per entry (`[permanent]` in the allowlist's reason column) rather
than by widening the list. **When a gate has an aspirational mode, check it is reachable before
planning work that turns it on.**

**T-26's `Accept:` LIST WAS WRONG ABOUT THREE OF ITS FOUR ITEMS**, and the check took twenty minutes
of reading rather than any measurement — see the revised entry in `implementation-plan.md`. The one
worth remembering: `glue/legacy/` is NOT dead code. `Liquid::ScopeBinding#bind` routes to it whenever
there is no owned render context, which is every `{% sql_aggregate %}` inside a reporter-hosted
template. Deleting it degrades cleanly (the `const_defined?` check is real) — to *no scope resolved*,
silently, on exactly the installs the integration exists for. **Before deleting a "legacy" directory,
grep for the guarded fallback that still routes to it**, not only for hard references.

**A PDF THAT `pdfinfo` READS PERFECTLY CAN STILL BE MALFORMED, AND `pdftotext` PUTS THE
PROOF ON STDERR.** T-30 wrote an engine-free PDF writer. Its first output opened with
`%PDF-`, ended with `%%EOF`, was over the minimum size, and `pdfinfo` reported *Title,
Pages: 1, Page size: A4* with no complaint at all — every assertion a reasonable spec would
have made. `pdftotext` extracted the text too, **and wrote three syntax errors to stderr**:
*"Missing 'endstream' or incorrect stream length"*, *"Unknown operator
'endstreamendobj'"*. The cause was one absent newline — the stream object's body ends
`endstream` and `endobj` followed it directly, so the file carried `endstreamendobj`, which
is ONE TOKEN to a PDF lexer. The error names `/Length`, which is not the problem.

Two rules. **Read a generated PDF's stderr, not only its stdout** — poppler recovers from a
damaged file and tells you on the other channel, so a check that only looks at extracted
text passes on a broken document. And **`pdfinfo` alone is not a validity check**: it reads
the trailer and the catalogue and never touches the content stream.

**A MIGRATION THAT GROWS AN EXISTING TABLE MEETS A RECORDER THAT HAD NEVER SEEN ONE.**
`spec/migrations/schema_recorder.rb` implemented `create_table`, `add_index` and
`table_exists?` and nothing else, because migrations 001-007 each create a table. T-30's 008
is the first `add_column` in the plugin, and the recorder raised `NoMethodError` — which is
the module's own stated design working (an unknown DDL call must be loud), and
`script/migrate_updown.sh` correctly reported **G11 UNKNOWN rather than passing**. Worth
knowing twice over: the recorder gives every migration a **fresh instance**, so an
`add_column` cannot see a table an earlier migration created. It records a pending
alteration and the driver applies it against the accumulated schema; writing it the obvious
way raises on a perfectly correct migration.

**THE MINITEST SUITE LEAVES THE PLUGIN TABLES WITHOUT THEIR `schema_migrations` ROWS, AND
`migrate_updown.sh` THEN CANNOT START.** Known, and here is what it actually looks like from
the inside so the next session recognises it in one line rather than five. After
`rake redmine:plugins:test`, `schema_migrations` holds only `1-redmine_reporter_dashboards`
while tables 002-008 all exist. `migrate 0` therefore reverses only 001, the reinstall then
hits `PG::DuplicateTable: relation "reporter_dashboards_templates" already exists`, and the
gate reports FAILED — which reads as a broken migration and is a dirty database. Recovery is
to drop the orphans and run again:

    cd redmine && RAILS_ENV=test bundle exec rails runner \
      'c=ActiveRecord::Base.connection; %w[reporter_dashboards_documents \
       reporter_dashboards_schedule_recipients reporter_dashboards_schedule_runs \
       reporter_dashboards_schedules reporter_dashboards_template_versions \
       reporter_dashboards_templates_roles reporter_dashboards_templates].each { |t| \
       c.drop_table(t, if_exists: true) }'

Run the gates BEFORE the Minitest suite whenever a migration is touched, and this never
happens.

**AND A FAILED `migrate_updown.sh` RUN POISONS THE NEXT ONE, WITH A DIFFERENT MESSAGE.**
Second half of the same afternoon. After the run above failed on `PG::DuplicateTable`, the
next invocation's `preseeded` arm passed and its `fresh` arm failed with *"VERSION=0 left
plugin rows in schema_migrations"*, listing all eight — which reads as a broken
down-migration and is the previous run's wreckage. Reset **both halves** before believing
either arm: drop the plugin tables AND delete the `%-redmine_reporter_dashboards` rows from
`schema_migrations`, then run the script exactly once. From a clean start both arms pass
with migration 008 in place.

**A CI step that needs the plugin checkout needs `working-directory` EVERY TIME.** The
`corpus` job checks out into `plugin/`; one step of six was missing it and failed in all
three engines for the one reason that step must never fail for — having found nothing to
check. `working-directory` is per step, not per job.

**VALUE AGREEMENT PROVES ARITHMETIC AND NOTHING ELSE. T-31's oracle compared every figure
two ways, on two engines, and a fresh-subagent review then found TWO BLOCKERS and EIGHT MAJORS
without a single figure disagreeing.** Worth reading before writing another oracle, because
the instinct after building one is that correctness is settled:

| what agreement could not see | what it was |
|---|---|
| a LABEL read off a different query | `group_by: issue` printed the subject of an issue the actor may not see — `time_entries.issue_id` is a column on the ENTRY, so it survives the visibility condition core puts in `left_join_issue` |
| the absence of a CEILING | `limit: 0` meant "no cap", so 50 000 buckets came back with `truncated: false`. Every figure in them was right |
| ORDER, and therefore membership | `sort_by` is not stable, so ties followed the engine's row order; past a cap that changes WHICH buckets exist |
| a SORT MODE doing something else | `sort: label` sorted by the raw id, and the spec's own name said "orders by key when asked for a label sort" |
| WHICH bucket the cap folded | `(none)` merged into `(other)`: unclassified hours reported as "some other activity" |
| a key that should have been TWO | a project-overridden activity as two buckets carrying the same name |
| a FILTER NAME | six of eleven drill-throughs named an `IssueQuery` filter; `author_id` exists on `TimeEntryQuery` and means the ENTRY's author, so it resolved to a plausible WRONG row set |
| an argument DROPPED | `drill:`, `split_by:`, `period:` silently ignored, against a README that promised them |

The pattern: an oracle checks the NUMBER in the bucket. It says nothing about the bucket's
label, its order, its existence, or the link on it. Those need the rows under the example's own
control (a recording double), a real `TimeEntryQuery`, and a real invisible record — three
different processes, which is why T-31's tests ended up in three files.

**AND A "MUTATION-TESTED" CLAIM IS ONLY AS GOOD AS THE MUTATIONS SOMEBODY ELSE CHOOSES.** The
same review re-ran 21 mutations of its own against a commit whose message said "27 mutations,
27 red" and **thirteen survived** — every one in a guard the commit named as killed. Choosing
your own mutations tests the examples you were already thinking about. Ask a reviewer to pick.

**NEVER PUT `spec/adapter` AND THE DB-LESS SPECS IN ONE RSPEC PROCESS. It produces a
CONSTANT SEVEN-FAILURE FLOOR, and a mutation harness built on it reports every mutation as
"red" whether or not the mutation did anything.** `adapter_helper.rb` says the two must be
separate processes and gives the reason (`spec/sql_aggregation/*` define a stub
`ActiveRecord::Base` when none exists; the adapter specs load the real one). T-31 increment 2
built a mutation harness that ran them together for speed and got a clean sweep of 19
"kills" — worthless, because the baseline was already 7 failures. Measured after separating
them: three of those guards were provably DEAD. Always run the unmutated control first and
require it to be GREEN; a harness whose control is red measures nothing.

    56 examples, 0 failures     # adapter, own process
    727 examples, 0 failures    # DB-less
    783 examples, 7 failures    # the two together — the floor

**AND MATCH THE SINGULAR: `grep -qE "[1-9][0-9]* (failures|errors)"` DOES NOT SEE
`1 failure`.** Same harness, same afternoon. One mutation was reported as surviving because
the only run that caught it reported exactly one failure. If a script decides green from
rspec's summary line, match `failure|error`, not the plural.

**A COARSE `unless defined?(ActiveRecord)` GUARD IN ONE DB-LESS SPEC SILENTLY DISABLES
ANOTHER'S STUB.** Four spec files stub that namespace. Three define `RecordNotFound` under
`unless defined?(ActiveRecord)`; T-31 added a fourth defining only `StatementInvalid` under
the same guard. On the seeds where the new file loaded first, `ActiveRecord` was already
defined, the other guards skipped, and `sql_stats_controller_spec.rb` failed on
`uninitialized constant ActiveRecord::RecordNotFound` — one spec breaking another through a
constant neither mentions, on some seeds only. **Guard the CONSTANT, never the namespace:**
`module ActiveRecord; end unless defined?(ActiveRecord)` then one `unless
defined?(ActiveRecord::X)` per class. All four files now do. Run the DB-less suite under
several `--seed` values before believing it.

**A ROUNDING GUARD NEEDS A BUCKET WHOSE FLOAT SUM IS NOT REPRESENTABLE.** T-31's fixture put
`0.1` and `0.2` in a bucket to justify rounding hours to two places — and also put `4.0`
there, and `0.1 + 0.2 + 4.0` is exact. Deleting the `.round(2)` left the whole suite green.
The two rows are now alone in their bucket, and an example asserts
`raw.sum != 0.3 && raw.sum.round(2) == 0.3` so the fixture cannot silently stop
discriminating.

**`H.count_queries { … }` COUNTS THE `let` YOU DEREFERENCE INSIDE IT.** An example asserting
a refusal costs zero statements failed on `User.find` — the first evaluation of the `actor`
`let`, inside the block. Resolve the scope into a local before opening the counter.

**A GUARD BEHIND A `rescue` CAN BE PROVABLY DEAD IN A GREEN RUN.** T-31's `applicable?`
refuses an issue-column dimension on a scope with no issues join. Forcing it to `true` — and
separately forcing `joined_to_issues?` to `true` — left every example green, because
PostgreSQL raised on `issues.tracker_id` and `measure_rows`' `rescue
ActiveRecord::StatementInvalid` returned nil either way. **Two guards, both dead, nothing
red.** The observable that separates a decision from a rescue is that the decision issues NO
statement: assert the query count, or drive it with a double and assert `group` was never
called. The general rule — whenever a rescue sits behind a guard, the guard needs an
assertion the rescue cannot satisfy.

**MariaDB CAN BE INSTALLED IN THIS CONTAINER, AND D-1 REPRODUCES ON IT IN SECONDS.**
`implementation-plan.md`'s T-31 clause 7 said *"the engine the defect lives on is the one a
local run in this container cannot install"* — stale, and now corrected there. §4's table has
carried a local MariaDB 10.11 row since 2026-08-05; this is the recipe, because looking it up
took longer than running it.
`sudo apt-get install -y mariadb-server mariadb-client default-libmysqlclient-dev`,
`sudo service mariadb start`, create `redmine_adapter_test`, then put `gem 'mysql2', '~> 0.5.0'`
in `redmine/Gemfile.local` — Redmine's Gemfile reads `config/database.yml` to choose database
gems, and `Gemfile.local` adds one without touching that file, so the Minitest suite stays on
PostgreSQL. Measured 2026-08-08 on MariaDB 10.11: whole `spec/adapter` green in 4 m, corpus
green, and D-1 live —

    [D-1] Mysql2 label-keyed grouped .sum over a 394-char expression:
          DIVERGES (keys [nil], total 3.75 against a real 8.8)

against `agrees (keys [20, 21, nil], total 8.8)` on PostgreSQL. Three buckets collapsed into
one and the figure was the last group's hours wearing the total's name.

**A DEFAULT ARGUMENT IS A DECISION, AND `ReportScope.build`'s IS `:ignore`.** Both of T-32's
review blockers were the same shape: a *silent fallback to a WIDER scope than the requester
asked for*. `ReportScope.build` defaults to `on_missing_query: :ignore`, so an unresolvable
`query_id` was dropped and the report rendered over the whole project — mailed, and audited
as `success` **under the query id it had ignored**. The `:raise` mode existed, written for
exactly this, and `find_query`'s own message is the argument for it: *"the alternative is
mailing a different report under the same name."* §Findings S-15 is the same defect one
caller earlier. **When a shared resolver offers two failure modes, the caller that has an
audience must pick one explicitly**; taking the default is not picking.

**AND THE SECOND BLOCKER WAS A DROP THAT HAPPENED ONE LINE ABOVE THE COMMENT FORBIDDING
DROPS.** `filter_map { Integer(id) if id.match?(/\A\d+\z/) }` discarded every non-numeric
issue id *before* the "refused, not silently included" rule ran — under a 12-line paragraph
explaining why dropping is a defect. The boundary is what makes it serious rather than
untidy: with `issue_ids=abc` the parsed list came out **empty**, took the "no set was named"
branch, and mailed a report over the requester's entire visible scope while the flash said
"sent to 1 recipient". **A parse step that can empty a list has to distinguish "nothing was
asked for" from "nothing survived parsing"**, and the second one must not inherit the first
one's meaning.

**A REFUSAL CODE WITH NO LOCALE KEY IS A BLANK PAGE, NOT A FALLBACK.** T-32's controller
rendered the diagnostics panel for `:render_failed` and nothing at all for the other seven
codes — the reason was computed, written to the audit row, and withheld from the person
standing in front of it, who saw an empty form and a 422. `:partial_delivery` was the worst:
some recipients already hold the report, the obvious next action is to press send again, and
nothing said so. The fix is T-31's `text_reporter_degradation_<code>` mechanism
(`error_reporter_adhoc_<code>`, raw message as fallback) **plus an example that walks every
code the class can emit** — the fallback alone would have hidden the next missing key.

**`link_to_user(nil)` RETURNS `""`, WHICH IS TRUTHY, so `link_to_user(x) || l(:fallback)` is
a guard that never fires.** Core's helper ends in `h(user.to_s)`. Use `.presence ||`. Worth
knowing twice over: in T-32 the dead guard was sitting on top of a locale key that did not
exist (`label_user_deleted`, in neither core nor this plugin) while the key that WAS
translated into nine languages was referenced nowhere — one bug hiding the other, so the
page showed an empty cell instead of "Translation missing" and neither was visible.

**`Render::Registry.register` TAKES THE CLASS AND CALLS `.new` ITSELF.** Handing it an
instance raises `NoMethodError: undefined method 'new'` from inside `ReportRun#with_pdf`,
three frames from the cause and reading like a bug in the render layer.

**AN SQL-STATEMENT ASSERTION ANCHORED AT `\A` IS DEFEATED BY ONE LEADING COMMENT, and
Rails emits them in production.** T-24's central claim — *the importer never writes to the
base plugin's tables* — was asserted with
`sql.match?(/\A\s*(INSERT|UPDATE|DELETE|…)/i)`. An independent review planted
`connection.execute("/* rails */ UPDATE report_templates SET name = 'PWNED'")` **inside the
runner** and the test stayed GREEN; only the row-comparison test the commit message had
called insufficient fired. `query_log_tags_enabled` is an ordinary setting and prepends
`/* app:… controller:… */` to every statement.

The anchor cannot simply be dropped — `SELECT id, updated_on FROM report_templates`
contains "update" — so the pattern has to match **verb + table**
(`/\b(INSERT\s+INTO|UPDATE|DELETE\s+FROM|…)\s+"?report_/i`). And the general rule is
HANDOVER's own, unlearned once: **negative-test a gate before trusting it.** This one was
written, believed, and cited in three documents without ever being watched fail. Its
negative test is now committed rather than performed by hand, with every shape the first
version missed.

**A CITATION IS PART OF THE CONTROL, AND THIS PROJECT HAS NOW SHIPPED THE SAME DEFECT
TWICE.** T-32's review found two comments citing spec files that had never been written;
T-24 then cited `spec/import/runner_spec.rb`, which also does not exist. If a comment says
"asserted in X", open X. A cited control that is not there is worse than no comment: it
tells the next reader the question has been answered.

**AN N+1 CAN BE INTRODUCED BY THE COMMIT THAT REMOVES ONE.** T-32's G6 fix preloaded the
audit page's users — and the same commit added `@project.users.select { allowed_to?(…) }`
to the compose form, which costs two queries per member (measured: 30 at 2 members, 50 at
12, **130 at 52**). `allowed_to?` resolves `roles_for_project` per User object. A permission
is a property of a ROLE: ask which roles carry it once, then filter membership rows.

**`User.active.where(id: ids)` SILENTLY DROPS whatever does not resolve** — a locked
account, a **Group** id (a `Principal` that is not a `User`), a deleted id. T-32 refused an
unentitled recipient wholesale and dropped these three in silence, one line above the
comment explaining why dropping is wrong. Compare `ids.length` with the resolved length;
locking is how Redmine offboards somebody, so a stale form is the ordinary route to it.

**A LIVENESS SCOPE ON ONE BRANCH AND NOT THE OTHER IS INVISIBLE UNTIL A FIXTURE HAS A
LOCKED ONE.** `resolve_actor` used `User.active` in its fallback and bare `find_by` in the
`RRD_ACTOR` branch, so a locked administrator could own every imported template — and
`author_id` is what `edit_own_…` reads. The mutation that removed `.active` from the
fallback SURVIVED, because no fixture has a locked admin and the two spellings answer
identically without one. Build the row the property is about.

**`test/**` CAN LEAVE A NON-PLUGIN TABLE BEHIND AND `migrate_updown.sh` THEN FAILS FOR A
THIRD REASON.** T-24's importer test creates and drops a stand-in `report_templates`. A run
that dies before `teardown` leaves it, and the G11 schema snapshot then sees a table on one
side and not the other. Add it to the drop list in §3's repair command; the recipe is
otherwise unchanged.

**`Mailer#mail` MERGES `From` WITH `reverse_merge!`, SO A CALLER-SUPPLIED HEADER WINS — the
sender is server-controlled only because no parameter exists to carry one.** Redmine's
`app/models/mailer.rb:693` does `headers.reverse_merge! 'From' => from`, and reverse-merge
keeps what is already there. So "the sender is server-controlled" is NOT a property of
inheriting `Mailer`; it is a property of no method on the subclass taking a `from:`, a
`headers:` or an options Hash that could hold one. Written down because the opposite is the
natural assumption, and because §7b.5's whole finding about the base plugin is a forged
sender. T-32 asserts it twice: once against the mailer's own `parameters` list, and once
against the `From` header of a message that actually came out — only the second can see a
header set somewhere else.

**AND `Mailer#process` RAISES UNLESS `args.first.is_a?(User)`,** because it sets
`User.current` and the recipient's language from it (`mailer.rb:43-45`). A mail to a bare
address — FR-61's allowlisted external recipient — therefore cannot take the address as its
first argument. `User.anonymous` is passed instead and the address goes in `to:`, which is
honest rather than a workaround: `logged?` is false, so the mail is composed in
`Setting.default_language`, which is the only language the installation knows for somebody
it has never met, and `User.current` is the safest value it could be.

**A ROLE-REPLACING `grant` HELPER REMOVES THE CORE PERMISSIONS YOUR SCOPE DEPENDS ON, AND A
VISIBILITY FIXTURE THEN PROVES NOTHING.** T-32's controller test uses T-25's `grant`
pattern — `@role.permissions = […]` replaces the set outright, which is what makes "hold ONE
permission and assert 403" readable. It also dropped `:view_issues`, so
`Issue.visible(requester)` was **empty**, and the test asserting *"an issue the requester
cannot see refuses the send"* had no visible issue to contrast it with: it would have gone
green whether or not the refusal worked. Grant the core permission the scope reads, and
assert the fixture discriminates.

**AND THE SAME TEST'S "INVISIBLE" ISSUE WAS VISIBLE.** The first version took a fixture issue
from another project. Fixture project 5 is PUBLIC, so `Issue.visible` includes issue 6 for
any logged-in user and the negative half was vacuous — caught only because the helper
asserted `assert_not Issue.visible(actor).exists?(hidden.id)` rather than trusting the
choice. Build the invisible row (a private issue, `issues_visibility = 'default'`, authored
by somebody else) so the rule that hides it is one the test sets, and keep the assertion
anyway.

**AN UNCHECKED CHECKBOX POSTS NOTHING, SO A BOOLEAN SETTING WITHOUT A HIDDEN FIELD CAN BE
TURNED ON AND NEVER OFF.** `check_box_tag` does not emit the paired hidden input that the
form-builder helper does, so unticking the box and saving leaves the previous value in
place — an administrator who has just switched external mail addresses *off* still has them
on, with a page that shows the box unticked. One `hidden_field_tag(name, '0', id: nil)`
before the checkbox, and the coercion reads both spellings.

**"ONE `@`" IS NOT AN ADDRESS CHECK.** `MailPolicy` refused `a@b@c` by counting `@`s and then
took everything after it as the domain — which accepted **`@example.com`**, an address with
no local part, as being in an allowlisted domain. Found by the spec's "text that is not an
address at all" table rather than by reading. The local part's grammar is the MTA's business;
its *existence* is not.

**A TEST THAT INVOKES A RAKE TASK CALLING `exit` KILLS THE WHOLE MINITEST RUN, AND THERE
IS NO SUMMARY LINE TO TELL YOU.** T-29, 2026-08-09. `import:plan` and `import:run`
end in `exit(...)` so they can be deploy steps — and **`exit(0)` raises `SystemExit`
exactly as `exit(2)` does.** Minitest does not rescue `SystemExit`: the run TERMINATED at
the first such test, having printed its dots and nothing else. `rake` answered 1 with **no
failing test named and no `N runs, N failures` line at all**, which reads as a broken
environment rather than a broken test — and the same run had passed minutes earlier, which
makes it read as flakiness. Two consequences. A rake-task test must convert the exit into a
value (`rescue SystemExit => e; status = e.status`) rather than let it escape, which is
also how the exit CODE becomes assertable — and `ImportPlanRakeTest` avoided this only by
never invoking a task that exits. And more generally: **a run with no summary line is
UNMEASURED, never green** — the same rule the mutation harness follows, met from the other
direction.

**AN INDEPENDENT READER WRITTEN TO CHECK YOUR OWN WRITER CAN BE THE THING THAT IS WRONG,
AND IT FAILS EXACTLY LIKE A BROKEN WRITER.** Same afternoon. `spec/archive/zip_stream_spec.rb`
parses the zip it produces rather than comparing it with a fixture — the right call, and
T-30's PDF is why. Its first version misread the end-of-central-directory record by two
bytes (`unpack('vVV')` from offset 8 straddles the total-entries field into the size field)
and reported *"central directory runs past the file"* on **13 of 21 examples**, against an
archive that `unzip -t` called *"No errors detected"* and Python's `zipfile.testzip`
accepted. Half an hour was available to spend debugging the writer. The rule that saved it:
**run the artefact through a real reader BEFORE trusting your own** — two of them, on
stderr as well as stdout. An independent oracle doubles the number of places a bug can be,
which is the price of it being independent.

**IN A FUNCTIONAL TEST, `@response`'s STREAM IS ALREADY MATERIALISED, SO IT CANNOT TELL YOU
WHETHER A RESPONSE WAS STREAMED.** T-29 again. `ActionController::TestCase` reads the body
to populate `response.body`, so reaching into `@response.instance_variable_get(:@stream)`
finds a fully concatenated String whatever the controller did — an assertion about the
harness wearing the words of an assertion about the code. What the controller actually
assigned survives on the CONTROLLER: `@controller.response_body` is the object handed to
Rack, and `ActionController::Metal#response_body=` wraps anything answering `to_str` in an
Array, so a buffered body cannot impersonate a lazy one. Measured by probing both before
writing the assertion.

**GOTENBERG EXEMPTS `/health` FROM BASIC AUTH, so the obvious credential check is one that
cannot fail.** T-34, measured against 8.35.0 with `--api-enable-basic-auth` and both env
vars set:

    GET  /health                        unauthenticated -> 200   <-- EXEMPT
    GET  /version                       unauthenticated -> 401
    POST /forms/chromium/convert/html   unauthenticated -> 401
    POST /forms/chromium/convert/html   authenticated   -> 415 (empty form)

A credential probe written against the health endpoint therefore answers 200 on a
correctly locked-down service AND on a wide-open one — a security check with no failing
input, which is this repository's most-repeated defect wearing a new costume. The probe
that works is an **unauthenticated POST to the convert route with no parts**: it is the
route that actually matters, it costs no render, and 401/403 versus anything else is
decisive. Note the corollary for the *other* direction — an endpoint that is simply DOWN
has proved nothing about its authentication, so a transport error must not be reported as
"it answered without the credential".

**AND GOTENBERG SILENTLY IGNORES `waitForExpression` WHEN JAVASCRIPT IS DISABLED, which
makes every chart in every report vanish with nothing failing anywhere.** Same afternoon,
and it is the exact failure `Preflight` exists to catch. Measured:

    JS live,     expression never true  -> 503 after the 30 s api timeout
    JS disabled, expression never true  -> 200 in 0.17 s

So on a container started with `--chromium-disable-javascript` the readiness contract is
void, the plugin does not even wait, and the document renders chart-free and healthy. The
obvious probe — send `waitForExpression` and see what happens — is worthless for detecting
it, because the healthy and broken cases both answer 200. **The discriminator is a document
whose script THROWS, sent with `failOnConsoleExceptions=true`: 409 when JavaScript is live,
200 when it is not**, in half a second either way. A check that succeeds by provoking an
error reads oddly and is the only cheap one that discriminates.

**GOTENBERG'S `landscape` ROTATES WHATEVER DIMENSIONS YOU GIVE IT, so swapping the page
AND setting the flag cancels out.** The reference adapter swaps `paperWidth`/`paperHeight`
itself because Chromium's printToPDF has no orientation flag it uses; copying that habit
across and *also* sending `landscape=true` produced a PORTRAIT page for every landscape
report. Measured:

    W=8.2677  H=11.6929  landscape=true  -> 841.92 x 595.92  (landscape)
    W=11.6929 H=8.2677   landscape=false -> 841.92 x 595.92  (landscape)
    W=11.6929 H=8.2677   landscape=true  -> 595.92 x 841.92  (PORTRAIT)

Nothing failed: the document rendered, the margins were right, only the page was the wrong
way round. **Conformance fixture F-03 is what caught it** (`expected 841.89 ± 3, got
595.92`), which is the argument for "passes T-12's corpus unmodified" being an acceptance
criterion rather than a formality — no unit assertion about the adapter's own form fields
could have seen it, because both fields were exactly what the code intended.

**AND `waitForExpression` REFUSES AN EXPRESSION THAT EVALUATES TO `undefined`, WITH A 400,
IN 0.2 s.** `Readiness::EXPRESSION` is `window.__rd && window.__rd.ready === true`, and
before the chart shell has run `window.__rd` is undefined — so the whole expression is
`undefined`, not `false`, and Gotenberg answers *"The expression … returned an exception or
undefined"* rather than waiting. Every chart-bearing report would have failed. The
reference adapter has always wrapped it (`page.evaluate("!!(#{EXPRESSION})")`), so the
coercion belongs to the interface rather than to this engine; wkhtmltopdf's arm reads the
same constant as a `--window-status` NAME, so it cannot go into the shared constant.

**A KEYWORD ARGUMENT DEFAULTING TO `nil` AND FALLING THROUGH TO `ENV` MAKES "EXPLICITLY
NONE" UNREPRESENTABLE, AND MAKES ITS OWN TESTS ENVIRONMENT-DEPENDENT.** T-34's adapter had
`credential: nil` with `credential || credential_from_env`, so `Gotenberg.new(credential:
nil)` — the exact thing the security examples are ABOUT — silently picked up
`RRD_GOTENBERG_USERNAME`. Every one of those examples was green on a laptop with no such
variable and would have been RED in the render-smoke job, which exports it. Caught by a
mutation run that happened to export the variables, not by any example. Two rules. Use a
SENTINEL (`FROM_ENV`) when `nil` is a meaningful value, and when a spec's subject is "no
credential", make it assert against an environment that HAS one.

**A LOCALLY GREEN SUITE SAYS NOTHING ABOUT A CI STEP YOU JUST WROTE, AND T-34 WAS REPORTED
COMPLETE WITH CI RED.** Gates, four Redmine branches, three databases, the corpus and a
regenerated matrix were all green on this machine; the first push went red and stayed red
for five commits. Twenty-five of twenty-six jobs passed every time — the one that failed was
the leg the task had added, which by definition had never run. **Check the run before
reporting.** `curl -sS "https://api.github.com/repos/<owner>/<repo>/actions/runs?branch=<b>&event=push&per_page=1"`
answers it in one line, and the GitHub MCP tools work for the session's own repository.

**`VAR=x docker compose up -d` SETS THE VARIABLE FOR EXACTLY ONE INVOCATION**, and every
later `docker compose` call re-parses the file and needs it again. The container starts and
the NEXT call dies with "required variable … is missing a value". In GitHub Actions add the
second trap on top: each `run:` block is its own shell, so `export` does not survive between
steps either. This bit twice — once in the startup step, once in the diagnostic added to
debug it. `docker logs <name>` needs no variables; `docker compose logs` does.

**`internal: true` PLUS `ports:` PUBLISHES NOTHING, SILENTLY.** Docker accepts the
configuration, starts a healthy container, and binds no port: `docker port` prints nothing
and `.NetworkSettings.Ports` is `map[3000/tcp:[]]`. There is no warning anywhere. This was
written into `docker-compose.gotenberg.yml` as advice for operators whose Redmine is not in
Docker, and it was wrong — the honest options are to put Redmine on the network, or to drop
`internal: true` AND publish on loopback, which is a real trade rather than a smaller one.
**Follow your own instructions once before shipping them.**

**A CONTAINER THAT SURVIVED A `dockerd` RESTART ANSWERS 500 TO EVERYTHING UNTIL IT IS
RECREATED.** Local trap, cost twenty minutes of chasing a CI failure that was not the same
bug. `docker compose up -d` reports "Running" and does not fix it; `--force-recreate` does.
Whenever this container starts misbehaving right after the daemon was restarted — which in
this environment happens whenever it idles — recreate before diagnosing.

**HEADLESS CHROMIUM IN A `read_only: true` CONTAINER NEEDS A WRITABLE HOME AND MORE THAN
64 MB OF `/dev/shm`,** and the error names neither: `chrome failed to start:
chrome_crashpad_handler: --database is required`. Gotenberg reports that as a bare
`500 Internal Server Error` with NO LINE IN ITS OWN ACCESS LOG, because it fails before the
logging middleware — while `/health`, 401 and 415 all behave perfectly. Point `HOME`,
`XDG_CACHE_HOME` and `XDG_CONFIG_HOME` at the tmpfs and set `shm_size`. Two caveats worth
carrying: this reproduced on a GitHub runner and NOT on a developer machine with the
identical file, image and spec, so the trigger is still unidentified; and the two
hypotheses before it were both wrong, refuted by a four-line write probe added to the CI
step. **When you cannot reproduce a failure, spend the cycle on a diagnostic that can
refute you rather than on the fix you like best.**

**`#$&` IN A REGEXP LITERAL IS GLOBAL-VARIABLE INTERPOLATION, AND IT ATE A SECURITY GUARD.**
T-34 wrote a media-type allowlist as `%r{…[A-Za-z0-9!#$&^_.+-]…}` and the class COMPILED as
`[A-Za-z0-9!^_.+-]` — `#$&` is Ruby's shorthand for interpolating `$&`, which was empty. It
happened to be STRICTER than intended, so nothing legitimate was refused and no test could
tell; the danger was proved by construction, with `$&` set to `]|.*` the same literal
compiles to a class that closes early and matches a CRLF payload. **The value of the guard
depended on `$&` in whatever frame loaded the file.** Escape it (`\#\$&`) — and when a
regexp IS the guard, assert its compiled behaviour, not the source you meant to write.

**A `raise` IN A CONSTRUCTOR IS A 500 WHEN THE CALLER IS `adapter.new`.** T-34's own comment
said "construction stays TOTAL — raising here would escape `adapter.new` in
`ReportRun#with_pdf`", and then `validate_endpoint!` raised. It was total for `nil` and `''`,
which were the two values tested; `RRD_GOTENBERG_URL=gotenberg:3000` — a missing scheme, i.e.
what an operator types after reading a compose file — 500'd the preview page, as did a
trailing newline from `--env-file`, a stray space, and surrounding quotes. **When you write
"this cannot raise", enumerate the inputs an OPERATOR produces, not the ones a spec does**:
no scheme, a newline, quotes, whitespace, and the thing you just decided to refuse.

**A PROBE THAT CARRIES A CREDENTIAL CANNOT TELL YOU WHETHER A CREDENTIAL IS REQUIRED.**
T-34's identity check said "unauthenticated" in its comment and sent `Authorization` anyway.
So against a service with the WRONG password configured, the 401 read as "a Gotenberg
enforcing its credential", the credential arm agreed, and the run reported PASS on both
before failing two checks later with an unrelated message — **a worse diagnosis than the one
the render path had produced before the preflight existed.** A 401 only means "enforcing" if
nothing was presented.

**`192.0.2.1` IS NOT A SAFE "NOT LOOPBACK" ADDRESS WHEN `no_proxy` CONTAINS `::1`.** A test
written to escape the loopback trap (`URI#find_proxy` returns nil for `127.*`) re-entered it:
URI's `no_proxy` scanner reduces `::1` to the host `1`, the rule is
`hostname.end_with?(".#{p_host}")`, and `"192.0.2.1".end_with?(".1")` is true. The mutation
survived the new test exactly as it had survived the old one. Use `.9`, and **assert the
precondition** — `expect(URI.parse(endpoint).find_proxy).not_to be_nil` — so the example
cannot go vacuous a third time.

**A SECURITY CHECK CAN BE CORRECT, TESTED, MEASURED — AND HUNG ON A METHOD NOTHING CALLS.**
T-34's worst defect, found by TWO independent reviews separately and reported first by both.
`Render::Preflight#run` is what the admin page and `rake …:render:preflight` both go through,
and it renders a probe document; it never called `engine.preflight`. So an adapter's own
credential check — rewritten three times because each earlier version could not fail — was
exercised only by RSpec and the conformance harness. Against a Gotenberg with NO
authentication, the exact command the README printed answered **exit 0 with eight PASSes**,
while three documents said the plugin refuses one. The rule that generalises: **when you
harden a check, run the command a user runs, in the state the check exists to catch.** A
green suite proves the method; only the command proves the path. Related and cheap: `grep -rn
'\.preflight\b' lib/ app/` had no hits outside spec/ and would have said so in one line.

**AND REGISTERING AN OPTIONAL ENGINE AT BOOT TURNED EVERY INSTALL'S PREFLIGHT RED.**
`PreflightSuite` runs every engine in `Registry.ids`, so adding `:gotenberg` made
`rake reporter_dashboards:render:preflight` exit **1** on every install without a container
the documentation calls optional — breaking the "exit 0, so it can be a deploy step"
contract the README advertises — and put a permanent red row on the admin page that no
operator could fix by installing anything. The `needs_service` rule had been added to
`ReportRun#resolve_engine` and to nothing else. **A rule about "an install has not chosen
this" belongs everywhere an engine is chosen FOR the operator**, and there were two such
places.

**`Net::HTTP.start(host, port, use_ssl: …)` SENDS YOUR REQUEST TO `$http_proxy`.** Its third
POSITIONAL argument is `p_addr = :ENV`, so a keyword-only call silently follows the ambient
proxy. Measured against a listening fake proxy: the whole multipart report AND
`Authorization: Basic …` arrived there instead of at the configured endpoint. It is
invisible in tests for a reason worth knowing on its own — **`URI::Generic#find_proxy`
returns nil for `127.*` and `localhost`**, so any loopback-based test of this is
unfalsifiable, and the first replacement test was loopback and the mutation survived it.
Pass `nil` explicitly, assert on the ARGUMENT, and if you want the behavioural half use
`192.0.2.1` (TEST-NET-1).

**A CREDENTIAL IN A CONFIGURED URL IS A LEAK EVEN WHEN NOTHING READS IT.**
`http://user:pass@host` was accepted, never used for authentication (the connection is made
with host and port), and interpolated into six failure messages — which reach the
diagnostics panel, the scheduled-report failure MAIL sent to every recipient, and a
persisted `Snapshot` row. **Refuse it rather than redacting it**: redacting fixes the leak
and keeps the silent non-authentication, and `user:pass@host` is the single most natural way
an operator writes basic auth for a service URL.

**A DEFAULT ENDPOINT OF `localhost:3000` IS REDMINE'S OWN PORT.** An unconfigured adapter
POSTed a probe document — and, with the credential vars set, a credential — to Redmine
itself, got a 404, and reported `:internal`, the code whose own comment says it means "a bug
here, not an engine fault". Every step locally reasonable; the composite a false accusation
against the plugin. There is no safe default for a service address. Keep construction TOTAL
(raising escapes `adapter.new` in `ReportRun#with_pdf` and in the conformance harness) and
answer a typed `Failure` naming the variable to set.

**IDENTITY BEFORE VERDICT, in any diagnostic with more than one check.** T-34 ordered its
preflight checks by COST — "each is cheaper than the one after it" — and produced three
confident wrong remediations: a service that was DOWN, one that was NOT A GOTENBERG (any
404: an nginx, a Redmine, a load balancer, a Gotenberg behind an unnamed root path) and one
merely erroring were all told their container was failing to enforce its credential. Cost is
the wrong axis. Establish WHAT you are talking to, then judge it. Same file, same afternoon:
a JavaScript-liveness check whose "not the expected 409" branch swallowed 503, 502 and 413
and blamed `--chromium-disable-javascript` for all of them.

**A SECOND `local` FOR THE SAME NAME IN A BASH FUNCTION RESETS IT, AND THE GATE THEN FAILS
WHILE PRINTING NOTHING.** `layer_purity.sh`'s new arm opened with `local rc=0`, set `rc=1`
on two failure paths, then declared `local route_hits='' file stripped rc` further down —
which re-declares `rc` in the same scope and unsets it. The two failures were wiped, the
closing `[ "$rc" -eq 0 ]` compared against an empty string, and the function returned
non-zero having echoed nothing at all. The gate said `layers checked=9` and `exit 1` with
no reason on any line — the single outcome that file exists to make impossible. Found by
running it; no amount of reading it found it.

---

**A DOUBLE THAT ANSWERS AN UNAUTHENTICATED PROBE WITH DATA A LOCKED SERVICE REFUSES MAKES A
CACHING MUTATION UNKILLABLE.** E-27 row 10, 2026-08-11. `gotenberg_spec.rb`'s `healthy`
script answered `/version` 200-with-the-version whether or not the request carried a
credential; a real locked-down Gotenberg answers **401** unauthenticated (measured, and the
adapter's own comments say so). Under that double, deleting the credential-probe
memoisation SURVIVED its mutation run — the identity probe's memo covered for it, in a
world that does not exist. The example about fetch-counting now scripts the measured
answers instead of reusing the friendly default. Rule: an example that counts, orders or
caches REQUESTS must script its double from measured behaviour, not from the shape that
keeps the rest of the file short — a convenience double is exactly as vacuous as a
convenience fixture, and only a mutation run says so.

**A TABLE THAT PINS SOME OF A THING'S ARMS AND NOT THE REST IS A COMMENT, AND ITS HEADER
WILL SAY OTHERWISE.** 2026-08-11, §Findings E-29. A twelve-row classification of Gotenberg's
failure arms was written as a seven-row table whose own header said *"moving any one of them
across the line is the defect this block exists to catch"*. An independent review moved FIVE
of the twelve — including the two a source comment claims by name are protected — and the
whole tree stayed green: **2569 examples, 0 failures**, byte-identical to the control, with
all five mutants applied at once. Two rules. When you write a table to pin a boundary,
ENUMERATE THE ARMS FROM THE SOURCE (`rg -n 'preflight_failure\(' file`) rather than from the
ones you were already thinking about; and mutate every row of it, because a row that cannot
fail is indistinguishable from a row that is right.

**EVERY `assert_not_includes … 'translation missing'` IN THIS PROJECT WAS BLIND, BECAUSE
RAILS CAPITALISES IT.** 2026-08-11, found by mutation. Rails renders a missing key as
**`"Translation missing: en.label_…"`** — measured in the test environment — so the
lowercase literal never matches, and DELETING a locale key the page under test uses left
the suite GREEN. Five call sites were affected across four files, the oldest shipped with
T-33, and every one of them is a control whose whole job is to notice an absent key. All
five are now `assert_no_match(/translation missing/i, …)` — case-insensitive rather than
capitalised, because the casing is Rails' and this plugin spans three Rails majors — and
the mutation (delete one key per page) now fails both settings tests. The general rule:
**a control that asserts the ABSENCE of a string must be measured by planting the string
it looks for**, and the cheapest way to plant it is to delete the key.

**AND `git checkout <path>` IN A MUTATION HARNESS DESTROYS UNCOMMITTED WORK.** Same
afternoon: a harness that restored one of its targets with `git checkout` silently reverted
an uncommitted change to that file, and the following control run reported 7 errors that had
nothing to do with any mutation. Restore from a COPY made before the mutation, never from
the index — the index is not where uncommitted work lives.

**A MUTATION HARNESS WHOSE RESTORE CAN BE INTERRUPTED MUST VERIFY THE TREE BEFORE EVERY
VERDICT, NOT AFTER THE BATCH.** 2026-08-11, disclosed by the adversarial QA pass that hit it:
a two-minute tool timeout landed BETWEEN applying a mutation and restoring it, so the next
three mutations in that batch ran against a dirty tree and one of them reported a
contaminated KILLED. It was caught only because the harness re-verified against
`git show HEAD:` afterwards and re-ran all four. The cheap fix is a precondition rather than
a postcondition — diff the file against `git show HEAD:<path>` before applying, and treat a
mismatch as UNMEASURED. This is the §1 entry above from the other side: there, a commit could
not tell a mutation from an edit; here, a mutation could not tell a clean tree from a
mutated one.

**AND THE FRIENDLY-DOUBLE ENTRY BELOW WAS RE-VIOLATED IN THE NEXT TASK, BY SOMEBODY WHO HAD
READ IT.** The same session wrote a comment above its new double saying, in as many words,
that scripting it from convenience is what made a mutation unkillable on 2026-08-11 — and
left the premise (a locked Gotenberg answers **401** to an unauthenticated `/version`)
asserted nowhere. Reintroducing the friendly answer kept all seven rows and the control
green. **A comment recording a lesson is not a control**: assert the double's own answers, at
the double, in the same file (`expect(locked({}).call(unauthenticated_get, 1).code).to
eq('401')`).

**`URI.parse` MAKES A SCHEMELESS VALUE OPAQUE, AND EVERY PARSED-URI GUARD SILENTLY SKIPS
IT.** E-27 row 9's first fix, rejected in review on 2026-08-11.
`URI.parse('gotenberg:3000/?token=abc')` has `scheme: "gotenberg"`, `query: nil` — so a
`uri.query` refusal never fires for precisely the schemeless spellings the endpoint spec
already lists as "what an operator actually types", and the value fell through to arms
whose messages interpolated `value.inspect` or the parser's message (which REPEATS the raw
value). `hunter2` was demonstrated arriving in a preflight failure message — the surface
that reaches mail and Snapshot rows — through both. Two rules. A guard about a URL's
CONTENT tests the RAW STRING before the parser gets a say. And no refusal message may
interpolate the refused value or the parser's account of it; the operator has the value in
front of them, the report recipient must never have it.

## 1b. Working agreement — verification, decided by the curator

**Curator decision, 2026-08-05: prefer pushing and letting CI judge over stopping.** Asked
whether a change whose only remaining unknown is an engine this container cannot run should
be held back or pushed, the answer was push. So:

- **A red CI cell on an engine that cannot be run locally is an ACCEPTED outcome**, not a
  failure of the change. MariaDB and MySQL are the concrete cases (their Debian packages
  conflict, so only one can be installed and neither is by default). Push, read the cell,
  iterate.
- **This does NOT extend to a locally red suite.** The distinction is the whole point: a
  test that could have been run here and was not is a different thing from a test that
  cannot be run here at all. D-1's first attempt was reverted because it left **11 DB-less
  unit examples** red — nothing to do with MariaDB — and that is still the right call.
  Local green, remote unknown: push. Local red: fix it or revert it.
- **Do not weaken an assertion to make the local suite green.** If an assertion has to
  change because the implementation legitimately made its subject unreachable, that is an
  argument for the pull request body, not an edit that quietly matches the new behaviour.
  D-1's first attempt hit this: it made *"keeps counts for a value outside the expected
  bucket list"* unreachable and needed 11 unit examples rewritten. **The fix that actually
  landed needed none of that** — it still folds whatever keys the database returned, so
  that example survives untouched. Worth remembering as a design smell: when a change
  forces you to delete assertions about defensive behaviour, ask whether a smaller change
  gets the same correctness. Here one did.

---

## 2. Known and deliberately untouched

**`lib/sql_aggregation/scope_resolution.rb` contains nine `rescue nil`,** a construct
`CLAUDE.md` §5 forbids, plus a fail-open `enforce_visibility` rescue. All pre-existing.
**Do not fix them.** T-07 deletes this file (demoted to `glue/legacy/`), so the work
would be thrown away, and touching it before T-01 is complete is a §1 refusal
condition. Flagged here so it is not mistaken for a new violation.

**`.codex/check_ruby_floor.sh` still exists and runs in CI.** `technical-spec.md` §8's
floor decision deletes it. Removing it changes a documented support claim, so it is a
curator decision (G9: the matrix changes in the same PR), not a cleanup.

**The registers-relation path in `scope_resolution.rb` does not enforce visibility.**
Finding F-2. It is FROZEN THAT WAY by a triple in the scope fixture, deliberately, so
that T-07 closing it is a visible decision rather than a diff nobody reads. Do not
"fix" it here: the file is the one T-07 demotes, and changing it now would move the
oracle it is measured against.

**`ZERO_REPORTER_MODE=strict` fails today, by design.** 13 files still name the base
plugin or the vendor gem, each listed with its reason in
`script/gates/zero_reporter.allowlist`. Warn mode enforces the ratchet. Strict is what
1.0 must pass.

---

## 3. Environment quirks (cloud sessions)

- **DOCKER WORKS HERE, BUT `service docker start` DOES NOT.** The init script dies on
  `ulimit: error setting limit (Operation not permitted)` and leaves no daemon, which
  reads as "Docker is unavailable in this container" and is not. Start it directly:

      nohup dockerd --iptables=false --ip6tables=false >/tmp/dockerd.log 2>&1 &

  Measured 2026-08-09: daemon up, and `docker pull gotenberg/gotenberg:8` succeeds
  through the proxy — **2.44 GB**, digest
  `sha256:a16a14e1f18a71405624bc028e90d4ef50ea774c352b303639c10bf7b141f760`. Both halves
  of T-34's premise therefore hold in a fresh container and neither needs re-deriving.
  If it refuses to start with *"process with PID … is still running"*, a daemon is
  already up — check `docker info` before deleting the pidfile.
- **`:chromium_cdp` CANNOT RUN AS ROOT, AND YOU ARE ROOT HERE.** This is why the engine
  looked unavailable in this container for five sessions, and P-2 recorded it as a fact
  about the tree. It is not:

      preflight failed: engine_crashed: the browser exited while we were waiting for it
      [chromium: Running as root without --no-sandbox is not supported.]

  CI never hit it because GitHub runners are unprivileged. The fix is a non-root user, and
  **not** `--no-sandbox` — the sandbox is the one control that contains a compromised
  renderer, and `docker-compose.gotenberg.yml` refuses that flag for the same reason:

      useradd -m -u 4242 rrdbench
      chmod -R a+rX /home/user/redmine_reporter_dashboards
      su rrdbench -c 'cd .../redmine && export HOME=/home/rrdbench \
        CHROME_PATH=/opt/pw-browsers/chromium-1194/chrome-linux/chrome \
        RRD_GOTENBERG_URL=http://127.0.0.1:3098 \
        RRD_GOTENBERG_USERNAME=rrd RRD_GOTENBERG_PASSWORD=s3cret && \
        RRD_CONFORMANCE=1 bundle exec rspec -I plugins/…/spec plugins/…/spec/conformance'

  **THE THREE `RRD_GOTENBERG_*` VARIABLES ARE NOT OPTIONAL SINCE 2026-08-11**, and this
  recipe carried none until an independent review ran it: `:gotenberg` is
  `verification: corpus` now, so a corpus engine whose preflight fails is a HARD failure
  rather than a skip — **69 examples, 23 failures**, every one of them reading
  *"gotenberg claims `verification: corpus` … and its preflight failed:
  engine_misconfigured: RRD_GOTENBERG_URL is unset"*. Start the containers first (the
  Docker entry below has the two `docker run` lines).

  MEASURED 2026-08-10: **20 pass / 0 fail / 0 skip** on Chromium 141.0.7390.37, the full
  corpus, locally. `wkhtmltopdf` runs 18/0/2 as root — it has no sandbox to refuse — so a
  run that skips only Chromium looks like a Chromium problem and is a *uid* problem.
- **THE MIRROR TRAP CAUGHT ME AGAIN, and it presents as a PASSING spec.** `rspec` run from
  inside `redmine/` reads `redmine/plugins/redmine_reporter_dashboards/`, which `rsync -a
  --delete` populated at clone time. I edited a constant the suite asserts on, ran the
  spec, and got **51 examples, 0 failures** — from the unedited copy. The assertion that
  should have caught the edit was fine; it never saw it. §8's rule with the command:

      rsync -a --delete --exclude redmine/ --exclude .git/ ./ \
        redmine/plugins/redmine_reporter_dashboards/

  Re-mirror BEFORE every run, and if a change you expected to break something does not,
  diff the mirror against `git show HEAD:<path>` before believing the green.
- **A FRESHLY-STARTED GOTENBERG FAILS THE PREFLIGHT'S JAVASCRIPT CHECK, AND THE CONTAINER
  IS FINE.** Measured 2026-08-11, three consecutive red runs of
  `script/render_preflight_exit_codes.sh` against a container created two minutes earlier —
  arm 1 reporting *"did not answer the JavaScript check in time"*. The JS probe is the FIRST
  conversion the container ever sees (`configuration_checks` run before the document
  checks), so it pays Chromium's cold start, and the container's own log says so:
  `process first start: context canceled`, **latency 10.011 s** against a
  `PROBE_TIMEOUT_MS` of 10 s. A plain conversion is 0.15–0.38 s once warm.

      # warm it, then the contract holds — two consecutive clean runs, measured
      printf '<html><body>x</body></html>' > /tmp/probe.html
      curl -s -o /dev/null -u rrd:s3cret -F 'files=@/tmp/probe.html;filename=index.html' \
        http://127.0.0.1:3098/forms/chromium/convert/html

  So a RED run of that script against a fresh container means nothing until you have warmed
  the browser — the mirror image of this section's usual trap. It is recorded as a product
  defect in §Findings **E-29 row 16**, because an operator following the README meets it on
  their first ever preflight; CI does not, because `render-smoke` runs the corpus first.
- **THE HOST'S DOCKER REACHES THE REGISTRY; A CONTAINER'S NETWORK DOES NOT.** Measured
  2026-08-10, and it is the reason the CVE gate is CI-only. `docker pull` works (the
  daemon uses the proxy), but a process *inside* a container gets no DNS:

      docker run --rm aquasec/trivy:latest image --download-db-only
      -> lookup mirror.gcr.io on 8.8.8.8:53: read udp …: i/o timeout

  So `gotenberg-cve`'s scan CANNOT be reproduced from a cloud session — only the parts
  of it that are plain shell. That is why the verdict was moved OUT of Trivy and into
  `script/gates/cve_accepted_diff.sh`, which needs neither docker nor a database and has
  its own self-test (`cve_accepted_diff_selftest.sh`, 18 cases) that runs locally in under
  a second. Registry *metadata* is reachable with plain `curl` against
  `auth.docker.io` + `registry-1.docker.io`, which is how "the `:8` tag still resolves to
  the pinned digest" was established without pulling anything.
- **`< /dev/null` AFTER A HEREDOC SILENTLY EMPTIES IT**, and it cost a whole mutation run
  that reported 12 of 12 survivors — including a mutant that deleted the verdict entirely,
  which is impossible. `python3 - "$f" <<'PY' … PY < /dev/null` redirects stdin *after* the
  heredoc is attached, so python reads nothing, does nothing, and **exits 0**. The
  `< /dev/null` was itself a fix for an earlier harness that hung reading stdin; the right
  place for it is on commands that are not already fed by a heredoc. If every mutant
  survives, suspect the harness before the tests: run one mutation by hand and confirm the
  file on disk actually changed.
- **STARTING `dockerd` COINCIDED WITH POSTGRESQL GOING DOWN.** Immediately afterwards
  every `rake` task failed with `PG::ConnectionBad: connection refused`, which surfaced
  first as `ActiveRecord::Migration` complaining about a pending schema — so it reads as
  a broken migration and cost a wrong diagnosis before `pg_isready` was tried.
  `service postgresql start` restores it with its data intact. Not proven to be causal
  (the container also idles, §3's own entry), but the two have now happened together;
  re-check the database before believing the next red run.
- **THE GOTENBERG WORK NEEDS TWO CONTAINERS, and the second one is the point.** T-34's
  credential check has to be OBSERVED failing, so a run needs an authenticated instance
  AND an unauthenticated one:

      docker run --rm -d --name gt-auth -p 3098:3000 \
        -e GOTENBERG_API_BASIC_AUTH_USERNAME=rrd -e GOTENBERG_API_BASIC_AUTH_PASSWORD=s3cret \
        gotenberg/gotenberg:8 gotenberg --api-enable-basic-auth
      docker run --rm -d --name gt-open -p 3099:3000 gotenberg/gotenberg:8

  Then `RRD_GOTENBERG_URL=http://127.0.0.1:3098 RRD_GOTENBERG_OPEN_URL=http://127.0.0.1:3099
  RRD_GOTENBERG_USERNAME=rrd RRD_GOTENBERG_PASSWORD=s3cret`. `spec/render/gotenberg_service_spec.rb`
  SKIPS with a reason without them, and **the corpus FAILS — it does not report gotenberg as
  unavailable any more.** That sentence was true while the engine was `verification: pending`
  and became false with the promotion on 2026-08-11: an engine the catalogue calls `corpus`
  and cannot reach is a raise, by design (`conformance_spec.rb`'s three-state rule).
  A third, `--chromium-disable-javascript` **and** authenticated, is what proves the
  JavaScript check fires — with no credential it fails at the credential arm first and
  the JS arm is never reached, which reads as the JS check passing.
- **DOCKER'S `tmpfs` DEFAULT IS `noexec`, and `noexec=false` is not how you say otherwise.**
  `docker-compose.gotenberg.yml` mounts `/tmp` as a tmpfs because the root filesystem is
  read-only, and Chromium is launched from a path Gotenberg maps in there. Written
  `/tmp:rw,noexec=false,…` the daemon refuses outright — *"invalid tmpfs option"* — which
  is the useful kind of mistake, because the container does not start rather than starting
  and failing every render. The spelling is `exec`.
- **`rsync` may be absent.** `redmine_clone.sh` fails with exit 127 at the mirror step.
  `sudo apt-get install -y rsync`.
- **`./.codex/redmine_clone.sh` WITH NO ARGUMENT DEFAULTS TO `5.1-stable` AND SWITCHES THE
  EXISTING CLONE'S BRANCH** (`redmine_clone.sh:4`, `REDMINE_VERSION="${1:-5.1-stable}"`).
  Re-mirroring "just to pick up an edit" therefore moves a 6.1 clone to 5.1, and the gems in
  `redmine/vendor/bundle` were installed for whichever branch was there before — so the next
  run fails somewhere unrelated. **Always pass the branch**: `./.codex/redmine_clone.sh
  6.1-stable`. Confirm with `cd redmine && git rev-parse --abbrev-ref HEAD`.
- **A recycled container keeps `redmine/` and loses the running services.** `pg_isready`
  answers "no response", `bundle install` from the PLUGIN root fails with *"Could not find gem
  'liquid'"* — the gems live in `redmine/vendor/bundle`, not in a system gem path, so every
  ruby/rspec/rake invocation runs from `redmine/`. `service postgresql start` brings the
  database back with its data intact.
- **RUNNING THE DB-LESS `rspec spec` SUITE WRECKS THE PLUGIN TABLES IN `redmine_test`, AND THE
  NEXT MINITEST RUN LOOKS LIKE A BROKEN MIGRATION.** Same cause as the bullet below —
  `spec/adapter`'s `load_schema!` uses `force: true` — but the symptom is one step further
  on and cost an independent review two false diagnoses on 2026-08-08. After `rspec spec`,
  `rake redmine:plugins:test` reports around a hundred errors, and
  `rake redmine:plugins:migrate` does NOT repair it: the `schema_migrations` rows survived,
  so the migration is a no-op. Both halves have to go:

  **The table list used to be spelled out here and had gone stale — it named seven tables
  and the schema had eleven, so following it left four behind and the migration still
  failed on the first one it met.** It is now derived from the connection, which cannot go
  stale and does not need editing when a migration adds a table. `force: :cascade` because
  the foreign keys between them make the drop order matter otherwise.
  `reporter_project_tabs` is deliberately NOT matched: FR-69 requires it to survive a
  rollback, and migration 001 recreates it only if it is absent.

      cd redmine && LANG=C.UTF-8 RAILS_ENV=test bundle exec rails runner '
        c = ActiveRecord::Base.connection
        c.tables.grep(/\Areporter_dashboards_/).each { |t|
          c.drop_table(t, if_exists: true, force: :cascade) }
        c.delete("DELETE FROM schema_migrations WHERE version LIKE " +
                 c.quote("%-redmine_reporter_dashboards"))'
      cd redmine && RAILS_ENV=test bundle exec rake redmine:plugins:migrate

  **Run Minitest BEFORE rspec, or repair in between.** Combined with the gates-before-suite
  rule for migrations, the order that always works is: gates → `migrate_updown.sh` →
  Minitest → rspec.
- **Never run two things that load `spec/adapter/adapter_helper.rb` at the same time.** They
  share one database; `load_schema!` recreates every table with `force: true` and `seed!`
  deletes every row, so the second process pulls the ground out from under the first. It cost
  a session two false diagnoses in one afternoon — first
  `PG::UndefinedTable: relation "users" does not exist` halfway through a working run, then a
  bench example reporting an **empty** substrate that was demonstrably there minutes earlier,
  both of which read as ordering bugs in the specs. It is not only `rspec`: a throwaway
  `bundle exec ruby` probe that requires the harness does exactly the same damage. Check with
  `pgrep -af rspec` (the `-f` matters — the process name is not "rspec") before starting
  anything, and when a long benchmark is in flight, wait.
- **PostgreSQL does not survive idle time.** `sudo service postgresql start`, then
  `pg_isready`. A stopped server surfaces as `ActiveRecord::ConnectionNotEstablished`
  in a `before(:suite)` hook, which reads like a spec bug.
- **Redmine 5.1 needs Ruby ≤ 3.2.** A container on 3.3+ cannot satisfy its Gemfile, so
  `detect_ruby_version` correctly refuses rather than running on an unsupported Ruby.
  5.1 is a CI-only branch unless `mise` is available.
- **`mise` is usually absent.** `.codex/ruby_version.sh` therefore prefers the Ruby
  already on `PATH` whenever it satisfies Redmine's own Gemfile — which covers 6.0,
  6.1 and 7.0 on a 3.3/3.4 container.
- **A FULL REDMINE CHECKOUT IS USUALLY OBTAINABLE, AND SEVERAL ENTRIES IN THIS FILE ASSUMED IT
  WAS NOT.** Done on 2026-08-07 in a cloud session that had been told there was no way to make one.
  `mise` is indeed absent — and `detect_ruby_version` returns **empty** for 6.1-stable on a 3.3
  container, meaning *use the Ruby on PATH*, so `mise` is never consulted. The only real blocker was
  `rsync`, which is one `apt-get install` away (see the first bullet in this section). Four commands:

      apt-get update && apt-get install -y rsync
      REPORTER_PLUGIN_PATH=/nonexistent ./.codex/redmine_clone.sh 6.1-stable
      REQUIRE_REPORTER_PLUGIN=0 ./.codex/test_setup.sh
      # ~6 minutes, mostly `bundle install`

  What that buys is the difference between arguing and measuring: the full-application Minitest
  suite, `rake redmine:plugins:migrate` in both directions, and `rails runner` against a booted app.
  T-36's whole acceptance rests on it, and it was expected to be `UNVERIFIED`.
  **`/opt/rbenv/versions/3.3.6/` also carries 3.1.6 and 3.2.6**, so 5.1-stable (which needs
  `< 3.3.0`) is reachable too by putting `/opt/rbenv/versions/3.2.6/bin` first on `PATH` — not tried
  yet, and worth a try before writing "CI only" again.
- **`spec_liquid` FAILS THREE EXAMPLES UNLESS `LANG` IS SET, and they look like escaping
  defects.** Measured 2026-08-08. With no locale — which is a bare container's default —
  Ruby's `Encoding.default_external` is **US-ASCII**, so `JSON.parse` on the output of
  `| json` raises `Encoding::InvalidByteSequenceError: "\xE2" on US-ASCII` for the three
  payloads carrying U+2028/U+2029. That reads as FR-19's escaping being broken and is the
  container. `LANG=C.UTF-8 bundle exec rspec … spec_liquid` is **301 examples, 0 failures**;
  without it, 3 failures on an unmodified tree. Same root cause as §1's `File.read` entry,
  one layer out: name the encoding, or give the process a locale.

      LANG=C.UTF-8 bundle exec rspec -I plugins/<name>/spec_liquid plugins/<name>/spec_liquid

- **`rspec` and `activerecord` are NOT installed in a fresh container**, so
  `/opt/rbenv/versions/3.3.6/bin/rspec -I spec spec` fails with *"command not found"* and the
  adapter specs fail to LOAD with `cannot load such file -- active_support` (which reads like a
  broken spec, not a missing gem). `gem install rspec activesupport activerecord pg liquid
  --no-document` fixes both. The rspec-from-inside-Redmine path CI uses does not need them because
  Redmine's own bundle supplies them.
- **Switching Redmine branches** used to fail silently because `test_setup.sh` dirties
  Redmine's Gemfile. `redmine_clone.sh` now discards that and asserts `HEAD`. If you
  see a run reporting one Redmine version while behaving like another, check this first
  — it is exactly what happened once.

---

## 4. What has actually been executed

`CLAUDE.md` hard rule 3: an untested configuration is unsupported. This is the honest
record as of the last local run.

| Configuration | Executed? | Result |
|---|---|---|
| Redmine 6.1-stable, standalone, PostgreSQL 16 | **yes, locally (2026-08-05)** | 956 rspec + 96 adapter + 217 corpus + 133 minitest, 0 failures |
| **Redmine 6.1-stable, standalone, PostgreSQL 16 — after D-1's fix** | **yes, locally (2026-08-05)** | 1127 rspec + 156 adapter + 217 corpus + 139 minitest, **0 failures**. Plus `spec/golden` from the PLUGIN CHECKOUT (where gate G7 has its git history): 0 pending. The corpus is byte-identical to before the fix — all 176 recorded values unchanged |
| **D-1's FIRST attempt, on MariaDB (CI run 31034989145)** | **YES, and it is why that attempt was replaced** | `corpus (MariaDB 11)` **green** — the fix was correct, and the overlay was rightly emptied. `adapter (MariaDB 11)` ran **over 35 minutes without finishing** against 5 m 39 s before it: the conditional-aggregate shape is pathologically slow on MariaDB at 10 000 issues. Correctness confirmed, performance refuted, in the same run |
| **D-1's fix on MariaDB (CI run 31036305443)** | **YES — 17 of 17 jobs green** | `adapter (MariaDB 11)` green in **4 m 16 s** of specs against **5 m 39 s** before the fix, and `corpus (MariaDB 11)` green with the overlay EMPTY and its exhaustiveness assertion live. Correctness AND performance confirmed on the engine the defect lives on. **The wall clock is half the measurement here** — the first attempt was green on the corpus too |
| Redmine 6.1-stable, standalone, **MariaDB 10.11** | **yes, locally** | 313 adapter+corpus, 0 failures. **The run that found defect D-1** |
| Redmine 6.1-stable, standalone, **MySQL 8.0.46** | **yes, locally** | 97 adapter + 214 corpus, 0 failures (before the last two cases were added). **The run that refuted D-1's scope** and exposed E-1 |
| **T-12/T-13: the engine conformance corpus, Chromium 141** | **yes, locally (2026-08-06)** | 20 of 20 fixtures pass — geometry, orientation+margins, footer tokens, page breaks, backgrounds, flexbox, the readiness six, inline assets, egress denial, typed refusal, a 2 000-row envelope, fonts, pathological input and the escaping payload set. Run as a **non-root user**, sandbox on, `--no-sandbox` never passed. **It found three defects on its first run** (§Findings E-2, E-3, E-4) |
| **T-12/T-13 DB-less half** | **yes, locally (2026-08-06)** | 155 examples green as root with no browser (45 pending), and 155 green as `rrd` with Chromium (22 pending — wkhtmltopdf, skipping with its reason). Includes the harness's own negative tests and 30 browser-less adapter examples |
| **`:wkhtmltopdf`** | **YES — and PROMOTED to `verification: corpus` on 2026-08-06** | Its first run ever (CI 31059574558) was 13 of 20; four failures were fixture bugs, one a real egress defect, and two were held as a curator decision (§Findings E-5). All seven are resolved, and the two that looked like capability differences turned out to be an **unpatched-Qt build** (§Findings E-18). Against the patched build CI uses: **18 PASS / 0 FAIL / 2 SKIP**, both skips naming `:readiness_expression`, an undeclared capability — G12's three-state rule working. The matrix was **regenerated from that run** (`RRD_MATRIX_WRITE=1`) and re-verified against a second clean run: 67 examples, 0 failures, 2 pending. Its twenty cells are now real, and a regression in any of them is a build failure |
| **`:gotenberg`** | **YES — PROMOTED on 2026-08-11, and CI HAS NOW RUN UNDER ENFORCEMENT** | **Run 31488625241 (`cc46172`) is the first CI run with this engine at `corpus`: 26 of 26 jobs green**, `Render conformance (G9, G12)` included — so the enforcing configuration is no longer a claim about a run nobody had read, which is INV-7's whole point. The condition E-27 row 1 set was met: CI run 31408759956 and every run since (31469385598 on `ee22bd6`) reported **19 pass / 0 fail / 1 skip** with zero occurrences of "gotenberg is not available here", and the same numbers came back from a local run against two real containers on 2026-08-11. The one skip is `F-14-asset-inline` for an `:asset_inline` this engine does not declare — G12's first arm, not a gap. Matrix **regenerated from a run in which all three corpus engines executed** (`RRD_MATRIX_WRITE=1`; chromium_cdp 20/0/0, wkhtmltopdf 18/0/2 patched-qt, gotenberg 19/0/1), which also **deleted the whole "Columns that are not measurements" section** — no engine is unverified any more, so `Matrix.footer_section` emits nothing. **What it costs, accepted knowingly:** a Gotenberg that will not come up in `render-smoke` is now a HARD failure, so every run of that job depends on the registry serving the pinned digest |
| **FR-50 — the install-wide engine selection** | **yes, locally (2026-08-11)** | **2650 DB-less examples, 0 failures**, 137 pending (was 2601 at `ee22bd6`), plus the full-application suite and the settings round trip. **16 mutations, 16 killed** — and the two that survived the first run are the entry worth keeping: one was a REDUNDANT SORT (`from_settings` normalises the id list before `new` does, so mutating the instance-level sort measured the class method twice) and one was a GUARD WITH NO BEHAVIOURAL SIGNATURE (blanking `selected_engine_id: ''` changes no outcome, because no engine is named `''`). Both were fixed the way §1 says: assert the claim where it is MADE — on the constructor, and on the reader — rather than through behaviour that cannot see it |
| **T-14: the render preflight, BOTH engines, in CI (run 31079493206)** | **YES** | **chromium_cdp 9/9 in 465 ms and wkhtmltopdf 9/9 in 380 ms**, both with the hosted image `EXPECTED_FAILURE` — INV-8 containment confirmed on two independent engines. This is the first time wkhtmltopdf has drawn the probe at all. It was **not** an argument for promoting it — `verification: corpus` is about T-12's twenty fixtures, and at the time neither of E-5's two open items had moved. Both have since, and the promotion happened on the corpus evidence rather than on this |
| **T-14: the render preflight, Chromium 141** | **yes, locally (2026-08-06)** | 9 of 9 checks pass in **943 ms**, run as the non-root user (see the Chromium note in §1): page breaks → 2 pages, `Page 1 of 2` compiled, page rgb[0,170,255] and badge rgb[204,0,0], the inline data: image decoding to its own colour, `CANVAS-STATE drawn`, `SHELL present`, and the Redmine-hosted image `EXPECTED_FAILURE` — INV-8 containment confirmed against a real browser rather than argued. **The first run took 17.5 s and was red**; the three defects it found were all in the diagnostic, not the engine (§Findings E-10) |
| **T-14 DB-less half** | **yes, locally (2026-08-06)** | 41 examples green with no browser (`spec/render/preflight_spec.rb`, `preflight_command_spec.rb`), including every one of the six document checks driven RED against a canned single-page PDF. `spec/render` + `spec/conformance` together: 205 examples, 0 failures, 49 pending. The Minitest half (`test/functional/reporter_preflight_controller_test.rb`, `test/unit/render_preflight_rake_test.rb`) **has not been executed** — it needs a booted Redmine, so the `standalone` CI job is its first run |
| **T-18: the drop layer, Liquid 4.0.4 AND 5.13.0** | **yes, locally (2026-08-06)** | 185 examples green under each major, run the way CI runs them (`rspec -r /tmp/pin.rb spec_liquid`). Includes the substitutability battery against `VersionDrop` as well as `NamedRefDrop`, and both E-8 gaps pinned as they are |
| **T-18: the gating performance criteria, PostgreSQL 16** | **yes, locally (2026-08-06)** | 31 adapter examples, 0 failures. Zero `Issue` instantiations at 10 and 10 000; one query for `size` at both; a custom field across 400 issues in 4 queries and a second for free; the cap AT and one past. The full adapter suite is **187 examples, 0 failures** with the harness's new `attachments` table and `Issue.visible`/`TimeEntry.visible` scopes, and the **corpus is unmoved — 217 examples, all 176 recorded values identical** |
| **T-18 in CI (run 31085742725)** | **YES — 18 of 18 green, first try** | Both things the local run could not answer are answered. `adapter (MySQL 8.0)` and `adapter (MariaDB 11)` green, so the batch's four visibility-filtered queries behave on all three engines. **All four `minitest` branches green** — 5.1, 6.0, 6.1 and 7.0 — which is the real answer to the Zeitwerk question in §1: `liquid/drops/` boots on every supported Redmine. All three `corpus` jobs green, so G7 holds across the harness change |
| **T-19: the filters and the lint, Liquid 4.0.4 AND 5.13.0** | **yes, locally (2026-08-06)** | 276 examples green under each major. Includes the `StandardFilters` enumeration (49 names on 4.0.4, 61 on 5.13.0, pinned per version), the 21-filter inventory, and the OQ-C measurement that closed it |
| **T-19: the escaping regression table, node v22** | **yes, locally (2026-08-06)** | 43 examples. 18 payloads through `| json`, each asserted to PARSE and to round-trip byte-for-byte; the OLD idiom pinned as measured — SyntaxError on a backslash terminator, and no payload reaching code position. **One assertion in it was wrong on the first run** and is now written from what the output actually is: the combined payload PARSES, because `| escape` turns its quotes into `&#39;` and `\&` is an identity escape. Two payload shapes, two outcomes |
| **T-19: the shipped copy-paste surface** | **yes, locally (2026-08-06)** | Both examples and all 25 README ```liquid snippets are FR-19-clean; the frozen reference copies asserted STILL defective, because `verification-liquid-js-escaping.md` cites their line numbers. 1433 DB-less examples, 187 adapter, corpus **byte-identical — 217 examples, all 176 values unchanged** |
| **T-20: the retirement, Liquid 4.0.4 AND 5.13.0** | **yes, locally (2026-08-06)** | **1460 DB-less examples** (was 1433), 0 failures, 114 pending — the deprecation shim's log-once, both `TagContext` branches, the retired-surface guard and the six inert-block lint cases. **278 spec_liquid under each major** (was 276), including the two version-project spellings `{% version_rollup %}` templates read. All six gates green, `LAYER_PURITY_MODE=strict` included, and `zero_reporter` down to **16 files / 16 entries** from 18. The retired-surface guard was **negative-tested**: a planted `Object.const_get('RedmineReporter::Liquid::Drops::IssueDrop')` fails it, a comment naming the class does not. **NOT RUN HERE: adapter, corpus, minitest** — no database and no Redmine checkout in this container, so CI is their first execution |
| **T-16: the chart layer, DB-less** | **yes, locally (2026-08-06)** | **1562 rspec examples, 0 failures** (was 1462), including 10 SVG goldens as deterministic text, the six families through both emitters, and the escaping payload set through the JSON data block. All seven gates green, `vendor_integrity` new and **negative-tested on all three arms** — a corrupted vendored byte, an unmanifested vendored file, and a planted CDN reference each fail it |
| **T-16: the shared-layout falsifier, Chromium 141** | **yes, locally (2026-08-06)** | Run as the non-root user. `chart.chartArea` against `ChartLayout#plot`: left 0.86%, right 0.00%, top 0.22%, bottom 1.17% — **worst edge 1.17% against a 2% tolerance** — and Chart.js used exactly the pinned ticks, min and max with no readiness degradation. **Its first run was red twice**, at 21.88% and then 4.94%, and both were real defects (§Findings E-16) |
| **T-33: the asset layer, DB-less** | **yes, locally (2026-08-06)** | **1832 rspec examples, 0 failures** (was 1562), 116 pending — 265 new, of which 39 exist because the review found four blockers (§Findings E-17): the policy's fail-closed collapse asserted as an equality of every answer, the fetcher's closed header set through a **recording double**, the resolved-IP check against 18 addresses including the v4-mapped forms, containment against a literal / percent-encoded / **double**-encoded `..` and a **symlink out of the root**, and the structural-inline terminator payloads. All seven gates green, `layer_purity` **strict** with its two new arms **negative-tested in both directions**. `spec/golden` green (166) after `git fetch --unshallow` — see the trap in §1 |
| **T-13: the conformance corpus, BOTH engines, LOCALLY** | **yes (2026-08-06) — first time for wkhtmltopdf outside CI** | On the build CI uses (`0.12.6.1`, **patched qt**): `chromium_cdp` Chrome/141.0.7390.37 **20 pass / 0 fail / 0 skip**, `wkhtmltopdf` **18 pass / 0 fail / 2 skip** — 67 examples, 0 failures, and the two skips are `:readiness_expression`, which E-5 accounted for. **Nothing is unexplained, so E-5's promotion condition was met — and the curator TOOK the decision on 2026-08-06** (§Findings E-18, and E-5 is now closed). The matrix has since been regenerated from this run and carries wkhtmltopdf's cells. Run as the non-root `rrd` user with `RRD_CONFORMANCE=1`. **On the DISTRO build it is 17/1/2 and the failure is the footer fixture — that build cannot do footers at all**; see §1 |
| **OQ-L settled by measurement — Mermaid 11.16.1 through both engines** | **yes, locally (2026-08-06)** | One probe document, both engines. Chromium 141: `mermaid.run()` resolves and both node labels extract from the PDF as SVG text. wkhtmltopdf 0.12.6.1 patched: **`PROBE-NO-MERMAID-GLOBAL`** — the bundle never defines its global, because Mermaid 11 is an esbuild IIFE opening with `\|\|=` (ES2021) that Qt WebKit cannot parse (`--debug-javascript` names it: `SyntaxError: Parse error`, once, at
the bundle's script line) — established by a DISCRIMINATOR, not inferred: two three-line documents differing only in `x.a = x.a \|\| 1` versus `x.a \|\|= 1` print `ES5-OK-1` and `INIT` respectively, and `INIT` means the statement BEFORE the assignment never ran, so the whole script block failed to parse. That rules out a timeout, the 3.5 MB size (a same-size ES5-only script runs fine) and the probe's
own JS. **`||=` is not the only blocker**: this build also lacks `globalThis`, which the bundle's
final line uses to publish the global — so "transpile the `||=`" is not a route back. **So `:mermaid` is absent for wkhtmltopdf despite `:javascript` being present**, which is the answer T-35's acceptance list expected and now has. Probe kept out of the repo deliberately — vendoring Mermaid is T-35's job, with `THIRD_PARTY.md` and the digest gate |
| **T-35: Mermaid, DB-less** | **yes, locally (2026-08-06)** | **1852 rspec examples, 0 failures** (was 1832), 92 pending — 20 new for `mermaid_boot.js` including a real `vm.Script` ES5 parse. **301 `spec_liquid` under each major** (was 278): the 23 tag examples found **three cross-major defects** (§Findings E-19). All seven gates green, `vendor_integrity` with two vendored files |
| **T-35 end to end, both engines** | **yes, locally (2026-08-06)** | One document through the tag, the T-33 resolver and both adapters. `chromium_cdp` Chrome/141: diagram **drawn** — node labels and the interpolated value extract from the PDF, the literal source is gone, no degradations. `wkhtmltopdf` 0.12.6.1 patched: **source still visible** and marked unsupported, only the expected `legacy_engine` degradation. The resolver inlined all three scripts, the 3.5 MB bundle via its `data:` fallback. Support matrix REGENERATED from a real run: one new row, `:modern_javascript` yes/yes/— |
| **T-33 under both Liquid majors** | **yes, locally (2026-08-06)** | 278 `spec_liquid` examples under 4.0.4 and under 5.13.0, unchanged from T-20 — the asset layer touches no Liquid surface, and that is the point of it naming neither layer |
| **T-40: the permission model, DB-less** | **yes, locally (2026-08-06)** | **1933 rspec examples, 0 failures** (was 1852), 92 pending — unchanged skip count. All seven gates green. **Fourteen negative tests, each observed to fail an intended example**: the four bypasses T-40's review used (an unguarded action in a NAMESPACED controller; `authorize` scoped away from three of four mapped actions by `only:` plus `skip_before_action`; a `define_method` in a controller body; a `def` inside a version conditional), plus a new unguarded action, a DELETED `before_action :authorize`, a `permission_*` key removed from `ru.yml`, an authoring entry that types `requires` instead of deriving it, a locale label added for an unregistered permission, a mapped action that does not exist, a `lands_in` naming a task absent from the plan, and three against §4.1's table — a drifted name, a wrong task, and the heading removed, which must fail LOUDLY rather than quietly extract nothing. **Several fail two or three examples rather than one** (the coverage check and the AST meta-test both, which is the pair working as designed); an earlier claim of "the intended example and only it" was wrong and is withdrawn. **One of them found a hole in the fix itself** — a guard that was absent answered `nil`, i.e. "covers every action", so deleting `before_action :authorize` outright passed the per-action check; absent is now `[]` and the case has its own example. **NOT RUN HERE: the functional suite, which EXISTS and covers this** — `test/functional/reporter_project_{pages,tabs}_controller_test.rb` grant and withhold these permissions and assert 200/403, and they are the only thing that proves the registration loop registered anything in a booted Redmine. No Redmine checkout in this container, so CI is their first execution against the loop |
| **T-22 + T-36: the schema and the rollback — THE FULL-APPLICATION SUITE, LOCALLY** | **yes (2026-08-07), and this is the first session to run it** | A real Redmine 6.1.3 checkout was obtainable after all (see §3): `rake redmine:plugins:migrate` in both directions, `rails runner` against a booted app, and **`rake redmine:plugins:test` — 258 runs, 1565 assertions, 0 failures, 0 errors, 4 skips**. That run is what found **§Findings E-21**: two of T-33's tests had been erroring since they were written, because the class calls `l(...)` without `Redmine::I18n`, so `test_the_partial_uses_locale_keys_and_not_hardcoded_english` had never asserted anything |
| **T-22 + T-36: gate G11, up → VERSION=0 → up → reinstall** | **yes, locally (2026-08-07), Rails 7.2 / PostgreSQL 16 ONLY** | `script/migrate_updown.sh`, both arms. **NEGATIVE-TESTED with five plants**: a non-unique occurrence index, a down that leaves its table behind, a 001 whose down DROPS `reporter_project_tabs` (both arms catch it), a leftover plugin table poisoning the baseline, and a residue whose NAME merely contains `reporter_project_tabs`. **5.1, 6.0 and 7.0 are the `migrate-updown` CI job's to answer and have never been run** — INV-7 applies to this exactly as much as to an engine |
| **T-22 + T-36: DB-less** | **yes, locally (2026-08-07)** | **1996 rspec examples, 0 failures, 116 pending** (was 1933/0/116 — **skip count unchanged**). All eight gates green, `layer_purity` strict included, `zero_reporter` still **16/16**. The new gate's eight rules each have a committed fixture that fires them, and **eight of those fixtures are bypasses an independent review walked through** while the first reader reported nothing |
| **T-23: template CRUD, preview and the permission promotion — THE FULL-APPLICATION SUITE** | **yes, locally (2026-08-07)** | `rake redmine:plugins:test` — **340 runs, 1810 assertions, 0 failures, 0 errors, 4 skips** (was 258/4 at T-22, 260/4 at the start of this session; the skip count has not moved). 58 functional, 19 unit and 3 integration runs are new. **2042 DB-less rspec, 0 failures, 75 pending**; `spec/golden` 166 examples 0 pending from the PLUGIN CHECKOUT (G7); all eight gates green with `LAYER_PURITY_MODE=strict`, `zero_reporter` still **16/16**; `script/migrate_updown.sh` green on both arms. **The functional suite is the only thing that can prove a controller guards anything**, and it is where every authorization assertion in T-23 lives |
| **T-23: the layer_purity `reporting` arm** | **yes, locally (2026-08-07), negative-tested in four directions** | A planted `Net::HTTP`, a planted `cookies` and a trailing comment on a CODE line each fail it; a whole-line comment naming `Net::HTTP`, `Faraday` and `cookies` does not. The composition root may name BOTH layers — that is what it is for — and may not hold the network or read request state |
| **T-25 (parts 1 and 2): the scheduler's arithmetic and its runner — THE FULL-APPLICATION SUITE** | **yes, locally (2026-08-07), and these are the POST-REVIEW figures** | `rake redmine:plugins:test` — **390 runs, 2042 assertions, 0 failures, 0 errors, 4 skips** (was 340/0/0/4 — **skip count unchanged**). 36 new Minitest examples driving the tick against a real database, because every claim the runner makes is about a WRITE: that the unique index refuses a second claim, that `update_columns` leaves an untouched column alone, that a run row stops saying `running`. A double cannot fail an index. DB-less: **2123 rspec examples, 0 failures, 126 pending** (was 2042). Nine gates green including `layer_purity` strict, G11 both arms, `zero_reporter` still 16/16, and the 2.7 floor |
| **T-25: every guard in the runner, negative-tested one at a time — TWICE, before and after an independent review** | **yes, locally (2026-08-07)** | Each guard removed in the mirrored copy, the one test that names it re-run, and confirmed RED: the at-most-once claim, the delivery contract (a port answering `nil` must not read as a success), `last_run_on` not advancing on a failure, the guarded recording of a failure (an exception in a rescue clause is not caught by that clause — FR-41 violated by the code written for it), the bounded error text, the schedule's own timezone, draft-versus-failure, S-7's `update_columns` in three mutations, and rule 5's column filtering in two. **Three of the first ten were GREEN under mutation and the examples were rewritten** — see the §1 traps. A fresh-subagent review then REJECTED the result with one blocker and five majors, every one backed by a probe it ran; the eight fixes were negative-tested the same way (14 mutations, 13 red) and the one that stayed green — a `[date, last_run_on].max` that `#regressed?` makes provably unreachable — was DELETED rather than kept as a second mechanism for one property. Two clauses survive as documented redundancy rather than load-bearing guards: `logged?` in the render identity (`AnonymousUser`'s status already fails `active?`) and nothing else |
| **T-25: the layer_purity `scheduling` arm** | **yes, locally (2026-08-07)** | Same pattern as the `reporting` arm and the same forbidden set. The scheduler runs from a rake task with no request behind it, so a cookie or a session there is not a leak across a boundary but a value that cannot exist |
| **T-25 (part 4): the schedule UI and its two permission promotions — THE FULL-APPLICATION SUITE** | **yes, locally (2026-08-08), POST-REVIEW figures** | `rake redmine:plugins:test` — **494 runs, 2392 assertions, 0 failures, 0 errors, 4 skips** (was 451 before the UI — **skip count unchanged throughout T-25**). DB-less **2123 examples, 0 failures, 126 pending**, including all 92 permission-map examples against the two now-live §4.1 rows. Nine gates green, `layer_purity` strict, locale parity **176 keys x 9 files** with identical interpolation placeholders |
| **T-25 part 4's independent review: a third REJECT, and the only one to find a privilege escalation** | **yes, locally (2026-08-08)** | **Two blockers, both escalations, both reproduced end to end**: `render_as_user_id` permitted and unfiltered (admin-visibility report into an ordinary member's inbox, with a private issue in it), and `#test_send` coupling FR-45's stored identity to delivery-to-the-presser with no tampering at all. Eight majors, four of them visible on the first page an operator opens — a `Translation missing` header, a private template's NAME disclosed as the page heading, an identity picker that never pre-selected (so no `render_as: user` schedule could be saved from its own form), and a partial PATCH silently deleting every recipient. All 16 fixed; **19 mutations run, 19 red**, two of which needed sharper examples after mutation showed the first attempt vacuous |
| **T-25 (part 3): the delivery, the mailer, the rake task and FR-44 — THE FULL-APPLICATION SUITE** | **yes, locally (2026-08-07), POST-REVIEW figures** | `rake redmine:plugins:test` — **451 runs, 2256 assertions, 0 failures, 0 errors, 4 skips** (was 390/0/0/4 before T-25 part 2 — **skip count unchanged throughout**). DB-less unchanged at **2123 examples, 0 failures, 126 pending** — the delivery is application layer and has no DB-less half. Nine gates green, `layer_purity` strict, locale parity **129 keys x 9 files** with identical interpolation placeholders in every language |
| **T-25 part 3's independent review: a second REJECT, 1 blocker + 5 majors + 6 minors + 3 nits, every one probe-backed** | **yes, locally (2026-08-07)** | The blocker was the heartbeat crying wolf on a healthy install (see §1). The majors: the owner's failure notice quoted a correlation id that existed nowhere else (`ReportRun` mints its own per document — run row `3a8cd94c…`, owner mail `23688ef7…`); **no owner notice at all** for the three failures that happen BEFORE `delivery.call`, of which a locked render identity is the likeliest in production, while the README said otherwise; an empty per-record report mailed as a success **with no attachment**; `#as`'s `ensure` unenforced (deleting it left the suite green); and the query-count bound set to the pre-change value, so it could not detect the regression it was written for. All 15 fixed and **16 mutations run, 16 red** — two examples were rewritten after mutation showed them vacuous. A test written for a MINOR then found an unlisted defect: a dangling `template_id` was a `NoMethodError` on nil rather than a failure |
| **T-30: the failure report — THE FULL-APPLICATION SUITE, POST-REVIEW** | **yes, locally (2026-08-08)** | `rake redmine:plugins:test` — **521 runs, 2488 assertions, 0 failures, 0 errors, 4 skips** (was 498/4 — **skip count unchanged**). DB-less **2192 examples, 0 failures, 102 pending** (was 2123/126; the pending count FELL because `poppler-utils` is now installed in this container, so ~24 previously-skipped examples actually ran). Nine gates green with `LAYER_PURITY_MODE=strict`, locale parity **184 keys x 9 files** with identical placeholders, and `script/migrate_updown.sh` green on BOTH arms with migration 008 — the first migration in this plugin that grows an existing table |
| **T-30: every guard, mutation-tested one at a time — TWICE, before and after an independent review** | **yes, locally (2026-08-08)** | **33 mutations, 33 red.** The first 21: the `endobj` delimiter, the PDF string escaping, `encodable?` answering honestly, the message and the detail each planted onto the page, the filename character filter and its empty fallback, `ORIGIN_KEYS.fetch` being a `fetch`, an undrawable VALUE degrading rather than raising, `to_h` carrying the template, the opt-in being consulted at all, the failure keeping the failure's own status, `#show` staying a page, rule 5's column guard, a nil in the column reading as off, the diagnostic naming the template, and the failure notice really having no attachment. One more was observed red during development rather than planted: deleting `add_column` from `schema_recorder.rb` makes G11 report UNKNOWN. A fresh-subagent review then found **four MAJORs**, and the twelve mutations covering their fixes are the rest: the font's own advance widths, a non-ASCII glyph charged the widest, the truncation marker fitted into the column rather than appended past it, a dropped row saying so, the language decided once for the whole document, an undrawable value getting a sentence rather than `?????`, the closed code set, the code inventory that READS THE TREE, the export carrying the flag, the engine and batch origins naming the template, and the two refusals minting a correlation id. **Two of the twelve were GREEN under mutation and both examples were rewritten** — a truncation example whose last kept line was short enough that appending the marker fitted anyway, and a filename example that `report-FAILED--.pdf` satisfied |
| **T-31 (increment 1): the `source` field end to end — THE FULL-APPLICATION SUITE** | **yes, locally (2026-08-08)** | `rake redmine:plugins:test` — **547 runs, 2540 assertions, 0 failures, 0 errors, 4 skips** (was 521/4 — **skip count unchanged**). DB-less **2208 examples, 0 failures, 102 pending** (was 2192). `spec_liquid` **301 examples, 0 failures** with `LANG=C.UTF-8` — see §3, because without a locale three of them fail and look like escaping defects. Nine gates green with `LAYER_PURITY_MODE=strict`; locale parity **190 keys x 9 files**. **The Ruby 2.7 floor gate earned its keep**: it caught an endless method definition in a new test |
| **T-31 (increment 1): every guard, mutation-tested one at a time** | **yes, locally (2026-08-08)** | **25 mutations, 25 red.** The `source` annotation and all three `RenderContext` derivations carrying it; the tag's refusal, its degradation and the legacy path still being issues; the controller's two-arm dispatch, the visibility filter, the project filter and `source` being permitted; `ReportRun`'s closed-set refusal, the context being told the source, and the drops following it; and all five of `TimeEntryVisibility`'s branches. **Three were GREEN and all three examples were rewritten** — a `case`'s `else` that turned out to be a second mechanism (DELETED rather than kept, following T-25's precedent), an administrator short-circuit that the built-in Non-member role made unobservable, and a visibility count the fixture could not discriminate |
| **T-29: the exchange bundle and the streamed archive — THE FULL-APPLICATION SUITE** | **yes, locally (2026-08-09)** | `rake redmine:plugins:test` — **697 runs, 3126 assertions, 0 failures, 0 errors, 4 skips** (was 665/4 — **the skip count did not move**). 32 net new: 21 for the importer against a real database, 9 for the rake wiring, 4 for the archive, less two the archive superseded. DB-less rspec **2392 examples, 0 failures, 103 pending** (was 2340); `spec_liquid` **301, 0 failures**; adapter PostgreSQL 16 **254, 0 failures, 9 pending**; pinned corpus **217, 0 failures**; `spec/golden` from the PLUGIN checkout **166, 0 failures, 0 pending** and `git diff -- spec/golden` empty. Nine gates green with `LAYER_PURITY_MODE=strict` including the new `archive` arm, `migrate_updown.sh` green on both arms, locale parity **247 keys x 9 files** with identical placeholders. **The Ruby 2.7 floor gate earned its keep again**: it caught `Hash#except`, which is Ruby 3.0 core and which ActiveSupport would have supplied at runtime — invisible without the gate |
| **T-29: two baseline deviations, both ENVIRONMENTAL and both resolved before anything was believed** | **yes, locally (2026-08-09)** | The first control run reported **8 skips against a documented 4**. Not a regression: the four extra were `poppler-utils is not installed`, and `apt-get install -y poppler-utils` restored 665/0/4 exactly — and made four previously-skipped assertions actually run. The DB-less suite reported **3 failures on an unmodified tree**, all `invalid byte sequence in US-ASCII` from a spec that READS a source file; `LANG=C.UTF-8` is the fix (§3's `spec_liquid` entry, now true of the main suite too since T-31 added a source-reading spec). Its example count is **2340 rather than the 2298 last recorded**, the difference being exactly the 42 `spec/adapter` examples that go pending without `RRD_ADAPTER_URL` — worth knowing before treating a count as a regression |
| **F-16: the asset layer wired into the render path — THE FULL-APPLICATION SUITE** | **yes, locally (2026-08-09)** | `rake redmine:plugins:test` — **878 runs, 3835 assertions, 0 failures, 0 errors, 4 skips** (was 845/4 — **the skip count did not move**). 33 new: 21 for the wiring against a real `Attachment`, a real `visible?` and a real `Setting.host_name`, and 12 for the degradation helper (§Findings E-25). DB-less rspec **2377 examples, 0 failures, 61 pending** (was 2362/61 — **pending unchanged**); `spec_liquid` **301, 0 failures**; `spec/golden` from the PLUGIN checkout **166, 0 failures, 0 pending** and `git diff -- spec/golden` empty. Nine gates green with `LAYER_PURITY_MODE=strict`, `migrate_updown.sh` green on both arms, locale parity with the new `label_reporter_report_failed_assets` × 9. **`migrate_updown` FAILED first and it was the §3 dirty-database symptom, not the migration** — the repair snippet, plus dropping T-24's stand-in `report_templates`, and it passed on the next run |
| **F-16 after THREE independent reviews (reviewer, adversarial QA, UX)** | **yes, locally (2026-08-09)** | `rake redmine:plugins:test` — **887 runs, 3867 assertions, 0 failures, 0 errors, 4 skips** (was 845/4 at the baseline — **the skip count never moved**). DB-less rspec **2379 examples, 0 failures, 61 pending** (was 2362/61 — pending unmoved); `spec_liquid` **301, 0 failures**; `spec/golden` from the PLUGIN checkout **166, 0 failures** with `git diff -- spec/golden` empty. Nine gates green with `LAYER_PURITY_MODE=strict`, `migrate_updown.sh` both arms, locale parity **303 keys x 9 files** verified by PARSING rather than counting. **Two of the three reviews independently found the same two blockers**, which is what made them worth believing: an asset refusal answering HTTP 500, and `policy_refusal?` blaming the asset policy for five of seven refusal causes — the second with a spec that hand-wrote a reason string the resolver cannot emit, so it passed against the broken code. Eleven further findings are RECORDED rather than closed (§Findings E-26), each with its measurement |
| **F-16: every guard mutation-tested, one at a time** | **yes, locally (2026-08-09)** | **21 mutations, 21 red**, control GREEN on all three targets first. **Two SURVIVED the first round and both were closed with new tests rather than argued away.** *"the factory ignores the mode the operator configured"* is the one to remember: an install set to `:external` would have had `:bundled` behaviour silently, and every other example in the file passed because `:bundled` is what they assert — the fix is an assertion on `policy.effective_mode` and on which of the two refusal WORDINGS comes back. The other, *"build a fetcher even when the policy forbids one"*, is an **equivalent mutant proved by construction** and is written up in §1 |
| **THE FULL MATRIX, RUN LOCALLY IN ONE SESSION — four Redmine versions × three database engines (2026-08-10)** | **YES, and this is the first time every cell has been executed on one tree** | Asked for by the curator after F-16. **Minitest, standalone, PostgreSQL 16, plugin suite `redmine:plugins:test`:** 5.1-stable (Ruby 3.2.6, Rails 6.1) **897 runs / 3808 assertions / 0F / 0E / 5 skips**; 6.0-stable **897 / 3906 / 0F / 0E / 4 skips**; 6.1-stable **897 / 3906 / 0F / 0E / 4 skips**; 7.0-stable (Rails 8.1) **897 / 3906 / 0F / 0E / 4 skips**. The run COUNT is identical across all four, which is the thing worth checking — a version-conditional `def` that silently defined no test would show up here and nowhere else. **The fifth skip on 5.1 is D-3 working**: `test_reporter_dashboard_icon_uses_the_svg_sprite_on_redmine_6_and_later` skips with *"this Redmine (5.1.13.stable) has no SVG icon sprite"*, which is the divergence the predicate exists to make testable. The other four are the permanent reporter-widget skips on every version. G10 holds: every skip carries a reason, and the total is version-conditional by design rather than drifting |
| **The same matrix, DATABASE half: `spec/adapter` + the pinned golden corpus on all three engines** | **yes, locally (2026-08-10)** | PostgreSQL 16 — adapter **254 examples, 0 failures, 9 pending**, corpus **217, 0 failures**. MariaDB 10.11 — adapter **254, 0 failures, 3 pending** in 5 m 0 s, corpus **217, 0 failures**. MySQL 8.0.46 — adapter **254, 0 failures, 2 pending** in 18.7 s, corpus **217, 0 failures**. **The corpus agreeing on all three is G7's differential**, and it is what says D-1's fix still holds on the engine the defect lives on. The pending counts differ BY DESIGN — each engine skips the examples written for the other two — and the example count does not, which is the assertion that matters |
| **Switching MySQL-family engines: the recipe, because HANDOVER's warning was right and cost twenty minutes** | **yes, locally (2026-08-10)** | The Debian packages conflict and `apt-get purge` inside a subshell that also runs `pkill` exits non-zero without purging — so MariaDB stayed installed while its datadir was deleted. Then `mysql-server` installs and **FREEZES** (`/etc/mysql/FROZEN`) because it finds a foreign datadir. The blocker after that is the one §3 already predicted: **`/etc/mysql/mariadb.conf.d/provider_*.cnf` survives, and `mysqld` aborts on `unknown variable 'provider_bzip2=force_plus_permanent'`** — which reads as a corrupt install and is a leftover config. Working sequence: stop the old server, `rm -rf /etc/mysql/mariadb.conf.d /var/lib/mysql /etc/mysql/FROZEN`, reinstall with `--force-confmiss`, `mkdir -p /var/lib/mysql-files` (mysqld aborts on `--secure-file-priv` before it ever logs anything useful), `mysqld --initialize-insecure`, then start it MANUALLY — `service mysql start` fails here exactly as `service docker start` does |
| Redmine 7.0-stable, standalone, PostgreSQL | yes, before T-01 | 906 rspec + 86 adapter + 114 minitest, 0 failures, 4 skips |
| Redmine 6.1-stable, with reporter, PostgreSQL | yes, before T-01 | 906 + 86 + 114, 0 failures, 0 skips |
| Redmine 5.1-stable / 6.0-stable | **no, and cannot be** | 5.1's Gemfile refuses Ruby 3.3+; CI only |
| **CI** | **YES — first run 2026-08-05, run 30992686636** | 17 jobs, **5 red**: `corpus` ×3 (a missing `working-directory`), `adapter` MySQL 8 (D-1's scope + E-1), `minitest` 5.1 (**92 errors — D-2**). Everything else green |
| **CI, second run 30998558913** | **YES** | **16 of 17 green**, including all three `corpus` jobs — the first real proof of gate G7's differential on PostgreSQL, MySQL 8 and MariaDB 11. The one red was `minitest` 5.1 again, 92 → **27 errors**, all D-3 (`sprite_icon`) |
| **CI, third run 31000622798** | **YES** | **17 of 17 green** — the first fully green CI run on this branch |
| **T-03: the R7 invariants, PostgreSQL 16** | **yes, locally (2026-08-05)** | 34 examples, 0 failures. Every workload's query count identical at 100 and 10 000 issues; **zero** `Issue` instantiations everywhere; the capped axes bounded and their collapsed totals intact |
| **T-03: the benchmark, PostgreSQL 16** | **yes, locally, twice (2026-08-05)** | 27 cells, 20 warm runs after 3 discarded, 4-core Xeon @2.80GHz. **The two runs disagree by up to ×1.26 on p95**, and `version_rollup.costs@100000` was *invalid* in the first (dispersion 0.417) and valid in the second (0.090) — finding P-3, and the reason no timing is a gate. The HTML\|PDF axis is **not measured and recorded as blocked** (P-2) |
| **T-02: the survey, PostgreSQL 16** | **yes, locally (2026-08-05)** | 22 adapter examples + 53 linter + 25 formatter, 0 failures. The rake task was also **run end to end** on both paths — reporter absent, and against temporary reporter-shaped tables seeded into `redmine_test` and dropped again — because reading the real output is what found the duplicate-finding noise and the unwrapped messages |
| **T-03 on MySQL / MariaDB** | **no** | The invariants spec runs in the existing `adapter` CI job on all three engines, so CI answers it; the *benchmark* is deliberately not in CI — a timing on a shared runner is noise, which is what the dispersion rule and the advisory label are about |

**MySQL and MariaDB cannot be installed at the same time** — the Debian packages
conflict, and switching costs an apt purge plus a datadir re-init each way. Both have now
been run locally, one after the other; if you need to switch, `rm -rf /etc/mysql` will
break the *next* server's `!includedir` (the package config has to be reinstalled with
`--force-confmiss`), and a leftover `mysqld` keeps the socket until it is killed by pid.

That first CI run is the most useful thing that has happened to this branch: three of
the five failures were invisible to every local configuration, and one of them (D-2) had
been shipping since v0.5.0.

The counts moved because T-01 added tests, not because anything changed: 906 → 953 rspec
(the corpus's DB-less coverage, the ratchet, the canonicaliser and the compat shim),
86 → 97 adapter (D-1 and the four actors), 114 → 130 minitest (the scope fixture), plus
the 214-example corpus verification, which is a new invocation and only runs with the
reference date pinned. MariaDB 10.11 rather than 11 because that is what the container's
apt repository carries; CI runs 11 and agrees with it.

That last row is the important one. The CI rewrite (secret removal, standalone
minitest, the `gates` and `baseline` jobs) is verified only by local simulation of each
step. **The first real CI run is the real check**, and a red one is information, not a
regression.

The 4 skips in every standalone run are the two report widgets' functional tests. They
need the private reporter plugin, they carry a reason, and they are the accepted cost
of a CI that runs on fork pull requests.

**2026-08-11, the E-30 round** (a fourth review of the E-29 follow-ups, which rejected them).
Executed in this container: `rspec` **2671 / 0 failures / 127 pending in the real working
directory** — read the G7 trap at the top of §1 before comparing that pending count with any
older one — `rake redmine:plugins:test` **920 runs / 0 failures / 0 errors / 4 skips** on
PostgreSQL, the eight `script/gates/*.sh` all OK, the three-engine conformance corpus green
against the real containers (`chromium_cdp` 20/0/0, `gotenberg` 19/0/1, `wkhtmltopdf` 18/0/2),
and **G9 measured rather than assumed**: regenerated with `RRD_MATRIX_WRITE=1` from that run and
`diff`ed against the committed file — identical. 14 mutations against the round's own guards, 14
killed. Not run here, and therefore UNVERIFIED for this round: `migrate-updown` (G11) and
`render-smoke` (G12), neither of which this change reaches — no migration, no capability
declaration, no matrix cell.

---

## 4b. What the next session should start with

**THE THREE OPEN DECISIONS ARE TAKEN (curator, 2026-08-08). T-31 IS UNBLOCKED and its entry in
`implementation-plan.md` has been rewritten to match.** Read §Findings **S-13** first — not
because anything is still open, but because it records a measurement you must not repeat and a
regression you must not reintroduce.

**The one thing to know before writing any code:** pointing the issue kernel at a time-entry
scope does **not** raise. It answers `COUNT(DISTINCT issues.id)` under time-entry labels — four
time entries over two issues came back as `2` in every bucket, and `spent_hours` came back
`nil`. So the new module is not an optimisation, it is the difference between right and
plausibly wrong, and T-31 carries a test asserting a time-entry scope never reaches
`QueryAggregator` for exactly that reason.

What was decided:

| | Decision |
|---|---|
| **S-11** | The failure-document opt-in is **per template**. No schedule column, now or later, unless T-28 gives it a destination. §7b.3 narrowed |
| **S-12** | The streamed zip is **T-29's alone**. T-30 is released; `send_document`'s 501 is what T-29 deletes |
| **S-13** | **The kernel stays frozen — no second G7 hunk.** Time entries get an owned sibling module. The separation is at the QUERY (`IssueQuery` vs `TimeEntryQuery`) and the CALCULATOR, and **nowhere above them**: one template model, one controller, one CRUD, one preview, one permission set. `[OQ-H]` still holds |
| **S-13 (3)** | **Mixing issue data and time data in one template is DROPPED, not deferred.** No second scope slot on `RenderContext`, no mixed-template test. §7b.4 and FR-60 corrected. Do not reintroduce it as a convenience |
| **S-14** | **A time-entry report silently shows most people only their own hours.** `TimeEntry.visible_condition` branches on `Role#time_entries_visibility` — `all` / `own` / none — and the `own` case produces a smaller, entirely believable total with nothing saying why. Decision: fail closed AND **label the narrowing on the page**, §9b.2's "Preview of 50 of 1 284" pattern. No new permission: core's `:view_time_entries` already governs it |

**DO NOT ADD A GOLDEN CORPUS FILE FOR THE NEW MODULE.** This paragraph said to, on the
first pass, and it was wrong — `spec/golden/README.md` states its own purpose plainly:
*"Nothing in this directory tests the plugin's behaviour. It tests that the behaviour has
not moved."* That is a drift detector for PORTED code, and there is no "before" here.
Snapshotting a new module on day one freezes whatever it answers, bugs included, and makes
fixing one look like a G7-shaped breach.

**What it needs instead — and this is the clause that carries the whole task:** compute every
figure TWICE, once through the module's SQL and once by loading the rows and summing them **in
Ruby**, and run the comparison on all three engines in `spec/adapter/`. Ruby arithmetic does
not vary by engine, which is exactly why it is the check that catches the next item.

**AND THE NEXT ITEM IS THE ONE THAT WILL BITE.** D-1's MariaDB column-label truncation (§1
above) was fixed for COUNT only. Measured in the tree: `grouped_counts` reads positionally
(`relation.pluck(*group_values, Arel.sql("COUNT(…)"))`), but `raw_measure` still calls
`relation.sum(Arel.sql(expression))` on a GROUPED relation — and ActiveRecord keys that Hash
by the group expression's own text, which MariaDB truncates at 256 characters. **`SUM(hours)`
grouped by a dimension is the new module's entire purpose**, so it walks straight into the
one defect class this project has documented as open and ungated. Copy `grouped_counts`'
positional shape for sums and averages from the first line of code, not after a red CI cell.

**Comparing against the plugin on `main` does not work for this**, and it was asked: `main`
has no time-entry-sourced reporting. `_report_by_spent_time.erb` renders a template belonging
to the PRIVATE `redmine_reporter` plugin (the reason for the four permanent skips) and
`_timelog.html.erb` is core Redmine. What `main` does have is `spent_hours` as a MEASURE over
an ISSUE scope — already frozen in T-01's corpus, so that comparison is already made.

---

---

## 5. Where to pick up

`implementation-plan.md` §Status is authoritative; verify it against `git log` per
`CLAUDE.md` §1. In short:

1. **T-01 is done.** The oracle exists: read `spec/golden/README.md` before touching
   anything in that directory, and treat a corpus difference as a finding to explain
   rather than a file to regenerate. Two things it produced that are somebody's work
   now: defect **D-1** (T-08 owns the fix) and finding **F-2** (T-07 owns the decision)
   — both in `implementation-plan.md` §Findings.
2. **T-03's aggregation half is done**, so `CLAUDE.md` §1's "no aggregator change before
   T-03" guard has expired. **T-03's HTML|PDF half stays owed by T-10** (P-2), recorded in
   the artefact as blocked.
3. **D-1 is FIXED**, in T-08, where the plan said it had to land. A counted axis is read
   positionally instead of through ActiveRecord's alias-keyed grouped `.count`; gate G7
   grew a declared-exception mechanism to express "the blob plus exactly this one argued
   hunk" (`spec/golden/kernel_exception.rb`); the per-adapter overlay is empty again with
   `RATCHET = 0`. **CI run 31036305443 is 17/17 green**, `adapter (MariaDB 11)` included and
   in 4 m 16 s against 5 m 39 s before the fix — so D-1 is measured fixed on the engine it
   lives on, not merely argued. What is
   still exposed, on purpose: a MEASURED age axis (README, database section). Read the
   §Findings entry before touching it — the first attempt is written up there and the
   reason it was replaced is a performance fact, not a correctness one.
8. **T-21 is done — the multi-actor visibility suite.** `test/unit/multi_actor_visibility_test.rb`,
   in the FULL APP because real `Role#issues_visibility`, a real private issue, a real
   role-restricted custom field and a real `IssueQuery` exist nowhere else. It builds its
   OWN substrate at reserved ids 940_xxx rather than sharing
   `golden_scope_fixture_test.rb`'s — that one is a frozen oracle whose output must not
   move, and the two need different rows. **Mutation-tested**: replacing
   `Issue.visible(User.current)` with `Issue` in its `base_scope` fails 4 of its 13
   tests, so it is load-bearing rather than decorative. Do that again if you change it.
   The trap it exists for is ORDERING: a memoised `User.current` or a cached visibility
   condition gives the second actor in a process the first one's answer, and every
   per-actor assertion still passes because each asserts one actor at a time.
10. **T-11, T-12 and T-13 are done, with one honest gap.** `render/engines/` holds a CDP client, a
   Chromium adapter and a wkhtmltopdf adapter; `spec/conformance/` holds 20 fixtures and the harness
   that applies the three-state rule; `docs/engine-support-matrix.md` is generated from the run and
   gate G9 compares it. **Chromium 141: 20 of 20.** Four things a later session should know.
   **F-7 is closed** — T-11's wall-clock falsifier is `F-13`, 3/3 attempts, and it discriminates
   because its timeout is 20 s rather than the default 10. **The corpus earned its keep on day one**,
   finding a half-built egress control, a footer that printed `Page1of3`, and a registry reset with
   no restore (§Findings E-2, E-3, E-4). **`:wkhtmltopdf` had never been run when this was written,
   and `verification: pending` was load-bearing for that reason. It has since run — 18/0/2 on the
   patched-Qt build — and was PROMOTED to `corpus` on 2026-08-06**, so its twenty cells are real and
   enforced. The principle behind the original sentence is unchanged: an unmeasured cell is INV-7's
   exact sin, and the promotion came from a run, not from confidence. And **the browser must not run
   as root** — see §1; that is the
   sandbox working, not an obstacle to route around with `--no-sandbox`.
   Next after T-13 was **T-14**, now done — see entry 11. **T-15** (render-path containment) is
   partly done and blocked on an entry point (§Findings E-6). **T-33** (the asset-resolution triple)
   depends on T-12 and is likewise open.

13. **T-19 is done — the owned filters and the FR-19 lint.** `liquid/filters.rb` plus six
   registered modules, `liquid/html_scanner.rb`, four new lint rules, and the examples and
   README actually fixed. Five things a later session should know.

   **REGISTRATION IS THE POINT, not the filter list.** `Filters.modules` is the DEFAULT of
   `TemplateRenderer#render`, and nothing anywhere calls `Template.register_filter` —
   `single_parse.sh` fails on one. The gem registers four modules globally at require time
   and monkey-patches `to_number` into `StandardFilters`; a spec asserts both are absent,
   because that is a property of the whole process and no care inside this plugin would
   restore it.

   **OQ-C IS CLOSED BY MEASUREMENT.** `where` and `sort_natural` are INHERITED — identical
   on both majors and already working on the drops, because Liquid's `where` reads through
   `Drop#[]`. `sum` is OWNED, because only Liquid 5 has one and a plugin supporting both
   majors cannot leave that divergence in place; it reproduces Liquid 5's semantics
   exactly, which is why it differs from its four neighbours on how it treats non-numbers.
   **The `StandardFilters` list is pinned per version and an unpinned Liquid FAILS** — that
   is the whole mechanism, and Liquid 5 added twelve filters since 4.0.4 without anybody
   choosing them.

   **`Support.read` GOES THROUGH `Drop#[]` AND NOTHING ELSE.** Never `send`, never
   `public_send`. §3.6 removes the gem's `call_method` as "the sharpest single instance of
   INV-9", and a filter resolving a property with `public_send` would reintroduce it one
   property name at a time — `avg: "estimated_hours"` and `avg: "destroy"` are the same
   call. A spec asserts the drop is never sent to.

   **THE LINT PARSES, AND ITS SPEC IS THE ARGUMENT.** See the trap in §1: the scanner cost
   two rounds. Every example in `spec/html_scanner_spec.rb` is a case the regexp it replaced
   got wrong, and the two hardest were prose mentioning `<script>`.

   **WHAT IS DEFERRED, AND WHAT IS HELD AT A RATCHET.** `| inline` is **F-10** and belongs to
   T-33 (`asset_policy`). The examples' Chart.js 2 idioms and `window.status` handshake are
   **not** fixed — they belong to T-16 and T-11, which rewrite that code — so
   `spec/shipped_templates_lint_spec.rb` pins FR-19 at ZERO and the rest at a per-file
   ratchet. Lower those numbers when their owner lands; never raise one.

14. **T-20 is done — the two compensating tags retired.** `{% geo_version_map %}` is a
   deprecation shim, `liquid/{version_drop,custom_field_value_drop,issue_drop_patch}.rb`
   are deleted, and `liquid/tag_context.rb` is new. Five things a later session should
   know, and the first two are the ones that cost time.

   **T-20'S `Touches:` LIST IS INCOMPLETE, AND SO MAY THE NEXT TASK'S BE.**
   `{% version_rollup %}` built one addon `VersionDrop` per row; the acceptance list does
   not mention it. It surfaced as a LoadError in `rspec spec` — loud, this time — but the
   question behind it was not: the replacement drop refuses a nil `RenderContext` and a
   host-plugin render has none. **Before deleting a class, `rg` for its constant, not
   only for its filename.** The registration site and the requires are the easy half.

   **`liquid/tag_context.rb` IS WHERE `User.current` IS READ, AND IT IS DELIBERATE.**
   `TagContext.for(liquid_context)` answers the owned `RenderContext` when the owned
   renderer supplied one, and otherwise builds an **actor-only** one — `scope` and
   `query` stay nil, so nothing rebuilds a scope by archaeology and §6's warning is
   respected rather than sidestepped. `TagContext.owned?` exists so the two branches are
   ASSERTABLE; a spec that only checked "a context came back" would pass either. This is
   **F-12** and the curator may still want it done differently — read the finding's table
   before changing it, because the two alternatives both cost something measured.

   **`issue.target_version` HAS A WINDOW WITH NO IMPLEMENTATION** between here and T-23.
   The accessor is on `Drops::IssueDrop`, but nothing constructs one, so a
   Reporter-rendered template gets Reporter's drop and it resolves to empty. **F-11**, in
   the CHANGELOG in plain words. Do not "fix" it by having the glue build a
   `Drops::IssueDrop` — that is the producer T-23 owns, and faking it makes the owned path
   look tested.

   **THE `:liquid` LINT SCOPE NOW SKIPS `{% comment %}` AND `{% raw %}` BODIES.** It did
   not, and the first thing the new deprecation rule did was flag the example template's
   own header comment explaining the migration. Same lesson as E-14 one construct further
   in. It **fails open** on an unterminated comment, on purpose: a missed exclusion costs
   one false finding, an over-eager one silences everything after it.

   **A DROP, NOT A HASH, IN `{% version_rollup %}`'s ROWS.** The tempting simplification
   is to hand each row a plain Hash of the version's facts. It is EAGER:
   `completed_percent` runs a query per version whether or not the template prints it, and
   `{{ v.version }}` stops substituting for the version name. Both are silent. The drop is
   lazy and string-substitutable; keep it.

15. **T-16 is done — the hybrid chart layer.** `charts/` (six files), `liquid/tags/chart_tag.rb`,
   `assets/javascripts/chart_boot.js`, vendored Chart.js 4.5.0. Six things a later session
   should know, and the first two will cost time if they are not known.

   **THE CHART LAYER IS NOT UNDER `render/`, AND THAT IS DELIBERATE.** §1.1's tree says it
   should be; E3 (`layer_purity.sh`) forbids `liquid/**` from naming the render layer; and
   §3.5 puts `charts` on `RenderContext`, which IS the Liquid layer. All three cannot hold.
   It lives at `lib/redmine_reporter_dashboards/charts/` naming neither layer, so both may
   name it. **F-13**, and moving it is a `git mv` if the curator disagrees — do not "fix"
   the tree without reading the finding, because the obvious fix breaks the gate.

   **THE FALSIFIER IS THE ONLY THING THAT CAN ANSWER THE SHARED-LAYOUT CLAIM, AND IT NEEDS
   A BROWSER.** Both emitters read the same `ChartLayout`, so a Ruby test comparing what
   each was TOLD compares a number with itself and passes for ever. The claim is that both
   DRAW the same rectangle, and Chart.js draws its own from real font metrics. Run it as
   the non-root user (§1's Chromium note):

       chmod -R a+rX . && su rrd -s /bin/bash -c \
         'RRD_CONFORMANCE=1 PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers rspec -I spec spec/charts/shared_layout_falsifier_spec.rb'

   **`RRD_CONFORMANCE=1` IS NOW REQUIRED and the command above did not used to need it.**
   The falsifier ran wherever `CdpClient.detect_binary` found anything, which meant it
   started GitHub's own Chromium in the plain `rspec` job — a job that installs nothing a
   browser needs — where it died mid-session and failed two examples on FOUR CI cells for
   four commits. "A binary exists" and "this run may start a browser" are different
   questions; the flag is the second one, and it is the same flag
   `chromium_containment_spec.rb` already used. Without it the two examples now skip
   NAMING the flag, which is UNVERIFIED and not a pass.

   It found two real defects on its first run (§Findings **E-16**) and now measures
   **1.17% worst edge** against a 2% tolerance. It is wired into the `render-smoke` CI job,
   which is also what would catch a Chart.js upgrade moving a default.

   **`responsive: true` SIZES THE CANVAS FROM THE PARENT, NOT FROM ITS OWN ATTRIBUTES.**
   That is the 21.88% finding, and it is worth knowing generally: a `<canvas width=640>`
   inside an 800px div becomes 768px wide and every server-computed coordinate is wrong.
   `ChartjsEmitter#frame_style` is what constrains it, and it uses `max-width` so §9b's
   "responsive down to a phone" still holds below the authored width.

   **A RUBY METHOD WITH A KEYWORD PARAMETER SWALLOWS A TRAILING BARE HASH.** Cost two
   rounds in one session, in two different files: `element('rect', 'x' => 0)` raised
   "unknown keywords: x" because the method declared `inner:`, and `context('stats' => x)`
   in a spec did the same because it declared `with_render_context:`. Both are now
   positional or braced, and both say so in a comment. Watch for it whenever a helper
   grows its first keyword argument.

   **THE THIRD EXAMPLE IS HELD AT ZERO AND THE OTHER TWO ARE NOT.**
   `examples/chart_tag_showcase.liquid` writes no markup at all, so it has no findings and
   `shipped_templates_lint_spec.rb` pins it at 0. The two legacy examples still load
   Chart.js 2.8 from cdnjs and their ratchets are UNCHANGED — **F-15** says why T-16 could
   not migrate them (they need an absolute plugin-asset URL that a Reporter-rendered
   template has no way to build) and who owns it. `vendor_integrity.sh` runs in **warn**
   mode for exactly those two lines; flipping it to strict is what finishing that job
   looks like.

   **`ScriptSafeJson` MOVED OUT OF THE FILTERS, and the move is the interesting part.**
   `| json`'s five script-context escapes are now
   `lib/redmine_reporter_dashboards/script_safe_json.rb`, belonging to no layer, because
   `ChartjsEmitter` is the second caller and it sits on the path a PDF engine takes.
   `Liquid::Filters::Escaping` keeps the constants as aliases. Two copies of a
   security-bearing escaper was the alternative, and the copy that drifts is always the one
   without a test.

19. **T-23 is done — the first owned HTTP entry point, and the first producer for four
   layers.** `app/controllers/reporter_dashboards/templates_controller.rb`,
   `lib/redmine_reporter_dashboards/reporting/`, five views, `Template`'s visibility and
   ownership, `patches/role_patch.rb`, and five permissions promoted. Six things a later
   session should know, and the first two will cost real time if they are not known.

   **THE REPORT BODY IS NEVER MARKUP IN THE VIEWER'S PAGE, and reverting that is a privilege
   escalation rather than a simplification.** It goes into an `srcdoc` ATTRIBUTE inside
   `sandbox="allow-scripts"` with no `allow-same-origin` (§4's opaque origin, INV-9's third
   mechanism). The review of T-23 refused the first version for inlining it, and the escalation is
   one sentence: an ordinary member holding `edit_own_…` writes a `<script>` and the next
   administrator to open the report runs it in their own session. `reporter_report_frame` carries
   the whole argument, and the deviation from §4's wording (the CSP is a `<meta>`, because a
   preview has no URL to put a header on) is **reported and open** — §Findings E-22.

   **`authorize` IS NECESSARY AND NOT SUFFICIENT ON THIS CONTROLLER.** Redmine's `authorize`
   passes on ANY permission mapping the action, so `manage_public_…` — which MUST map `#create`,
   because that is where the visibility decision is made, and it is core's own shape for
   `manage_public_queries` — would reach a code-execution endpoint on its own. Four second guards
   close that and the two things the permission model cannot say at all: "import needs `add_…`
   **and** `edit_…`" is a conjunction, and "own" is a property of the RECORD. Do not delete a
   `require_*_permission` because `authorize` is already there.

   **THE NAME `require_add_permission` IS TAKEN AND MUST NOT BE USED.** `permission_map_spec.rb`
   asserts no file under `app/`, `lib/`, `db/` or `init.rb` mentions Redmine's role-granting API,
   and that method name contains it as a substring. It is `require_create_permission` for that
   reason and the controller says so; renaming it back turns a security check red for a reason
   that looks nothing like the name.

   **`Template.visible` IS HAND-WRITTEN SQL AND IT RAN ON POSTGRESQL ONLY.** Finding S-9's shape
   exactly: it lives in the `minitest` job, which is one engine. It was ALSO two clauses short of
   core's roles arm on its first version — no `projects` join, no
   `templates.project_id = m.project_id` — which let a role held in ANOTHER project satisfy a
   ROLES-visible template here. Re-diff it against `redmine/app/models/query.rb:377` if you touch
   it, and disbelieve any comment claiming it matches core.

   **A SCOPE AND A PREDICATE ANSWERING ONE QUESTION WILL DRIFT, and the matrix is what catches
   it.** `test_the_scope_and_the_predicate_agree_for_every_actor_and_every_template` found two
   real disagreements on its first two runs — an administrator, then Anonymous — and both were in
   the code rather than the test. **But a matrix is only as good as its actors**: the version that
   missed the cross-project leak had a role granted to nobody, so both sides said "no" for the
   wrong reason. When you add a row, ask what would still pass if the rule were deleted.

   **WHAT IS DELIBERATELY NOT BUILT.** A per-record export of more than one document is refused
   with a **501** — the zip is E-6's third owed bullet and belongs to whoever builds streamed
   archives. `source: time_entries` is refused with a message naming **T-31**; the column accepts
   it, the picker does not offer it, and nothing reports time entries against the issue scope. And
   a per-record PREVIEW draws exactly ONE document (`PREVIEW_MAX_DOCUMENTS`), because fifty
   synchronous PDF renders is a worker any member can hold for five minutes.

22. **T-32 is done — ad-hoc report mail, and every clause of §7b.5's indictment is closed by
   construction.** `app/controllers/reporter_dashboards/mail_controller.rb`,
   `reporting/{mail_policy,adhoc_delivery}.rb`, migration 009's two audit tables, two models,
   two mailer actions, four settings, 37 keys × 9 locales, and T-40's promotion of
   `mail_reporter_dashboards_reports`. Five things a later session should know.

   **THE SENDER IS SERVER-CONTROLLED BECAUSE NO PARAMETER EXISTS, NOT BECAUSE `Mailer` IS
   INHERITED.** See the new §1 trap: `Mailer#mail` uses `reverse_merge!`, so a caller's own
   `From` would win. Do not add a `headers:` or an options Hash to either mailer action —
   a test asserts their `parameters` lists, the same shape `DocumentRequest`'s "no field a
   credential could travel in" assertion takes.

   **AN ISSUE THE REQUESTER CANNOT SEE REFUSES THE WHOLE SEND, and "drop it" is the wrong
   fix.** T-32's `Accept:` says *refused, not silently included* — and silently DROPPING it
   is the plausible-looking alternative with its own defect: the requester asks for twelve
   issues, gets a report covering nine, and nothing says which three or why. The refusal
   names the COUNT and not the ids, because naming them would confirm which exist.

   **THE RATE LIMIT COUNTS OFF THE AUDIT TABLE, AND THE BEFORE/AFTER-CLAIM SPLIT IS
   LOAD-BEARING.** A refusal that happens before any work (rate limit, disallowed address,
   no recipients) writes **no** row — a quota a refused request consumes is one nobody can
   recover from. A failure that got as far as rendering **is** audited, because the render is
   the expensive half. A test for each; the first version of the second one passed for the
   wrong reason until the split was made explicit.

   **`address` IS THE ONE ADDRESS COLUMN IN THIS SCHEMA AND THE GUARD WAS TIGHTENED TO SAY
   SO.** `schema_contract_spec.rb` now asserts it exists in exactly one table and is
   nullable. §Findings **S-19** carries the argument: the columns §7 refuses are delivery
   INPUTS, this one is a record written after the policy decision, and nothing that sends
   reads it. Do not add a second one.

   **WHAT IS DELIBERATELY NOT BUILT.** No `render_as` — an ad-hoc send renders as the
   requester and there is no second identity, so `render_…_as_others` has no counterpart
   here and adding one would reintroduce T-25's escalation. No failure MAIL: the requester
   is standing at the page and reads the diagnostics panel, so INV-5 is satisfied by there
   being no mail at all. And no audit row for a pre-render refusal — see above.

21. **T-30 is done — the failure report, and it is drawn without an engine.**
   `render/minimal_pdf.rb`, `reporting/failure_document.rb`, migration 008,
   `Diagnostic#template_name`, and the `#document` action's one new branch. Five things a
   later session should know.

   **THE WRITER EXISTS BECAUSE THE ENGINE IS THE THING THAT FAILED.** Most of the codes that
   can reach a failure document are engine codes — `engine_crashed`, `engine_unavailable`,
   `readiness_timeout`, `output_not_pdf` — so drawing it through the configured adapter is a
   coin toss whose losing side is *no document at all*, which is precisely the outcome FR-59
   replaces. `MinimalPdf` has no process, no socket and no asset, and the DB-less suite
   drives all of it. **It is not a general PDF library and must not become one**: the moment
   it needs an image or a table, the answer is an engine.

   **THE SAFETY CLAIM IS HELD BY CONSTRUCTION, NOT BY A PAYLOAD LIST.** T-30's `Accept:`
   asks for tests that the document carries no exception class, no SQL and no role, member
   or project id — and a test can only name the strings somebody thought of. So
   `FailureDocument` reads `code`, `origin`, `line`, `engine`, `engine_version`,
   `duration_ms`, `correlation_id` and the template's name, and there is **no path from
   `#message` or `#detail` to the page** — `message` is safe by contract and is still absent,
   because the document travels further than the panel does. The example that would notice a
   future edit is *"does not carry the diagnostic message either, safe though it is"*; the
   three payload examples would all go on passing without it.

   **ONLY `#document` CAN PRODUCE ONE, and the status stays the failure's own.** `#show` and
   `#preview` are pages — §9b.2 puts the diagnostics panel there and a page that downloads a
   PDF instead of answering is a worse page — and both are asserted to stay pages even when
   the template asks for a document. The response carries 500/422/501 rather than 200,
   because a 200 carrying "this is not your report" is INV-5 one layer up: every script,
   monitor and `curl` against that endpoint would record a success.

   **THE BASE-14 FONTS DRAW WINDOWS-1252 AND NOTHING ELSE, and the caller is told rather
   than the text mangled.** `encodable?` is public for that reason. A label in a locale the
   writer cannot draw falls back to the **English** string for that line and sets
   `locale_degraded?`, which the controller logs; a VALUE has no second language, so an
   undrawable template name is replaced and the run is marked degraded. Silently drawing
   `?????` for a Russian operator is the plausible-looking wrong answer this repository keeps
   deleting.

   **WHAT IS DELIBERATELY NOT BUILT, AND BOTH ARE NOW SETTLED.** The schedule half of
   §7b.3's opt-in is **dropped** — the curator narrowed §7b.3 to "per template" on
   2026-08-08 (§Findings ~~S-11~~), because the owner's notice is required to carry no
   attachment and the document store is T-28's, so there was no scheduled consumer for the
   bytes. Do not add a `failure_document` column to `reporter_dashboards_schedules`. And
   E-6's zip is **T-29's alone** as of the same date (§Findings ~~S-12~~); T-30 made the 501
   answer with a failure document, which is not the same as building an archive.

20. **T-25 is PART DONE and nothing delivers yet.** Two increments: `scheduling/occurrences.rb`
   (the date arithmetic, pure) and `scheduling/runner.rb` (the tick). Still owed: the delivery
   itself, the two permission promotions, the schedule UI, the mailer, nine locales, the rake task
   and the preflight "never run" warning. Five things a later session should know.

   **THE `delivery:` PORT IS REQUIRED AND HAS NO DEFAULT, and that is the seam the rest of T-25
   plugs into.** It implements `#call(schedule:, occurrence_date:, actor:, run:)` and answers a
   `Runner::Delivered` — or raises, which is handled identically. Everything the runner owns is
   bookkeeping (claim, rescue, run state, exit code) and none of it needs to know what a report is;
   that is what lets a raise mid-run, a duplicate claim and an identity locked last week all be
   driven without a browser or an SMTP server. **A port answering anything else is a FAILURE**, not
   a success — recording a delivery that never happened would also advance `last_run_on` and so
   remove the day from the catch-up window.

   **FR-41 NEEDS TWO RESCUES, AND THE SECOND ONE IS NOT OBVIOUS.** `rescue => e; record_failure;
   write_schedule_state` re-raises out of the RESCUE BODY if the write itself fails, because an
   exception raised inside a rescue clause is not caught by that clause — so every schedule after
   this one silently does not deliver, FR-41 violated by the code written to satisfy it.
   `record_failure_state` is the guard, and it LOGS rather than swallowing: "failed, and the failure
   could not be recorded" is a worse fact than "failed".

   **A DRAFT IS NOT A FAILURE.** `repeat` and `start_date` are both nullable by T-22's decision, so
   an enabled half-built schedule is a legitimate row. Counting it as a failure would make the cron
   entry exit non-zero on every tick for ever, and an exit code that is always non-zero is one
   nobody reads — the same decay CLAUDE.md §7 describes for a gate made advisory. It is recorded as
   `skipped`, which is the status vocabulary T-22 defined for exactly this and nothing had used. An
   unknown-but-PRESENT repeat rule is the other case and is a real failure.

   **`last_run_on` IS NOT ADVANCED BY A FAILURE, on purpose.** It is the catch-up floor, so
   advancing it would move a day that did not deliver out of the window — FR-40's "a missed
   occurrence is visible" turned into its opposite. The cost is that a persistently failing schedule
   re-enumerates the same days each catch-up tick and has each claim refused; that is bounded by
   `max_catchup_days`, costs one failed INSERT apiece, and each refusal names the schedule and the
   date. Do not "fix" the log noise by advancing the column.

   **THE RENDER POLICY IS A CLOSED SET, and the version that was not cost a BLOCKER.**
   `if render_as == 'user' … else author end` sends every other value — an unknown policy, a
   case variant, a value a later version wrote — down the author branch silently, reports
   success, and mails one person's view of the data to a list chosen for somebody else's.
   `validates … inclusion:` does not close it, because `update_columns` and `update_all`
   bypass validation and this plugin uses both, and §7 rule 5 makes the state routine: roll
   back one minor while keeping the DATA and every newer policy reverts. Close the set the
   way `Occurrences` closes the repeat rule. The same shape is worth checking anywhere a
   stored string selects behaviour.

   **T-25 IS NOW THREE PARTS AND ONLY THE UI IS LEFT.** Part 3 added
   `reporting/scheduled_delivery.rb` (render + mail), `ReporterDashboardsMailer`,
   `scheduling/{heartbeat,run_command}.rb`, two rake tasks and 7 keys x 9 locales. Four
   things to know. **The delivery lives in `reporting/` and moving it would fail the
   gate** — `scheduling/` may not name Render or Liquid, which is only true because the
   composition root does the rendering. **`User.current` is deliberately set around the
   render**, because `IssueQuery#statement` reads it and there is no argument to pass
   instead; a rake task runs as Anonymous, so without it a saved query resolves to nothing
   and the report is empty rather than wrong. **The runner has TWO ports now** — `delivery:`
   and `notify:` — because three failures (locked identity, unknown policy, unknown repeat)
   raise before the delivery is reached, and FR-43's owner notice lives behind the delivery.
   `Delivered#reported?` stops one failure producing two mails. **An empty per-record run
   sends nothing and is not a failure**: zero is the good outcome for "my overdue issues"
   and a breakage for a weekly status report, the plugin cannot tell which, so the run row
   records `document_count: 0` and nobody is paged.

   **T-25 IS COMPLETE, AND ITS UI IS WHERE BOTH ESCALATIONS WERE.** `SchedulesController`
   (8 actions), 5 views, a helper, and the two §4.1 rows promoted to live. Four things to
   know. **`render_as_user_id` is resolved in `apply_render_identity`, never permitted** —
   the bound is "yourself, or anybody if you are an administrator", which is §7b.5's *you
   can only mail what you can see* applied to the field; anything wider is a curator
   decision (see the ASK below). **You may test-send only a schedule that renders as you**
   (or be an administrator): FR-45 fixes the identity, so the delivery target is what gives
   way. **`manage_…_schedules` maps `#index`/`#show` too** — without them a role holding it
   alone created a schedule and got a 403 on the redirect. **Absent and empty are different
   requests** for both `recipient_user_ids` and `template_id`; the form carries a hidden
   blank so an emptied multi-select is expressible at all.

   **S-7's OBLIGATION IS PAID, AND READING THE ROW BACK CANNOT PROVE IT.** See the three new §1
   traps. The run state goes through `update_columns`; the example that establishes it subscribes to
   `sql.active_record` and asserts which columns the UPDATE names, because Rails' partial writes
   make a full-row write and a two-column write leave an identical row behind.

18. **T-40 is done — the permission model, and `[OQ-F]` is CLOSED because the SETTING is gone.**
   `lib/redmine_reporter_dashboards/permissions.rb`, `spec/permissions/permission_map_spec.rb` and
   `spec/permissions/registration_dsl_spec.rb`. Read `technical-spec.md` §4.1 and §Findings **E-20**
   before touching anything about authorization. Six things a later session should know.

   **Do not add a `template_authoring` setting back.** The curator rejected it outright on
   2026-08-06: roles get permissions the normal Redmine way. Both of `[OQ-F]`'s candidate defaults
   were wrong for the same reason, and the one the spec *recommended* was the worse of the two —
   `:project_managers` would have widened a code-execution privilege on upgrade, silently and
   installation-wide. If a future task wants an install-wide switch over authoring, that is the same
   mistake wearing a new name.

   **`:admins_only` IS NOT A CONSTRUCTION GUARANTEE, and the first version of this entry said it
   was.** This plugin grants nothing — but core's `lib/redmine/default_data/loader.rb:51` runs
   `manager.permissions = manager.setable_permissions.collect {|p| p.name}`, identically on 5.1 →
   7.0, and `setable_permissions` subtracts only `public_permissions` for a givable role. *Load the
   default configuration* on a fresh install with this plugin present therefore grants **Manager**
   every setable permission of ours, `require: :member` included. **No spec in this repository can
   see that** — the grant is in core — which is why T-27's diagnostic has to list the roles holding
   OUR authoring permissions and not only the base plugin's. Do not restate the absolute claim.

   **The ten reporting permissions are DESIGN, not code, and that is deliberate.** They live in
   `PLANNED` with the task that registers each one. A permission an administrator can tick that
   guards nothing is a lie in the roles screen. Promotion is four parts — fill in `actions`, drop
   `lands_in`, add the nine `permission_*` labels, and for the FIRST one promoted the nine
   `project_module_reporter_dashboards_reports` labels, because the reports module is new and its
   fieldset legend goes through `l_or_humanize(mod, prefix: 'project_module_')` in two views. The
   spec asserts all four the moment you start.

   **The spec PARSES the controllers, and the fixtures are the load-bearing part — not the
   meta-test.** `RubyVM::AbstractSyntaxTree` answers "which methods are public actions", because a
   regexp cannot know where `private` is (§Findings E-14, and the deleted ES5 "shorthand method"
   regexp). The failure mode of reading an AST is the *opposite* of a regexp's: a construct the
   reader never learned makes it return **nothing**, and every assertion built on it passes
   vacuously. The meta-test against the four real controllers did not stop that — T-40's review got
   past the gate four times with ordinary controller code (E-20). `spec/permissions/fixtures/controllers/`
   is the answer: two files carrying `only:`, `except:`, `skip_before_action`, `define_method`, a `def`
   inside a conditional, `private def`, `def self.`, `class << self`, and `protected` followed by
   `public`. **If you extend the reader, extend the fixtures — a construct that is not in them is a
   construct the gate cannot see.** Note Ruby 3.4 renamed `NODE_LIT` to `NODE_SYM`, which is why both
   are accepted, and that a call with a block is an `ITER` wrapping the `FCALL`, which the first fix
   for `define_method` missed.

   **`init.rb` no longer contains the permission list, and the loop is asserted twice.** Three
   literal `permission` calls became a loop over `registrations_by_module`; the spec compares its
   output with those three calls argument for argument, and `registration_dsl_spec.rb` runs the loop
   against a recorder mimicking `Redmine::Plugin#project_module`'s `instance_eval` — committed this
   time, and it fails if `init.rb` stops containing the loop it copies. `Entry#registration_options`
   omits `read`/`require` rather than passing `false`/`nil`, which is what the literals did; not a
   correctness requirement (`Permission#initialize` reads `options[:read] || false`), just easier to
   assert as identical.

   **What still has not been run: the full-app half, and it EXISTS.** The first version of this entry
   said "there is none". Wrong — `test/functional/reporter_project_tabs_controller_test.rb` and
   `reporter_project_pages_controller_test.rb` call `Role.find(1).add_permission!` and assert
   200/403, and they are the only thing in the tree that proves the loop registered anything in a
   booted Redmine. There is no Redmine checkout in this container, so **CI is their first execution
   against the loop.**

17. **T-35 is done and was RE-SCOPED — read §Findings F-17 before touching it.** Vendored Mermaid,
   a thin block tag, `:modern_javascript`, and deliberately **no** sanitiser, no `MermaidSpec`, no
   collector and no `:mermaid` capability. Four things a later session should know.

   **`registers` DOES NOT HAVE THE SAME LIFETIME ON THE TWO LIQUID MAJORS, and it cost a real
   defect.** On Liquid 4 `context.registers` belongs to the TEMPLATE and survives every render; on
   5.13.0 it does not. A boolean "already emitted the library" flag therefore gave the first report
   its 3.5 MB Mermaid and every later render of the same parsed template none — diagrams silently
   undrawn. Key per-render state on the **Context's object identity**, which is fresh on both.
   Anything else you put in `registers` has this hazard.

   **LIQUID 4 SKIPS A TAG WHOSE `blank?` IS TRUE, and `Raw#blank?` means "empty body".** So an
   empty `{% mermaid %}` rendered to nothing on 4.0.4 and to a refusal element on 5.13.0. Any
   `Raw` subclass that must always emit needs `blank?` overridden to `false`.

   **`mermaid_boot.js` IS ES5 AND MUST STAY ES5.** Its whole job on wkhtmltopdf is to produce the
   fallback, and one arrow function kills the entire script at parse time on exactly that engine —
   so the fallback would silently not happen where it is needed. `spec/charts/mermaid_boot_spec.rb`
   asserts it with a real `vm.Script` ES5 parse plus a per-construct scan over CODE ONLY (the file's
   own comments name `||=` and arrow functions, so scanning comments is the E-14 mistake again).

   **THE 3.5 MB BUNDLE TAKES T-33's `data:` FALLBACK, and that is not a bug.** Measured end to end:
   the resolver inlines it with `Degradation(:asset_structural_fallback)` because the minified
   bundle contains an element terminator, so it becomes a `data:text/javascript;base64,…` rather
   than a `<script>` block — and Chromium draws the diagram from it perfectly. Two T-33 code paths
   proven by a real document rather than by a spec.

16. **T-33 is done — the asset triple, one policy, and the plugin's first settings block.**
   `assets/` (ten files) + `render/asset_binding.rb`. Six things a later session should know, and
   the first two will cost time if they are not known.

   **THE TREE IN §1.1 IS NOW CORRECT, AND IT WAS NOT BEFORE.** F-13 and F-13b are **closed by
   the curator**: `charts/` and `assets/` are siblings of `render/`, naming neither the render
   layer nor the Liquid layer, and `layer_purity.sh` has an arm for each. Do not "tidy" either
   into `render/` — the gate will stop you, and the gate is right: a fetcher inside `render/`
   contradicts the invariant that directory exists to protect. The two arms were
   **negative-tested** (a planted constant in each direction fails; a comment naming the same
   constant does not).

   **`:asset_http` IS NEVER SELECTED — read that before "fixing" the `:redmine`/`:external`
   rows of §5.1's table.** The table says those modes fetch "over `:asset_http`". The resolver
   does not: wherever a fetch is permitted the PLUGIN fetches and the engine receives bytes.
   That is stronger than T-33's acceptance clause ("off wherever the engine supports upload")
   and it is deliberate — §5.1's own inversion paragraph demands it. §5.1 now carries an
   AS BUILT section saying so. A spec drives an engine declaring all three models in
   `:external` mode and asserts `:inline` comes back.

   **A FROZEN VALUE OBJECT AND A LAZY MEMO CANNOT COEXIST, and it cost the first smoke run.**
   `Reference` memoised `url` and `classification` on first use and every accessor raised
   `FrozenError`. Everything derived is now computed in the constructor before `freeze`. The
   code READ correctly; only running it found this. The same shape is waiting in any value
   object in this repository that grows a memo.

   **THE SCANNER'S NEGATIVES ARE THE WHOLE POINT, and they are E-14 one layer further in.** A
   URL in an HTML comment is never fetched (refusing the document over it is wrong); a URL in a
   `<script>` BODY is a string in a program (rewriting it corrupts the program); a URL in a
   `<textarea>` is text a reader is meant to see. All three are skipped by tracking element
   state. And `<style>` bodies are the opposite case — `url()` in there IS a subresource. Every
   one of those has a spec, because each is a HOLE rather than a false positive.

   **`srcset` IS ONE REFERENCE, NOT N, AND THE REASON IS A COMMA.** A `data:` URI contains one
   (`data:image/png;base64,…`) and `srcset` is comma-separated, so splicing a replacement per
   candidate produces an attribute that no longer parses. The first candidate is resolved, the
   whole attribute value is replaced, and the rest are dropped with
   `Degradation(:asset_srcset_collapsed)` — visibly, because a PDF page has one pixel density
   and silently dropping alternatives is still dropping them.

   **A STYLESHEET IS A DOCUMENT, and this was the review's worst finding.** CSS carries `url()`
   and `@import`, so embedding a stylesheet verbatim handed every reference inside it to the
   engine as a LIVE URL — egress under `:bundled`, and an allowlist bypass under `:external`
   because one allowlisted host then chose arbitrary further egress. `Resolver#resolve_stylesheet`
   closes it, depth-capped. **JavaScript is deliberately NOT treated this way**: a URL in a
   program is a string, not a subresource, a script can mint one at runtime, and only the engine's
   own egress denial answers that (`F-15-egress-denial`). Do not "finish the job" by rewriting
   URLs inside JS — it would corrupt programs while closing nothing.

   **A TRAILING SLASH MEANS NOTHING IN HTML, and honouring it cost a stylesheet.** `<style/>` is
   an OPEN style element; the scanner skipped its body and every `url()` in it went unseen. The
   same test scanned a `<script/>` body as markup. Foreign content (`<svg>`/`<math>`) is the one
   real exception and is TRACKED — this plugin emits inline SVG itself, and treating `<style/>`
   inside it as open makes the scanner hunt for a `</style>` that is not there and stop, losing
   every later reference.

   **A STRUCTURAL REWRITE DISCARDS THE ELEMENT'S ATTRIBUTES, and three of them are semantic.**
   `media=print` silently became all-media, `type=module` became a classic script, `disabled`
   started applying. Rather than replicate HTML's semantics, the rewrite is allowed only for a
   closed safe set (`STRUCTURAL_SAFE_ATTRIBUTES`, with `media` carried through) and anything else
   falls back to a `data:` URI, which keeps the element intact. Adding a name to that set is a
   claim about what the attribute does.

   **THE LAYER IS NOW CALLED — F-16 CLOSED 2026-08-09.** `Reporting::ReportRun` resolves the
   engine first, asks it for `#capabilities`, runs each rendered body through
   `Assets::Resolver` and binds the result with `Render::AssetBinding`. Two things a later
   session should know. `RedmineReporterDashboards.asset_resolver` is the production factory
   and it lives in the **composition root, not in `reporting/`** — `Assets::Fetcher` is the
   plugin's only egress and `layer_purity`'s `reporting` arm exists to stop that layer
   becoming a second place that knows about HTTP; building one there would pass the gate's
   literal patterns and defeat its sentence. And `Reporting::AttachmentMapper` is the
   `mappers` port this class documents and nothing implemented — it is gated on
   `Attachment#visible?(**the run's actor**)`, which is where INV-1 lives on this path.

   **NOTHING CONSUMES `DocumentRequest#assets` YET, and that half is unchanged.** Neither shipped adapter declares
   `:asset_upload`, so the resolver always chooses `:inline` for both — correct and fully
   exercised — and the upload branch is proven at the resolver against a capability set that
   declares it. Declaring the capability without building the CDP `Fetch.enable` interceptor
   would be INV-7's exact sin, and G12 turns it from a skip into a hard failure. Finding
   **F-16**; the owner is T-34, whose engine's only model IS upload.

12. **T-18 is done — the owned drop layer.** `liquid/drops/` (12 classes + 3 bases),
   `liquid/batch.rb`, `liquid/diagnostics.rb`, and `RenderContext` grown a `batch`, a
   `diagnostics` and a `budget`. Five things a later session should know.

   **THE SPECS ARE SPLIT IN TWO ON PURPOSE, and neither can answer the other's question.**
   `spec_liquid/drops_spec.rb` + `collection_drop_spec.rb` render REAL templates against fake
   records — that is where the disposition table, the drop protocol and the two Liquid majors are
   proven. `spec/adapter/drop_performance_spec.rb` drives the drops DIRECTLY with no template —
   that is where the SQL is. The adapter half cannot render a template: `adapter_helper.rb`
   requires `spec_helper.rb`, which defines the Liquid stub, and the stub and the real gem cannot
   share a process (E-7). Pulling the gem in there would break 200+ tag examples in `rspec spec`.
   Do not "unify" these two files.

   **VISIBILITY LIVES IN `Batch`, NOT IN THE DROPS**, and a reviewer should check that first. Four
   of the six keys read tables with their own rules, so the actor is a REQUIRED constructor
   argument. The case that matters is the auditor: they hold ROLE_MANAGER in a DIFFERENT project,
   so `CustomField.visible` resolves the restricted field for them and only Redmine's per-project
   `visible_by?` refuses it. Without that second call the leak passes for everyone holding the role
   anywhere — and a values-only assertion would not see it, which is why the spec asserts the
   field's NAME is absent too.

   **`total_spent_hours` short-circuits on a LEAF, and that is load-bearing.** The batch answers
   own-hours; the total is self-plus-descendants, so for a leaf the two are the same number and the
   batched value answers with no query. Only a parent pays. `leaf?` is `rgt - lft == 1` on the row
   already loaded, and it is `respond_to?`-guarded because the adapter harness's Issue has no
   nested-set columns.

   **THE CAP IS THE MEMORY BOUND AND `find_each` IS NOT.** Liquid's `{% for %}` calls
   `Utils.slice_collection_using_each`, which collects the WHOLE segment into an Array before
   rendering one iteration. Batching bounds the database result set and the preload working set,
   not the peak memory of the render. Also: an ORDERED scope is deliberately NOT walked with
   `find_each` — that forces primary-key order and silently discards the author's, which renders a
   report in the wrong sequence with nothing to say so.

   **What T-18 did NOT do, deliberately:** nothing constructs a drop yet. There is no producer,
   exactly as `RenderContext`'s own comment says of T-07 — T-19 (filters), T-20 (retiring the two
   compensating tags) and T-23 are what wire them in. The `liquid/{version,custom_field_value}_drop.rb`
   and `issue_drop_patch.rb` files in the OLD location are still live for installs with the host
   plugin; T-20 deletes them. The two questions it raised are ANSWERED (2026-08-06): **F-8** is
   closed — `UserDrop#mail` stays absent, and note the scope, because the name invites the wrong
   one: it is only about printing an address inside a template body, not about §7b.5's mail
   sending, which resolves Redmine users server-side and reads `User#mail` on the model. **F-9** is
   deferred to real-template testing, with `Drops::CLASSES` holding the inventory until then.

11. **T-14 is done — the render preflight, in three places that share one implementation.**
   `render/preflight.rb` builds the probe document and the checks, `render/pdf_inspector.rb` reads
   the PDF back, `render/preflight_command.rb` owns the exit codes; the rake task and
   `ReporterPreflightController` are glue over them. Four things a later session should know.

   **`spec/conformance/pdf_probe.rb` is now a POLICY over `PdfInspector`, not an implementation.**
   The one thing it still decides is the one thing the two callers genuinely disagree about: a
   missing poppler is a hard ERROR for the corpus (a matrix generated without the probes prints PASS
   for checks that never ran) and a named SKIP for an operator (it is an optional package). Keep new
   reading code in `PdfInspector`; keep policy in its caller. The harness spec plants a missing tool
   by stubbing `PdfProbe.missing_tools`, so `PdfProbe.require_tools!` must keep consulting its OWN
   `missing_tools` rather than reaching past it.

   **`:skip` does not make the run red, and `complete?` is why that is honest.** `ok?` means nothing
   failed; `complete?` means nothing was left unanswered; the headline never prints a bare "OK" when
   a check was skipped, and the exit code is 0/1/2 with **2 = no engine registered, so nothing was
   verified** — deliberately not 0. If you add a check, add its id to
   `ReporterPreflightHelper::CHECK_LABELS` and to all nine locale files, or a Russian UI silently
   renders the English title.

   **The probe document inlines the SHIPPED `chart_shell.js`, in `<head>`.** Not a copy of it, and
   not at the end of the body: the hosted-image probe calls `__rd.begin()`/`end()` inline so the
   document stays open until that fetch resolves, which is what makes `HOSTED-IMAGE blocked` a fact
   rather than a race. Without the shell the probe waited out the full watchdog — 17.5 s and a
   spurious `readiness_timeout` — which is §Findings E-10's first defect.

   **The probe's GEOMETRY is load-bearing too, and it fooled me once.** Anything the pixel checks
   sample must be `position: absolute` with a percentage top/height, like `.badge` and `.plate` —
   never in normal flow. A flow-positioned element lands wherever the engine's default margins put
   it, so a red pixel check cannot be told apart from a layout difference. That cost a CI round and
   very nearly put a false sentence about wkhtmltopdf into the support matrix (§Findings E-11):
   it decodes inline `data:` images perfectly, and my plate was 4mm off.

   **The probe's colours are load-bearing, and one of them was wrong.** `PROBE_PNG` must be a
   colour that appears NOWHERE else in the document. It was `#00aaff`, the page background, and
   the `inline_asset` check therefore passed whether or not the image decoded — the `<img>` has a
   fixed height, so the page showed through. If you change either `PROBE_PNG` or
   `body { background }`, check they still differ; a spec asserts it, because nothing else can.

   **A check that cannot run is emitted, never omitted.** `DOCUMENT_CHECKS` drives both the run
   path and the poppler-missing skip path so the report has ONE shape. The first version returned
   early with an umbrella skip and silently dropped the INV-8 containment check; two installs' JSON
   were also not comparable. Add a check to that table, not to the array.

   **`degradations` is not "any degradation is a defect".** wkhtmltopdf stamps `legacy_engine` on
   every render by design, and the blocked hosted image produces `asset_unresolved` — the one the
   probe deliberately provokes. Both are expected, both are still printed. Only the asset one is
   conditional: with no Redmine base URL, an unresolved asset IS a defect.

   **The Minitest half had never run when it was written.** `test/functional/reporter_preflight_controller_test.rb`
   and `test/unit/render_preflight_rake_test.rb` need a booted Redmine, so the `standalone` CI job
   is their first execution — it went green on all four branches on the first try. Local
   verification of anything in `app/` stops at `ruby -c` plus an ERB compile; note that plain ERB
   mis-parses `<%= form_tag … do %>` where Rails does not, so a bare `ERB.new(...).src` syntax check
   reports a false failure on any view with a block helper.

9. **T-10 is done — `render/` exists and `layer_purity` is STRICT.** The document-request
   interface only: types, a sum type, and the wrapper that makes INV-5 mechanical.
   Nothing renders yet. Two things a later session should know. **`DocumentRequest`'s
   security property is its SHAPE** — the spec asserts against the constructor's
   parameter list that no `cookies:`/`headers:`/`auth:`/`url:` exists, so adding any
   general-purpose escape hatch fails a test rather than passing review; read the file
   comment before you add a field. And **`Renderer` is where INV-5 stops being a rule** —
   it rewrites any adapter's output that is not `%PDF-`…`%%EOF` or is under
   MIN_PDF_BYTES, so no adapter can breach it by accident. Its documented LIMIT is next
   to the check: the byte test kills "exception as document" and says nothing about a
   VALID PDF whose content is wrong. Do not let it stand in for the whole invariant.
   **P-2's second premise is now half false** — Chromium 141 IS in this container, so
   T-11/T-13 can be exercised rather than written blind. A local Chromium is still not a
   CI-verified engine; that is T-12's job, and the `render-smoke` job it added is where
   that becomes true. **Both were exercised, 2026-08-06** — see entry 10.
4. **T-02 is done.** `rake reporter_dashboards:migrate_from_reporter:plan` is the repeatable form of the
   R-15 measurement, and `RedmineReporterDashboards::TemplateLinter` is the linter FR-71
   later puts behind the editor's lint panel — so extend that one rule table rather than
   writing a second checker. It raised **F-3** (a question about gate G8's 1.0 target)
   which is the curator's. What is still owed by a later task: `rake
   reporter_dashboards:lint_templates`, which the spec names in §6 — today it would be a
   duplicate of `import:plan`'s section 5, so it was deliberately not written twice.
5. **T-07 is done** — §6 records what is exercised and what deliberately is not.
6. **T-08 is done — port AND D-1 fix.** The two kernel files are at
   `lib/redmine_reporter_dashboards/aggregation/`, and `KERNEL_FILES` is a map (working-tree
   path => v0.5.0 blob path) so gate G7 compares the ported file with its baseline instead of
   comparing a path with itself. G7 now reconstructs the expected file as *blob + declared
   hunks* rather than diffing: `drill_through.rb` declares none and is held to plain
   byte-identity; `query_aggregator.rb` declares ONE, D-1's.
7. **T-09 is done, and the status table used to say the opposite in both directions.**
   The secret, the probe job and the private checkout went earlier; this session added
   the two gates its `Accept:` list still named — `layer_purity.sh` (E3, internal
   layering) and `compat_size.sh` (E4, version divergence) — and moved the one scattered
   `Redmine::VERSION` out of a helper into `Compat`. **`layer_purity` runs in warn mode
   because `render/` does not exist until T-10, and it reports an absent layer on its own
   line rather than passing over it: T-10 should flip it to
   `LAYER_PURITY_MODE=strict` in the same PR that creates `render/`.** Two things stay
   open and are findings, not work: **F-4** (nobody has committed a `compat/` LOC number,
   and CLAUDE.md claims one exists) and **F-5** (the dated fork-PR run, which no job can
   produce). **Next: T-10**, which also owes T-03's blocked HTML|PDF baseline (P-2). **There is no writer for
   those recorded fragments, deliberately** — an overlay entry records a MEASUREMENT and can
   be regenerated, an exception records an ARGUMENT and must be written by hand with its
   reason, or the gate becomes a formality. Next: **T-09 onward**.

---

## 6. T-07 as built — what is exercised, and what deliberately is not

Implemented 2026-08-05. The design that preceded it was right about the shape; this
records what a reader cannot see from the diff.

**The seam was five call sites.** Two `include`s, two `resolve_scope`, one
`resolve_query`. `Liquid::ScopeBinding` keeps those two method names, so each tag
changed by one line.

| Layer | File | Sources |
|---|---|---|
| owned | `liquid/scope_binding.rb` | **two**: `query_id:` → `IssueQuery.visible(actor)`, else `RenderContext#scope` |
| owned | `liquid/render_context.rb` | — carries actor, scope, query. **An actor is required to construct one** |
| legacy | `glue/legacy/scope_resolution.rb` | six, unchanged, moved |
| legacy | `glue/legacy/reporter_list_patch.rb` | owns the thread-local, moved |

**`enforce_visibility` was not ported, and that is the point.** It exists in the legacy
module because five of its six sources have provenance it cannot vouch for — which is
also why it has to fail OPEN. Both owned sources start from `Issue.visible`, so there is
nothing left to defend. An invariant held by construction, not by a patch.

**THE OWNED PATH IS NOT EXERCISED IN PRODUCTION YET, and must not be made to look as
if it is.** Nothing builds a `RenderContext`: these tags only ever run inside the
optional host plugin's renderer, and standalone T-06 degrades the widgets. So every
real render still takes the legacy path, which is exactly what T-07's acceptance list
asks for. T-10 is what fills it in. If you are tempted to have the glue synthesise a
`RenderContext` from the host's registers to "finish" this — don't. It would run the
same archaeology behind a new name and make the owned path look tested.

What *is* exercised: `spec/liquid/scope_binding_spec.rb`, 25 examples, including one
that stubs `User.current` to RAISE and asserts the owned path completes. INV-1 is the
easiest invariant here to lose silently, so it is tested by explosion rather than by
reading the code.

**The two results that mattered, both measured:** `spec/golden/` is byte-identical
(`git diff --stat -- spec/golden` empty) and all **217 corpus examples** pass — T-07's
acceptance list calls that "the single most important assertion in the whole plan".
F-2's decision is what bought the first one: closing the leak by construction in the
owned path, rather than patching the legacy module, means the frozen scope-fixture
triple never moved.

**A trap for the next mover.** The two tag specs and the scope-fixture test exercise
the LEGACY path, so they must `require` `glue/legacy/scope_resolution` explicitly.
On a real install it arrives via `REPORTER_GLUE_FILES`; in a spec process nothing loads
it, and `ScopeBinding` then correctly resolves *nothing* — which reads as 40 broken
examples rather than as a missing require.

**`REPORTER_GLUE_FILES` is separate from `REPORTER_PATCH_FILES` on purpose.** The legacy
module is loaded whenever the host plugin is present, not as a side effect of the
`IssueListReportTemplate` prepend succeeding. Tying the two would mean one failed patch
silently costing an install its scope resolution.

**The gate:** `script/gates/no_thread_local.sh`, wired into the `gates` job. It also
catches `thread_variable_set`/`Fiber[]`, because swapping the spelling would satisfy a
naive grep while changing nothing. Warn mode passes with two exemptions; strict mode
fails today by design, and is what 1.0 must pass once `glue/legacy/` is gone.

**Still under `lib/` rather than `glue/`**, and deliberately left for a later mechanical
move: `reporter_report_content_patch.rb`, `patches/report_patch.rb`,
`liquid/issue_drop_patch.rb`, `liquid/custom_field_value_drop.rb`. All host-plugin-only.
T-07 moved exactly what its `Touches:` line named plus what the new gate forced; a
general reorganisation is a different commit.
