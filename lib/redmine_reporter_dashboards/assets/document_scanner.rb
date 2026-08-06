# frozen_string_literal: true

module RedmineReporterDashboards
  module Assets
    # ONE PASS OVER THE DOCUMENT, finding every reference an engine would go and fetch.
    #
    # --- WHY THIS IS A TOKENIZER AND NOT A REGEXP, AGAIN ---
    #
    # HANDOVER §1 records what a regexp costs here: `HtmlScanner`'s first version found
    # `<script>` inside a Liquid comment and reported **72 escaping findings in a template
    # that had none**, and linting a README as one document produced 23 findings in
    # Markdown prose. This scanner has the same three hazards and each one is a hole
    # rather than a false positive, which is worse:
    #
    #   a URL inside `<!-- … -->`        the browser never fetches it. Rewriting it is
    #                                    harmless; REFUSING the document over it is not
    #   a URL inside a `<script>` BODY   `var next = "/issues/1"` is not a subresource. A
    #                                    scanner that rewrites it corrupts the script
    #   a URL inside a `<textarea>`      literal text an author is showing to a reader
    #
    # All three are skipped by tracking element state, not by pattern. And a `<style>`
    # BODY is the opposite case — `url()` in there IS a subresource and must be found.
    #
    # --- WHAT AN INCOMPLETE TABLE COSTS ---
    #
    # Every attribute this table misses is an egress hole, so the table is closed and
    # errs towards including things a report should not contain (`<iframe>`, `<object>`)
    # so that they are REFUSED rather than passed through unseen. `srcset` is in it for
    # exactly that reason: it is the attribute a first draft forgets, and one unhandled
    # subresource is all an SSRF needs (the same argument `F-15-egress-denial` makes about
    # using four reference types instead of one).
    class DocumentScanner
      # Tag -> attribute -> usage. `link` and `script` are handled separately because
      # `link`'s usage depends on its `rel` and `script` needs its element span.
      ATTRIBUTE_REFERENCES = {
        'img' => { 'src' => :image, 'srcset' => :image, 'lowsrc' => :image },
        'source' => { 'src' => :image, 'srcset' => :image },
        'input' => { 'src' => :image },
        'video' => { 'src' => :media, 'poster' => :image },
        'audio' => { 'src' => :media },
        'track' => { 'src' => :other },
        'embed' => { 'src' => :other },
        'object' => { 'data' => :other },
        'iframe' => { 'src' => :other },
        'frame' => { 'src' => :other },
        # SVG. `<use href="#id">` is a fragment and classifies as `:ignored`; the same
        # attribute pointing at another document does not, which is why it is here.
        'image' => { 'href' => :image, 'xlink:href' => :image },
        'use' => { 'href' => :image, 'xlink:href' => :image },
        'feimage' => { 'href' => :image, 'xlink:href' => :image },
        # Legacy presentational attributes. Still honoured by both shipped engines.
        'body' => { 'background' => :image },
        'table' => { 'background' => :image },
        'td' => { 'background' => :image },
        'th' => { 'background' => :image }
      }.freeze

      # `rel` values that cause a fetch, and what the fetched thing is for. Anything else
      # (`canonical`, `alternate`, `author`) is metadata and not a subresource.
      LINK_RELS = {
        'stylesheet' => :stylesheet,
        'icon' => :image,
        'shortcut' => :image,
        'apple-touch-icon' => :image,
        'apple-touch-icon-precomposed' => :image,
        'mask-icon' => :image,
        'preload' => :other,
        'prefetch' => :other,
        'preconnect' => :other,
        'dns-prefetch' => :other
      }.freeze

      # Bodies this scanner must not look inside. `style` is deliberately absent — see
      # the class comment.
      OPAQUE_BODIES = %w[script textarea].freeze

      TAG_NAME = /\A([A-Za-z][A-Za-z0-9:._-]*)/.freeze
      ATTRIBUTE = /
        \s+
        ([A-Za-z_:][-A-Za-z0-9_:.]*)                       # 1 name
        (?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'`=<>]+)))?  # 2 dq  3 sq  4 bare
      /x.freeze

      CSS_URL = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^)'"\s]*))\s*\)/i.freeze
      # `@import "x.css";` — the form `CSS_URL` does not match, and it fetches.
      CSS_IMPORT = /@import\s+(?:"([^"]*)"|'([^']*)')/i.freeze

      attr_reader :html, :origin

      def initialize(html, origin: Origin.new)
        @html = html.to_s
        @origin = origin
      end

      def self.scan(html, origin: Origin.new)
        new(html, origin: origin).scan
      end

      # References in document order, with non-overlapping value spans.
      def scan
        references = []
        index = 0
        length = @html.length

        while (open = @html.index('<', index))
          index = handle(open, references)
          break if index.nil? || index > length
        end

        # SORTED BY POSITION at the end, not assumed to arrive that way. Two producers
        # append out of order — a `style` attribute is scanned mid-tag while the tag's other
        # attributes are still being read, and a `<style>` body is scanned once per pattern
        # rather than once per position. Document order is what a reader of the reference
        # list expects and what the resolver's disjointness assertion is stated in.
        references.sort_by { |reference| reference.span.first }
      end

      private

      # Returns the index to continue from. One method so every branch is forced to
      # answer "and where does the next token start?" — the bug this shape prevents is an
      # infinite loop on a malformed tag, which `spec/assets/document_scanner_spec.rb`
      # tests for with an unterminated comment and an unterminated tag.
      def handle(open, references)
        return skip_to(open, '-->', 3) if @html[open, 4] == '<!--'
        return skip_to(open, '>', 1) if %w[! ?].include?(@html[open + 1]) || @html[open + 1] == '/'

        match = TAG_NAME.match(@html[open + 1, 64].to_s)
        return open + 1 if match.nil?

        name = match[1].downcase
        tag_end = tag_end_index(open)
        return @html.length if tag_end.nil?

        attributes = parse_attributes(open + 1 + match[1].length, tag_end)
        self_closing = @html[tag_end - 1] == '/'

        collect(name, attributes, open, tag_end, references)

        if OPAQUE_BODIES.include?(name) && !self_closing
          body_end, element_end = raw_text_bounds(name, tag_end + 1)
          # ONLY when the element was actually closed. An unterminated `<script src=…>`
          # would otherwise get an element span running to the end of the document, and
          # the structural rewrite would delete everything after it.
          patch_element_span(references, name, open, element_end) unless body_end.nil?
          return body_end.nil? ? @html.length : element_end
        end

        if name == 'style' && !self_closing
          body_end, element_end = raw_text_bounds(name, tag_end + 1)
          scan_css(tag_end + 1, body_end || @html.length, references)
          return body_end.nil? ? @html.length : element_end
        end

        tag_end + 1
      end

      def skip_to(open, terminator, terminator_length)
        found = @html.index(terminator, open + 2)
        found.nil? ? @html.length : found + terminator_length
      end

      # The index of the tag's closing `>`, skipping any `>` inside a quoted attribute
      # value. `<img alt="a > b" src="x">` is why this is not `index('>')`.
      def tag_end_index(open)
        position = open + 1
        quote = nil
        while position < @html.length
          char = @html[position]
          if quote
            quote = nil if char == quote
          elsif char == '"' || char == "'"
            quote = char
          elsif char == '>'
            return position
          end
          position += 1
        end
        nil
      end

      # `[{ name:, value:, span: }]` with ABSOLUTE spans, so a replacement can be spliced
      # without re-finding anything. A valueless attribute gets a nil span and is skipped
      # by every consumer.
      def parse_attributes(from, tag_end)
        segment = @html[from...tag_end].to_s
        attributes = []
        position = 0

        while (match = ATTRIBUTE.match(segment, position))
          value_group = [2, 3, 4].find { |group| match[group] }
          attributes << {
            name: match[1].downcase,
            value: value_group ? match[value_group] : nil,
            span: value_group ? [from + match.begin(value_group), match[value_group].length] : nil
          }
          position = match.end(0)
          break if position <= match.begin(0)
        end

        attributes
      end

      def collect(name, attributes, open, tag_end, references)
        attributes.each do |attribute|
          next if attribute[:span].nil?

          if attribute[:name] == 'style'
            scan_css(attribute[:span].first, attribute[:span].first + attribute[:span].last,
                     references)
            next
          end

          usage = usage_for(name, attribute[:name], attributes)
          next if usage.nil?

          references.concat(build(attribute, usage, element_span_for(name, attribute[:name], open,
                                                                    tag_end)))
        end
      end

      def usage_for(tag, attribute, attributes)
        return LINK_RELS[link_rel(attributes)] if tag == 'link' && attribute == 'href'
        return :script if tag == 'script' && attribute == 'src'

        ATTRIBUTE_REFERENCES.dig(tag, attribute)
      end

      # `rel="shortcut icon"` is two tokens and means the icon. First recognised token
      # wins; an unrecognised `rel` answers nil and the reference is skipped.
      def link_rel(attributes)
        raw = attributes.find { |attribute| attribute[:name] == 'rel' }&.fetch(:value)
        raw.to_s.downcase.split(/\s+/).find { |token| LINK_RELS.key?(token) }
      end

      # Only two elements can be replaced WHOLE, and only these two need to be: §5.1 says
      # "CSS, JS and SVG inlined into the single document body", and a `<style>` block is
      # the form every engine — including a 2011 WebKit — is certain to accept.
      def element_span_for(tag, attribute, open, tag_end)
        return [open, tag_end + 1 - open] if tag == 'link' && attribute == 'href'
        return [open, nil] if tag == 'script' && attribute == 'src'

        nil
      end

      # `srcset` is ONE reference, not N. The candidates are alternatives for different
      # pixel densities and a PDF page has exactly one, so the first is resolved and the
      # rest are dropped — VISIBLY, through `candidates`, which the resolver turns into a
      # degradation. Resolving them all and splicing each in place is not an option: a
      # `data:` URI contains a comma, and `srcset` is comma-separated.
      def build(attribute, usage, element_span)
        return [] if attribute[:value].to_s.strip.empty?

        if attribute[:name] == 'srcset'
          segments = attribute[:value].split(',')
          first = segments.first.to_s.strip.split(/\s+/).first.to_s
          return [] if first.empty?

          return [Reference.new(raw: first, usage: usage, span: attribute[:span],
                                origin: origin, candidates: segments.length)]
        end

        [Reference.new(raw: attribute[:value], usage: usage, span: attribute[:span],
                       origin: origin, element_span: element_span)]
      end

      # `<script src>`'s element span cannot be known until the closing tag is found, so
      # it is filled in afterwards. The alternative — looking ahead before recording —
      # would duplicate the raw-text search for every script element in the document.
      def patch_element_span(references, name, open, element_end)
        return unless name == 'script'

        references.map! do |reference|
          next reference unless reference.element_span == [open, nil]

          Reference.new(raw: reference.raw, usage: reference.usage, span: reference.span,
                        origin: reference.origin, element_span: [open, element_end - open],
                        candidates: reference.candidates)
        end
      end

      # `[body_end, element_end]`. `body_end` is where the raw text stops; `element_end`
      # is past the closing tag. nil body_end means the element was never closed, and the
      # caller then stops scanning rather than looping.
      # A case-insensitive search with an OFFSET, not `@html.downcase.index(…)`. The
      # downcased copy is a whole extra document allocated per raw-text element, which on
      # a 2 000-row report with a script block per chart is measurable for no reason.
      def raw_text_bounds(name, from)
        closing = @html.index(/<\/#{Regexp.escape(name)}/i, from)
        return [nil, @html.length] if closing.nil?

        gt = @html.index('>', closing)
        [closing, gt.nil? ? @html.length : gt + 1]
      end

      def scan_css(from, to, references)
        segment = @html[from...to].to_s

        [[CSS_URL, [1, 2, 3]], [CSS_IMPORT, [1, 2]]].each do |pattern, groups|
          position = 0
          while (match = pattern.match(segment, position))
            group = groups.find { |candidate| match[candidate] }
            if group && !match[group].strip.empty?
              usage = pattern == CSS_IMPORT ? :stylesheet : css_usage(match[group])
              references << Reference.new(
                raw: match[group], usage: usage,
                span: [from + match.begin(group), match[group].length], origin: origin
              )
            end
            position = match.end(0)
            break if position <= match.begin(0)
          end
        end
      end

      # A `url()` in CSS is a font when it is in a `@font-face` and an image otherwise,
      # and this scanner does not parse CSS structure. The EXTENSION answers it well
      # enough, and getting it wrong costs a content-type refusal that names the file —
      # not a silent inlining of the wrong type.
      # `.css` is here because `@import url(x.css)` is the ONE `url()` that is a
      # stylesheet. Without it the reference is typed `:image`, `LocalStore` refuses it for
      # a usage mismatch, and the refusal blames the file for being a stylesheet.
      FONT_EXTENSIONS = %w[.woff .woff2 .ttf .otf .eot].freeze
      CSS_USAGE_BY_EXTENSION = { '.css' => :stylesheet }.freeze

      def css_usage(url)
        extension = File.extname(url.split(/[?#]/, 2).first.to_s).downcase
        return :font if FONT_EXTENSIONS.include?(extension)

        CSS_USAGE_BY_EXTENSION.fetch(extension, :image)
      end
    end
  end
end
