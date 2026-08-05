# frozen_string_literal: true

# Orientation and margins together, because they fail together: an engine that ignores
# `landscape` usually also ignores the margin block, and an engine that applies margins
# in the wrong unit (inches read as millimetres) produces a page that still looks
# plausible until someone measures it.
#
# THE FALSIFIER IS THE 17.8 mm SAMPLE. The request asks for 25 mm margins; the default
# is 12 mm. A pixel 6% into a 297 mm-wide page is 17.8 mm from the edge — inside a
# 25 mm margin and outside a 12 mm one. So an engine that silently kept its own default
# fails on that one sample and passes every other check in this file, which is the
# whole reason the sample is there.
RedmineReporterDashboards::Conformance.fixture(
  'F-03-orientation-margins', 'landscape A4 with 25 mm margins', dir: __dir__
) do |f|
  f.requires!(:landscape, :margins, :print_backgrounds)
  f.request!(page_size: 'A4', orientation: :landscape,
             margins_mm: { 'top' => 25, 'right' => 25, 'bottom' => 25, 'left' => 25 })

  f.check('landscape swaps the page axes') do |v|
    width, height = v.page_size_pt
    v.expect_within(width, 841.89, 3, 'landscape page width (pt)')
    v.expect_within(height, 595.28, 3, 'landscape page height (pt)')
    v.expect_true(width > height, 'landscape means the page is wider than it is tall')
  end

  # The content box is filled edge to edge with one flat colour, so "where does the
  # content start" is answerable by reading a pixel rather than by inferring it from
  # text positions, which move with the font.
  f.check('the content box starts inside the requested margin') do |v|
    v.expect_colour(v.pixel(x: 0.5, y: 0.5), [0, 170, 255], 'centre of the page')
    v.expect_colour(v.pixel(x: 0.02, y: 0.5), [255, 255, 255], 'inside the left margin (5.9 mm)')
    v.expect_colour(v.pixel(x: 0.06, y: 0.5), [255, 255, 255],
                    'at 17.8 mm — still margin at 25 mm, but content at the 12 mm default')
  end
end
