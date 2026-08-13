# frozen_string_literal: true

# T-38 — "`break-inside: avoid` holds for cards and chart blocks".
#
# --- THE DEFECT IT EXISTS TO CATCH ---
#
# A card whose chart lands at the foot of one page and whose caption lands at the top of the
# next is worse than either half alone: the reader is shown a number with no label, then a
# label with no number, and nothing on either page says they belong together. Same class as
# F-21's unnamed columns, one block down.
#
# --- WHY FOURTEEN BLOCKS AND NOT ONE ---
#
# The first version of this fixture put ONE card behind one tall spacer, tuned so the card
# would straddle a boundary, and asserted the page it moved to. That worked on Chromium and
# was meaningless on wkhtmltopdf, which drew the same document in 4 pages rather than 5 and
# fitted the card comfortably inside page 1 — so the assertion passed while testing nothing,
# and the page NUMBER in it was a layout accident of one engine.
#
# Fourteen blocks behind seven drifting spacer heights cross a boundary on every engine
# instead. The assertion is then engine-independent and stronger: EVERY block's two halves
# are on the SAME page, whichever page that is.
#
# --- MEASURED IN BOTH DIRECTIONS, which is what makes it a check rather than a hope ------
#
# 2026-08-13, this document with the break rules present and then removed:
#
#   rules present   wkhtmltopdf (patched qt) 3 pages, 0 split. Distro build 4 pages, 0 split.
#                   Chromium 5 pages, 0 split.
#   rules removed   wkhtmltopdf (patched qt) 3 pages, 2 blocks split (5 and 10). Distro build
#                   4 pages, 1 split (block 12). Chromium 5 pages, 3 split (6, 9 and 12).
#
# So this fixture goes red on every engine if the stylesheet stops asking, which is the
# property the first version did not have. **Both wkhtmltopdf builds were measured, and that
# is not thoroughness for its own sake**: F-21 and F-23 each spent a round declaring a
# capability that existed only on the unpatched distro build (HANDOVER §1's trap, and
# `Render::Capabilities` carries the retraction). A measurement on one binary is a measurement
# of one accident.
#
# --- BOTH SPELLINGS, ONE FIXTURE ---
#
# The stylesheet writes `page-break-inside: avoid` AND `break-inside: avoid` on every block,
# because wkhtmltopdf's 2011 WebKit knows only the legacy one — and the measurement above is
# what proves it needs it. This fixture cannot tell the two spellings apart, nor should it:
# what a report needs is the block held together on whichever engine drew it, and
# `spec/report_stylesheet_spec.rb` asserts the presence of both per selector.
#
# NO `requires!`. Nothing in the closed capability vocabulary describes keeping a block whole
# — `:page_break_css` is about explicit breaks rather than avoided ones — and both spellings
# are honoured by all three engines in the matrix, measured on both wkhtmltopdf builds. A red
# cell here is a real failure.
RedmineReporterDashboards::Conformance.fixture(
  'F-22-unbroken-blocks',
  'the shipped stylesheet never lets a card or a chart block straddle a page break',
  dir: __dir__
) do |f|
  f.request!(page_size: 'A4', timeout_ms: 60_000)

  block_count = 14

  # Odd blocks are `.rrd-card`, even ones are `<figure>` — the two selectors the stylesheet
  # names for this, exercised in one document rather than in two fixtures, because the
  # question ("did it straddle") and the arithmetic are identical for both.
  f.expand! do |html|
    blocks = (1..block_count).map do |i|
      spacer = "s#{(i % 7) + 1}"
      tag = i.odd? ? 'div' : 'figure'
      css = i.odd? ? ' class="rrd-card"' : ''
      label = format('BLOCK-%02d', i)
      <<~BLOCK
        <div class="#{spacer}">SPACER-#{format('%02d', i)}</div>
        <#{tag}#{css}>
          <p>#{label}-TOP</p>
          <svg class="rrd-chart" xmlns="http://www.w3.org/2000/svg" width="200" height="70"
               role="img" aria-labelledby="t#{i} d#{i}">
            <title id="t#{i}">bar chart</title><desc id="d#{i}">one bar</desc>
            <rect x="0" y="0" width="200" height="70" fill="#FFFFFF"/>
            <rect x="10" y="10" width="40" height="50" fill="#0072B2" stroke="#00528C"/>
          </svg>
          <p>#{label}-BOTTOM</p>
        </#{tag}>
      BLOCK
    end
    html.sub('<!--BLOCKS-->', blocks.join("\n"))
  end

  # Which page each marker landed on, read once per page rather than once per marker: 14
  # blocks x 2 markers x 5 pages would be 140 `pdftotext` calls for an answer that needs 5.
  pages_by_marker = lambda do |v|
    (1..v.page_count).each_with_object({}) do |page, out|
      v.flat_text(page: page).scan(/BLOCK-\d\d-(?:TOP|BOTTOM)/).uniq.each do |marker|
        (out[marker] ||= []) << page
      end
    end
  end

  f.check('the document really does cross several page boundaries') do |v|
    v.expect_between(v.page_count, 3, 12, 'page count')
  end

  f.check('no block has its two halves on different pages') do |v|
    seen = pages_by_marker.call(v)

    (1..block_count).each do |i|
      label = format('BLOCK-%02d', i)
      top = seen["#{label}-TOP"]
      bottom = seen["#{label}-BOTTOM"]

      v.expect_true(top && bottom,
                    "#{label} is missing from the document altogether (top=#{top.inspect}, " \
                    "bottom=#{bottom.inspect}) — a block that was DROPPED would otherwise " \
                    'pass the same-page test')
      v.expect_equal(bottom, top,
                     "#{label}: the pages its two halves landed on. A block split across a " \
                     'boundary is a chart on one page and its caption on the next')
    end
  end

  # THE DISCRIMINATOR, and without it the check above passes on a one-page document. The
  # blocks have to be SPREAD over the pages for "none of them straddled" to be a finding
  # rather than an arithmetic accident.
  f.check('the blocks are spread across the pages, so nothing straddled by luck') do |v|
    pages = pages_by_marker.call(v).values.flatten.uniq

    v.expect_true(pages.length >= 3,
                  "the blocks landed on #{pages.length} page(s) (#{pages.sort.inspect}); at " \
                  'least 3 is what makes "no block straddled a boundary" a real answer')
  end
end
