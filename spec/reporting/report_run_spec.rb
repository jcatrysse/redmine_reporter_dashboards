# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/reporting/report_run'

# T-23 — the decisions a run makes ABOUT a render, driven without one.
#
# The real Liquid render and the real engine are exercised end to end in the full
# application suite (`test/functional/reporter_dashboards_templates_controller_test.rb`),
# where there is a Redmine to boot and issues to report on. What is asserted HERE is
# everything that is a decision rather than a render, because each of these is a branch a
# functional test reaches only by accident:
#
#   * the cap is asked BEFORE anything is loaded (T-15's owed refusal, at its source);
#   * the truncation arithmetic §9b.2's "preview of 50 of 1 284" is printed from;
#   * a template failure aborts the run rather than producing a partial export;
#   * an absent engine is reported, never skipped (§9b.2's "false signal");
#   * a `source` this version cannot render is refused rather than answered from the
#     wrong table.
# HOISTED OUT OF THE `describe` BLOCK AND NAMESPACED, and HANDOVER §1 is why: a constant
# assigned inside `RSpec.describe` is assigned at the file's TOP LEVEL, because the block
# is a closure whose lexical scope is the file. `ReportRunSpecSupport::FakeIssue` inside a describe is
# `Object::FakeIssue` for the whole process, and the collision passes in isolation and
# fails only in the randomised full run — which cost this project two examples once
# already. Everything this file needs lives in one module named after the file.
module ReportRunSpecSupport
  # NO `unless defined?` GUARD. `Guard` inside a module body resolves through
  # Object first, so a top-level constant of the same name anywhere in the suite
  # would make the assignment a silent no-op and every use below a NameError —
  # the guard would create the failure it looks like it prevents.
  Guard = RedmineReporterDashboards::Render::BatchGuard
  TR = RedmineReporterDashboards::Liquid::TemplateRenderer

  # An issue relation that counts, limits and materialises, and knows its own SQL —
  # `RenderContext#same_scope?` compares by `to_sql` (finding E-13), so a double without
  # one silently becomes a second Batch.
  class FakeScope
    attr_reader :limit_value, :count_calls, :materialised

    def initialize(size, limit_value: nil)
      @size = size
      @limit_value = limit_value
      @count_calls = 0
      @materialised = false
    end

    def count
      @count_calls += 1
      @size
    end

    def limit(value)
      self.class.new(@size, limit_value: value)
    end

    def to_a
      @materialised = true
      Array.new([@size, @limit_value || @size].min) { |i| FakeIssue.new(i + 1) }
    end

    def to_sql
      "SELECT * FROM issues LIMIT #{@limit_value.inspect}"
    end
  end

  FakeIssue = Struct.new(:id)

  FakeTemplateRecord = Struct.new(:id, :name, :content, :source, :output, :orientation,
                                  :page_size, :margins, :project,
                                  keyword_init: true) do
    def engine_hint_or_nil
      nil
    end
  end

  # Answers `#render` the way `TemplateRenderer` does, and counts. The count is the
  # assertion for "nothing was rendered", which is the only way to tell a refusal that
  # refused from a refusal that happened to come back empty.
  class CountingRenderer
    attr_reader :calls

    def initialize(result_for: nil)
      @calls = 0
      @result_for = result_for
    end

    def render(_source, **_kwargs)
      @calls += 1
      @result_for ? @result_for.call(@calls) : TR::Document.new(body: "<p>#{@calls}</p>",
                                                                duration_ms: 1,
                                                                output_class: :report)
    end
  end

  # An ENGINE ADAPTER stand-in. The real `Render::Renderer` wraps it, so capability
  # negotiation and INV-5's `%PDF-`…`%%EOF` post-condition both really run — which is
  # deliberate: this file is about the branch around the adapter, and a fake that
  # bypassed the wrapper would let a run "succeed" on bytes the wrapper would refuse.
  class FakeAdapter
    class << self
      attr_accessor :behaviour
    end

    # An empty set: this document declares no required or essential capabilities, so
    # negotiation passes and no degradation is recorded.
    def capabilities
      []
    end

    def id
      'fake'
    end

    def render(request)
      self.class.behaviour.call(request)
    end
  end

  # Over `Renderer::MIN_PDF_BYTES`, because the wrapper refuses a document at or under
  # it as `:output_empty`. A "PDF" of forty bytes is what a crashed engine produces.
  PDF_BYTES = "%PDF-1.4\n#{'0' * 2_000}\n%%EOF"
end

RSpec.describe RedmineReporterDashboards::Reporting::ReportRun do
  let(:actor) { double('User', id: 3, logged?: true) }
  let(:guard) { ReportRunSpecSupport::Guard.new(max_documents: 5) }

  def template(overrides = {})
    ReportRunSpecSupport::FakeTemplateRecord.new(
      **{ id: 1, name: 'T', content: 'x', source: 'issues', output: 'combined',
          orientation: 'portrait', page_size: 'A4', margins: nil,
          project: nil }.merge(overrides)
    )
  end

  def run(scope:, renderer: ReportRunSpecSupport::CountingRenderer.new, **overrides)
    described_class.new(**{ template: template, actor: actor, scope: scope,
                            guard: guard, template_renderer: renderer }.merge(overrides))
  end

  describe 'the cap, which is where T-15 owed a refusal' do
    it 'refuses a per-record run over the cap and renders NOTHING' do
      scope = ReportRunSpecSupport::FakeScope.new(9)
      renderer = ReportRunSpecSupport::CountingRenderer.new
      outcome = run(scope: scope, renderer: renderer,
                    template: template(output: 'per_record')).call

      expect(outcome).not_to be_ok
      expect(renderer.calls).to eq(0)
      expect(outcome.diagnostic.origin).to eq(:batch)
    end

    it 'names both numbers in the refusal, which is the whole point of the message' do
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(9),
                    template: template(output: 'per_record')).call

      expect(outcome.diagnostic.message).to include('9 documents', 'the limit is 5')
    end

    it 'never materialises the scope when it refuses' do
      # `cap_refusal_for_count` exists so the refusal costs one COUNT(*) rather than
      # 40 000 ActiveRecord objects. If this ever fails, the cap still "works" and the
      # memory it exists to save is being spent anyway.
      scope = ReportRunSpecSupport::FakeScope.new(9)
      run(scope: scope, template: template(output: 'per_record')).call

      expect(scope.materialised).to be(false)
    end

    it 'allows exactly the cap, and refuses one past it' do
      at_cap = run(scope: ReportRunSpecSupport::FakeScope.new(5), template: template(output: 'per_record')).call
      past = run(scope: ReportRunSpecSupport::FakeScope.new(6), template: template(output: 'per_record')).call

      expect(at_cap).to be_ok
      expect(past).not_to be_ok
    end

    it 'never refuses a combined report, however many issues it reads' do
      # A combined report is ONE document over any number of rows, so the document cap
      # has nothing to say about it. Conflating "documents" with "issues" here would cap
      # a perfectly ordinary quarterly report at five issues.
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(40_000)).call

      expect(outcome).to be_ok
    end
  end

  describe 'the preview bound, which §9b.2 requires to be visible' do
    let(:preview_guard) { ReportRunSpecSupport::Guard.new(max_documents: 500) }

    def preview(size, output: 'combined')
      described_class.preview(template: template(output: output), actor: actor,
                              scope: ReportRunSpecSupport::FakeScope.new(size), guard: preview_guard,
                              template_renderer: ReportRunSpecSupport::CountingRenderer.new).call
    end

    it 'reports the bound and the total for a combined preview' do
      outcome = preview(1_284)

      expect(outcome.shown_count).to eq(described_class::PREVIEW_MAX_ISSUES)
      expect(outcome.total_count).to eq(1_284)
      expect(outcome).to be_truncated
    end

    it 'draws exactly one document for a per-record preview, and says so' do
      # A PER-RECORD PREVIEW DRAWS ONE DOCUMENT, NOT FIFTY, and the difference is a
      # denial of service rather than a nicety: fifty PDF renders in one synchronous
      # request, bounded only by `BatchGuard`'s five-minute deadline, is a worker any
      # member holding one authoring permission could hold for five minutes by pressing
      # Preview. Found by the independent review of T-23.
      outcome = preview(1_284, output: 'per_record')

      expect(outcome.shown_count).to eq(described_class::PREVIEW_MAX_DOCUMENTS)
      expect(outcome.sections.length).to eq(1)
      expect(outcome.total_count).to eq(1_284)
      expect(outcome).to be_truncated
    end

    it 'is not truncated when everything fits, so the notice is not always shown' do
      expect(preview(3)).not_to be_truncated
      expect(preview(described_class::PREVIEW_MAX_ISSUES)).not_to be_truncated
    end

    it 'renders one template for a per-record preview, not fifty' do
      renderer = ReportRunSpecSupport::CountingRenderer.new
      described_class.preview(template: template(output: 'per_record'), actor: actor,
                              scope: ReportRunSpecSupport::FakeScope.new(1_284),
                              guard: preview_guard,
                              template_renderer: renderer).call

      expect(renderer.calls).to eq(described_class::PREVIEW_MAX_DOCUMENTS)
    end

    # A COMBINED preview still reads fifty issues: there is one document either way, so
    # the thing being bounded is what the collection drop sees, which is §9b.2's number.
    it 'still reads up to fifty issues for a combined preview' do
      renderer = ReportRunSpecSupport::CountingRenderer.new
      outcome = described_class.preview(template: template, actor: actor,
                                        scope: ReportRunSpecSupport::FakeScope.new(1_284),
                                        guard: preview_guard,
                                        template_renderer: renderer).call

      expect(renderer.calls).to eq(1)
      expect(outcome.shown_count).to eq(described_class::PREVIEW_MAX_ISSUES)
    end

    it 'gives a preview the preview execution limits, not a report`s' do
      # `ExecutionPolicy` deliberately gives preview the WIDGET's limits: an author
      # should feel a runaway template at the keyboard rather than at 06:00. If this
      # class asked for `:report` the limit would be eight times looser than the one the
      # scheduled run will apply.
      built = described_class.preview(template: template, actor: actor,
                                      scope: ReportRunSpecSupport::FakeScope.new(1), guard: preview_guard)

      expect(built.output_class).to eq(:preview)
    end
  end

  describe 'a template that fails' do
    let(:failure) do
      ReportRunSpecSupport::TR::Failure.new(code: :syntax_error, message: 'unexpected end of template',
                      line: 12, correlation_id: 'cid-1')
    end

    it 'answers a diagnostic carrying the Liquid line, which FR-58 names' do
      renderer = ReportRunSpecSupport::CountingRenderer.new(result_for: ->(_n) { failure })
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1), renderer: renderer).call

      expect(outcome.diagnostic.origin).to eq(:template)
      expect(outcome.diagnostic.line).to eq(12)
      expect(outcome.diagnostic.correlation_id).to eq('cid-1')
    end

    it 'ABORTS a per-record run at the first failure rather than exporting holes' do
      # One template produces every document, so a failure is "this template does not
      # work" and not "document 2 is missing". Rendering the rest would hand somebody a
      # partial export with no way to tell which rows are absent.
      renderer = ReportRunSpecSupport::CountingRenderer.new(result_for: lambda { |n|
        n == 2 ? failure : ReportRunSpecSupport::TR::Document.new(body: 'ok', duration_ms: 1, output_class: :report)
      })
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(4), renderer: renderer,
                    template: template(output: 'per_record')).call

      expect(outcome).not_to be_ok
      expect(renderer.calls).to eq(2)
      expect(outcome.documents).to be_empty
    end

    it 'never attempts the PDF once the HTML failed' do
      renderer = ReportRunSpecSupport::CountingRenderer.new(result_for: ->(_n) { failure })
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1), renderer: renderer).call(pdf: true)

      expect(outcome).not_to be_pdf_attempted
    end
  end

  describe 'the PDF half' do
    around do |example|
      RedmineReporterDashboards::Render::Registry.isolated { example.run }
    end

    it 'reports an absent engine instead of quietly returning the HTML' do
      # §9b.2: "a preview that only proves the easy path is a false signal". With no
      # engine there is no PDF, and the one thing this must not do is say nothing.
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1)).call(pdf: true)

      expect(outcome).not_to be_ok
      expect(outcome.diagnostic.code).to eq(:engine_unavailable)
      expect(outcome).to be_pdf_attempted
    end

    it 'keeps the HTML it already rendered when the PDF half fails' do
      # The author still gets to see what their template produced; losing it would make
      # a missing engine look like a broken template.
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1)).call(pdf: true)

      expect(outcome.sections.length).to eq(1)
    end

    it 'answers an engine failure as an ENGINE diagnostic, not a template one' do
      ReportRunSpecSupport::FakeAdapter.behaviour = lambda do |request|
        RedmineReporterDashboards::Render::Failure.new(
          code: :engine_crashed, message: 'the browser went away',
          correlation_id: request.correlation_id, engine: 'fake', engine_version: '1.0'
        )
      end
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1), engine: ReportRunSpecSupport::FakeAdapter).call(pdf: true)

      expect(outcome.diagnostic.origin).to eq(:engine)
      expect(outcome.diagnostic.engine).to eq('fake')
    end

    it 'answers the bytes and the engine when everything worked' do
      ReportRunSpecSupport::FakeAdapter.behaviour = lambda do |request|
        RedmineReporterDashboards::Render::Success.new(
          bytes: ReportRunSpecSupport::PDF_BYTES, engine: 'fake',
          engine_version: '1.0'
        )
      end
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1), engine: ReportRunSpecSupport::FakeAdapter).call(pdf: true)

      expect(outcome).to be_ok
      expect(outcome.documents.length).to eq(1)
      expect(outcome.engine_id).to eq('fake')
    end

    it 'carries the template`s page geometry into the request' do
      seen = nil
      ReportRunSpecSupport::FakeAdapter.behaviour = lambda do |request|
        seen = request
        RedmineReporterDashboards::Render::Success.new(
          bytes: ReportRunSpecSupport::PDF_BYTES, engine: 'fake',
          engine_version: '1.0'
        )
      end
      run(scope: ReportRunSpecSupport::FakeScope.new(1), engine: ReportRunSpecSupport::FakeAdapter,
          template: template(page_size: 'A3', orientation: 'landscape',
                             margins: '10,11,12,13')).call(pdf: true)

      expect(seen.page_size).to eq('A3')
      expect(seen).to be_landscape
      expect(seen.margins_mm)
        .to eq('top' => 10, 'right' => 11, 'bottom' => 12, 'left' => 13)
    end

    it 'falls back to the request`s own default margins rather than inventing one' do
      seen = nil
      ReportRunSpecSupport::FakeAdapter.behaviour = lambda do |request|
        seen = request
        RedmineReporterDashboards::Render::Success.new(
          bytes: ReportRunSpecSupport::PDF_BYTES, engine: 'fake',
          engine_version: '1.0'
        )
      end
      run(scope: ReportRunSpecSupport::FakeScope.new(1), engine: ReportRunSpecSupport::FakeAdapter,
          template: template(margins: '')).call(pdf: true)

      expect(seen.margins_mm)
        .to eq(RedmineReporterDashboards::Render::DocumentRequest::DEFAULT_MARGINS_MM)
    end
  end

  describe 'a source this version cannot render' do
    it 'refuses a time-entry template rather than reporting on issues' do
      # T-22 built the column and T-31 gives it a scope. Between them the value can
      # exist — an import can create one — and rendering it against the ISSUE scope
      # would be a report about the wrong table that looks entirely correct.
      renderer = ReportRunSpecSupport::CountingRenderer.new
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(3), renderer: renderer,
                    template: template(source: 'time_entries')).call

      expect(outcome).not_to be_ok
      expect(outcome.diagnostic.code).to eq(:unsupported_source)
      expect(outcome.diagnostic.message).to include('T-31')
      expect(renderer.calls).to eq(0)
    end
  end

  describe 'the arguments it refuses to be built with' do
    it 'needs an actor, because INV-1 is lost by a default argument' do
      expect { described_class.new(template: template, actor: nil, scope: nil, guard: guard) }
        .to raise_error(ArgumentError, /actor/)
    end

    it 'refuses an output class it has no limits for' do
      expect do
        described_class.new(template: template, actor: actor, scope: nil, guard: guard,
                            output_class: :widget)
      end.to raise_error(ArgumentError, /output class/)
    end

    it 'refuses a per-record run with no scope rather than answering "combined"' do
      # Silently producing one document where the author asked for one per issue is a
      # wrong answer that looks like a right one.
      expect do
        run(scope: nil, template: template(output: 'per_record')).call
      end.to raise_error(ArgumentError, /per-record report needs an issue scope/)
    end
  end
end
