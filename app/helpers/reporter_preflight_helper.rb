# frozen_string_literal: true

# The translation seam between the render layer and the admin page.
#
# `Render::Preflight::Check` carries an English `title` and a stable symbolic `id`. The
# title is for the rake task and the JSON artefact — an ops surface, and CLAUDE.md's
# working language is English. The ADMIN PAGE is a user-facing view, so §10 applies to
# it and nothing there may be a hardcoded string.
#
# The `id` is what bridges the two: it is the part of `Check` that is a contract rather
# than prose, so it is the part that keys a locale file. A view keyed on the title would
# break every translation the day somebody improves the wording, which is the same
# reason the diagnostic emits JSON instead of log lines.
#
# --- ONE THING ON THE PAGE IS DELIBERATELY NOT TRANSLATED: `Check#detail` ---
#
# It carries an engine's own message, an exception class and text, a URL, a pixel
# triple. Those are DIAGNOSTIC VALUES, not prose: they are what an administrator pastes
# into an issue and what a maintainer greps for, and translating `Errno::ENOENT` or
# `rgb[0, 170, 255]` would make the report less useful in every language including
# English. §10's rule is about strings the product SAYS; this column is data the engine
# reported. Everything the product says here — every label, every state, every unit — is
# keyed.
module ReporterPreflightHelper
  # Closed maps, not `"label_..._#{id}"`. An unknown id must not become a missing
  # translation an operator sees as `translation missing: ...`; it falls back to the
  # English title the check already carries, which is always present and always true.
  CHECK_LABELS = {
    engine: :label_reporter_preflight_check_engine,
    degradations: :label_reporter_preflight_check_degradations,
    page_breaks: :label_reporter_preflight_check_page_breaks,
    footer: :label_reporter_preflight_check_footer,
    background: :label_reporter_preflight_check_background,
    inline_asset: :label_reporter_preflight_check_inline_asset,
    javascript: :label_reporter_preflight_check_javascript,
    readiness: :label_reporter_preflight_check_readiness,
    hosted_asset: :label_reporter_preflight_check_hosted_asset,
    # T-34. An ENGINE'S OWN configuration checks, and the deferral. Seven ids shipped
    # without keys and the control below still passed, because it hand-wrote the emitted
    # set — see `Render.emittable_check_ids`, which it now reads instead.
    engine_not_selected: :label_reporter_preflight_check_engine_not_selected,
    engine_configuration: :label_reporter_preflight_check_engine_configuration,
    gotenberg_endpoint: :label_reporter_preflight_check_gotenberg_endpoint,
    gotenberg_reachable: :label_reporter_preflight_check_gotenberg_reachable,
    gotenberg_credential: :label_reporter_preflight_check_gotenberg_credential,
    gotenberg_version: :label_reporter_preflight_check_gotenberg_version,
    gotenberg_javascript: :label_reporter_preflight_check_gotenberg_javascript
  }.freeze

  STATE_LABELS = {
    pass: :label_reporter_preflight_state_pass,
    fail: :label_reporter_preflight_state_fail,
    skip: :label_reporter_preflight_state_skip,
    expected_failure: :label_reporter_preflight_state_expected_failure
  }.freeze

  # Redmine's own status classes, so the page looks like the rest of the admin area and
  # this plugin ships no design tokens of its own (CLAUDE.md §4).
  #
  # `expected_failure` is deliberately NOT the failure colour. A check that is supposed
  # to fail and one that is not must never look the same, or the one that matters gets
  # ignored along with the one that does not.
  STATE_CLASSES = {
    pass: 'icon icon-ok',
    fail: 'icon icon-error',
    skip: 'icon icon-help',
    expected_failure: 'icon icon-warning'
  }.freeze

  # The engine selector's options (E-27 row 6): the default set first, then every
  # registered engine BY ITS ID. Ids are ops vocabulary, the same tokens the rake
  # surface's `RRD_ENGINE=` takes and the report headings already print, so they are
  # deliberately not translated — a localised alias here would be one more name for a
  # thing that has exactly one name everywhere else.
  def reporter_preflight_engine_options
    [[l(:label_reporter_preflight_engine_default), '']] +
      RedmineReporterDashboards::Render::Registry.ids.map { |id| [id.to_s, id.to_s] }
  end

  # Even the unit. `ms` reads the same in most of the nine locales and not in all of
  # them, and a view that hardcodes one token is a view that hardcodes the next one too.
  def reporter_preflight_duration(ms)
    l(:label_reporter_preflight_duration_ms, count: ms.to_i)
  end

  def reporter_preflight_check_label(check)
    key = CHECK_LABELS[check.id.to_sym]
    key ? l(key) : check.title
  end

  def reporter_preflight_state_label(state)
    key = STATE_LABELS[state.to_sym]
    key ? l(key) : state.to_s
  end

  def reporter_preflight_state_class(state)
    STATE_CLASSES.fetch(state.to_sym, '')
  end

  # One sentence an administrator can act on, and never a bare "OK" when something did
  # not run — the same rule `Report#headline` states for the terminal.
  def reporter_preflight_summary(report)
    return l(:text_reporter_preflight_problems, count: report.failures.length) unless report.ok?
    return l(:text_reporter_preflight_ok) if report.complete?

    l(:text_reporter_preflight_incomplete, count: report.skipped.length)
  end
end
