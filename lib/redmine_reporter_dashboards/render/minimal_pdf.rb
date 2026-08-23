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

      # --- WRAPPING IS BY REAL ADVANCE WIDTH, AND THE FIRST VERSION GUESSED ---
      #
      # It wrapped at 62 characters on the reasoning that Helvetica at 11pt "averages a
      # little under 5.5pt per character". The independent review measured the drawn text
      # with `pdftotext -bbox-layout` and the average is not the bound: the ordinary
      # template name
      #
      #   QUARTERLY CONSOLIDATED PROGRAMME STATUS REPORT NORTHERN REGION 2026 Q3 FINAL
      #
      # — 76 characters, well inside the model's 255 — drew to x = 600.2pt, which is 61pt
      # past the right margin and **5pt past the edge of the paper**. Capitals average
      # 0.68em, not 0.49em. That is the same defect as the vertical overflow this file
      # already fixed, on the other axis, reachable with data an author types in.
      #
      # So the widths are the FONT'S widths. These are Adobe's Helvetica and
      # Helvetica-Bold AFM advance widths for ASCII, in 1/1000 em, and anything outside
      # that range is charged `WIDEST_GLYPH` — a true upper bound for WinAnsi Helvetica,
      # not an average — so an accented or box-drawing character can never be
      # under-measured. A table can be mistyped, which is why the specs assert the DRAWN
      # geometry with poppler rather than trusting the numbers here.
      HELVETICA_WIDTHS = [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584
      ].freeze

      HELVETICA_BOLD_WIDTHS = [
        278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
        975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
        333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
        611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584
      ].freeze

      # Charged for every byte outside ASCII. `@` is the widest ASCII glyph in Helvetica at
      # 1015/1000; nothing in WinAnsi Helvetica exceeds it, so this cannot under-measure.
      WIDEST_GLYPH = 1015
      FIRST_MEASURED_BYTE = 32
      LAST_MEASURED_BYTE = 126

      # A gutter between the label column and the value column, so a label that fills its
      # column does not touch the value beside it.
      COLUMN_GAP = 12

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
      # second bound on the LAYOUT — and when it fires it SAYS SO, because the first
      # version's comment claimed it "refused" a silent overflow while in fact dropping the
      # remaining rows without a mark.
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
        dropped = false

        out << "\n/F2 #{TITLE_SIZE} Tf"
        out << "\n" << text_op(MARGIN, y, clip_to_width(title, body_width, TITLE_SIZE, bold: true))

        y -= LINE_HEIGHT * 2

        # THE LABEL COLUMN IS MEASURED, NOT ASSUMED. It used to be a fixed 150pt, which the
        # Polish and Hungarian labels come close to filling — and a label wider than its
        # column would have drawn straight over the value beside it. Taking the widest label
        # actually present also gives the value column every point the labels do not need.
        label_column = label_column_width(rows)
        value_x = MARGIN + label_column + COLUMN_GAP
        value_width = PAGE_WIDTH - MARGIN - value_x

        rows.each do |label, value|
          label = label.to_s

          # ONE LINE IS RESERVED so the marker below can be drawn. Asking `room?(y)` here
          # stopped exactly when there was no longer room for anything, marker included —
          # so the page that most needed to admit it was incomplete was the one that could
          # not say so.
          unless room?(y - LINE_HEIGHT)
            dropped = true
            break
          end

          if label.empty?
            clip(wrap(value.to_s, body_width, BODY_SIZE), MAX_PARAGRAPH_LINES,
                 body_width, BODY_SIZE).each do |line|
              break unless room?(y)

              out << "\n/F1 #{BODY_SIZE} Tf"
              out << "\n" << text_op(MARGIN, y, line)
              y -= LINE_HEIGHT
            end
          else
            out << "\n/F2 #{BODY_SIZE} Tf"
            out << "\n" << text_op(MARGIN, y, label)

            clip(wrap(value.to_s, value_width, BODY_SIZE), MAX_VALUE_LINES,
                 value_width, BODY_SIZE).each do |line|
              break unless room?(y)

              out << "\n/F1 #{BODY_SIZE} Tf"
              out << "\n" << text_op(value_x, y, line)
              y -= LINE_HEIGHT
            end
          end

          y -= LINE_HEIGHT / 2
        end

        # A DROPPED ROW SAYS SO. The bound used to `break` in silence while its own comment
        # claimed it refused a silent overflow — which is the shape of claim this file
        # exists to stop making. Unreachable with FR-59's nine rows; present so that a
        # future caller with forty gets a page that admits it is incomplete.
        if dropped && room?(y)
          out << "\n/F1 #{BODY_SIZE} Tf"
          out << "\n" << text_op(MARGIN, y, TRUNCATION_MARKER)
        end

        out << "\nET"
        out
      end

      # The full text column, used by the title and by the full-width paragraphs.
      def body_width
        PAGE_WIDTH - (MARGIN * 2)
      end

      # Bounded so a pathological label cannot take the whole page and leave the value no
      # room; `clip_to_width` then cuts anything past it.
      def label_column_width(rows)
        cap = ((PAGE_WIDTH - (MARGIN * 2)) * 0.4).floor
        widest = rows.map { |label, _| advance(label.to_s, BODY_SIZE, bold: true) }.max.to_f

        [[widest.ceil, cap].min, 1].max
      end

      # THE BOUND IS ON THE COORDINATE, NOT ON A LINE COUNT, and the first version was a
      # line count. It failed the forty-row example at **y = -199**: each row costs a line
      # AND a half-line of spacing, so "42 lines fit" was true of the lines and false of
      # the page. Asking the cursor removes the arithmetic and cannot drift when the
      # spacing changes.
      def room?(y)
        y >= MARGIN
      end

      # --- measurement -------------------------------------------------------------------

      # The drawn width of `text` at `size`, in points. Bytes outside the measured ASCII
      # range are charged the widest glyph in the font, so this is never an under-estimate
      # — which is the only direction that matters for a bound.
      def advance(text, size, bold: false)
        widths = bold ? HELVETICA_BOLD_WIDTHS : HELVETICA_WIDTHS
        total = 0

        encode(text.to_s).each_byte do |byte|
          total += if byte >= FIRST_MEASURED_BYTE && byte <= LAST_MEASURED_BYTE
                     widths[byte - FIRST_MEASURED_BYTE]
                   else
                     WIDEST_GLYPH
                   end
        end

        total * size / 1000.0
      end

      # One line, cut to fit, with the marker inside the width rather than appended past it
      # — appending was how `clip` pushed its last line six characters over.
      def clip_to_width(text, width, size, bold: false)
        string = text.to_s
        return string if advance(string, size, bold: bold) <= width

        marker_room = width - advance(TRUNCATION_MARKER, size, bold: bold) - 2
        kept = +''
        string.each_char do |char|
          break if advance(kept + char, size, bold: bold) > marker_room

          kept << char
        end

        "#{kept}#{TRUNCATION_MARKER}"
      end

      def text_op(x, y, text)
        out = binary("1 0 0 1 #{x} #{y} Tm (")
        out << escape(text)
        out << ') Tj'
        out
      end

      # Wraps to a WIDTH IN POINTS rather than to a character count — see the note on the
      # width tables. A word wider than the column (a correlation id has no spaces in it,
      # and neither does a URL) is HARD-BROKEN rather than allowed to run off the page. A
      # value that silently leaves the paper is the same class of defect as one that is
      # silently truncated, and it is what the first version did for any name in capitals.
      def wrap(text, width, size, bold: false)
        words = text.to_s.split(/\s+/).reject(&:empty?)
        return [''] if words.empty?

        lines = []
        current = +''

        words.each do |word|
          # A word wider than the whole column is broken into fitting chunks first.
          while advance(word, size, bold: bold) > width
            lines << current unless current.empty?
            current = +''
            chunk = fitting_prefix(word, width, size, bold)
            lines << chunk
            word = word[chunk.length..] || ''
          end
          next if word.empty?

          candidate = current.empty? ? word : "#{current} #{word}"
          if !current.empty? && advance(candidate, size, bold: bold) > width
            lines << current
            current = +word
          else
            current = candidate
          end
        end

        lines << current unless current.empty?
        lines
      end

      # The longest leading run of `word` that fits. Answers one character when even that
      # does not fit, which cannot happen at these sizes and stops the loop above being
      # infinite if it ever does.
      def fitting_prefix(word, width, size, bold)
        kept = +''
        word.each_char do |char|
          break if advance(kept + char, size, bold: bold) > width

          kept << char
        end

        kept.empty? ? word[0, 1] : kept
      end

      # Keeps at most `limit` lines and says so on the last one. The marker is fitted INTO
      # the column rather than appended past it: appending made the last line six
      # characters wider than the column it had just been wrapped to fit, which is how the
      # first version drew past the right margin even after wrapping correctly.
      def clip(lines, limit, width, size, bold: false)
        return lines if lines.length <= limit

        kept = lines[0, limit]
        candidate = "#{kept[-1]} #{TRUNCATION_MARKER}"
        kept[-1] = if advance(candidate, size, bold: bold) <= width
                     candidate
                   else
                     clip_to_width(candidate, width, size, bold: bold)
                   end
        kept
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
