# frozen_string_literal: true

# Text has to survive two journeys: onto the page, and back off it.
#
# Onto the page is the obvious one — an engine with no fonts draws tofu. Back off it is
# the one that gets forgotten, and it is what a reader actually does: select, copy,
# search, and (for accessibility) have read aloud. That round trip needs a `/ToUnicode`
# map in the PDF, which an engine can omit while producing a document that LOOKS
# perfect. Every check here is an extraction, so a document that is beautiful and
# unreadable to a machine fails.
#
# Deliberately NOT tested: CJK. Whether a container ships Noto CJK is a question about
# the image, not about the engine, and a red cell here would be blaming the wrong
# component. Cyrillic and Greek are in the metric-compatible core fonts that any Linux
# image with fonts at all has, so they discriminate between "this engine loses non-ASCII"
# and "this image has no fonts" — which are different bugs with different owners.
RedmineReporterDashboards::Conformance.fixture(
  'F-18-fonts', 'text goes onto the page and comes back off it', dir: __dir__
) do |f|
  f.request!(page_size: 'A4')

  f.check('plain Latin text round-trips exactly') do |v|
    v.expect_includes(v.text, 'FONT-LATIN quick brown fox', 'extracted text')
  end

  f.check('non-ASCII survives the trip in both directions') do |v|
    v.expect_includes(v.text, 'FONT-CYRILLIC Проект', 'extracted Cyrillic')
    v.expect_includes(v.text, 'FONT-GREEK Δοκιμή', 'extracted Greek')
  end

  f.check('punctuation a report actually uses is not mangled') do |v|
    v.expect_includes(v.text, 'FONT-PUNCT — “quoted” … ±3 °C', 'extracted punctuation')
  end

  # Extraction alone cannot tell drawn text from invisible text: a document with the
  # glyphs and a white fill extracts perfectly and prints blank. One pixel closes that.
  f.check('the text was actually inked') do |v|
    dark = v.pixel(x: 0.5, y: 0.5, dpi: 72)
    v.expect_true(dark.sum < 600, "the text band is blank (rgb#{dark.inspect})")
  end
end
