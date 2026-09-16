# frozen_string_literal: true

# T-38 — "drill-through links in the PDF are real links, asserted by extracting the link
# annotations from the produced PDF".
#
# --- WHAT "REAL LINK" MEANS, AND WHY THE ASSERTION HAD TO BE ANNOTATIONS ---
#
# §9b.4: "the drill-through `<a>` elements are real links — which also happens to make the
# PDF's charts clickable and its text selectable, the two things a rasterised chart loses."
# A `<a xlink:href>` that reached the paper as blue text and nothing else would satisfy
# every assertion about the document's TEXT and none about that claim, so the reading is
# `/URI` annotations: the object a PDF viewer turns into a click.
#
# --- THE HARNESS'S OWN BLIND SPOT IS HANDLED RATHER THAN IGNORED ---
#
# MEASURED 2026-08-13: `pdftohtml` attaches a link to the text under it, and `SvgRenderer`
# wraps `<rect>`, `<circle>` and `<path>` — never text — so poppler reports NOTHING for a
# chart's drill-through even when Chromium put the annotation in the file. `PdfProbe.links`
# therefore reads the bytes and uses poppler as its WITNESS: anything poppler found that the
# scan did not is reported as a HARNESS failure in the harness's own words. The plain link
# in this document is that witness, which is why it is here and asserted.
#
# --- IT BRIEFLY HAD A `requires!`, AND THE CAPABILITY BEHIND IT WAS RETRACTED ---
#
# Measured first on `apt install wkhtmltopdf` (Ubuntu 0.12.6, UNPATCHED Qt): only the plain
# HTML link became an annotation there, neither SVG anchor did, and a `:svg_link_annotations`
# capability was written so that engine would SKIP. Then measured on
# `wkhtmltopdf 0.12.6.1 (with patched qt)` — the release `.deb` CI installs and the only
# supported build — where **all three anchors** produce `/URI` annotations. No support
# difference, capability retracted, `requires!` gone. HANDOVER §1 carries the trap in capitals;
# `Render::Capabilities` carries the retraction and the rule it leaves behind.
RedmineReporterDashboards::Conformance.fixture(
  'F-23-drill-through-links',
  "a chart's drill-through anchors become real PDF link annotations",
  dir: __dir__
) do |f|
  f.request!(page_size: 'A4')

  # THE WITNESS FIRST. If this fails, the harness's reader is broken or the engine draws no
  # annotations at all, and either way the next check's answer means nothing — so it is
  # asserted separately and reads as its own sentence in the matrix.
  f.check('an ordinary link becomes an annotation, which proves the reader works') do |v|
    v.expect_includes(v.links.join(' '), 'https://drill.example/plain?filter=all',
                      'the plain HTML link, as an annotation')
  end

  f.check("every bar's drill-through URL is a real link annotation") do |v|
    links = v.links.join(' ')
    v.expect_includes(links, 'https://drill.example/bar?status=new', 'the first bar')
    v.expect_includes(links, 'https://drill.example/bar?status=closed', 'the second bar')
  end

  # The text half of the same claim, and it is not redundant: an engine that rasterised the
  # chart could still carry the annotations (they are page objects, not glyphs) while losing
  # every label. Both halves are what §9b.4 promises.
  f.check("the chart's text is on the page as text, not as pixels") do |v|
    v.expect_includes(v.flat_text, 'PLAIN-LINK', 'the document text')
  end
end
