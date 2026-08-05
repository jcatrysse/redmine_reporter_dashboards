# frozen_string_literal: true

require 'open3'
require 'tmpdir'

module RedmineReporterDashboards
  module Conformance
    # What the harness is allowed to know about a PDF.
    #
    # --- WHY THIS IS NOT A PDF PARSER ---
    #
    # Every conformance question here is answerable from three external tools, and the
    # alternative — a hand-rolled reader for object streams, Flate, subset fonts and
    # ToUnicode CMaps — would be several hundred lines of code that is itself untested
    # and whose bugs look exactly like engine defects. A wrong answer from OUR reader
    # would be indistinguishable from a wrong answer from the engine, which is the one
    # thing a conformance harness must never be.
    #
    #   pdfinfo    page count, page geometry in points
    #   pdftotext  the text the reader can actually select
    #   pdftoppm   the pixels, as a raw P6 bitmap
    #
    # --- AND WHY A MISSING TOOL IS A HARD ERROR, NEVER A SKIP ---
    #
    # This repository keeps rediscovering one failure mode: a check that did not run
    # looks exactly like a check that passed (`HANDOVER.md` §1 — the mirrored plugin
    # with no git history, the corpus without a reference date, `|| true` on a gate's
    # search). So `require_tools!` raises, the run stops, and the reason names the
    # package. A conformance suite that quietly stopped verifying geometry because
    # poppler was not installed is worse than no conformance suite, because the matrix
    # it generates still says PASS.
    module PdfProbe
      TOOLS = %w[pdfinfo pdftotext pdftoppm].freeze
      INSTALL_HINT = 'apt-get install -y poppler-utils'

      class ToolMissing < StandardError; end
      class ProbeFailed < StandardError; end

      # A colour comparison tolerance, per channel. Deliberately small: this is an
      # EXACT assertion about a flat fill, not a perceptual diff. Chromium renders
      # `#00aaff` as (0, 170, 255) exactly; the tolerance absorbs a rasteriser's
      # rounding, not a design change. CLAUDE.md §7 makes perceptual diffs advisory —
      # this is not one, and the difference is that a flat fill has a right answer.
      COLOUR_TOLERANCE = 8

      module_function

      def available?
        TOOLS.all? { |tool| which(tool) }
      end

      def missing_tools
        TOOLS.reject { |tool| which(tool) }
      end

      def require_tools!
        missing = missing_tools
        return true if missing.empty?

        raise ToolMissing,
              "the conformance harness needs #{missing.join(', ')} and they are not on PATH. " \
              "Install with: #{INSTALL_HINT}. This is an ERROR rather than a skip on purpose: " \
              'a matrix generated without the probes would report PASS for checks that never ran.'
      end

      def which(tool)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, tool)
          File.executable?(path) && !File.directory?(path)
        end
      end

      # ---- the three probes -------------------------------------------------

      def page_count(pdf_path)
        info(pdf_path).fetch('Pages').to_i
      end

      # Points, as the PDF itself carries them — 1 pt = 1/72 in, so A4 portrait is
      # 595 x 842. Returned as floats because engines disagree in the first decimal
      # and a conformance check should be about the page size, not about rounding.
      def page_size_pt(pdf_path)
        raw = info(pdf_path).fetch('Page size')
        match = raw.match(/([\d.]+)\s*x\s*([\d.]+)\s*pts/)
        raise ProbeFailed, "cannot read a page size out of #{raw.inspect}" unless match

        [match[1].to_f, match[2].to_f]
      end

      # `-layout` keeps columns roughly where they were, which is what makes a footer
      # assertion ("the page number is on the right") mean anything at all.
      def text(pdf_path, page: nil)
        args = ['pdftotext', '-layout']
        args += ['-f', page.to_s, '-l', page.to_s] if page
        run(*args, pdf_path, '-')
      end

      # One pixel, addressed as a FRACTION of the page rather than in device units,
      # so a check reads "the middle of the page" and does not silently change meaning
      # when the fixture's page size does.
      def pixel(pdf_path, page: 1, x: 0.5, y: 0.5, dpi: 24)
        Dir.mktmpdir('rrd-ppm') do |dir|
          prefix = File.join(dir, 'page')
          run('pdftoppm', '-r', dpi.to_s, '-f', page.to_s, '-l', page.to_s, pdf_path, prefix)
          ppm = Dir[File.join(dir, 'page*.ppm')].sort.first
          raise ProbeFailed, "pdftoppm produced no bitmap for page #{page}" unless ppm

          read_ppm_pixel(File.binread(ppm), x, y)
        end
      end

      def colour_matches?(actual, expected, tolerance: COLOUR_TOLERANCE)
        actual.length == expected.length &&
          actual.each_with_index.all? { |value, i| (value - expected[i]).abs <= tolerance }
      end

      # ---- plumbing ---------------------------------------------------------

      # P6: a text header (magic, width, height, maxval) followed by raw RGB triples.
      # Parsed here rather than shelled out to, because this part genuinely is trivial
      # and adding an image library for it would be the tail wagging the dog.
      def read_ppm_pixel(bytes, x_fraction, y_fraction)
        header = bytes.match(/\AP6\s+(\d+)\s+(\d+)\s+(\d+)\s/m)
        raise ProbeFailed, 'not a P6 bitmap' unless header
        raise ProbeFailed, "unsupported maxval #{header[3]}" unless header[3] == '255'

        width = header[1].to_i
        height = header[2].to_i
        x = (x_fraction * width).to_i.clamp(0, width - 1)
        y = (y_fraction * height).to_i.clamp(0, height - 1)
        offset = header.end(0) + ((y * width) + x) * 3
        bytes.byteslice(offset, 3).unpack('C3')
      end

      def info(pdf_path)
        @info ||= {}
        @info[cache_key(pdf_path)] ||= parse_info(run('pdfinfo', pdf_path))
      end

      def parse_info(output)
        output.each_line.with_object({}) do |line, out|
          key, _, value = line.partition(':')
          out[key.strip] = value.strip unless value.empty?
        end
      end

      # The path alone is not a key: a fixture may render twice to the same temporary
      # file, and a cached page count from the previous render is a silent lie.
      def cache_key(pdf_path)
        stat = File.stat(pdf_path)
        [pdf_path, stat.size, stat.mtime.to_f].join('|')
      end

      def run(*command)
        require_tools!
        out, err, status = Open3.capture3(*command)
        return out if status.success?

        raise ProbeFailed, "#{command.first} failed (#{status.exitstatus}): #{err.strip}"
      end
    end
  end
end
