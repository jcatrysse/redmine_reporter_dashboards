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
module ReporterPreflightHelper
  # Closed maps, not `"label_..._#{id}"`. An unknown id must not become a missing
  # translation an operator sees as `translation missing: ...`; it falls back to the
  # English title the check already carries, which is always present and always true.
  CHECK_LABELS = {
    engine: :label_reporter_preflight_check_engine,
    degradations: :label_reporter_preflight_check_degradations,
    document: :label_reporter_preflight_check_document,
    page_breaks: :label_reporter_preflight_check_page_breaks,
    footer: :label_reporter_preflight_check_footer,
    background: :label_reporter_preflight_check_background,
    inline_asset: :label_reporter_preflight_check_inline_asset,
    javascript: :label_reporter_preflight_check_javascript,
    readiness: :label_reporter_preflight_check_readiness,
    hosted_asset: :label_reporter_preflight_check_hosted_asset
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
