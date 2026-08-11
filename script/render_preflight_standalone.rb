# frozen_string_literal: true

# The preflight command, runnable without Redmine — the same glue
# `lib/tasks/reporter_dashboards.rake` performs, minus the one line that reads
# `Setting` (a base URL only the application can know; without it the hosted-image
# check is skipped, which the report says out loud).
#
# --- WHY THIS EXISTS (§Findings E-27 row 11) ---
#
# `rake reporter_dashboards:render:preflight` documents an exit-code contract —
# 0 verified, 1 failed, 2 nothing verified — and for two releases NO CI RUN EVER READ
# ONE OF THOSE CODES off a real process. The rake glue is unit-tested with a stubbed
# `Preflight`, and `PreflightCommand`'s spec drives the codes in-process; what nobody
# exercised was the contract end to end: a real engine, a real service, a real exit
# status. The render-smoke job has the real services and no Redmine, so this driver is
# how the contract gets a process boundary there (`script/render_preflight_exit_codes.sh`
# is the caller and the assertion).
#
# Interface, same as the rake surface: RRD_ENGINE selects engines, RRD_FORMAT picks
# text or json, and the exit code is the product.

require File.expand_path('../lib/redmine_reporter_dashboards/render/preflight_command', __dir__)
RedmineReporterDashboards::Render::PreflightCommand.load_engines!

exit RedmineReporterDashboards::Render::PreflightCommand.new(
  engine_ids: ENV.fetch('RRD_ENGINE', nil),
  format: ENV.fetch('RRD_FORMAT', 'text').to_sym
).call
