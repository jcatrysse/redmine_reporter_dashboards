# frozen_string_literal: true

require 'cgi'

module RedmineReporterDashboards
  module Assets
    # ONE subresource reference found in a document, classified.
    #
    # The classification is the only decision this class makes, and everything the policy
    # does keys off it. Five values, and the fifth is the one that matters:
    #
    #   :data_uri      already inline. Nothing to do, nothing to fetch, no bytes to cap
    #   :ignored       a fragment, `mailto:`, `about:`, `javascript:` — not a subresource
    #   :local_path    `/plugin_assets/…` — a path on THIS install, resolvable on disk
    #   :same_origin   an absolute URL whose host AND PORT are this install's
    #   :third_party   an absolute http(s) URL somewhere else
    #   :unresolvable  a relative path, or a scheme this layer will not touch
    #
    # `:unresolvable` is a REFUSAL, not a shrug. A request-less render has no base to
    # resolve `logo.png` against — there is no document URL, because the document was
    # never served. The engine would draw a blank box, and a blank box in an audit
    # document that a reader cannot tell from "there was no logo" is exactly the silent
    # shape INV-4 objects to. So it is named in the failure with the reference in it.
    #
    # --- ATTRIBUTE VALUES ARE HTML-ESCAPED AND URLS ARE PERCENT-ESCAPED ---
    #
    # `<img src="/a&amp;b.png">` refers to `/a&b.png`, and `%2e%2e%2f` decodes to `../`.
    # Both are unescaped here, ONCE, before any comparison or path handling — because a
    # check performed against the escaped form is a check an attacker chooses the
    # encoding of. `LocalStore` then does its own realpath containment on the decoded
    # path, so this is defence in depth rather than the control.
    class Reference
      USAGES = %i[image stylesheet script font media other].freeze
      CLASSIFICATIONS = %i[data_uri ignored local_path same_origin third_party unresolvable].freeze

      # Schemes that are not subresources and never become one.
      IGNORED_SCHEMES = %w[mailto tel sms about javascript data cid blob ws wss file].freeze
      FETCHABLE_SCHEMES = %w[http https].freeze

      attr_reader :raw, :usage, :span, :element_span, :origin, :candidates, :element_attributes

      # `span` is the byte range of the value this reference was read from, so the
      # resolver can splice a replacement in without re-parsing. `element_span` is the
      # range of the whole element, present only where a structural rewrite is possible
      # (`<link rel=stylesheet>` and `<script src>` — see `Resolver`). `element_attributes`
      # is what that element carried, so the resolver can refuse a structural rewrite that
      # would change the element's meaning rather than replicate HTML semantics.
      def initialize(raw:, usage:, span:, origin: Origin.new, element_span: nil,
                     candidates: 1, element_attributes: nil)
        @raw = raw.to_s
        @usage = usage.to_sym
        raise ArgumentError, "#{usage.inspect} is not a usage: #{USAGES.inspect}" unless
          USAGES.include?(@usage)

        @span = span
        @element_span = element_span
        @element_attributes = (element_attributes || {}).freeze
        @origin = origin
        # >1 means an `srcset` with alternatives, only the first of which is resolved.
        # Recorded so the resolver can degrade VISIBLY rather than quietly dropping them.
        @candidates = candidates

        # EVERYTHING DERIVED IS COMPUTED HERE, BEFORE `freeze`. The first draft memoised
        # `url` and `classification` lazily and every accessor raised `FrozenError` on
        # first use — the object is frozen for the same reason every value object in this
        # plugin is, and a lazy memo is a mutation. Caught by the first smoke run; a
        # reviewer would not have seen it, because the code reads correctly.
        @url = CGI.unescapeHTML(@raw).strip
        @scheme_literal = @url[/\A([A-Za-z][A-Za-z0-9+.\-]*):/, 1]&.downcase
        @parsed_authority = parse_authority
        @classification = classify
        @scheme = compute_scheme
        @host = compute_host
        @port = compute_port
        @path = compute_path
        freeze
      end

      # The reference with HTML entities resolved — what the browser would actually
      # request. `CGI.unescapeHTML` handles the named and numeric forms.
      attr_reader :url, :classification, :scheme, :host, :port, :path

      def data_uri?
        classification == :data_uri
      end

      def ignored?
        classification == :ignored
      end

      def passthrough?
        data_uri? || ignored?
      end

      # Local and same-origin are the same file on the same disk; the only difference is
      # whether the author wrote the host. The policy asks about the network, and for
      # both of those the network question is the same one.
      def fetch_classification
        classification == :local_path ? :same_origin : classification
      end

      NETWORKED = %i[local_path same_origin third_party].freeze

      # The absolute URL, for a message a human reads. Length-capped and stripped of
      # control characters, because it lands in `Failure#message`, which is shown to a
      # user — and a message is not a place to relay 4 KB of author-controlled bytes.
      MAX_DISPLAY = 200

      def display
        text = url.gsub(/[[:cntrl:]]/, '')
        text.length > MAX_DISPLAY ? "#{text[0, MAX_DISPLAY]}…" : text
      end

      def to_h
        { 'url' => display, 'usage' => usage.to_s, 'classification' => classification.to_s }.freeze
      end

      private

      def classify
        return :ignored if @url.empty?
        return :data_uri if @url.downcase.start_with?('data:')
        return :ignored if @url.start_with?('#')
        # A CONTROL CHARACTER MAKES A URL UNUSABLE, and one in particular makes it dangerous: a
        # CR or LF in a path is a request-splitting primitive, and `Net::HTTP` answers it with a
        # bare `ArgumentError` rather than a refusal. Refused here, at the earliest point, so
        # nothing downstream has to remember. `.strip` does not cover it — it trims the ends, and
        # `/a\nb.png` has a non-whitespace byte after the newline.
        return :unresolvable if @url.match?(/[[:cntrl:]]/)
        return :ignored if @scheme_literal && IGNORED_SCHEMES.include?(@scheme_literal)
        return :unresolvable if @scheme_literal && !FETCHABLE_SCHEMES.include?(@scheme_literal)

        # Protocol-relative `//host/path` inherits the document's scheme, which for a
        # request-less render is this install's.
        return classify_absolute if @scheme_literal || @url.start_with?('//')
        return :local_path if @url.start_with?('/')

        # A relative path. No base exists, so this is honestly unresolvable — see the
        # class comment on why that is a refusal and not a blank image.
        :unresolvable
      end

      def classify_absolute
        host, port = @parsed_authority
        return :unresolvable if host.nil? || host.empty?

        origin.same?(host, port, @scheme_literal || origin.scheme) ? :same_origin : :third_party
      end

      def compute_scheme
        return origin.scheme if @classification == :local_path

        @scheme_literal || (@url.start_with?('//') ? origin.scheme : nil)
      end

      def compute_host
        return nil unless NETWORKED.include?(@classification)
        return origin.host if @classification == :local_path

        @parsed_authority.first
      end

      def compute_port
        return nil unless NETWORKED.include?(@classification)
        return origin.port if @classification == :local_path

        @parsed_authority.last || Origin::DEFAULT_PORTS[@scheme]
      end

      # The path component, with this install's mount prefix removed for anything
      # same-origin — which is what `LocalStore` maps. Percent-decoding happens in
      # `LocalStore`, not here: it owns the containment check and must see the raw form.
      def compute_path
        case @classification
        when :local_path then origin.strip_prefix(strip_query(@url))
        when :same_origin then origin.strip_prefix(strip_query(after_authority))
        when :third_party then strip_query(after_authority)
        end
      end

      # Everything after `scheme://` or `//`, i.e. `host[:port]/path?query`.
      def after_authority
        rest = @url.sub(%r{\A[A-Za-z][A-Za-z0-9+.\-]*://}, '').sub(%r{\A//}, '')
        slash = rest.index('/')
        slash.nil? ? '/' : rest[slash..]
      end

      def parse_authority
        rest = @url.sub(%r{\A[A-Za-z][A-Za-z0-9+.\-]*://}, '').sub(%r{\A//}, '')
        authority = rest.split(%r{[/?#]}, 2).first.to_s
        # `user:pass@host` — credentials in a URL are dropped, never carried. §5.1:
        # assets are fetched anonymously or not at all, and userinfo is the oldest way to
        # smuggle a credential past a check that only looked at the host.
        Origin.split_authority(authority.split('@', 2).last.to_s)
      end

      def strip_query(text)
        text.to_s.split(/[?#]/, 2).first.to_s
      end
    end
  end
end
