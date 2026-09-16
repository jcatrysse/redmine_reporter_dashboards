# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/assets'

# T-33 — `asset_policy` (technical-spec.md §5.1, FR-64).
#
# The clause this file exists for is the one T-33 names as "the fail-closed test, and the
# one most likely to be got wrong": an empty `asset_allowlist` under `:external` must behave
# IDENTICALLY to `:bundled`. Identically is asserted as an equality of every answer the
# policy gives, not as a spot check on one predicate — because a partial collapse (fetch
# denied but the mode still reported as external) is exactly the shape that would let a
# caller elsewhere reach a different conclusion.
module RedmineReporterDashboards
  module Assets
    RSpec.describe Policy do
      # A logger that records rather than prints, so FR-15's "dropped with a log line" is
      # a fact about what was logged and not about what the code looks like.
      let(:logged) { [] }
      let(:logger) { double('logger', warn: nil) }

      before { allow(logger).to receive(:warn) { |message| logged << message } }

      describe 'the three values' do
        it 'defaults to :bundled, which fetches nothing' do
          policy = described_class.bundled

          expect(policy.mode).to eq(:bundled)
          expect(policy.effective_mode).to eq(:bundled)
          expect(policy).to be_bundled
          expect(policy.may_fetch?(:same_origin)).to be(false)
          expect(policy.may_fetch?(:third_party)).to be(false)
        end

        it ':redmine fetches same-origin references and refuses third-party ones' do
          policy = described_class.new(mode: :redmine, allowlist: %w[redmine.example])

          expect(policy.may_fetch?(:same_origin)).to be(true)
          expect(policy.may_fetch?(:third_party)).to be(false)
        end

        it ':external fetches both classes, still allowlist-only' do
          policy = described_class.new(mode: :external, allowlist: %w[cdn.example])

          expect(policy.may_fetch?(:same_origin)).to be(true)
          expect(policy.may_fetch?(:third_party)).to be(true)
          expect(policy.fetch_allowed?(:third_party, 'cdn.example')).to be(true)
          # The mode permits the class and the host is not listed. Both conditions,
          # not either.
          expect(policy.fetch_allowed?(:third_party, 'other.example')).to be(false)
        end

        it 'refuses an unknown mode rather than falling back, when constructed in code' do
          expect { described_class.new(mode: :everything) }
            .to raise_error(Policy::InvalidPolicy, /not an asset policy/)
        end
      end

      # ------------------------------------------------------------------
      # The clause T-33 flags as most likely to be got wrong.
      describe 'an empty allowlist' do
        it 'makes :external behave IDENTICALLY to :bundled, answer for answer' do
          external = described_class.new(mode: :external, allowlist: [])
          bundled = described_class.bundled

          %i[same_origin third_party local_path unresolvable].each do |classification|
            expect(external.may_fetch?(classification))
              .to eq(bundled.may_fetch?(classification)),
                  "may_fetch?(#{classification}) differs"
            expect(external.fetch_allowed?(classification, 'anything.example'))
              .to eq(bundled.fetch_allowed?(classification, 'anything.example')),
                  "fetch_allowed?(#{classification}) differs"
          end
          expect(external.effective_mode).to eq(bundled.effective_mode)
          expect(external).to be_bundled
        end

        it 'collapses :redmine too, and there is nothing to lose by it' do
          # Under :bundled a same-origin reference is rewritten to the file on disk, which
          # is strictly better than fetching it. So the fail-closed direction costs the
          # operator nothing they had.
          policy = described_class.new(mode: :redmine, allowlist: [])

          expect(policy).to be_bundled
          expect(policy.may_fetch?(:same_origin)).to be(false)
        end

        it 'still REPORTS the configured mode, so the collapse can be shown' do
          policy = described_class.new(mode: :external, allowlist: [])

          # `mode` is what the operator chose; `effective_mode` is what happens. Both are
          # needed: a settings page that only knew the second could not tell an
          # administrator their switch did nothing.
          expect(policy.mode).to eq(:external)
          expect(policy.effective_mode).to eq(:bundled)
          expect(policy).to be_collapsed
        end

        it 'is not "collapsed" when the mode is already the default' do
          expect(described_class.bundled).not_to be_collapsed
        end
      end

      # ------------------------------------------------------------------
      describe 'hosts, not patterns' do
        it 'accepts bare host names, lowercased, trailing dot stripped, deduplicated' do
          policy = described_class.new(mode: :external,
                                       allowlist: ['CDN.Example', 'cdn.example.', ' a.b '])

          expect(policy.allowlist).to eq(%w[cdn.example a.b])
        end

        it 'refuses a wildcard, a scheme, a port and a path when constructed in code' do
          ['*.example.com', 'https://cdn.example', 'cdn.example:443',
           'cdn.example/path'].each do |bad|
            expect { described_class.new(mode: :external, allowlist: [bad]) }
              .to raise_error(Policy::InvalidPolicy, /not bare hostnames/), bad
          end
        end

        it 'matches a host case-insensitively and with a trailing dot' do
          policy = described_class.new(mode: :external, allowlist: %w[cdn.example])

          expect(policy.allows_host?('CDN.example')).to be(true)
          expect(policy.allows_host?('cdn.example.')).to be(true)
          expect(policy.allows_host?('evil.cdn.example')).to be(false)
          # The wildcard case, from the other side: a listed host must not match a
          # subdomain, or `cdn.example` would authorise `cdn.example.attacker.net`.
          expect(policy.allows_host?('cdn.example.attacker.net')).to be(false)
          expect(policy.allows_host?(nil)).to be(false)
        end
      end

      # ------------------------------------------------------------------
      # FR-15: typed, bounded, and over-limit input DROPPED WITH A LOG LINE rather than
      # stored. Redmine validates nothing on plugin settings, so this is the only place it
      # can happen.
      describe '.from_settings' do
        it 'reads the four keys an administrator can set' do
          policy = described_class.from_settings(
            { 'asset_policy' => 'external', 'asset_allowlist' => "cdn.example\nfonts.example",
              'inline_max_bytes' => '1024', 'asset_max_bytes' => '2048' }, logger: logger
          )

          expect(policy.mode).to eq(:external)
          expect(policy.allowlist).to eq(%w[cdn.example fonts.example])
          expect(policy.inline_max_bytes).to eq(1024)
          expect(policy.asset_max_bytes).to eq(2048)
          expect(policy.dropped).to be_empty
          expect(logged).to be_empty
        end

        it 'accepts an allowlist pasted with commas, semicolons or spaces' do
          policy = described_class.from_settings(
            { 'asset_policy' => 'external', 'asset_allowlist' => 'a.example, b.example;c.example' },
            logger: logger
          )

          expect(policy.allowlist).to eq(%w[a.example b.example c.example])
        end

        it 'drops an unknown mode, logs it, and uses :bundled' do
          policy = described_class.from_settings({ 'asset_policy' => 'anything' }, logger: logger)

          expect(policy.mode).to eq(:bundled)
          expect(policy.dropped.map { |entry| entry[:key] }).to eq(%w[asset_policy])
          expect(logged.join).to include('asset_policy')
        end

        it 'drops a pattern from the allowlist and keeps the valid entries' do
          policy = described_class.from_settings(
            { 'asset_policy' => 'external',
              'asset_allowlist' => "*.example.com\ncdn.example\nhttps://x.example" },
            logger: logger
          )

          expect(policy.allowlist).to eq(%w[cdn.example])
          expect(policy.dropped.length).to eq(2)
          expect(logged.length).to eq(2)
        end

        it 'never raises on operator input, whatever shape it is' do
          [nil, {}, 'a string', 42, { 'asset_policy' => nil, 'inline_max_bytes' => 'lots' }]
            .each do |input|
            expect { described_class.from_settings(input, logger: logger) }.not_to raise_error
          end
        end

        # ---------- the boundaries, AT and ONE PAST (CLAUDE.md §3 phase 3) ----------
        it 'accepts a cap AT the ceiling and clamps one past it' do
          at = described_class.from_settings(
            { 'asset_max_bytes' => Policy::MAX_ASSET_MAX_BYTES.to_s }, logger: logger
          )
          expect(at.asset_max_bytes).to eq(Policy::MAX_ASSET_MAX_BYTES)
          expect(at.dropped).to be_empty

          past = described_class.from_settings(
            { 'asset_max_bytes' => (Policy::MAX_ASSET_MAX_BYTES + 1).to_s }, logger: logger
          )
          expect(past.asset_max_bytes).to eq(Policy::MAX_ASSET_MAX_BYTES)
          expect(past.dropped.first[:reason]).to include('ceiling')
        end

        it 'accepts a cap AT the minimum and replaces one below it' do
          at = described_class.from_settings({ 'inline_max_bytes' => '1' }, logger: logger)
          expect(at.inline_max_bytes).to eq(1)

          below = described_class.from_settings({ 'inline_max_bytes' => '0' }, logger: logger)
          expect(below.inline_max_bytes).to eq(Policy::DEFAULT_INLINE_MAX_BYTES)
          expect(below.dropped.first[:reason]).to include('below')

          negative = described_class.from_settings({ 'inline_max_bytes' => '-5' }, logger: logger)
          expect(negative.inline_max_bytes).to eq(Policy::DEFAULT_INLINE_MAX_BYTES)
        end

        it 'lowers an inline threshold that is above the hard cap, rather than raising' do
          policy = described_class.from_settings(
            { 'inline_max_bytes' => '4000', 'asset_max_bytes' => '2000' }, logger: logger
          )

          expect(policy.inline_max_bytes).to eq(2000)
          expect(policy.asset_max_bytes).to eq(2000)
          expect(policy.dropped.map { |entry| entry[:key] }).to include('inline_max_bytes')
        end

        it 'refuses the same combination when constructed in CODE, because that is a bug' do
          expect { described_class.new(inline_max_bytes: 4000, asset_max_bytes: 2000) }
            .to raise_error(Policy::InvalidPolicy, /never be reached/)
        end

        it 'survives a nil logger' do
          expect { described_class.from_settings({ 'asset_policy' => 'nope' }) }
            .not_to raise_error
        end
      end

      describe 'the constants §5.1 fixes' do
        it 'keeps the transport conditions as constants, not settings' do
          # Each is a security property, and a setting is a thing an operator can be
          # talked into changing. Asserted so that turning one into a setting has to break
          # a test rather than merely pass review.
          expect(Policy::CONNECT_TIMEOUT_S).to eq(2)
          expect(Policy::TOTAL_TIMEOUT_S).to eq(5)
          expect(Policy::MAX_REDIRECTS).to eq(0)
          expect(Policy::FETCH_SCHEME).to eq('https')
        end

        it 'uses §5.1\'s documented defaults' do
          expect(Policy::DEFAULT_INLINE_MAX_BYTES).to eq(512 * 1024)
          expect(Policy::DEFAULT_ASSET_MAX_BYTES).to eq(8 * 1024 * 1024)
        end
      end
    end
  end
end
