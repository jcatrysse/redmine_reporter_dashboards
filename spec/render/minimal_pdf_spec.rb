# frozen_string_literal: true

require 'open3'

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/render/minimal_pdf'
require_relative '../../lib/redmine_reporter_dashboards/render/pdf_inspector'
require_relative '../../lib/redmine_reporter_dashboards/render/renderer'

# T-30 — the engine-free PDF writer.
#
# --- WHY MOST OF THIS FILE READS THE BYTES BACK WITH POPPLER ---
#
# §7b.3's objection to the base plugin is that the user got "a file named `.pdf` that is
# not a PDF". A spec that asserts the output starts with `%PDF-` would have passed against
# the first version of `assemble`, which poppler rejected with *"Missing 'endstream' or
# incorrect stream length"* — the object body ended `endstream` and `endobj` followed with
# no delimiter, so the file carried the token `endstreamendobj`. Reading the code could not
# find that. A reader could, on the first try.
#
# The poppler-backed examples SKIP NAMING THE PACKAGE when it is absent (CLAUDE.md §6's
# rule: an example about reasoning stubs the probe, one that genuinely needs it skips), and
# the structural examples below hold without it — including one that fails on exactly the
# defect above, so the regression is guarded even where poppler is not installed.
module MinimalPdfSpecSupport
  SUBJECT = RedmineReporterDashboards::Render::MinimalPdf
  INSPECTOR = RedmineReporterDashboards::Render::PdfInspector

  ROWS = [
    ['Correlation id', '3a8cd94c-1f2e-4a7b-9c11-88b0d2e4f001'],
    ['Template', 'Weekly status'],
    [nil, 'This document is not the report.']
  ].freeze
end

RSpec.describe RedmineReporterDashboards::Render::MinimalPdf do
  let(:bytes) do
    described_class.build(title: 'Report could not be generated',
                          rows: MinimalPdfSpecSupport::ROWS)
  end

  describe 'the bytes it produces' do
    it 'starts with the PDF magic, which is the first half of INV-5s post-condition' do
      expect(bytes[0, 5]).to eq('%PDF-')
    end

    it 'ends with the trailer marker, which is the other half' do
      expect(bytes).to include('%%EOF')
    end

    # `Renderer` rewrites any adapter output under this size as `Failure(:output_empty)`.
    # These bytes never travel through `Renderer` — but a writer whose output its own
    # project's guard would reject is not one to hand anybody, so the bound is asserted
    # against the CONSTANT rather than against a number typed here.
    it 'is larger than the minimum this project accepts from any engine' do
      expect(bytes.bytesize)
        .to be > RedmineReporterDashboards::Render::Renderer::MIN_PDF_BYTES
    end

    it 'is binary, so a caller can write it without an encoding conversion' do
      expect(bytes.encoding).to eq(Encoding::ASCII_8BIT)
    end

    # THE REGRESSION GUARD FOR THE DEFECT POPPLER FOUND, and it holds with no poppler.
    # `endstream` immediately followed by `endobj` is one token to a PDF lexer.
    it 'never runs endstream into endobj, which is one token to a lexer' do
      expect(bytes).not_to include('endstreamendobj')
    end

    # Every xref entry is exactly twenty bytes — ten of offset, a space, five of
    # generation, a space, the type, and a two-byte end of line. A reader that finds
    # nineteen reports a damaged file.
    it 'writes twenty-byte xref entries' do
      table = bytes[/xref\r?\n0 \d+\r?\n(.*?)trailer/m, 1]
      expect(table.bytesize % 20).to eq(0)
    end

    # And the offsets have to be TRUE, not merely well-formed. This is the one structural
    # property a malformed writer gets wrong silently: a reader seeking to a wrong offset
    # finds no `N 0 obj` there and reports a damaged file.
    it 'writes offsets that actually land on their object headers' do
      table = bytes[/xref\r?\n0 \d+\r?\n(.*?)trailer/m, 1]
      offsets = table.scan(/^(\d{10}) 00000 n/).flatten.map(&:to_i)

      expect(offsets).not_to be_empty
      offsets.each_with_index do |offset, index|
        expect(bytes[offset, 32]).to start_with("#{index + 1} 0 obj")
      end
    end

    it 'points startxref at the xref table itself' do
      start = bytes[/startxref\s+(\d+)/, 1].to_i
      expect(bytes[start, 4]).to eq('xref')
    end
  end

  describe 'reading the document back with poppler' do
    before do
      unless MinimalPdfSpecSupport::INSPECTOR.available?
        skip 'poppler-utils is not installed (apt-get install -y poppler-utils)'
      end
    end

    it 'is one page' do
      expect(MinimalPdfSpecSupport::INSPECTOR.page_count(bytes)).to eq(1)
    end

    it 'is A4, which is the size the page box declares' do
      width, height = MinimalPdfSpecSupport::INSPECTOR.page_size_pt(bytes)

      expect(width.round).to eq(described_class::PAGE_WIDTH)
      expect(height.round).to eq(described_class::PAGE_HEIGHT)
    end

    it 'carries the title, the labels and the values as extractable text' do
      text = MinimalPdfSpecSupport::INSPECTOR.text(bytes)

      expect(text).to include('Report could not be generated')
      expect(text).to include('3a8cd94c-1f2e-4a7b-9c11-88b0d2e4f001')
      expect(text).to include('This document is not the report.')
    end

    # THE CHECK THAT WOULD HAVE FAILED BEFORE THE `endobj` FIX. pdftotext extracts the
    # text either way -- it recovers -- but it writes its complaint to stderr, and a
    # document a reader has to recover from is not one to send anybody.
    it 'is read without a single syntax complaint' do
      err = MinimalPdfSpecSupport::INSPECTOR.with_document(bytes) do |path, _dir|
        _out, stderr, _status = Open3.capture3('pdftotext', path, '-')
        stderr.to_s
      end

      expect(err).to eq('')
    end
  end

  describe 'text that cannot be drawn' do
    it 'answers false for a string outside the base-14 encoding' do
      expect(described_class.encodable?("Отчёт")).to be(false)
    end

    it 'answers true for Latin-1, which the encoding does cover' do
      expect(described_class.encodable?("café über")).to be(true)
    end

    # The accented characters have to SURVIVE, not merely be accepted. A writer that
    # answered `encodable?` true and then drew mojibake would pass the example above.
    it 'draws Latin-1 text as itself rather than as mojibake' do
      out = described_class.build(title: "Résumé", rows: [['a', "café"]])

      # 0xE9 is WinAnsi's e-acute, which is what the font was told to expect.
      expect(out).to include([0xE9].pack('C'))
    end
  end

  describe 'characters that would break the file' do
    # `(`, `)` and `\` end or escape a PDF literal string. A template name is
    # author-controlled, so an unescaped one is not only a malformed document: it is a way
    # to close the string and write page operators.
    it 'escapes the three characters that end a PDF string' do
      out = described_class.build(title: 'a', rows: [['x', 'a(b)c\\d']])

      expect(out).to include('a\\(b\\)c\\\\d')
    end

    it 'stays readable with a payload that tries to close the string and draw' do
      skip 'poppler-utils is not installed' unless MinimalPdfSpecSupport::INSPECTOR.available?

      payload = ') Tj 1 0 0 1 100 100 Tm (INJECTED'
      out = described_class.build(title: 'a', rows: [['x', payload]])
      text = MinimalPdfSpecSupport::INSPECTOR.text(out)

      # The payload appears as TEXT, and the operators it tried to smuggle appear with
      # it rather than having been executed.
      expect(text).to include('INJECTED')
      expect(text).to include(') Tj')
    end
  end

  # FOUND BY DRIVING IT, NOT BY READING IT. A 400-word value produced 66 lines whose
  # lowest sat at y = -271 — off the paper — while `pdfinfo` reported one A4 page and
  # `pdftotext` extracted the visible half without complaint. What falls off is the END of
  # the document, which is where the sentence saying "this is not the report" lives.
  describe 'content that would run off the page' do
    let(:long) { 'word ' * 400 }

    let(:bytes) do
      described_class.build(title: 'Report could not be generated',
                            rows: [['Template', long],
                                   ['Correlation id', 'x' * 300],
                                   [nil, 'THE LAST SENTENCE']])
    end

    # The assertion is on the COORDINATES rather than on the extracted text, because
    # pdftotext happily reports text that is off the paper — which is why nothing caught
    # this until the numbers were read.
    it 'draws nothing below the bottom margin' do
      ys = bytes.scan(/1 0 0 1 \d+ (-?\d+) Tm/).flatten.map(&:to_i)

      expect(ys).not_to be_empty
      expect(ys.min).to be >= described_class::MARGIN
    end

    it 'draws nothing above the top of the page either' do
      ys = bytes.scan(/1 0 0 1 \d+ (-?\d+) Tm/).flatten.map(&:to_i)

      expect(ys.max).to be <= described_class::PAGE_HEIGHT - described_class::MARGIN
    end

    # THE ROW THAT MATTERS MOST IS THE LAST ONE. A bound that simply stopped drawing at the
    # bottom would pass both examples above and still lose the notice.
    it 'still draws the final row after an absurdly long earlier one' do
      skip 'poppler-utils is not installed' unless MinimalPdfSpecSupport::INSPECTOR.available?

      expect(MinimalPdfSpecSupport::INSPECTOR.text(bytes)).to include('THE LAST SENTENCE')
    end

    it 'says the value was cut rather than ending it silently' do
      skip 'poppler-utils is not installed' unless MinimalPdfSpecSupport::INSPECTOR.available?

      expect(MinimalPdfSpecSupport::INSPECTOR.text(bytes))
        .to include(described_class::TRUNCATION_MARKER)
    end

    it 'keeps exactly MAX_VALUE_LINES lines of a long value' do
      expect(described_class.clip(%w[a b c d e], described_class::MAX_VALUE_LINES, 200, 11)
                            .length)
        .to eq(described_class::MAX_VALUE_LINES)
    end

    it 'leaves a value that fits completely alone, marker included' do
      expect(described_class.clip(%w[a b], described_class::MAX_VALUE_LINES, 200, 11))
        .to eq(%w[a b])
    end

    # The marker used to be APPENDED, which made the last line six characters wider than
    # the column it had just been wrapped to fit.
    # THE LAST KEPT LINE HAS TO BE A FULL ONE, or the example proves nothing: appending
    # " [...]" to a short line fits anyway, which is how the first version of this passed
    # under mutation. The lines here come out of `wrap` itself, so each is as wide as the
    # column allows — which is the case that actually occurs.
    it 'fits the truncation marker into the column rather than past it' do
      lines = described_class.wrap('x' * 400, 120, 11)
      expect(lines.length).to be > 2

      clipped = described_class.clip(lines, 2, 120, 11)

      expect(clipped.last).to end_with(described_class::TRUNCATION_MARKER)
      expect(described_class.advance(clipped.last, 11)).to be <= 120
    end

    # A DROPPED ROW SAYS SO. The bound used to `break` in silence while its comment claimed
    # it refused a silent overflow.
    it 'marks the page when it had to drop rows entirely' do
      many = described_class.build(title: 't',
                                   rows: Array.new(60) { |i| ["label #{i}", "value #{i}"] })

      expect(many).to include(described_class::TRUNCATION_MARKER)
    end

    # The layout bound is the second one, and it exists for a caller that passes more ROWS
    # than the value cap can save it from.
    it 'refuses to overflow even when handed forty rows' do
      many = described_class.build(title: 't',
                                   rows: Array.new(40) { |i| ["label #{i}", "value #{i}"] })
      ys = many.scan(/1 0 0 1 \d+ (-?\d+) Tm/).flatten.map(&:to_i)

      expect(ys.min).to be >= described_class::MARGIN
    end
  end

  describe 'wrapping' do
    it 'breaks a long unbroken value rather than letting it run off the page' do
      lines = described_class.wrap('a' * 150, 200, 11)

      expect(lines.length).to be > 1
      expect(lines).to all(satisfy { |line| described_class.advance(line, 11) <= 200 })
    end

    it 'wraps on spaces when it can' do
      expect(described_class.wrap((['word'] * 20).join(' '), 120, 11))
        .to all(satisfy { |line| described_class.advance(line, 11) <= 120 })
    end

    it 'answers one empty line for empty input, so a nil value still draws a row' do
      expect(described_class.wrap('', 200, 11)).to eq([''])
    end

    # THE WIDTHS ARE THE FONT'S, AND THE FIRST VERSION GUESSED AN AVERAGE. Capitals are
    # ~0.68em against the 0.49em the character-count bound assumed, which is how an
    # ordinary 76-character name drew 5pt past the edge of the paper.
    it 'charges capitals what they actually cost, not an average' do
      expect(described_class.advance('W' * 10, 11)).to be > described_class.advance('i' * 10, 11)
    end

    it 'never under-measures a character outside the ASCII table' do
      expect(described_class.advance("\u00e9", 11))
        .to eq(described_class::WIDEST_GLYPH * 11 / 1000.0)
    end
  end
end
