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

  # T-27 — THE UPGRADE DIAGNOSTIC, ON EVERY RENDER OF THIS PAGE.
  #
  # A `before_action` and not a line in `show`, because `run` renders the same template:
  # written in `show` alone, pressing the button would make the audit vanish, which is
  # the one moment an administrator is definitely looking at this page.
  #
  # It is deliberately NOT behind the POST. `run` is a POST because it spawns a browser
  # (see below); this costs one `SELECT` over a table with a handful of rows, and the
  # failure it exists to catch is a grant nobody went looking for — so it has to be on
  # the page an administrator lands on, not behind an action they must choose.
  before_action :load_authoring_audit

  helper :reporter_preflight

  def show
    @reports = nil
  end

  # `engine` NAMES ONE ENGINE TO CHECK DELIBERATELY, and its absence keeps the old
  # behaviour: the default set, with a named skip per service-backed engine. Without it
  # this page could not diagnose `:gotenberg` at all (§Findings E-27 row 6): the deferral
  # always applied, and the skip told an administrator — the one reader who has no shell
  # — to go and run a rake task. Naming an engine is a decision, so it runs the real
  # checks, credential included, exactly as `RRD_ENGINE=<id>` does on the rake surface.
  #
  # The value is handed to `PreflightSuite`, whose registry lookup is the validation —
  # a name it does not know, or a value that parses to no id at all (`'  '`, `','`),
  # raises rather than silently running the default set, and the page answers with an
  # error naming the known engines instead of a 500. Nothing is ever constructed from
  # the parameter: every id in it is matched against `Registry.ids` or the whole value
  # is refused. "Every id" because the suite parses a comma-separated LIST, exactly as
  # `RRD_ENGINE` does — the select offers single ids, but a hand-crafted
  # `engine=a,b` runs both, which is the rake surface's own documented meaning and
  # admin-gated either way.
  def run
    engine = params[:engine].to_s
    @reports = Render::PreflightSuite.new(
      engine_ids: engine.empty? ? nil : engine,
      redmine_base_url: redmine_base_url,
      # FR-50 — the same port the rake task fills, and the reason it is a port rather than a
      # read inside the suite: this controller is application code and may know that a
      # `Setting` table exists; `render/**` may not (mechanism E5).
      selected_engine_id: RedmineReporterDashboards.render_engine_id(logger: Rails.logger),
      logger: Rails.logger
    ).reports
    render :show
  rescue Render::Registry::UnknownEngine
    flash.now[:error] = l(:text_reporter_preflight_unknown_engine,
                          engines: Render::Registry.ids.map(&:to_s).join(', '))
    @reports = nil
    render :show
  end

  private

  # `Role.all` and NOT `Role.givable`, which is the one decision in this method.
  #
  # `Role.givable` excludes the builtin Non-member and Anonymous roles — and a builtin
  # role CAN hold the base plugin's authoring permission, because
  # `:manage_report_templates` is registered with no `require:` at all, so
  # `Role#setable_permissions` subtracts nothing for either of them and an administrator
  # can tick it on Anonymous. That is the most alarming row this page can print, and
  # `givable` would filter out exactly it. Ours cannot land there — `Entry#requires`
  # derives `:member` from `authoring` — which is the asymmetry the page reports.
  #
  # `order(:id)` because the audit sorts by name and needs a deterministic tiebreak on a
  # duplicate name; an unordered read gives Postgres, MySQL and MariaDB three different
  # answers (CLAUDE.md §6).
  def load_authoring_audit
    @authoring_audit =
      RedmineReporterDashboards::Permissions::AuthoringAudit.rows(Role.order(:id).to_a)
  end

  # The port `render/**` may not reach for itself — mechanism E5, and the boundary
  # `layer_purity.sh` enforces. This controller is application code, so it is allowed to
  # know that Redmine keeps its own URL in Setting; `Render::Preflight` is not.
  def redmine_base_url
    return nil if Setting.host_name.blank?

    "#{Setting.protocol}://#{Setting.host_name}"
  end
end
