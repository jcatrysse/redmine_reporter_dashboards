# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'pdf_probe'
require 'tmpdir'

# T-38 — the link reader, tested WITHOUT an engine.
#
# --- WHY THIS FILE EXISTS ---
#
# It did not, and an independent review found a defect in five minutes that a corpus run
# could not have found in a year: `pdftohtml -xml` XML-escapes its attribute values, so a URL
# containing `&` came back as `…&amp;x=1` from poppler and `…&x=1` from the byte scan, and the
# cross-check reported a HARNESS FAILURE for a link it had read perfectly. F-23's three
# fixture URLs are single-parameter, so the corpus was green; a real Redmine drill-through URL
# (`/issues?set_filter=1&f[]=status_id&op[]==&v[status_id][]=1`) is `&`-dense and would have
# detonated the guard on the first realistic chart.
#
# The lesson is the one this repository keeps relearning: a reader whose only test is a green
# corpus is a reader nobody has watched fail. So the fixtures here are HAND-BUILT PDFs, small
# enough to read, with the annotation written by this file rather than by a browser — which is
# what makes it possible to ask what happens with a `&`, with no links at all, and with an
# annotation the text-based reader cannot see.
RSpec.describe RedmineReporterDashboards::Conformance::PdfProbe do
  before do
    missing = described_class.missing_tools
    skip "needs #{missing.join(', ')} on PATH (apt-get install -y poppler-utils)" if missing.any?
  end

  # A one-page PDF with one `/URI` annotation over the word `PLAIN-LINK`, written by hand.
  #
  # UNCOMPRESSED, and that is the point rather than laziness: the byte scan reads literal
  # `/URI (…)` strings, and both engines in the matrix write them that way. A fixture that
  # compressed its object streams would be testing a document neither engine produces.
  def pdf_with(url, text: 'PLAIN-LINK', annotation: true)
    annots = annotation ? ' /Annots [6 0 R]' : ''
    objects = []
    objects << "<< /Type /Catalog /Pages 2 0 R >>"
    objects << "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
    objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] " \
               "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R#{annots} >>"
    stream = "BT /F1 12 Tf 72 760 Td (#{text}) Tj ET"
    objects << "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
    objects << "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    if annotation
      objects << "<< /Type /Annot /Subtype /Link /Rect [70 755 200 775] /Border [0 0 0] " \
                 "/A << /S /URI /URI (#{url}) >> >>"
    end

    body = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |object, index|
      offset = body.bytesize
      body << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      offset
    end
    start = body.bytesize
    body << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
    offsets.each { |offset| body << format("%010d 00000 n \n", offset) }
    body << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\n" \
            "startxref\n#{start}\n%%EOF\n"
    body
  end

  def with_pdf(bytes)
    Dir.mktmpdir('rrd-link-probe') do |dir|
      path = File.join(dir, 'document.pdf')
      File.binwrite(path, bytes)
      yield path
    end
  end

  describe '.links' do
    it 'reads a plain URL out of the annotation' do
      with_pdf(pdf_with('https://drill.example/plain')) do |path|
        expect(described_class.links(path)).to eq(['https://drill.example/plain'])
      end
    end

    # THE DEFECT THIS FILE WAS WRITTEN FOR. Poppler answers `&amp;`, the scan answers `&`, and
    # without `CGI.unescapeHTML` the difference was reported as the harness's reader having
    # missed a link — naming the wrong culprit for a document that was completely fine.
    it 'agrees with poppler about a URL containing an ampersand' do
      url = 'https://drill.example/issues?set_filter=1&f[]=status_id&op[]==&v[]=1'

      with_pdf(pdf_with(url)) do |path|
        expect { described_class.links(path) }.not_to raise_error
        expect(described_class.links(path)).to eq([url])
      end
    end

    it 'agrees about the other XML entities too' do
      url = 'https://drill.example/q?a=<1>&b="2"'

      with_pdf(pdf_with(url)) do |path|
        expect(described_class.links(path)).to eq([url])
      end
    end

    it 'answers an empty list for a document with no links, rather than raising' do
      with_pdf(pdf_with('https://drill.example/x', annotation: false)) do |path|
        expect(described_class.links(path)).to eq([])
      end
    end

    # A LIMITATION, WRITTEN DOWN RATHER THAN DISCOVERED. The scan reads `/URI (…)` strings
    # anywhere in the file, so an annotation object that no page references is still counted —
    # and poppler, which walks the page tree, correctly reports nothing, so the cross-check
    # cannot catch it either (it only fires when poppler sees MORE). No engine in the matrix
    # writes an orphaned annotation, which is why this is acceptable; it is asserted so the
    # behaviour is a known property of the reader instead of a surprise in somebody's fixture.
    it 'counts an ORPHANED annotation object no page references, which poppler does not' do
      orphaned = pdf_with('https://drill.example/x').sub(' /Annots [6 0 R]', '')

      with_pdf(orphaned) do |path|
        expect(described_class.links(path)).to eq(['https://drill.example/x'])
      end
    end

    # THE CROSS-CHECK HAS TO BE ABLE TO FIRE, or it is a comment. The scan is stubbed blind
    # while poppler still sees the link — which is what a compressed annotation dictionary
    # would look like — and the message has to name the HARNESS rather than an engine.
    it 'raises a HARNESS failure, naming itself, when its own scan misses what poppler found' do
      inspector = RedmineReporterDashboards::Render::PdfInspector
      allow(inspector).to receive(:uri_annotations_at).and_return([])

      with_pdf(pdf_with('https://drill.example/plain')) do |path|
        expect { described_class.links(path) }
          .to raise_error(described_class::ProbeFailed, /HARNESS failure/)
      end
    end

    # And it must NOT fire the other way round: the scan seeing more than poppler is the
    # NORMAL case for a chart, because `SvgRenderer` wraps a `<rect>` and poppler attaches a
    # link only to text. A guard that failed on that would fail on every chart.
    it 'does not raise when the scan sees an annotation poppler cannot' do
      inspector = RedmineReporterDashboards::Render::PdfInspector
      allow(inspector).to receive(:text_links_at).and_return([])

      with_pdf(pdf_with('https://drill.example/plain')) do |path|
        expect(described_class.links(path)).to eq(['https://drill.example/plain'])
      end
    end
  end

  describe 'the tool policy' do
    # M6: the link reader is in the harness's OWN tool list, so the one up-front check covers
    # it and `.links` never raises a second exception class for the same condition.
    it 'counts pdftohtml among the tools the harness requires' do
      allow(RedmineReporterDashboards::Render::PdfInspector)
        .to receive(:missing_link_tools).and_return(['pdftohtml'])

      expect(described_class.missing_tools).to include('pdftohtml')
      expect { described_class.require_tools! }
        .to raise_error(described_class::ToolMissing, /pdftohtml/)
    end

    # …and NOT among the inspector's, because `Render::Preflight` shares the inspector and
    # runs on an operator's install, where a missing pdftohtml must not turn a working
    # diagnostic into an unavailable one.
    it 'leaves the inspector\'s own tool list alone, so a preflight still runs without it' do
      expect(RedmineReporterDashboards::Render::PdfInspector::TOOLS)
        .not_to include('pdftohtml')
    end
  end
end
