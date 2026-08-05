# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/render/document_request'
require_relative '../../lib/redmine_reporter_dashboards/render/page_furniture'
require_relative '../../lib/redmine_reporter_dashboards/render/result'
require_relative '../../lib/redmine_reporter_dashboards/render/failure'
require_relative '../../lib/redmine_reporter_dashboards/render/capabilities'
require_relative '../../lib/redmine_reporter_dashboards/render/registry'
require_relative '../../lib/redmine_reporter_dashboards/render/renderer'

# T-10 — the document-request interface.
#
# These specs boot nothing. That is not a convenience, it is the point: L3 is supposed
# to be reachable without Rails, ActiveRecord or Redmine, and a suite that needed any of
# them would be evidence the layer had already leaked.
module RedmineReporterDashboards
  module Render
    # A minimal PDF that satisfies both post-conditions, so a test about capability
    # negotiation is not accidentally also a test about byte validation.
    VALID_PDF = "%PDF-1.4\n#{'x' * 2000}\n%%EOF"

    RSpec.describe 'the render contract' do
      let(:correlation_id) { 'corr-1' }

      def request(**overrides)
        DocumentRequest.new(body: '<html></html>', correlation_id: correlation_id, **overrides)
      end

      # A stand-in adapter. Four methods, exactly the engine interface §5 names.
      def engine(capabilities: Capabilities::ALL, result: nil, raises: nil, id: :fake)
        double = Object.new
        double.define_singleton_method(:id) { id }
        double.define_singleton_method(:version) { '1.0' }
        double.define_singleton_method(:capabilities) { capabilities }
        double.define_singleton_method(:render) do |_req|
          raise raises if raises

          result
        end
        double
      end

      def success(bytes: VALID_PDF)
        Success.new(bytes: bytes, engine: :fake, engine_version: '1.0')
      end

      # ----------------------------------------------------------------
      # DocumentRequest — the shape IS the security property
      # ----------------------------------------------------------------

      describe DocumentRequest do
        # THE INV-8 ASSERTION, and it is written against the constructor's SIGNATURE
        # rather than against behaviour on purpose. "Cookie-passing is unrepresentable"
        # is a claim about what can be expressed, so the test asks what can be expressed.
        # A future `headers:` or `extra_options:` bag fails here and has to be argued.
        it 'has no field a credential could travel in' do
          accepted = DocumentRequest.instance_method(:initialize).parameters
                                    .select { |kind, _| %i[key keyreq].include?(kind) }
                                    .map(&:last)

          forbidden = %i[cookies cookie headers header_hash auth authorization credentials
                         token password url fetch_url extra_options options]
          expect(accepted & forbidden).to be_empty,
                                          "DocumentRequest gained #{(accepted & forbidden).inspect}. " \
                                          'INV-8 says a credential must be UNREPRESENTABLE here, not ' \
                                          'merely discouraged — see the file comment before adding one.'
        end

        # Not the engine's default. Chromium's printToPDF defaults this to false, and a
        # naive swap silently loses every badge and progress-bar colour.
        it 'defaults print_backgrounds to true rather than to the engine default' do
          expect(request.print_backgrounds).to be(true)
        end

        it 'defaults to A4 portrait print media with a timeout' do
          expect(request.page_size).to eq('A4')
          expect(request.orientation).to eq(:portrait)
          expect(request.media).to eq(:print)
          expect(request.timeout_ms).to eq(DocumentRequest::DEFAULT_TIMEOUT_MS)
        end

        it 'is frozen, so nothing can rewrite a request after it was authorised' do
          expect(request).to be_frozen
        end

        it 'refuses a page size, orientation or medium outside the closed sets' do
          expect { request(page_size: 'A0') }.to raise_error(DocumentRequest::InvalidRequest)
          expect { request(orientation: :sideways) }.to raise_error(DocumentRequest::InvalidRequest)
          expect { request(media: :braille) }.to raise_error(DocumentRequest::InvalidRequest)
        end

        it 'fills missing margins from the default rather than dropping them' do
          expect(request(margins_mm: { 'top' => 30 }).margins_mm)
            .to eq(DocumentRequest::DEFAULT_MARGINS_MM.merge('top' => 30))
        end

        it 'refuses HTML where structured furniture belongs' do
          expect { request(footer: '<div>page 1</div>') }
            .to raise_error(DocumentRequest::InvalidRequest, /PageFurniture/)
        end

        it 'refuses a capability outside the closed vocabulary' do
          expect { request(required_capabilities: [:teleportation]) }
            .to raise_error(Capabilities::UnknownCapability)
        end

        # An essential capability that is not required is never checked, because the
        # negotiation only subtracts what was required. It reads as a guarantee and is
        # none, so it is refused rather than silently ignored.
        it 'refuses an essential capability that is not also required' do
          expect { request(essential_capabilities: [:javascript]) }
            .to raise_error(DocumentRequest::InvalidRequest, /never checked/)
        end
      end

      # ----------------------------------------------------------------
      # PageFurniture — a closed token set
      # ----------------------------------------------------------------

      describe PageFurniture do
        it 'accepts literal text plus tokens from the closed set' do
          furniture = described_class.new(left: 'Acme', right: 'Page {{page}} of {{pages}}')

          expect(furniture.tokens_used).to contain_exactly('page', 'pages')
        end

        # Passing an unknown token through means it reaches the reader as `{{pgae}}` in
        # a document they were told was finished, and the author never learns.
        it 'refuses an unknown token instead of passing it through to the reader' do
          expect { described_class.new(center: 'Page {{pgae}}') }
            .to raise_error(described_class::UnknownToken, /closed token set/)
        end

        it 'knows when it would render nothing' do
          expect(described_class.new).to be_empty
          expect(described_class.new(center: 'x')).not_to be_empty
        end

        it 'carries the four provenance tokens a six-month-old PDF needs' do
          expect(described_class::TOKENS)
            .to include('plugin_version', 'engine', 'render_duration_ms', 'datetime')
        end
      end

      # ----------------------------------------------------------------
      # The sum type
      # ----------------------------------------------------------------

      describe Failure do
        it 'refuses a code outside the closed set' do
          expect { described_class.new(code: :vibes, message: 'x', correlation_id: 'c') }
            .to raise_error(described_class::UnknownCode)
        end

        # `attachment.write(result.bytes)` on a Failure would produce a zero-byte PDF,
        # which is the same defect in a new costume. So asking raises.
        it 'has no bytes, loudly' do
          failure = described_class.new(code: :timeout, message: 'x', correlation_id: 'c')

          expect { failure.bytes }.to raise_error(NoMethodError, /no bytes/)
          expect(failure).to be_failure
          expect(failure).not_to be_success
        end
      end

      describe Success do
        it 'reports no degradations as an empty list rather than nil' do
          expect(success.degradations).to eq([])
          expect(success).not_to be_degraded
        end
      end

      # ----------------------------------------------------------------
      # Registry — a closed map, never constantize
      # ----------------------------------------------------------------

      describe Registry do
        before { described_class.reset! }
        after  { described_class.reset! }

        it 'resolves only what was explicitly registered' do
          adapter = Object.new
          described_class.register(:chromium_cdp, adapter)

          expect(described_class.fetch(:chromium_cdp)).to be(adapter)
          expect(described_class.ids).to eq([:chromium_cdp])
        end

        # A silent fallback means a deployment that asks for one engine and quietly
        # gets another — and then stamps the wrong engine into the PDF metadata.
        it 'raises on an unknown id rather than falling back to a default' do
          expect { described_class.fetch(:nope) }.to raise_error(described_class::UnknownEngine)
        end

        it 'refuses two adapters answering to one id' do
          described_class.register(:a, Object.new)

          expect { described_class.register(:a, Object.new) }
            .to raise_error(described_class::DuplicateEngine)
        end
      end

      # ----------------------------------------------------------------
      # Renderer — where INV-5 stops being a rule people follow
      # ----------------------------------------------------------------

      describe Renderer do
        it 'passes a real PDF through' do
          result = described_class.new(engine: engine(result: success)).render(request)

          expect(result).to be_success
          expect(result.bytes).to eq(VALID_PDF)
        end

        # The defect this whole layer exists for: the base plugin returns e.message AS
        # THE DOCUMENT. Here that cannot reach the caller as a document.
        it 'rewrites non-PDF bytes to output_not_pdf, whatever the adapter claimed' do
          result = described_class.new(engine: engine(result: success(bytes: '<html>oh no</html>')))
                                  .render(request)

          expect(result).to be_failure
          expect(result.code).to eq(:output_not_pdf)
        end

        it 'rewrites a truncated PDF to output_empty even though it looks like a PDF' do
          result = described_class.new(engine: engine(result: success(bytes: "%PDF-1.4\n%%EOF")))
                                  .render(request)

          expect(result.code).to eq(:output_empty)
        end

        it 'turns an adapter that raises into engine_crashed rather than an exception' do
          result = described_class.new(engine: engine(raises: RuntimeError.new('boom')))
                                  .render(request)

          expect(result.code).to eq(:engine_crashed)
          expect(result.detail).to include('boom')
          expect(result.message).not_to include('boom'), 'the user-facing message must be safe'
        end

        it 'turns an adapter that answers something else into internal' do
          result = described_class.new(engine: engine(result: :surprise)).render(request)

          expect(result.code).to eq(:internal)
        end

        it 'refuses when an ESSENTIAL capability is missing, naming it' do
          bare = engine(capabilities: [], result: success)
          req = request(required_capabilities: [:javascript], essential_capabilities: [:javascript])

          result = described_class.new(engine: bare).render(req)

          expect(result.code).to eq(:capability_unsupported)
          expect(result.message).to include('javascript')
        end

        # The three-state rule's middle state: not refused, not silent.
        it 'proceeds when a DEGRADABLE capability is missing, and records it' do
          bare = engine(capabilities: [:javascript], result: success)
          req = request(required_capabilities: %i[javascript outline],
                        essential_capabilities: [:javascript])

          result = described_class.new(engine: bare).render(req)

          expect(result).to be_success
          expect(result).to be_degraded
          expect(result.degradations.map(&:capability)).to eq([:outline])
        end

        it 'never raises, even when the adapter is broken in every direction at once' do
          broken = Object.new
          broken.define_singleton_method(:capabilities) { raise 'no' }

          expect { described_class.new(engine: broken).render(request) }.not_to raise_error
          expect(described_class.new(engine: broken).render(request)).to be_failure
        end

        it 'carries the correlation id onto the failure, so the log and the view join up' do
          result = described_class.new(engine: engine(result: success(bytes: 'nope')))
                                  .render(request)

          expect(result.correlation_id).to eq(correlation_id)
        end

        # E5: the logger is a constructor PORT. Without one the renderer must still
        # work — a nil logger is a legitimate configuration, not a crash.
        it 'works with no logger at all, and uses one when given' do
          logged = []
          logger = Object.new
          logger.define_singleton_method(:warn) { |line| logged << line }
          bare = engine(capabilities: [:javascript], result: success)
          req = request(required_capabilities: %i[javascript outline],
                        essential_capabilities: [:javascript])

          expect { described_class.new(engine: bare).render(req) }.not_to raise_error
          described_class.new(engine: bare, logger: logger).render(req)

          expect(logged.join).to include('outline')
        end
      end
    end
  end
end
