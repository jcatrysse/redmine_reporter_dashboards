# frozen_string_literal: true

# A two-column layout, drawn with the one mechanism EVERY engine has.
#
# --- WHAT THIS FIXTURE USED TO BE, AND WHAT WAS GIVEN UP (finding E-5) ---
#
# It was `F-07-flexbox`, and it asserted a `display:flex` row laid out side by side.
# That is the single clearest demonstration of why `:chromium_cdp` is the reference
# engine: wkhtmltopdf's 2011 WebKit STACKS a flex row, so a two-column report silently
# becomes a one-column report on the compatibility engine.
#
# It was weakened by curator decision on 2026-08-06, and the reason is worth keeping
# because it is a real limit of the design rather than a preference. The three-state
# rule can only skip a fixture on a capability the engine DECLARES, and
# `technical-spec.md` §5 defines that vocabulary as CLOSED — it has no `:flexbox`. So
# the difference was real, correct for that engine, and unsayable. The options were to
# open the vocabulary (a spec change), to leave wkhtmltopdf unpromotable forever, or to
# weaken this. The third was chosen.
#
# **NOTHING IN THE CORPUS COVERS FLEXBOX NOW.** That is the cost, stated here rather
# than discovered later: an engine that cannot lay out a flex row passes this suite. If
# the capability vocabulary is ever opened, the flexbox version of this fixture belongs
# back in it — `git log` has it, and the E-5 entry has the reasoning.
#
# What is still asserted, and is worth asserting: a two-column layout reaches the paper
# AS TWO COLUMNS. Tables are how every engine in the matrix does that, including the
# 2011 one, so this is a floor rather than a frontier — and a floor that a broken
# layout engine still falls through.
RedmineReporterDashboards::Conformance.fixture(
  'F-07-column-layout', 'a two-column layout stays side by side', dir: __dir__
) do |f|
  f.requires!(:print_backgrounds)
  f.request!(page_size: 'A4', margins_mm: { 'top' => 0, 'right' => 0, 'bottom' => 0, 'left' => 0 })

  # Geometric, not textual: extraction cannot tell "side by side" from "stacked",
  # because both contain the same words in the same order.
  f.check('the two columns sit beside each other, not above') do |v|
    v.expect_colour(v.pixel(x: 0.25, y: 0.10), [204, 0, 0], 'left column')
    v.expect_colour(v.pixel(x: 0.75, y: 0.10), [0, 122, 0], 'right column')
  end

  f.check('the row is one row high, so nothing wrapped below it') do |v|
    v.expect_colour(v.pixel(x: 0.25, y: 0.30), [255, 255, 255], 'below the row')
  end
end
