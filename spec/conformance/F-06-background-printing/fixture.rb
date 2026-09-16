# frozen_string_literal: true

# The default that costs colour if nobody overrides it.
#
# Chromium's `printToPDF` defaults `printBackground` to FALSE. Every badge, every
# progress bar, every alternating table row in the existing templates is a CSS
# background, so an adapter that passes the engine's default through produces a report
# that is *technically correct and visibly ruined* — and nothing fails, because the
# text is all still there. `DocumentRequest` therefore defaults it to TRUE, and this
# fixture is the check that the default survived the trip to the engine.
#
# Read as a pixel rather than as a flag: an adapter can set `printBackground: true` and
# still lose the colour to a stylesheet reset, a media query or a colour-adjust rule.
# The question is what came out, not what was sent.
RedmineReporterDashboards::Conformance.fixture(
  'F-06-background-printing', 'backgrounds print by default', dir: __dir__
) do |f|
  f.requires!(:print_backgrounds)
  f.request!(page_size: 'A4')

  f.check('the page background is drawn, not dropped') do |v|
    v.expect_colour(v.pixel(x: 0.5, y: 0.25), [0, 170, 255], 'page background')
  end

  # A badge is the case that actually matters: a small filled element on top of the
  # page background. An engine that paints the body background and drops element
  # backgrounds passes the check above and fails this one.
  f.check('an element background is drawn too') do |v|
    v.expect_colour(v.pixel(x: 0.5, y: 0.62), [204, 0, 0], 'badge background')
  end
end
