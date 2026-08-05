# frozen_string_literal: true

# Flexbox, because it is the single CSS feature that separates the two adapters this
# plugin ships. wkhtmltopdf renders with a 2011 QtWebKit; a flex row there does not lay
# out side by side, it stacks — and a two-column report becomes a one-column report
# without any error anywhere.
#
# The falsifier is geometric, not textual. Two children, red then green, each half the
# row. Sample the row a quarter and three quarters across: laid out side by side that
# is red then green, and STACKED it is red then red. Text extraction cannot tell those
# apart, which is why this check reads pixels.
RedmineReporterDashboards::Conformance.fixture(
  'F-07-flexbox', 'a flex row lays out side by side', dir: __dir__
) do |f|
  f.requires!(:print_backgrounds)
  f.request!(page_size: 'A4', margins_mm: { 'top' => 0, 'right' => 0, 'bottom' => 0, 'left' => 0 })

  f.check('the two flex children sit beside each other, not above') do |v|
    v.expect_colour(v.pixel(x: 0.25, y: 0.10), [204, 0, 0], 'left flex child')
    v.expect_colour(v.pixel(x: 0.75, y: 0.10), [0, 122, 0], 'right flex child')
  end

  f.check('the row is one row high, so nothing wrapped below it') do |v|
    v.expect_colour(v.pixel(x: 0.25, y: 0.30), [255, 255, 255], 'below the flex row')
  end
end
