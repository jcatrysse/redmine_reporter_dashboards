# frozen_string_literal: true

# THE FALSIFIER. This is the fixture T-11's Accept list ends on, and finding F-7 is the
# record of it being owed until an engine existed to run it through.
#
# One chart signals at 6 s, and writes a marker into the DOM immediately before it
# calls `end()`. Three implementations are told apart by this one page:
#
#   a fixed 3-second delay      prints before the marker exists  -> no marker, FAIL
#   waiting out the timeout     20 s of wall clock               -> over 12 s, FAIL
#   honouring the signal        about 6.3 s, marker present      -> PASS
#
# The timeout is 20 s ON PURPOSE. At the default 10 s, "wait for the timeout" and
# "honour a 6 s signal" both land inside a 12 s bound and the fixture would stop
# discriminating — which is the failure mode of a test that is loosened after its first
# flake until it proves nothing.
#
# Three attempts, all of which must pass, with bounds wide enough that a loaded CI
# runner does not need them relaxed later. T-11: "run 3/3 attempts on the gate with
# deliberately generous bounds — a tight wall-clock bound gets loosened after the first
# flake and then proves nothing."
RedmineReporterDashboards::Conformance.fixture(
  'F-13-readiness-late-signal', 'a chart signalling at 6 s is waited for, and only for that',
  dir: __dir__
) do |f|
  f.requires!(:javascript)
  f.request!(page_size: 'A4')
  f.readiness!(timeout_ms: 20_000, client_timeout_ms: 18_000)
  f.attempts!(3)

  f.check('the wall clock is the chart, not the timeout and not a guess') do |v|
    v.expect_between(v.duration_ms, 5_900, 12_000,
                     'monotonic render duration (ms) for a chart that signals at 6 s')
  end

  f.check('the post-readiness marker is in the document') do |v|
    v.expect_includes(v.flat_text, 'POST-READINESS-MARKER', 'the text written just before end()')
  end

  # See F-08: a compatibility engine stamps `:legacy_engine` on everything it draws,
  # and a readiness fixture must not fail over an unrelated degradation.
  f.check('nothing timed out — neither the engine nor the page gave up') do |v|
    v.expect_true(!v.degradations.include?(:readiness_timeout),
                  "expected no readiness degradation, got #{v.degradations.inspect}")
    v.expect_excludes(v.flat_text, 'client_watchdog', 'the page-side degradation list')
  end
end
