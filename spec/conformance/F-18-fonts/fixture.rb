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
    v.expect_includes(v.flat_text, 'FONT-LATIN quick brown fox', 'extracted text')
  end

  f.check('non-ASCII survives the trip in both directions') do |v|
    v.expect_includes(v.flat_text, 'FONT-CYRILLIC Проект', 'extracted Cyrillic')
    v.expect_includes(v.flat_text, 'FONT-GREEK Δοκιμή', 'extracted Greek')
  end

  f.check('punctuation a report actually uses is not mangled') do |v|
    v.expect_includes(v.flat_text, 'FONT-PUNCT — “quoted” … ±3 °C', 'extracted punctuation')
  end

  # --- ONE CHECK WAS REMOVED HERE, AND THIS IS WHAT IT WAS (finding E-5) ---
  #
  # `the text was actually inked`: a single pixel sampled from the middle of a large
  # glyph band, asserting it was dark. It exists because extraction alone CANNOT tell
  # drawn text from invisible text — a document with the right glyphs and a white fill
  # extracts perfectly and prints blank, and every check above it would pass.
  #
  # wkhtmltopdf returned white there. Whether that is missing glyphs, different line
  # metrics putting the band somewhere else, or genuinely unpainted text was never
  # established, because the engine cannot be run in the container this was developed
  # in. Removed by curator decision on 2026-08-06 rather than guessed at: the closed
  # capability vocabulary (`technical-spec.md` §5) has nothing to say about text
  # rendering, so the three-state rule had no capability to skip it on.
  #
  # **THE INVISIBLE-TEXT FAILURE MODE IS NOW UNCOVERED**, and that is the cost. It is
  # narrower than it sounds — the four extraction checks above still fail on missing
  # glyphs, wrong encodings and mangled punctuation, which is most of what goes wrong
  # with fonts — but a report drawn in white on white would pass this suite. The
  # preflight probe (T-14) is the right place for it to come back, because that runs
  # against ONE engine an operator has actually installed rather than against every
  # engine in the matrix.
end
