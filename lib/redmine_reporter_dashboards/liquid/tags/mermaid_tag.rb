# frozen_string_literal: true

require_relative '../execution_policy'

module RedmineReporterDashboards
  module Liquid
    module Tags
      # `{% mermaid %} … {% endmermaid %}` — a thin tag over a vendored library, and thin is
      # the whole design decision.
      #
      # --- WHY THIS IS 200 LINES AND `{% chart %}` IS 324 ---
      #
      # T-35 originally specified a `MermaidSpec`, a collector, a `:mermaid` capability and an
      # SVG sanitiser — four pieces of per-library machinery. The curator's intent is the
      # opposite: *"a modern system accepting most modern forms of javascript … we didn't want
      # a specific management of specific javascript libraries. We just used chart.js and
      # mermaid as examples"* (§Findings F-17). So:
      #
      #   * no spec object and no collector. `{% chart %}` needs them because the PLUGIN
      #     computes a chart's layout and the HTML and PDF twins must agree about it. Mermaid
      #     computes its own layout, so there is nothing to compute once and share.
      #   * no sanitiser. An author may write `<script>` directly (INV-9: authoring IS code
      #     execution), so stripping it from a library's output in the same document is a cost
      #     with a security-shaped name.
      #   * no `:mermaid` capability. `:modern_javascript` says the true and general thing —
      #     see `Render::Capabilities`.
      #
      # What is left is the ergonomics: a block tag so an author writes the diagram and not the
      # scaffolding, the library referenced once per document, and the readiness contract joined
      # without the author knowing it exists.
      #
      # --- THE BODY IS RAW, AND THE TAG INHERITS THAT RATHER THAN IMPLEMENTING IT ---
      #
      # Mermaid syntax is full of `{`, `}` and `|` — `B{Choice}`, `A -->|yes| C` — which Liquid
      # would try to read as markup. §6.1 therefore requires the body NOT be interpolated by
      # default, and `Liquid::Raw` already captures a body verbatim on BOTH majors (4.0.4 and
      # 5.13.0), which a hand-rolled version would have to do against two different tokenizer
      # APIs. Inheriting it is the only cross-major-safe option.
      #
      # The render entry point is NOT the same on the two majors, though: Liquid 4 calls
      # `render`, Liquid 5 calls `render_to_output_buffer`, and `Raw` overrides only the latter.
      # Defining both is what makes one class work on both, and `spec_liquid/` runs it twice.
      #
      # --- `interpolate: true` SUBSTITUTES VALUES, NOT LIQUID, AND THAT IS THE SECURITY LINE ---
      #
      # This is the one place in the tag where bytes that are NOT the author's reach the output:
      # an issue subject, a custom field value, a version name — written by every user, not by
      # the manager who wrote the template. After F-17 dropped the sanitiser, escaping at this
      # boundary is the only control on that path, so it matters more than it did, not less.
      #
      # Two properties, both deliberate:
      #
      #   * a `{{ lookup }}` is resolved through the Liquid CONTEXT and its value is escaped.
      #     There is no second `Template.parse` — `script/gates/single_parse.sh` forbids one, and
      #     a template parsed here would carry none of the execution policy's limits.
      #   * `{% … %}` is NOT executed. A diagram is not a place for control flow, and refusing
      #     to run tags here means an interpolated diagram cannot reach a filter, a drop method
      #     or another tag. An author who needs a loop builds the source above the tag and
      #     interpolates one variable.
      class MermaidTag < ::Liquid::Raw
        # §6.1: "`mermaid_max_bytes` (default 16 KiB of source)". A diagram larger than this is
        # a diagram nobody can read and a layout Mermaid will spend the render budget on.
        DEFAULT_MAX_BYTES = 16 * 1024

        # The plugin's own vendored copy, referenced root-relative. On the owned render path
        # T-33's resolver maps this back to the file on disk and inlines it; in a browser it is
        # an ordinary asset request. Either way nothing is fetched from a CDN (§6).
        ASSET_ROOT = '/plugin_assets/redmine_reporter_dashboards/javascripts'
        LIBRARY_SRC = "#{ASSET_ROOT}/vendor/mermaid.min.js"
        BOOT_SRC = "#{ASSET_ROOT}/mermaid_boot.js"

        # ONCE PER RENDER, not once per diagram. The library is 3.5 MB; emitting it per tag
        # would multiply that by the number of diagrams. The Liquid context's registers are the
        # per-render scratchpad — the same mechanism the aggregation tags use for their budget —
        # so this needs no collector and no state on the tag.
        REGISTER_KEY = :rrd_mermaid_assets_emitted

        # An accessible label is a label, not a paragraph. `ChartLayout::MAX_LABEL_CHARS`
        # bounds a chart's category labels at 24 for a layout reason this has none of, so
        # the number is its own: long enough for a real sentence, short enough that an
        # attribute cannot become the document.
        MAX_LABEL_CHARS = 200

        # `[A-Za-z][\w-]*`, the same restriction `ChartSpec` puts on a chart id: RESTRICTED
        # rather than escaped, so there is nothing to get wrong later when it lands in an
        # attribute.
        ID_PATTERN = /\A[A-Za-z][A-Za-z0-9_-]*\z/
        PARAM_RE = /(\w+)\s*:\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))/
        # A single `{{ … }}` lookup. Deliberately not a Liquid subset: no filters, no `{% %}`.
        LOOKUP_RE = /\{\{\s*([a-zA-Z_][\w.\[\]'"-]*)\s*\}\}/

        # `Liquid::Raw::Syntax` is `/\A\s*\z/` on BOTH majors — a raw tag takes no markup at
        # all, so `{% mermaid id: d1 %}` is a Liquid *syntax error* without this. The signature
        # is identical on 4.0.4 and 5.13.0, which is the only reason one override serves both.
        #
        # Validated rather than merely allowed: anything that is not a `key: value` list is
        # still refused, so a typo remains a syntax error at PARSE time (where an author sees
        # it in the editor) rather than becoming a silently ignored parameter at render time.
        MARKUP_SYNTAX = /\A(?:\s*\w+\s*:\s*(?:"[^"]*"|'[^']*'|[^\s,]+)\s*,?)*\s*\z/

        def ensure_valid_markup(tag_name, markup, parse_context)
          return if MARKUP_SYNTAX.match?(markup.to_s)

          raise ::Liquid::SyntaxError,
                parse_context.locale.t('errors.syntax.tag_unexpected_args', tag: tag_name)
        end

        # LIQUID 4 SKIPS A BLANK TAG, and `Raw#blank?` answers "is the body empty". So
        # `{% mermaid %}{% endmermaid %}` rendered to NOTHING on 4.0.4 and to a refusal element
        # on 5.13.0 — measured, not guessed. This tag is never blank: a refused diagram is still
        # an element, because a reader looking at a gap cannot tell one from a diagram the author
        # never wrote (INV-4). Found by running the spec under both majors, which is the only
        # thing that could have found it.
        def blank?
          false
        end

        def initialize(tag_name, markup, tokens)
          super
          @params = markup.to_s.scan(PARAM_RE)
                          .each_with_object({}) { |(k, dq, sq, bare), out|
                            out[k.strip] = dq || sq || bare || ''
                          }
        end

        # Liquid 4's entry point.
        def render(context)
          build(context)
        end

        # Liquid 5's entry point. `Raw` overrides this one, so a subclass that defined only
        # `render` would be silently bypassed there and emit the raw body — which is why both
        # exist and why `spec_liquid/` runs this class under both majors.
        def render_to_output_buffer(context, output)
          output << build(context)
          output
        end

        private

        def build(context)
          Budget.from(context).check!('mermaid')

          id = diagram_id
          # THE CAP IS ON THE AUTHOR'S SOURCE, measured BEFORE escaping. Applied afterwards it
          # would shrink by three bytes for every `>` — and Mermaid syntax is mostly arrows, so
          # `mermaid_max_bytes` would mean a different limit for every diagram and a smaller one
          # the more arrows it has. Caught by the AT-the-limit example, which is what those are
          # for.
          raw = raw_source(context)
          return refusal(id, 'too_large') if raw.bytesize > max_bytes(context)
          return refusal(id, 'empty') if raw.strip.empty?

          assets(context) + diagram(id, escape(raw), raw)
        rescue ::Liquid::Error, ArgumentError
          # An authoring mistake. The document keeps rendering — a template with one broken
          # diagram out of four is still three diagrams of report — and the placeholder says a
          # diagram was refused rather than printing why into the paper (INV-5).
          refusal(diagram_id, 'invalid')
        end

        # The author's source, interpolated if asked for and NOT yet escaped. Escaping happens
        # once, at the point of emission, and it is not conditional on `interpolate:` — a raw
        # body needs it too, because `A --> B` carries a `>` that must not close a tag and `-->`
        # would otherwise end an HTML comment. One rule for everything entering the element is
        # the version a later reader cannot get wrong.
        def raw_source(context)
          raw = @body.to_s
          truthy?(@params['interpolate']) ? interpolate(raw, context) : raw
        end

        # Values, not Liquid. See the class comment for why this is not a parse.
        def interpolate(text, context)
          text.gsub(LOOKUP_RE) do
            value = context[::Regexp.last_match(1)]
            # `nil` becomes empty rather than "": a missing lookup should leave the diagram
            # readable rather than inserting a literal.
            value.nil? ? '' : value.to_s
          end
        end

        def escape(text)
          text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end

        # T-38 — "every `SvgRenderer` AND MERMAID output carries `<title>`/`<desc>`".
        #
        # --- WHY THE LABELS TRAVEL AS ATTRIBUTES AND NOT AS SVG ---
        #
        # §Findings F-17, measured: Mermaid draws in the BROWSER on both bindings, so the
        # plugin never holds the SVG — there is no server-side moment in which to add a
        # child element to it. What the plugin CAN do is state the labels where the boot
        # script will find them, which is what these two attributes are. `mermaid_boot.js`
        # inserts them into the SVG once Mermaid has produced one, and leaves Mermaid's own
        # `accTitle:`/`accDescr:` alone if the author used those instead.
        #
        # F-17 also measured that Mermaid emits NO `<title>` and NO `<desc>` in this
        # configuration, so without this there is none — a screen reader announces several
        # hundred unlabelled `<path>` elements, which is the state `SvgRenderer` has a
        # `role="img"` and an `aria-labelledby` to avoid.
        #
        # --- THE DEFAULT TITLE IS THE DIAGRAM'S OWN KEYWORD, IN ITS OWN WORDS ---
        #
        # "Every output carries one" means a diagram with no `title:` needs a default, and
        # the obvious English default is the one thing this cannot be: CLAUDE.md §10 forbids
        # a hardcoded user-facing string, the report body has no locale (`ReportDocument`
        # says why it carries no `lang`), and a `<title>` reading "flowchart diagram" in a
        # Russian report is the bug §10 is about. So the default is Mermaid's OWN first
        # keyword — `flowchart`, `sequenceDiagram`, `gantt` — which is a language-neutral
        # fact about the source rather than a sentence in one language.
        #
        # --- AND THE DEFAULT DESCRIPTION IS NOT HERE AT ALL ---
        #
        # `SvgRenderer`'s `<desc>` carries the numbers, because for a chart the numbers are
        # the content. A diagram's equivalent content is its SOURCE — `A --> B` says what
        # the picture says — and the source is already in the `<pre>`, which is where the
        # boot script reads it from BEFORE Mermaid replaces it. Duplicating it into an
        # attribute would double every diagram's bytes to say the same thing twice.
        # `source` is the ESCAPED body, which is what goes into the `<pre>`. `raw` is the
        # author's, which is what the title is derived from — deriving it from the escaped
        # copy and then escaping the result again is how `&` becomes `&amp;amp;`.
        def diagram(id, source, raw)
          %(<pre class="rrd-mermaid" data-rd-mermaid="#{id}") +
            %( data-rd-mermaid-title="#{attribute(diagram_title(raw))}") +
            authored_desc_attribute +
            %(>\n#{source}\n</pre>)
        end

        # BOUNDED, like the title — and the first version was not, which an independent review
        # found: `MAX_LABEL_CHARS` was applied to `title` only, so a `desc:` was bounded by
        # nothing but the template body. A description is the parameter MOST likely to be long,
        # and the constant's own comment says "short enough that an attribute cannot become the
        # document".
        def authored_desc_attribute
          desc = @params['desc'].to_s.strip
          return '' if desc.empty?

          %( data-rd-mermaid-desc="#{attribute(desc[0, MAX_LABEL_CHARS])}")
        end

        # The author's `title:`, or the diagram's own keyword. BOUNDED, because it lands in
        # an attribute and `title:` is author-supplied like every other parameter.
        # THREE SOURCES, IN THIS ORDER, and the middle one is a review finding.
        #
        #   `title:` on the tag        the author said it here, so it wins.
        #   the diagram's frontmatter  Mermaid 11 renders a `title:` inside a `---` block as the
        #                              diagram's VISIBLE title. Reading it is not a nicety: the
        #                              first version skipped frontmatter entirely to find the
        #                              keyword, so a diagram displaying "Approval flow" got an
        #                              accessible name of "flowchart" — a screen reader and a
        #                              sighted reader given different answers about one picture.
        #   Mermaid's own keyword      the fallback. `flowchart`, `sequenceDiagram`, `gantt`.
        #
        # AND THE FALLBACK IS DELIBERATELY NOT AN ENGLISH SENTENCE. "flowchart diagram" would be
        # a hardcoded user-facing string (CLAUDE.md §10) in a document that has no locale —
        # `ReportDocument` says why it carries no `lang` — so a Russian report would get an
        # English name. Mermaid's keyword is a language-neutral fact about the source.
        def diagram_title(raw_source)
          authored = @params['title'].to_s.strip
          return authored[0, MAX_LABEL_CHARS] unless authored.empty?

          (frontmatter_title(raw_source) || keyword_of(raw_source))[0, MAX_LABEL_CHARS]
        end

        # `title:` inside a `---` … `---` block, which is where Mermaid 11 takes the diagram's
        # visible title from. Nothing else in the frontmatter is read: it is YAML, this is not a
        # YAML parser, and a `title:` line is the only key with a reader here.
        def frontmatter_title(raw_source)
          lines = raw_source.to_s.lines.map(&:strip)
          return nil unless lines.first == '---'

          closing = lines[1..].to_a.index('---')
          return nil if closing.nil?

          line = lines[1, closing].to_a.find { |one| one.start_with?('title:') }
          return nil if line.nil?

          value = line.sub(/\Atitle:\s*/, '').strip.gsub(/\A["']|["']\z/, '')
          value.empty? ? nil : value
        end

        # Mermaid's first keyword. Blank lines, `%%` directives and comments, and an
        # optional `---` YAML frontmatter block are skipped, because all three can legally
        # precede the diagram declaration and none of them is the diagram's kind.
        #
        # ANSWERS `''` RATHER THAN GUESSING when it finds nothing it recognises. An empty
        # title means the boot script writes no `<title>`, which is honest; a made-up one
        # would be a label that describes nothing.
        def keyword_of(raw_source)
          lines = raw_source.to_s.lines.map(&:strip)
          lines = drop_frontmatter(lines)
          line = lines.find { |one| !one.empty? && !one.start_with?('%%') }
          line.to_s[/\A[A-Za-z][A-Za-z0-9_-]*/].to_s
        end

        def drop_frontmatter(lines)
          return lines unless lines.first == '---'

          closing = lines[1..].to_a.index('---')
          closing.nil? ? lines : lines[(closing + 2)..].to_a
        end

        # THE BODY ESCAPER IS NOT ENOUGH FOR AN ATTRIBUTE. `escape` handles `&`, `<` and
        # `>`, which is what a `<pre>`'s content needs; an attribute value also has to
        # survive its own quoting. `PARAM_RE` accepts a single-quoted value, so
        # `title: 'say "hi"'` really can carry a double quote, and both quote forms are
        # escaped rather than one — a rule with an exception is a rule somebody applies
        # inconsistently.
        def attribute(value)
          escape(value.to_s).gsub('"', '&quot;').gsub("'", '&#39;')
        end

        # A REFUSED DIAGRAM IS STILL AN ELEMENT (INV-4). A reader looking at a gap cannot tell a
        # refused diagram from one the author never wrote, and the diagnostics list is
        # downstream of a reader who has already been confused.
        def refusal(id, reason)
          %(<pre class="rrd-mermaid" data-rd-mermaid="#{id}" ) +
            %(data-rd-mermaid-state="refused" data-rd-mermaid-refused="#{reason}"></pre>)
        end

        # `<script src>` rather than inlined bytes, and the difference is 3.5 MB per diagram.
        # Emitted before the FIRST diagram of each render.
        #
        # KEYED ON THE CONTEXT'S IDENTITY, and that is a bug fix rather than a flourish.
        # `registers` does not have the same lifetime on the two majors: on Liquid 4 it belongs
        # to the TEMPLATE and survives every render, on 5.13.0 it does not. A plain boolean
        # therefore meant that on 4.0.4 the SECOND render of a cached template emitted no
        # library at all — every diagram in that report silently undrawn. A `Context` is fresh
        # per render on both majors, so its identity is the one thing that reliably says
        # "same render". Measured under both; nothing about this was visible by reading.
        def assets(context)
          registers = context.registers if context.respond_to?(:registers)
          return emit_assets unless registers.respond_to?(:[]) && registers.respond_to?(:[]=)

          return '' if registers[REGISTER_KEY] == context.object_id

          registers[REGISTER_KEY] = context.object_id
          emit_assets
        end

        def emit_assets
          %(<script src="#{LIBRARY_SRC}"></script>\n) +
            %(<script src="#{BOOT_SRC}"></script>\n)
        end

        def diagram_id
          candidate = @params['id'].to_s
          ID_PATTERN.match?(candidate) ? candidate : 'mermaid'
        end

        # The cap is a POLICY value where one is bound and a constant otherwise, so a widget
        # render and a report render can differ without this tag knowing which it is in.
        def max_bytes(context)
          policy = context.registers[:rrd_execution_policy] if context.respond_to?(:registers) &&
                                                               context.registers.is_a?(Hash)
          limit = policy.respond_to?(:mermaid_max_bytes) ? policy.mermaid_max_bytes : nil
          Integer(limit || DEFAULT_MAX_BYTES)
        rescue ArgumentError, TypeError
          DEFAULT_MAX_BYTES
        end

        def truthy?(value)
          %w[true yes 1].include?(value.to_s.strip.downcase)
        end
      end
    end
  end
end
