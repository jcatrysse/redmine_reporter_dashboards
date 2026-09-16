# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/render/engines/gotenberg'
require_relative '../../lib/redmine_reporter_dashboards/render/renderer'
require_relative '../../lib/redmine_reporter_dashboards/render/pdf_inspector'

module RedmineReporterDashboards
  module Render
    module Engines
      # THE SAME CLAIMS AS `gotenberg_spec.rb`, AGAINST A REAL CONTAINER.
      #
      # `gotenberg_spec.rb` proves the adapter asks for the right thing and runs
      # everywhere. This file proves the service ANSWERS the way the adapter believes it
      # does, and it needs a container — so every example here is a statement about
      # `gotenberg/gotenberg:8` that would otherwise be a statement about my memory of its
      # documentation. Every constant in the adapter that encodes a wire fact was read off
      # a run of these.
      #
      # TWO ENDPOINTS, because one of them is the security check's subject:
      #
      #   RRD_GOTENBERG_URL       an authenticated instance (--api-enable-basic-auth)
      #   RRD_GOTENBERG_OPEN_URL  an instance with NO authentication at all
      #
      # The second exists for T-34's Accept: "a test stands up an unauthenticated instance
      # to prove the failure fires (a security check that is never observed failing is not
      # a check)". `docker-compose.gotenberg.yml` and the render-smoke job both start the
      # pair; the compose file is what an operator copies, the job is what proves it.
      #
      # SKIPPED WITH A REASON, never silently. A skip here means "no container", and G12's
      # three-state rule is the same rule one level up: an absent engine is not a pass.
      # METHODS, NOT CONSTANTS — the sibling spec fixed this and this file was left behind,
      # which an adversarial QA pass measured: `Render::Engines::CREDENTIAL` was still a
      # process-global holding the live password, alongside AUTHENTICATED, OPEN_ENDPOINT and
      # PLATE. A constant assigned inside `RSpec.describe` lands on the enclosing lexical
      # scope, which here is a PRODUCTION namespace.
      RSpec.describe "#{Gotenberg} against a real container" do
        def authenticated_endpoint
          ENV.fetch('RRD_GOTENBERG_URL', nil)
        end

        def open_endpoint
          ENV.fetch('RRD_GOTENBERG_OPEN_URL', nil)
        end

        def credential
          [ENV.fetch('RRD_GOTENBERG_USERNAME', nil), ENV.fetch('RRD_GOTENBERG_PASSWORD', nil)]
        end

        # An 8x8 solid #00ff00 plate. Its COLOUR is the assertion, for the reason
        # `Preflight::PROBE_PNG`'s comment gives at length: an engine can accept an image,
        # fail to decode it, draw the broken-image glyph, and produce a document of
        # exactly the same size with nothing failing.
        def plate_png
          'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEElEQVR42mNg+M+AHQ0tCQ' \
            'DpMD/BHYHcAQAAAABJRU5ErkJggg=='
        end

        def skip_without_authenticated
          return if authenticated_endpoint && credential.none?(&:nil?)

          skip 'set RRD_GOTENBERG_URL, RRD_GOTENBERG_USERNAME and RRD_GOTENBERG_PASSWORD ' \
               'to an authenticated Gotenberg (docker-compose.gotenberg.yml starts one)'
        end

        def engine
          Gotenberg.new(endpoint: authenticated_endpoint, credential: credential)
        end

        def request(**overrides)
          DocumentRequest.new(correlation_id: 'service-spec', **overrides)
        end

        describe '#preflight' do
          it 'passes against a correctly configured instance' do
            skip_without_authenticated
            result = engine.preflight

            expect(result).to be_success, -> { "#{result.code}: #{result.message}" }
          end

          # THE ONE THE ACCEPT LIST NAMES. Observed failing against a real service that
          # really does answer without a credential — not argued, and not stubbed.
          it 'FAILS, with a named remediation, against an UNAUTHENTICATED instance' do
            unless open_endpoint
              skip 'set RRD_GOTENBERG_OPEN_URL to a Gotenberg started WITHOUT ' \
                   '--api-enable-basic-auth; the check has to be observed failing'
            end

            result = Gotenberg.new(endpoint: open_endpoint, credential: %w[user pass]).preflight

            expect(result).to be_failure
            # `:engine_misconfigured` against a REAL open container, which is the only
            # place this code's meaning can be checked rather than asserted: the service
            # is up and answering, so "unavailable" was the one thing it was not
            # (§Findings E-27 row 3).
            expect(result.code).to eq(:engine_misconfigured)
            expect(result.message).to include('WITHOUT the configured credential')
            expect(result.message).to include('--api-enable-basic-auth')
          end

          # The control for the example above, and the reason it is not vacuous: the SAME
          # adapter, the SAME code path, against a service that does enforce the
          # credential, passes. Without this pair, "it failed" could mean the adapter
          # fails against everything.
          it 'and the same check PASSES against the authenticated one' do
            skip_without_authenticated
            expect(engine.preflight).to be_success
          end

          it 'probes a version off the service rather than believing a constant' do
            skip_without_authenticated
            expect(engine.version).to match(/\A8\.\d+/)
          end
        end

        describe 'the upload asset model, end to end' do
          # F-16's REMAINING HALF, made real. `:asset_upload` was declared by no shipped
          # engine, so `Assets::Resolver` always chose `:inline` and
          # `DocumentRequest#assets` was always empty. This is the first time bytes
          # travelling in the REQUEST come back drawn on the page.
          #
          # The assertion is a PIXEL, not a byte count. The first version of this probe
          # double-encoded the plate and uploaded base64 text as a PNG: the request
          # succeeded, the PDF was a plausible size, and the image was blank. A byte-count
          # assertion would have passed.
          it 'draws bytes that travelled in the request, and the pixel proves it' do
            skip_without_authenticated
            skip 'needs poppler (pdftoppm)' unless PdfInspector.available?

            result = Renderer.new(engine: engine).render(
              request(body: '<!DOCTYPE html><html><body style="margin:0">' \
                            '<img src="rrd-asset-plate.png" width="600" height="300">' \
                            '<p>UPLOAD-MARKER</p></body></html>',
                      assets: { 'rrd-asset-plate.png' => { 'bytes' => plate_png.unpack1('m'),
                                                           'content_type' => 'image/png' } },
                      required_capabilities: [:asset_upload],
                      essential_capabilities: [:asset_upload],
                      page_size: 'A4',
                      margins_mm: { 'top' => 0, 'right' => 0, 'bottom' => 0, 'left' => 0 })
            )

            expect(result).to be_success, -> { "#{result.code}: #{result.message}" }
            expect(PdfInspector.flat_text(result.bytes)).to include('UPLOAD-MARKER')

            drawn = PdfInspector.pixel(result.bytes, x: 0.5, y: 0.1)
            expect(drawn.zip([0, 255, 0]).map { |a, b| (a - b).abs }.max)
              .to be <= PdfInspector::COLOUR_TOLERANCE,
                  "the uploaded plate drew #{drawn.inspect}, not green — bytes came back " \
                  'and the image did not'
          end

          it 'refuses an asset name that could rewrite the request, and sends nothing' do
            skip_without_authenticated
            result = engine.render(
              request(body: '<p>x</p>',
                      assets: { "a\"; filename=\"evil.html" => { 'bytes' => 'x',
                                                                 'content_type' => 'text/plain' } })
            )

            expect(result).to be_failure
            expect(result.code).to eq(:internal)
          end
        end

        describe 'readiness, which this engine cannot honour in one request' do
          # MEASURED: an expression that never becomes true ends the whole conversion with
          # no bytes at all, so "render anyway" is a SECOND request. The contract is the
          # caller's, and the cost of the difference is paid in the adapter.
          it 'renders anyway on a non-strict timeout, and says what was lost' do
            skip_without_authenticated
            result = engine.render(
              request(body: '<html><body><p>NEVER-READY</p></body></html>',
                      readiness: Readiness.new(timeout_ms: 2_000, client_timeout_ms: 1_000),
                      timeout_ms: 30_000)
            )

            expect(result).to be_success, -> { "#{result.code}: #{result.message}" }
            expect(result.degradations.map(&:capability)).to include(:readiness_timeout)
          end

          it 'turns the same timeout into a typed failure when strict was asked for' do
            skip_without_authenticated
            result = engine.render(
              request(body: '<html><body><p>NEVER-READY</p></body></html>',
                      readiness: Readiness.new(timeout_ms: 2_000, client_timeout_ms: 1_000,
                                               strict: true),
                      timeout_ms: 30_000)
            )

            expect(result).to be_failure
            expect(result.code).to eq(:readiness_timeout)
          end

          # THE DEFECT THE `!!` EXISTS FOR, asserted against the service that has it.
          # `window.__rd && window.__rd.ready === true` is `undefined` before the chart
          # shell runs, and Gotenberg answers `400 … returned an exception or undefined`
          # rather than waiting. This example fails — 400/`:internal` instead of a
          # degraded success — the moment the coercion is removed.
          it 'waits rather than being refused for an expression that is not yet defined' do
            skip_without_authenticated
            expect(Gotenberg::READINESS_EXPRESSION).to start_with('!!(')

            result = engine.render(
              request(body: '<html><body><p>NO-SHELL</p></body></html>',
                      readiness: Readiness.new(timeout_ms: 2_000, client_timeout_ms: 1_000),
                      timeout_ms: 30_000)
            )

            expect(result).to be_success
            expect(result.degradations.map(&:capability)).to include(:readiness_timeout)
          end

          it 'settles immediately once the document declares itself ready' do
            skip_without_authenticated
            result = engine.render(
              request(body: '<html><body><p>READY-NOW</p>' \
                            '<script>window.__rd = { ready: true }</script></body></html>',
                      readiness: Readiness.new(timeout_ms: 8_000, client_timeout_ms: 4_000),
                      timeout_ms: 30_000)
            )

            expect(result).to be_success
            expect(result.degradations).to be_empty
          end
        end

        describe 'page furniture' do
          it 'numbers the pages, in this engine\'s own token spelling' do
            skip_without_authenticated
            skip 'needs poppler (pdftotext)' unless PdfInspector.available?

            result = engine.render(
              request(body: '<html><body><p>ONE</p>' \
                            '<p style="page-break-before:always">TWO</p></body></html>',
                      footer: PageFurniture.new(center: 'Page {{page}} of {{pages}}'))
            )

            expect(result).to be_success
            text = PdfInspector.flat_text(result.bytes)
            expect(text).to include('Page 1 of 2')
            expect(text).to include('Page 2 of 2')
          end
        end

        describe 'the forbidden route, asserted against the service' do
          # The gate says the string is absent from the tree and the unit spec says the
          # adapter never builds it. This says the third thing: even the route that WOULD
          # work is not reachable through this adapter, because there is no argument that
          # reaches the path.
          it 'exposes no argument by which a caller could name a different route' do
            skip_without_authenticated
            parameters = Gotenberg.instance_method(:initialize).parameters.map(&:last)

            expect(parameters).to contain_exactly(:endpoint, :credential, :http, :logger)
            expect(Gotenberg::CONVERT_PATH).to eq('/forms/chromium/convert/html')
            expect(Gotenberg::CONVERT_PATH).to be_frozen
          end
        end
      end
    end
  end
end
