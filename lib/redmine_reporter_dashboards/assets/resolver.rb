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
          'inlined as a data: URI rather than into the body: inlining it structurally ' \
          'would either close the block early or change what the element means',
        asset_nested_depth:
          'a stylesheet imported another one past the nesting cap; the deepest import ' \
          'was not resolved',
        asset_document_cap:
          'the document referenced more assets than max_references, and the rest were ' \
          'not resolved',
        asset_none: 'the document referenced nothing that had to be resolved'
      }.freeze

      # DOCUMENT-LEVEL BOUNDS, and they are constants rather than settings for the same reason
      # the fetcher's timeouts are: each is a safety property, and a setting is a thing an
      # operator can be talked into raising. §5.1 caps a single asset (`asset_max_bytes`) and
      # says nothing about a document; a template with 5 000 `<img>` tags therefore had no bound
      # at all, which is the "no unbounded output" half of G6.
      #
      # `MAX_REFERENCES` is generous — a 2 000-row report with a chart per section is nowhere
      # near it — and past it the remaining references are REFUSED rather than passed through, so
      # the overflow cannot become egress.
      MAX_REFERENCES = 500

      # The aggregate embedded size. Twenty 7 MiB images each pass `asset_max_bytes` and together
      # make a 140 MiB document that no engine will draw and no mail server will carry.
      MAX_TOTAL_BYTES = 32 * 1024 * 1024

      # `@import` chains. Three is more than any real stylesheet and bounds the recursion so a
      # circular import is a degradation rather than a stack overflow.
      MAX_CSS_DEPTH = 3

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
        references = suppress_nested_element_spans(DocumentScanner.scan(document, origin: @origin))
        state = State.new

        references.each do |reference|
          # `references_exhausted?` and not `index >=`: the budget is spent by nested
          # stylesheet references too, so a document whose first `<link>` used the whole
          # allowance must not then resolve 500 more of its own. See `State#spend_reference`.
          if state.references_exhausted?
            state.refuse(reference,
                         "is past the #{MAX_REFERENCES}-reference cap for one document and was " \
                         'not resolved')
            next
          end

          state.spend_reference
          resolve_one(reference, state)
        end
        if references.length > MAX_REFERENCES
          state.degrade(:asset_document_cap,
                        data: { 'references' => references.length, 'cap' => MAX_REFERENCES })
        end

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

      # A STRUCTURAL REWRITE REPLACES A WHOLE ELEMENT, so it cannot be used when another
      # reference lives inside that element — and one legitimately can:
      #
      #     <link rel="stylesheet" href="/a.css" style="background:url(/logo.png)">
      #
      # Two references, disjoint VALUE spans (the scanner keeps its promise), but the `url()`
      # span sits inside the `<link>`'s element span. The first version noticed that only at
      # splice time and RAISED `ArgumentError` out of a method documented never to raise, from a
      # perfectly ordinary document. Found by the review's own repro, not by reading.
      #
      # Suppressing the element span downgrades that one reference to an attribute rewrite — a
      # `data:` URI — and both then splice cleanly. `assert_disjoint!` stays as a last-resort
      # assertion about this file's own arithmetic, which is what it should always have been.
      def suppress_nested_element_spans(references)
        spans = references.map(&:span)

        references.map do |reference|
          element = reference.element_span
          next reference if element.nil? || element.first.nil? || element.last.nil?

          from = element.first
          to = element.first + element.last
          nested = spans.any? do |start, length|
            next false if start == reference.span.first && length == reference.span.last

            start >= from && start + length <= to
          end
          next reference unless nested

          Reference.new(raw: reference.raw, usage: reference.usage, span: reference.span,
                        origin: reference.origin, element_span: nil,
                        candidates: reference.candidates,
                        element_attributes: reference.element_attributes)
        end
      end

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
                    :encoded, :embedded_bytes

        def initialize
          @replacements = []
          @assets = {}
          @degradations = []
          @refusals = []
          @models_used = []
          @counts = { passthrough: 0, inlined: 0, uploaded: 0, fetched: 0, refused: 0 }
          @encoded = {}
          @embedded_bytes = 0
          @references_spent = 0
        end

        # THE REFERENCE CAP IS A BUDGET FOR THE WHOLE WALK, not a bound on the document's
        # own reference list — and it was the second of those, which left a hole.
        #
        # `MAX_REFERENCES` was applied only to `DocumentScanner.scan`'s results in `call`.
        # `resolve_stylesheet` recursed with NO cap at all, and a stylesheet is document
        # content: an author attaches a CSS file and references it, so `<link>` costs one
        # reference and the file behind it costs as many as it likes. Measured by an
        # independent QA pass — 3 200 inner references produced 3 201 inlines in 11 s,
        # strictly linear at ~3.5 ms each, one `Attachment.find_by` AND one `File.binread`
        # apiece, with no memoisation. An 8 MB stylesheet of `url()` rules is ~200 000
        # references, and `bind_assets` repeats the whole thing per document.
        #
        # Counting spends rather than positions closes it, because a nested reference and a
        # top-level one now draw on the same budget. The output was already bounded — the
        # spliced CSS eventually trips `asset_max_bytes` — so what this bounds is the WORK,
        # which is the half a size cap cannot see.
        def spend_reference
          @references_spent += 1
        end

        def references_exhausted?
          @references_spent >= MAX_REFERENCES
        end

        attr_reader :references_spent

        def embed_bytes(size)
          @embedded_bytes += size
        end

        def replace(span, text)
          @replacements << [span.first, span.last, text]
        end

        def degrade(code, detail: nil, data: {})
          @degradations << { code: code, detail: detail || DEGRADATIONS[code], data: data }
        end

        # `policy_caused` DEFAULTS TO FALSE so that adding a refusal site cannot silently
        # start blaming the asset policy — the direction that matters, because that is the
        # answer which sends an administrator to enable egress.
        def refuse(reference, reason, policy_caused: false)
          @refusals << Resolution::Refusal.new(
            url: reference.display, usage: reference.usage,
            classification: reference.classification, reason: reason,
            policy_caused: policy_caused
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

        # A STYLESHEET IS A DOCUMENT, and this is the hole the review found. CSS carries its own
        # subresources — `url()` and `@import` — and embedding a stylesheet verbatim hands every
        # one of them to the engine as a live URL. Under `:bundled` that is egress the policy
        # exists to refuse; under `:external` it lets one allowlisted host choose arbitrary
        # further egress, which is a complete allowlist bypass. So CSS is resolved BEFORE it is
        # embedded, by the same rules, to a bounded depth.
        #
        # JavaScript is deliberately NOT treated this way, and the difference is real rather
        # than convenient: a URL in a program is a string, not a subresource, and a script can
        # always mint one at runtime. No scanner can close that; only the engine's own egress
        # denial can, which is why INV-8 keeps `--host-resolver-rules` on the browser and why
        # conformance fixture `F-15-egress-denial` exists. Rewriting URLs inside JS would
        # corrupt programs while closing nothing.
        if reference.usage == :stylesheet
          payload = resolve_stylesheet(payload, reference, state, 1)
          return if payload.nil?
        end

        embed(reference, payload, state)
      end

      # `[bytes, content_type]` with every reference inside the CSS resolved, or nil if
      # something in it was refused — a refusal inside a stylesheet fails the whole document
      # closed, naming the inner URL, exactly as one in the document body does.
      def resolve_stylesheet(payload, reference, state, depth)
        bytes, content_type = payload
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return payload unless text.valid_encoding?

        if depth > MAX_CSS_DEPTH
          state.degrade(:asset_nested_depth, data: { 'url' => reference.display, 'depth' => depth })
          return payload
        end

        inner = DocumentScanner.scan_css_text(text, origin: @origin)
        return payload if inner.empty?

        replacements = []
        inner.each do |nested|
          next state.count(:passthrough) if nested.passthrough?

          # THE SAME BUDGET AS THE DOCUMENT'S OWN REFERENCES. Refusing rather than
          # degrading, and returning nil rather than continuing, because a stylesheet that
          # is only half resolved would embed the rest of its `url()`s as LIVE URLs — the
          # egress this method exists to close (the review of T-33 called that its worst
          # finding). A refusal inside a stylesheet already fails the document closed;
          # running out of budget is one more way to be inside one.
          if state.references_exhausted?
            state.refuse(nested,
                         "is past the #{MAX_REFERENCES}-reference cap for one document and was " \
                         'not resolved')
            return nil
          end

          state.spend_reference
          nested_payload = obtain(nested, state)
          return nil if nested_payload.nil?

          if nested.usage == :stylesheet
            nested_payload = resolve_stylesheet(nested_payload, nested, state, depth + 1)
            return nil if nested_payload.nil?
          end

          nested_bytes, nested_type = nested_payload
          if nested_bytes.bytesize > policy.asset_max_bytes
            state.refuse(nested, "is #{nested_bytes.bytesize} bytes, above the " \
                                 "#{policy.asset_max_bytes}-byte asset_max_bytes cap")
            return nil
          end

          state.count(:inlined)
          state.used(INLINE)
          replacements << [nested.span.first, nested.span.last,
                           data_uri(nested_bytes, nested_type, state)]
        end

        [splice(text, replacements), content_type]
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
          file = @local_store.file_for(reference.path, usage: reference.usage,
                                       max_bytes: policy.asset_max_bytes)
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
          # THE POLICY IS THE CAUSE ONLY WHEN THE DISK HAD NOTHING TO SAY. A `local_reason`
          # means the reference named something on this install and `LocalStore` already
          # explained why it did not answer — the file is absent, the type is wrong for the
          # way the document uses it, the actor may not see the attachment. Widening the
          # policy fixes none of those, and an anonymous fetch (FR-65) cannot fetch an
          # attachment that needs a session at all. So the causal sentence is reserved for
          # the case where the ONLY thing standing in the way is the policy.
          state.refuse(reference, refusal_reason(reference, local_reason),
                       policy_caused: local_reason.nil?)
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
      # COMPOSED, not a chain of early returns. The first version returned a fixed sentence as
      # soon as a local reason existed, which swallowed the two things an operator most needs to
      # be told: that the allowlist is empty and the mode therefore collapsed, and which host is
      # missing from it. A refusal that names a mode the operator never configured — "asset_policy
      # bundled" when they set `:external` — is worse than no reason at all (INV-4).
      def refusal_reason(reference, local_reason = nil)
        parts = []
        # THE LOCAL REASON LEADS, when there is one. A `.css` referenced by an `<img>` resolves on
        # disk perfectly well; saying "does not resolve to a file on disk" first would send an
        # operator looking for a missing file that is right there.
        if local_reason
          parts << local_reason
        elsif policy.bundled? && reference.fetch_classification == :same_origin
          parts << 'is a URL on this install that does not resolve to a file on disk'
        end

        parts << policy_reason(reference)
        parts.join(', and ')
      end

      def policy_reason(reference)
        if policy.collapsed?
          return 'asset_allowlist is empty, so asset_policy ' \
                 "#{policy.mode} behaves as bundled and nothing is fetched " \
                 '(§5.1: misconfiguration fails closed)'
        end
        if policy.may_fetch?(reference.fetch_classification)
          return "the host is not in asset_allowlist (#{reference.host})"
        end

        "asset_policy #{policy.effective_mode} does not fetch " \
          "#{reference.fetch_classification} references"
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

        # THE AGGREGATE, not just the individual. Twenty assets that each pass
        # `asset_max_bytes` still make a document no engine will draw — §5.1 caps one asset and
        # says nothing about a document, which is the other half of G6's "no unbounded output".
        if state.embedded_bytes + size > MAX_TOTAL_BYTES
          state.refuse(reference,
                       "would take this document past the #{MAX_TOTAL_BYTES}-byte total " \
                       "embedded-asset budget (#{state.embedded_bytes} bytes already embedded)")
          return
        end
        state.embed_bytes(size)

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

      # WHICH ATTRIBUTES A STRUCTURAL REWRITE MAY DISCARD. Replacing an element with a `<style>`
      # or `<script>` block throws away everything the element carried, and some of it changes
      # what the element MEANS:
      #
      #   <link rel=stylesheet media=print href=…>   a print-only sheet becomes all-media
      #   <link rel=stylesheet disabled href=…>      a disabled sheet starts applying
      #   <script type=module src=…>                 a module becomes a classic script
      #   <script defer src=…>                       execution order changes
      #
      # Rather than replicate HTML's semantics for each, the rewrite is allowed only for
      # elements carrying nothing but these — and `media` is carried THROUGH onto the `<style>`
      # tag, because a print stylesheet is exactly what a report has. Anything else falls back to
      # a `data:` URI, which keeps the element and every attribute on it.
      STRUCTURAL_SAFE_ATTRIBUTES = {
        stylesheet: %w[href rel media charset].freeze,
        script: %w[src charset].freeze
      }.freeze

      # nil when there is no structural form, or when the bytes or the element make one unsafe.
      def structural_text(reference, bytes, content_type, state)
        span = reference.element_span
        return nil if span.nil? || span.first.nil? || span.last.nil?
        return fallback(reference, state) unless structural_element?(reference)

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

          "<style#{media_attribute(reference)}>\n#{text}\n</style>"
        when :script
          return fallback(reference, state) if terminator?(text, 'script') || text.include?('<!--')

          "<script>\n#{text}\n</script>"
        end
      end

      # Every attribute the element carried has to be in the safe set, or the rewrite would
      # silently change what it means. Compared as a SUBSET rather than by looking for known-bad
      # names: an attribute nobody thought about is then a fallback rather than a surprise.
      def structural_element?(reference)
        allowed = STRUCTURAL_SAFE_ATTRIBUTES[reference.usage]
        return false if allowed.nil?

        (reference.element_attributes.keys - allowed).empty?
      end

      # `media` is the one attribute carried through, because a print-only stylesheet is exactly
      # what a report has and promoting it to all-media is a visible layout change. The value is
      # escaped: it is author-controlled and it is going into attribute position.
      def media_attribute(reference)
        media = reference.element_attributes['media']
        return '' if media.nil? || media.to_s.strip.empty?

        %( media="#{escape_attribute(media)}")
      end

      def escape_attribute(value)
        value.to_s.gsub('&', '&amp;').gsub('"', '&quot;').gsub('<', '&lt;').gsub('>', '&gt;')
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

      # Two replacements over the same bytes would make the output depend on their order, which
      # would be a defect in THIS file's arithmetic. Loud, because a silent one produces
      # plausible output.
      #
      # It must be unreachable from document content, and the first version was not: a
      # `<link rel=stylesheet href=… style="background:url(…)">` produced an element-span
      # replacement containing a value-span one, and this raised `ArgumentError` out of a method
      # documented never to raise. `suppress_nested_element_spans` closes that case at the top of
      # `call`; the message no longer blames `DocumentScanner`, whose value spans are disjoint in
      # every case measured — pointing a maintainer at the wrong file is its own defect.
      def assert_disjoint!(ordered)
        ordered.each_cons(2) do |(later_start, _, _), (earlier_start, earlier_length, _)|
          next if earlier_start + earlier_length <= later_start

          raise ArgumentError,
                "overlapping asset replacements at #{earlier_start} and #{later_start}: two " \
                'replacements cover the same bytes, so the output would depend on their order. ' \
                'This is a bug in Resolver — see suppress_nested_element_spans.'
        end
      end
    end
  end
end
