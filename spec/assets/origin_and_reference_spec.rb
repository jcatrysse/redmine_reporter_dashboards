# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/assets'

# T-33 — `Origin` and `Reference`, which between them make every later decision.
#
# The classification is the ONLY judgement in this layer: the policy, the fetcher and the
# resolver all key off it, so a reference classified `:same_origin` when it is not is an
# allowlist bypass and one classified `:third_party` when it is ours is a report that
# refuses to render. Both are tested from the wrong direction as well as the right one.
module RedmineReporterDashboards
  module Assets
    RSpec.describe Origin do
      it 'parses the two settings Redmine builds every request-less URL from' do
        origin = described_class.from_settings('https', 'redmine.example')

        expect(origin.scheme).to eq('https')
        expect(origin.host).to eq('redmine.example')
        expect(origin.port).to eq(443)
        expect(origin.prefix).to eq('')
        expect(origin).to be_known
      end

      it 'preserves a sub-path prefix, because that is the install a hand-built URL breaks on' do
        origin = described_class.from_settings('https', 'redmine.example/redmine')

        expect(origin.prefix).to eq('/redmine')
        expect(origin.to_s).to eq('https://redmine.example/redmine')
        # And strips it again, because `LocalStore` maps the un-prefixed path.
        expect(origin.strip_prefix('/redmine/plugin_assets/x.png')).to eq('/plugin_assets/x.png')
        expect(origin.strip_prefix('/plugin_assets/x.png')).to eq('/plugin_assets/x.png')
        expect(origin.strip_prefix('/redmineelse/x.png')).to eq('/redmineelse/x.png')
      end

      it 'keeps a non-default port and compares on HOST AND PORT' do
        origin = described_class.from_settings('http', 'redmine.example:3000')

        expect(origin.port).to eq(3000)
        expect(origin.to_s).to eq('http://redmine.example:3000')
        expect(origin.same?('redmine.example', 3000)).to be(true)
        # The case this exists for: a development instance's asset must not be treated as
        # this install's just because the host name matches.
        expect(origin.same?('redmine.example', 8080)).to be(false)
        expect(origin.same?('other.example', 3000)).to be(false)
      end

      it 'defaults the compared port from the scheme when the URL omitted it' do
        origin = described_class.from_settings('https', 'redmine.example')

        expect(origin.same?('redmine.example', nil, 'https')).to be(true)
        expect(origin.same?('redmine.example', nil, 'http')).to be(false)
      end

      it 'FAILS CLOSED when the port cannot be determined at all' do
        # "If I cannot work out the port, assume it is ours" means "assume this reference is
        # local and may be read off disk". The default has to be the other way round.
        origin = described_class.from_settings('https', 'redmine.example')

        expect(origin.same?('redmine.example', nil, nil)).to be(false)
        expect(origin.same?('redmine.example', nil, 'gopher')).to be(false)
      end

      it 'handles an IPv6 literal with and without a port' do
        expect(described_class.parse('http://[::1]:3000').host).to eq('[::1]')
        expect(described_class.parse('http://[::1]:3000').port).to eq(3000)
        expect(described_class.parse('https://[2001:db8::1]').host).to eq('[2001:db8::1]')
      end

      it 'is NOT known when nothing is configured, and that is the fail-closed answer' do
        # An unconfigured `host_name` must make every absolute URL third-party — refused
        # under the default policy — rather than accidentally same-origin.
        [described_class.new, described_class.parse(''), described_class.parse(nil)]
          .each do |origin|
          expect(origin).not_to be_known
          expect(origin.same?('redmine.example', 443)).to be(false)
          expect(origin.to_s).to eq('')
        end
      end
    end

    # ------------------------------------------------------------------
    RSpec.describe Reference do
      let(:origin) { Origin.from_settings('https', 'redmine.example') }

      def reference(raw, usage: :image)
        described_class.new(raw: raw, usage: usage, span: [0, raw.length], origin: origin)
      end

      describe 'classification' do
        {
          'data:image/png;base64,AAA' => :data_uri,
          'DATA:image/png;base64,AAA' => :data_uri,
          '#anchor' => :ignored,
          'mailto:someone@example.com' => :ignored,
          'javascript:alert(1)' => :ignored,
          'about:blank' => :ignored,
          'cid:part1' => :ignored,
          'file:///etc/passwd' => :ignored,
          '/plugin_assets/x/logo.png' => :local_path,
          '/redmine/plugin_assets/x/logo.png' => :local_path,
          'https://redmine.example/logo.png' => :same_origin,
          'https://REDMINE.example/logo.png' => :same_origin,
          '//redmine.example/logo.png' => :same_origin,
          'https://third.example/logo.png' => :third_party,
          '//third.example/logo.png' => :third_party,
          'http://redmine.example/logo.png' => :third_party,
          'gopher://third.example/logo.png' => :unresolvable,
          'logo.png' => :unresolvable,
          './logo.png' => :unresolvable,
          '../logo.png' => :unresolvable,
          '' => :ignored
        }.each do |raw, expected|
          it "classifies #{raw.inspect} as #{expected}" do
            expect(reference(raw).classification).to eq(expected)
          end
        end

        it 'treats http:// as third-party on an https install, because the ORIGIN differs' do
          # Not a special case — `same?` compares the effective port, and 80 is not 443.
          # Worth pinning: an http reference on an https install is a mixed-content
          # reference, and treating it as "ours" would let it past the allowlist.
          expect(reference('http://redmine.example/logo.png').classification).to eq(:third_party)
        end

        it 'is :unresolvable for a relative path, which is a refusal and not a blank image' do
          # A render has no document URL to resolve against, so this genuinely cannot be
          # answered. INV-4: naming it beats drawing an empty box a reader cannot tell from
          # an absent one.
          expect(reference('logo.png').classification).to eq(:unresolvable)
        end
      end

      describe 'decoding' do
        it 'resolves HTML entities before classifying or comparing' do
          # `<img src="https://third.example/a&amp;b.png">` refers to `a&b.png`.
          ref = reference('https://third.example/a&amp;b.png')

          expect(ref.url).to eq('https://third.example/a&b.png')
          expect(ref.path).to eq('/a&b.png')
        end

        it 'resolves a numeric entity in the HOST, which is how a check gets bypassed' do
          # `&#101;` is `e`. A host comparison against the escaped form would see
          # `third.exampl&#101;` and call it something else entirely.
          expect(reference('https://third.exampl&#101;/x.png').host).to eq('third.example')
        end

        it 'strips a query and a fragment from the path' do
          expect(reference('/plugin_assets/x/logo.png?v=2#f').path).to eq('/plugin_assets/x/logo.png')
        end
      end

      describe 'the network questions' do
        it 'answers the same fetch classification for a path and its absolute form' do
          expect(reference('/plugin_assets/x/logo.png').fetch_classification).to eq(:same_origin)
          expect(reference('https://redmine.example/x.png').fetch_classification).to eq(:same_origin)
        end

        it 'DROPS URL credentials rather than carrying them' do
          # §5.1: assets are fetched anonymously or not at all. Userinfo is the oldest way
          # to smuggle a credential past a check that only looked at the host — and the
          # host it would smuggle it past is `cdn.example`, not `redmine.example`.
          ref = reference('https://user:secret@cdn.example/logo.png')

          expect(ref.host).to eq('cdn.example')
          expect(ref.classification).to eq(:third_party)
          # The path is taken from after the authority, so the credential is not smuggled
          # into it either.
          expect(ref.path).to eq('/logo.png')
        end

        it 'does not treat a host that merely CONTAINS ours as ours' do
          %w[
            https://redmine.example.attacker.net/x.png
            https://notredmine.example/x.png
            https://redmine.example:8443/x.png
          ].each do |url|
            expect(reference(url).classification).to eq(:third_party), url
          end
        end

        it 'answers nil host and port for anything that reaches no network' do
          %w[data:image/png;base64,AA #a mailto:x@y logo.png].each do |raw|
            expect(reference(raw).host).to be_nil, raw
            expect(reference(raw).port).to be_nil, raw
          end
        end

        it 'defaults the port from the scheme' do
          expect(reference('https://cdn.example/x.png').port).to eq(443)
          expect(reference('https://cdn.example:8443/x.png').port).to eq(8443)
        end
      end

      describe 'display' do
        it 'caps the length, because it lands in a message a user reads' do
          long = "https://cdn.example/#{'a' * 400}.png"

          expect(reference(long).display.length).to be <= Reference::MAX_DISPLAY + 1
        end

        it 'strips control characters, each named explicitly' do
          # WRITTEN WITH EXPLICIT ESCAPES, and the reason is a bug in the first version of
          # this example: it carried a literal NUL byte in the source where a space was
          # intended, which made the whole file "binary" to `grep` and made the assertion
          # pass because NUL is a control character too. A control character in a test about
          # control characters has to be spelled, not typed.
          {
            "https://cdn.example/a\nb.png" => 'https://cdn.example/ab.png',
            "https://cdn.example/a\u0000b.png" => 'https://cdn.example/ab.png',
            "https://cdn.example/a\tb.png" => 'https://cdn.example/ab.png',
            "https://cdn.example/a\rb.png" => 'https://cdn.example/ab.png'
          }.each do |raw, expected|
            expect(reference(raw).display).to eq(expected), raw.inspect
          end

          # A SPACE IS NOT A CONTROL CHARACTER and is deliberately kept: `%20` in a URL is
          # legitimate, and silently deleting it would change which file the refusal names.
          expect(reference('https://cdn.example/a b.png').display)
            .to eq('https://cdn.example/a b.png')
        end
      end

      it 'refuses an unknown usage rather than carrying it' do
        expect { described_class.new(raw: '/x.png', usage: :whatever, span: [0, 6]) }
          .to raise_error(ArgumentError, /is not a usage/)
      end

      it 'is frozen and every derived value is already computed' do
        # The first draft memoised lazily and raised FrozenError on first use. A frozen
        # value object with a lazy memo is a contradiction; this pins the resolution.
        ref = reference('https://cdn.example/x.png')

        expect(ref).to be_frozen
        expect { ref.classification }.not_to raise_error
        expect { ref.path }.not_to raise_error
      end
    end
  end
end
