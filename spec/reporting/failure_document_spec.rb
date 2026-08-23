# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/reporting/failure_document'
require_relative '../../lib/redmine_reporter_dashboards/render/pdf_inspector'
require_relative '../../lib/redmine_reporter_dashboards/render/renderer'
require_relative '../../lib/redmine_reporter_dashboards/render/failure'
require_relative '../../lib/redmine_reporter_dashboards/liquid/template_renderer'

# T-30 / FR-59.
#
# --- THE GROUP THAT MATTERS IS "what may never be in one" ---
#
# T-30's acceptance asks for tests that the document contains no exception class name, no
# SQL fragment and no role, member or project id. Those examples are here, and they are
# driven with a diagnostic whose `detail` carries ALL THREE — so they are asserting that
# the field did not travel, rather than that nobody put one in.
#
# But a test can only name the strings somebody thought of, which is why the property is
# held by construction: `FailureDocument` reads `code`, `origin`, `line`, `engine`,
# `engine_version`, `duration_ms`, `correlation_id` and the template's name, and there is
# no path from `#message` or `#detail` to the page. The last example in that group is the
# one that would notice if a future edit added one.
module FailureDocumentSpecSupport
  INSPECTOR = RedmineReporterDashboards::Render::PdfInspector
  DIAGNOSTIC = RedmineReporterDashboards::Reporting::Diagnostic

  # An English-only port. `call(key, locale)`, and it ignores the locale — which is what
  # every example except the fallback group wants.
  ENGLISH = {
    label_reporter_report_failed_template: 'This template could not be rendered',
    label_reporter_report_failed_engine: 'The render engine could not produce this document',
    # F-16's fourth origin. It is here because `FailureDocument::ALL_KEYS` iterates
    # `ORIGIN_KEYS`, so an origin whose label is missing makes `every_key_drawable?` raise
    # — the closed-list mechanism this file's own comment describes, working.
    label_reporter_report_failed_assets: 'A file this report refers to could not be included',
    label_reporter_report_refused: 'This export was refused',
    label_reporter_failure_document_title: 'Report could not be generated',
    label_reporter_failure_document_generated_at: 'Generated',
    text_reporter_failure_document_notice: 'This document is not the report.',
    label_reporter_template: 'Report template',
    label_reporter_report_diagnostic_code: 'Code',
    label_reporter_report_diagnostic_line: 'Line',
    label_reporter_report_diagnostic_correlation_id: 'Correlation id',
    label_reporter_preflight_engine_version: 'Engine',
    label_reporter_preflight_duration: 'Duration',
    text_reporter_failure_document_value_unavailable:
      'This value could not be shown in this document.'
  }.freeze

  # A locale where SOME keys are drawable and some are not — Polish, measured: 7 of the 12
  # draw and 5 do not. This is the case that produced a half-English document.
  POLISH = {
    label_reporter_template: 'Szablon raportu',
    label_reporter_failure_document_generated_at: 'Utworzono',
    label_reporter_report_diagnostic_code: 'Kod',
    label_reporter_report_diagnostic_correlation_id: 'Identyfikator korelacji',
    label_reporter_preflight_duration: 'Czas trwania',
    # The two that carry a character WinAnsi cannot draw.
    label_reporter_failure_document_title: "Nie udało się wygenerować raportu",
    label_reporter_report_failed_engine: "Obsługa nie zdołała utworzyć dokumentu"
  }.freeze

  RUSSIAN = {
    label_reporter_failure_document_title: "Не удалось сформировать отчёт",
    label_reporter_report_failed_engine: "Обработчик не смог создать документ"
  }.freeze

  def self.english
    ->(key, _locale) { ENGLISH.fetch(key) }
  end

  # The real thing's shape: ask for the locale, fall through to English when the locale
  # has no entry — which is what `I18n.t` does with a fallback chain.
  def self.russian
    lambda do |key, locale|
      return RUSSIAN.fetch(key, ENGLISH.fetch(key)) if locale != :en

      ENGLISH.fetch(key)
    end
  end

  def self.polish
    lambda do |key, locale|
      return POLISH.fetch(key, ENGLISH.fetch(key)) if locale != :en

      ENGLISH.fetch(key)
    end
  end
end

RSpec.describe RedmineReporterDashboards::Reporting::FailureDocument do
  # A diagnostic carrying EVERY dangerous field a real one can carry. `detail` is what the
  # base plugin put in the document; `message` is safe by contract but is still not on the
  # page, because the document travels and the panel does not.
  let(:diagnostic) do
    FailureDocumentSpecSupport::DIAGNOSTIC.new(
      origin: :engine,
      code: :engine_crashed,
      message: 'the engine stopped before it produced a document',
      template_name: 'Weekly status',
      engine: 'chromium_cdp',
      engine_version: 'Chrome/141.0.7390.37',
      duration_ms: 812,
      correlation_id: '3a8cd94c-1f2e-4a7b-9c11-88b0d2e4f001',
      detail: 'ActiveRecord::StatementInvalid: PG::UndefinedColumn: ERROR: ' \
              'SELECT * FROM members WHERE role_id = 3 AND project_id = 17 AND user_id = 42'
    )
  end

  subject(:document) do
    described_class.new(diagnostic: diagnostic,
                        generated_at: '2026-08-08 09:14:02 UTC',
                        translate: FailureDocumentSpecSupport.english)
  end

  describe 'the filename' do
    it 'is report-FAILED-<correlation id>.pdf, so it cannot be mistaken for the report' do
      expect(document.filename)
        .to eq('report-FAILED-3a8cd94c-1f2e-4a7b-9c11-88b0d2e4f001.pdf')
    end

    # A filename reaches a Content-Disposition header and somebody's filesystem. Every id
    # this plugin mints is a UUID, so this is about a caller that hands over something
    # else — and the two literal ids that exist on refusal paths are among them.
    it 'strips anything outside a closed character set' do
      hostile = FailureDocumentSpecSupport::DIAGNOSTIC.new(
        origin: :batch, code: :resource_limit, message: 'x',
        correlation_id: "../../etc/passwd\r\nX-Evil: 1"
      )

      name = described_class.new(diagnostic: hostile, generated_at: 'now',
                                 translate: FailureDocumentSpecSupport.english).filename

      expect(name).to eq('report-FAILED-....etcpasswdX-Evil1.pdf')
      expect(name).not_to include('/')
      expect(name).not_to include("\n")
    end

    it 'falls back to a word rather than producing a bare extension' do
      empty = FailureDocumentSpecSupport::DIAGNOSTIC.new(
        origin: :batch, code: :resource_limit, message: 'x', correlation_id: '###'
      )

      expect(described_class.new(diagnostic: empty, generated_at: 'now',
                                 translate: FailureDocumentSpecSupport.english).filename)
        .to eq('report-FAILED-unknown.pdf')
    end

    it 'is served as a PDF, which is the type its bytes actually are' do
      expect(document.content_type).to eq('application/pdf')
    end
  end

  describe 'the bytes' do
    it 'are a real PDF rather than a file named one' do
      expect(document.bytes[0, 5]).to eq('%PDF-')
      expect(document.bytes).to include('%%EOF')
    end

    it 'is one page' do
      skip 'poppler-utils is not installed' unless FailureDocumentSpecSupport::INSPECTOR.available?

      expect(FailureDocumentSpecSupport::INSPECTOR.page_count(document.bytes)).to eq(1)
    end

    # The bound is asserted HERE and not only in the writer's spec, because this is the
    # artefact that gets sent: `MinimalPdf` will happily draw a 789-byte document from an
    # empty title and no rows, and what matters is that the real one clears the size every
    # engine's output in this project has to clear.
    it 'clears the minimum size this project accepts from any engine' do
      expect(document.bytes.bytesize)
        .to be > RedmineReporterDashboards::Render::Renderer::MIN_PDF_BYTES
    end

    # THE WHOLE PAGE FITS ON THE PAGE. A template name is author-controlled and the model
    # bounds it at 255 characters, which is four wrapped lines — enough to have pushed the
    # notice off the paper before the writer bounded its own layout.
    it 'keeps every line on the paper even with the longest name the model allows' do
      long = described_class.new(
        diagnostic: FailureDocumentSpecSupport::DIAGNOSTIC.new(
          origin: :engine, code: :engine_crashed, message: 'x',
          template_name: 'N' * 255, engine: 'chromium_cdp',
          engine_version: 'Chrome/141.0.7390.37', duration_ms: 9,
          correlation_id: '3a8cd94c-1f2e-4a7b-9c11-88b0d2e4f001'
        ),
        generated_at: '2026-08-08 09:14:02 UTC',
        translate: FailureDocumentSpecSupport.english
      )
      ys = long.bytes.scan(/1 0 0 1 \d+ (-?\d+) Tm/).flatten.map(&:to_i)

      expect(ys.min).to be >= RedmineReporterDashboards::Render::MinimalPdf::MARGIN
    end
  end

  describe 'what the reader is told' do
    let(:text) do
      skip 'poppler-utils is not installed' unless FailureDocumentSpecSupport::INSPECTOR.available?

      FailureDocumentSpecSupport::INSPECTOR.text(document.bytes)
    end

    it 'is titled as a failure' do
      expect(text).to include('Report could not be generated')
    end

    it 'names the template, which is FR-58s first noun' do
      expect(text).to include('Weekly status')
    end

    it 'carries the correlation id, which is the whole point of the artefact' do
      expect(text).to include('3a8cd94c-1f2e-4a7b-9c11-88b0d2e4f001')
    end

    it 'carries the closed-set code rather than free text' do
      expect(text).to include('engine_crashed')
    end

    it 'names the engine and its version' do
      expect(text).to include('chromium_cdp')
      expect(text).to include('Chrome/141.0.7390.37')
    end

    it 'says in as many words that this is not the report' do
      expect(text).to include('This document is not the report.')
    end

    it 'headlines with the same sentence the interactive panel uses for this origin' do
      expect(text).to include('The render engine could not produce this document')
    end
  end

  # ---------------------------------------------------------------- the safety group
  describe 'what may never be in one' do
    let(:text) do
      skip 'poppler-utils is not installed' unless FailureDocumentSpecSupport::INSPECTOR.available?

      FailureDocumentSpecSupport::INSPECTOR.text(document.bytes)
    end

    it 'contains no exception class name' do
      expect(text).not_to include('ActiveRecord::StatementInvalid')
      expect(text).not_to include('PG::UndefinedColumn')
      expect(text).not_to match(/[A-Za-z]+::[A-Za-z]+Error/)
    end

    it 'contains no SQL fragment' do
      expect(text).not_to include('SELECT')
      expect(text).not_to include('FROM members')
      expect(text).not_to match(/\bWHERE\b/)
    end

    it 'contains no role, member or project id' do
      expect(text).not_to include('role_id')
      expect(text).not_to include('project_id')
      expect(text).not_to include('user_id')
    end

    it 'contains the detail field nowhere at all, byte for byte' do
      expect(document.bytes).not_to include('StatementInvalid')
      expect(document.bytes).not_to include('role_id')
    end

    # THE ONE THAT NOTICES A FUTURE EDIT rather than a payload somebody thought of.
    # `message` is safe by contract and is still absent, because the document travels
    # further than the panel does. If a later change puts it back, this fails and the
    # three examples above go on passing.
    it 'does not carry the diagnostic message either, safe though it is' do
      expect(document.bytes).not_to include('the engine stopped before it produced')
    end
  end

  describe 'a locale the base-14 fonts cannot draw' do
    subject(:document) do
      described_class.new(diagnostic: diagnostic,
                          generated_at: '2026-08-08 09:14:02 UTC',
                          translate: FailureDocumentSpecSupport.russian,
                          locale: :ru)
    end

    it 'produces a document rather than raising' do
      expect { document.bytes }.not_to raise_error
    end

    it 'says it fell back, so the log line is not a guess' do
      expect(document.locale_degraded?).to be(true)
    end

    it 'draws the WHOLE document in English rather than a line of it' do
      skip 'poppler-utils is not installed' unless FailureDocumentSpecSupport::INSPECTOR.available?

      expect(FailureDocumentSpecSupport::INSPECTOR.text(document.bytes))
        .to include('Report could not be generated')
    end

    it 'does not claim a fallback when the locale is drawable' do
      drawable = described_class.new(diagnostic: diagnostic,
                                     generated_at: 'now',
                                     translate: FailureDocumentSpecSupport.english,
                                     locale: :de)

      expect(drawable.locale_degraded?).to be(false)
    end
  end

  # A PARTIALLY DRAWABLE LOCALE IS THE INTERESTING CASE, and per-key fallback got it
  # wrong: measured across the nine shipped locales, Polish draws 7 of 12 keys and
  # Hungarian 8 of 12, so the first version produced a Polish document with an English
  # title and an English closing paragraph. A document half in each language is worse than
  # either whole one, and this is the artefact that travels.
  describe 'a locale the fonts can only half draw' do
    subject(:document) do
      described_class.new(diagnostic: diagnostic,
                          generated_at: '2026-08-08 09:14:02 UTC',
                          translate: FailureDocumentSpecSupport.polish,
                          locale: :pl)
    end

    let(:text) do
      skip 'poppler-utils is not installed' unless FailureDocumentSpecSupport::INSPECTOR.available?

      FailureDocumentSpecSupport::INSPECTOR.text(document.bytes)
    end

    it 'says it fell back' do
      expect(document.locale_degraded?).to be(true)
    end

    it 'draws the labels it COULD have drawn in Polish in English instead' do
      expect(text).to include('Report template')
      expect(text).not_to include('Szablon raportu')
    end

    it 'is not a mixture: no Polish string survives anywhere in the document' do
      %w[Utworzono Kod Identyfikator].each do |polish|
        expect(text).not_to include(polish)
      end
    end
  end

  # A VALUE HAS NO SECOND LANGUAGE TO FALL BACK TO. A Cyrillic template name is a template
  # a Russian installation has, and `MinimalPdf.build` raises on it — which would turn
  # "your report failed" into a 500 on exactly the install that needed the document.
  describe 'a value the fonts cannot draw' do
    let(:diagnostic) do
      FailureDocumentSpecSupport::DIAGNOSTIC.new(
        origin: :template, code: :syntax_error, message: 'x',
        template_name: "Еженедельный отчёт", correlation_id: 'cid-1'
      )
    end

    it 'produces a document rather than raising' do
      expect { document.bytes }.not_to raise_error
    end

    it 'marks the run as degraded rather than pretending the name was drawn' do
      expect(document.locale_degraded?).to be(true)
    end

    it 'still carries the correlation id, which is what identifies the run' do
      skip 'poppler-utils is not installed' unless FailureDocumentSpecSupport::INSPECTOR.available?

      expect(FailureDocumentSpecSupport::INSPECTOR.text(document.bytes)).to include('cid-1')
    end

    # IT DOES NOT BECOME A ROW OF QUESTION MARKS, which is what the first version drew —
    # `???????????? ????? ?` — while both this class's comment and `MinimalPdf`'s said in
    # as many words that this code does not do that.
    it 'replaces the value with one sentence rather than one ? per character' do
      skip 'poppler-utils is not installed' unless FailureDocumentSpecSupport::INSPECTOR.available?

      text = FailureDocumentSpecSupport::INSPECTOR.text(document.bytes)

      expect(text).to include('This value could not be shown in this document.')
      expect(text).not_to match(/\?{3}/)
    end
  end

  describe 'the origin vocabulary' do
    # THE MAP IS CLOSED AND `fetch` IS WHAT KEEPS IT CLOSED. `Diagnostic::ORIGINS` is the
    # authority; a fourth origin added there without a sentence here must fail loudly
    # rather than draw a document with a blank headline.
    it 'has a sentence for every origin a diagnostic can have' do
      expect(described_class::ORIGIN_KEYS.keys)
        .to match_array(FailureDocumentSpecSupport::DIAGNOSTIC::ORIGINS)
    end

    it 'raises rather than drawing a blank headline for an origin it does not know' do
      unknown = Struct.new(:origin, :code, :line, :engine, :engine_version, :duration_ms,
                           :correlation_id, :template_name, keyword_init: true)
                      .new(origin: :invented, code: :x, correlation_id: 'c',
                           template_name: 't')

      expect do
        described_class.new(diagnostic: unknown, generated_at: 'now',
                            translate: FailureDocumentSpecSupport.english).bytes
      end.to raise_error(KeyError)
    end
  end
end
