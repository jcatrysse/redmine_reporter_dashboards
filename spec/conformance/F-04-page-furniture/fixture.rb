# frozen_string_literal: true

# The footer, and specifically the two tokens no template is allowed to spell itself.
#
# `PageFurniture` exists because `[page]`, `class="pageNumber"` and `@bottom-right` are
# three engine-native spellings of one idea, and a template that picks one is soldered
# to that engine — swap it and the footer becomes literal text or vanishes. So the
# author writes `{{page}} / {{pages}}`, and THIS fixture is what proves the compilation
# happened: page 1 of 3 says "1 / 3" and page 3 says "3 / 3".
#
# Note what is asserted on the LAST page as well as the first. An engine that renders
# the footer once, or that stamps the same number on every page, passes a one-page
# check and fails this one.
RedmineReporterDashboards::Conformance.fixture(
  'F-04-page-furniture', 'per-page footer with page numbers', dir: __dir__
) do |f|
  f.requires!(:footer, :page_furniture_tokens, :page_break_css)
  f.request!(
    page_size: 'A4',
    footer: RedmineReporterDashboards::Render::PageFurniture.new(
      left: 'FOOT-LEFT', right: '{{page}} / {{pages}}', font_size_pt: 9
    )
  )

  f.check('the document is three pages') do |v|
    v.expect_equal(v.page_count, 3, 'page count')
  end

  f.check('every page carries the footer, numbered for that page') do |v|
    v.expect_includes(v.text(page: 1), '1 / 3', 'page 1 footer')
    v.expect_includes(v.text(page: 2), '2 / 3', 'page 2 footer')
    v.expect_includes(v.text(page: 3), '3 / 3', 'page 3 footer')
  end

  f.check('the literal slot text survives beside the tokens') do |v|
    v.expect_includes(v.text(page: 2), 'FOOT-LEFT', 'page 2 left slot')
  end

  # If an engine's own footer syntax leaked through the compiler, the reader sees the
  # markup instead of the number. That is a silent defect on the engine that DOES
  # understand it and a loud one everywhere else, so it is asserted rather than assumed.
  f.check('no engine-native footer markup reaches the paper') do |v|
    %w[[page] [topage] pageNumber totalPages].each do |native|
      v.expect_excludes(v.text, native, 'rendered text')
    end
  end
end
