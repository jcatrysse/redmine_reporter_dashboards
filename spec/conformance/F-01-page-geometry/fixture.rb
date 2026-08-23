# frozen_string_literal: true

# The floor. Every engine has to put a known amount of paper under the document, and
# if this one is wrong nothing measured afterwards means anything — a margin is a
# fraction of a page, a break is a page boundary, a footer sits at a page edge.
#
# No `requires!`: page geometry is not a capability an engine may decline. An engine
# that cannot do this is not an engine this plugin can use, and the matrix should say
# so in red rather than in grey.
RedmineReporterDashboards::Conformance.fixture(
  'F-01-page-geometry', 'A4 portrait is 595 x 842 pt', dir: __dir__
) do |f|
  f.request!(page_size: 'A4', orientation: :portrait)

  f.check('the document is exactly one page') do |v|
    v.expect_equal(v.page_count, 1, 'page count')
  end

  # A4 is 210 x 297 mm = 595.28 x 841.89 pt. The tolerance absorbs an engine that
  # converts through inches at three decimal places, not one that chose Letter.
  # Letter is 612 x 792, which is 17 pt and 50 pt away — outside this by an order
  # of magnitude, which is the point of choosing 3.
  f.check('the page is A4 portrait, in points') do |v|
    width, height = v.page_size_pt
    v.expect_within(width, 595.28, 3, 'page width (pt)')
    v.expect_within(height, 841.89, 3, 'page height (pt)')
  end

  f.check('the document body reached the paper') do |v|
    v.expect_includes(v.text, 'GEOMETRY-MARKER', 'body text')
  end
end
