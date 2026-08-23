# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/assets'
require_relative '../../lib/redmine_reporter_dashboards/render/asset_binding'

# T-33 — the seam: `Assets::Resolution` in, `DocumentRequest` or `Failure` out.
#
# The clause this file proves is the one that says what a refusal LOOKS like: "a third-party
# URL under `:bundled` yields `Failure(:asset_unresolved)` **naming the URL**, not a blank
# image". Naming it is the requirement. A report with a silently missing logo is one a reader
# cannot tell from a report that never had one, and if it is an audit record the difference
# matters (INV-4).
module RedmineReporterDashboards
  module Render
    RSpec.describe AssetBinding do
      def resolution(**overrides)
        Assets::Resolution.new(**{ body: '<html><body>ok</body></html>' }.merge(overrides))
      end

      # `policy_caused` IS AN ARGUMENT NOW, and that field is the whole fix. The cause used
      # to be inferred from the reason PROSE, and an independent QA pass measured the
      # inference wrong for five of the seven refusal shapes: `Resolver#refusal_reason`
      # appends a policy sentence to every refusal it composes, so "does the reason mention
      # asset_policy" answered yes for a missing file and for an attachment the viewer may
      # not see. The default matches the Struct's: NOT policy-caused, because that is the
      # direction which cannot invent a remedy.
      def refusal(url, reason: 'asset_policy bundled does not fetch third_party references',
                  policy_caused: true)
        Assets::Resolution::Refusal.new(url: url, usage: :image, classification: :third_party,
                                        reason: reason, policy_caused: policy_caused)
      end

      describe 'a clean resolution' do
        it 'becomes a DocumentRequest carrying the rewritten body' do
          request = described_class.apply(resolution: resolution(body: '<p>inlined</p>'),
                                          correlation_id: 'corr-1', page_size: 'A3')

          expect(request).to be_a(DocumentRequest)
          expect(request.body).to eq('<p>inlined</p>')
          expect(request.page_size).to eq('A3')
          expect(request.correlation_id).to eq('corr-1')
        end

        it 'passes the asset bytes through as DocumentRequest#assets' do
          assets = { 'rrd-asset-abc.png' => { 'bytes' => 'PNG', 'content_type' => 'image/png' } }
          request = described_class.apply(resolution: resolution(assets: assets),
                                          correlation_id: 'corr-1')

          expect(request.assets).to eq(assets)
        end

        it 'requires AND makes essential :asset_upload when assets travel in the request' do
          # Not circular even though the resolver only chose upload because the engine
          # declared it: the resolution and the render can be separated in time — a queued
          # report, a retry after an engine switch, a preview on one engine and a document on
          # another — and an engine that cannot read request-borne bytes would draw a document
          # with every uploaded asset missing. Declaring it essential turns that into a
          # refusal that names the capability.
          request = described_class.apply(
            resolution: resolution(assets: { 'a.png' => { 'bytes' => 'x',
                                                          'content_type' => 'image/png' } }),
            correlation_id: 'corr-1'
          )

          expect(request.required_capabilities).to include(:asset_upload)
          expect(request.essential_capabilities).to include(:asset_upload)
        end

        it 'adds nothing when no asset travels in the request' do
          request = described_class.apply(resolution: resolution, correlation_id: 'corr-1')

          expect(request.required_capabilities).to be_empty
          expect(request.essential_capabilities).to be_empty
        end

        it 'preserves capabilities the caller already asked for' do
          request = described_class.apply(
            resolution: resolution(assets: { 'a.png' => { 'bytes' => 'x',
                                                          'content_type' => 'image/png' } }),
            correlation_id: 'corr-1',
            required_capabilities: %i[javascript readiness_expression],
            essential_capabilities: [:javascript]
          )

          expect(request.required_capabilities).to include(:javascript, :readiness_expression,
                                                           :asset_upload)
          expect(request.essential_capabilities).to include(:javascript, :asset_upload)
        end
      end

      # ------------------------------------------------------------------
      describe 'a refused resolution' do
        it 'becomes Failure(:asset_unresolved) naming the URL' do
          result = described_class.apply(
            resolution: resolution(refusals: [refusal('https://third.example/tracker.png')]),
            correlation_id: 'corr-9', engine: :chromium_cdp
          )

          expect(result).to be_a(Failure)
          expect(result.code).to eq(:asset_unresolved)
          expect(result.message).to include('https://third.example/tracker.png')
          expect(result.correlation_id).to eq('corr-9')
          expect(result.engine).to eq(:chromium_cdp)
        end

        it 'is a Failure and therefore HAS NO BYTES to attach' do
          # INV-5: a Failure is not bytes, cannot be attached, and asking for them raises
          # rather than producing a zero-byte PDF in somebody's inbox.
          result = described_class.apply(resolution: resolution(refusals: [refusal('https://x/y.png')]),
                                        correlation_id: 'c')

          expect { result.bytes }.to raise_error(NoMethodError)
          expect(Result.failure?(result)).to be(true)
        end

        it 'names several URLs, and caps the list' do
          urls = (1..8).map { |n| "https://third.example/#{n}.png" }
          result = described_class.apply(
            resolution: resolution(refusals: urls.map { |url| refusal(url) }), correlation_id: 'c'
          )

          expect(result.message).to include('https://third.example/1.png')
          expect(result.message).to include('and 3 more')
          expect(result.message).not_to include('https://third.example/8.png')
          # ALL of them are in `detail`, which is what the diagnostics view reads (FR-58).
          expect(result.detail.length).to eq(8)
        end

        it 'deduplicates a URL referenced several times' do
          result = described_class.apply(
            resolution: resolution(refusals: [refusal('https://x/y.png'), refusal('https://x/y.png')]),
            correlation_id: 'c'
          )

          expect(result.message.scan('https://x/y.png').length).to eq(1)
        end

        it 'carries a SAFE message: the URLs and no reason prose' do
          # `Failure#message` is shown to a user and "must never carry a raw exception". One of
          # the reasons the resolver can record is the fetcher's `:transport` reason, which
          # carries an exception class and message verbatim — so a message that relayed reasons
          # would trade a false cause for an information leak. The reasons live in `detail`,
          # which is what FR-58's diagnostics view reads.
          result = described_class.apply(
            resolution: resolution(refusals: [refusal('https://x/y.png',
                                                      reason: 'RuntimeError at /srv/app/lib/x.rb:12')]),
            correlation_id: 'c'
          )

          expect(result.message).not_to include('RuntimeError')
          expect(result.message).not_to include('/srv/app')
          expect(result.detail.first['reason']).to include('RuntimeError')
        end

        # THE CAUSE IS NOT ALWAYS THE POLICY, and the first version said it always was — telling
        # an administrator to change a setting that provably would not help.
        it 'asserts the policy as the cause ONLY when every refusal is a policy one' do
          policy_only = described_class.apply(
            resolution: resolution(refusals: [refusal('https://third.example/a.png')]),
            correlation_id: 'c'
          )

          expect(policy_only.message).to include('asset policy does not permit')
        end

        it 'does NOT blame the policy for a relative reference, which never consults it' do
          relative = Assets::Resolution::Refusal.new(
            url: 'logo.png', usage: :image, classification: :unresolvable,
            reason: 'is not resolvable: a render has no document URL'
          )

          result = described_class.apply(resolution: resolution(refusals: [relative]),
                                        correlation_id: 'c')

          expect(result.message).not_to include('asset policy does not permit')
          expect(result.message).to include('could not be resolved')
          expect(result.message).to include('logo.png')
        end

        # THE REASON STRINGS HERE WERE NOT WHAT THE RESOLVER EMITS, and it mattered. The
        # wrongly-typed one lacked the `", and asset_policy bundled does not fetch …"` tail
        # that `refusal_reason` really appends — so this example passed against an
        # implementation that blamed the policy for every refusal, which is what shipped.
        # HANDOVER §1's fixture-that-cannot-discriminate, in the one place built to catch
        # this. The reasons are corrected to the composed shape and the cause is carried as
        # data; `spec/assets/resolver_spec.rb` asserts the resolver SETS that data, which
        # is the half no fixture in this file can see.
        it 'does NOT blame the policy for an oversize or wrongly-typed asset' do
          [['is 9000000 bytes, above the 8388608-byte asset_max_bytes cap', :local_path],
           ['is on disk, but its type is not usable for the way the document references it, ' \
            'and asset_policy bundled does not fetch same_origin references',
            :local_path]].each do |reason, classification|
            refused = Assets::Resolution::Refusal.new(url: '/plugin_assets/x/a.png', usage: :image,
                                                      classification: classification, reason: reason,
                                                      policy_caused: false)
            result = described_class.apply(resolution: resolution(refusals: [refused]),
                                          correlation_id: 'c')

            expect(result.message).not_to include('asset policy does not permit'), reason
          end
        end

        it 'falls back to the neutral message when the refusals are MIXED' do
          mixed = [refusal('https://third.example/a.png'),
                   Assets::Resolution::Refusal.new(url: 'logo.png', usage: :image,
                                                   classification: :unresolvable,
                                                   reason: 'is not resolvable')]

          result = described_class.apply(resolution: resolution(refusals: mixed),
                                        correlation_id: 'c')

          expect(result.message).not_to include('asset policy does not permit')
          expect(result.message).to include('2 assets')
        end

        it 'builds no DocumentRequest at all, so no engine can be handed the document' do
          result = described_class.apply(resolution: resolution(refusals: [refusal('https://x/y.png')]),
                                        correlation_id: 'c')

          expect(result).not_to be_a(DocumentRequest)
        end
      end

      # ------------------------------------------------------------------
      describe 'degradations' do
        it 'translates the asset layer\'s plain Hashes into Render::Degradation' do
          # `Assets` speaks in plain Hashes precisely so it does not have to name this layer
          # (F-13b). This is the one place the translation happens.
          resolved = resolution(degradations: [{ code: :asset_srcset_collapsed,
                                                 detail: 'dropped 2' }])

          degradations = described_class.degradations(resolved)

          expect(degradations.length).to eq(1)
          expect(degradations.first).to be_a(Degradation)
          expect(degradations.first.capability).to eq(:asset_srcset_collapsed)
          expect(degradations.first.detail).to eq('dropped 2')
        end

        it 'reads a String-keyed Hash too, because a resolution may have been serialised' do
          resolved = resolution(degradations: [{ 'code' => :asset_inline_oversize,
                                                 'detail' => 'big' }])

          expect(described_class.degradations(resolved).first.capability)
            .to eq(:asset_inline_oversize)
        end

        it 'answers an empty list rather than nil for a clean resolution' do
          expect(described_class.degradations(resolution)).to eq([])
        end
      end

      describe 'the boundary itself' do
        it 'names nothing this layer is forbidden to name' do
          # E3 is a grep, and this is the behaviour behind it: the file constructs render
          # types from a resolution and does no resolving — no socket, no file, no model.
          source = File.read(
            File.expand_path('../../lib/redmine_reporter_dashboards/render/asset_binding.rb',
                             __dir__),
            encoding: 'UTF-8'
          )
          code = source.lines.reject { |line| line.strip.start_with?('#') }.join

          %w[Net::HTTP Faraday ActiveRecord Rails. cookie].each do |forbidden|
            expect(code).not_to include(forbidden), forbidden
          end
        end
      end
    end
  end
end
