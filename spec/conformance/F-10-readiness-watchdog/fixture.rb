# frozen_string_literal: true

# T-11's THIRD falsifying fixture: one chart that begins and never ends.
#
# The IN-PAGE watchdog is what answers here, and it is deliberately set to fire before
# the engine's own timeout. That ordering is the whole design: if the page declares
# itself ready, the engine gets a clean signal AND a recorded reason; if only the
# engine times out, all anyone ever knows is that nothing answered. A page that can say
# why it gave up is worth more than one that was cut off — so the watchdog fires first,
# and the reason travels in the document.
#
# The engine timeout is 6 s and the page watchdog 2 s. An implementation that only had
# the engine timeout would come back at 6 s with nothing to say; this one comes back at
# about 2 s carrying `client_watchdog`.
RedmineReporterDashboards::Conformance.fixture(
  'F-10-readiness-watchdog', 'a chart that never ends is cut short by the page, not the engine',
  dir: __dir__
) do |f|
  f.requires!(:javascript)
  f.request!(page_size: 'A4')
  f.readiness!(timeout_ms: 6_000, client_timeout_ms: 2_000)
  f.attempts!(2)

  f.check('the page gave up before the engine would have') do |v|
    v.expect_between(v.duration_ms, 1_800, 4_500,
                     'render duration (ms): the 2 s page watchdog, not the 6 s engine timeout')
  end

  f.check('the document says why it gave up') do |v|
    v.expect_includes(v.flat_text, 'client_watchdog', 'the page-side degradation list')
    v.expect_includes(v.flat_text, 'RD-STATE ready=true pending=1',
                      'ready by watchdog, with the unfinished chart still counted')
  end

  # The document still contains everything that was not a chart. That is the trade the
  # whole readiness design is built on: a chart-less-but-otherwise-correct document
  # beats no document.
  f.check('the rest of the document survived') do |v|
    v.expect_includes(v.flat_text, 'READINESS-WATCHDOG', 'body text')
    v.expect_includes(v.flat_text, 'TABLE-ROW-7', 'content that had nothing to do with the chart')
  end
end
