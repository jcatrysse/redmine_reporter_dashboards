# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/reporting/report_run'
# F-16. `report_run.rb` reaches the asset layer through
# `RedmineReporterDashboards.asset_resolver`, which lives in the boot file and cannot be
# loaded here (it needs ActiveSupport). The classes themselves are DB-less, so the PORT is
# injected and what travels through it is the real `Assets::Resolver`.
require_relative '../../lib/redmine_reporter_dashboards/assets'
require 'tmpdir'

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

  # `engine_hint` is a MEMBER rather than a hard-coded nil (T-34): the auto-detection
  # examples need the other branch, and the reader stays the model's degrading one —
  # §7 rule 5's "an install one minor behind has no such column" is why `ReportRun` goes
  # through `engine_hint_or_nil` and never touches the attribute.
  FakeTemplateRecord = Struct.new(:id, :name, :content, :source, :output, :orientation,
                                  :page_size, :margins, :project, :engine_hint,
                                  keyword_init: true) do
    def engine_hint_or_nil
      engine_hint
    end
  end

  # Answers `#render` the way `TemplateRenderer` does, and counts. The count is the
  # assertion for "nothing was rendered", which is the only way to tell a refusal that
  # refused from a refusal that happened to come back empty.
  class CountingRenderer
    attr_reader :calls

    # `body_for` is F-16's addition: the asset examples need to control the HTML that
    # reaches the resolver, and `result_for` is the wrong lever for that — it replaces the
    # whole `Document`, so every caller of it would have to rebuild one just to change a
    # string. Both are kept because they answer different questions: `result_for` is how a
    # FAILURE is driven, `body_for` is how a BODY is.
    def initialize(result_for: nil, body_for: nil)
      @calls = 0
      @result_for = result_for
      @body_for = body_for
    end

    def render(_source, **_kwargs)
      @calls += 1
      return @result_for.call(@calls) if @result_for

      body = @body_for ? @body_for.call(@calls) : "<p>#{@calls}</p>"
      TR::Document.new(body: body, duration_ms: 1, output_class: :report)
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

    # `FakeAdapter.behaviour` and NOT `self.class.behaviour`, so `InliningAdapter` below
    # shares the one lever every example already sets. A class-level accessor is per-class,
    # so a subclass would silently read its own nil.
    def render(request)
      FakeAdapter.behaviour.call(request)
    end
  end

  # AN ENGINE THAT DECLARES `:asset_inline`, which is what both shipped adapters declare
  # and what makes an image embeddable at all.
  #
  # `FakeAdapter` declaring nothing is not an oversight, and the two together are what make
  # F-16's central claim observable: the resolver picks the most restrictive model THE
  # ENGINE DECLARES, so the SAME document and the SAME resolver produce an inlined image
  # against this adapter and a named refusal against one that can embed nothing. A single
  # adapter could not tell those apart from "the resolver always inlines".
  class InliningAdapter < FakeAdapter
    def capabilities
      [:asset_inline]
    end

    def id
      'inlining'
    end
  end

  # A stand-in that STAMPS ITS OWN NAME into the Success it returns, so an example can
  # tell WHICH adapter ran. `FakeAdapter.behaviour` deliberately cannot: it is one shared
  # lambda, which is exactly what makes it a convenient lever and a useless witness.
  # A LOGGER THAT RECORDS. FR-50's "an unregistered selection is ignored" is a behaviour whose
  # only observable half is the log line, so the line is part of the assertion rather than a
  # side effect somebody hopes happened.
  class Recorder
    attr_reader :lines

    def initialize
      @lines = []
    end

    def warn(line)
      @lines << line
    end
  end

  def self.named_adapter(name)
    Class.new do
      define_method(:capabilities) { [] }
      define_method(:id) { name }
      define_method(:render) do |_request|
        RedmineReporterDashboards::Render::Success.new(
          bytes: PDF_BYTES, engine: name, engine_version: '1.0'
        )
      end
    end
  end

  # Over `Renderer::MIN_PDF_BYTES`, because the wrapper refuses a document at or under
  # it as `:output_empty`. A "PDF" of forty bytes is what a crashed engine produces.
  PDF_BYTES = "%PDF-1.4\n#{'0' * 2_000}\n%%EOF"

  Assets = RedmineReporterDashboards::Assets

  # A REAL RESOLVER BEHIND THE PORT, NOT A DOUBLE (F-16).
  #
  # The production factory reads `Setting.protocol`, `Setting.host_name` and the plugin
  # settings, so it cannot run in this process — but every class it assembles is DB-less
  # by design, and `spec/assets/` drives them all directly. So the port is injected and the
  # thing injected is `Assets::Resolver` itself, configured from the same value objects
  # production configures it from. A double would prove that `ReportRun` calls something
  # and nothing at all about what a document comes back looking like, which is the entire
  # question F-16 asks.
  #
  # `engine_capabilities` is passed through from the ENGINE rather than fixed here, because
  # "the resolver is told what the resolved engine can do" is the ordering claim the whole
  # fix is about — pinning it would make the one thing under test a constant.
  def self.resolver(policy: Assets::Policy.bundled, roots: {}, mappers: [],
                    origin: Assets::Origin.new, fetcher: nil, seen: nil)
    lambda do |engine_capabilities:|
      seen&.push(engine_capabilities)
      Assets::Resolver.new(
        policy: policy,
        local_store: Assets::LocalStore.new(roots: roots, mappers: mappers),
        engine_capabilities: engine_capabilities,
        origin: origin,
        fetcher: fetcher
      )
    end
  end

  # An install at `https://redmine.example`, so a URL on that host is `:same_origin` and
  # anything else is `:third_party`. Without one, `Origin.new` matches nothing and EVERY
  # absolute URL is third-party — which would make the same-origin examples below pass for
  # the wrong reason.
  def self.origin
    Assets::Origin.parse('https://redmine.example')
  end

  # A one-pixel PNG, written to disk so the local store has something real to type, size
  # and read. A fixture on disk rather than a stub because `LocalStore` is `realpath`-based
  # containment and `File.size`-based capping; neither can be exercised against a double.
  PNG_BYTES = [
    '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489',
    '0000000a49444154789c6360000002000100ffff03000006000557bfabd4',
    '0000000049454e44ae426082'
  ].join.scan(/../).map { |pair| pair.to_i(16) }.pack('C*')
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

  # `engine_preference: nil` — "this installation has selected no engine" — UNLESS an example
  # says otherwise, and the axis is stated here rather than inherited. FR-50's resolution goes
  # through `RedmineReporterDashboards.render_engine_id`, which lives in the boot file and
  # cannot be loaded in this suite (the same reason `asset_resolver` is injected), so the
  # default sentinel would make five examples about something else fail with a
  # `NoMethodError` — measured, not guessed. CLAUDE.md §6 applied to a setting: set it in the
  # test, do not inherit it.
  def run(scope:, renderer: ReportRunSpecSupport::CountingRenderer.new, **overrides)
    described_class.new(**{ template: template, actor: actor, scope: scope,
                            guard: guard, template_renderer: renderer,
                            engine_preference: nil,
                            asset_resolver: ReportRunSpecSupport.resolver }.merge(overrides))
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
      described_class.preview(asset_resolver: ReportRunSpecSupport.resolver, template: template(output: output), actor: actor,
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
      described_class.preview(asset_resolver: ReportRunSpecSupport.resolver, template: template(output: 'per_record'), actor: actor,
                              scope: ReportRunSpecSupport::FakeScope.new(1_284),
                              guard: preview_guard,
                              template_renderer: renderer).call

      expect(renderer.calls).to eq(described_class::PREVIEW_MAX_DOCUMENTS)
    end

    # A COMBINED preview still reads fifty issues: there is one document either way, so
    # the thing being bounded is what the collection drop sees, which is §9b.2's number.
    it 'still reads up to fifty issues for a combined preview' do
      renderer = ReportRunSpecSupport::CountingRenderer.new
      outcome = described_class.preview(asset_resolver: ReportRunSpecSupport.resolver, template: template, actor: actor,
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
      built = described_class.preview(asset_resolver: ReportRunSpecSupport.resolver, template: template, actor: actor,
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

    # ------------------------------------------------------------------
    # T-34. "Default engine unchanged — a test asserts auto-detect never selects
    # `:gotenberg`."
    #
    # WRITTEN SO THAT IT CAN FAIL. Asking the real registry and checking the answer is
    # not `:gotenberg` passes against the OLD fallback too, because that fallback was
    # `Registry.ids.first` — i.e. alphabetical order — and `chromium_cdp` happens to sort
    # first. These register gotenberg where the accident would have chosen it.
    describe 'which engine auto-detection lands on' do
      # BOTH EXAMPLES USE ENGINES THE CATALOGUE CARRIES, deliberately. The rule under
      # test is "never auto-select one that NEEDS A SERVICE", and driving it with an
      # unknown id would test the other rule — the one that deliberately does NOT refuse
      # what the catalogue has not heard of, because a stand-in adapter is how most of
      # this suite works.
      it 'refuses to auto-select an engine that needs a service, and reports it' do
        RedmineReporterDashboards::Render::Registry.register(:gotenberg,
                                                            ReportRunSpecSupport::FakeAdapter)
        # The declared default is NOT registered, so the fallback is what answers — and
        # the only registered engine is one the catalogue says needs a container.
        expect(RedmineReporterDashboards::Render::Registry.ids).to eq([:gotenberg])

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1)).call(pdf: true)

        expect(outcome).not_to be_ok
        # `:engine_misconfigured` since 2026-08-11 (§Findings E-29): the engines ARE here and
        # none of them can be picked automatically, so the remedy is an operator's and it has
        # a page to point at.
        expect(outcome.diagnostic.code).to eq(:engine_misconfigured)
        # AND THE SENTENCE, which is the half the code cannot carry (§Findings E-30). A
        # review mutated this message to nonsense and the FULL suite stayed green — 2670
        # examples, 0 failures — while the message it shipped said "no render engine is
        # registered" three lines under an assertion that one is. It reaches the diagnostics
        # panel and the scheduled-failure mail; NOT the failure PDF, which carries a
        # deliberately narrower field set (`failure_document.rb` argues it).
        expect(outcome.diagnostic.message).to include('needs a separate service')
        expect(outcome.diagnostic.message).to include('Administration')
        expect(outcome.diagnostic.message).not_to include('no render engine is registered')
        # AND IT STAYS DRAWABLE. `MinimalPdf` is Windows-1252, so a `→` in a sentence that ever
        # reached a drawn artefact WOULD be replaced wholesale by "value unavailable" — measured
        # on the first draft of this message, which used one. Conditional on purpose: `message`
        # is not among `FailureDocument`'s fields today, so this guards the character against a
        # future field set rather than a live bug. `—` is Windows-1252 (0x97) and stays.
        expect(outcome.diagnostic.message).not_to include('→')
        expect(outcome.diagnostic.detail).to include('registered=gotenberg')
      end

      # THE THIRD STATE, found twice independently — by an adversarial pass here and by a
      # fourth review — after the two-state split shipped claiming to be exhaustive. A stored
      # selection naming an engine that is NOT registered leaves `selected_engine_id` nil, so
      # this arm answers, and the sentence used to end "and none has been selected" for an
      # operator who had selected one. `EnginePreference` drops such a value at the settings
      # boundary so production cannot reach it — but the `engine_preference:` port is public,
      # which is the same reason the empty-selection example below this one exists.
      it 'does not tell an installation that selected a stale engine that it selected nothing' do
        RedmineReporterDashboards::Render::Registry.register(:gotenberg,
                                                            ReportRunSpecSupport::FakeAdapter)
        logger = ReportRunSpecSupport::Recorder.new

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                      engine_preference: 'athena', logger: logger).call(pdf: true)

        expect(outcome).not_to be_ok
        expect(outcome.diagnostic.code).to eq(:engine_misconfigured)
        # THE WHOLE SENTENCE. A review reworded the lie rather than restoring it — "every
        # registered engine needs a separate service and you have selected nothing" — and the
        # guard passed, because `not_to match(/none has been selected/i)` pins one PHRASING of
        # the falsehood instead of the property. A message that has been wrong twice is pinned
        # entire, so the next rewording is deliberate and has a failing test in front of it.
        expect(outcome.diagnostic.message).to eq(
          'no render engine on this installation can be selected automatically: every ' \
          'registered engine needs a separate service. Choose one under Administration > ' \
          'Plugins, or install an engine that needs none'
        )
        # AND THE DISCRIMINATOR IS IN THE LOG, WHICH IS WHERE A READER IS. A draft put
        # `selected=athena` into `Diagnostic#detail` and called that "admin-facing"; a review
        # measured that detail is printed nowhere at all — the panel names it under "WHAT IS
        # DELIBERATELY NOT PRINTED", `to_h` omits it, `FailureDocument` excludes it, no logger
        # writes it. The stale value was already reaching the log from `selected_engine_id`,
        # which is what this asserts instead. The log line is the fix; the detail was decoration
        # nobody could read.
        expect(logger.lines.join("\n")).to include('athena')
        expect(logger.lines.join("\n")).to include('not registered here')
        expect(outcome.diagnostic.detail).not_to include('athena')
      end

      # THE `FROM_SETTINGS` BRANCH, WHICH THE ROUND BEFORE THIS LEFT UNCOVERED IN RSPEC. That
      # round deleted an example whose subject was a memoisation it also deleted — correctly —
      # and a review then measured the cost: mutating `engine_preference` to ignore the
      # sentinel entirely survived the whole rspec suite (2672 examples, 0 failures) and was
      # caught only by `test/functional/render_engine_settings_test.rb`. CI held, so nothing
      # shipped broken; but a branch covered on one surface only is one deletion away from
      # being covered nowhere. This is the branch, and nothing else.
      #
      # THE PORT DOES NOT EXIST IN THIS PROCESS, which is why the branch was never covered
      # here: `RedmineReporterDashboards.render_engine_id` lives in the boot file, which the
      # DB-less suite does not load, so reaching the sentinel used to raise `NameError`. The
      # example stands the port up for its duration and removes it again — hand-rolled in this
      # file's style, and `|**_kwargs|` rather than a bare `**` for the Ruby 2.7 floor.
      it 'resolves the sentinel through the installation port rather than using it as an id' do
        RedmineReporterDashboards::Render::Registry.register(:gotenberg,
                                                            ReportRunSpecSupport::FakeAdapter)
        asked = 0
        logger = ReportRunSpecSupport::Recorder.new
        mod = RedmineReporterDashboards
        existed = mod.respond_to?(:render_engine_id)
        original = existed ? mod.method(:render_engine_id) : nil
        mod.define_singleton_method(:render_engine_id) do |**_kwargs|
          asked += 1
          nil
        end

        begin
          outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                        engine_preference: described_class::FROM_SETTINGS,
                        logger: logger).call(pdf: true)

          expect(asked).to eq(1)
          expect(outcome).not_to be_ok
          # AND THE SENTINEL IS NEVER TREATED AS AN ENGINE NAME — asserted on the LOG, because
          # a review measured that the diagnostic CODE cannot tell the two paths apart: looking
          # `:from_settings` up as an id also fails, also falls through to the same arm, and
          # also answers `:engine_misconfigured`. The log is where the difference shows: under
          # the mutant it reads *selects render engine "from_settings"* — double-quoted, since
          # `warn_line` interpolates `id.to_s.inspect`, and the first version of this comment
          # wrote `:from_settings` with a colon, which is not what ships.
          #
          # EMPTY, POSITIVELY. `not_to include` alone would also pass if `logger` stopped being
          # wired through at all; on the clean path this run has nothing to complain about, so
          # the expectation is that it said nothing.
          expect(logger.lines).to eq([])
          expect(outcome.diagnostic.code).to eq(:engine_misconfigured)
        ensure
          if existed
            mod.define_singleton_method(:render_engine_id, original)
          else
            mod.singleton_class.send(:remove_method, :render_engine_id)
          end
        end
      end

      it 'passes over it for one that needs nothing, even though it sorts first' do
        # `:gotenberg` sorts BEFORE `:wkhtmltopdf`, so the old `Registry.ids.first`
        # fallback answered gotenberg here. That is the accident this replaces.
        #
        # EACH STAND-IN STAMPS ITS OWN NAME INTO THE RESULT, rather than sharing
        # `FakeAdapter.behaviour`. The first version registered `InliningAdapter` and
        # asserted `engine_id == 'inlining'` — but `engine_id` comes from the `Success`
        # the adapter RETURNS, and both classes return the one lambda's, so the example
        # would have read the same name whichever adapter ran. It could not fail.
        RedmineReporterDashboards::Render::Registry.register(:gotenberg,
                                                            ReportRunSpecSupport.named_adapter('picked-gotenberg'))
        RedmineReporterDashboards::Render::Registry.register(:wkhtmltopdf,
                                                            ReportRunSpecSupport.named_adapter('picked-wkhtmltopdf'))
        expect(RedmineReporterDashboards::Render::Registry.ids.first).to eq(:gotenberg)

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1)).call(pdf: true)

        expect(outcome).to be_ok
        expect(outcome.engine_id).to eq('picked-wkhtmltopdf')
      end

      # THE DECLARED DEFAULT IS PREFERRED OVER WHATEVER SORTS FIRST, and the example that
      # used to sit here could not fail, twice over. It asserted
      # `expect(outcome.engine_id).not_to eq(:gotenberg)` — `engine_id` is a STRING, so a
      # Symbol comparison is unconditionally true — and both adapters it registered
      # rendered through the one shared `FakeAdapter.behaviour` lambda, so the value could
      # not have discriminated even with the right type. Its own premise comment was wrong
      # as well: it claimed the declared default sorted LAST while the line below asserted
      # it sorted first. Found by an independent review; the identical lesson had been
      # written into the example immediately above it three lines earlier.
      #
      # The discriminator is an engine the catalogue has never heard of whose id sorts
      # BEFORE `chromium_cdp` — which is the `:athena` case `report_run.rb`'s own comment
      # invents. Under the old `Registry.ids.first` fallback this example answers
      # `picked-athena`; under the declared-default rule it answers `picked-chromium`.
      it 'prefers the engine config/capabilities.yml declares as the default' do
        RedmineReporterDashboards::Render::Registry.register(
          :athena, ReportRunSpecSupport.named_adapter('picked-athena')
        )
        RedmineReporterDashboards::Render::Registry.register(
          :chromium_cdp, ReportRunSpecSupport.named_adapter('picked-chromium')
        )
        # `:athena` sorts first, and it is auto-selectable — the catalogue does not know
        # it, and being unknown is not evidence that it needs a service. So the ONLY thing
        # that can put chromium_cdp ahead of it is the declared default being read.
        expect(RedmineReporterDashboards::Render::Registry.ids.first).to eq(:athena)

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1)).call(pdf: true)

        expect(outcome).to be_ok
        expect(outcome.engine_id).to eq('picked-chromium')
      end

      # ------------------------------------------------------------------
      # FR-50 — THIS INSTALLATION'S OWN CHOICE, and the four things about it that can break.
      #
      # Every example here is written against a DISCRIMINATOR, because the whole hazard in a
      # precedence chain is that a step which does nothing looks exactly like a step that
      # works: `:athena` sorts before `chromium_cdp` and is auto-selectable, `chromium_cdp` is
      # the declared default, and each stand-in stamps its OWN name into the Success — the
      # lesson three examples above this one, where two adapters shared a lambda and the
      # assertion could not have failed.
      it "renders with the engine the INSTALLATION selected, over the declared default" do
        RedmineReporterDashboards::Render::Registry.register(
          :athena, ReportRunSpecSupport.named_adapter('picked-athena')
        )
        RedmineReporterDashboards::Render::Registry.register(
          :chromium_cdp, ReportRunSpecSupport.named_adapter('picked-chromium')
        )

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                      engine_preference: 'athena').call(pdf: true)

        expect(outcome).to be_ok
        expect(outcome.engine_id).to eq('picked-athena')
      end

      # THE CONTROL FOR THE EXAMPLE ABOVE. Without it, "the setting was honoured" could mean
      # "athena was going to be chosen anyway" — which is precisely what the old
      # `Registry.ids.first` fallback would have done.
      it 'and the same registry answers the declared default when nothing is selected' do
        RedmineReporterDashboards::Render::Registry.register(
          :athena, ReportRunSpecSupport.named_adapter('picked-athena')
        )
        RedmineReporterDashboards::Render::Registry.register(
          :chromium_cdp, ReportRunSpecSupport.named_adapter('picked-chromium')
        )

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                      engine_preference: nil).call(pdf: true)

        expect(outcome.engine_id).to eq('picked-chromium')
      end

      # A HINT OUTRANKS THE SETTING, which is what keeps a template portable: changing the
      # installation's engine must not change what an existing document looks like.
      it 'loses to a template that names an engine itself' do
        RedmineReporterDashboards::Render::Registry.register(
          :athena, ReportRunSpecSupport.named_adapter('picked-athena')
        )
        RedmineReporterDashboards::Render::Registry.register(
          :chromium_cdp, ReportRunSpecSupport.named_adapter('picked-chromium')
        )

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                      engine_preference: 'athena',
                      template: template(engine_hint: 'chromium_cdp')).call(pdf: true)

        expect(outcome.engine_id).to eq('picked-chromium')
      end

      # THE POINT OF THE WHOLE FEATURE (§Findings E-27 row 2). Auto-detection refuses a
      # service-backed engine — the example at the top of this block proves it still does —
      # and an installation that SELECTS one gets it. Same registry, same catalogue entry,
      # opposite outcome, and the only difference is the setting.
      it 'MAY select an engine that needs a service, which auto-detection may not' do
        RedmineReporterDashboards::Render::Registry.register(
          :gotenberg, ReportRunSpecSupport.named_adapter('picked-gotenberg')
        )
        expect(RedmineReporterDashboards::Render::Registry.ids).to eq([:gotenberg])

        refused = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                      engine_preference: nil).call(pdf: true)
        chosen = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                     engine_preference: 'gotenberg').call(pdf: true)

        expect(refused).not_to be_ok
        expect(refused.diagnostic.code).to eq(:engine_misconfigured)
        # The refusal must name the control that would fix it — this example is the pair
        # "auto-detection refuses / a selection is honoured", so the refusal half is exactly
        # where an operator needs pointing at the setting (§Findings E-30).
        expect(refused.diagnostic.message).to include('Administration')
        expect(chosen).to be_ok
        expect(chosen.engine_id).to eq('picked-gotenberg')
      end

      # THE BLANK GUARD'S OBSERVABLE IS THE LOG LINE, and an independent review measured that
      # nothing in the tree covered it. `engine_preference: ''` cannot arrive through
      # `FROM_SETTINGS` — `EnginePreference` coerces blank to nil — but the port is public, and
      # without the guard every render of such a run writes *this installation selects render
      # engine ""* into the log, which an operator reads as an install that selected an engine
      # called nothing.
      it 'says nothing at all about an empty selection, rather than naming ""' do
        RedmineReporterDashboards::Render::Registry.register(
          :chromium_cdp, ReportRunSpecSupport.named_adapter('picked-chromium')
        )
        logger = ReportRunSpecSupport::Recorder.new

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                      engine_preference: '  ', logger: logger).call(pdf: true)

        expect(outcome).to be_ok
        expect(outcome.engine_id).to eq('picked-chromium')
        expect(logger.lines.join).not_to include('this installation selects')
      end

      # §7 rule 5's routine case: a value stored on a host that had the engine, read on a host
      # that does not. It must degrade to the default with a line in the log, never raise —
      # `Registry.fetch` raises `UnknownEngine`, and that would 500 every report on the
      # install rather than the one template.
      it 'ignores a selection this host has no adapter for, and says so in the log' do
        RedmineReporterDashboards::Render::Registry.register(
          :chromium_cdp, ReportRunSpecSupport.named_adapter('picked-chromium')
        )
        logger = ReportRunSpecSupport::Recorder.new

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                      engine_preference: 'gotenberg', logger: logger).call(pdf: true)

        expect(outcome).to be_ok
        expect(outcome.engine_id).to eq('picked-chromium')
        expect(logger.lines.join)
          .to include('this installation selects render engine "gotenberg"')
      end

      # A template may still ASK for it by name — that is what an engine hint is for, and
      # it is the difference between choosing an engine and having one chosen for you.
      it 'still honours a template that names it explicitly' do
        RedmineReporterDashboards::Render::Registry.register(:gotenberg,
                                                            ReportRunSpecSupport::FakeAdapter)
        ReportRunSpecSupport::FakeAdapter.behaviour = lambda do |_request|
          RedmineReporterDashboards::Render::Success.new(
            bytes: ReportRunSpecSupport::PDF_BYTES, engine: 'gotenberg', engine_version: '8.35.0'
          )
        end

        outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1),
                      template: template(engine_hint: 'gotenberg')).call(pdf: true)

        expect(outcome).to be_ok
        expect(outcome.engine_id).to eq('gotenberg')
      end
    end

    it 'reports an absent engine instead of quietly returning the HTML' do
      # §9b.2: "a preview that only proves the easy path is a false signal". With no
      # engine there is no PDF, and the one thing this must not do is say nothing.
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(1)).call(pdf: true)

      expect(outcome).not_to be_ok
      # THE OTHER STATE OF THE SAME METHOD, and the one that keeps `:engine_unavailable`
      # (§Findings E-30): nothing is registered, so nothing is THERE, and what fixes it is an
      # install rather than a setting. The sibling example in the block above is the
      # registry-not-empty half.
      #
      # THIS EXAMPLE USED TO OPEN WITH `expect(Registry.ids).to eq([])`, claiming to stop the
      # two examples "silently becoming one case". A review proved that control cannot fail:
      # it simulated a total registry leak and the guard fired at **0 of 12 seeds**, because
      # RSpec runs a group's own examples before its child groups and because no adapter file
      # is required in this DB-less process. A guard that cannot fail is worse than none — it
      # reads as cover. The line it occupied now buys something that CAN fail:
      expect(outcome.diagnostic.code).to eq(:engine_unavailable)
      expect(outcome.diagnostic.message).to include('no render engine is registered')
      # THE DETAIL, which nothing anywhere asserted. The same review mutated it to nonsense
      # and the FULL suite stayed green (2671 examples, 0 failures) — and it is the surviving
      # half of the pair the previous round's commit message claimed were both killed.
      #
      # IT IS NOT WHAT AN ADMINISTRATOR READS, and the first version of this comment said it
      # was. `Diagnostic#detail` is printed nowhere — the panel lists it under "WHAT IS
      # DELIBERATELY NOT PRINTED", `to_h` omits it so no serialiser can leak it, and its only
      # readers are the two delivery `restamp` sites. It is still worth pinning: it is part of
      # this object's contract, it is carried across a delivery, and a string that nothing
      # asserts is a string that quietly becomes wrong.
      expect(outcome.diagnostic.detail).to include('Registry.ids is empty')
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

  # --- F-16: THE ASSET LAYER IS ACTUALLY CALLED -----------------------------------------
  #
  # `Assets::Resolver` and `Render::AssetBinding` were complete, correct and tested since
  # T-33 and NOTHING CALLED THEM: `#document_request` built a `DocumentRequest` straight
  # off `section.body` and passed no `assets:`, so every URL-referenced image reached the
  # engine as a live URL — which INV-8 denies a credential, so it drew BLANK. Measured by
  # the review of T-28 increment 3 against a real render: `PDF contains '/attachments/':
  # true`.
  #
  # What is asserted here is the WIRING and its ORDERING, which is where the difficulty
  # was. The resolver's own behaviour has 200-odd examples in `spec/assets/`; repeating
  # them here would be a second oracle for one rule. What those cannot see is that
  # anybody calls it, that the engine is resolved FIRST so its capabilities can be asked,
  # and that a refusal becomes a typed Failure rather than a blank image.
  describe 'the asset layer, which nothing used to call (F-16)' do
    around do |example|
      RedmineReporterDashboards::Render::Registry.isolated { example.run }
    end

    # The body every example below renders. `CountingRenderer` is the Liquid half and
    # answers a fixed string, so the "template" is this.
    def body_renderer(html)
      ReportRunSpecSupport::CountingRenderer.new(body_for: ->(_n) { html })
    end

    # `engine:` defaults to the adapter that CAN embed, because that is what a real install
    # has. The examples that want the other case pass `FakeAdapter` explicitly and say why.
    def drew(scope_size: 1, engine: ReportRunSpecSupport::InliningAdapter, **overrides)
      seen = []
      ReportRunSpecSupport::FakeAdapter.behaviour = lambda do |request|
        seen << request
        RedmineReporterDashboards::Render::Success.new(
          bytes: ReportRunSpecSupport::PDF_BYTES, engine: 'fake', engine_version: '1.0'
        )
      end
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(scope_size),
                    engine: engine, **overrides).call(pdf: true)
      [outcome, seen]
    end

    describe 'a same-origin Redmine URL' do
      # THE ACCEPTANCE CRITERION, stated as the thing a reader of the PDF would check:
      # the bytes of the image are IN the document and the URL is GONE. Asserting only
      # that the URL is absent would pass against a resolver that deleted the tag.
      it 'is inlined off disk, so the image is IN the document rather than blank' do
        Dir.mktmpdir do |dir|
          File.binwrite(File.join(dir, 'logo.png'), ReportRunSpecSupport::PNG_BYTES)
          html = '<p><img src="https://redmine.example/plugin_assets/x/logo.png"></p>'

          _outcome, seen = drew(
            renderer: body_renderer(html),
            asset_resolver: ReportRunSpecSupport.resolver(
              roots: { '/plugin_assets/x' => dir }, origin: ReportRunSpecSupport.origin
            )
          )

          expect(seen.first.body).to include('data:image/png;base64,')
          expect(seen.first.body).not_to include('redmine.example')
        end
      end

      # THE FIXTURE HAS TO DISCRIMINATE. If the resolver silently did nothing, the example
      # above would still fail — but only because of the `data:` assertion. This one proves
      # the same document is genuinely unresolvable without the root, so the pass above is
      # attributable to the root and not to something incidental.
      it 'is REFUSED when it maps to no file, rather than passed through to the engine' do
        html = '<p><img src="https://redmine.example/plugin_assets/x/logo.png"></p>'

        outcome, seen = drew(
          renderer: body_renderer(html),
          asset_resolver: ReportRunSpecSupport.resolver(origin: ReportRunSpecSupport.origin)
        )

        expect(seen).to be_empty
        expect(outcome).not_to be_ok
        expect(outcome.diagnostic.code).to eq(:asset_unresolved)
      end
    end

    describe 'a third-party URL under the default :bundled policy' do
      let(:html) { '<p><img src="https://cdn.example.net/tracker.png"></p>' }

      it 'is a typed failure and NOT a blank image' do
        outcome, seen = drew(renderer: body_renderer(html),
                             asset_resolver: ReportRunSpecSupport.resolver(
                               origin: ReportRunSpecSupport.origin
                             ))

        expect(seen).to be_empty
        expect(outcome).not_to be_ok
        expect(outcome.diagnostic.code).to eq(:asset_unresolved)
      end

      # NAMING THE URL IS THE REQUIREMENT, in T-33's own words: "a report with a silently
      # missing logo is one a reader cannot tell from a report that never had one".
      it 'NAMES the URL in the user-facing message' do
        outcome, = drew(renderer: body_renderer(html),
                        asset_resolver: ReportRunSpecSupport.resolver(
                          origin: ReportRunSpecSupport.origin
                        ))

        expect(outcome.diagnostic.message).to include('https://cdn.example.net/tracker.png')
      end

      # NO ENGINE RAN, so calling this an engine failure would send the reader to check a
      # binary that was never started. `:assets` is a fourth origin for that reason, and
      # this is the assertion that stops it being folded back into `:engine`.
      it 'is an ASSETS diagnostic, and carries no engine or engine version' do
        outcome, = drew(renderer: body_renderer(html),
                        asset_resolver: ReportRunSpecSupport.resolver(
                          origin: ReportRunSpecSupport.origin
                        ))

        expect(outcome.diagnostic.origin).to eq(:assets)
        expect(outcome.diagnostic.engine).to be_nil
        expect(outcome.diagnostic.engine_version).to be_nil
      end
    end

    # THE ORDERING CLAIM, WHICH IS THE HARD PART OF F-16. The resolver picks the most
    # restrictive asset model THE ENGINE DECLARES, so it cannot be built before the engine
    # is resolved. The old code instantiated the adapter as an ARGUMENT to `Renderer.new`,
    # so no variable held it and nothing could ask it anything.
    it 'asks the RESOLVED ENGINE for its capabilities before building any request' do
      seen_capabilities = []
      drew(renderer: body_renderer('<p>no assets here</p>'),
           asset_resolver: ReportRunSpecSupport.resolver(seen: seen_capabilities))

      expect(seen_capabilities).to eq([[:asset_inline]])
    end

    # THE OTHER HALF OF THE SAME CLAIM, and without it the example above is satisfied by
    # any constant. Same document, same resolver, same disk — a different ENGINE, and the
    # answer changes from an embedded image to a named refusal. That is only possible if
    # the engine's declared capabilities really do reach the resolver.
    it 'refuses the same document against an engine that declares no asset model' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'logo.png'), ReportRunSpecSupport::PNG_BYTES)
        html = '<p><img src="/plugin_assets/x/logo.png"></p>'
        resolver = ReportRunSpecSupport.resolver(roots: { '/plugin_assets/x' => dir },
                                                 origin: ReportRunSpecSupport.origin)

        inlined, = drew(renderer: body_renderer(html), asset_resolver: resolver)
        refused, seen = drew(renderer: body_renderer(html), asset_resolver: resolver,
                             engine: ReportRunSpecSupport::FakeAdapter)

        expect(inlined).to be_ok
        expect(refused).not_to be_ok
        expect(refused.diagnostic.code).to eq(:asset_unresolved)
        expect(seen).to be_empty
      end
    end

    # ONE RESOLVER FOR THE RUN, not one per document — it holds the policy, the store and
    # any fetcher, none of which vary per section, and `Resolver#call` is re-entrant by
    # design. A per-section resolver would re-read the settings and rebuild the store for
    # every document in a 200-document per-record export.
    it 'builds ONE resolver for a multi-document run' do
      seen_capabilities = []
      drew(scope_size: 3,
           template: template(output: 'per_record'),
           renderer: body_renderer('<p>no assets here</p>'),
           asset_resolver: ReportRunSpecSupport.resolver(seen: seen_capabilities))

      expect(seen_capabilities.length).to eq(1)
    end

    # A DEGRADATION IS NOT A FAILURE AND IS NOT SILENT EITHER (INV-4). `srcset` collapses
    # to its first candidate because a PDF page has one pixel density, and the reader is
    # told. Before F-16 nothing resolved, so nothing degraded, so this said nothing.
    it 'carries the resolution`s degradations into the outcome' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'logo.png'), ReportRunSpecSupport::PNG_BYTES)
        html = '<p><img srcset="/plugin_assets/x/logo.png 1x, /plugin_assets/x/logo.png 2x">' \
               '</p>'

        outcome, = drew(renderer: body_renderer(html),
                        asset_resolver: ReportRunSpecSupport.resolver(
                          roots: { '/plugin_assets/x' => dir },
                          origin: ReportRunSpecSupport.origin
                        ))

        expect(outcome).to be_ok
        expect(outcome.degradations.map(&:capability)).to include(:asset_srcset_collapsed)
      end
    end

    # NEITHER SHIPPED ENGINE DECLARES `:asset_upload`, so the resolver always chooses
    # `:inline` and `assets` stays empty — which is what F-16's own text says is correct
    # and fully exercised. This pins it, so the day T-34 declares the capability, the
    # example that changes is the one that should.
    it 'passes an EMPTY asset map to an engine that declares no upload model' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'logo.png'), ReportRunSpecSupport::PNG_BYTES)

        _outcome, seen = drew(
          renderer: body_renderer('<p><img src="/plugin_assets/x/logo.png"></p>'),
          asset_resolver: ReportRunSpecSupport.resolver(
            roots: { '/plugin_assets/x' => dir }, origin: ReportRunSpecSupport.origin
          )
        )

        expect(seen.first.assets).to be_empty
        expect(seen.first.body).to include('data:image/png;base64,')
      end
    end
  end

  describe 'a source outside the closed set' do
    # T-31 REPLACED THIS EXAMPLE'S SUBJECT. It used to assert that a `time_entries`
    # template was refused, because `source` was a column before it was a feature. Both
    # sources render now — so what has to be refused is a value neither branch knows.
    #
    # `Template` validates `source` on save and that is NOT enough on its own:
    # `update_columns` and `update_all` bypass validation and this plugin uses both, and §7
    # rule 5 makes "an install one minor behind reading a newer row" routine. So the set is
    # closed where the behaviour is chosen, and the `else` that would quietly report on
    # issues does not exist.
    it 'refuses a source it does not know rather than reporting on issues' do
      renderer = ReportRunSpecSupport::CountingRenderer.new
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(3), renderer: renderer,
                    template: template(source: 'invoices')).call

      expect(outcome).not_to be_ok
      expect(outcome.diagnostic.code).to eq(:unsupported_source)
      expect(outcome.diagnostic.message).to include('invoices')
    end

    it 'renders nothing at all for it, rather than a report about the wrong table' do
      renderer = ReportRunSpecSupport::CountingRenderer.new
      run(scope: ReportRunSpecSupport::FakeScope.new(3), renderer: renderer,
          template: template(source: 'invoices')).call

      expect(renderer.calls).to eq(0)
    end

    # AND BOTH KNOWN SOURCES GET THROUGH. Without this the closed check could be refusing
    # everything and the two examples above would still pass.
    it 'renders a time-entry template, which T-31 made a supported source' do
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(3),
                    template: template(source: 'time_entries')).call

      expect(outcome).to be_ok
    end

    it 'renders an issue template, unchanged' do
      outcome = run(scope: ReportRunSpecSupport::FakeScope.new(3),
                    template: template(source: 'issues')).call

      expect(outcome).to be_ok
    end
  end

  describe 'the arguments it refuses to be built with' do
    it 'needs an actor, because INV-1 is lost by a default argument' do
      expect { described_class.new(template: template, actor: nil, scope: nil, guard: guard) }
        .to raise_error(ArgumentError, /actor/)
    end

    # THIS EXAMPLE USED `:widget` AS ITS UNKNOWN CLASS, and that is how the defect T-26a
    # tripped over got here: `:widget` has been a real class in `ExecutionPolicy` since
    # T-17, this list was a second copy that never grew it, and the copy was pinned by an
    # example asserting the divergence. The two are one object now, so an unknown class
    # has to be one that is genuinely absent from both.
    it 'refuses an output class it has no limits for' do
      expect do
        described_class.new(template: template, actor: actor, scope: nil, guard: guard,
                            output_class: :banner)
      end.to raise_error(ArgumentError, /output class/)
    end

    it 'accepts every output class the execution policy has limits for' do
      expect(described_class::OUTPUT_CLASSES)
        .to be(::RedmineReporterDashboards::Liquid::ExecutionPolicy::OUTPUT_CLASSES)

      described_class::OUTPUT_CLASSES.each do |output_class|
        expect do
          described_class.new(template: template, actor: actor, scope: nil, guard: guard,
                              output_class: output_class)
        end.not_to raise_error
      end
    end

    it 'refuses a per-record run with no scope rather than answering "combined"' do
      # Silently producing one document where the author asked for one per issue is a
      # wrong answer that looks like a right one.
      expect do
        run(scope: nil, template: template(output: 'per_record')).call
      end.to raise_error(ArgumentError, /per-record report needs a record scope/)
    end
  end
end
