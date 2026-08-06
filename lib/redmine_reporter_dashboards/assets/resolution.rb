# frozen_string_literal: true

module RedmineReporterDashboards
  module Assets
    # WHAT ONE RESOLVER WALK PRODUCED, as data.
    #
    # Deliberately not a `Render::Success`/`Render::Failure`. This layer names neither the
    # render layer nor the Liquid layer (see `assets.rb`), so a refusal here is a plain
    # value and `Render::AssetBinding` is what turns it into `Failure(:asset_unresolved)`.
    # The split is what lets `spec/assets/` run with no render types loaded at all, and it
    # is why the refusal carries the URL rather than a formatted message: the message is
    # the binding's decision, because the binding knows it is user-facing.
    #
    # `assets` is a PLAIN frozen Hash of plain frozen Hashes — `{ name => { 'bytes' =>,
    # 'content_type' => } }` — for the same reason. It goes straight into
    # `DocumentRequest#assets`, and `render/` must be able to carry it without naming a
    # type from here.
    class Resolution
      Refusal = Struct.new(:url, :usage, :classification, :reason, keyword_init: true) do
        def to_h
          { 'url' => url, 'usage' => usage.to_s, 'classification' => classification.to_s,
            'reason' => reason }.freeze
        end
      end

      attr_reader :body, :assets, :degradations, :refusals, :models_used, :counts

      def initialize(body:, assets: {}, degradations: [], refusals: [], models_used: [],
                     counts: {})
        @body = body.to_s.freeze
        @assets = assets.freeze
        @degradations = Array(degradations).freeze
        @refusals = Array(refusals).freeze
        @models_used = Array(models_used).map(&:to_sym).uniq.freeze
        @counts = counts.freeze
        freeze
      end

      # `ok?` means nothing was refused. It does NOT mean nothing degraded — an oversize
      # asset inlined anyway, or an `srcset` collapsed to one candidate, are both recorded
      # and both fine. Conflating the two is how a degradation becomes invisible, which is
      # the failure mode `Render::Success#degraded?` exists to prevent one layer down.
      def ok?
        refusals.empty?
      end

      def refused?
        !ok?
      end

      def degraded?
        !degradations.empty?
      end

      # Every refused URL, deduplicated, in the order they were met. This is what a
      # `Failure` message is built from — T-33: "a third-party URL under `:bundled` yields
      # `Failure(:asset_unresolved)` **naming the URL**, not a blank image".
      def refused_urls
        refusals.map(&:url).uniq
      end

      def to_h
        { 'ok' => ok?, 'assets' => assets.keys, 'models_used' => models_used.map(&:to_s),
          'degradations' => degradations.map { |entry| entry.transform_keys(&:to_s) },
          'refusals' => refusals.map(&:to_h), 'counts' => counts.transform_keys(&:to_s) }.freeze
      end
    end
  end
end
