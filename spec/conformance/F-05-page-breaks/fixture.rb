# frozen_string_literal: true

# Explicit breaks, and the thing that actually goes wrong with them: an engine honours
# `page-break-before` but not `break-before`, or the reverse, and a report that was four
# pages in review becomes one long page in production. Both spellings are in the
# document for that reason — a template must not have to know which decade its engine
# is from.
#
# The assertion is not just the page count. Each marker is asserted to be on ITS OWN
# page: a document where all four markers land on page 1 and three blank pages follow
# also has a page count of four.
RedmineReporterDashboards::Conformance.fixture(
  'F-05-page-breaks', 'three explicit breaks make four pages', dir: __dir__
) do |f|
  f.requires!(:page_break_css)
  f.request!(page_size: 'A4')

  f.check('three breaks produce exactly four pages') do |v|
    v.expect_equal(v.page_count, 4, 'page count')
  end

  f.check('each section is on the page the break put it on') do |v|
    %w[BREAK-ALPHA BREAK-BETA BREAK-GAMMA BREAK-DELTA].each_with_index do |marker, i|
      page = i + 1
      v.expect_includes(v.text(page: page), marker, "page #{page}")
      other = v.text(page: page == 1 ? 2 : 1)
      v.expect_excludes(other, marker, "#{marker} must not also appear on another page")
    end
  end
end
