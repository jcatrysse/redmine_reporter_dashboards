# frozen_string_literal: true

require_relative 'capabilities'
require_relative 'document_request'
require_relative 'failure'
require_relative 'result'

module RedmineReporterDashboards
  module Render
    # THE SEAM. `Assets::Resolution` in, `DocumentRequest` or `Failure` out.
    #
    # --- WHY THIS FILE IS IN `render/` AND THE RESOLVER IS NOT ---
    #
    # F-13b, decided: the resolver holds the network, and `render/**` may not (mechanism
    # E3, which is INV-8 in executable form — see `assets.rb`). But `DocumentRequest` and
    # `Failure` are render types, and something has to build them from a resolution. That
    # something does no resolving, opens no socket and reads no file; it maps one value
    # object onto two others. So it lives here, where the types it constructs live, and the
    # gate is satisfied by fact rather than by exemption: nothing in this file names
    # `Net::HTTP`, `Rails`, `ActiveRecord`, `Liquid` or `Issue`.
    #
    # §1.1's tree wanted `render/asset_resolver.rb`. What belongs at that address is this —
    # the render layer's statement of *how a resolution becomes its input*. The machinery
    # sits upstream, and `document_request.rb`'s own comment is why: `body` is "a COMPLETE,
    # already-asset-resolved document", so by the time anything here runs, resolution is
    # over.
    #
    # --- A REFUSAL IS A `Failure`, NEVER A BLANK IMAGE ---
    #
    # T-33: "a third-party URL under `:bundled` yields `Failure(:asset_unresolved)` **naming
    # the URL**, not a blank image". Naming it is the whole requirement: a report with a
    # silently missing logo is one a reader cannot tell from a report that never had one,
    # and if that report is an audit record the difference matters (INV-4). `message` is
    # user-facing and therefore carries the URLs and nothing else — no exception class, no
    # file path, no policy internals. `detail` is for the diagnostics view and carries the
    # per-reference reasons.
    module AssetBinding
      # More than this in one message is noise; the rest are in `detail`.
      MAX_NAMED_URLS = 5

      class << self
        # `resolution` is an `Assets::Resolution`. Everything else is `DocumentRequest`'s
        # own vocabulary and is passed through untouched — this method adds exactly two
        # things to it, `body` and `assets`, plus the capability requirement that carrying
        # request-borne bytes implies.
        def apply(resolution:, correlation_id:, engine: nil, **request_args)
          return failure_for(resolution, correlation_id, engine) if resolution.refused?

          DocumentRequest.new(
            body: resolution.body,
            assets: resolution.assets,
            correlation_id: correlation_id,
            **merge_capabilities(resolution, request_args)
          )
        end

        # The degradations a resolution recorded, in the render layer's vocabulary, so an
        # adapter's `Success` can carry them alongside its own. `Assets` speaks in plain
        # Hashes precisely so it does not have to name this class (see `assets.rb`), and
        # this is the one place that translation happens.
        def degradations(resolution)
          resolution.degradations.map do |entry|
            Degradation.new(capability: entry[:code] || entry['code'],
                            detail: entry[:detail] || entry['detail'])
          end
        end

        private

        # UPLOAD IS ESSENTIAL WHEN IT IS USED, and that is not circular reasoning even
        # though the resolver only chose upload because the engine declared it. The
        # resolution and the render can be separated in time — a queued report, a retry
        # after an engine switch, a preview rendered on one engine and a document on
        # another — and an engine that cannot read request-borne bytes would draw a
        # document with every uploaded asset missing. Declaring it essential turns that
        # into a refusal that names the capability instead.
        def merge_capabilities(resolution, request_args)
          return request_args if resolution.assets.empty?

          required = Array(request_args[:required_capabilities]) | [:asset_upload]
          essential = Array(request_args[:essential_capabilities]) | [:asset_upload]
          request_args.merge(required_capabilities: required, essential_capabilities: essential)
        end

        def failure_for(resolution, correlation_id, engine)
          urls = resolution.refused_urls
          named = urls.first(MAX_NAMED_URLS)
          remainder = urls.length - named.length

          Failure.new(
            code: :asset_unresolved,
            message: message_for(named, remainder),
            correlation_id: correlation_id,
            engine: engine,
            detail: resolution.refusals.map(&:to_h)
          )
        end

        def message_for(named, remainder)
          list = named.join(', ')
          tail = remainder.positive? ? " (and #{remainder} more)" : ''
          if named.length == 1
            "This report references an asset that cannot be resolved without fetching it " \
              "over the network, which the current asset policy does not permit: #{list}."
          else
            "This report references #{named.length} assets that cannot be resolved without " \
              "fetching them over the network, which the current asset policy does not " \
              "permit: #{list}#{tail}."
          end
        end
      end
    end
  end
end
