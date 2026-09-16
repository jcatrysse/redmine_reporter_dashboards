# frozen_string_literal: true

# The default asset model, and the one R9 depends on: `:bundled`, where a document
# arrives at the engine already complete and the engine fetches NOTHING. An image is a
# `data:` URI, a font is a `data:` URI, the stylesheet is inline. That is what makes a
# correct render possible with name resolution denied, which is simultaneously the
# cheapest SSRF control in the design (technical-spec.md §5.1, §9).
#
# The check is a pixel and not a byte count: an engine can accept a `data:` URI, fail
# to decode it, and draw the broken-image glyph — same document size, no error, wrong
# report. The image is a flat 8x8 of one colour, scaled up, so "did it decode" and
# "did it decode CORRECTLY" are the same question.
RedmineReporterDashboards::Conformance.fixture(
  'F-14-asset-inline', 'a data: URI image resolves without any fetch', dir: __dir__
) do |f|
  f.requires!(:asset_inline, :print_backgrounds)
  f.request!(page_size: 'A4', margins_mm: { 'top' => 0, 'right' => 0, 'bottom' => 0, 'left' => 0 })

  f.check('the inline image is decoded and drawn') do |v|
    v.expect_colour(v.pixel(x: 0.5, y: 0.10), [0, 170, 255], 'the inlined PNG')
  end

  f.check('the document around it rendered') do |v|
    v.expect_includes(v.text, 'ASSET-INLINE-MARKER', 'body text')
  end
end
