# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/reporting/diagnostic'
require_relative '../../lib/redmine_reporter_dashboards/reporting/report_run'

# T-23 / FR-58. The one place two failure vocabularies become one panel.
#
# The example that matters most is the last group: §7b.3's whole complaint about the base
# plugin is that the exception message reached the reader — SQL fragments, role ids,
# project ids — because the message *was* the document. `detail` is that text, and it must
# not be able to travel.
# Namespaced for HANDOVER §1's reason — see the comment in `exchange_spec.rb`. `DiagnosticSpecSupport::RF` in
# particular is exactly the kind of two-letter name a second spec file would also want.
module DiagnosticSpecSupport
  TRF = RedmineReporterDashboards::Liquid::TemplateRenderer::Failure
  RF = RedmineReporterDashboards::Render::Failure
end

RSpec.describe RedmineReporterDashboards::Reporting::Diagnostic do

  describe '.from_template_failure' do
    let(:failure) do
      DiagnosticSpecSupport::TRF.new(code: :syntax_error, message: 'unexpected end', line: 12,
              duration_ms: 4, detail: 'Liquid::SyntaxError at users.name = 1 OR 1=1',
              correlation_id: 'cid-a')
    end

    it 'is a TEMPLATE diagnostic, which is what chooses the headline the author reads' do
      expect(described_class.from_template_failure(failure).origin).to eq(:template)
    end

    it 'keeps the Liquid line, which is the only actionable field for an author' do
      expect(described_class.from_template_failure(failure).line).to eq(12)
    end

    it 'names no engine, because no engine was involved' do
      expect(described_class.from_template_failure(failure).engine).to be_nil
    end

    it 'falls back to the caller`s correlation id when the failure carries none' do
      bare = DiagnosticSpecSupport::TRF.new(code: :internal, message: 'x')

      expect(described_class.from_template_failure(bare, correlation_id: 'cid-b')
                            .correlation_id).to eq('cid-b')
    end
  end

  describe '.from_render_failure' do
    let(:failure) do
      DiagnosticSpecSupport::RF.new(code: :engine_crashed, message: 'the browser went away',
             engine: 'chromium_cdp', engine_version: '141', duration_ms: 900,
             detail: 'EPIPE on /tmp/x', correlation_id: 'cid-c')
    end

    it 'is an ENGINE diagnostic and carries engine and version, which FR-58 names' do
      diagnostic = described_class.from_render_failure(failure)

      expect(diagnostic.origin).to eq(:engine)
      expect(diagnostic.engine).to eq('chromium_cdp')
      expect(diagnostic.engine_version).to eq('141')
    end

    it 'never has a Liquid line, because a crashed browser has no line' do
      expect(described_class.from_render_failure(failure).line).to be_nil
    end
  end

  describe '.from_batch_refusal' do
    let(:refusal) do
      RedmineReporterDashboards::Render::BatchGuard.new(max_documents: 2)
                                                   .cap_refusal_for_count(9)
    end

    it 'is a BATCH diagnostic even though the object is a Render::Failure' do
      # Same class, different origin. Nothing was drawn, no engine was started, and the
      # remedy is "select fewer" rather than "check the engine" — so presenting it as an
      # engine failure would send the reader to the wrong place.
      expect(described_class.from_batch_refusal(refusal).origin).to eq(:batch)
    end

    it 'names no engine, because none ran' do
      expect(described_class.from_batch_refusal(refusal).engine).to be_nil
    end

    it 'keeps the message with both numbers in it' do
      expect(described_class.from_batch_refusal(refusal).message)
        .to include('9 documents', 'the limit is 2')
    end
  end

  describe 'what may leave this object' do
    let(:diagnostic) do
      described_class.new(origin: :template, code: :runtime_error, message: 'safe summary',
                          correlation_id: 'cid-d',
                          detail: "PG::UndefinedColumn: SELECT * FROM issues WHERE " \
                                  'project_id IN (4,7) AND role_id = 3')
    end

    it 'CANNOT serialise the raw detail, which is §7b.3`s entire complaint' do
      # A mail, a failure PDF (T-30) or an API response all go through `to_h`. Whatever
      # they do with it, they cannot leak SQL, role ids or project ids through this
      # object, because the Hash has no field to carry them in.
      serialised = diagnostic.to_h

      expect(serialised).not_to have_key('detail')
      expect(serialised.values.join(' ')).not_to include('PG::UndefinedColumn', 'role_id',
                                                         'project_id')
    end

    it 'still exposes the detail on the object, for the log' do
      expect(diagnostic.detail).to include('PG::UndefinedColumn')
    end

    it 'serialises every field FR-58 names' do
      # `template` was added by T-30. FR-58's list is *"what failed, THE TEMPLATE, the
      # Liquid line where applicable, engine and version, duration and a correlation
      # id"*, and it was the one noun this object did not carry — so a failure document
      # or a mail built from `to_h` could not name the report it was about.
      expect(diagnostic.to_h.keys)
        .to eq(%w[origin code message template line engine engine_version duration_ms
                  correlation_id])
    end

    # AND `detail` IS STILL NOT AMONG THEM. Adding a field to this Hash is the moment the
    # question gets asked again, so it is asserted next to the addition rather than three
    # examples away.
    it 'still refuses to serialise the detail' do
      expect(diagnostic.to_h.keys).not_to include('detail')
      expect(diagnostic.to_h.values.map(&:to_s).join(' ')).not_to include('PG::')
    end

    it 'is frozen, so a view cannot edit the record of what went wrong' do
      expect(diagnostic).to be_frozen
    end
  end

  describe 'the closed origin set' do
    it 'refuses an origin the views have no branch for' do
      expect do
        described_class.new(origin: :something_else, code: :x, message: 'y',
                            correlation_id: 'z')
      end.to raise_error(ArgumentError, /not a diagnostic origin/)
    end
  end
end
