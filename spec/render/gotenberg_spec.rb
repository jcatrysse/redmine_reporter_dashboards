# frozen_string_literal: true

require 'base64'
require 'socket'
require 'timeout'

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/render/engines/gotenberg'
require_relative '../../lib/redmine_reporter_dashboards/render/engine_catalogue'
require_relative '../../lib/redmine_reporter_dashboards/render/renderer'
require_relative '../../lib/redmine_reporter_dashboards/render/preflight_suite'
require_relative '../../lib/redmine_reporter_dashboards/render/preflight_command'

# HOISTED OUT OF THE PRODUCTION NAMESPACE, and HANDOVER §1 is why: a constant assigned
# inside `RSpec.describe Gotenberg` lands on `Render::Engines`, because the block's lexical
# scope is wherever the `module` keywords put it. An independent review measured what this
# file was leaking:
#
#     Engines.constants -> [:AUTHENTICATED, :CREDENTIAL, :FakeGotenberg, :OPEN_ENDPOINT,
#                           :PDF, :PLATE, :RecordingHttp]
#     Engines::CREDENTIAL -> ["rrd", "s3cret"]
#
# A live password as a process-global on a production namespace, and `Engines::PDF` waiting
# for the second file to want that name. One module named after the file, as
# `ReportRunSpecSupport` does.
module GotenbergSpecSupport
  # A recording transport. It captures what the adapter sent and answers whatever the
  # example scripted — the same shape T-33's fetcher specs use, and for the same reason: a
  # request asserted by reading the source is a request nobody has seen.
  class RecordingHttp
    Call = Struct.new(:base, :request, :seconds, keyword_init: true)

    attr_reader :calls

    def initialize(&responder)
      @calls = []
      @responder = responder
    end

    def to_proc
      lambda do |base, request, seconds|
        @calls << Call.new(base: base, request: request, seconds: seconds)
        @responder.call(request, @calls.length)
      end
    end
  end

  # A real PDF is not needed — `Renderer` is the only thing that checks the bytes, and
  # where an example is about the bytes it uses this.
  PDF = "%PDF-1.4\n#{'x' * 2_000}\n%%EOF\n".b

  # Answers every request 200 with a PDF, exactly as a Gotenberg started without
  # `--api-enable-basic-auth` does.
  class FakeGotenberg
    attr_reader :port, :paths

    def initialize(pdf)
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr[1]
      @paths = []
      @pdf = pdf
      @thread = Thread.new { serve }
    end

    def stop
      @server.close
      @thread.kill
    rescue IOError
      nil
    end

    private

    def serve
      loop do
        client = @server.accept
        handle(client)
      rescue IOError, Errno::EBADF
        break
      end
    end

    def handle(client)
      request_line = client.gets.to_s
      @paths << request_line.split[1]
      length = 0
      while (line = client.gets) && line != "\r\n"
        length = line.split(':', 2).last.to_i if line.downcase.start_with?('content-length:')
      end
      client.read(length) if length.positive?

      body = @paths.last.to_s.end_with?('/version') ? '8.35.0' : @pdf
      client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Content-Type: application/pdf\r\n\r\n")
      client.write(body)
      client.close
    end
  end
end

module RedmineReporterDashboards
  module Render
    module Engines
      # WHAT THIS FILE PROVES, and what `spec/conformance` proves instead.
      #
      # The corpus proves the engine DID the right thing and needs a container. This file
      # proves the adapter ASKED for the right thing and needs nothing — it runs in the
      # ordinary `rspec` job, on four Redmine branches, on every push. For an engine whose
      # whole failure surface is a wire format, that is most of the risk.
      #
      # TWO EXCEPTIONS, both because a check nobody has watched fail is not a check:
      #
      #   * the credential check STANDS UP A REAL UNAUTHENTICATED LISTENER (`FakeGotenberg`
      #     below, a TCPServer answering 200) rather than stubbing the transport, because
      #     T-34's Accept says the failure must be OBSERVED. A stub that returns 200 tests
      #     the branch; a socket that answers 200 tests the check.
      #   * `spec/render/gotenberg_service_spec.rb` runs the same assertions against the
      #     real container, gated on it being there.
      #
      # Read every example here as "the adapter asked for X", never as "Gotenberg did X".
      RSpec.describe Gotenberg do
        # METHODS, NOT CONSTANTS. Even `RecordingHttp = GotenbergSpecSupport::RecordingHttp`
        # would put the name back on `Render::Engines`, which is the thing being fixed.
        def recording_http(&responder)
          GotenbergSpecSupport::RecordingHttp.new(&responder)
        end

        def pdf_bytes
          GotenbergSpecSupport::PDF
        end

        def ok(body = pdf_bytes)
          response = Net::HTTPOK.new('1.1', '200', 'OK')
          allow(response).to receive(:body).and_return(body)
          response
        end

        def status(klass, code, body = '')
          response = klass.new('1.1', code, 'x')
          allow(response).to receive(:body).and_return(body)
          response
        end

        def adapter(responder = nil, **options)
          http = recording_http(&(responder || ->(_req, _n) { ok }))
          [described_class.new(endpoint: 'http://gotenberg.test:3000',
                               credential: %w[user pass], http: http.to_proc, **options), http]
        end

        def request(**overrides)
          DocumentRequest.new(body: '<html><body>x</body></html>', correlation_id: 'spec',
                              **overrides)
        end

        # Parses a captured multipart body back into parts. An INDEPENDENT reader rather
        # than a regexp over the string the adapter built, because a body asserted with
        # `include?` passes against a form whose boundaries are wrong.
        def parts_of(request)
          boundary = request['Content-Type'][/boundary=(.+)\z/, 1]
          raise 'no boundary' if boundary.nil?

          request.body.split("--#{boundary}").filter_map do |chunk|
            next if chunk.strip.empty? || chunk.start_with?('--')

            head, body = chunk.sub(/\A\r\n/, '').split("\r\n\r\n", 2)
            disposition = head[/Content-Disposition:[^\r\n]*/]
            { name: disposition[/name="([^"]*)"/, 1],
              filename: disposition[/filename="([^"]*)"/, 1],
              content_type: head[/Content-Type:\s*([^\r\n]*)/, 1],
              body: body.to_s.sub(/\r\n\z/, '') }
          end
        end

        # THE VERSION PROBE IS A CALL TOO. `Success` is stamped with `#version`, which is
        # probed from the service and memoised — so the FIRST render of an adapter makes
        # two requests, and an assertion that counts calls or reads `calls.first` without
        # saying which it means is measuring the wrong one. Every example that is about
        # the form goes through here.
        def conversions(http)
          http.calls.reject { |call| call.request.path.end_with?('/version') }
        end

        def fields_of(request)
          parts_of(request).reject { |p| p[:filename] }
                           .each_with_object({}) { |p, out| out[p[:name]] = p[:body] }
        end

        def files_of(request)
          parts_of(request).select { |p| p[:filename] }
                           .each_with_object({}) { |p, out| out[p[:filename]] = p }
        end

        # ------------------------------------------------------------------
        describe 'registration and declaration' do
          it 'is registered under its own id' do
            expect(Registry.fetch(:gotenberg)).to eq(described_class)
          end

          it 'declares exactly what config/capabilities.yml declares for it' do
            declared = EngineCatalogue.load['gotenberg'].capabilities
            expect(described_class::CAPABILITIES.sort).to eq(declared.sort)
          end

          # THE ONE THAT MAKES F-16's REMAINING HALF REAL. Before this adapter no shipped
          # engine declared `:asset_upload`, so `Assets::Resolver` always chose `:inline`
          # and `DocumentRequest#assets` was always empty.
          it 'declares :asset_upload and NOT :asset_inline, so the resolver chooses upload' do
            expect(described_class::CAPABILITIES).to include(:asset_upload)
            expect(described_class::CAPABILITIES).not_to include(:asset_inline)
          end

          it 'declares no egress capability at all' do
            expect(described_class::CAPABILITIES).not_to include(:asset_http)
          end

          it 'is not the default engine' do
            expect(EngineCatalogue.load.default_engine.id).to eq('chromium_cdp')
            expect(EngineCatalogue.load['gotenberg'].default).to be(false)
          end
        end

        # ------------------------------------------------------------------
        # T-34's Accept: "Default engine unchanged — a test asserts auto-detect never
        # selects `:gotenberg`."
        #
        # THE HONEST VERSION OF THAT TEST IS NOT "ask the real registry and check the
        # answer is not gotenberg". `Registry.ids` is `keys.sort`, so `chromium_cdp` sorts
        # before `gotenberg` and that assertion passes against the OLD fallback, which
        # was `ids.first` — an alphabetical accident. It is a test that cannot fail, which
        # is what two of the last three reviews found three of.
        #
        # So the discriminator is the rule itself: an engine the catalogue says NEEDS A
        # SERVICE is never auto-selectable, whatever it is called and whatever sorts
        # first. `spec/reporting/report_run_spec.rb` drives the same rule through the
        # resolver with gotenberg registered FIRST.
        describe 'auto-detection' do
          let(:catalogue) { EngineCatalogue.load }

          it 'never offers an engine that needs a service' do
            expect(catalogue['gotenberg'].needs_service).to be(true)
            expect(catalogue.auto_selectable?('gotenberg')).to be(false)
          end

          it 'offers the two engines that need nothing' do
            expect(catalogue.auto_selectable?('chromium_cdp')).to be(true)
            expect(catalogue.auto_selectable?('wkhtmltopdf')).to be(true)
          end

          # NOT FAIL-CLOSED, and that was measured rather than chosen. The first version
          # refused every id the catalogue does not carry, which is the instinct this
          # project usually rewards — and it broke 112 tests, because
          # `Registry.isolated { register(:fake, …) }` is how an adapter is stood up all
          # over the suite, and it would equally exclude an adapter another plugin
          # registers. The rule is "never one that SAYS it needs a service"; an absent
          # entry says nothing.
          it 'does not refuse an engine the catalogue has never heard of' do
            expect(catalogue['not_an_engine']).to be_nil
            expect(catalogue.auto_selectable?('not_an_engine')).to be(true)
          end

          it 'names the declared default rather than whatever sorts first' do
            expect(catalogue.default_engine_id).to eq('chromium_cdp')
          end
        end

        # ------------------------------------------------------------------
        describe 'the forbidden route' do
          # The gate asserts the STRING is absent from the tree; this asserts the
          # BEHAVIOUR, so the two fail independently. A gate can be edited.
          it 'only ever posts convert/html, whatever the request asks for' do
            engine, http = adapter
            engine.render(request(page_size: 'A3', orientation: :landscape))
            engine.render(request(readiness: Readiness.new))

            paths = conversions(http).map { |call| call.request.path }
            expect(paths).to all(end_with('/forms/chromium/convert/html'))
            expect(paths.length).to eq(2)
            expect(http.calls.map { |c| c.request.path }.join).not_to include('convert/url')
          end
        end

        # ------------------------------------------------------------------
        describe 'the multipart form' do
          it 'sends the document as index.html' do
            engine, http = adapter
            engine.render(request(body: '<p>THE-BODY</p>'))

            index = files_of(http.calls.first.request)['index.html']
            expect(index[:name]).to eq('files')
            expect(index[:content_type]).to eq('text/html')
            expect(index[:body]).to eq('<p>THE-BODY</p>')
          end

          it 'sends each resolved asset as a sibling file under its own name' do
            engine, http = adapter
            engine.render(request(assets: {
                                    'rrd-asset-aaa.png' => { 'bytes' => "\x89PNG\r\n".b,
                                                             'content_type' => 'image/png' },
                                    'rrd-asset-bbb.css' => { 'bytes' => 'body{}',
                                                             'content_type' => 'text/css' }
                                  },
                                  required_capabilities: [:asset_upload],
                                  essential_capabilities: [:asset_upload]))

            files = files_of(http.calls.first.request)
            expect(files.keys).to contain_exactly('index.html', 'rrd-asset-aaa.png',
                                                  'rrd-asset-bbb.css')
            expect(files['rrd-asset-aaa.png'][:body].b).to eq("\x89PNG\r\n".b)
            expect(files['rrd-asset-aaa.png'][:content_type]).to eq('image/png')
          end

          it 'accepts symbol-keyed assets as well as string-keyed ones' do
            engine, http = adapter
            engine.render(request(assets: { 'a.png' => { bytes: 'B', content_type: 'image/png' } },
                                  required_capabilities: [:asset_upload],
                                  essential_capabilities: [:asset_upload]))

            expect(files_of(http.calls.first.request)['a.png'][:body]).to eq('B')
          end

          # A NAME IS A HEADER VALUE AND A PATH AT THE SAME TIME. Both injections are one
          # regexp away, and both are refused before a byte is sent.
          {
            'a path' => 'a/../../etc/passwd',
            'a quote that reopens the disposition' => 'a"; filename="evil.html',
            'a newline that starts a new header' => "a\r\nContent-Type: text/html",
            'an empty name' => '',
            'a leading dot' => '.hidden'
          }.each do |what, name|
            it "refuses #{what} as an asset name, and sends nothing" do
              engine, http = adapter
              result = engine.render(request(assets: { name => { 'bytes' => 'x',
                                                                 'content_type' => 'text/plain' } },
                                             required_capabilities: [:asset_upload],
                                             essential_capabilities: [:asset_upload]))

              expect(result).to be_failure
              expect(result.code).to eq(:internal)
              expect(result.detail).to include('not a plain file name')
              expect(http.calls).to be_empty
            end
          end

          it 'accepts the name shape the resolver actually produces' do
            engine, http = adapter
            name = "rrd-asset-#{'a' * 32}.png"
            engine.render(request(assets: { name => { 'bytes' => 'x', 'content_type' => 'image/png' } },
                                  required_capabilities: [:asset_upload],
                                  essential_capabilities: [:asset_upload]))

            expect(files_of(conversions(http).first.request).keys).to include(name)
          end

          # A body containing the boundary would split the request somewhere the adapter
          # did not choose. The boundary is random per request AND checked.
          it 'never uses a boundary that occurs in any part body' do
            engine, http = adapter
            engine.render(request(body: 'x' * 50))

            captured = http.calls.first.request
            boundary = captured['Content-Type'][/boundary=(.+)\z/, 1]
            expect(boundary).to start_with('----rrd')
            # One opening delimiter per part, plus the closing one. Nothing else — a body
            # that contained the boundary would show up as an extra occurrence here.
            expect(captured.body.scan(boundary).length).to eq(parts_of(captured).length + 1)
          end
        end

        # ------------------------------------------------------------------
        describe 'the geometry, in the units this route speaks' do
          # THE PAGE IS SENT PORTRAIT AND THE FLAG ROTATES IT — doing both cancels out.
          # MEASURED: `landscape=true` rotates whatever dimensions it is given, so the
          # first version (swap here AND set the flag) produced a PORTRAIT page for every
          # landscape report, with nothing failing except conformance fixture F-03.
          it 'converts millimetres to inches and lets the flag do the rotation' do
            engine, http = adapter
            engine.render(request(page_size: 'A4', orientation: :landscape,
                                  margins_mm: { 'top' => 25, 'right' => 25,
                                                'bottom' => 25, 'left' => 25 }))

            fields = fields_of(http.calls.first.request)
            expect(fields['landscape']).to eq('true')
            # NOT swapped. The flag is the only thing that rotates.
            expect(fields['paperWidth']).to eq('8.2677')
            expect(fields['paperHeight']).to eq('11.6929')
            expect(fields['marginTop']).to eq('0.9843')
          end

          it 'sends the same page dimensions either way round, and only the flag differs' do
            engine, http = adapter
            engine.render(request(page_size: 'A4'))
            engine.render(request(page_size: 'A4', orientation: :landscape))

            portrait = fields_of(conversions(http)[0].request)
            landscape = fields_of(conversions(http)[1].request)
            expect(landscape.values_at('paperWidth', 'paperHeight'))
              .to eq(portrait.values_at('paperWidth', 'paperHeight'))
            expect([portrait['landscape'], landscape['landscape']]).to eq(%w[false true])
          end

          it 'keeps A4 portrait the way round it was asked for' do
            engine, http = adapter
            engine.render(request(page_size: 'A4'))

            fields = fields_of(http.calls.first.request)
            expect(fields['paperWidth']).to eq('8.2677')
            expect(fields['paperHeight']).to eq('11.6929')
            expect(fields['landscape']).to eq('false')
          end

          it 'uses the size the request named, not always A4' do
            engine, http = adapter
            engine.render(request(page_size: 'Letter'))

            expect(fields_of(http.calls.first.request)['paperWidth']).to eq('8.5')
          end

          # Chromium's own default is false, and every badge in the shipped templates is a
          # CSS background.
          it 'asks for backgrounds by default, and does not when told not to' do
            engine, http = adapter
            engine.render(request)
            engine.render(request(print_backgrounds: false))

            expect(fields_of(conversions(http)[0].request)['printBackground']).to eq('true')
            expect(fields_of(conversions(http)[1].request)['printBackground']).to eq('false')
          end

          it 'asks for print media and never lets the engine choose the page size' do
            engine, http = adapter
            engine.render(request)

            fields = fields_of(http.calls.first.request)
            expect(fields['emulatedMediaType']).to eq('print')
            expect(fields['preferCssPageSize']).to eq('false')
          end

          it 'sends a document title as metadata when there is one, and no field when not' do
            engine, http = adapter
            engine.render(request(pdf_metadata: { 'title' => 'Quarter "3"' }))
            engine.render(request)

            expect(fields_of(conversions(http)[0].request)['metadata'])
              .to eq('{"Title":"Quarter \"3\""}')
            expect(fields_of(conversions(http)[1].request)).not_to have_key('metadata')
          end
        end

        # ------------------------------------------------------------------
        describe 'page furniture' do
          it 'sends the footer as footer.html with this engine\'s token spelling' do
            engine, http = adapter
            engine.render(request(footer: PageFurniture.new(center: 'Page {{page}} of {{pages}}')))

            footer = files_of(http.calls.first.request)['footer.html']
            expect(footer[:body]).to include('<span class="pageNumber"></span>')
            expect(footer[:body]).to include('<span class="totalPages"></span>')
          end

          # F-04's two lessons, inherited rather than rediscovered.
          it 'protects the spaces, which the furniture document would otherwise collapse' do
            engine, http = adapter
            engine.render(request(footer: PageFurniture.new(center: 'Page {{page}}')))

            expect(files_of(http.calls.first.request)['footer.html'][:body])
              .to include('Page&nbsp;<span class="pageNumber">')
          end

          it 'escapes literal slot text rather than interpolating it raw' do
            engine, http = adapter
            engine.render(request(footer: PageFurniture.new(left: '<b>x</b>')))

            body = files_of(http.calls.first.request)['footer.html'][:body]
            expect(body).to include('&lt;b&gt;x&lt;/b&gt;')
            expect(body).not_to include('<b>x</b>')
          end

          it 'sends no furniture file when there is no furniture' do
            engine, http = adapter
            engine.render(request)

            expect(files_of(http.calls.first.request).keys).to eq(['index.html'])
          end
        end

        # ------------------------------------------------------------------
        describe 'readiness' do
          # MEASURED against 8.35.0: without the `!!` the expression evaluates to
          # `undefined` before the chart shell has run, and Gotenberg answers
          # `400 … returned an exception or undefined` in 0.2 s — so the contract's
          # "wait, then render anyway" never starts and every chart-bearing report fails.
          it 'coerces the readiness expression to a boolean' do
            engine, http = adapter
            engine.render(request(readiness: Readiness.new))

            expression = fields_of(http.calls.first.request)['waitForExpression']
            expect(expression).to eq("!!(#{Readiness::EXPRESSION})")
            expect(expression).to start_with('!!(')
          end

          it 'asks for no readiness when the request wanted none' do
            engine, http = adapter
            engine.render(request)

            expect(fields_of(http.calls.first.request)).not_to have_key('waitForExpression')
          end

          # THE CONTRACT: on timeout the engine still renders, and the result says what
          # was lost. Gotenberg cannot do that in one request, so the adapter pays for it
          # in a second one — which is the abstraction working rather than leaking.
          it 'renders anyway after a readiness timeout, and records the degradation' do
            engine, http = adapter(lambda { |req, n|
              raise Net::ReadTimeout if n == 1 && fields_of(req).key?('waitForExpression')

              ok
            })

            result = engine.render(request(readiness: Readiness.new(timeout_ms: 100,
                                                                    client_timeout_ms: 50),
                                           timeout_ms: 5_000))

            expect(result).to be_success
            expect(result.degradations.map(&:capability)).to eq([:readiness_timeout])
            expect(conversions(http).length).to eq(2)
            expect(fields_of(conversions(http)[1].request)).not_to have_key('waitForExpression')
          end

          it 'turns the same timeout into a typed failure when strict was asked for' do
            engine, http = adapter(->(_req, _n) { raise Net::ReadTimeout })

            result = engine.render(request(readiness: Readiness.new(timeout_ms: 100,
                                                                    client_timeout_ms: 50,
                                                                    strict: true),
                                           timeout_ms: 5_000))

            expect(result).to be_failure
            expect(result.code).to eq(:readiness_timeout)
            # NO RETRY. Strict means the caller would rather have nothing.
            expect(conversions(http).length).to eq(1)
          end

          # The first draft retried on EVERY timeout, including one with no readiness at
          # all — so a request with `timeout_ms: 30_000` spent it twice before failing.
          it 'does NOT retry a plain timeout when no readiness was asked for' do
            engine, http = adapter(->(_req, _n) { raise Net::ReadTimeout })

            result = engine.render(request(timeout_ms: 200))

            expect(result).to be_failure
            expect(result.code).to eq(:timeout)
            expect(conversions(http).length).to eq(1)
          end

          it 'fails rather than looping when the retry times out too' do
            engine, http = adapter(->(_req, _n) { raise Net::ReadTimeout })

            result = engine.render(request(readiness: Readiness.new(timeout_ms: 100,
                                                                    client_timeout_ms: 50),
                                           timeout_ms: 5_000))

            expect(result).to be_failure
            expect(result.code).to eq(:timeout)
            expect(conversions(http).length).to eq(2)
          end

          # The readiness budget must not outrun the request's own deadline.
          it 'never waits longer for readiness than the request allows in total' do
            engine, http = adapter
            engine.render(request(readiness: Readiness.new(timeout_ms: 10_000,
                                                           client_timeout_ms: 8_000),
                                  timeout_ms: 2_000))

            expect(conversions(http).first.seconds).to be <= 2.0
          end
        end

        # ------------------------------------------------------------------
        # THREE EXAMPLES THAT EXIST BECAUSE A MUTATION SURVIVED WITHOUT THEM. An
        # independent review ran seventeen of its own choosing and thirteen lived; these
        # are the three it proved non-equivalent BY CONSTRUCTING the observable difference.
        describe 'the things the first round of mutations walked straight through' do
          # M4: `timeout_ms: remaining_ms(deadline)` -> `request.timeout_ms` survived the
          # whole suite, because every readiness example used a double that raises
          # INSTANTLY — no time passes, so the retry's remaining budget and the full
          # request budget are the same number. A transport that actually SPENDS its
          # budget is what separates them.
          it 'spends the request deadline ONCE across the readiness retry, not twice' do
            spent = []
            http = nil
            # The double reads the budget the adapter chose for THIS call and burns it —
            # which is the only way the two branches differ, and why a raise-instantly
            # double could never have told them apart.
            engine, http = adapter(lambda { |_req, _n|
              seconds = http.calls.last.seconds
              spent << seconds
              sleep(seconds)
              raise Net::ReadTimeout
            })

            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            engine.render(request(readiness: Readiness.new(timeout_ms: 400,
                                                           client_timeout_ms: 200),
                                  timeout_ms: 800))
            elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000

            expect(spent.length).to eq(2)
            # The mutant spends 400 + 800 = 1_200 ms against a stated bound of 800.
            expect(spent.sum).to be <= 0.9
            expect(elapsed_ms).to be < 1_100
          end

          # M6: `body.to_s.dup.b` -> `body.to_s` survived, because every body, footer slot,
          # asset and metadata title in this file is pure ASCII — in a plugin that ships
          # nine locales, and against HANDOVER §1's three separate entries on this exact
          # class of bug. The mutant raises `Encoding::CompatibilityError` and sends
          # NOTHING, while blaming the network for it.
          it 'sends a document with non-ASCII text, an accented footer and a title' do
            engine, http = adapter
            result = engine.render(request(
                                     body: '<p>Wintersemester — Bericht über Rückstände · 費用</p>',
                                     footer: PageFurniture.new(center: 'Seite {{page}} — Bericht'),
                                     pdf_metadata: { 'title' => 'Rapport trimestriel — coûts' },
                                     assets: { 'rrd-asset-e.css' => {
                                       'bytes' => "body{content:'é'}", 'content_type' => 'text/css'
                                     } },
                                     required_capabilities: [:asset_upload],
                                     essential_capabilities: [:asset_upload]
                                   ))

            expect(result).to be_success
            body = conversions(http).first.request.body
            expect(body.encoding).to eq(Encoding::ASCII_8BIT)
            expect(body).to include('Rückstände'.b)
            expect(body).to include('Seite'.b)
            expect(body).to include('coûts'.b)
          end

          # Minor 13: `{0,127}` in SAFE_ASSET_NAME had no boundary test, and widening it to
          # `{0,4096}` survived. AT the limit and ONE PAST it, which CLAUDE.md §3 phase 3
          # requires of every limit.
          it 'accepts an asset name AT the length cap and refuses one past it' do
            at_cap = "a#{'b' * 127}"
            past_cap = "a#{'b' * 128}"
            expect(at_cap.length).to eq(128)

            engine, http = adapter
            engine.render(request(assets: { at_cap => { 'bytes' => 'x', 'content_type' => 'text/css' } },
                                  required_capabilities: [:asset_upload],
                                  essential_capabilities: [:asset_upload]))
            expect(files_of(conversions(http).first.request).keys).to include(at_cap)

            other, other_http = adapter
            result = other.render(request(assets: { past_cap => { 'bytes' => 'x',
                                                                  'content_type' => 'text/css' } },
                                          required_capabilities: [:asset_upload],
                                          essential_capabilities: [:asset_upload]))
            expect(result).to be_failure
            expect(other_http.calls).to be_empty
          end
        end

        # ------------------------------------------------------------------
        # The two security defects an independent review found by measurement. Both were
        # invisible to every other example here for the same reason: everything in this
        # file talks to loopback and pure ASCII.
        describe 'what the transport must NOT do' do
          # `Net::HTTP.start(host, port, use_ssl: …)` leaves `p_addr` at its `:ENV`
          # default, so the socket goes wherever `http_proxy` points. Measured against a
          # listening fake proxy: the whole multipart report AND
          # `Authorization: Basic …` arrived there. Loopback endpoints hide it, because
          # `URI::Generic#find_proxy` returns nil for `127.*`.
          # A LOOPBACK ENDPOINT CANNOT TEST THIS, and the first version of this example was
          # loopback and survived the mutation. `URI::Generic#find_proxy` returns nil for
          # `127.*` and for `localhost`, so with the endpoint on loopback the proxy is
          # never consulted and `p_addr: :ENV` and `p_addr: nil` behave identically — which
          # is also precisely why the defect was invisible in every spec and in both CI
          # containers. Two halves, because each is weak alone:
          #
          #   the ARGUMENT — the claim is about the third positional, so it is asserted on
          #     the call, which is the `update_columns` lesson from HANDOVER §1;
          #   the BEHAVIOUR — against 192.0.2.1 (TEST-NET-1, guaranteed unroutable) a
          #     proxied request reaches a listener on loopback and a direct one cannot.
          it 'passes nil for p_addr, so an ambient proxy cannot redirect the request' do
            captured = nil
            allow(Net::HTTP).to receive(:start) do |*args, **_kwargs|
              captured = args
              raise Errno::ECONNREFUSED
            end

            with_env('http_proxy' => 'http://127.0.0.1:9', 'HTTP_PROXY' => 'http://127.0.0.1:9') do
              described_class.new(endpoint: 'http://gotenberg.test:3000', credential: %w[u p])
                             .render(request(timeout_ms: 1_000))
            end

            expect(captured.length).to eq(3),
                                       'Net::HTTP.start was called without a p_addr argument, so it ' \
                                       'defaults to :ENV and the socket follows http_proxy'
            expect(captured[2]).to be_nil
          end

          it 'and behaviourally: nothing reaches a proxy that http_proxy points at' do
            seen = []
            proxy = TCPServer.new('127.0.0.1', 0)
            thread = Thread.new do
              client = proxy.accept
              seen << client.gets.to_s
              client.close
            rescue IOError, Errno::EBADF
              nil
            end

            result = with_env('http_proxy' => "http://127.0.0.1:#{proxy.addr[1]}",
                              'HTTP_PROXY' => "http://127.0.0.1:#{proxy.addr[1]}") do
              # THE PRECONDITION, ASSERTED. Without it this example cannot tell "the
              # adapter refused the proxy" from "Ruby was never going to use one here",
              # and the second is what it actually measured for its first two versions.
              expect(URI.parse('http://192.0.2.9:3000').find_proxy).not_to be_nil
              # TEST-NET-1, and `.9` RATHER THAN `.1`. The first version used 192.0.2.1
              # and the mutation SURVIVED it: this container's `no_proxy` contains `::1`,
              # URI's scanner reduces that to the host `1`, and the rule is
              # `hostname.end_with?(".#{p_host}")` — so `192.0.2.1` matched `.1` and was
              # never proxied whatever `p_addr` said. The example escaped one vacuity trap
              # into another; the precondition below is what stops it happening a third
              # time.
              described_class.new(endpoint: 'http://192.0.2.9:3000', credential: %w[u p])
                             .render(request(timeout_ms: 1_000))
            end

            expect(result).to be_failure
            expect(seen).to be_empty,
                            "the proxy received #{seen.inspect} — the report and the " \
                            'credential went somewhere the operator did not configure'
          ensure
            proxy&.close
            thread&.kill
          end

          # E-27 row 11: the `use_ssl: false` mutation SURVIVED the whole suite — there was
          # no HTTPS coverage anywhere, so an https endpoint silently spoken in plaintext
          # (credential, report and all) was invisible. Two halves, like the proxy pair
          # above and for the same reason:
          #
          #   the ARGUMENT — the claim is about what `Net::HTTP.start` is handed, so it is
          #     asserted on the call, for BOTH schemes;
          #   the BEHAVIOUR — against a plaintext listener, an https endpoint's first bytes
          #     on the wire must be a TLS ClientHello (0x16), never an HTTP request line.
          it 'pins use_ssl to the endpoint scheme, on the call itself' do
            captured = {}
            allow(Net::HTTP).to receive(:start) do |*_args, **kwargs|
              captured = kwargs
              raise Errno::ECONNREFUSED
            end

            described_class.new(endpoint: 'https://gotenberg.test:3443', credential: %w[u p])
                           .render(request(timeout_ms: 1_000))
            expect(captured[:use_ssl]).to be(true),
                                          'an https endpoint did not ask for TLS — the credential ' \
                                          'and the report would cross the network in plaintext'

            described_class.new(endpoint: 'http://gotenberg.test:3000', credential: %w[u p])
                           .render(request(timeout_ms: 1_000))
            expect(captured[:use_ssl]).to be(false)
          end

          it 'and behaviourally: an https endpoint puts TLS on the wire, not the request' do
            server = TCPServer.new('127.0.0.1', 0)
            first_bytes = nil
            thread = Thread.new do
              client = server.accept
              first_bytes = client.read(5).to_s
              client.close
            rescue IOError, Errno::EBADF
              nil
            end

            result = described_class.new(endpoint: "https://127.0.0.1:#{server.addr[1]}",
                                         credential: %w[u p])
                                    .render(request(timeout_ms: 2_000))
            thread.join(5)

            expect(result).to be_failure
            expect(first_bytes).not_to be_nil, 'nothing reached the listener at all'
            # 0x16 is the TLS handshake content type, the first byte of every ClientHello.
            expect(first_bytes.bytes.first).to eq(0x16),
                                               "expected a TLS ClientHello, got #{first_bytes.inspect} — " \
                                               'the request went out in plaintext'
            expect(first_bytes).not_to match(/\A(GET|POST)/)
          ensure
            server&.close
            thread&.kill
          end

          it 'refuses an endpoint carrying a credential, rather than leaking it into a message' do
            engine = with_env('RRD_GOTENBERG_URL' => nil) do
              described_class.new(endpoint: 'http://user:hunter2@gotenberg.test:3000')
            end
            result = engine.render(request)

            expect(engine.endpoint).to be_nil
            expect(result).to be_failure
            expect(result.message).to include('must not carry a user or password')
            # AND THE PASSWORD IS NOT IN WHAT THE USER SEES. That is the point: this
            # message reaches the diagnostics panel and the scheduled-report failure mail.
            expect(result.message).not_to include('hunter2')
            expect(result.detail.to_s).not_to include('hunter2')
          end

          # E-27 row 9 — the OTHER natural spelling of a credential in a URL. Userinfo
          # was refused because it authenticates nothing here and `@endpoint` travels in
          # six failure messages; a query token has the identical shape (`uri_for` joins
          # request paths onto the endpoint, and resolution drops the base's query), and
          # for a whole release it was accepted, unused and interpolated.
          it 'refuses an endpoint carrying a token in its query string, as it does userinfo' do
            engine = with_env('RRD_GOTENBERG_URL' => nil) do
              described_class.new(endpoint: 'http://gotenberg.test:3000/?token=hunter2')
            end
            result = engine.render(request)

            expect(engine.endpoint).to be_nil
            expect(result).to be_failure
            expect(result.message).to include('query string')
            expect(result.message).to include('RRD_GOTENBERG_USERNAME')
            # AND THE TOKEN IS NOT IN WHAT THE USER SEES — this message reaches the
            # diagnostics panel and the scheduled-report failure mail.
            expect(result.message).not_to include('hunter2')
            expect(result.detail.to_s).not_to include('hunter2')
          end

          it 'refuses a fragment too, and keeps its value out of the message' do
            engine = with_env('RRD_GOTENBERG_URL' => nil) do
              described_class.new(endpoint: 'http://gotenberg.test:3000/#token=hunter2')
            end
            result = engine.preflight

            expect(engine.endpoint).to be_nil
            expect(result).to be_failure
            expect(result.message).not_to include('hunter2')
            expect(result.detail.to_s).not_to include('hunter2')
          end

          # THE SPELLINGS THAT DODGED THE FIRST VERSION OF THIS GUARD, found by an
          # independent review. `URI.parse('gotenberg:3000/?token=abc')` is an OPAQUE
          # URI whose `#query` is nil, so a parsed-URI check never fired for the
          # schemeless spellings — and the value then fell to arms whose messages
          # interpolated `value.inspect` (the scheme arm) or the parser's own message,
          # which repeats the raw value (the InvalidURIError rescue). `hunter2` was
          # demonstrated arriving in a preflight failure message through both. The rule
          # is stronger than "refuse `?`": NO refusal message may carry the value.
          ['gotenberg:3000/?token=hunter2', '127.0.0.1:3000?token=hunter2',
           'user:hunter2@gotenberg:3000', 'ftp://hunter2.example:3000',
           'http://[hunter2'].each do |sneaky|
            it "keeps the refused value out of every message for #{sneaky.inspect}" do
              engine = with_env('RRD_GOTENBERG_URL' => nil) do
                described_class.new(endpoint: sneaky)
              end
              result = engine.preflight

              expect(engine.endpoint).to be_nil
              expect(result).to be_failure
              expect(result.message).not_to include('hunter2')
              expect(result.detail.to_s).not_to include('hunter2')
            end
          end

          # The asset NAME was guarded and the content type — the other header value in
          # the same part — was not. A CRLF there produced 14 Content-Disposition headers
          # for 13 parts.
          it 'refuses an asset content type that could rewrite the request' do
            engine, http = adapter
            result = engine.render(request(
                                     assets: { 'a.css' => {
                                       'bytes' => 'x',
                                       'content_type' => "text/css\r\nContent-Disposition: form-data; name=\"files\"; filename=\"index.html\""
                                     } },
                                     required_capabilities: [:asset_upload],
                                     essential_capabilities: [:asset_upload]
                                   ))

            expect(result).to be_failure
            expect(result.code).to eq(:internal)
            expect(result.detail).to include('not a plain media type')
            expect(http.calls).to be_empty
          end

          it 'still accepts every content type the asset layer can actually produce' do
            engine, http = adapter
            %w[image/png image/svg+xml text/css application/javascript
               font/woff2 text/css;charset=utf-8].each_with_index do |type, i|
              engine.render(request(assets: { "a#{i}.bin" => { 'bytes' => 'x',
                                                               'content_type' => type } },
                                    required_capabilities: [:asset_upload],
                                    essential_capabilities: [:asset_upload]))
            end

            expect(conversions(http).length).to eq(6)
          end
        end

        # ------------------------------------------------------------------
        describe 'the credential' do
          it 'sends basic auth, and no other header a credential could travel in' do
            engine, http = adapter
            engine.render(request)

            captured = http.calls.first.request
            expect(captured['Authorization']).to start_with('Basic ')
            expect(captured['Cookie']).to be_nil
            names = captured.each_header.map { |name, _| name.downcase }
            # `content-length` is absent because Net::HTTP adds it at send time, after the
            # transport seam this double sits on. Everything the ADAPTER sets is here.
            expect(names).to contain_exactly('accept-encoding', 'accept', 'user-agent',
                                             'content-type', 'gotenberg-trace',
                                             'authorization', 'host')
          end

          it 'sends no Authorization header when no credential is configured' do
            http = recording_http { |_req, _n| ok }
            # explicit `credential: nil`, and the environment deliberately left alone —
            # `FROM_ENV` is what separates the two, and this is the example that says so.
            engine = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                         credential: nil, http: http.to_proc)
            engine.render(request)

            expect(http.calls.first.request['Authorization']).to be_nil
          end

          # A half-filled pair is not a credential. Treating `["user", ""]` as one would
          # make the preflight check pass against a service that refuses everybody.
          [[nil, nil], ['user', ''], ['', 'pass'], ['', '']].each do |pair|
            it "treats #{pair.inspect} as no credential at all" do
              http = recording_http { |_req, _n| ok }
              engine = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                           credential: pair, http: http.to_proc)
              engine.render(request)

              expect(http.calls.first.request['Authorization']).to be_nil
            end
          end

          # `credential: nil` MEANS NONE, and it used to mean "look in the environment" —
          # which made every example below green on a clean machine and red in the
          # render-smoke job, which exports RRD_GOTENBERG_*. Asserted against an
          # environment that HAS a credential, so the sentinel cannot quietly go back to
          # being `nil` without this failing.
          it 'distinguishes "no credential" from "I did not say"' do
            with_env('RRD_GOTENBERG_USERNAME' => 'envuser',
                     'RRD_GOTENBERG_PASSWORD' => 'envpass') do
              none = recording_http { |_req, _n| ok }
              described_class.new(endpoint: 'http://gotenberg.test:3000', credential: nil,
                                  http: none.to_proc).render(request)
              expect(none.calls.first.request['Authorization']).to be_nil

              unsaid = recording_http { |_req, _n| ok }
              described_class.new(endpoint: 'http://gotenberg.test:3000',
                                  http: unsaid.to_proc).render(request)
              expect(unsaid.calls.first.request['Authorization']).not_to be_nil
            end
          end

          it 'reads a credential from the environment when none is injected' do
            http = recording_http { |_req, _n| ok }
            with_env('RRD_GOTENBERG_USERNAME' => 'envuser',
                     'RRD_GOTENBERG_PASSWORD' => 'envpass') do
              engine = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                           http: http.to_proc)
              engine.render(request)
            end

            user, password = Base64.decode64(http.calls.first.request['Authorization'].split.last)
                                   .split(':', 2)
            expect([user, password]).to eq(%w[envuser envpass])
          end
        end

        # ------------------------------------------------------------------
        describe 'the correlation id' do
          it 'travels in Gotenberg\'s own trace header so the two logs can be joined' do
            engine, http = adapter
            engine.render(request(correlation_id: 'rrd-abc-123'))

            expect(http.calls.first.request['Gotenberg-Trace']).to eq('rrd-abc-123')
          end

          it 'cannot split the request, whatever the id contains' do
            engine, http = adapter
            engine.render(request(correlation_id: "abc\r\nX-Evil: 1"))

            value = http.calls.first.request['Gotenberg-Trace']
            expect(value).not_to include("\r")
            expect(value).not_to include("\n")
            expect(value).to eq('abc X-Evil: 1')
          end
        end

        # ------------------------------------------------------------------
        describe 'what each answer means' do
          # 401/403 ARE `:engine_misconfigured` AND THE NEIGHBOURS IN THIS TABLE ARE WHY IT
          # IS A TABLE (§Findings E-27 row 3). The service answered — it is not away — and
          # it will answer 401 until a credential changes, which is a sentence only an
          # operator can act on. The other five rows must not move with it: a 503 is the
          # container giving up on a render, a 400/415 is a bug HERE, and a 500 is a crash.
          {
            [Net::HTTPUnauthorized, '401'] => :engine_misconfigured,
            [Net::HTTPForbidden, '403'] => :engine_misconfigured,
            [Net::HTTPServiceUnavailable, '503'] => :timeout,
            [Net::HTTPBadRequest, '400'] => :internal,
            [Net::HTTPUnsupportedMediaType, '415'] => :internal,
            [Net::HTTPInternalServerError, '500'] => :engine_crashed
          }.each do |(klass, code), expected|
            it "maps #{code} to Failure(#{expected})" do
              engine, = adapter(->(_req, _n) { status(klass, code, 'because') })
              result = engine.render(request)

              expect(result).to be_failure
              expect(result.code).to eq(expected)
              expect(result.detail).to include(code)
            end
          end

          it 'reports a refused credential with the environment variables to check' do
            engine, = adapter(->(_req, _n) { status(Net::HTTPUnauthorized, '401') })
            expect(engine.render(request).message).to include('GOTENBERG_API_BASIC_AUTH_USERNAME')
          end

          it 'reports an unreachable service as engine_unavailable, not as a crash' do
            engine, = adapter(->(_req, _n) { raise Errno::ECONNREFUSED })
            result = engine.render(request)

            expect(result.code).to eq(:engine_unavailable)
            expect(result.message).to eq('the render service could not be reached')
          end

          # `Failure#message` is user-facing and must never carry a raw exception.
          it 'keeps the exception out of the user-facing message and in the detail' do
            engine, = adapter(->(_req, _n) { raise Errno::ECONNREFUSED, 'gory internals' })
            result = engine.render(request)

            expect(result.message).not_to include('Errno')
            expect(result.detail).to include('Errno::ECONNREFUSED')
          end

          it 'stamps the engine and a version on every failure, even a cold one' do
            engine, = adapter(->(_req, _n) { raise Errno::ECONNREFUSED })
            result = engine.render(request)

            expect(result.engine).to eq(:gotenberg)
            expect(result.engine_version).to eq('unknown')
            expect(result.correlation_id).to eq('spec')
          end

          it 'records a required capability it does not have as a degradation' do
            engine, = adapter
            result = engine.render(request(required_capabilities: [:tagged_pdf]))

            expect(result).to be_success
            expect(result.degradations.map(&:capability)).to eq([:tagged_pdf])
          end
        end

        # ------------------------------------------------------------------
        # `version_within(deadline)` HAD NO TEST AT ALL — an adversarial QA pass reverted
        # it wholesale, loosened its boundary, dropped its cap and dropped its memo, and
        # all four survived the suite. The stamp is probed from the service, so an
        # un-deadlined probe extends a request that has already stated its bound.
        describe 'the version stamp, which must not extend a request past its deadline' do
          it 'gives up on the stamp rather than the deadline' do
            # A DOUBLE THAT IGNORES ITS BUDGET CANNOT TIME OUT, and the first version of
            # this example returned a version after sleeping past the deadline — measuring
            # nothing. `seconds` is what the adapter chose for THIS call.
            http = nil
            engine, http = adapter(lambda { |req, _n|
              next ok if req.is_a?(Net::HTTP::Post)

              seconds = http.calls.last.seconds
              raise Net::ReadTimeout if seconds < 0.4

              ok('8.35.0')
            })

            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = engine.render(request(timeout_ms: 120))
            elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000

            expect(result).to be_success
            # `unavailable (timeout)` and not `unknown`: it TRIED, inside what was left,
            # and said what happened. Either is honest; the one thing it must not be is a
            # version obtained by spending time the caller did not give it.
            expect(result.engine_version).to eq('unavailable (timeout)')
            expect(elapsed_ms).to be < 300
            # It DID try, within what was left, and gave up on the stamp rather than on
            # the deadline — which is the distinction the fix is about.
            expect(http.calls.count { |c| c.request.path.end_with?('/version') }).to eq(1)
            expect(http.calls.last.seconds).to be < 0.2
          end

          it 'still stamps a real version when there is budget for one' do
            engine, = adapter(->(req, _n) { req.is_a?(Net::HTTP::Post) ? ok : ok('8.35.0') })
            expect(engine.render(request(timeout_ms: 30_000)).engine_version).to eq('8.35.0')
          end

          it 'probes once per adapter, not once per document' do
            engine, http = adapter(->(req, _n) { req.is_a?(Net::HTTP::Post) ? ok : ok('8.35.0') })
            3.times { engine.render(request) }

            expect(http.calls.count { |c| c.request.path.end_with?('/version') }).to eq(1)
          end

          it 'never lets the stamp probe outlive PROBE_TIMEOUT_MS, however long the request is' do
            engine, http = adapter(->(req, _n) { req.is_a?(Net::HTTP::Post) ? ok : ok('8.35.0') })
            engine.render(request(timeout_ms: 600_000))

            probe = http.calls.find { |c| c.request.path.end_with?('/version') }
            expect(probe.seconds).to be <= described_class::PROBE_TIMEOUT_MS / 1000.0
          end
        end

        # ------------------------------------------------------------------
        # A CONSTANT ASSIGNED INSIDE `RSpec.describe` LANDS ON THE ENCLOSING PRODUCTION
        # NAMESPACE (HANDOVER §1). Both Gotenberg spec files leaked, one of them a live
        # password, and the second file was still leaking after the first was fixed —
        # which is what an assertion is for.
        describe 'this spec file itself' do
          # NOT an exact list: which adapters are loaded depends on what else the run
          # required, and an exact list would be red for a reason that is not this one.
          # The subject is the names these two spec files own.
          it 'puts none of its own names on Render::Engines' do
            expect(Engines.constants).not_to include(:PDF, :RecordingHttp, :FakeGotenberg,
                                                     :AUTHENTICATED, :OPEN_ENDPOINT,
                                                     :CREDENTIAL, :PLATE)
          end
        end

        # ------------------------------------------------------------------
        describe 'the endpoint' do
          it 'refuses anything that is not an http(s) URL naming a host' do
            # `''` IS NOT IN THIS LIST ANY MORE. An empty endpoint now means "nobody
            # configured one", which is answered with a typed Failure naming
            # RRD_GOTENBERG_URL rather than by raising out of a constructor that
            # `ReportRun#with_pdf` and the conformance harness both call unguarded.
            ['file:///etc/passwd', 'ftp://host/x', 'not a url', 'http://',
             'gopher://host'].each do |bad|
              expect(described_class.new(endpoint: bad).endpoint).to be_nil,
                                                                     "#{bad.inspect} was accepted"
            end
          end

          # CONSTRUCTION IS TOTAL, AND IT ONLY LOOKED IT. `validate_endpoint!` RAISED, and
          # `ReportRun#with_pdf` does a bare `adapter.new` with no rescue above it — so an
          # adversarial QA pass 500'd the preview page with `RRD_GOTENBERG_URL=gotenberg:3000`,
          # a missing scheme, which is exactly what an operator types after reading the
          # compose file. Only `nil` and `''` had been tested, and only those two were total.
          [nil, '', '   ', "\t", 'gotenberg:3000', 'localhost:3000',
           "http://gotenberg:3000\n", ' http://gotenberg:3000 ', '"http://gotenberg:3000"',
           'http://user:pass@gotenberg:3000', 'http://gotenberg:3000/?token=abc',
           'http://gotenberg:3000/#token=abc'].each do |value|
            it "builds without raising for #{value.inspect}, and refuses in the RESULT" do
              engine = nil
              # THE ENVIRONMENT IS CLEARED. `endpoint: nil` means "I did not say", so with
              # RRD_GOTENBERG_URL exported — which the render-smoke job does — this example
              # would silently test a working adapter. Green here, green there, measuring
              # nothing in both.
              with_env('RRD_GOTENBERG_URL' => nil) do
                expect { engine = described_class.new(endpoint: value) }.not_to raise_error
              end

              result = engine.render(request)
              expect(result).to be_failure
              # NOT `:engine_unavailable`: nothing was reached and nothing is down. There
              # is either no address or an unusable one, and only an operator can change
              # that (§Findings E-27 row 3).
              expect(result.code).to eq(:engine_misconfigured)
              expect(result.message).to include('Gotenberg render service')
              # Every method a caller may reach for, on an adapter that has no endpoint.
              expect(engine.id).to eq(:gotenberg)
              expect(engine.capabilities).to eq(described_class::CAPABILITIES)
              expect(engine.version).to eq('unknown')
              expect(engine.shutdown).to be(true)
              expect(engine.preflight).to be_failure
            end
          end

          it 'says WHICH way the configured address is wrong, not just that it is' do
            result = with_env('RRD_GOTENBERG_URL' => nil) do
              described_class.new(endpoint: 'gotenberg:3000')
            end.preflight

            expect(result.message).to include('cannot be used')
            expect(result.message).to include('http/https')
          end

          # `URI.join(base, '/version')` discards the base's path, so an endpoint under
          # `--api-root-path` was called at the wrong place and answered 404 — which reads
          # as "this is not a Gotenberg".
          it 'keeps a root path, rather than posting to the server root' do
            http = recording_http { |_req, _n| ok }
            engine = described_class.new(endpoint: 'http://host:3000/gotenberg',
                                         credential: %w[u p], http: http.to_proc)
            engine.render(request)

            expect(http.calls.first.request.path).to eq('/gotenberg/forms/chromium/convert/html')
          end

          it 'reads the endpoint from the environment when none is injected' do
            with_env('RRD_GOTENBERG_URL' => 'http://from-env:9999') do
              expect(described_class.new.endpoint).to eq('http://from-env:9999/')
            end
          end
        end

        # ------------------------------------------------------------------
        describe '#version' do
          it 'is probed from the service rather than being a constant' do
            engine, = adapter(->(req, _n) { req.path.end_with?('/version') ? ok('8.35.0') : ok })
            expect(engine.version).to eq('8.35.0')
          end

          it 'says so rather than guessing when the service will not answer' do
            engine, = adapter(->(_req, _n) { raise Errno::ECONNREFUSED })
            expect(engine.version).to start_with('unavailable')
          end
        end

        # ==================================================================
        # PREFLIGHT
        # ==================================================================
        describe '#preflight' do
          # Scripts a whole healthy service, so an example can break exactly one thing.
          def healthy(overrides = {})
            lambda do |req, _n|
              key = req.path.end_with?('/version') ? :version : form_kind(req)
              handler = overrides[key]
              next handler.call(req) if handler

              case key
              when :version then ok('8.35.0')
              when :unauthenticated then status(Net::HTTPUnauthorized, '401')
              when :javascript then status(Net::HTTPConflict, '409', 'console exception')
              else ok
              end
            end
          end

          def form_kind(req)
            return :unauthenticated if req['Authorization'].nil?
            return :javascript if req.body.to_s.include?('failOnConsoleExceptions')

            :render
          end

          it 'passes against a service that is authenticated, current and running JS' do
            engine, = adapter(healthy)
            expect(engine.preflight).to be_success
          end

          # IDENTITY, THEN CREDENTIAL, THEN EVERYTHING ELSE — and nothing renders until
          # all three have passed. The order is the fix for two INV-4 misdiagnoses: a
          # service that is DOWN and one that is NOT A GOTENBERG were both being accused
          # of failing to enforce their credential.
          it 'establishes what it is talking to, then the credential, before rendering' do
            engine, http = adapter(healthy)
            engine.preflight

            paths = http.calls.map { |call| call.request.path }
            # 1. identity, UNAUTHENTICATED — a 401 only means "enforcing" if nothing was
            #    presented, which is the whole reason this probe carries no credential.
            expect(paths.first).to end_with('/version')
            expect(http.calls.first.request['Authorization']).to be_nil
            # 2. the credential arm: is OUR credential accepted, and is the route closed
            #    without one? Two questions, two probes.
            expect(http.calls[1].request['Authorization']).to start_with('Basic ')
            unauthenticated = http.calls.find do |call|
              call.request.path.end_with?('/forms/chromium/convert/html') &&
                call.request['Authorization'].nil?
            end
            expect(unauthenticated).not_to be_nil
            # 3. and the render round trip is last, and authenticated.
            expect(http.calls.last.request['Authorization']).to start_with('Basic ')
          end

          it 'renders nothing at all when a configuration check fails' do
            engine, http = adapter(healthy(unauthenticated: ->(_req) { ok }))
            engine.preflight

            expect(http.calls.map { |c| c.request.body.to_s }.join)
              .not_to include('PREFLIGHT-MARKER')
          end

          # THE MEASUREMENT THIS PROBE EXISTS BECAUSE OF: Gotenberg exempts `/health` from
          # basic auth, so a credential check pointed at it answers 200 on a locked-down
          # service and on a wide-open one alike.
          it 'never probes /health, which is exempt from authentication' do
            engine, http = adapter(healthy)
            engine.preflight

            expect(http.calls.map { |call| call.request.path }).to all(satisfy { |p| !p.include?('/health') })
          end

          context 'when the endpoint answers WITHOUT the configured credential' do
            it 'fails, and names the remediation' do
              engine, = adapter(healthy(unauthenticated: ->(_req) { ok }))
              result = engine.preflight

              expect(result).to be_failure
              expect(result.code).to eq(:engine_misconfigured)
              expect(result.message).to include('WITHOUT the configured credential')
              expect(result.message).to include('--api-enable-basic-auth')
              expect(result.detail).to include('/forms/chromium/convert/html')
            end

            # 400 is what an EMPTY form gets from an open service, and 401 from a closed
            # one. Anything that is not a refusal is the finding.
            [['200', Net::HTTPOK], ['400', Net::HTTPBadRequest],
             ['415', Net::HTTPUnsupportedMediaType]].each do |code, klass|
              it "treats #{code} from the unauthenticated probe as an open service" do
                engine, = adapter(healthy(unauthenticated: ->(_r) { status(klass, code) }))
                expect(engine.preflight).to be_failure
              end
            end

            it 'accepts a 403 as a refusal, the same as a 401' do
              engine, = adapter(healthy(unauthenticated: lambda { |_r|
                status(Net::HTTPForbidden, '403')
              }))
              expect(engine.preflight).to be_success
            end
          end

          context 'when no credential is configured at all' do
            it 'fails, with a different remediation from the one above' do
              http = recording_http(&healthy)
              engine = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                           credential: nil, http: http.to_proc)
              result = engine.preflight

              expect(result).to be_failure
              expect(result.message).to include('without a credential')
              expect(result.message).to include('GOTENBERG_API_BASIC_AUTH_USERNAME')
              expect(result.detail).to include('no credential is configured')
            end

            # An endpoint nobody can reach has proved nothing about its authentication, so
            # the credential arm stays quiet and the round trip reports the real problem.
            it 'blames the transport, not the credential, when the service is down' do
              engine, = adapter(->(_req, _n) { raise Errno::ECONNREFUSED })
              result = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                           credential: %w[u p],
                                           http: ->(*) { raise Errno::ECONNREFUSED }).preflight

              expect(result.message).not_to include('WITHOUT the configured credential')
              expect(engine).to be_a(described_class)
              expect(result).to be_failure
            end
          end

          context 'the version floor' do
            it 'refuses a Gotenberg below the supported major' do
              engine, = adapter(healthy(version: ->(_r) { ok('7.10.2') }))
              result = engine.preflight

              expect(result.code).to eq(:engine_version_unsupported)
              expect(result.message).to include('below the supported floor')
            end

            it 'accepts a later major than the one it was written against' do
              engine, = adapter(healthy(version: ->(_r) { ok('9.0.0') }))
              expect(engine.preflight).to be_success
            end

            # THE IDENTITY CHECK CATCHES THIS FIRST NOW, and says the useful thing. It
            # used to fall through and tell the operator their container was not
            # enforcing its credential — about an nginx.
            it 'refuses something that is not a Gotenberg at all, and says so' do
              engine, = adapter(healthy(version: ->(_r) { ok('<html>hello</html>') }))
              result = engine.preflight

              expect(result).to be_failure
              expect(result.message).to include('does not look like a Gotenberg')
              expect(result.message).not_to include('WITHOUT the configured credential')
            end

            it 'says nothing answered, rather than blaming the credential, when it is down' do
              engine, = adapter(->(_req, _n) { raise Errno::ECONNREFUSED })
              result = engine.preflight

              expect(result.message).to include('nothing answered at')
              expect(result.message).not_to include('WITHOUT the configured credential')
            end
          end

          context 'the JavaScript liveness check' do
            # MEASURED: with `--chromium-disable-javascript` Gotenberg answers 200 to a
            # document whose script throws, AND silently ignores `waitForExpression` — so
            # every chart in every report disappears with nothing failing anywhere.
            it 'fails when a throwing script does NOT produce a console exception' do
              engine, = adapter(healthy(javascript: ->(_r) { ok }))
              result = engine.preflight

              expect(result).to be_failure
              expect(result.message).to include('JavaScript disabled')
              expect(result.message).to include('--chromium-disable-javascript')
              expect(result.detail).to include('answered 200')
            end

            it 'sends a document that actually throws, with failOnConsoleExceptions set' do
              engine, http = adapter(healthy)
              engine.preflight

              probe = http.calls.find { |c| c.request.body.to_s.include?('failOnConsoleExceptions') }
              expect(fields_of(probe.request)['failOnConsoleExceptions']).to eq('true')
              expect(files_of(probe.request)['index.html'][:body]).to include('throw new Error')
            end

            # A timeout is not a pass. The first draft treated it as one, which made this
            # check unable to fail against the service least worth trusting.
            it 'fails rather than passing when the probe times out' do
              engine, = adapter(healthy(javascript: ->(_r) { raise Net::ReadTimeout }))
              result = engine.preflight

              expect(result).to be_failure
              expect(result.message).to include('did not answer the JavaScript check in time')
            end
          end

          # ------------------------------------------------------------------
          # WHOSE PROBLEM IS IT — `:engine_misconfigured` VERSUS `:engine_unavailable`.
          #
          # §Findings E-27 row 3, decided by the curator on 2026-08-11. Written as ONE
          # table rather than as a code assertion added to each existing example, because
          # the thing that has to hold is a BOUNDARY: every row below is a real answer a
          # real Gotenberg gives, and moving any one of them across the line is the defect
          # this block exists to catch. Three of them sit one HTTP status apart from a row
          # on the other side.
          #
          # THE DOUBLE IS SCRIPTED FROM MEASURED BEHAVIOUR, not from `healthy` (HANDOVER
          # §1, 2026-08-11): a locked-down Gotenberg answers **401** to an unauthenticated
          # `/version`, and the friendly default answers 200-with-the-version — which is a
          # service that does not exist and which has already made one mutation in this
          # file unkillable.
          context 'whose problem the failure is' do
            def locked(overrides = {})
              lambda do |req, _n|
                key = if req['Authorization'].nil? && req.path.end_with?('/version')
                        :identity
                      elsif req.path.end_with?('/version')
                        :version
                      elsif req['Authorization'].nil?
                        :unauthenticated
                      elsif req.body.to_s.include?('failOnConsoleExceptions')
                        :javascript
                      else
                        :render
                      end
                handler = overrides[key]
                next handler.call(req) if handler

                case key
                when :identity, :unauthenticated then status(Net::HTTPUnauthorized, '401')
                when :version then ok('8.35.0')
                when :javascript then status(Net::HTTPConflict, '409', 'console exception')
                else ok
                end
              end
            end

            # The control: without it, every row below could be passing because this
            # double fails everything.
            it 'is a double a healthy preflight passes against' do
              engine, = adapter(locked)
              expect(engine.preflight).to be_success
            end

            # THE OVERRIDES ARE BUILT INSIDE THE EXAMPLE, not in the table. `ok` and
            # `status` are example-scope helpers, and a lambda written in the table literal
            # closes over the example GROUP — where neither exists. The first version did
            # exactly that and three of these seven errored with "`status` is not available
            # on an example group", which is a real property of RSpec worth not
            # re-discovering.
            def scenario(name)
              case name
              when :refused_credential
                { version: ->(_r) { status(Net::HTTPUnauthorized, '401') } }
              when :answers_without_credential then { unauthenticated: ->(_r) { ok } }
              when :javascript_off then { javascript: ->(_r) { ok } }
              when :nothing_there then { identity: ->(_r) { raise Errno::ECONNREFUSED } }
              when :name_does_not_resolve
                { identity: ->(_r) { raise SocketError, 'getaddrinfo: Name or service not known' } }
              when :identity_timed_out then { identity: ->(_r) { raise Net::ReadTimeout } }
              when :not_a_gotenberg
                { identity: ->(_r) { status(Net::HTTPNotFound, '404', '<html>nginx</html>') } }
              when :version_not_a_version
                { version: ->(_r) { ok('<html>hello</html>') } }
              when :convert_route_answers_oddly
                { unauthenticated: ->(_r) { status(Net::HTTPServiceUnavailable, '503') } }
              when :javascript_probe_broken
                { javascript: ->(_r) { status(Net::HTTPServiceUnavailable, '503') } }
              when :javascript_probe_timed_out
                { javascript: ->(_r) { raise Net::ReadTimeout } }
              when :javascript_probe_threw then { javascript: ->(_r) { raise IOError, 'pipe' } }
              else {}
              end
            end

            # THE DOUBLE'S OWN PREMISE, ASSERTED. An independent review demonstrated that
            # `locked` can be quietly made friendly again — answering an unauthenticated
            # `/version` 200-with-the-version, as no locked Gotenberg does — and all twelve
            # rows below still pass, against a service that cannot exist. The comment above
            # was the only thing holding it, and a comment is not a control (CLAUDE.md §3).
            #
            # The number is MEASURED against the real container, not chosen:
            #   curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3098/version  ->  401
            it 'is scripted from what a locked Gotenberg really answers, not from convenience' do
              # ASSERTED ON THE SCRIPT ITSELF, with no adapter in the way: the premise is a
              # property of the double, so the double is what is interrogated. Going through
              # `#preflight` would prove only that the run passed, which is what every row
              # below already does — and what survived the friendly-double mutation.
              unauthenticated = Net::HTTP::Get.new(described_class::VERSION_PATH)
              authenticated = Net::HTTP::Get.new(described_class::VERSION_PATH)
              authenticated['Authorization'] = 'Basic dXNlcjpwYXNz'

              expect(locked({}).call(unauthenticated, 1).code).to eq('401')
              expect(locked({}).call(authenticated, 2).code).to eq('200')
            end

            {
              'no credential is configured' =>
                [:engine_misconfigured, nil, :none],
              'the configured credential is refused' =>
                [:engine_misconfigured, %w[user pass], :refused_credential],
              'the service answers the conversion route without the credential' =>
                [:engine_misconfigured, %w[user pass], :answers_without_credential],
              'JavaScript is disabled, which is the VERDICT' =>
                [:engine_misconfigured, %w[user pass], :javascript_off],
              # And the three that must NOT move. Each is one status code away from a row
              # above it, and each is a question this adapter cannot answer from here.
              'nothing is at the address' =>
                [:engine_unavailable, %w[user pass], :nothing_there],
              # THE ONE REACHABILITY FAULT WHOSE REMEDY IS UNAMBIGUOUS (E-29's own
              # recommendation, taken): a host that does not resolve cannot be fixed by
              # starting anything.
              'the configured name does not resolve' =>
                [:engine_misconfigured, %w[user pass], :name_does_not_resolve],
              'nothing answers in time' =>
                [:engine_unavailable, %w[user pass], :identity_timed_out],
              'something answers and is not a Gotenberg' =>
                [:engine_unavailable, %w[user pass], :not_a_gotenberg],
              # FIVE OF THESE ROWS EXIST BECAUSE AN INDEPENDENT REVIEW MOVED THEIR ARMS AND
              # THE WHOLE SUITE STAYED GREEN — 2569 examples, 0 failures, with all five
              # mutants applied at once. The block's own header claims moving any one of them
              # is the defect it exists to catch, and it pinned seven arms out of twelve.
              'the endpoint answered /version with something that is not a version' =>
                [:engine_unavailable, %w[user pass], :version_not_a_version],
              'the conversion route answers something that is not about authentication' =>
                [:engine_unavailable, %w[user pass], :convert_route_answers_oddly],
              'the JavaScript probe could not be COMPLETED, so there is no verdict' =>
                [:engine_unavailable, %w[user pass], :javascript_probe_broken],
              'the JavaScript probe did not answer in time, which is also not a verdict' =>
                [:engine_unavailable, %w[user pass], :javascript_probe_timed_out],
              'the JavaScript probe threw, which is not a verdict either' =>
                [:engine_unavailable, %w[user pass], :javascript_probe_threw]
            }.each do |label, (expected, credential, scenario_name)|
              it "reports #{expected} when #{label}" do
                http = recording_http(&locked(scenario(scenario_name)))
                engine = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                             credential: credential, http: http.to_proc)
                result = engine.preflight

                expect(result).to be_failure
                expect(result.code).to eq(expected)
              end
            end

            # THE CODE IS NOT DECORATION ON THE SENTENCE: it is what a caller branches on,
            # so the two must agree. The claim asserted here is the narrow one that is TRUE —
            # an arm that only knows "nothing answered" does not accuse the credential or
            # JavaScript. The broader sentence this comment used to carry ("an unavailability
            # never claims to know which configuration is wrong") was refuted by an
            # independent review with the shipped 404 message, which does name the address and
            # `--api-root-path`: it is telling an operator the two things it CAN distinguish,
            # which is right, and the code stays `:engine_unavailable` because it cannot tell
            # a wrong path from a service that is down.
            it 'never accuses the credential or JavaScript when it only knows nothing answered' do
              http = recording_http(&locked(identity: ->(_r) { raise Errno::ECONNREFUSED }))
              result = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                           credential: %w[user pass], http: http.to_proc).preflight

              expect(result.code).to eq(:engine_unavailable)
              expect(result.message).not_to include('credential')
              expect(result.message).not_to include('JavaScript')
            end

            # `#preflight` MUST NEVER RAISE (technical-spec.md §5), and an adversarial QA
            # pass measured the one path that did: `check_credential`'s authenticated
            # `/version` probe had no rescue, so a service that answers the identity probe
            # and then stops listening — a restart, an OOM kill, `--force-recreate` — threw
            # `Errno::ECONNREFUSED` out of `#preflight` altogether. Under
            # `verification: pending` that became a skip; at `corpus` it is one conformance
            # example with a raw stack trace reading as a plugin defect.
            #
            # Both the CLASSES that escape and the RESULT are asserted: `send_request` turns
            # only the three timeout classes into `TIMED_OUT`, so each of these reaches the
            # rescue as itself.
            [Errno::ECONNREFUSED, EOFError, Errno::ECONNRESET, SocketError].each do |error|
              it "answers a Failure rather than raising #{error} mid-preflight" do
                calls = 0
                http = recording_http do |req, _n|
                  calls += 1
                  # The identity probe answers, so the sequence gets past `check_reachable`
                  # and into the arm that had no rescue. Anything else dies.
                  next status(Net::HTTPUnauthorized, '401') if calls == 1

                  raise error
                end
                engine = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                             credential: %w[user pass], http: http.to_proc)

                result = nil
                expect { result = engine.preflight }.not_to raise_error
                expect(result).to be_failure
                expect(result.code).to eq(:engine_unavailable)
                expect(result.message).to include('nothing answered at')
                # AND THE CLASS IS IN THE DETAIL RATHER THAN THE MESSAGE, which is the rule
                # for every other transport failure in this adapter.
                expect(result.detail).to include(error.name)
                expect(result.message).not_to include(error.name)
              end
            end

            # AND THE TWO SENTENCES ARE DIFFERENT, which is the half a code alone cannot
            # carry: before this, a name that does not resolve and a socket that refuses both
            # said "nothing answered at …, Confirm the container is running" — the INV-4
            # misdiagnosis shape, with the discriminator sitting unused in `detail`.
            it 'tells a name that does not resolve apart from a socket that refuses' do
              def result_for(scenario_name)
                http = recording_http(&locked(scenario(scenario_name)))
                described_class.new(endpoint: 'http://gotenberg.test:3000',
                                    credential: %w[user pass], http: http.to_proc).preflight
              end

              unresolvable = result_for(:name_does_not_resolve)
              refused = result_for(:nothing_there)

              expect(unresolvable.message).to include('does not resolve')
              expect(unresolvable.message).to include('RRD_GOTENBERG_URL')
              expect(unresolvable.message).not_to include('is running')
              expect(refused.message).to include('nothing answered at')
              expect(refused.message).not_to include('does not resolve')
              # The class stays in the detail and out of the user-facing sentence, as every
              # other transport failure in this adapter does.
              expect(unresolvable.detail).to include('SocketError')
              expect(unresolvable.message).not_to include('SocketError')
            end

            # An unconfigured install: no endpoint at all. This is the one an operator of
            # a fresh install meets, and it is a misconfiguration by definition — there is
            # nothing to be unavailable.
            it 'reports an install that has configured no endpoint as misconfigured' do
              engine = with_env('RRD_GOTENBERG_URL' => nil) { described_class.new }

              expect(engine.preflight.code).to eq(:engine_misconfigured)
              expect(engine.render(request).code).to eq(:engine_misconfigured)
            end
          end

          # E-27 row 10. The identity and credential probes both GET `/version` and threw
          # the body away, so `check_version` fetched it a third time for a fact two
          # earlier probes had already read.
          context 'the version probe is fetched once, not once per check that wants it' do
            it 'asks /version exactly twice — the unauthenticated identity probe and the credential probe' do
              # NOT `healthy`, and the difference is what this example is about: `healthy`
              # answers the UNAUTHENTICATED identity probe 200 with the version, which a
              # real locked-down Gotenberg never does (measured: 401). Scripted that way,
              # the identity memo covers for a deleted credential-probe memo and the
              # mutation survives — the first version of this example did exactly that.
              http = recording_http do |req, _n|
                if req['Authorization'].nil?
                  status(Net::HTTPUnauthorized, '401')
                elsif req.path.end_with?('/version')
                  ok('8.35.0')
                elsif req.body.to_s.include?('failOnConsoleExceptions')
                  status(Net::HTTPConflict, '409', 'console exception')
                else
                  ok
                end
              end
              engine = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                           credential: %w[user pass], http: http.to_proc)
              expect(engine.preflight).to be_success

              version_gets = http.calls.select { |c| c.request.path.end_with?('/version') }
              expect(version_gets.length).to eq(2)
              # And they are the two probes that carry different questions — one with no
              # credential (identity), one with it (acceptance). The version CHECK reads
              # the memo.
              expect(version_gets.map { |c| c.request['Authorization'].nil? }).to eq([true, false])
            end

            it 'learns the version from the identity probe on an open service, with no second fetch' do
              # An OPEN service with no credential: the identity probe reads the version
              # 200 and the credential check then fails without another request — so the
              # report header's `engine.version` must come off the memo, not the wire.
              http = recording_http { |req, _n| req.path.end_with?('/version') ? ok('8.35.0') : ok }
              engine = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                           credential: nil, http: http.to_proc)
              expect(engine.preflight).to be_failure

              fetches = http.calls.count { |c| c.request.path.end_with?('/version') }
              expect(fetches).to eq(1)
              expect(engine.version).to eq('8.35.0')
              expect(http.calls.count { |c| c.request.path.end_with?('/version') }).to eq(1)
            end

            # `engine_version` travels in failure messages, mail and Snapshot rows; a
            # body that opens with a version must contribute ONLY the version. The
            # second body has no whitespace at all — the first token class (`\S*`) kept
            # everything after the version in exactly that case, and an adversarial QA
            # pass is what said so.
            ["8.35.0\ntrailing noise", '8.35.0<script>alert(1)</script>',
             "8.35.0;#{'A' * 500}"].each do |body|
              it "memoises the version token and none of the rest of #{body[0, 24].inspect}" do
                http = recording_http do |req, _n|
                  req.path.end_with?('/version') ? ok(body) : ok
                end
                engine = described_class.new(endpoint: 'http://gotenberg.test:3000',
                                             credential: nil, http: http.to_proc)
                engine.preflight

                expect(engine.version).to eq('8.35.0')
              end
            end

            it 'does not adopt a non-version body as the engine version' do
              engine, = adapter(healthy(version: ->(_r) { ok('<html>login</html>') }))
              result = engine.preflight

              expect(result).to be_failure
              # The junk 200 fails the identity check; memoising its body would stamp
              # `<html>login</html>` into this failure's engine_version.
              expect(result.engine_version).to eq('unknown')
            end
          end

          # The other half of row 10: these hashes carried no `duration_ms`, so the admin
          # page printed "0 ms" for a configuration check that had just spent ten seconds
          # timing out.
          context 'the configuration checks carry their own durations' do
            it 'stamps an integer duration on every check' do
              engine, = adapter(healthy)
              checks = engine.configuration_checks

              expect(checks.length).to eq(4)
              expect(checks.map { |c| c[:duration_ms] }).to all(be_a(Integer))
            end

            it 'measures the check rather than stamping a constant' do
              engine, = adapter(healthy(version: lambda { |_r|
                sleep 0.03
                ok('8.35.0')
              }))
              checks = engine.configuration_checks

              reachable = checks.find { |c| c[:id] == :gotenberg_reachable }
              expect(reachable[:duration_ms]).to be >= 20
            end

            it 'stamps 0 rather than nil on the unconfigured check' do
              engine = with_env('RRD_GOTENBERG_URL' => nil) { described_class.new }
              check = engine.configuration_checks.first

              expect(check[:id]).to eq(:gotenberg_endpoint)
              expect(check[:duration_ms]).to eq(0)
            end
          end

          it 'ends with a real round trip, so a service that answers but cannot draw fails' do
            engine, = adapter(healthy(render: ->(_r) { status(Net::HTTPInternalServerError, '500') }))
            result = engine.preflight

            expect(result).to be_failure
            expect(result.code).to eq(:engine_crashed)
          end
        end

        # ==================================================================
        # A REAL, UNAUTHENTICATED LISTENER
        #
        # T-34's Accept: "a test stands up an unauthenticated instance to prove the failure
        # fires (a security check that is never observed failing is not a check)". A double
        # returning 200 exercises the branch. A socket that answers 200 exercises the CHECK
        # — the URL building, the multipart encode, the real `Net::HTTP` round trip and the
        # status interpretation, none of which the double touches.
        #
        # `spec/render/gotenberg_service_spec.rb` runs the same assertion against a real
        # Gotenberg container where one is available; this runs everywhere, on every push.
        # ==================================================================
        describe 'against a real unauthenticated listener' do
          around do |example|
            @fake = GotenbergSpecSupport::FakeGotenberg.new(pdf_bytes)
            example.run
          ensure
            @fake&.stop
          end

          it 'is OBSERVED failing: a credential is configured and the service answers anyway' do
            engine = described_class.new(endpoint: "http://127.0.0.1:#{@fake.port}",
                                         credential: %w[user pass])
            result = engine.preflight

            expect(result).to be_failure
            expect(result.code).to eq(:engine_misconfigured)
            expect(result.message).to include('WITHOUT the configured credential')
          end

          it 'proves the same listener passes the check once it starts refusing' do
            # The control for the example above. Without it, "it failed" could mean the
            # adapter fails against every listener, which would be a different bug wearing
            # the same green tick.
            refusing = described_class.new(
              endpoint: "http://127.0.0.1:#{@fake.port}", credential: %w[user pass],
              http: lambda { |_base, req, _s|
                next status(Net::HTTPUnauthorized, '401') if req['Authorization'].nil?
                next ok('8.35.0') if req.path.end_with?('/version')
                next status(Net::HTTPConflict, '409') if req.body.to_s.include?('failOnConsoleExceptions')

                ok
              }
            )
            expect(refusing.preflight).to be_success
          end

          # THE EXAMPLE THE WHOLE TASK TURNED OUT TO NEED, and it is deliberately about
          # `PreflightSuite` rather than about `Gotenberg#preflight`.
          #
          # Two independent reviews found the same blocker: every one of these checks was
          # correct, tested, and hung on a method NOTHING IN THE SHIPPED PRODUCT CALLED.
          # The admin page and `rake reporter_dashboards:render:preflight` both go through
          # `Preflight#run`, which only ever rendered a probe document — so against a
          # Gotenberg with no authentication at all, the exact command the README prints
          # returned exit 0 and eight PASSes.
          #
          # So this drives the PRODUCT SURFACE, against a real listener that really does
          # answer without a credential, and asserts the thing an operator would see. An
          # example against the adapter method could not have failed for the right reason,
          # because the adapter method was already right.
          it 'FAILS THE PRODUCT PREFLIGHT, not just the adapter, against an open service' do
            report = with_env('RRD_GOTENBERG_URL' => "http://127.0.0.1:#{@fake.port}",
                              'RRD_GOTENBERG_USERNAME' => 'user',
                              'RRD_GOTENBERG_PASSWORD' => 'pass') do
              PreflightSuite.new(engine_ids: 'gotenberg').reports.first
            end

            expect(report.checks.select(&:failed?).map(&:id)).to eq([:gotenberg_credential])
            expect(report.checks.find(&:failed?).detail)
              .to include('WITHOUT the configured credential')
            # AND NOTHING WAS RENDERED. Eight green document checks under one red
            # configuration check is how a reader concludes the red one is cosmetic — an
            # unauthenticated Gotenberg draws a perfectly good probe document.
            expect(report.checks.map(&:id)).not_to include(:page_breaks)
          end

          it 'and the rake task exits non-zero on it, which is the deploy-gate contract' do
            status = with_env('RRD_GOTENBERG_URL' => "http://127.0.0.1:#{@fake.port}",
                              'RRD_GOTENBERG_USERNAME' => 'user',
                              'RRD_GOTENBERG_PASSWORD' => 'pass') do
              PreflightCommand.new(engine_ids: 'gotenberg', format: :json).call
            end

            expect(status).to eq(PreflightCommand::FAILURES)
          end

          it 'never asks the real listener about /health' do
            described_class.new(endpoint: "http://127.0.0.1:#{@fake.port}",
                                credential: %w[user pass]).preflight

            expect(@fake.paths).not_to be_empty
            expect(@fake.paths).to all(satisfy { |p| !p.to_s.include?('/health') })
          end
        end

        # ------------------------------------------------------------------
        # THE OTHER HALF OF THE SAME BLOCKER. Registering `:gotenberg` at boot put it in
        # `Registry.ids`, and `PreflightSuite` runs every registered engine — so
        # `rake reporter_dashboards:render:preflight` EXITED 1 on every install that does
        # not run a container the documentation calls optional, and the admin page carried
        # a permanent red row. Unlike a missing Chromium, an operator cannot fix that by
        # installing anything: they have not chosen Gotenberg, they have simply not chosen.
        describe 'what the default preflight does with an engine that needs a service' do
          around do |example|
            Registry.isolated do
              Registry.register(:gotenberg, described_class)
              example.run
            end
          end

          it 'defers it with a named skip rather than failing, and rake still exits 0' do
            report = PreflightSuite.new.reports.find { |r| r.engine_id.to_s == 'gotenberg' }

            expect(report.checks.map(&:state)).to eq([:skip])
            expect(report.checks.first.id).to eq(:engine_not_selected)
            # THE SKIP NAMES HOW TO ASK. A silently shorter list is the failure mode; a
            # skip that does not say what to do about it is the next one.
            expect(report.checks.first.detail).to include('RRD_ENGINE=gotenberg')
            expect(report.checks).to all(be_ok)
          end

          it 'still runs it, for real, when the operator names it' do
            report = PreflightSuite.new(engine_ids: 'gotenberg').reports.first

            expect(report.checks.map(&:id)).not_to include(:engine_not_selected)
          end

          # ------------------------------------------------------------------
          # FR-50 — AND THE INSTALL'S OWN CHOICE STOPS THE DEFERRAL, which is the third place
          # this rule has had to be written (§Findings E-27's "a rule about 'an install has not
          # chosen this' belongs everywhere an engine is chosen FOR the operator"). Without it
          # the skip's own sentence — "this install has not chosen it" — is false on exactly
          # the installs that chose it, and the diagnostic refuses to check the engine every
          # report renders through.
          #
          # `RRD_GOTENBERG_URL` IS PINNED TO nil IN ALL THREE, and that is not tidiness: the
          # render-smoke job exports it, so without the pin these examples would make real
          # HTTP requests there and none here — green in both, measuring two different things.
          # E-27's control run found exactly that shape in this file's credential examples.
          it 'does NOT defer an engine this installation selected' do
            report = with_env('RRD_GOTENBERG_URL' => nil) do
              PreflightSuite.new(selected_engine_id: 'gotenberg')
                            .reports.find { |r| r.engine_id.to_s == 'gotenberg' }
            end

            expect(report.checks.map(&:id)).not_to include(:engine_not_selected)
            # AND IT REALLY RAN: an unconfigured endpoint is its OWN named failure, which is
            # what an operator who selected this engine needs to see instead of a skip.
            expect(report.checks.find(&:failed?).id).to eq(:gotenberg_endpoint)
          end

          # THE DISCRIMINATOR. Without this, `selected?` returning true for everything would
          # pass the example above — and would silently un-defer every service-backed engine
          # on every install, which is the defect E-27 row's "every install's preflight went
          # red" was about.
          it 'still defers it when the installation selected a DIFFERENT engine' do
            report = with_env('RRD_GOTENBERG_URL' => nil) do
              PreflightSuite.new(selected_engine_id: 'chromium_cdp')
                            .reports.find { |r| r.engine_id.to_s == 'gotenberg' }
            end

            expect(report.checks.map(&:id)).to eq([:engine_not_selected])
          end

          it 'treats an empty selection as no selection, because that is how an unset setting posts' do
            report = with_env('RRD_GOTENBERG_URL' => nil) do
              PreflightSuite.new(selected_engine_id: '')
                            .reports.find { |r| r.engine_id.to_s == 'gotenberg' }
            end

            expect(report.checks.map(&:id)).to eq([:engine_not_selected])
          end

          # AND THE SAME CLAIM ON THE READER, because the behavioural half above is an
          # EQUIVALENT MUTANT and the mutation run said so: with the blank normalisation
          # deleted, `selected_engine_id` becomes `''`, `selected?('gotenberg')` is still
          # false, and the deferral still happens — so the example passes against a guard
          # that is not there. `''` reaching a reader that means "an engine id" is the thing
          # the guard produces, so that is what is asserted (HANDOVER §1: the claim is about
          # the CONSTRUCTOR, so assert on the constructor).
          ['', '   ', nil].each do |value|
            it "reads #{value.inspect} back as no selection at all" do
              expect(PreflightSuite.new(selected_engine_id: value).selected_engine_id).to be_nil
            end
          end

          it 'says what to set when no endpoint is configured, rather than guessing one' do
            report = with_env('RRD_GOTENBERG_URL' => nil) do
              PreflightSuite.new(engine_ids: 'gotenberg').reports.first
            end

            failed = report.checks.find(&:failed?)
            expect(failed.id).to eq(:gotenberg_endpoint)
            expect(failed.detail).to include('RRD_GOTENBERG_URL')
          end
        end

        # ------------------------------------------------------------------
        def with_env(values)
          saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
          values.each { |key, value| ENV[key] = value }
          yield
        ensure
          saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        end
      end
    end
  end
end
