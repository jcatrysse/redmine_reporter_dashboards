# frozen_string_literal: true

# T-14 — the render preflight, for an administrator who does not have a shell.
#
# The rake task is the same diagnostic and reaches a different person: whoever can run
# `rake` on the box is usually not whoever is looking at a report with a hole in it. So
# both exist, and they share every decision — the checks, the states, the wording, and
# the running itself — because both go through `Render::PreflightSuite`. This controller
# adds authorization, an HTTP verb and a view, and nothing else.
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
# one. `PreflightSuite` shuts every engine down afterwards, so the page cannot leak the
# browsers it starts.
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
    @reports = Render::PreflightSuite.new(redmine_base_url: redmine_base_url,
                                          logger: Rails.logger).reports
    render :show
  end

  private

  # The port `render/**` may not reach for itself — mechanism E5, and the boundary
  # `layer_purity.sh` enforces. This controller is application code, so it is allowed to
  # know that Redmine keeps its own URL in Setting; `Render::Preflight` is not.
  def redmine_base_url
    return nil if Setting.host_name.blank?

    "#{Setting.protocol}://#{Setting.host_name}"
  end
end
