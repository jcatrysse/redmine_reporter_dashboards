# frozen_string_literal: true

# The ENGINE's timeout arm — the case F-10 cannot reach.
#
# F-10's page answers, late and apologetically. This page never answers AT ALL: it
# declares `window.__rd` with `ready: false` and no watchdog, which is what a document
# looks like when the shell failed to load, when a script threw before the watchdog was
# armed, or when a template predates the protocol entirely. There is no in-page
# component left to be clever, so the engine's own timeout is the only thing between
# the reader and a hang.
#
# What must happen: the engine RENDERS ANYWAY and the result carries
# `Degradation(:readiness_timeout)`. Not a failure — the tables, the totals and the
# narrative are all there and the reader is told what is missing.
RedmineReporterDashboards::Conformance.fixture(
  'F-11-readiness-timeout', 'a page that never signals is rendered anyway, and degraded',
  dir: __dir__
) do |f|
  f.requires!(:javascript)
  f.request!(page_size: 'A4')
  f.readiness!(timeout_ms: 3_000, client_timeout_ms: 2_900)

  f.check('the engine waited its timeout and then gave up') do |v|
    v.expect_between(v.duration_ms, 2_900, 7_000, 'render duration (ms) against a 3 s timeout')
  end

  f.check('it is a Success, not a Failure') do |v|
    v.expect_true(v.result.success?, "expected a Success, got #{v.result.class}")
  end

  f.check('the readiness timeout is recorded as a degradation') do |v|
    v.expect_includes(v.degradations.map(&:to_s).join(','), 'readiness_timeout',
                      'degradations on the result')
  end

  f.check('the document is complete apart from what it was waiting for') do |v|
    v.expect_includes(v.flat_text, 'NEVER-SIGNALS', 'body text')
    v.expect_includes(v.flat_text, 'TABLE-ROW-7', 'content that did not depend on the signal')
  end
end
