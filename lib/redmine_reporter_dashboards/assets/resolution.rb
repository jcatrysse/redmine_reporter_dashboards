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
      # `policy_caused` IS A FIELD BECAUSE THE ALTERNATIVE WAS READING THE PROSE, AND THAT
      # WAS MEASURED WRONG.
      #
      # `Render::AssetBinding` has to decide whether to print "…which the current asset
      # policy does not permit", because telling an administrator to enable egress for a
      # refusal egress cannot fix is a remedy that provably does nothing (INV-4, and
      # `asset_binding.rb` argues it at length). It decided by looking for the substring
      # `asset_policy` in `reason` — and `Resolver#refusal_reason` appends
      # `policy_reason` to EVERY refusal it composes, so the guard matched everything and
      # five of the seven refusal causes got the wrong remedy. Found end to end by an
      # independent QA pass; the spec that "covered" it hand-wrote a reason string the
      # resolver cannot produce, which is HANDOVER §1's fixture-that-cannot-discriminate.
      #
      # So the classification is made where the decision is made — in `Resolver`, which
      # knows whether it consulted the policy or the disk — and travels as data. Prose is
      # for the reader; this is for the caller.
      # `cap_exceeded` IS THE SECOND CLASSIFICATION, and it exists for the same reason as
      # the first: the CAUSE decides what a reader is told, and the cause cannot be
      # recovered from the prose. A document past `MAX_REFERENCES` produced
      # `Failure(:asset_unresolved)` listing URLs that "could not be resolved" — true of
      # the mechanism and false as an explanation, because nothing is wrong with those URLs
      # and resolving them individually would work. The reader needs "this report is too
      # big", which is a different sentence, a different code, and a different remedy.
      # Curator decision, 2026-08-10 (§Findings E-26 #4).
      Refusal = Struct.new(:url, :usage, :classification, :reason, :policy_caused,
                           :cap_exceeded, keyword_init: true) do
        # DEFAULTS TO FALSE, and that direction matters: a refusal nobody classified must
        # not claim the policy is at fault, because that is the answer that sends somebody
        # to open the network.
        def policy_caused?
          policy_caused ? true : false
        end

        def cap_exceeded?
          cap_exceeded ? true : false
        end

        def to_h
          { 'url' => url, 'usage' => usage.to_s, 'classification' => classification.to_s,
            'reason' => reason, 'policy_caused' => policy_caused?,
            'cap_exceeded' => cap_exceeded? }.freeze
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
