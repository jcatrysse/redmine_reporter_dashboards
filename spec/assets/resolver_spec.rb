# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/assets'

# T-33 — `Resolver`. This file is the task's acceptance list, line by line.
#
#   one walk choosing the MOST RESTRICTIVE model the engine declares
#   `:bundled` renders correctly with the engine's name resolution denied
#   a third-party URL under `:bundled` -> refused, NAMING the URL, not a blank image
#   an empty `asset_allowlist` under `:external` behaves IDENTICALLY to `:bundled`
#   `:asset_http` proven OFF wherever the engine supports `:asset_upload`
#   an author CANNOT widen egress from template content
module RedmineReporterDashboards
  module Assets
    RSpec.describe Resolver do
      around do |example|
        Dir.mktmpdir('rrd-resolve') do |dir|
          @tmp = dir
          File.binwrite(File.join(dir, 'logo.png'), "\x89PNG#{'x' * 40}")
          File.binwrite(File.join(dir, 'app.css'), '.a { color: red }')
          File.binwrite(File.join(dir, 'app.js'), 'var a = 1;')
          File.binwrite(File.join(dir, 'big.png'), "\x89PNG#{'x' * 4000}")
          example.run
        end
      end

      let(:origin) { Origin.from_settings('https', 'redmine.example') }
      let(:store) { LocalStore.new(roots: { '/plugin_assets/rrd' => @tmp }) }
      let(:logged) { [] }
      let(:logger) { double('logger').tap { |l| allow(l).to receive(:warn) { |m| logged << m } } }

      # A fetcher double that records what it was asked for and answers bytes.
      class StubFetcher
        attr_reader :asked

        def initialize(answer: nil)
          @asked = []
          @answer = answer
        end

        def fetch(reference)
          @asked << reference.url
          @answer || Fetcher::Fetched.new(bytes: "\x89PNGfetched", content_type: 'image/png',
                                          size: 12)
        end
      end

      def resolver(policy: Policy.bundled, capabilities: [:asset_inline], fetcher: nil,
                   local_store: nil)
        described_class.new(policy: policy, local_store: local_store || store,
                            engine_capabilities: capabilities, fetcher: fetcher,
                            origin: origin, logger: logger)
      end

      def local(path)
        "/plugin_assets/rrd/#{path}"
      end

      # ------------------------------------------------------------------
      describe 'the model choice — most restrictive first' do
        it 'INLINES a local file the engine can inline' do
          result = resolver.call(%(<img src="#{local('logo.png')}">))

          expect(result).to be_ok
          expect(result.models_used).to eq([:inline])
          expect(result.body).to match(%r{<img src="data:image/png;base64,[A-Za-z0-9+/=]+">})
          expect(result.assets).to be_empty
        end

        it 'UPLOADS a local file above the inline threshold when the engine declares upload' do
          policy = Policy.new(inline_max_bytes: 100, asset_max_bytes: 1_000_000)
          result = resolver(policy: policy, capabilities: %i[asset_inline asset_upload])
                   .call(%(<img src="#{local('big.png')}">))

          expect(result).to be_ok
          expect(result.models_used).to eq([:upload])
          expect(result.assets.length).to eq(1)
          name = result.assets.keys.first
          expect(result.body).to include(%(<img src="#{name}">))
          expect(result.assets[name]['content_type']).to eq('image/png')
        end

        it 'INLINES above the threshold anyway when the engine has no upload model, and DEGRADES' do
          # The threshold is a cost decision (base64 growth versus a round trip); the cap is
          # the safety one. So paying the cost and saying so beats refusing a document over
          # an engine limitation.
          policy = Policy.new(inline_max_bytes: 100, asset_max_bytes: 1_000_000)
          result = resolver(policy: policy, capabilities: [:asset_inline])
                   .call(%(<img src="#{local('big.png')}">))

          expect(result).to be_ok
          expect(result.models_used).to eq([:inline])
          expect(result.degradations.map { |d| d[:code] }).to eq([:asset_inline_oversize])
        end

        it 'REFUSES above asset_max_bytes, which is the hard cap — AT it and one past it' do
          size = File.size(File.join(@tmp, 'big.png'))

          at = resolver(policy: Policy.new(inline_max_bytes: size, asset_max_bytes: size))
               .call(%(<img src="#{local('big.png')}">))
          expect(at).to be_ok

          past = resolver(policy: Policy.new(inline_max_bytes: size - 1,
                                            asset_max_bytes: size - 1))
                 .call(%(<img src="#{local('big.png')}">))
          expect(past).to be_refused
          expect(past.refusals.first.reason).to include('asset_max_bytes')
        end

        it 'REFUSES when the engine declares no asset model at all' do
          result = resolver(capabilities: []).call(%(<img src="#{local('logo.png')}">))

          expect(result).to be_refused
          expect(result.refusals.first.reason)
            .to include('neither :asset_inline nor :asset_upload')
        end

        it 'leaves a data: URI and a fragment alone' do
          html = %(<img src="data:image/png;base64,AAA"><svg><use href="#icon"/></svg>)
          result = resolver.call(html)

          expect(result).to be_ok
          expect(result.body).to eq(html)
          expect(result.counts[:passthrough]).to eq(2)
        end

        it 'records `asset_none` nowhere and simply does nothing on a document with no assets' do
          result = resolver.call('<p>plain</p>')

          expect(result).to be_ok
          expect(result.body).to eq('<p>plain</p>')
          expect(result.models_used).to be_empty
        end
      end

      # ------------------------------------------------------------------
      # The inversion §5.1 calls "the single thing that keeps INV-8 true".
      describe ':asset_http is never selected' do
        it 'is not chosen even by an engine declaring all three models, in :external mode' do
          # THE case that would otherwise pick it: the reference is remote, the policy
          # permits a fetch, and the engine says it can resolve URLs itself.
          policy = Policy.new(mode: :external, allowlist: %w[cdn.example])
          fetcher = StubFetcher.new
          result = resolver(policy: policy, fetcher: fetcher,
                            capabilities: %i[asset_inline asset_upload asset_http])
                   .call('<img src="https://cdn.example/logo.png">')

          expect(result).to be_ok
          expect(result.models_used).not_to include(:asset_http)
          expect(result.models_used).not_to include(:fetch)
          expect(result.models_used).to eq([:inline])
          # THE PLUGIN fetched, and the document now carries bytes rather than a URL.
          expect(fetcher.asked).to eq(['https://cdn.example/logo.png'])
          expect(result.body).to include('data:image/png;base64,')
          expect(result.body).not_to include('cdn.example')
        end

        it 'is not chosen in any policy mode, and the two upgraded modes still RESOLVE' do
          # Written so no arm is vacuous: `models_used` being empty would satisfy "does not
          # include :asset_http" while proving nothing, so each mode also asserts what it
          # DID do. `:bundled` refuses the reference, and both upgraded modes inline it.
          # Each mode is given a reference IT is supposed to fetch — `:redmine` fetches
          # same-origin only, so handing it a third-party URL would make its arm vacuous for
          # the wrong reason.
          [[:bundled, 'https://cdn.example/logo.png', []],
           [:redmine, 'https://redmine.example/live.png', [:inline]],
           [:external, 'https://cdn.example/logo.png', [:inline]]].each do |mode, url, expected|
            policy = Policy.new(mode: mode, allowlist: %w[cdn.example redmine.example])
            result = resolver(policy: policy, fetcher: StubFetcher.new,
                              capabilities: %i[asset_inline asset_upload asset_http])
                     .call(%(<img src="#{url}">))

            expect(result.models_used).to eq(expected), mode.to_s
            expect(result.models_used).not_to include(:asset_http), mode.to_s
          end
        end
      end

      # ------------------------------------------------------------------
      describe ':bundled — the default' do
        it 'refuses a third-party URL and NAMES it' do
          result = resolver.call('<img src="https://third.example/tracker.png?id=1">')

          expect(result).to be_refused
          expect(result.refused_urls).to eq(['https://third.example/tracker.png?id=1'])
          expect(result.refusals.first.reason).to include('does not fetch third_party')
          # Not a blank image: the reference is still in the body, unrewritten, and the
          # caller turns the refusal into a Failure rather than rendering.
          expect(result.body).to include('third.example')
        end

        it 'rewrites a SAME-ORIGIN absolute URL back to the file on disk' do
          # §5.1's `:bundled` row, and the answer to F-15: a plugin-asset URL is mapped BACK
          # to disk, never fetched. Building the absolute URL and letting the engine fetch it
          # would turn a file on the same disk into an egress requirement.
          result = resolver.call(%(<img src="https://redmine.example#{local('logo.png')}">))

          expect(result).to be_ok
          expect(result.body).to include('data:image/png;base64,')
          expect(result.counts[:fetched]).to eq(0)
        end

        it 'rewrites a same-origin URL on a SUB-PATH install' do
          sub = Origin.from_settings('https', 'redmine.example/redmine')
          result = described_class.new(policy: Policy.bundled, local_store: store,
                                      engine_capabilities: [:asset_inline], origin: sub)
                                 .call(%(<img src="/redmine#{local('logo.png')}">))

          expect(result).to be_ok
          expect(result.body).to include('data:image/png;base64,')
        end

        it 'refuses a same-origin URL that is NOT on disk, saying it is absent' do
          result = resolver.call(%(<img src="#{local('missing.png')}">))

          expect(result).to be_refused
          expect(result.refusals.first.reason).to include('does not exist')
          expect(result.refusals.first.reason).to include('does not fetch')
        end

        it 'refuses a relative reference, because a render has no base to resolve it against' do
          result = resolver.call('<img src="logo.png">')

          expect(result).to be_refused
          expect(result.refusals.first.classification).to eq(:unresolvable)
        end

        it 'never calls the fetcher at all' do
          fetcher = StubFetcher.new
          resolver(fetcher: fetcher).call('<img src="https://third.example/a.png">')

          expect(fetcher.asked).to be_empty
        end
      end

      # ------------------------------------------------------------------
      # T-33: "the fail-closed test, and the one most likely to be got wrong".
      describe 'an empty allowlist under :external' do
        let(:html) do
          <<~HTML
            <img src="https://third.example/a.png">
            <link rel="stylesheet" href="https://redmine.example/live.css">
            <img src="#{local('logo.png')}">
          HTML
        end

        it 'produces the IDENTICAL resolution to :bundled — body, refusals and counts' do
          bundled = resolver(policy: Policy.bundled, fetcher: StubFetcher.new).call(html)
          external = resolver(policy: Policy.new(mode: :external, allowlist: []),
                              fetcher: StubFetcher.new).call(html)

          expect(external.body).to eq(bundled.body)
          expect(external.refused_urls).to eq(bundled.refused_urls)
          expect(external.counts).to eq(bundled.counts)
          expect(external.models_used).to eq(bundled.models_used)
        end

        it 'says WHY in the refusal, so an operator is not left guessing' do
          result = resolver(policy: Policy.new(mode: :external, allowlist: []),
                            fetcher: StubFetcher.new).call(html)

          expect(result.refusals.map(&:reason).join).to include('asset_allowlist is empty')
          expect(result.refusals.map(&:reason).join).to include('behaves as bundled')
        end
      end

      # ------------------------------------------------------------------
      describe ':redmine and :external' do
        it ':redmine fetches an allowlisted same-origin URL and refuses a third-party one' do
          policy = Policy.new(mode: :redmine, allowlist: %w[redmine.example])
          fetcher = StubFetcher.new
          result = resolver(policy: policy, fetcher: fetcher).call(
            '<img src="https://redmine.example/live/chart.png">' \
            '<img src="https://third.example/x.png">'
          )

          expect(fetcher.asked).to eq(['https://redmine.example/live/chart.png'])
          expect(result.refused_urls).to eq(['https://third.example/x.png'])
        end

        it ':external fetches an allowlisted third-party URL only' do
          policy = Policy.new(mode: :external, allowlist: %w[cdn.example])
          fetcher = StubFetcher.new
          result = resolver(policy: policy, fetcher: fetcher).call(
            '<img src="https://cdn.example/ok.png"><img src="https://other.example/no.png">'
          )

          expect(fetcher.asked).to eq(['https://cdn.example/ok.png'])
          expect(result.refused_urls).to eq(['https://other.example/no.png'])
        end

        it 'turns a fetcher refusal into a named resolution refusal' do
          policy = Policy.new(mode: :external, allowlist: %w[cdn.example])
          refusing = StubFetcher.new(answer: Fetcher::Refusal.new(code: :private_address,
                                                                  reason: 'resolves to 127.0.0.1'))
          result = resolver(policy: policy, fetcher: refusing)
                   .call('<img src="https://cdn.example/a.png">')

          expect(result).to be_refused
          expect(result.refusals.first.reason).to include('127.0.0.1')
        end

        it 'refuses rather than trusting a fetcher that answered with something unexpected' do
          policy = Policy.new(mode: :external, allowlist: %w[cdn.example])
          odd = double('fetcher')
          allow(odd).to receive(:fetch).and_return('just a string')

          result = resolver(policy: policy, fetcher: odd)
                   .call('<img src="https://cdn.example/a.png">')

          expect(result).to be_refused
        end

        it 'refuses when a fetch is permitted and no fetcher was supplied' do
          policy = Policy.new(mode: :external, allowlist: %w[cdn.example])
          result = resolver(policy: policy, fetcher: nil)
                   .call('<img src="https://cdn.example/a.png">')

          expect(result).to be_refused
          expect(result.refusals.first.reason).to include('no fetcher')
        end
      end

      # ------------------------------------------------------------------
      # T-33: "A test asserts an author CANNOT widen egress from template content."
      describe 'an author cannot widen egress' do
        let(:hostile) do
          <<~HTML
            <meta name="asset_policy" content="external">
            <meta http-equiv="Content-Security-Policy" content="default-src *">
            <!-- asset_policy: external -->
            <!-- asset_allowlist: evil.example -->
            <img src="https://evil.example/a.png?asset_policy=external&asset_allowlist=evil.example">
            <script>window.asset_policy = 'external';</script>
            <style>/* asset_policy: external */ .x { background: url(https://evil.example/b.png) }</style>
            <img srcset="https://evil.example/c.png 1x">
            <iframe src="https://evil.example/d"></iframe>
          HTML
        end

        it 'refuses every remote reference whatever the document says about policy' do
          result = resolver.call(hostile)

          expect(result).to be_refused
          expect(result.refused_urls.length).to eq(4)
          expect(result.refused_urls).to all(include('evil.example'))
        end

        it 'is unchanged by the document — the same policy object answers the same way' do
          policy = Policy.bundled
          resolver(policy: policy).call(hostile)

          # Nothing the walk did mutated the policy. It is frozen, but a frozen object can
          # still be replaced by a caller that thought it was allowed to.
          expect(policy.mode).to eq(:bundled)
          expect(policy.allowlist).to be_empty
          expect(policy).to be_frozen
        end

        it 'has no constructor argument a Liquid render could reach' do
          # Policy, store, capabilities and fetcher are all constructor arguments. There is
          # no register, no Liquid variable and no tag parameter that changes any of them.
          expect(described_class.instance_method(:initialize).parameters.map(&:last))
            .to eq(%i[policy local_store engine_capabilities fetcher origin logger])
          expect(described_class.instance_method(:call).parameters).to eq([[:req, :html]])
        end
      end

      # ------------------------------------------------------------------
      describe 'structural inlining, and the injection it would otherwise open' do
        it 'replaces a <link rel=stylesheet> with a <style> block' do
          result = resolver.call(%(<head><link rel="stylesheet" href="#{local('app.css')}"></head>))

          expect(result.body).to include('<style>')
          expect(result.body).to include('.a { color: red }')
          expect(result.body).not_to include('<link')
        end

        it 'replaces a <script src> with a <script> block, closing tag included' do
          result = resolver.call(%(<head><script src="#{local('app.js')}"></script></head>))

          expect(result.body).to eq("<head><script>\nvar a = 1;\n</script></head>")
        end

        it 'discards a body the HTML parser would have ignored anyway' do
          result = resolver.call(%(<script src="#{local('app.js')}">ignored()</script>))

          expect(result.body).not_to include('ignored()')
        end

        it 'FALLS BACK to a data: URI when the CSS contains `</style`' do
          # Structural inlining of bytes containing the element terminator would close the
          # block early and everything after it would be parsed as markup. That is an
          # injection, not a rendering bug — and base64 contains no `<`.
          File.binwrite(File.join(@tmp, 'evil.css'), '.a{} </style><script>alert(1)</script>')
          result = resolver.call(%(<link rel="stylesheet" href="#{local('evil.css')}">))

          expect(result.body).not_to include('<script>alert(1)</script>')
          expect(result.body).to include('href="data:text/css;base64,')
          expect(result.degradations.map { |d| d[:code] }).to eq([:asset_structural_fallback])
        end

        it 'catches the spaced and cased forms of the terminator too' do
          ['</ STYLE >', '</StYlE>', '</style'].each do |terminator|
            File.binwrite(File.join(@tmp, 'evil.css'), ".a{} #{terminator}")
            result = resolver.call(%(<link rel="stylesheet" href="#{local('evil.css')}">))

            expect(result.body).to include('data:text/css;base64,'), terminator
          end
        end

        it 'FALLS BACK for a script containing `</script` or `<!--`' do
          ['var a = "</script>";', 'var a = 1; <!-- comment'].each do |source|
            File.binwrite(File.join(@tmp, 'evil.js'), source)
            result = resolver.call(%(<script src="#{local('evil.js')}"></script>))

            expect(result.body).to include('data:text/javascript;base64,'), source
          end
        end

        it 'falls back for bytes that are not valid UTF-8, rather than corrupting them' do
          File.binwrite(File.join(@tmp, 'binary.css'), "\xff\xfe.a{}")
          result = resolver.call(%(<link rel="stylesheet" href="#{local('binary.css')}">))

          expect(result.body).to include('data:text/css;base64,')
        end
      end

      # ------------------------------------------------------------------
      describe 'the splice' do
        it 'rewrites several references in one pass without shifting any of them' do
          html = <<~HTML
            <link rel="stylesheet" href="#{local('app.css')}">
            <img src="#{local('logo.png')}">
            <p style="background:url(#{local('logo.png')})">x</p>
            <img srcset="#{local('logo.png')} 1x, #{local('big.png')} 2x">
          HTML

          result = resolver.call(html)

          expect(result).to be_ok
          expect(result.body.scan('data:image/png;base64,').length).to eq(3)
          expect(result.body).to include('<style>')
          expect(result.body).not_to include('/plugin_assets/rrd')
        end

        it 'degrades VISIBLY when srcset alternatives are dropped' do
          result = resolver.call(%(<img srcset="#{local('logo.png')} 1x, #{local('big.png')} 2x">))

          degradation = result.degradations.find { |d| d[:code] == :asset_srcset_collapsed }
          expect(degradation[:data]['dropped']).to eq(1)
        end

        it 'reads and encodes a repeated asset ONCE' do
          html = (1..5).map { %(<img src="#{local('logo.png')}">) }.join
          result = resolver.call(html)

          expect(result.body.scan('data:image/png;base64,').length).to eq(5)
          # The bytes are read per reference (the store has no cache) but encoded once, so
          # the five data URIs are the same object's value rather than five base64 passes.
          expect(result.body.scan(/data:image\/png;base64,([A-Za-z0-9+\/=]+)/).uniq.length).to eq(1)
        end

        it 'carries an asset once when several references upload the same bytes' do
          policy = Policy.new(inline_max_bytes: 10, asset_max_bytes: 1_000_000)
          html = (1..3).map { %(<img src="#{local('big.png')}">) }.join
          result = resolver(policy: policy, capabilities: %i[asset_inline asset_upload]).call(html)

          expect(result.assets.length).to eq(1)
          expect(result.counts[:uploaded]).to eq(3)
        end

        it 'is re-entrant: two documents through one resolver do not share assets' do
          policy = Policy.new(inline_max_bytes: 10, asset_max_bytes: 1_000_000)
          one = resolver(policy: policy, capabilities: %i[asset_inline asset_upload])
          first = one.call(%(<img src="#{local('big.png')}">))
          second = one.call('<p>nothing</p>')

          expect(first.assets.length).to eq(1)
          expect(second.assets).to be_empty
        end
      end

      # ------------------------------------------------------------------
      # HANDOVER §1 records this trap twice, and its second symptom "does not look like an
      # encoding bug at all": `Encoding::CompatibilityError: incompatible character encodings:
      # UTF-8 and US-ASCII`, raised from a line that does no reading. A report body that reached
      # this layer through a `File.read` with no `encoding:` on a host with no `LANG` is
      # US-ASCII-tagged, and splicing a UTF-8 stylesheet into it raises. Found by running it, not
      # by reading it.
      describe 'the document\'s encoding' do
        before do
          File.binwrite(File.join(@tmp, 'accented.css'), "/* Größe — ω */\n.a{color:red}")
        end

        let(:document) do
          %(<p>Überprüfung — Größe · 日本語</p><img src="#{local('logo.png')}">) +
            %(<link rel="stylesheet" href="#{local('accented.css')}"><p>ünd — ω</p>)
        end

        it 'splices into a UTF-8 body' do
          result = resolver.call(document.dup)

          expect(result).to be_ok
          expect(result.body.encoding).to eq(Encoding::UTF_8)
          expect(result.body).to be_valid_encoding
          expect(result.body).to include('Überprüfung — Größe · 日本語')
          expect(result.body).to include('Größe — ω'), 'the stylesheet was inlined structurally'
        end

        it 'RELABELS a US-ASCII-tagged body whose bytes are valid UTF-8, rather than raising' do
          body = document.dup.force_encoding(Encoding::US_ASCII)

          result = nil
          expect { result = resolver.call(body) }.not_to raise_error
          expect(result.body.encoding).to eq(Encoding::UTF_8)
          expect(result.body).to include('Überprüfung')
          expect(result.degradations).to be_empty, 'nothing had to degrade — it is the same bytes'
        end

        it 'relabels a BINARY-tagged body the same way' do
          result = resolver.call(document.dup.force_encoding(Encoding::BINARY))

          expect(result.body.encoding).to eq(Encoding::UTF_8)
          expect(result.body).to include('Überprüfung')
        end

        it 'FALLS BACK for a body that is genuinely not UTF-8, and re-encodes nothing' do
          # Latin-1 bytes that are not valid UTF-8. Re-encoding the body would change report
          # content to make this layer's life easier; the structural insert falls back to a
          # `data:` URI instead, which is pure ASCII and therefore always compatible.
          body = (+"<p>\xDCber</p><link rel=\"stylesheet\" href=\"#{local('accented.css')}\">")
                 .force_encoding(Encoding::ISO_8859_1)

          result = nil
          expect { result = resolver.call(body) }.not_to raise_error
          expect(result).to be_ok
          expect(result.body.encoding).to eq(Encoding::ISO_8859_1)
          expect(result.body).to include('data:text/css;base64,')
          expect(result.degradations.map { |d| d[:code] }).to include(:asset_structural_fallback)
          expect(result.body.b).to include("\xDC".b), 'the original bytes are untouched'
        end

        it 'keeps character offsets right when multibyte text sits between references' do
          # `String#index`, `MatchData#begin` and `String#[]=` are all CHARACTER-indexed, so they
          # agree — but only as long as nothing in the chain switches to `bytesize`. Two
          # references either side of 12 multibyte characters is what would expose it.
          result = resolver.call(
            %(<p>——日本語——</p><img src="#{local('logo.png')}"><p>ωωω</p><img src="#{local('logo.png')}">)
          )

          expect(result).to be_ok
          expect(result.body.scan('data:image/png;base64,').length).to eq(2)
          expect(result.body).to include('<p>——日本語——</p>')
          expect(result.body).to include('<p>ωωω</p>')
        end
      end

      # ------------------------------------------------------------------
      # THE HOLE THE REVIEW FOUND, and the most serious one in T-33 as first written.
      #
      # A stylesheet is a document: CSS carries `url()` and `@import`. Embedding one verbatim
      # handed every reference inside it to the engine as a LIVE URL — egress under `:bundled`,
      # and under `:external` a complete allowlist bypass, because one allowlisted host then
      # chose arbitrary further egress. Reproduced before the fix and asserted here after it.
      describe 'references INSIDE an inlined stylesheet' do
        before do
          File.binwrite(File.join(@tmp, 'evil.css'),
                        'body{background:url(https://evil.example/track.png)} ' \
                        '@import url("https://evil.example/more.css");')
          File.binwrite(File.join(@tmp, 'local.css'),
                        %(body{background:url("#{local('logo.png')}")}))
        end

        it 'REFUSES a third-party url() inside it under :bundled, naming the inner URL' do
          result = resolver.call(%(<link rel="stylesheet" href="#{local('evil.css')}">))

          expect(result).to be_refused
          expect(result.refused_urls).to include('https://evil.example/track.png')
          expect(result.body).not_to include('evil.example')
        end

        it 'refuses it through the data: URI path too, not only the structural one' do
          # A `<link>` carrying `disabled` cannot be structurally rewritten, so it takes the
          # `data:` branch — which embedded the same unresolved bytes.
          result = resolver.call(%(<link rel="stylesheet" href="#{local('evil.css')}" disabled>))

          expect(result).to be_refused
          expect(result.refused_urls).to include('https://evil.example/track.png')
        end

        it 'refuses it inside a <style> body that was itself inlined from a file' do
          File.binwrite(File.join(@tmp, 'nested.css'), %(@import url("#{local('evil.css')}");))
          result = resolver.call(%(<link rel="stylesheet" href="#{local('nested.css')}">))

          expect(result).to be_refused
          expect(result.refused_urls).to include('https://evil.example/track.png')
        end

        it 'RESOLVES a local url() inside it, so an ordinary stylesheet still works' do
          result = resolver.call(%(<link rel="stylesheet" href="#{local('local.css')}">))

          expect(result).to be_ok
          expect(result.body).to include('<style>')
          expect(result.body).to include('data:image/png;base64,')
          expect(result.body).not_to include('/plugin_assets/rrd')
        end

        it 'FETCHES it rather than passing it through when the policy permits' do
          policy = Policy.new(mode: :external, allowlist: %w[evil.example])
          fetcher = StubFetcher.new
          result = resolver(policy: policy, fetcher: fetcher)
                   .call(%(<link rel="stylesheet" href="#{local('evil.css')}">))

          expect(result).to be_ok
          # THE PLUGIN fetched both, and the engine gets bytes — the inversion, one level down.
          expect(fetcher.asked).to eq(['https://evil.example/track.png',
                                       'https://evil.example/more.css'])
          expect(result.body).not_to include('evil.example')
        end

        it 'bounds the @import chain and degrades rather than recursing without limit' do
          # A circular import must be a degradation, not a stack overflow.
          File.binwrite(File.join(@tmp, 'loop.css'), %(@import url("#{local('loop.css')}");))

          result = nil
          expect { result = resolver.call(%(<link rel="stylesheet" href="#{local('loop.css')}">)) }
            .not_to raise_error
          expect(result.degradations.map { |d| d[:code] }).to include(:asset_nested_depth)
        end

        it 'does NOT rewrite URLs inside JavaScript, because a string is not a subresource' do
          # The distinction is real rather than convenient: a script can mint a subresource at
          # runtime and no scanner can close that — only the engine's own egress denial can,
          # which is what conformance fixture F-15-egress-denial is for. Rewriting URLs in JS
          # would corrupt programs while closing nothing.
          File.binwrite(File.join(@tmp, 'app2.js'), 'var u = "https://evil.example/x.png";')
          result = resolver.call(%(<script src="#{local('app2.js')}"></script>))

          expect(result).to be_ok
          expect(result.body).to include('https://evil.example/x.png')
        end
      end

      # ------------------------------------------------------------------
      # `Resolver#call` promises never to raise for anything a document can do, and it did:
      # a `<link>` with a background image in its inline style produced an element-span
      # replacement containing a value-span one and `assert_disjoint!` fired `ArgumentError`.
      describe 'a reference nested inside a structurally-rewritable element' do
        it 'does not raise, and resolves both' do
          html = %(<html><link rel="stylesheet" href="#{local('app.css')}" ) +
                 %(style="background:url(#{local('logo.png')})"></html>)

          result = nil
          expect { result = resolver.call(html) }.not_to raise_error
          expect(result).to be_ok
          # The element span is suppressed, so BOTH become attribute rewrites.
          expect(result.body.scan('base64,').length).to eq(2)
          expect(result.body).to include('<link')
        end

        it 'does not raise for the @import form, or on a <script>' do
          [%(<link rel="stylesheet" href="#{local('app.css')}" style='@import "#{local('app.css')}"'>),
           %(<script src="#{local('app.js')}" style="background:url(#{local('logo.png')})"></script>)]
            .each do |html|
            expect { resolver.call(html) }.not_to raise_error, html[0, 40]
          end
        end

        it 'still uses the structural form when nothing is nested inside the element' do
          result = resolver.call(%(<link rel="stylesheet" href="#{local('app.css')}">))

          expect(result.body).to include('<style>')
        end
      end

      # ------------------------------------------------------------------
      # Replacing an element with a `<style>`/`<script>` block discards everything it carried,
      # and some of that changes what the element MEANS.
      describe 'what a structural rewrite may discard' do
        it 'CARRIES media through, because a print-only stylesheet is what a report has' do
          result = resolver.call(%(<link rel="stylesheet" media="print" href="#{local('app.css')}">))

          expect(result.body).to include('<style media="print">')
        end

        it 'escapes the media value, which is author-controlled and goes in attribute position' do
          result = resolver.call(
            %(<link rel="stylesheet" media='print" onload="alert(1)' href="#{local('app.css')}">)
          )

          expect(result.body).not_to include('onload="alert(1)"')
          expect(result.body).to include('&quot;')
        end

        it 'falls back rather than flattening a module script into a classic one' do
          result = resolver.call(%(<script src="#{local('app.js')}" type="module"></script>))

          expect(result.body).to include('type="module"')
          expect(result.body).to include('data:text/javascript;base64,')
          expect(result.degradations.map { |d| d[:code] }).to include(:asset_structural_fallback)
        end

        it 'falls back rather than enabling a disabled stylesheet' do
          result = resolver.call(%(<link rel="stylesheet" href="#{local('app.css')}" disabled>))

          expect(result.body).not_to include('<style')
          expect(result.body).to include('data:text/css;base64,')
        end

        it 'falls back for defer, async, integrity and anything else it was not told about' do
          %w[defer async integrity="sha384-x" crossorigin nomodule id="x" onload="alert(1)"]
            .each do |extra|
            result = resolver.call(%(<script src="#{local('app.js')}" #{extra}></script>))

            expect(result.body).to include('data:text/javascript;base64,'), extra
          end
        end

        it 'allows the attributes it was told about' do
          result = resolver.call(%(<link rel="stylesheet" charset="utf-8" href="#{local('app.css')}">))

          expect(result.body).to include('<style>')
        end
      end

      # ------------------------------------------------------------------
      # §5.1 caps ONE asset and says nothing about a document, which is the other half of G6's
      # "no unbounded output". These caps are constants for the same reason the fetcher's
      # timeouts are: each is a safety property, not a preference.
      describe 'document-level bounds' do
        it 'resolves AT the reference cap and refuses one past it' do
          at = resolver.call((1..described_class::MAX_REFERENCES)
                              .map { %(<img src="#{local('logo.png')}">) }.join)
          expect(at).to be_ok
          expect(at.counts[:inlined]).to eq(described_class::MAX_REFERENCES)

          past = resolver.call((1..(described_class::MAX_REFERENCES + 1))
                                .map { %(<img src="#{local('logo.png')}">) }.join)
          expect(past).to be_refused
          expect(past.refusals.first.reason).to include('reference cap')
          expect(past.degradations.map { |d| d[:code] }).to include(:asset_document_cap)
        end

        it 'refuses past the aggregate embedded-byte budget, not only the per-asset cap' do
          # Twenty assets each inside `asset_max_bytes` still make a document no engine will draw.
          File.binwrite(File.join(@tmp, 'chunk.png'), "\x89PNG#{'x' * 3_000}")
          policy = Policy.new(inline_max_bytes: 10_000, asset_max_bytes: 10_000)
          stub_const("#{described_class}::MAX_TOTAL_BYTES", 5_000)

          result = resolver(policy: policy)
                   .call((1..3).map { %(<img src="#{local('chunk.png')}">) }.join)

          expect(result).to be_refused
          expect(result.refusals.first.reason).to include('total')
        end
      end

      # ------------------------------------------------------------------
      # The AT-and-one-past the plan claims for the model-choice threshold. The review measured
      # that flipping `<=` to `<` left the entire suite green.
      describe 'the inline threshold, AT and one past' do
        it 'inlines a file of EXACTLY inline_max_bytes and uploads one byte more' do
          exact = 400
          File.binwrite(File.join(@tmp, 'exact.png'), "\x89PNG#{'x' * (exact - 4)}")
          File.binwrite(File.join(@tmp, 'over.png'), "\x89PNG#{'x' * (exact - 3)}")
          policy = Policy.new(inline_max_bytes: exact, asset_max_bytes: 1_000_000)
          capable = %i[asset_inline asset_upload]

          at = resolver(policy: policy, capabilities: capable)
               .call(%(<img src="#{local('exact.png')}">))
          expect(at.models_used).to eq([:inline])
          expect(at.degradations).to be_empty

          past = resolver(policy: policy, capabilities: capable)
                 .call(%(<img src="#{local('over.png')}">))
          expect(past.models_used).to eq([:upload])
        end
      end

      # ------------------------------------------------------------------
      # The store refuses a type/usage mismatch and the resolver must carry that refusal rather
      # than reaching past it. The review measured that removing the `usage:` argument entirely
      # left the suite green.
      describe 'a type that does not match the way the document uses it' do
        it 'refuses a .css referenced by an <img>, naming the mismatch' do
          result = resolver.call(%(<img src="#{local('app.css')}">))

          expect(result).to be_refused
          expect(result.refusals.first.reason).to include('not usable for the way')
        end

        it 'refuses a .png referenced by <link rel=stylesheet>' do
          result = resolver.call(%(<link rel="stylesheet" href="#{local('logo.png')}">))

          expect(result).to be_refused
          expect(result.refusals.first.reason).to include('not usable for the way')
        end

        it 'refuses a .css referenced by <script src>, rather than inlining it as a program' do
          result = resolver.call(%(<script src="#{local('app.css')}"></script>))

          expect(result).to be_refused
          expect(result.body).not_to include('color:red')
        end
      end

      # ------------------------------------------------------------------
      describe 'the refusal reason names what an operator configured' do
        it 'announces the collapse rather than a mode nobody chose' do
          # The first version returned early on the local reason and reported "asset_policy
          # bundled" to an operator who had set `:external` — naming a mode they never
          # configured and never mentioning the collapse, which is the one thing it exists to say.
          result = resolver(policy: Policy.new(mode: :external, allowlist: []))
                   .call(%(<img src="#{local('missing.png')}">))

          reason = result.refusals.first.reason
          expect(reason).to include('does not exist on disk')
          expect(reason).to include('asset_allowlist is empty')
          expect(reason).to include('External'.downcase)
        end

        it 'names the missing host when the mode permits the class' do
          result = resolver(policy: Policy.new(mode: :external, allowlist: %w[other.example]),
                            fetcher: StubFetcher.new)
                   .call('<img src="https://cdn.example/a.png">')

          expect(result.refusals.first.reason).to include('cdn.example')
          expect(result.refusals.first.reason).to include('asset_allowlist')
        end
      end

      describe 'the result is data, not render types' do
        it 'refuses to name the render layer, so `spec/assets` needs none of it loaded' do
          # F-13b: this layer names neither the render layer nor the Liquid layer, and
          # `script/gates/layer_purity.sh` has an arm for it. Asserted here as well, because
          # a gate is a grep and this is the behaviour behind it.
          result = resolver.call(%(<img src="#{local('logo.png')}">))

          expect(result).to be_a(Resolution)
          expect(result.degradations.first).to be_nil
          expect(result.to_h.keys).to include('ok', 'assets', 'models_used', 'refusals')
        end
      end
    end
  end
end
