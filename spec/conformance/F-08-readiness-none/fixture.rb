# frozen_string_literal: true

# T-11's FIRST falsifying fixture: a document with no charts at all.
#
# This is the one an implementation with a fixed `javascript_delay: 3000` cannot pass,
# and it is the cheapest case in the corpus: a page with nothing to draw must be the
# FASTEST document on the site, not the slowest. The shell settles on DOMContentLoaded
# for exactly this reason (the bug that writing it found: nothing ever calls `end()`,
# so `pending` never reaches zero *from above zero*, and a chart-free page waited out
# the watchdog).
#
# The bound is deliberately generous and still falsifying: the readiness configuration
# below puts the in-page watchdog at 4 s, so an implementation that waits for a timer
# rather than for the signal takes at least 4 s and cannot come in under 2.5.
RedmineReporterDashboards::Conformance.fixture(
  'F-08-readiness-none', 'a chart-free document is ready immediately', dir: __dir__
) do |f|
  f.requires!(:javascript)
  f.request!(page_size: 'A4')
  f.readiness!(timeout_ms: 6_000, client_timeout_ms: 4_000)
  f.attempts!(2)

  f.check('it renders well inside the readiness budget') do |v|
    v.expect_between(v.duration_ms, 0, 2_500,
                     'render duration (ms) for a document with nothing to wait for')
  end

  f.check('nothing was recorded as degraded') do |v|
    v.expect_equal(v.degradations, [], 'degradations')
  end

  f.check('the page reported itself ready, not timed out') do |v|
    v.expect_includes(v.text, 'RD-STATE ready=true', 'the readiness state mirrored into the DOM')
    v.expect_includes(v.text, 'degraded=[]', 'the page-side degradation list')
  end
end
