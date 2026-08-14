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
  # --- `<html lang>` — THE INSTALLATION DEFAULT, BY DECISION ------------------------
  #
  # This section used to say the attribute was deliberately absent, because a locale is
  # a property of a REQUEST and a scheduled render has none. The question it left open —
  # *whose* language does a scheduled report speak — is curator decision #7 (2026-08-13),
  # and the answer is **the installation default**: `Setting.default_language`.
  #
  # The three candidates were the installation default, the schedule's owner, and one
  # render per recipient. The last is the most correct and costs a render per language;
  # the middle one makes the same report speak differently depending on who set the
  # schedule up. The installation default is one line, is right for the great majority of
  # installs, and can be refined later without breaking a document that already carries it.
  #
  # NOT `I18n.locale`, and that distinction is the whole point. `I18n.locale` is ambient
  # per-request state, so the SAME template would produce a different `lang` depending on
  # who happened to trigger it — an interactive preview in Dutch, the schedule's own run in
  # whatever the worker inherited. `Setting.default_language` is a property of the
  # INSTALLATION, so every document this plugin produces declares the same language.
  #
  # A screen reader announces the document in this language and a PDF engine hyphenates
  # with it, so it is a real accessibility improvement rather than a formality. `dir` is
  # NOT set: all nine locales this plugin ships are left-to-right, and emitting a direction
  # nobody has measured would be a claim rather than a fact.
  module ReportDocument
    # What `lang` says when Redmine is not loaded, or when the setting is blank — which it
    # can be: `Setting.default_language` is a String and an administrator may empty it.
    FALLBACK_LANGUAGE = 'en'

    # `head` is markup the CALLER owns and this module never invents. Today its only
    # user is `ReportFrame`, whose CSP `<meta>` must sit in the head of the document
    # that body is going into — and must not appear in the PDF document, where there is
    # no browser to enforce it and an engine might reasonably refuse its own asset.
    #
    # `lang:` is a seam, not a feature: it defaults to the installation's language and
    # exists so a spec can assert the markup without stubbing a global. No caller passes it.
    def self.wrap(body, head: '', lang: default_language)
      "<!DOCTYPE html>\n" \
        "<html lang=\"#{escape_attribute(lang)}\"><head><meta charset=\"utf-8\">\n" \
        "#{head}" \
        "#{ReportStylesheet.style_element}\n" \
        "</head><body>#{body}</body></html>\n"
    end

    # DEFENSIVE ON PURPOSE, and each guard answers a case that exists. `Setting` is
    # Redmine's, so it is absent in the DB-less spec run; `default_language` is a plain
    # String column that an administrator can empty; and a value is only trusted if it
    # looks like a language tag, because this one goes into an ATTRIBUTE.
    def self.default_language
      value = (defined?(::Setting) && ::Setting.respond_to?(:default_language) ?
               ::Setting.default_language : nil).to_s
      LANGUAGE_TAG.match?(value) ? value : FALLBACK_LANGUAGE
    end

    # Redmine's own locale names — `en`, `pt-BR`, `zh-TW` — which are already BCP 47 tags.
    # Anything else falls back rather than being escaped into the document: a `lang` nobody
    # can parse is worth less than a wrong-but-valid one, and this is the only value in
    # this module that does not come from the caller.
    LANGUAGE_TAG = /\A[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*\z/.freeze

    # `LANGUAGE_TAG` already excludes every character that matters here, so this cannot
    # fire — it is belt and braces on the ONE attribute value this module interpolates,
    # and it is three characters rather than a dependency on ERB::Util, which the DB-less
    # spec run does not load. NOT `html_safe` anywhere (INV-9).
    def self.escape_attribute(value)
      value.to_s.gsub('&', '&amp;').gsub('"', '&quot;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
    private_class_method :escape_attribute
  end
end
