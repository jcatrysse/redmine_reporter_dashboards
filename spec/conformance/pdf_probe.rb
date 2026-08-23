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

      # THE LINK READER IS IN THIS LIST TOO, so the harness's ONE up-front check covers it and
      # `PdfProbe.links` never has to raise a second exception class for the same condition.
      # This file says a few lines up why that must not happen — "two classes for one
      # condition is how a rescue ends up catching neither" — and the first version of the
      # link probe had exactly that shape: `require_tools!` raising `ToolMissing` and then
      # `Inspector.require_link_tools!` raising `Inspector::Unavailable` with the inspector's
      # operator-facing wording. Found in review.
      #
      # It is added HERE and not to `Inspector::TOOLS`, and that is the point of this file
      # being a policy: `Render::Preflight` shares the inspector and runs on somebody's
      # install, where a missing `pdftohtml` should not turn a working diagnostic into an
      # unavailable one. The harness needs it; an operator's preflight does not.
      def missing_tools
        Inspector.missing_tools + Inspector.missing_link_tools
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
      #
      # EVERY ONE ASKS `require_tools!` FIRST, and that is the policy, not ceremony.
      # The inspector has its own guard and it raises `Inspector::Unavailable` with the
      # inspector's wording — which is right for an operator and wrong here, and would
      # leave TWO EXCEPTION CLASSES FOR ONE CONDITION. This file says a few lines up why
      # that must not happen. Without these calls the harness's own message —
      # "a matrix generated without the probes would report PASS for checks that never
      # ran" — is reachable only from `Runner`'s single up-front check, and the per-call
      # guard is gone. Caught in review.

      def page_count(pdf_path)
        require_tools!
        Inspector.page_count_at(pdf_path)
      end

      def page_size_pt(pdf_path)
        require_tools!
        Inspector.page_size_pt_at(pdf_path)
      end

      def text(pdf_path, page: nil)
        require_tools!
        Inspector.text_at(pdf_path, page: page)
      end

      def pixel(pdf_path, page: 1, x: 0.5, y: 0.5, dpi: 24)
        require_tools!
        Inspector.pixel_at(pdf_path, page: page, x: x, y: y, dpi: dpi)
      end

      def colour_matches?(actual, expected, tolerance: COLOUR_TOLERANCE)
        Inspector.colour_matches?(actual, expected, tolerance: tolerance)
      end

      # T-38 — the link annotations in the document, and the CROSS-CHECK that makes reading
      # them admissible under this file's own rule.
      #
      # `spec/conformance/README.md`: "A wrong answer from *our* reader must never be
      # confusable with a wrong answer from the engine." The two readings the inspector
      # offers are exactly that risk and exactly its answer:
      #
      #   poppler (`pdftohtml -xml`)   TRUSTWORTHY, and PARTIAL. It attaches a link to the
      #                                text under it, so it sees an `<a href>` around a word
      #                                and cannot see an `<a xlink:href>` around a `<rect>`
      #                                — which is every chart drill-through `SvgRenderer`
      #                                emits. Measured 2026-08-13 against Chromium: the
      #                                annotation is in the file and poppler reports nothing.
      #   the byte scan                COMPLETE for the engines in this matrix, and it is
      #                                ours. If an engine ever wrote its annotations into a
      #                                compressed object stream the scan would answer an
      #                                empty list, which reads exactly like an engine that
      #                                drew no links.
      #
      # So the scan is the answer and poppler is its witness: anything poppler found that
      # the scan did not means THE SCAN is broken, and the raise says so in the harness's
      # own voice. A fixture that asserts on this therefore cannot blame an engine for a
      # reader's blind spot — which is the whole reason the two are read together rather
      # than picking whichever one is convenient.
      def links(pdf_path)
        require_tools!

        scanned = Inspector.uri_annotations_at(pdf_path)
        witnessed = Inspector.text_links_at(pdf_path)
        missed = witnessed - scanned
        return scanned if missed.empty?

        raise ProbeFailed,
              "the harness's link reader missed #{missed.inspect}, which pdftohtml found in " \
              "the same file. This is a HARNESS failure, not an engine one: the byte scan " \
              'reads only uncompressed annotation dictionaries, and this document has ' \
              'annotations it cannot see. Do not read a red cell here as the engine ' \
              'drawing no links.'
      end

      def read_ppm_pixel(bytes, x_fraction, y_fraction)
        Inspector.read_ppm_pixel(bytes, x_fraction, y_fraction)
      end
    end
  end
end
