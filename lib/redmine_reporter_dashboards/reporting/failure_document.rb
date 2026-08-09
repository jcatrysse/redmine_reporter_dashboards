# frozen_string_literal: true

require_relative 'diagnostic'
require_relative '../render/minimal_pdf'

module RedmineReporterDashboards
  module Reporting
    # T-30 / FR-59 — the optional failure document.
    #
    # `Render::MinimalPdf` decides what a PDF looks like. This decides **what may be in
    # one**, which is the half with the security weight, and the split is the same one
    # T-14 made between `PdfInspector` (reading) and `PdfProbe` (policy): keep the
    # mechanism in one place and the policy in its caller, so the two cannot drift.
    #
    # --- THE SUMMARY IS BUILT FROM THE CODE, NEVER FROM THE MESSAGE ---
    #
    # T-30's acceptance says the tests must assert the document contains no exception
    # class name, no SQL fragment and no role, member or project id. A test can only
    # assert that about the strings it happens to think of. So the property is held by
    # CONSTRUCTION instead: the only fields that reach the page are
    #
    #   * `code`           — a member of three closed sets (`Render::Failure::CODES`,
    #                        `TemplateRenderer::FAILURE_CODES` and the three this plugin
    #                        adds), so it is a vocabulary rather than text;
    #   * `origin`         — one of three symbols, resolved to a translated sentence;
    #   * `line`           — an Integer;
    #   * `engine`, `engine_version`, `duration_ms` — the adapter's own name and version;
    #   * `correlation_id` — a UUID this plugin minted;
    #   * the template's name, which the requester already had to be able to see.
    #
    # `Diagnostic#message` is NOT among them, and neither is `#detail`. `message` is safe
    # by contract and is what the interactive panel prints; `detail` is the raw exception
    # and `Diagnostic#to_h` already refuses to carry it. The document is the artefact that
    # TRAVELS, so it gets the narrower set, and the assertion the plan asks for then holds
    # for payloads nobody thought of as well as the ones they did.
    #
    # --- THE FILENAME IS PART OF THE REQUIREMENT ---
    #
    # `report-FAILED-<correlation-id>.pdf`, "so it can never be mistaken for the report"
    # (§7b.3). The id is filtered to a closed character set for the same reason
    # `TemplatesController#download_filename` filters a template name: a filename reaches
    # a `Content-Disposition` header and somebody's filesystem. Every id this plugin mints
    # is a UUID and passes through untouched; the two literal ids that exist on refusal
    # paths (`'batch'`, `'-'`) also do; anything else is a caller this filter is here for.
    class FailureDocument
      FILENAME_PREFIX = 'report-FAILED-'

      # Reused rather than reinvented: these are the sentences the interactive panel
      # already headlines with (`ReporterDashboards::TemplatesHelper#reporter_diagnostic_headline`),
      # so an operator holding the PDF and an author looking at the editor read the same
      # words for the same failure. A second vocabulary for the same states is how two
      # descriptions of one event start disagreeing.
      #
      # IT IS NOW THE SAME OBJECT AND NOT A MATCHING COPY. This was a literal Hash whose
      # three rows happened to equal the helper's three `when` arms, and "happened to" is
      # the whole problem — F-16's `:assets` origin was added to `Diagnostic::ORIGINS` and
      # both copies needed finding. `Diagnostic` owns the set, so it owns the labels.
      ORIGIN_KEYS = Diagnostic::ORIGIN_LABEL_KEYS

      # Every string on the page, in order. A closed list because `build` iterates it: a
      # key added here without a translation is a missing label, and the locale parity
      # spec is what catches that.
      TITLE_KEY = :label_reporter_failure_document_title
      NOTICE_KEY = :text_reporter_failure_document_notice
      TEMPLATE_KEY = :label_reporter_template
      GENERATED_KEY = :label_reporter_failure_document_generated_at
      CODE_KEY = :label_reporter_report_diagnostic_code
      LINE_KEY = :label_reporter_report_diagnostic_line
      CORRELATION_KEY = :label_reporter_report_diagnostic_correlation_id
      ENGINE_KEY = :label_reporter_preflight_engine_version
      DURATION_KEY = :label_reporter_preflight_duration
      UNDRAWABLE_KEY = :text_reporter_failure_document_value_unavailable

      # Every key that can appear on the page, so `effective_locale` can ask about the
      # document as a whole rather than one string at a time. The three origin sentences
      # are all in it because the locale decision must not depend on which failure this is.
      ALL_KEYS = (ORIGIN_KEYS.values + [TITLE_KEY, NOTICE_KEY, TEMPLATE_KEY, GENERATED_KEY,
                                        CODE_KEY, LINE_KEY, CORRELATION_KEY, ENGINE_KEY,
                                        DURATION_KEY, UNDRAWABLE_KEY]).freeze

      attr_reader :diagnostic, :generated_at, :locale

      # translate  a REQUIRED port, `call(key, locale)` -> String. Required and with no
      #            default for the same reason `Runner`'s `delivery:` is: this class runs
      #            in the DB-less suite where there is no Redmine and no `I18n`, and a
      #            default would either drag one in or quietly ship an English-only
      #            document that nobody would notice until a Russian operator opened it.
      def initialize(diagnostic:, generated_at:, translate:, locale: :en)
        @diagnostic = diagnostic
        @generated_at = generated_at
        @translate = translate
        @locale = locale
        @fell_back = false
      end

      def filename
        "#{FILENAME_PREFIX}#{safe_id}.pdf"
      end

      def content_type
        'application/pdf'
      end

      def bytes
        @bytes ||= ::RedmineReporterDashboards::Render::MinimalPdf.build(title: title,
                                                                          rows: rows)
      end

      # Whether any string on the page had to be taken from English because the requested
      # locale could not be drawn (see `MinimalPdf`'s encoding note). Answered AFTER
      # `bytes`, and the caller records it as a degradation rather than the document
      # pretending it was written in the locale it says it was.
      def locale_degraded?
        bytes
        @fell_back
      end

      private

      def title
        text(TITLE_KEY)
      end

      # THE VALUES ARE ENCODABILITY-CHECKED TOO, NOT ONLY THE LABELS. A template named in
      # Cyrillic is a template a Russian installation has, and `MinimalPdf.build` would
      # raise `Encoding::UndefinedConversionError` on it — turning "your report failed"
      # into a 500. The name is replaced with a marker in that one case, which is visible
      # and survivable, and the correlation id below it is what identifies the run anyway.
      def rows
        list = []
        # The headline first, full width: the reader's first question is "what happened",
        # and a label column answers "which template" before it answers that.
        list << [nil, text(ORIGIN_KEYS.fetch(diagnostic.origin))]
        # READ OFF THE DIAGNOSTIC, not passed in beside it. The panel and this document
        # must name the same template, and two arguments for one fact is how they stop.
        list << [text(TEMPLATE_KEY), value(diagnostic.template_name)]
        list << [text(GENERATED_KEY), value(generated_at)]
        list << [text(CODE_KEY), value(diagnostic.code)]
        list << [text(LINE_KEY), value(diagnostic.line)] if diagnostic.line
        if diagnostic.engine
          list << [text(ENGINE_KEY),
                   value([diagnostic.engine, diagnostic.engine_version].compact.join(' '))]
        end
        list << [text(DURATION_KEY), value("#{diagnostic.duration_ms} ms")] if diagnostic.duration_ms
        list << [text(CORRELATION_KEY), value(diagnostic.correlation_id)]
        list << [nil, text(NOTICE_KEY)]
        list
      end

      # THE LANGUAGE IS DECIDED ONCE, FOR THE WHOLE DOCUMENT, and the first version decided
      # it per key. Measured by the independent review across the nine shipped locales:
      #
      #   de en es it pt-BR  12/12 keys drawable
      #   hu                  8/12   (title, notice, duration, failed_engine undrawable)
      #   pl                  7/12
      #   ru zh               0/12
      #
      # Per-key fallback therefore produced a Polish document with an English title and an
      # English closing paragraph, and a Hungarian one whose only English word was
      # "Duration". A document half in each language is worse than either whole one, and
      # this is the artefact that TRAVELS. So: if any string on the page cannot be drawn in
      # the requested locale, the whole document is drawn in English and `locale_degraded?`
      # says so.
      def effective_locale
        return @effective_locale if defined?(@effective_locale)

        @effective_locale = if locale.to_s == 'en' || every_key_drawable?(locale)
                              locale
                            else
                              @fell_back = true
                              :en
                            end
      end

      def every_key_drawable?(candidate)
        ALL_KEYS.all? do |key|
          ::RedmineReporterDashboards::Render::MinimalPdf
            .encodable?(@translate.call(key, candidate).to_s)
        end
      end

      def text(key)
        string = @translate.call(key, effective_locale).to_s
        return string if ::RedmineReporterDashboards::Render::MinimalPdf.encodable?(string)

        # An English string this writer cannot draw is a defect in the locale file rather
        # than a property of the language, so it is not silently dropped either.
        @fell_back = true
        string.encode(::RedmineReporterDashboards::Render::MinimalPdf::ENCODING,
                      invalid: :replace, undef: :replace, replace: '?')
      end

      # A VALUE HAS NO SECOND LANGUAGE TO FALL BACK TO, AND IT DOES NOT BECOME `?????`.
      # The first version encoded with `replace: '?'`, so a Cyrillic template name came out
      # as `???????????? ????? ?` — which is exactly the "page of question marks" both this
      # file and `MinimalPdf` say in as many words that this code does not produce. One
      # explicit sentence instead: the reader is told the value could not be shown, and the
      # correlation id below it is what identifies the run anyway.
      def value(raw)
        string = raw.to_s
        return string if ::RedmineReporterDashboards::Render::MinimalPdf.encodable?(string)

        @fell_back = true
        text(UNDRAWABLE_KEY)
      end

      def safe_id
        cleaned = diagnostic.correlation_id.to_s.gsub(/[^0-9A-Za-z._-]+/, '')
        cleaned.empty? ? 'unknown' : cleaned[0, 80]
      end
    end
  end
end
