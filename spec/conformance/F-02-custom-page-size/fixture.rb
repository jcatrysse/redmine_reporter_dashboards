# frozen_string_literal: true

# A page size that is NOT the engine's built-in default. wkhtmltopdf and Chromium
# disagree about what "default" means (A4 vs Letter, depending on the build's locale),
# so a report that looks right on the developer's machine and wrong on the server is
# exactly this defect. Asking for the size explicitly is the fix; this fixture is what
# proves the ask arrives.
RedmineReporterDashboards::Conformance.fixture(
  'F-02-custom-page-size', 'Letter is honoured over the engine default', dir: __dir__
) do |f|
  f.requires!(:custom_page_size)
  f.request!(page_size: 'Letter', orientation: :portrait)

  f.check('the page is US Letter, not A4') do |v|
    width, height = v.page_size_pt
    v.expect_within(width, 612.0, 3, 'page width (pt)')
    v.expect_within(height, 792.0, 3, 'page height (pt)')
  end
end
