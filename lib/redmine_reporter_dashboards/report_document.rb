# frozen_string_literal: true

require_relative 'report_stylesheet'

module RedmineReporterDashboards
  # T-38 — the ONE place a rendered report body becomes a standalone HTML document.
  #
  # --- WHY A SECOND MODULE RATHER THAN A SECOND METHOD ON `ReportFrame` -------------
  #
  # `ReportFrame` says of itself that it is "the ONLY place that assembles the document
  # or names the sandbox", and that property is what stopped the CSP and the body
  # becoming separable. It is kept: `ReportFrame.document` still owns the sandbox
  # policy and still is the only caller that names it. What moved here is the part that
  # is NOT about a sandbox — the doctype, the charset and the stylesheet — because the
  # PDF binding needs exactly that part and has no sandbox at all.
  #
  # The alternative was to let the PDF path assemble its own document, and that is the
  # arrangement T-38 exists to end: two assemblers means the HTML view and the PDF get
  # the same stylesheet only until somebody edits one of them. `technical-spec.md`
  # §9b.4 wants "the same document at two sizes rather than two designs", which is a
  # claim about construction rather than about intent.
  #
  # So there is one assembler with two callers:
  #
  #   ReportFrame.document(body)          -> adds the CSP meta, for the srcdoc iframe
  #   Reporting::ReportRun#bind_assets    -> adds nothing, for DocumentRequest#body
  #
  # --- NO `html_safe`, AND THE BODY IS NOT ESCAPED EITHER ---------------------------
  #
  # `body` is already-rendered markup from the Liquid layer, which is where escaping
  # happens (FR-19, `ScriptSafeJson`, the drop layer). This module concatenates; it
  # does not decide anything about the body's safety and does not mark it safe. On the
  # HTML binding the result becomes the value of a `srcdoc` ATTRIBUTE, which Rails
  # escapes as attribute data (INV-9 — held by construction, by `report_document_spec.rb`'s
  # own source check, and since T-27 by `script/gates/no_html_safe.sh`, which runs in CI's
  # `gates` job); on the PDF binding
  # it becomes `DocumentRequest#body`, which no browser of the viewer's ever parses.
  #
  # --- WHAT IS DELIBERATELY NOT HERE -----------------------------------------------
  #
  # `<html lang>`. It is a real accessibility improvement and it needs a locale, which
  # is a property of a REQUEST — and a scheduled render has none. Adding it would mean
  # either threading a locale through `ReportRun` (T-38 does not ask for it) or reading
  # `I18n.locale` here, which would be ambient state in a module that has none. Left
  # out and recorded, rather than guessed at.
  module ReportDocument
    # `head` is markup the CALLER owns and this module never invents. Today its only
    # user is `ReportFrame`, whose CSP `<meta>` must sit in the head of the document
    # that body is going into — and must not appear in the PDF document, where there is
    # no browser to enforce it and an engine might reasonably refuse its own asset.
    def self.wrap(body, head: '')
      "<!DOCTYPE html>\n" \
        "<html><head><meta charset=\"utf-8\">\n" \
        "#{head}" \
        "#{ReportStylesheet.style_element}\n" \
        "</head><body>#{body}</body></html>\n"
    end
  end
end
