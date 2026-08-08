# frozen_string_literal: true

module RedmineReporterDashboards
  module Render
    # T-30 — a PDF writer with no engine behind it.
    #
    # --- WHY THIS EXISTS AT ALL, WHEN THE PLUGIN ALREADY HAS TWO PDF ENGINES ---
    #
    # FR-59's failure document is wanted precisely when the render path did not work.
    # Most of the codes that can reach it are engine codes — `engine_crashed`,
    # `engine_unavailable`, `readiness_timeout`, `output_not_pdf` — so drawing the failure
    # document through the engine that just produced one of them is a coin toss, and the
    # side it lands on when it fails is *no document at all*, which is the outcome the
    # feature exists to replace.
    #
    # So this writes the bytes itself. It has no process, no socket, no temporary file and
    # no asset, and it is exercised by the DB-less suite rather than by a browser.
    # Everything it can draw is in `build`'s signature: a title and a list of label/value
    # pairs. It is deliberately not a general PDF library and must not grow into one — the
    # moment it needs an image or a table, the answer is an engine.
    #
    # --- WHAT "REAL, VALID PDF" MEANS HERE, AND HOW IT IS CHECKED ---
    #
    # §7b.3's objection to the base plugin is not that the user got information, it is that
    # they got "a file named `.pdf` that is not a PDF". So the output is verified the same
    # way every other document in this project is: `Render::PdfInspector` reads it back
    # with poppler in the specs, and it satisfies `Renderer`'s own post-conditions
    # (`%PDF-` … `%%EOF`, over `MIN_PDF_BYTES`) even though it does not travel through
    # `Renderer` — a writer that produced bytes its own project's guard would reject is
    # not one to hand anybody.
    #
    # --- ENCODING: WinAnsi, AND THE CALLER IS TOLD RATHER THAN THE TEXT MANGLED ---
    #
    # The base-14 fonts a PDF reader is required to have carry a single-byte encoding, so
    # this can draw Windows-1252 and nothing else. Embedding a Unicode font would add a
    # megabyte of vendored bytes to a document whose whole job is to be producible when
    # things are broken. Rather than silently replacing what it cannot draw with `?` — a
    # Russian operator receiving a page of question marks is the "plausible-looking wrong
    # answer" this repository keeps deleting — `encodable?` is public and the caller
    # decides. `Reporting::FailureDocument` uses it to fall back to the English string for
    # that one line, and records that it did.
    #
    # --- EVERY BUFFER IN HERE IS BINARY, AND THAT IS NOT A DETAIL ---
    #
    # WinAnsi text carries bytes over 127. Interpolating such a string into a UTF-8 source
    # literal raises `Encoding::CompatibilityError` from a line that does no reading —
    # HANDOVER §1's second encoding symptom, which cost a session once already. So nothing
    # here interpolates an encoded value: an ASCII literal is APPENDED to a binary buffer,
    # which is always defined, and the encoded bytes are appended after it.
    module MinimalPdf
      # A4 in PostScript points, which is the unit a PDF page box is in.
      PAGE_WIDTH = 595
      PAGE_HEIGHT = 842

      MARGIN = 56           # ~20mm
      TITLE_SIZE = 17
      BODY_SIZE = 11
      LINE_HEIGHT = 16
      LABEL_WIDTH = 150     # points reserved for the label column

      # Helvetica at 11pt averages a little under 5.5pt per character. Wrapping is by
      # character count rather than by real font metrics on purpose: the alternative is
      # shipping the AFM widths of two fonts to lay out a page nobody reads twice, and a
      # wrap that is a few characters early costs nothing here.
      WRAP_COLUMNS = 62
      PARAGRAPH_COLUMNS = 86

      # --- WHY OVERFLOW IS BOUNDED TWICE ---
      #
      # Found by driving this with a 400-word value: 66 lines were emitted and the lowest
      # sat at **y = -271**, i.e. off the paper entirely. `pdfinfo` still said "Pages: 1"
      # and `pdftotext` still extracted the visible half, so nothing complained — and what
      # falls off is the END of the document, which is where the notice explaining that
      # this is not the report lives. A page that silently loses its own explanation is the
      # quiet wrong answer this project keeps deleting.
      #
      # Bounded per VALUE first, because that removes the failure by construction rather
      # than by arithmetic: with every value capped the row set cannot exceed the page, and
      # a reader gets a truncation marker instead of a missing sentence. `room?` is then a
      # second bound on the LAYOUT, so a future caller passing forty rows is refused a
      # silent overflow rather than trusted to have read this comment.
      MAX_VALUE_LINES = 3
      MAX_PARAGRAPH_LINES = 5

      # `…` is not in WinAnsi as a single reliable glyph across readers; three dots is.
      TRUNCATION_MARKER = '[...]'

      # The encoding both fonts declare. Named once so the declaration in the font object
      # and the conversion in `encode` cannot drift apart.
      ENCODING = 'Windows-1252'

      BINARY = ::Encoding::ASCII_8BIT

      module_function

      # Whether this writer can draw every character of `text`. Public because the caller
      # has to be able to ask BEFORE it commits to a string — see the encoding note above.
      def encodable?(text)
        encode(text.to_s)
        true
      rescue ::Encoding::UndefinedConversionError, ::Encoding::InvalidByteSequenceError
        false
      end

      # title  the heading, drawn bold
      # rows   an ordered Array of [label, value] pairs. A nil or empty label draws the
      #        value across the full width, which is how the summary paragraph is set.
      def build(title:, rows:)
        content = content_stream(title, rows)

        objects = []
        objects << binary('<</Type/Catalog/Pages 2 0 R>>')
        objects << binary('<</Type/Pages/Kids[3 0 R]/Count 1>>')
        objects << binary("<</Type/Page/Parent 2 0 R/MediaBox[0 0 #{PAGE_WIDTH} #{PAGE_HEIGHT}]" \
                          '/Resources<</Font<</F1 5 0 R/F2 6 0 R>>>>/Contents 4 0 R>>')
        objects << stream_object(content)
        objects << binary('<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>')
        objects << binary('<</Type/Font/Subtype/Type1/BaseFont/Helvetica-Bold' \
                          '/Encoding/WinAnsiEncoding>>')
        objects << info_object(title)

        assemble(objects)
      end

      # --- the document ------------------------------------------------------------------

      # `Tf` selects a font, `Tm` positions, `Tj` draws. Every line is absolutely
      # positioned inside a single `BT`/`ET` block, because a text object relying on
      # leading would have to track its own cursor across the wrap loop and get it wrong
      # once.
      def content_stream(title, rows)
        out = binary('BT')
        y = PAGE_HEIGHT - MARGIN - TITLE_SIZE

        out << "\n/F2 #{TITLE_SIZE} Tf"
        out << "\n" << text_op(MARGIN, y, title)

        y -= LINE_HEIGHT * 2

        rows.each do |label, value|
          label = label.to_s
          break unless room?(y)

          if label.empty?
            clip(wrap(value.to_s, PARAGRAPH_COLUMNS), MAX_PARAGRAPH_LINES).each do |line|
              break unless room?(y)

              out << "\n/F1 #{BODY_SIZE} Tf"
              out << "\n" << text_op(MARGIN, y, line)
              y -= LINE_HEIGHT
            end
          else
            out << "\n/F2 #{BODY_SIZE} Tf"
            out << "\n" << text_op(MARGIN, y, label)

            clip(wrap(value.to_s, WRAP_COLUMNS), MAX_VALUE_LINES).each do |line|
              break unless room?(y)

              out << "\n/F1 #{BODY_SIZE} Tf"
              out << "\n" << text_op(MARGIN + LABEL_WIDTH, y, line)
              y -= LINE_HEIGHT
            end
          end

          y -= LINE_HEIGHT / 2
        end

        out << "\nET"
        out
      end

      # THE BOUND IS ON THE COORDINATE, NOT ON A LINE COUNT, and the first version was a
      # line count. It failed the forty-row example at **y = -199**: each row costs a line
      # AND a half-line of spacing, so "42 lines fit" was true of the lines and false of
      # the page. Asking the cursor removes the arithmetic and cannot drift when the
      # spacing changes.
      def room?(y)
        y >= MARGIN
      end

      # Keeps at most `limit` lines and says so on the last one. The marker is APPENDED
      # rather than replacing the line, because "the value continues" and "the value ended
      # here" are different facts and a reader cannot tell them apart otherwise.
      def clip(lines, limit)
        return lines if lines.length <= limit

        kept = lines[0, limit]
        kept[-1] = "#{kept[-1]} #{TRUNCATION_MARKER}"
        kept
      end

      def text_op(x, y, text)
        out = binary("1 0 0 1 #{x} #{y} Tm (")
        out << escape(text)
        out << ') Tj'
        out
      end

      # A word longer than the column (a correlation id has no spaces in it, and neither
      # does a URL) is HARD-BROKEN rather than allowed to run off the page. A value that
      # silently leaves the paper is the same class of defect as one that is silently
      # truncated.
      def wrap(text, columns)
        words = text.to_s.split(/\s+/).reject(&:empty?)
        return [''] if words.empty?

        lines = []
        current = +''

        words.each do |word|
          while word.length > columns
            lines << current unless current.empty?
            current = +''
            lines << word[0, columns]
            word = word[columns..]
          end

          candidate = current.empty? ? word : "#{current} #{word}"
          if candidate.length > columns
            lines << current
            current = +word
          else
            current = candidate
          end
        end

        lines << current unless current.empty?
        lines
      end

      # --- bytes -------------------------------------------------------------------------

      def stream_object(content)
        out = binary("<</Length #{content.bytesize}>>\nstream\n")
        out << content
        out << "\nendstream"
        out
      end

      def info_object(title)
        out = binary('<</Title(')
        out << escape(title)
        out << ')/Producer(redmine_reporter_dashboards)>>'
        out
      end

      # The xref table is the part that makes this a PDF rather than a text file that
      # starts with `%PDF-`, and every entry is EXACTLY twenty bytes: a ten-digit offset,
      # a space, a five-digit generation, a space, the type, and a two-byte end of line.
      # A reader that finds nineteen reports a damaged file, which is the failure mode
      # this whole class exists to avoid.
      def assemble(objects)
        out = binary("%PDF-1.4\n")
        # A binary comment right after the header is what tells a transfer agent this is
        # not a text file. Four bytes over 127, as the specification suggests.
        out << [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A].pack('C*')

        offsets = []
        objects.each_with_index do |body, index|
          offsets << out.bytesize
          out << "#{index + 1} 0 obj"
          out << body
          # THE NEWLINE BEFORE `endobj` IS LOAD-BEARING AND POPPLER IS WHAT FOUND IT.
          # The stream object's body ends `…endstream`, so without a delimiter the file
          # carries the token `endstreamendobj` — and pdftotext reported *"Missing
          # 'endstream' or incorrect stream length"*, which reads exactly like a wrong
          # `/Length` and is not. Reading this file could not have told you; running a
          # real PDF reader over the output did, on the first try.
          out << "\nendobj\n"
        end

        startxref = out.bytesize
        out << "xref\n0 #{objects.length + 1}\n"
        out << "0000000000 65535 f\r\n"
        offsets.each { |offset| out << format("%010d 00000 n\r\n", offset) }
        out << "trailer<</Size #{objects.length + 1}/Root 1 0 R/Info #{objects.length} 0 R>>\n"
        out << "startxref\n#{startxref}\n%%EOF\n"
        out
      end

      # `(`, `)` and `\` are the three characters that end or escape a PDF literal string,
      # so an unescaped one in a template name is a malformed document — and, since the
      # name is author-controlled, a way to write arbitrary page operators. Escaped here
      # and nowhere else, which is why every caller goes through `build`.
      def escape(text)
        encode(text.to_s).gsub(/([\\()])/) { "\\#{::Regexp.last_match(1)}" }
      end

      def encode(text)
        text.to_s.encode(ENCODING).force_encoding(BINARY)
      end

      def binary(text)
        (+text).force_encoding(BINARY)
      end
    end
  end
end
