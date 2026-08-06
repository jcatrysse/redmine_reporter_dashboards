# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/assets'

# T-33 — `Fetcher`, the only egress in this plugin (§5.1, FR-65).
#
# T-33's acceptance list is explicit about HOW two of these must be proven, and both are
# honoured here rather than approximated:
#
#   "a fetch carries **no** cookie/session/API-key/`Authorization` header — asserted by a
#    request-recording double, not by reading the code"
#   "a DNS name resolving to `127.0.0.1`/`169.254.0.0/16`/RFC1918 is refused **after**
#    resolution"
#
# The first is why `RecordingTransport` exists: a spec that greps this file proves what the
# file says, and a double that records every header proves what was SENT. The second is why
# the resolver port is injectable — a real DNS lookup would make the test depend on the
# network it is asserting we do not use.
module RedmineReporterDashboards
  module Assets
    RSpec.describe Fetcher do
      # Records every call, answers whatever the example set up. Four fields, which is the
      # whole transport port — see `Fetcher::Transport`.
      class RecordingTransport
        attr_reader :calls

        def initialize(response: nil, raise_with: nil)
          @calls = []
          @response = response
          @raise_with = raise_with
        end

        def get(**options)
          @calls << options
          raise Fetcher::Transport::Error, @raise_with if @raise_with

          @response || Fetcher::Transport::Response.new(
            status: 200, content_type: 'image/png', body: 'PNGBYTES',
            timed_out: false, too_large: false
          )
        end
      end

      let(:origin) { Origin.from_settings('https', 'redmine.example') }
      let(:policy) { Policy.new(mode: :external, allowlist: %w[cdn.example redmine.example]) }
      let(:transport) { RecordingTransport.new }
      let(:resolved) { ['93.184.216.34'] }
      let(:logged) { [] }
      let(:logger) { double('logger').tap { |l| allow(l).to receive(:warn) { |m| logged << m } } }

      # `addresses` defaults to a SENTINEL rather than to nil, because nil is one of the
      # answers a resolver can legitimately give — "did not resolve" — and `addresses ||
      # resolved` silently turned that case into a successful lookup.
      NO_OVERRIDE = Object.new.freeze

      def fetcher(policy_override = nil, transport_override = nil, addresses = NO_OVERRIDE)
        described_class.new(policy: policy_override || policy,
                            http: transport_override || transport,
                            resolver: ->(_host) { addresses.equal?(NO_OVERRIDE) ? resolved : addresses },
                            logger: logger)
      end

      def reference(raw, usage: :image)
        Reference.new(raw: raw, usage: usage, span: [0, raw.length], origin: origin)
      end

      # ------------------------------------------------------------------
      describe 'the closed header set' do
        it 'sends no cookie, session, API key or Authorization header — recorded, not read' do
          fetcher.fetch(reference('https://cdn.example/logo.png'))

          headers = transport.calls.first[:headers]
          expect(headers.keys.sort).to eq(%w[Accept Accept-Encoding User-Agent])
          # Named individually as well as by the whitelist, so a future header added to the
          # set has to break this line and not merely slip past a count.
          %w[Cookie cookie Set-Cookie Authorization authorization X-Redmine-API-Key
             X-Redmine-Switch-User Proxy-Authorization].each do |forbidden|
            expect(headers).not_to have_key(forbidden)
          end
          expect(headers.values.join).not_to match(/session|api.?key|bearer/i)
        end

        it 'sends an Accept derived from the USAGE, and nothing an author chose' do
          fetcher.fetch(reference('https://cdn.example/a.css', usage: :stylesheet))

          expect(transport.calls.first[:headers]['Accept']).to eq('text/css')
        end

        it 'has no argument through which a caller could add a header' do
          # The security property is the SHAPE, as with `DocumentRequest`: there is no
          # `headers:` parameter to pass one through, so adding one is a diff somebody has
          # to argue rather than a call somebody makes.
          expect(described_class.instance_method(:fetch).parameters).to eq([[:req, :reference]])
          expect(described_class.instance_method(:initialize).parameters.map(&:last))
            .to eq(%i[policy http resolver logger])
        end
      end

      # ------------------------------------------------------------------
      describe 'https only' do
        it 'refuses an http:// reference even to an allowlisted host' do
          # `http://redmine.example/...` classifies as third-party on an https install, and
          # would be refused for that too — so the case is built to reach the scheme check:
          # an allowlisted host over http on an http install.
          http_origin = Origin.from_settings('http', 'redmine.example')
          ref = Reference.new(raw: 'http://redmine.example/logo.png', usage: :image,
                              span: [0, 1], origin: http_origin)

          result = fetcher.fetch(ref)

          expect(result).to be_a(Fetcher::Refusal)
          expect(result.code).to eq(:scheme)
          expect(transport.calls).to be_empty
        end
      end

      # ------------------------------------------------------------------
      describe 'the policy gate comes first' do
        it 'refuses before resolving anything when the mode does not permit the class' do
          result = fetcher(Policy.bundled).fetch(reference('https://cdn.example/logo.png'))

          expect(result.code).to eq(:policy)
          expect(transport.calls).to be_empty
        end

        it 'refuses an unlisted host and says which one' do
          result = fetcher.fetch(reference('https://other.example/logo.png'))

          expect(result.code).to eq(:not_allowlisted)
          expect(transport.calls).to be_empty
        end
      end

      # ------------------------------------------------------------------
      # The rebinding case, which is the reason this is `ipaddr=` and not a second lookup.
      describe 'the resolved address' do
        it 'refuses loopback, link-local and every RFC1918 range' do
          %w[127.0.0.1 127.1.2.3 169.254.169.254 10.0.0.1 172.16.5.5 192.168.1.1
             100.64.0.1 0.0.0.0 224.0.0.1 255.255.255.255].each do |address|
            result = fetcher(nil, RecordingTransport.new, [address])
                     .fetch(reference('https://cdn.example/logo.png'))

            expect(result).to be_a(Fetcher::Refusal), address
            expect(result.code).to eq(:private_address), address
          end
        end

        it 'refuses the IPv6 equivalents, INCLUDING the v4-mapped forms' do
          # `::ffff:127.0.0.1` is a loopback address wearing a v6 costume. A check that only
          # looked at `IPAddr#ipv4?` misses it, and the two libraries that produce these
          # strings disagree about which form they hand back.
          %w[::1 :: fe80::1 fc00::1 ff02::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1
             2001:db8::1].each do |address|
            result = fetcher(nil, RecordingTransport.new, [address])
                     .fetch(reference('https://cdn.example/logo.png'))

            expect(result.code).to eq(:private_address), address
          end
        end

        it 'refuses when ANY resolved address is private, not only the first' do
          # A name that answers with a public and a private address is the split-horizon
          # case, and picking the first would make the outcome depend on resolver ordering.
          result = fetcher(nil, RecordingTransport.new, ['93.184.216.34', '10.0.0.1'])
                   .fetch(reference('https://cdn.example/logo.png'))

          expect(result.code).to eq(:private_address)
        end

        it 'refuses a name that does not resolve' do
          expect(fetcher(nil, RecordingTransport.new, []).fetch(reference('https://cdn.example/a.png'))
                   .code).to eq(:dns)
          expect(fetcher(nil, RecordingTransport.new, nil).fetch(reference('https://cdn.example/a.png'))
                   .code).to eq(:dns)
        end

        it 'refuses an unparseable address rather than letting it through' do
          expect(fetcher(nil, RecordingTransport.new, ['not-an-ip'])
                   .fetch(reference('https://cdn.example/a.png')).code).to eq(:private_address)
        end

        it 'CONNECTS to the checked address, which is what closes the rebinding window' do
          fetcher(nil, transport, ['93.184.216.34']).fetch(reference('https://cdn.example/a.png'))

          call = transport.calls.first
          expect(call[:address]).to eq('93.184.216.34')
          # And the host is still carried, so SNI and the Host header stay correct.
          expect(call[:host]).to eq('cdn.example')
        end

        it 'accepts an ordinary public address' do
          expect(fetcher.fetch(reference('https://cdn.example/logo.png')))
            .to be_a(Fetcher::Fetched)
        end
      end

      # ------------------------------------------------------------------
      describe 'the caps, AT the boundary and one past it' do
        def response(body:, content_type: 'image/png', status: 200, timed_out: false,
                     too_large: false)
          RecordingTransport.new(
            response: Fetcher::Transport::Response.new(
              status: status, content_type: content_type, body: body,
              timed_out: timed_out, too_large: too_large
            )
          )
        end

        it 'accepts a body AT asset_max_bytes and refuses one byte past it' do
          capped = Policy.new(mode: :external, allowlist: %w[cdn.example],
                              inline_max_bytes: 10, asset_max_bytes: 10)

          at = fetcher(capped, response(body: 'a' * 10)).fetch(reference('https://cdn.example/a.png'))
          expect(at).to be_a(Fetcher::Fetched)
          expect(at.size).to eq(10)

          past = fetcher(capped, response(body: 'a' * 11))
                 .fetch(reference('https://cdn.example/a.png'))
          expect(past).to be_a(Fetcher::Refusal)
          expect(past.code).to eq(:too_large)
        end

        it 'passes the cap DOWN to the transport, so the abort happens while reading' do
          capped = Policy.new(mode: :external, allowlist: %w[cdn.example],
                              inline_max_bytes: 4096, asset_max_bytes: 4096)
          fetcher(capped, transport).fetch(reference('https://cdn.example/a.png'))

          # `response.body` on a 4 GB answer is a memory-exhaustion primitive. The cap has
          # to reach the reader, not only the check afterwards.
          expect(transport.calls.first[:max_bytes]).to eq(4096)
        end

        it 'refuses when the transport reports the size cap tripped' do
          result = fetcher(nil, response(body: '', too_large: true))
                   .fetch(reference('https://cdn.example/a.png'))

          expect(result.code).to eq(:too_large)
        end

        it 'refuses a redirect rather than following it, and says so' do
          [301, 302, 303, 307, 308].each do |status|
            result = fetcher(nil, response(body: '', status: status))
                     .fetch(reference('https://cdn.example/a.png'))

            expect(result.code).to eq(:redirect), status.to_s
            expect(result.reason).to include('redirect count is 0')
          end
        end

        it 'refuses a non-200, non-redirect status' do
          result = fetcher(nil, response(body: 'x', status: 404))
                   .fetch(reference('https://cdn.example/a.png'))

          expect(result.code).to eq(:status)
        end

        it 'refuses a timeout' do
          result = fetcher(nil, response(body: '', timed_out: true))
                   .fetch(reference('https://cdn.example/a.png'))

          expect(result.code).to eq(:timeout)
        end

        it 'carries §5.1\'s two timeouts to the transport' do
          fetcher.fetch(reference('https://cdn.example/a.png'))

          expect(transport.calls.first[:connect_timeout]).to eq(Policy::CONNECT_TIMEOUT_S)
          expect(transport.calls.first[:read_timeout]).to be <= Policy::TOTAL_TIMEOUT_S
          expect(transport.calls.first[:read_timeout]).to be > 0
        end
      end

      # ------------------------------------------------------------------
      describe 'content type' do
        it 'refuses a type that is not usable for the way the document referenced it' do
          answer = RecordingTransport.new(
            response: Fetcher::Transport::Response.new(
              status: 200, content_type: 'text/html', body: '<html>', timed_out: false,
              too_large: false
            )
          )

          result = fetcher(nil, answer).fetch(reference('https://cdn.example/logo.png'))

          expect(result.code).to eq(:content_type)
        end

        it 'accepts a type carrying a charset parameter' do
          answer = RecordingTransport.new(
            response: Fetcher::Transport::Response.new(
              status: 200, content_type: 'text/css; charset=utf-8', body: 'a{}',
              timed_out: false, too_large: false
            )
          )

          result = fetcher(nil, answer)
                   .fetch(reference('https://cdn.example/a.css', usage: :stylesheet))

          expect(result).to be_a(Fetcher::Fetched)
          expect(result.content_type).to eq('text/css')
        end
      end

      # ------------------------------------------------------------------
      describe 'transport failure' do
        it 'becomes a refusal, never an exception escaping into a render' do
          result = fetcher(nil, RecordingTransport.new(raise_with: 'SocketError: nope'))
                   .fetch(reference('https://cdn.example/a.png'))

          expect(result).to be_a(Fetcher::Refusal)
          expect(result.code).to eq(:transport)
        end

        it 'does NOT swallow a defect in this file' do
          # `rescue Transport::Error` and nothing wider. A `StandardError` rescue would
          # report a bug here as an unreachable host — CLAUDE.md §5.
          broken = double('transport')
          allow(broken).to receive(:get).and_raise(NoMethodError, 'planted')

          expect { fetcher(nil, broken).fetch(reference('https://cdn.example/a.png')) }
            .to raise_error(NoMethodError, /planted/)
        end
      end

      describe 'logging' do
        it 'logs every refusal with the URL, so a diagnostics page has something to show' do
          fetcher.fetch(reference('https://other.example/logo.png'))

          expect(logged.join).to include('other.example/logo.png')
          expect(logged.join).to include('asset_allowlist')
        end

        it 'survives a nil logger' do
          quiet = described_class.new(policy: policy, http: transport,
                                      resolver: ->(_host) { resolved })

          expect { quiet.fetch(reference('https://other.example/a.png')) }.not_to raise_error
        end
      end

      describe 'the production transport' do
        it 'exists and answers the port\'s one method' do
          # Not exercised against a real socket here — that would be a test of the network.
          # What is pinned is that the class the fetcher defaults to implements the port,
          # so a rename cannot leave the default broken until the first real fetch.
          expect(Fetcher::NetHttpTransport.new).to respond_to(:get)
          expect(Fetcher::NetHttpTransport.instance_method(:get).parameters.map(&:last))
            .to eq(%i[host port path address headers connect_timeout read_timeout max_bytes])
        end
      end
    end
  end
end
