# frozen_string_literal: true

require 'cgi'
require 'open3'
require 'tmpdir'

module RedmineReporterDashboards
  module Render
    # Reading a PDF back, for the one purpose that needs it: telling an operator
    # whether the document that just came out is the document they wanted.
    #
    # --- WHY THIS IS IN lib/ AND NOT ONLY IN THE TEST HARNESS ---
    #
    # It started as `spec/conformance/pdf_probe.rb`, which is where it is used most. But
    # `Preflight` needs exactly the same three answers on a REAL INSTALL — that is the
    # whole point of a preflight, and a diagnostic that cannot see inside the document
    # can only report "bytes came back", which is the check that was already passing
    # while every report lost its images. `PdfProbe` now delegates here rather than
    # keeping a second copy: CLAUDE.md §6, no second way of doing something that already
    # has a way.
    #
    # --- WHY THIS IS NOT A PDF PARSER ---
    #
    # Every question here is answerable from three external tools, and the alternative —
    # a hand-rolled reader for object streams, Flate, subset fonts and ToUnicode CMaps —
    # would be several hundred lines of untested code whose bugs look exactly like engine
    # defects. A wrong answer from OUR reader would be indistinguishable from a wrong
    # answer from the engine, which is the one thing a diagnostic must never be.
    #
    #   pdfinfo    page count, page geometry in points
    #   pdftotext  the text the reader can actually select
    #   pdftoppm   the pixels, as a raw P6 bitmap
    #
    # --- IT IS OPTIONAL, AND THE DIFFERENCE MATTERS ---
    #
    # `poppler-utils` is not a plugin dependency and must not become one: it would be a
    # package install for a diagnostic most operators run once. So `available?` is a
    # real question, and a caller that cannot run a check reports `:skip` WITH THE
    # PACKAGE NAMED — never a quiet pass. The conformance harness treats the same absence
    # as a hard error, because there a missing probe means the matrix would print PASS
    # for checks that never ran. Same mechanism, two policies, each correct for its
    # caller — and the policy is the caller's, which is why `require_tools!` lives on
    # both sides rather than being decided here.
    #
    # --- BYTES OR A PATH ---
    #
    # `Preflight` holds a rendered document in memory; the conformance harness holds a
    # file it wrote. Rather than force either to convert, every probe comes in two
    # spellings — `page_count(bytes)` and `page_count_at(path)` — where the bytes form is
    # a three-line wrapper over the path form. One implementation, two entry points.
    module PdfInspector
      TOOLS = %w[pdfinfo pdftotext pdftoppm].freeze
      INSTALL_HINT = 'install poppler-utils for the full preflight (pdfinfo, pdftotext, pdftoppm)'

      class Unavailable < StandardError; end
      class InspectionFailed < StandardError; end

      # Per channel. This is an exact comparison against a flat fill, not a perceptual
      # one: the tolerance absorbs a rasteriser's rounding, not a design change.
      # CLAUDE.md §7 makes perceptual diffs advisory — this is not one, and the
      # difference is that a flat fill has a right answer.
      COLOUR_TOLERANCE = 8

      module_function

      # ---- availability -----------------------------------------------------

      def missing_tools
        TOOLS.reject { |tool| which(tool) }
      end

      def available?
        missing_tools.empty?
      end

      def which(tool)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, tool)
          File.executable?(path) && !File.directory?(path)
        end
      end

      def require_tools!
        missing = missing_tools
        return true if missing.empty?

        raise Unavailable, "#{missing.join(', ')} not found — #{INSTALL_HINT}"
      end

      # ---- the probes, on bytes ---------------------------------------------

      def with_document(bytes)
        Dir.mktmpdir('rrd-inspect') do |dir|
          path = File.join(dir, 'document.pdf')
          File.binwrite(path, bytes)
          yield path, dir
        end
      end

      def page_count(bytes)
        with_document(bytes) { |path, _| page_count_at(path) }
      end

      def page_size_pt(bytes)
        with_document(bytes) { |path, _| page_size_pt_at(path) }
      end

      def text(bytes, page: nil)
        with_document(bytes) { |path, _| text_at(path, page: page) }
      end

      def pixel(bytes, page: 1, x: 0.5, y: 0.5, dpi: 24)
        with_document(bytes) { |path, _| pixel_at(path, page: page, x: x, y: y, dpi: dpi) }
      end

      # Whitespace collapsed. A PDF has lines, not sentences: a phrase assertion against
      # the raw text fails whenever the column happens to break in the middle of it.
      def flat_text(bytes, page: nil)
        flatten(text(bytes, page: page))
      end

      def flat_text_at(path, page: nil)
        flatten(text_at(path, page: page))
      end

      def flatten(raw)
        raw.gsub(/\s+/, ' ').strip
      end

      # ---- the probes, on a path --------------------------------------------

      def page_count_at(path)
        info(path).fetch('Pages').to_i
      end

      # Points, as the PDF itself carries them — 1 pt = 1/72 in, so A4 portrait is
      # 595 x 842. Returned as floats because engines disagree in the first decimal and
      # a check should be about the page size, not about rounding.
      def page_size_pt_at(path)
        raw = info(path).fetch('Page size')
        match = raw.match(/([\d.]+)\s*x\s*([\d.]+)\s*pts/)
        raise InspectionFailed, "cannot read a page size out of #{raw.inspect}" unless match

        [match[1].to_f, match[2].to_f]
      end

      # `-layout` keeps columns roughly where they were, which is what makes a footer
      # assertion ("the page number is on the right") mean anything at all.
      def text_at(path, page: nil)
        args = ['pdftotext', '-layout']
        args += ['-f', page.to_s, '-l', page.to_s] if page
        run(*args, path, '-')
      end

      # One pixel, addressed as a FRACTION of the page rather than in device units, so a
      # check reads "the middle of the page" and does not silently change meaning when
      # the page size does.
      def pixel_at(path, page: 1, x: 0.5, y: 0.5, dpi: 24)
        Dir.mktmpdir('rrd-ppm') do |dir|
          prefix = File.join(dir, 'page')
          run('pdftoppm', '-r', dpi.to_s, '-f', page.to_s, '-l', page.to_s, path, prefix)
          ppm = Dir[File.join(dir, 'page*.ppm')].sort.first
          raise InspectionFailed, "pdftoppm produced no bitmap for page #{page}" unless ppm

          read_ppm_pixel(File.binread(ppm), x, y)
        end
      end

      def colour_matches?(actual, expected, tolerance: COLOUR_TOLERANCE)
        actual.length == expected.length &&
          actual.each_with_index.all? { |value, i| (value - expected[i]).abs <= tolerance }
      end

      # ---- link annotations (T-38) -------------------------------------------
      #
      # "Drill-through links in the PDF are real links, asserted by extracting the link
      # annotations from the produced PDF." Two readers, and the second exists because the
      # first cannot see the annotation that matters.
      #
      # MEASURED 2026-08-13, on this container, on all three engines in the matrix — and the
      # wkhtmltopdf row is stated for the SUPPORTED build, because the first version of this
      # comment stated it for the distro one and was wrong (see `Render::Capabilities`, which
      # carries the retraction of the two capabilities that mistake nearly bought):
      #
      #   plain `<a href>` around text     every engine: annotation, and poppler reports it
      #   `<a xlink:href>` around a <rect> every engine: the annotation IS in the PDF
      #                                    (`/URI (https://…)` in the bytes), and poppler
      #                                    reports NOTHING — there is no text under it
      #   `<a xlink:href>` around <text>   every engine: annotation, and poppler reports it
      #
      # `pdftohtml` is a TEXT extractor: it attaches a link to the text under it, and
      # `SvgRenderer` wraps `<rect>`, `<circle>` and `<path>` — never text — so a chart's
      # drill-through is invisible to it. That is a limitation of the reader, and reporting
      # it as "the engine drew no link" would be the harness lying about the engine, which
      # `spec/conformance/README.md` says must never happen.
      #
      # So there are two readings and `PdfProbe` cross-checks them: everything poppler can
      # see must also be in the byte scan. If the scan misses something poppler found, the
      # SCAN is broken and the harness says so in its own words instead of blaming an
      # engine. That is what makes a byte scan admissible here at all.
      LINK_TOOLS = %w[pdftohtml].freeze

      def missing_link_tools
        LINK_TOOLS.reject { |tool| which(tool) }
      end

      # The hrefs poppler reports, which is the subset of annotations that sit over text.
      # `-xml` rather than `-c`: the XML output carries `<a href="…">` around the text run
      # and nothing else, so there is no HTML to parse around it.
      #
      # `CGI.unescapeHTML` IS THE WHOLE CORRECTNESS OF THE CROSS-CHECK, and the first version
      # left it out. `pdftohtml -xml` XML-escapes the attribute, so a URL with a `&` in it
      # comes back as `…?filter=all&amp;x=1` while `uri_annotations_at` reads the raw bytes
      # and answers `…?filter=all&x=1`. `PdfProbe.links` compares the two sets and raises when
      # poppler saw something the scan did not — so every `&` in a URL produced a HARNESS
      # failure blaming the reader for a link it had read perfectly. Measured by an
      # independent review against a hand-built PDF, and it matters more than it sounds: a
      # real Redmine drill-through URL is `&`-dense
      # (`/issues?set_filter=1&f[]=status_id&op[]==&v[status_id][]=1`), so the guard would
      # have detonated on the first realistic chart.
      def text_links_at(path)
        require_link_tools!
        xml = run('pdftohtml', '-stdout', '-xml', '-i', path)
        xml.scan(/<a\s+href="([^"]*)"/).flatten.map { |href| CGI.unescapeHTML(href) }.uniq
      end

      # Every `/URI` value in the file's bytes.
      #
      # A SCAN AND NOT A PARSER, and the difference is the point: it decodes nothing, walks
      # no object graph and answers "these URI strings are in this file". Both engines in
      # this repository's matrix write the annotation dictionary uncompressed, which is why
      # it works; an engine that put its annotations inside a Flate object stream would
      # answer an EMPTY list here, and `PdfProbe.links` is what turns that into a harness
      # failure rather than an accusation against the engine.
      #
      # The literal-string form `(…)` is what both engines emit — measured. Balanced inner
      # parentheses are not handled, and a URL containing one is not something to guess at:
      # the fixture's own URLs are plain.
      def uri_annotations_at(path)
        File.binread(path).scan(/\/URI\s*\(([^()]*)\)/).flatten
            .map { |uri| uri.force_encoding(Encoding::UTF_8) }.uniq
      end

      def require_link_tools!
        missing = missing_link_tools
        return true if missing.empty?

        raise Unavailable,
              "reading a PDF's link annotations needs #{missing.join(', ')} on PATH"
      end

      # ---- plumbing ---------------------------------------------------------

      # P6: a text header (magic, width, height, maxval) then raw RGB triples. Parsed
      # here rather than shelled out to, because this part genuinely is trivial and
      # adding an image library for it would be the tail wagging the dog.
      def read_ppm_pixel(bytes, x_fraction, y_fraction)
        header = bytes.match(/\AP6\s+(\d+)\s+(\d+)\s+(\d+)\s/m)
        raise InspectionFailed, 'not a P6 bitmap' unless header
        raise InspectionFailed, "unsupported maxval #{header[3]}" unless header[3] == '255'

        width = header[1].to_i
        height = header[2].to_i
        x = (x_fraction * width).to_i.clamp(0, width - 1)
        y = (y_fraction * height).to_i.clamp(0, height - 1)
        offset = header.end(0) + ((y * width) + x) * 3
        bytes.byteslice(offset, 3).unpack('C3')
      end

      # NOT MEMOISED, DELIBERATELY. It was, keyed by path+size+mtime — a sensible
      # micro-optimisation in a short-lived test process with stable fixture paths, and
      # a defect the moment this file moved to `lib/`. `with_document` mints a fresh
      # `Dir.mktmpdir` path per call, so every admin-page POST and every rake run added
      # an entry that could never be hit again: an unbounded, never-evicted hash in a
      # long-running web process, shared across request threads with no synchronisation.
      # `pdfinfo` costs a few milliseconds; the cache was buying nothing and holding
      # memory forever.
      def info(path)
        parse_info(run('pdfinfo', path))
      end

      def parse_info(output)
        output.each_line.with_object({}) do |line, out|
          key, _, value = line.partition(':')
          out[key.strip] = value.strip unless value.empty?
        end
      end

      # The output is tagged UTF-8 rather than left at the default external encoding.
      # `pdftotext` emits UTF-8, but on a server with a POSIX locale Ruby would label it
      # US-ASCII — and then the first accented character in a document turns a regexp
      # match into `ArgumentError: invalid byte sequence`. A diagnostic that crashes on
      # a French report is worse than one that does not exist.
      def run(*command)
        require_tools!
        out, err, status = Open3.capture3(*command)
        return out.force_encoding(Encoding::UTF_8) if status.success?

        raise InspectionFailed, "#{command.first} failed (#{status.exitstatus}): #{err.strip}"
      end
    end
  end
end
