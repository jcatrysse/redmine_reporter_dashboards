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

          expect(out).to include('<pre class="rrd-mermaid" data-rd-mermaid="flow1">')
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
            .to include('data-rd-mermaid="mermaid">')

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
