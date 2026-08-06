# frozen_string_literal: true

require_relative '../../lib/redmine_reporter_dashboards/render/pdf_inspector'

module RedmineReporterDashboards
  module Conformance
    # What the harness is allowed to know about a PDF.
    #
    # --- THIS FILE IS A POLICY, NOT AN IMPLEMENTATION ---
    #
    # The reading itself — pdfinfo, pdftotext, pdftoppm, the P6 pixel parse — moved to
    # `Render::PdfInspector` when `Preflight` (T-14) needed exactly the same three
    # answers on a real install. Keeping a second copy here would be a second way of
    # doing something that already has a way (CLAUDE.md §6), and worse: the copy the
    # conformance corpus trusts and the copy an operator's diagnostic trusts could drift
    # apart, so a green matrix would stop meaning the diagnostic is right.
    #
    # What stays here is the ONE thing the two callers genuinely disagree about.
    #
    # --- A MISSING TOOL IS A HARD ERROR HERE, AND A SKIP THERE ---
    #
    # `Preflight` runs on somebody's install, where poppler is an optional package and a
    # named skip is the honest answer. This harness GENERATES THE SUPPORT MATRIX, and
    # this repository keeps rediscovering one failure mode: a check that did not run
    # looks exactly like a check that passed (`HANDOVER.md` §1 — the mirrored plugin with
    # no git history, the corpus without a reference date, `|| true` on a gate's search).
    # A matrix generated without the probes would still print PASS for geometry, colour
    # and text — checks that never executed. So `require_tools!` raises, the run stops,
    # and the reason names the package.
    #
    # Same mechanism, opposite policy, and the policy is what this file is for.
    module PdfProbe
      Inspector = Render::PdfInspector

      TOOLS = Inspector::TOOLS
      INSTALL_HINT = 'apt-get install -y poppler-utils'

      class ToolMissing < StandardError; end

      # The inspector's failure, under the name the harness has always used for it.
      # Aliased rather than wrapped: a probe failure means the same thing on both sides,
      # and two classes for one condition is how a rescue ends up catching neither.
      ProbeFailed = Inspector::InspectionFailed

      COLOUR_TOLERANCE = Inspector::COLOUR_TOLERANCE

      module_function

      def available?
        Inspector.available?
      end

      def missing_tools
        Inspector.missing_tools
      end

      def which(tool)
        Inspector.which(tool)
      end

      # THE POLICY. Note it consults *this* module's `missing_tools` rather than the
      # inspector's: the harness's own spec plants a missing tool by stubbing it here,
      # and a call that reached past it would test the real PATH instead of the case.
      def require_tools!
        missing = missing_tools
        return true if missing.empty?

        raise ToolMissing,
              "the conformance harness needs #{missing.join(', ')} and they are not on PATH. " \
              "Install with: #{INSTALL_HINT}. This is an ERROR rather than a skip on purpose: " \
              'a matrix generated without the probes would report PASS for checks that never ran.'
      end

      # ---- the three probes, delegated --------------------------------------
      #
      # Path-based: a fixture has already written its document to the work directory,
      # and the inspector's byte-based spellings would copy it back out to a second
      # temporary file for nothing.

      def page_count(pdf_path)
        Inspector.page_count_at(pdf_path)
      end

      def page_size_pt(pdf_path)
        Inspector.page_size_pt_at(pdf_path)
      end

      def text(pdf_path, page: nil)
        Inspector.text_at(pdf_path, page: page)
      end

      def pixel(pdf_path, page: 1, x: 0.5, y: 0.5, dpi: 24)
        Inspector.pixel_at(pdf_path, page: page, x: x, y: y, dpi: dpi)
      end

      def colour_matches?(actual, expected, tolerance: COLOUR_TOLERANCE)
        Inspector.colour_matches?(actual, expected, tolerance: tolerance)
      end

      def read_ppm_pixel(bytes, x_fraction, y_fraction)
        Inspector.read_ppm_pixel(bytes, x_fraction, y_fraction)
      end
    end
  end
end
