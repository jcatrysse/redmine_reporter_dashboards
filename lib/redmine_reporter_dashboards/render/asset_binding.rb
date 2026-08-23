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

        # THE CAP IS A SIZE PROBLEM, NOT A RESOLUTION PROBLEM, and saying otherwise sent the
        # reader after the wrong thing. A document past `MAX_REFERENCES` used to produce
        # `Failure(:asset_unresolved)` listing URLs that "could not be resolved" — true of
        # the mechanism and false as an explanation: nothing is wrong with those URLs, each
        # would resolve on its own, and the remedy is not to fix them but to reference
        # fewer. Curator decision, 2026-08-10 (§Findings E-26 #4): the reader is told the
        # report is too big.
        #
        # `:resource_limit` is the same code the run-level byte budget answers with, which
        # is the point — a report refused for being too large says so with one vocabulary,
        # whether the limit it hit counts references or bytes.
        #
        # ANY cap refusal decides this, not "every refusal is one": past the cap, EVERY
        # remaining reference is refused for that reason, so a document that also has a
        # genuine third-party URL would otherwise report whichever cause happened to sort
        # first. The size problem is the one that has to be fixed before the other is even
        # visible.
        def failure_for(resolution, correlation_id, engine)
          if resolution.refusals.any?(&:cap_exceeded?)
            return Failure.new(
              code: :resource_limit,
              message: cap_message(resolution),
              correlation_id: correlation_id,
              engine: engine,
              detail: resolution.refusals.map(&:to_h)
            )
          end

          Failure.new(
            code: :asset_unresolved,
            message: message_for(resolution),
            correlation_id: correlation_id,
            engine: engine,
            detail: resolution.refusals.map(&:to_h)
          )
        end

        # NAMES BOTH NUMBERS, like every other limit message in this plugin — how many the
        # report asked for, and how many one document may hold. It does NOT list the URLs:
        # there are at least five hundred of them, and a message that names five and says
        # "and 900 more" tells the reader nothing they can act on.
        def cap_message(resolution)
          refused = resolution.refusals.count(&:cap_exceeded?)
          "This report is too big: it refers to more files than one document can embed. " \
            "#{refused} reference#{'s' if refused != 1} past the limit " \
            "#{refused == 1 ? 'was' : 'were'} not resolved. Reference fewer files, or " \
            'split the report.'
        end

        # THE CAUSE IS NOT ALWAYS THE POLICY, and the first version said it was.
        #
        # It emitted one fixed sentence — "cannot be resolved without fetching it over the
        # network, which the current asset policy does not permit" — for every refusal. That is
        # false for most of them, and for two it is actively misleading: a RELATIVE reference is
        # refused before the policy is consulted at all, and an oversize or wrongly-typed asset
        # is refused with the widest policy this plugin permits. An administrator told "the asset
        # policy does not permit it" would go and enable egress, and the report would still fail.
        # A remedy that provably does nothing is worse than no remedy (INV-4).
        #
        # So the causal sentence is used only when every refusal really is a policy one. Otherwise
        # the message names the URLs and NO cause, and sends the reader to the diagnostics view.
        #
        # It does NOT relay `Resolution::Refusal#reason` — and the first attempt at this fix did,
        # which the suite caught. Those reasons are correct and are for an operator: one of them
        # is `Fetcher`'s `:transport` reason, which carries an exception class and message
        # verbatim. `Failure#message` is user-facing and "must never carry a raw exception", so
        # relaying them traded a false cause for an information leak. The reasons live in
        # `detail`, which is where FR-58's diagnostics view reads from.
        POLICY_CLASSIFICATIONS = %i[same_origin third_party local_path].freeze

        def message_for(resolution)
          urls = resolution.refused_urls
          named = urls.first(MAX_NAMED_URLS)
          remainder = urls.length - named.length
          tail = remainder.positive? ? " (and #{remainder} more)" : ''
          subject = urls.length == 1 ? 'an asset' : "#{urls.length} assets"
          list = "#{named.join(', ')}#{tail}"

          if resolution.refusals.all? { |refusal| policy_refusal?(refusal) }
            return "This report references #{subject} that cannot be resolved without fetching " \
                   "them over the network, which the current asset policy does not permit: #{list}."
          end

          # IT USED TO SAY "the reason for each is in the render diagnostics for this
          # correlation id", and that is a pointer to a page which deliberately does not
          # show it: `_diagnostics.html.erb`'s own comment says `Diagnostic#detail` is NOT
          # printed, and the per-refusal reasons live in exactly that field. So the reader
          # followed the sentence to the panel they were already looking at and found a
          # code and an id. A remedy that provably does nothing is worse than none (INV-4)
          # — the same rule that had already been broken one method down.
          #
          # It now says where the reasons actually are, and names the one person who can
          # read them. Rendering `Resolution::Refusal#to_h` in the panel is the better fix
          # and is §Findings E-26 #7; this is the honest sentence until somebody builds it.
          "This report references #{subject} that could not be resolved: #{list}. An " \
            'administrator can find the reason for each in the application log, under this ' \
            'correlation id.'
        end

        # A refusal the asset policy is genuinely responsible for — ASKED AS DATA, and the
        # previous version asked it as prose and was wrong for five of the seven causes.
        #
        # It read `refusal.reason.include?('asset_policy')`. `Resolver#refusal_reason`
        # APPENDS `policy_reason` to every refusal it composes, so the guard matched a
        # missing file, a wrongly-typed file and an attachment the viewer may not see —
        # each of which was then told the remedy is to enable network egress, which cannot
        # fix any of them and does open the network. Exactly the outcome the long comment
        # above says this method exists to prevent. Measured end to end by an independent
        # QA pass; the spec that appeared to cover it hand-wrote a reason string the
        # resolver never emits, so it discriminated nothing.
        #
        # `Resolution::Refusal#policy_caused?` is set by the resolver at the point the
        # decision is taken, defaults to false, and is the only thing consulted here. The
        # classification check stays: it is about which references CAN be policy-refused at
        # all, which is a different question and still worth asking.
        def policy_refusal?(refusal)
          return false unless POLICY_CLASSIFICATIONS.include?(refusal.classification)

          refusal.policy_caused?
        end
      end
    end
  end
end
