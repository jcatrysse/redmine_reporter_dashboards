# frozen_string_literal: true

require 'digest'

module RedmineReporterDashboards
  module Assets
    # ONE WALK, and per reference the MOST RESTRICTIVE MODEL THE ENGINE DECLARES (§5.1,
    # FR-63).
    #
    #   inline  no egress, one self-contained document          most restrictive
    #   upload  no egress, bytes travel in the request
    #   fetch   the ENGINE resolves the URL itself               never selected — see below
    #
    # --- `:asset_http` IS NEVER SELECTED, AND THAT IS STRONGER THAN THE SPEC ASKS ---
    #
    # T-33's acceptance list asks that "`:asset_http` is proven **off** in `:external` mode
    # wherever the engine supports `:asset_upload`". This resolver never selects it in ANY
    # mode, for any engine, whatever it declares — because §5.1's inversion has no
    # exception worth carving: *"Resolution happens in the plugin, never in the engine: the
    # plugin fetches, validates and hands over bytes via `:asset_upload`. That single
    # inversion is what keeps INV-8 true — the renderer is never the thing holding the
    # network."* Where a fetch is permitted, THIS process performs it, under the
    # `Fetcher`'s caps, and the engine receives bytes.
    #
    # The capability stays in the vocabulary because an engine may still declare it and an
    # operator still has to be able to read that the model exists. `spec/assets/resolver_spec.rb`
    # asserts it is never chosen, including against a capability set declaring all three
    # models in `:external` mode, which is the case that would otherwise pick it.
    #
    # --- AN AUTHOR CANNOT REACH THIS OBJECT ---
    #
    # Policy, capabilities, store and fetcher are all constructor arguments. There is no
    # register, no Liquid variable, no tag parameter and no document syntax that changes
    # any of them, which is T-33's "a test asserts an author **cannot** widen egress from
    # template content" — asserted by driving a document that tries every shape: a
    # `<meta>` directive, an `asset_policy` comment, and a reference whose own query string
    # says `?asset_policy=external`.
    #
    # --- INLINING IS A `data:` URI EXCEPT WHERE §5.1 NAMES THE BODY ---
    #
    # §5.1: "CSS, JS and SVG inlined into the single document body". For `<link
    # rel=stylesheet>` and `<script src>` that is done structurally — the element is
    # REPLACED by a `<style>` or `<script>` block — because a `<style>` block is the form
    # every engine accepts, including the 2011 WebKit in the compatibility adapter, and
    # because a `data:` stylesheet is the one thing there that could plausibly differ.
    #
    # Structural inlining has a hazard a `data:` URI does not: bytes containing `</style`
    # or `</script` would CLOSE THE BLOCK EARLY and everything after them would be parsed
    # as markup. That is an injection, not a rendering bug. So the terminator is checked,
    # and a file containing one falls back to a `data:` URI — where it cannot break out,
    # because base64 contains no `<`. Both paths are tested with a payload that carries the
    # terminator.
    class Resolver
      # In order of restrictiveness, which is the order the choice is made in.
      INLINE = :inline
      UPLOAD = :upload

      DEGRADATIONS = {
        asset_inline_oversize:
          'inlined above inline_max_bytes because the engine declares no upload model',
        asset_srcset_collapsed:
          'srcset alternatives dropped — a PDF page has one pixel density',
        asset_structural_fallback:
          'inlined as a data: URI rather than into the body: the bytes contain the ' \
          'element terminator, and inlining them structurally would close the block early',
        asset_none: 'the document referenced nothing that had to be resolved'
      }.freeze

      attr_reader :policy, :engine_capabilities

      def initialize(policy:, local_store:, engine_capabilities:, fetcher: nil,
                     origin: Origin.new, logger: nil)
        @policy = policy
        @local_store = local_store
        @engine_capabilities = Array(engine_capabilities).map(&:to_sym).freeze
        @fetcher = fetcher
        @origin = origin
        @logger = logger
      end

      def inline?
        @engine_capabilities.include?(:asset_inline)
      end

      def upload?
        @engine_capabilities.include?(:asset_upload)
      end

      # The whole interface. Returns a `Resolution`; never raises for anything a document
      # or a network can do.
      def call(html)
        document = normalize_encoding(html)
        # The probe is what `structural_text` compares an asset's text against. Held for the
        # duration of one walk rather than passed through five frames.
        @document_encoding_probe = document
        references = DocumentScanner.scan(document, origin: @origin)
        state = State.new

        references.each { |reference| resolve_one(reference, state) }

        Resolution.new(
          body: splice(document, state.replacements),
          assets: state.assets.freeze,
          degradations: state.degradations,
          refusals: state.refusals,
          models_used: state.models_used,
          counts: state.counts
        )
      end

      private

      # NAME THE DOCUMENT'S ENCODING ONCE, at the entry point. HANDOVER §1: "anything crossing
      # into this process from a file or a pipe gets its encoding named" — and a report body has
      # crossed at least one of those. A body that is US-ASCII-tagged but actually UTF-8 (the
      # `File.read` with no `encoding:` on a host with no `LANG`) is relabelled here, so the
      # spans, the splice and every comparison downstream agree about what a character is.
      #
      # A body that is genuinely not UTF-8 is left exactly as it arrived. Re-encoding it would
      # change report content to make this layer's life easier, which is the wrong trade; the
      # compatibility check in `structural_text` then keeps the splice safe.
      def normalize_encoding(html)
        text = html.to_s.dup
        return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

        candidate = text.dup.force_encoding(Encoding::UTF_8)
        candidate.valid_encoding? ? candidate : text
      end

      # Mutable accumulator for one walk. A local class rather than six ivars, so `call`
      # is re-entrant: a memoised ivar on the resolver would leak one document's assets
      # into the next, and a resolver is exactly the kind of object somebody will reuse.
      class State
        attr_reader :replacements, :assets, :degradations, :refusals, :models_used, :counts,
                    :encoded

        def initialize
          @replacements = []
          @assets = {}
          @degradations = []
          @refusals = []
          @models_used = []
          @counts = { passthrough: 0, inlined: 0, uploaded: 0, fetched: 0, refused: 0 }
          @encoded = {}
        end

        def replace(span, text)
          @replacements << [span.first, span.last, text]
        end

        def degrade(code, detail: nil, data: {})
          @degradations << { code: code, detail: detail || DEGRADATIONS[code], data: data }
        end

        def refuse(reference, reason)
          @refusals << Resolution::Refusal.new(
            url: reference.display, usage: reference.usage,
            classification: reference.classification, reason: reason
          )
          @counts[:refused] += 1
        end

        def count(key)
          @counts[key] += 1
        end

        def used(model)
          @models_used << model
        end
      end

      def resolve_one(reference, state)
        if reference.passthrough?
          state.count(:passthrough)
          return
        end

        if reference.candidates > 1
          state.degrade(:asset_srcset_collapsed, data: { 'url' => reference.display,
                                                         'dropped' => reference.candidates - 1 })
        end

        payload = obtain(reference, state)
        return if payload.nil?

        embed(reference, payload, state)
      end

      # `[bytes, content_type]` or nil, having already recorded the refusal.
      def obtain(reference, state)
        case reference.classification
        when :unresolvable
          state.refuse(reference,
                       'is not resolvable: a render has no document URL, so a relative ' \
                       'reference has no base and an unsupported scheme has no handler')
          nil
        when :local_path, :same_origin
          file = @local_store.file_for(reference.path, usage: reference.usage)
          next_step = file.nil?
          # THE REASON IS READ IMMEDIATELY, and passed along rather than asked for later.
          # `LocalStore#reason_text` describes its LAST lookup, so a caller that asks for
          # it two calls further on gets a truthful-looking answer about the wrong file.
          # Making it an argument turns a temporal coupling into a visible one.
          next_step ? fetched(reference, state, local_reason: @local_store.reason_text)
                    : [file.bytes, file.content_type]
        when :third_party
          fetched(reference, state)
        end
      end

      def fetched(reference, state, local_reason: nil)
        # THE `:bundled` ROW, and the order matters. A same-origin reference that is on
        # disk was already answered above; reaching here means it is not, and under
        # `:bundled` there is no second chance — "never fetched", in §5.1's words.
        unless policy.fetch_allowed?(reference.fetch_classification, reference.host)
          state.refuse(reference, refusal_reason(reference, local_reason))
          return nil
        end

        if @fetcher.nil?
          state.refuse(reference,
                       'would need a fetch and no fetcher was supplied to the resolver')
          return nil
        end

        result = @fetcher.fetch(reference)
        # POSITIVE check. `unless Refusal` would treat anything unexpected a fetcher
        # returned — nil, a bare String, a double somebody wrote in a hurry — as bytes, and
        # this is the one place in the layer where a wrong answer becomes document content.
        unless result.is_a?(Fetcher::Fetched)
          state.refuse(reference, result.respond_to?(:reason) ? result.reason : 'could not be fetched')
          return nil
        end

        state.count(:fetched)
        [result.bytes, result.content_type]
      end

      # Why THIS reference was refused, in the words an operator can act on. The three
      # cases read very differently and collapsing them into "asset unresolved" is what
      # makes a diagnostics page useless.
      def refusal_reason(reference, local_reason = nil)
        # THE LOCAL REASON LEADS, when there is one. A `.css` referenced by an `<img>`
        # resolves on disk perfectly well; saying "does not resolve to a file on disk"
        # first would send an operator looking for a missing file that is right there.
        if local_reason
          return "#{local_reason}, and asset_policy #{policy.effective_mode} does not fetch " \
                 'as a second attempt'
        end
        if policy.bundled? && reference.fetch_classification == :same_origin
          return 'is a URL on this install that does not resolve to a file on disk, and ' \
                 'asset_policy is bundled, which never fetches'
        end
        if policy.collapsed?
          return "would need a fetch, and asset_allowlist is empty — asset_policy " \
                 "#{policy.mode} therefore behaves as bundled (§5.1: misconfiguration " \
                 'fails closed)'
        end
        if policy.may_fetch?(reference.fetch_classification)
          return "host is not in asset_allowlist (#{reference.host})"
        end

        "asset_policy #{policy.effective_mode} does not fetch #{reference.fetch_classification} " \
          'references'
      end

      # THE MODEL CHOICE. Inline first, because it is the most restrictive: one document,
      # no request-borne bytes, nothing for a caller to forget to pass on.
      def embed(reference, payload, state)
        bytes, content_type = payload
        size = bytes.bytesize

        if size > policy.asset_max_bytes
          state.refuse(reference,
                       "is #{size} bytes, above the #{policy.asset_max_bytes}-byte " \
                       'asset_max_bytes cap')
          return
        end

        if inline? && size <= policy.inline_max_bytes
          inline!(reference, bytes, content_type, state)
        elsif upload?
          upload!(reference, bytes, content_type, state)
        elsif inline?
          # Over the threshold and the engine cannot take request-borne bytes. The
          # threshold is a COST decision (base64 growth versus a round trip) and the cap is
          # the safety one, so the right answer here is to pay the cost and say so.
          state.degrade(:asset_inline_oversize,
                        data: { 'url' => reference.display, 'bytes' => size })
          inline!(reference, bytes, content_type, state)
        else
          state.refuse(reference,
                       'cannot be embedded: the engine declares neither :asset_inline nor ' \
                       ':asset_upload, so there is no way to give it these bytes without ' \
                       'putting it on the network')
        end
      end

      def inline!(reference, bytes, content_type, state)
        state.count(:inlined)
        state.used(INLINE)

        structural = structural_text(reference, bytes, content_type, state)
        if structural
          state.replace(reference.element_span, structural)
        else
          state.replace(reference.span, data_uri(bytes, content_type, state))
        end
      end

      # nil when there is no structural form, or when the bytes make one unsafe.
      def structural_text(reference, bytes, content_type, state)
        span = reference.element_span
        return nil if span.nil? || span.first.nil? || span.last.nil?

        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return nil unless text.valid_encoding?
        # THE ENCODING HAZARD HANDOVER §1 RECORDS TWICE, in its second and least obvious form.
        # A document that reached here as US-ASCII (a `File.read` with no `encoding:` on a host
        # with no `LANG`, or `Open3.capture3` output) cannot receive a UTF-8 insert: the splice
        # raises `Encoding::CompatibilityError` from a line that does no reading, which reads as
        # a bug in the wrong file. A `data:` URI is pure ASCII and always compatible, so an
        # incompatible pair falls back to one rather than raising.
        return fallback(reference, state) unless Encoding.compatible?(@document_encoding_probe, text)

        case reference.usage
        when :stylesheet
          return fallback(reference, state) if terminator?(text, 'style')

          "<style>\n#{text}\n</style>"
        when :script
          return fallback(reference, state) if terminator?(text, 'script') || text.include?('<!--')

          "<script>\n#{text}\n</script>"
        end
      end

      def fallback(reference, state)
        state.degrade(:asset_structural_fallback, data: { 'url' => reference.display })
        nil
      end

      # `</style`, `</ style`, `</STYLE` — the forms an HTML parser accepts as a close.
      def terminator?(text, name)
        text.match?(/<\s*\/\s*#{name}/i)
      end

      def upload!(reference, bytes, content_type, state)
        name = asset_name(bytes, content_type)
        state.assets[name] ||= { 'bytes' => bytes, 'content_type' => content_type }.freeze
        state.count(:uploaded)
        state.used(UPLOAD)
        # The engine serves `request.assets` from memory under a path it controls, so the
        # document refers to the NAME. A relative reference is correct here and nowhere
        # else in this layer: the engine's interceptor is the base.
        state.replace(reference.span, name)
      end

      # CONTENT-ADDRESSED, so a logo referenced twenty times is carried once and the
      # twenty references agree. `Digest::SHA256`, not MD5 — CLAUDE.md §5 forbids MD5 for
      # anything security-bearing and an asset name is a lookup key an author can
      # influence, which is close enough to want collision resistance.
      def asset_name(bytes, content_type)
        digest = Digest::SHA256.hexdigest(bytes)[0, 32]
        extension = ContentTypes::BY_EXTENSION.key(ContentTypes.normalize(content_type))
        "rrd-asset-#{digest}#{extension}"
      end

      # `[bytes].pack('m0')` rather than `Base64.strict_encode64`: `base64` left Ruby's
      # default gems in 3.4, and this layer has to load in a bare RSpec process on four
      # Ruby versions (mechanism E2). One less thing to be absent.
      # Memoised BY THE BYTES, not by their `hash`. A Hash keyed on `String#hash` would
      # answer the wrong data URI on a collision, silently — and "silently wrong bytes in
      # a document" is the one failure mode this whole layer exists to remove.
      def data_uri(bytes, content_type, state)
        state.encoded[bytes] ||= "data:#{content_type};base64,#{[bytes].pack('m0')}"
      end

      # ONE SPLICE, right to left, so every recorded span still refers to the ORIGINAL
      # offsets when it is applied. Left to right would invalidate every span after the
      # first replacement, and the symptom would be a document that is subtly shredded
      # rather than one that obviously fails.
      def splice(html, replacements)
        return html.dup if replacements.empty?

        ordered = replacements.sort_by { |start, length, _| [-start, -length] }
        assert_disjoint!(ordered)

        out = html.dup
        ordered.each { |start, length, text| out[start, length] = text }
        out
      end

      # Two replacements over the same bytes would make the output depend on their order,
      # which is a defect in this file rather than in the document. Loud, because a silent
      # one produces plausible output.
      def assert_disjoint!(ordered)
        ordered.each_cons(2) do |(later_start, _, _), (earlier_start, earlier_length, _)|
          next if earlier_start + earlier_length <= later_start

          raise ArgumentError,
                "overlapping asset replacements at #{earlier_start} and #{later_start}: " \
                'the scanner produced two spans over the same bytes, which is a bug in ' \
                'DocumentScanner rather than in the document.'
        end
      end
    end
  end
end
