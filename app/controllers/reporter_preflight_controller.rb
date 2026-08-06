# frozen_string_literal: true

# T-14 — the render preflight, for an administrator who does not have a shell.
#
# The rake task is the same diagnostic and reaches a different person: whoever can run
# `rake` on the box is usually not whoever is looking at a report with a hole in it. So
# both exist, and they share every decision — the checks, the states, the wording —
# because both call `Render::Preflight`. This controller adds authorization, an HTTP
# verb and a view, and nothing else.
#
# --- WHY `run` IS A POST ---
#
# It starts a browser, renders a document and waits for it. A GET with that behind it is
# a GET a crawler, a prefetching proxy or a browser's address bar can fire, and each of
# those would spawn an engine. `show` is the GET; `run` is the POST, and Redmine's CSRF
# protection applies to it because it is one.
#
# --- AND WHY IT RUNS INLINE ---
#
# It holds a web worker for a few seconds. That is deliberate: the alternative is a job
# queue this plugin does not have, and a diagnostic an administrator runs by hand
# perhaps twice in an installation's life does not justify one. The engine's own limits
# bound it — `ProcessPool` REFUSES rather than queueing behind a busy worker, and the
# request carries a 30-second timeout — so the worst case is a slow page, never a hung
# one.
class ReporterPreflightController < ApplicationController
  # The plugin's lib/ is not on Redmine's autoload paths, so `Render` would not resolve
  # here. `lib/redmine_reporter_dashboards.rb` has already required it at boot; this is
  # only a shorter name for it in this file.
  Render = RedmineReporterDashboards::Render

  layout 'admin'

  # Every action, not "the admin layout already implies it". An administrator-only
  # diagnostic that spawns a subprocess is exactly the action where an inherited check
  # is not good enough.
  before_action :require_admin

  helper :reporter_preflight

  def show
    @reports = nil
  end

  def run
    @reports = Render::Registry.ids.map { |id| report_for(id) }
    render :show
  end

  private

  # A construction failure is a REPORT, not a 500. "Chromium is not installed" is the
  # single most likely thing this page finds, and an error page tells the administrator
  # less than the check that says so by name.
  #
  # --- AND THE ENGINE IS SHUT DOWN, EVERY TIME ---
  #
  # A fresh adapter is constructed per request, and the Chromium one owns a process pool
  # that starts a browser on its first render. Without the `ensure` below, an
  # administrator who clicks the button three times leaves three browsers running for
  # the lifetime of the web worker — a diagnostic whose own side effect is the resource
  # leak it exists to detect. The rake task gets away with it because the process exits;
  # this does not.
  def report_for(id)
    engine = Render::Registry.fetch(id).new
    begin
      Render::Preflight.new(engine: engine, redmine_base_url: redmine_base_url,
                            logger: Rails.logger).run
    ensure
      shutdown(engine, id)
    end
  rescue StandardError => e
    Rails.logger.error("[reporter_dashboards] preflight could not start #{id}: " \
                       "#{e.class}: #{e.message}")
    Render::Preflight::Report.new(
      engine_id: id, engine_version: 'unavailable', duration_ms: 0,
      checks: [Render::Preflight::Check.new(
        id: :engine, title: 'the render engine could be started', state: :fail,
        detail: "#{e.class}: #{e.message}", duration_ms: 0
      )]
    )
  end

  # A shutdown that raises must not turn a completed diagnostic into a 500 — the report
  # is already built by the time this runs, and losing it to a cleanup error would be
  # the worst possible trade. Logged rather than swallowed silently: `rescue nil` is a
  # forbidden construct here for exactly this reason.
  def shutdown(engine, id)
    engine.shutdown if engine.respond_to?(:shutdown)
  rescue StandardError => e
    Rails.logger.warn("[reporter_dashboards] preflight could not shut down #{id}: " \
                      "#{e.class}: #{e.message}")
  end

  # The port `render/**` may not reach for itself — mechanism E5, and the boundary
  # `layer_purity.sh` enforces. This controller is application code, so it is allowed to
  # know that Redmine keeps its own URL in Setting; `Render::Preflight` is not.
  def redmine_base_url
    return nil if Setting.host_name.blank?

    "#{Setting.protocol}://#{Setting.host_name}"
  end
end
