# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # Where a `<script>` element starts and stops, decided by walking the document's
    # states rather than by matching a pattern against it.
    #
    # T-19's acceptance list requires the FR-19 lint to *"parse rather than regex the
    # HTML"*, and this is what it parses with. The rule it feeds is the one the security
    # review ranked highest — `{{ }}` inside `<script>` without `| json`/`| js` — so
    # "where is the script" has to be answered correctly or the rule is answered
    # correctly about the wrong text.
    #
    # --- WHY NOT NOKOGIRI, WHICH IS ALREADY IN THE PROCESS ---
    #
    # Because a Liquid template is not an HTML document, and an HTML parser's job is to
    # REPAIR one. `{% if urgent %}<div class="red">{% endif %}` is an entirely ordinary
    # template and an unbalanced fragment; a repairing parser moves nodes, invents
    # `<html>`/`<body>`, and closes elements the author closes in the other branch. A
    # region that gets moved is a region whose offsets no longer point at the source, and
    # the linter's whole reporting model is line numbers into the source the author is
    # editing. Nokogiri also gives no byte offsets — `node.line` and nothing finer.
    #
    # So: a scanner over the HTML grammar's states. Not a regex, not a document model —
    # the third option, and the only one that answers "which bytes of THIS FILE are
    # script content" exactly.
    #
    # --- WHAT A REGEX ACTUALLY GETS WRONG, each of which has a spec ---
    #
    #   <!-- <script>{{ x }}</script> -->     a commented-out block is not code
    #   <script data-note="a>b">              `[^>]*>` ends the tag at the wrong `>`
    #   <div title="{{ a > b }}">             a Liquid expression is not markup
    #   <script type="application/json">      the type decides which rule applies
    #   <style>                               raw text too, and not script
    #
    # The first two are the ones that produce a WRONG finding rather than a missing one,
    # and a linter that cries wolf is a linter somebody switches off.
    class HtmlScanner
      # HTML's raw-text elements: their content ends only at the matching end tag, and
      # markup inside them is not markup. `script` and `style` are the two that matter
      # here; `textarea` and `title` are escapable-raw-text and are included because a
      # `<` inside one is likewise not a tag.
      RAW_TEXT = %w[script style textarea title].freeze

      # One region of the source, with the offsets to prove where it came from.
      Region = Struct.new(:name, :attributes, :content, :content_offset, keyword_init: true) do
        # `<script>` with no type, or one naming JavaScript, is executable. A
        # `type="application/json"` block is DATA — still linted for unescaped
        # interpolation (an unquoted value breaks the JSON just as surely) but it is not
        # the same finding and a caller may want to tell them apart.
        JS_TYPES = ['', 'text/javascript', 'application/javascript', 'module',
                    'text/ecmascript', 'application/ecmascript'].freeze

        def type
          attributes['type'].to_s.downcase.strip
        end

        def javascript?
          JS_TYPES.include?(type)
        end
      end

      # A cap, because this runs on author-supplied text. `TemplateLinter` bounds the body
      # before it gets here, and this bounds the work per document independently — two
      # limits rather than one, for the same reason §4 wants both resource limits and a
      # deadline.
      MAX_REGIONS = 500

      def initialize(source)
        @source = source.to_s
        @length = @source.length
      end

      # Every raw-text region in the document, in source order.
      def regions
        @regions ||= scan
      end

      def script_regions
        regions.select { |region| region.name == 'script' }
      end

      private

      # ONE PASS, and the state is explicit rather than implied by where we are in a
      # regexp. Each branch consumes a construct whole, which is what makes a `>` inside
      # an attribute or a Liquid expression harmless: it is never looked at as markup
      # because the scanner is not in a state that looks for markup there.
      def scan
        found = []
        index = 0

        while index < @length
          char = @source[index]

          if liquid_at?(index)
            index = skip_liquid(index)
          elsif comment_at?(index)
            index = skip_comment(index)
          elsif char == '<' && tag_name_at(index + 1)
            index = consume_element(index, found)
          else
            index += 1
          end

          break if found.length >= MAX_REGIONS
        end

        found
      end

      # `{{ … }}` and `{% … %}` are consumed whole WHEREVER they appear, including inside
      # a tag's attribute list. `<div title="{{ a > b }}">` is a real template and the `>`
      # in it does not end the tag — which is the third of the four cases a regex gets
      # wrong, and the one most likely to be in a template already.
      def liquid_at?(index)
        @source[index] == '{' && ['{', '%'].include?(@source[index + 1])
      end

      # Two Liquid tags own their BODY as well as themselves, and both bodies have to be
      # skipped whole.
      #
      # FOUND BY BREAKING IT. The first version skipped only the tag, so a
      # `{% comment %}` explaining *why* chart data must not be built by string
      # concatenation — a comment containing the word `<script>` in prose — opened a
      # script region that ran to the next real `</script>`, several hundred lines away.
      # The linter then reported 72 escaping findings in a template that had none: every
      # interpolation in between was suddenly "inside a script".
      #
      # It is not only a false-positive bug, it is the right semantics. A
      # `{% comment %}` body is not rendered, so nothing in it can be a defect in the
      # output; a `{% raw %}` body is rendered LITERALLY, so `{{ x }}` in it is text
      # rather than interpolation. Both are cases where scanning the content would
      # describe a document that does not exist.
      BLOCK_BODIES = %w[comment raw].freeze

      def skip_liquid(index)
        if @source[index + 1] == '%' && (name = block_body_at(index))
          return skip_block_body(index, name)
        end

        closing = @source[index + 1] == '{' ? '}}' : '%}'
        found = @source.index(closing, index + 2)
        found.nil? ? @length : found + 2
      end

      def block_body_at(index)
        name = @source[index + 2, 32].to_s[/\A-?\s*([a-z]+)/, 1]
        BLOCK_BODIES.include?(name) ? name : nil
      end

      # To `{% endcomment %}` / `{% endraw %}`, or to end of source if the author never
      # closed it — which is a Liquid syntax error the renderer will report, not
      # something for the scanner to guess about.
      def skip_block_body(index, name)
        match = /\{%-?\s*end#{name}\s*-?%\}/.match(@source, index)
        match ? match.end(0) : @length
      end

      def comment_at?(index)
        @source[index, 4] == '<!--'
      end

      def skip_comment(index)
        found = @source.index('-->', index + 4)
        found.nil? ? @length : found + 3
      end

      # `<name` … `>`, then — for a raw-text element — everything up to the matching end
      # tag. Returns the index to continue from.
      def consume_element(index, found)
        name = tag_name_at(index + 1)
        after_name = index + 1 + name.length
        tag_end = skip_attributes(after_name)
        return tag_end if tag_end >= @length

        attributes = parse_attributes(@source[after_name...tag_end].to_s)
        content_start = tag_end + 1

        lowered = name.downcase
        return content_start unless RAW_TEXT.include?(lowered)
        # `<script src="…"/>` — self-closing is not valid HTML for a script, but a
        # template author writes it and the scanner must not then swallow the rest of the
        # document looking for an end tag that is not coming.
        return content_start if @source[tag_end - 1] == '/'

        close = find_end_tag(lowered, content_start)
        found << Region.new(name: lowered, attributes: attributes,
                            content: @source[content_start...close].to_s,
                            content_offset: content_start)
        close
      end

      # A tag name only where HTML permits one, so `a < b` in prose is not an element and
      # `</script>` is not confused with `<script>`.
      def tag_name_at(index)
        @source[index..]&.slice(/\A[A-Za-z][A-Za-z0-9-]*/)
      end

      # Walk to the `>` that ends the tag, skipping quoted attribute values and Liquid.
      # `<script data-note="a>b">` is the second case a regex gets wrong: `[^>]*>` stops
      # inside the attribute, and everything after it is then read as document text —
      # so the script's content is never linted at all.
      def skip_attributes(index)
        while index < @length
          char = @source[index]

          if liquid_at?(index)
            index = skip_liquid(index)
          elsif char == '"' || char == "'"
            index = skip_quoted(index, char)
          elsif char == '>'
            return index
          else
            index += 1
          end
        end
        @length
      end

      def skip_quoted(index, quote)
        found = @source.index(quote, index + 1)
        found.nil? ? @length : found + 1
      end

      # Raw text ends at `</name` followed by whitespace, `>` or `/` — the HTML spec's
      # own rule. `</scriptfoo>` does NOT end a script, and a JS string containing
      # `"</script>"` DOES: the tokenizer never looks inside the string, which is exactly
      # why `| json` has to escape `<` rather than trusting the quotes.
      def find_end_tag(name, from)
        pattern = %r{</#{Regexp.escape(name)}(?=[\s/>])}i
        match = pattern.match(@source, from)
        match ? match.begin(0) : @length
      end

      # Enough attribute parsing to read a `type`. Values may be double-quoted,
      # single-quoted or bare; a bare value ends at whitespace.
      def parse_attributes(text)
        text.scan(/([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s>]+))?/)
            .each_with_object({}) do |(name, value), out|
          out[name.downcase] = value.nil? ? '' : value.gsub(/\A["']|["']\z/, '')
        end
      end
    end
  end
end
