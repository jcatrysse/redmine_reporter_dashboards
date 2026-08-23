# frozen_string_literal: true

require_relative '../lib/redmine_reporter_dashboards/liquid/tags/mermaid_tag'

# T-35 — `{% mermaid %}`, against the REAL Liquid gem, under both majors.
#
# It lives in `spec_liquid/` rather than `spec/` because everything worth asserting about this
# tag is a property of Liquid itself: that `Liquid::Raw`'s parse captures a body containing `{`
# and `|` verbatim, and that the render entry point differs between 4 and 5 — Liquid 4 calls
# `render`, Liquid 5 calls `render_to_output_buffer`, and `Raw` overrides only the second, so a
# subclass defining only the first is silently bypassed on one major and emits the raw body.
# The stub Liquid in `spec/spec_helper.rb` could not catch either.
module RedmineReporterDashboards
  module Liquid
    RSpec.describe Tags::MermaidTag do
      before { ::Liquid::Template.register_tag('mermaid', described_class) }

      def render(template, assigns = {})
        ::Liquid::Template.parse(template).render(assigns)
      end

      FLOW = "graph LR\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]"

      # ------------------------------------------------------------------
      describe 'the body is RAW' do
        it 'keeps braces and pipes that Liquid would otherwise read as markup' do
          # `B{Choice}` and `-->|yes|` are ordinary Mermaid and would not survive Liquid.
          out = render("{% mermaid id: d1 %}#{FLOW}{% endmermaid %}")

          expect(out).to include('A[Start] --&gt; B{Choice}')
          expect(out).to include('B --&gt;|yes| C[Done]')
        end

        it 'does NOT evaluate Liquid in the body by default' do
          out = render('{% mermaid %}graph LR{{ secret }}{% endmermaid %}', 'secret' => 'LEAKED')

          expect(out).to include('{{ secret }}')
          expect(out).not_to include('LEAKED')
        end

        it 'does not execute a tag in the body' do
          out = render('{% mermaid %}graph LR{% assign x = 1 %}{% endmermaid %}')

          expect(out).to include('{% assign x = 1 %}')
        end

        # ESCAPED ALWAYS, not only when interpolated. `-->` would otherwise close an HTML
        # comment and `>` would close a tag, so a raw author body needs it too — one rule
        # rather than a rule with an exception.
        it 'escapes &, < and > on the way into the <pre>' do
          out = render('{% mermaid %}graph LR
  A["a & b"] --> B["<c>"]{% endmermaid %}')

          expect(out).to include('&amp;')
          expect(out).to include('&lt;c&gt;')
          expect(out).not_to include('<c>')
        end
      end

      # ------------------------------------------------------------------
      # The one place bytes that are NOT the author's reach a diagram, and after F-17 dropped
      # the SVG sanitiser it is the only control on that path.
      describe 'interpolate: true' do
        it 'substitutes a value from the context' do
          out = render('{% mermaid interpolate: true %}graph LR
  A[{{ name }}] --> B{% endmermaid %}', 'name' => 'Sprint 4')

          expect(out).to include('A[Sprint 4]')
        end

        it 'ESCAPES the substituted value, which is the security line' do
          out = render('{% mermaid interpolate: true %}graph LR
  A[{{ subject }}]{% endmermaid %}',
                       'subject' => '<script>alert(1)</script>')

          expect(out).not_to include('<script>')
          expect(out).to include('&lt;script&gt;')
        end

        it 'substitutes VALUES and still does not execute Liquid' do
          # A diagram is not a place for control flow. Refusing tags here means an
          # interpolated diagram cannot reach a filter, a drop method or another tag.
          out = render('{% mermaid interpolate: true %}graph LR
  {% assign x = 1 %}A[{{ name | upcase }}]{% endmermaid %}', 'name' => 'x')

          expect(out).to include('{% assign x = 1 %}')
          expect(out).to include('{{ name | upcase }}'), 'a filter is not a lookup'
        end

        it 'renders a missing lookup as nothing rather than as a literal' do
          out = render('{% mermaid interpolate: true %}graph LR
  A[{{ absent }}]{% endmermaid %}')

          expect(out).to include('A[]')
          expect(out).not_to include('absent')
        end

        it 'is off for any value that is not true/yes/1' do
          %w[false no 0 maybe].each do |value|
            out = render(%({% mermaid interpolate: #{value} %}graph LR
  A[{{ name }}]{% endmermaid %}), 'name' => 'X')

            expect(out).to include('{{ name }}'), value
          end
        end
      end

      # ------------------------------------------------------------------
      describe 'the emitted markup' do
        it 'is a <pre> carrying the id the boot script selects on' do
          out = render("{% mermaid id: flow1 %}#{FLOW}{% endmermaid %}")

          # NOT `…="flow1">`. T-38 added the accessibility labels after this attribute, so
          # asserting the closing `>` here would be asserting the attribute ORDER of an
          # element whose order carries no meaning.
          expect(out).to include('<pre class="rrd-mermaid" data-rd-mermaid="flow1"')
        end

        it 'falls back to a safe id rather than escaping a hostile one' do
          # RESTRICTED rather than escaped, the same rule `ChartSpec` applies: there is then
          # nothing to get wrong later when the id lands in an attribute.
          ['<script>', '1leading', '', 'a b', 'a;b'].each do |bad|
            out = render(%({% mermaid id: "#{bad}" %}#{FLOW}{% endmermaid %}))

            expect(out).to include('data-rd-mermaid="mermaid"'), bad.inspect
            expect(out).not_to include(bad) if bad.length > 2
          end
        end

        it 'refuses malformed MARKUP at parse time, where an author can see it' do
          # `Liquid::Raw::Syntax` is `/\A\s*\z/`, so the override has to widen it — and it
          # widens to a `key: value` list and no further. A bare word is a syntax error at PARSE
          # time, which an author sees in the editor, rather than a silently ignored parameter
          # discovered when a diagram does not appear.
          ['nonsense', 'id', 'id:', '= 1'].each do |markup|
            expect { render(%({% mermaid #{markup} %}#{FLOW}{% endmermaid %})) }
              .to raise_error(::Liquid::SyntaxError), markup.inspect
          end
        end

        it 'accepts the quoting forms an author actually writes' do
          ['id: d1', 'id: "d1"', "id: 'd1'", 'id: d1, interpolate: true',
           '  id: d1   interpolate: true  '].each do |markup|
            expect { render(%({% mermaid #{markup} %}#{FLOW}{% endmermaid %})) }
              .not_to raise_error, markup.inspect
          end
        end

        it 'references the library and the boot script ONCE for several diagrams' do
          # The library is 3.5 MB. Per-diagram emission would multiply that by the diagram
          # count, which is why the register exists.
          out = render("{% mermaid id: a %}#{FLOW}{% endmermaid %}" \
                       "{% mermaid id: b %}#{FLOW}{% endmermaid %}" \
                       "{% mermaid id: c %}#{FLOW}{% endmermaid %}")

          expect(out.scan('vendor/mermaid.min.js').length).to eq(1)
          expect(out.scan('mermaid_boot.js').length).to eq(1)
          expect(out.scan('data-rd-mermaid=').length).to eq(3)
        end

        it 'references the plugin asset root-relative, never a CDN' do
          out = render("{% mermaid %}#{FLOW}{% endmermaid %}")

          expect(out).to include('src="/plugin_assets/redmine_reporter_dashboards/javascripts/vendor/mermaid.min.js"')
          expect(out).not_to match(%r{https?://})
        end

        # THE CROSS-MAJOR DEFECT THIS FILE EXISTS FOR. `registers` belongs to the TEMPLATE on
        # Liquid 4 and survives every render; on 5.13.0 it does not. A plain boolean flag
        # therefore meant the SECOND render of a cached template emitted no library at all on
        # 4.0.4 — every diagram in that report silently undrawn. Keying on the Context's
        # identity fixes it, because a Context is fresh per render on both majors.
        it 'emits the assets on EVERY render of the same template, not just the first' do
          template = ::Liquid::Template.parse("{% mermaid %}#{FLOW}{% endmermaid %}")

          3.times do |n|
            expect(template.render.scan('mermaid.min.js').length).to eq(1), "render #{n + 1}"
          end
        end
      end

      # ------------------------------------------------------------------
      # T-38 — the accessibility labels, on the RUBY side.
      #
      # THIS BLOCK EXISTS BECAUSE IT DID NOT, and an independent review said so plainly: the
      # change added `diagram_title`, `keyword_of`, `frontmatter_title`, `attribute` and
      # `authored_desc_attribute` and tested none of them. What coverage there was lived in
      # `spec/charts/mermaid_boot_spec.rb`, whose harness WRITES the title attribute itself —
      # so it proved everything about the JavaScript and nothing about the tag emitting one.
      #
      # `spec_liquid/` and not `spec/`, for this file's own reason: the params come from a real
      # `Liquid::Raw` parse of real markup, and the stub cannot do that.
      describe 'the accessibility labels (T-38, FR-76)' do
        def head_of(out)
          out[/<pre[^>]*>/].to_s
        end

        def title_in(out)
          head_of(out)[/data-rd-mermaid-title="([^"]*)"/, 1]
        end

        def desc_in(out)
          head_of(out)[/data-rd-mermaid-desc="([^"]*)"/, 1]
        end

        it 'carries the author\'s title' do
          out = render(%({% mermaid id: d1, title: "Approval flow" %}#{FLOW}{% endmermaid %}))

          expect(title_in(out)).to eq('Approval flow')
        end

        it 'carries the author\'s desc, and omits the attribute when there is none' do
          with = render(%({% mermaid desc: "Draft to review" %}#{FLOW}{% endmermaid %}))
          without = render("{% mermaid %}#{FLOW}{% endmermaid %}")

          expect(desc_in(with)).to eq('Draft to review')
          expect(head_of(without)).not_to include('data-rd-mermaid-desc')
        end

        # NO `desc` ATTRIBUTE IS THE DESIGN, not an omission: `mermaid_boot.js` falls back to
        # the `<pre>`'s own text, which IS the diagram's description, and duplicating 16 KiB of
        # source into an attribute to say the same thing twice would double every diagram.
        it 'leaves the description to the source when the author gave none' do
          expect(head_of(render("{% mermaid %}#{FLOW}{% endmermaid %}")))
            .not_to include('data-rd-mermaid-desc')
        end

        describe 'the default title, which is Mermaid\'s own keyword' do
          {
            "graph LR\n  A --> B" => 'graph',
            "flowchart TD\n  A --> B" => 'flowchart',
            "sequenceDiagram\n  A->>B: hi" => 'sequenceDiagram',
            "stateDiagram-v2\n  [*] --> S" => 'stateDiagram-v2',
            "gantt\n  title X" => 'gantt',
            "pie title Split\n  \"a\" : 1" => 'pie',
            "%%{init: {} }%%\nclassDiagram\n  A <|-- B" => 'classDiagram',
            "\n\n  journey\n  title X" => 'journey'
          }.each do |source, keyword|
            it "reads #{keyword.inspect} out of #{source.lines.first.strip.inspect}" do
              expect(title_in(render("{% mermaid %}#{source}{% endmermaid %}"))).to eq(keyword)
            end
          end

          # A REVIEW FINDING. Mermaid 11 renders a frontmatter `title:` as the diagram's VISIBLE
          # title, and the first version skipped the whole block looking for the keyword — so a
          # diagram displaying "Approval flow" announced itself as "flowchart". A screen reader
          # and a sighted reader given different answers about one picture is worse than a
          # generic name.
          it 'prefers a frontmatter title, because that is what Mermaid draws' do
            source = "---\ntitle: Approval flow\n---\nflowchart LR\n  A --> B"

            expect(title_in(render("{% mermaid %}#{source}{% endmermaid %}")))
              .to eq('Approval flow')
          end

          it 'still prefers the tag\'s own title over the frontmatter' do
            source = "---\ntitle: From the diagram\n---\nflowchart LR\n  A --> B"

            expect(title_in(render(%({% mermaid title: "From the tag" %}#{source}{% endmermaid %}))))
              .to eq('From the tag')
          end

          it 'falls through to the keyword past a frontmatter with no title' do
            source = "---\nconfig:\n  theme: neutral\n---\nsequenceDiagram\n  A->>B: hi"

            expect(title_in(render("{% mermaid %}#{source}{% endmermaid %}")))
              .to eq('sequenceDiagram')
          end

          # ANSWERS NOTHING RATHER THAN GUESSING. An unterminated frontmatter block and a body
          # of only comments both leave the keyword unfindable, and an empty title means the
          # boot script writes no `<title>` — which is honest. A made-up one would be a label
          # describing nothing, and T-38's "every Mermaid output carries a `<title>`" is
          # therefore true of every diagram whose kind can be read and no others. Recorded here
          # rather than left for a reader to discover.
          it 'answers an empty title when it cannot tell what the diagram is' do
            unterminated = "---\ntitle: never closed\nflowchart LR\n  A --> B"
            comments_only = "%% just a comment\n%% and another"

            expect(title_in(render("{% mermaid %}#{unterminated}{% endmermaid %}"))).to eq('')
            expect(title_in(render("{% mermaid %}#{comments_only}{% endmermaid %}"))).to eq('')
          end
        end

        describe 'escaping, for ATTRIBUTE position rather than element content' do
          # The body escaper handles `&`, `<` and `>`, which is what a `<pre>`'s content needs.
          # An attribute value also has to survive its own quoting, and `PARAM_RE` accepts a
          # single-quoted value — so `title: 'say "hi"'` really can carry a double quote.
          it 'escapes both quote forms as well as the three markup characters' do
            out = render(%({% mermaid title: '&<>"x' %}#{FLOW}{% endmermaid %}))

            expect(title_in(out)).to eq('&amp;&lt;&gt;&quot;x')
          end

          it 'cannot break out of the attribute with a tag' do
            out = render(%({% mermaid title: '"><script>x</script>' %}#{FLOW}{% endmermaid %}))

            expect(out).not_to include('<script>')
            expect(head_of(out)).to include('&quot;&gt;&lt;script&gt;')
          end

          it 'escapes a single quote too, so a single-quoted attribute would survive as well' do
            expect(title_in(render(%({% mermaid title: "it's" %}#{FLOW}{% endmermaid %}))))
              .to eq('it&#39;s')
          end

          # ESCAPED ONCE, NOT TWICE. The title is derived from the RAW body and escaped at
          # emission; deriving it from the already-escaped copy would turn `&` into `&amp;amp;`.
          it 'does not double-escape' do
            expect(title_in(render(%({% mermaid title: "a & b" %}#{FLOW}{% endmermaid %}))))
              .to eq('a &amp; b')
          end

          # THE SAME PROPERTY FOR THE DERIVED TITLE, and it took a surviving mutation to
          # notice: passing the tag the ESCAPED body instead of the raw one changed nothing in
          # any example, because a keyword and every fixture's frontmatter title were plain
          # ASCII. A frontmatter title with an `&` in it is the case that tells them apart.
          it 'does not double-escape a title it read out of the frontmatter either' do
            source = "---\ntitle: R&D <team>\n---\nflowchart LR\n  A --> B"

            expect(title_in(render("{% mermaid %}#{source}{% endmermaid %}")))
              .to eq('R&amp;D &lt;team&gt;')
          end
        end

        # AT the limit and one past it, on BOTH labels — and `desc` is here because it was
        # UNBOUNDED in the first version. `MAX_LABEL_CHARS` was applied to the title only, so a
        # description was bounded by nothing but the template body, which is the parameter most
        # likely to be long. Found by an independent review.
        describe 'the label cap' do
          let(:cap) { described_class::MAX_LABEL_CHARS }

          it 'passes a title AT the cap through and truncates one past it' do
            at = 'x' * cap
            expect(title_in(render(%({% mermaid title: "#{at}" %}#{FLOW}{% endmermaid %})))).to eq(at)
            expect(title_in(render(%({% mermaid title: "#{at}y" %}#{FLOW}{% endmermaid %}))).length)
              .to eq(cap)
          end

          # THE DERIVED TITLE IS CAPPED TOO, and only the AUTHORED one was tested until a
          # mutation survived: removing the cap from the frontmatter/keyword branch changed
          # nothing, because every fixture's derived title was short. A frontmatter title is
          # author-supplied like any other parameter.
          it 'caps a title derived from the frontmatter, not only one given on the tag' do
            long = 'F' * (cap + 40)
            source = "---\ntitle: #{long}\n---\nflowchart LR\n  A --> B"

            expect(title_in(render("{% mermaid %}#{source}{% endmermaid %}")).length).to eq(cap)
          end

          it 'caps the desc as well, which it did not' do
            over = 'd' * (cap + 50)

            expect(desc_in(render(%({% mermaid desc: "#{over}" %}#{FLOW}{% endmermaid %}))).length)
              .to eq(cap)
          end

          # The cap is on CHARACTERS, so a multi-byte label cannot be cut in half — and it is
          # applied BEFORE escaping, so it cannot cut an entity in half either.
          it 'truncates characters rather than bytes, and never mid-entity' do
            out = render(%({% mermaid title: "#{'é' * (described_class::MAX_LABEL_CHARS + 5)}" %}#{FLOW}{% endmermaid %}))

            expect(title_in(out).length).to eq(described_class::MAX_LABEL_CHARS)
            expect(title_in(out)).not_to include('&am')
          end
        end

        # A REFUSED DIAGRAM HAS NO SVG, so there is nothing to label and no attribute is
        # emitted. Asserted so the absence is a decision rather than a gap.
        it 'writes no labels on a refused diagram' do
          out = render('{% mermaid %}{% endmermaid %}')

          expect(out).to include('data-rd-mermaid-refused="empty"')
          expect(out).not_to include('data-rd-mermaid-title')
        end
      end

      # ------------------------------------------------------------------
      describe 'the source cap' do
        # AT the limit and ONE PAST it — and the diagram deliberately contains arrows, because
        # the first implementation capped the ESCAPED source and every `>` cost three bytes of
        # an author's allowance. `mermaid_max_bytes` has to mean the same number whatever the
        # diagram is made of.
        it 'accepts a diagram AT mermaid_max_bytes and refuses one byte past it' do
          cap = described_class::DEFAULT_MAX_BYTES
          arrows = "graph LR\n" + ('  A[x] --> B[y]\n' * 40)
          at = arrows + (' ' * (cap - arrows.bytesize))
          expect(at.bytesize).to eq(cap)
          expect(at).to include('-->'), 'the arrows are the point of this example'

          expect(render("{% mermaid %}#{at}{% endmermaid %}"))
            .to include('data-rd-mermaid="mermaid"')

          out = render("{% mermaid %}#{at} {% endmermaid %}")
          expect(out).to include('data-rd-mermaid-refused="too_large"')
        end

        it 'refuses an empty diagram rather than emitting an empty <pre>' do
          expect(render('{% mermaid %}{% endmermaid %}'))
            .to include('data-rd-mermaid-refused="empty"')
          expect(render("{% mermaid %}   \n  {% endmermaid %}"))
            .to include('data-rd-mermaid-refused="empty"')
        end

        # INV-4: a reader looking at a gap cannot tell a refused diagram from one the author
        # never wrote, so a refusal is still an element.
        it 'emits an element even when refused, and says why in an attribute not in the paper' do
          out = render('{% mermaid %}{% endmermaid %}')

          expect(out).to include('<pre class="rrd-mermaid"')
          expect(out).to include('data-rd-mermaid-state="refused"')
        end
      end

      # ------------------------------------------------------------------
      describe 'both Liquid majors' do
        # Liquid 4 SKIPS a tag whose `blank?` is true, and `Raw#blank?` answers "is the body
        # empty" — so an empty diagram rendered to NOTHING on 4.0.4 and to a refusal element on
        # 5.13.0. A refused diagram is still an element (INV-4).
        #
        # Asserted through a RENDER rather than by instantiating the tag, because
        # `Liquid::Tag.new` is private on 4.0.4 and public on 5.13.0 — the visibility difference
        # HANDOVER §Findings E-7 already records. The override is also pinned by name, so
        # deleting it fails a test rather than only changing one major's output.
        it 'is never blank, so an empty diagram is not skipped by Liquid 4' do
          expect(described_class.instance_methods(false)).to include(:blank?)
          expect(render('{% mermaid %}{% endmermaid %}'))
            .to include('data-rd-mermaid-state="refused"')
        end

        it 'defines BOTH render entry points, because the two majors call different ones' do
          # Liquid 4 calls `render`; Liquid 5 calls `render_to_output_buffer`, which `Raw`
          # overrides — so a subclass with only `render` emits the RAW BODY on Liquid 5 and
          # every assertion above would pass on one major and fail on the other.
          expect(described_class.instance_methods(false)).to include(:render,
                                                                    :render_to_output_buffer)
        end

        it 'produces identical output through whichever entry point this major uses' do
          # Not a tautology: it asserts the two implementations agree, which is the property
          # that decays if somebody edits one of them.
          out = render("{% mermaid id: d %}#{FLOW}{% endmermaid %}")

          expect(out).to include('data-rd-mermaid="d"')
          expect(out).not_to include('{% raw %}')
        end

        it 'inherits Raw\'s parse rather than reimplementing it against two tokenizers' do
          expect(described_class.superclass).to eq(::Liquid::Raw)
          expect(described_class.instance_methods(false)).not_to include(:parse)
        end
      end
    end
  end
end
