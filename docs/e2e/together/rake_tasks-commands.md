# Rake tasks against the e2e database (production)

### `rake reporter_dashboards:migrate_from_reporter:plan`

exit 0

```
------------------------------------------------------------------------------
reporter_dashboards:migrate_from_reporter:plan — read-only survey
------------------------------------------------------------------------------
Nothing was written. This task only reads.
------------------------------------------------------------------------------
1. reporter's tables
------------------------------------------------------------------------------
  report_templates         ABSENT
  report_schedules         ABSENT
  report_schedules_users   ABSENT
None of the tables above exists in this database, so there is nothing to
survey here. That is the expected result on an installation that never had
redmine_reporter — it is not an error, and it is not evidence that the
production installation has nothing either. Run this task against the
database that actually holds the templates.
Sections 2 to 5 are omitted for that reason — the numbering below stays
fixed so a section number always means the same thing.
------------------------------------------------------------------------------
6. what this survey could NOT answer
------------------------------------------------------------------------------
  R-15 query 4 — how much the ad-hoc mail and public-token paths are actually
  used — cannot be answered from a database connection. It lives in the request
  log. Run this on the Redmine host:
      grep -cE '(/issue_mails|[?&]token=)' log/production.log*
  Until it has been run, the keep/drop decision for those two features rests on
```

### `rake reporter_dashboards:lint_templates`

exit 0

```
==============================================================================
reporter_dashboards — template lint
==============================================================================
  4 template(s) examined.
  0 error(s), 0 warning(s).
  0 template(s) have at least one error.
  An error is something that will break when the render path changes; a warning
  may be a false positive and says so in its own message.
  Nothing to report — every template is clean.
```

### `RRD_PROJECT=e2e-project rake reporter_dashboards:lint_templates`

exit 0

```
==============================================================================
reporter_dashboards — template lint
==============================================================================
  3 template(s) examined.
  0 error(s), 0 warning(s).
  0 template(s) have at least one error.
  An error is something that will break when the render path changes; a warning
  may be a false positive and says so in its own message.
  Nothing to report — every template is clean.
```

### `RRD_PROJECT=e2e-project RRD_OUT=/home/user/redmine_reporter_dashboards/redmine/tmp/e2e-bundle.json rake reporter_dashboards:export:bundle`

exit 0

```
wrote 2457 bytes to /home/user/redmine_reporter_dashboards/redmine/tmp/e2e-bundle.json
```

### `RRD_FILE=/home/user/redmine_reporter_dashboards/redmine/tmp/e2e-bundle.json RRD_PROJECT=e2e-private rake reporter_dashboards:import:plan`

exit 0

```
Template bundle — plan
======================
PLAN ONLY — nothing was written.
format_version: 1
exported_at:    2026-10-06T21:17:17Z
plugin_version: 0.5.0
templates:      3
3      imported
  E2E issue report: imported
  E2E private draft: imported
  E2E time report: imported
Plan complete.
```

### `RRD_FILE=/nonexistent.json RRD_PROJECT=e2e-private rake reporter_dashboards:import:plan`

exit 2

```
/nonexistent.json does not exist
```

### `RRD_FILE=/home/user/redmine_reporter_dashboards/redmine/tmp/e2e-bundle.json RRD_PROJECT=e2e-private RRD_ON_CONFLICT=rename RRD_ACTOR=admin rake reporter_dashboards:import:run`

exit 0

```
Template bundle — apply
=======================
format_version: 1
exported_at:    2026-10-06T21:17:17Z
plugin_version: 0.5.0
templates:      3
3      imported
  E2E issue report: imported
  E2E private draft: imported
  E2E time report: imported
OK.
```

### `rake reporter_dashboards:schedules:status`

exit 1

```
enabled schedules: 1
last attempt:      never
  * At least one schedule is active and has never been reached by a run. The scheduler needs a periodic external invocation — see the README — and it looks like nothing is calling it.
```

### `rake reporter_dashboards:schedules:run`

exit 0

```
1 schedule(s) considered, 0 incomplete, 1 occurrence(s) claimed, 0 already claimed, 1 delivered, 0 failed
  * At least one schedule is active and has never been reached by a run. The scheduler needs a periodic external invocation — see the README — and it looks like nothing is calling it.
  * This run is that invocation. If it came from cron, nothing further is needed and the warning above will not appear again.
```

schedules:run delivered 1 mail(s) with subject "E2E daily issue report"

### `rake reporter_dashboards:schedules:run`

exit 0

```
1 schedule(s) considered, 0 incomplete, 0 occurrence(s) claimed, 1 already claimed, 0 delivered, 0 failed
```

### `rake reporter_dashboards:schedules:status`

exit 0

```
enabled schedules: 1
last attempt:      2026-10-06 21:17:35 UTC
  no warnings
```

### `RRD_DRY_RUN=1 rake reporter_dashboards:documents:purge`

exit 0

```
would purge 0 document(s), 0 byte(s) of stored report
nothing expired
```

### `RRD_ENGINE=chromium_cdp rake reporter_dashboards:render:preflight`

exit 0

```
render preflight: chromium_cdp Chrome/141.0.7390.37 (OK, 568ms)
  PASS               the render engine produced a document          35617 bytes from chromium_cdp Chrome/141.0.7390.37
  PASS               nothing was silently degraded                  none
  PASS               page breaks produce more than one page         2 page(s)
  PASS               the page-number footer is compiled and numbered Page 1 of 2
  PASS               backgrounds are printed, so badges keep their colour page rgb[0, 170, 255], badge rgb[204, 0, 0]
  PASS               an inline (data:) image decodes to the right colour rgb[1, 255, 0], wanted rgb[0, 255, 0]
  PASS               the JavaScript path runs, so charts can draw   CANVAS-STATE drawn
  PASS               the readiness shell loads, so a chart-free page does not wait SHELL present
  EXPECTED_FAILURE   a Redmine-hosted image is blocked (expected: the renderer has no network) blocked, as the :bundled policy intends
```
