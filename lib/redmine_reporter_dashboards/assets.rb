# frozen_string_literal: true

module RedmineReporterDashboards
  # The asset layer — three models, one policy (technical-spec.md §5.1, FR-63…FR-66).
  #
  # --- WHY IT IS HERE AND NOT UNDER `render/` — F-13b, DECIDED ---
  #
  # §1.1's tree puts `asset_resolver.rb` under `render/`. It cannot go there, and the
  # reason is not a gate technicality:
  #
  #   * §5.1 requires that "resolution happens **in the plugin, never in the engine**:
  #     the plugin fetches, validates and hands over bytes via `:asset_upload`". So the
  #     resolver is the thing that HOLDS THE NETWORK.
  #   * `render/document_request.rb` says `body` is "a COMPLETE, already-asset-resolved
  #     document precisely so the engine never fetches anything on the viewer's behalf".
  #     By the render layer's own contract, resolution has already happened by the time
  #     anything in `render/` runs.
  #   * mechanism E3 (`script/gates/layer_purity.sh`) therefore forbids `render/**` from
  #     naming `Net::HTTP`, `Faraday`, `cookie` and `session` — the four things a fetcher
  #     is made of. The gate is not disagreeing with §5.1; it is §5.1 in executable form.
  #
  # A fetcher inside `render/` would contradict INV-8 — *the renderer is never the thing
  # holding the network* — which is the invariant that directory exists to protect. So
  # the resolver sits UPSTREAM of the render layer, in a namespace that names neither
  # layer, exactly as `Charts` does (F-13). The tree in §1.1 has been corrected rather
  # than worked around, and `layer_purity.sh` now has an arm for this directory so
  # "neutral namespace" is enforced instead of merely asserted.
  #
  # --- TWO THINGS CALLED `assets/`, AND THEY ARE DIFFERENT ---
  #
  #   assets/                              the plugin's STATIC files, mirrored by Redmine
  #                                        to public/plugin_assets/ and read off disk here
  #   lib/redmine_reporter_dashboards/assets/   this Ruby layer
  #
  # `BundledAssets::ROOT` is the bridge between them, and it is the only place the second
  # knows about the first.
  #
  # --- THE SHAPE, IN ONE PARAGRAPH ---
  #
  #   Policy          three values, `:bundled` by default; an empty allowlist collapses
  #                   any upgraded mode back to `:bundled` — misconfiguration fails closed
  #   DocumentScanner one pass over the document, finding every subresource reference
  #   LocalStore      a URL path -> a file on disk, traversal-proof, content-typed
  #   Fetcher         the ONLY egress in this plugin: https-only, anonymous, capped,
  #                   redirect-free, and IP-checked AFTER resolution
  #   Resolver        per reference, the MOST RESTRICTIVE model the engine declares
  #   Resolution      body + named asset bytes + degradations + refusals
  #
  # `Render::AssetBinding` is what turns a `Resolution` into a `DocumentRequest` or a
  # `Failure(:asset_unresolved)`. It lives in `render/` because both of those are render
  # types and it does no resolving — it is the seam, not the machinery.
  module Assets
    # `:asset_http` is IN the capability vocabulary and is NEVER SELECTED by the
    # resolver. That is the inversion §5.1 calls "the single thing that keeps INV-8
    # true": where a fetch is permitted at all, the PLUGIN fetches and hands the engine
    # bytes, so the engine's own name resolution stays denied in every mode. The
    # capability remains expressible because an engine may still declare it and an
    # operator may still need to read that it exists — `spec/assets/resolver_spec.rb`
    # asserts it is never chosen, including against an engine that declares all three.
    MODELS = %i[inline upload].freeze
  end
end

require_relative 'assets/content_types'
require_relative 'assets/policy'
require_relative 'assets/origin'
require_relative 'assets/reference'
require_relative 'assets/bundled_assets'
require_relative 'assets/local_store'
require_relative 'assets/fetcher'
require_relative 'assets/document_scanner'
require_relative 'assets/resolution'
require_relative 'assets/resolver'
