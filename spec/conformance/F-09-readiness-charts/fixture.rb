# frozen_string_literal: true

# T-11's SECOND falsifying fixture: three charts that finish.
#
# Each takes 600 ms, and they run concurrently, so a page that waits for the signal is
# done a little after 600 ms and a page that waits out a fixed 3-second delay is not.
# The upper bound is 2 900 ms for that reason and no other — it is the largest number
# that still fails today's implementation.
#
# The lower bound matters just as much and is easier to overlook: a document returned
# in 50 ms did not wait for anything, which means the charts are missing from it. Both
# ends of this bound are falsifying, which is what makes it a measurement rather than
# a smoke test.
RedmineReporterDashboards::Conformance.fixture(
  'F-09-readiness-charts', 'three charts that finish, and the wait is theirs', dir: __dir__
) do |f|
  f.requires!(:javascript)
  f.request!(page_size: 'A4')
  f.readiness!(timeout_ms: 10_000, client_timeout_ms: 8_000)
  f.attempts!(2)

  f.check('it waited for the charts and no longer') do |v|
    v.expect_between(v.duration_ms, 550, 2_900, 'render duration (ms) for three 600 ms charts')
  end

  f.check('all three charts drew before the page was printed') do |v|
    %w[CHART-DONE-1 CHART-DONE-2 CHART-DONE-3].each do |marker|
      v.expect_includes(v.text, marker, 'chart output')
    end
  end

  f.check('the page reached zero pending without the watchdog') do |v|
    v.expect_includes(v.text, 'RD-STATE ready=true pending=0', 'readiness state')
    v.expect_excludes(v.text, 'client_watchdog', 'degradation list')
  end
end
