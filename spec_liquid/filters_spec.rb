# frozen_string_literal: true

# T-19's filter spec. Real gem, both majors — see `spec_liquid/README.md`.
#
# Three things here are not behaviour tests and matter more than the behaviour tests:
#
#   THE INVENTORY. `Filters::OWNED` / `REMOVED` / `INHERITED` / `DEFERRED` are §3.6's
#   decisions in executable form, and each is asserted. A security removal nobody checks
#   is a security removal somebody re-adds as a convenience six months later, and the
#   reason would not be in the diff.
#
#   THE `StandardFilters` ENUMERATION. T-19's Accept list asks for it explicitly: *"a
#   StandardFilters enumeration spec so a Liquid upgrade adding a filter is a CI failure
#   rather than a silent capability grant."* Liquid 5 added `find`, `has`, `reject`,
#   `sum`, `squish`, `base64_*` and six more since 4.0.4. Every one of those became
#   available to every template in this plugin without anybody deciding it should be.
#   The list below is PINNED per version; an unpinned version fails and prints what to
#   paste in, so the grant is a decision rather than a side effect of `bundle update`.
#
#   NOT GLOBAL. The gem registers four filter modules at require time and monkey-patches
#   `to_number` into `StandardFilters`. Asserted absent, because that is a property of
#   the whole process and no amount of care inside this plugin would restore it.

require 'liquid'

require_relative 'support/drop_fakes'
require_relative '../lib/redmine_reporter_dashboards/liquid/filters'
require_relative '../lib/redmine_reporter_dashboards/liquid/drops'

module RedmineReporterDashboards
  module Liquid
    RSpec.describe Filters do
      before do
        skip 'run with the real gem: rspec -r liquid spec_liquid' unless defined?(::Liquid::VERSION)
      end

      # Rendered through a real template with the owned modules added per render, which is
      # exactly how `TemplateRenderer` does it. Calling the module methods directly would
      # prove the arithmetic and not the registration.
      def render(source, assigns = {})
        template = ::Liquid::Template.parse(source, error_mode: :strict)
        context = ::Liquid::Context.new([stringify(assigns)], {}, {}, true)
        context.add_filters(Filters.modules)
        template.render(context)
      end

      def stringify(hash)
        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      # ----------------------------------------------------------------
      # The inventory
      # ----------------------------------------------------------------

      describe 'the inventory (§3.6)' do
        it 'registers exactly the filters OWNED claims, and no others' do
          expect(Filters.registered_names).to eq(Filters.owned_names.sort)
        end

        it 'gives every owned filter a reason somebody can read' do
          Filters::OWNED.each do |name, reason|
            expect(reason.to_s.length).to be > 15, "#{name} has no stated purpose"
          end
        end

        it 'registers none of the filters REMOVED for a security reason' do
          %w[call_method regex_replace regex_replace_once md5 file_url].each do |name|
            expect(Filters.registered_names).not_to include(name),
                                                    "#{name} is back: #{Filters::REMOVED[name]}"
          end
        end

        it 'registers none of the non-deterministic filters — a report may be an audit record' do
          %w[random shuffle].each { |name| expect(Filters.registered_names).not_to include(name) }
        end

        it 'registers none of the mutating filters' do
          %w[push pop shift unshift].each { |name| expect(Filters.registered_names).not_to include(name) }
        end

        it 'states the reason for every removal' do
          Filters::REMOVED.each do |name, reason|
            expect(reason.to_s.length).to be > 10, "#{name} was removed with no reason given"
          end
        end

        # `| inline` is on §3.6's list and is deliberately absent. Asserted so it cannot be
        # added here by accident: T-33 owns `asset_policy`, and a second embedding path
        # that does not consult it is the exact shape T-33's acceptance list forbids.
        it 'defers `inline` to the task that owns the policy it must obey' do
          expect(Filters::DEFERRED).to have_key('inline')
          expect(Filters::DEFERRED['inline']).to include('T-33')
          expect(Filters.registered_names).not_to include('inline')
        end
      end

      # ----------------------------------------------------------------
      # StandardFilters — the enumeration T-19 asks for
      # ----------------------------------------------------------------

      describe "Liquid's own filter surface" do
        # Regenerate with:
        #   ruby -rliquid -e 'puts Liquid::StandardFilters.public_instance_methods(false).sort'
        PINNED = {
          '4.0.4' => %w[abs append at_least at_most capitalize ceil compact concat date default
                        divided_by downcase escape escape_once first floor h join last lstrip map
                        minus modulo newline_to_br plus prepend remove remove_first replace
                        replace_first reverse round rstrip size slice sort sort_natural split strip
                        strip_html strip_newlines times truncate truncatewords uniq upcase url_decode
                        url_encode where].freeze,
          '5.13.0' => %w[abs append at_least at_most base64_decode base64_encode
                         base64_url_safe_decode base64_url_safe_encode capitalize ceil compact concat
                         date default divided_by downcase escape escape_once find find_index first
                         floor h has join last lstrip map minus modulo newline_to_br plus prepend
                         reject remove remove_first remove_last replace replace_first replace_last
                         reverse round rstrip size slice sort sort_natural split squish strip
                         strip_html strip_newlines sum times truncate truncatewords uniq upcase
                         url_decode url_encode where].freeze
        }.freeze

        let(:actual) { ::Liquid::StandardFilters.public_instance_methods(false).map(&:to_s).sort }

        it 'is exactly what this project has looked at' do
          expected = PINNED[::Liquid::VERSION]

          # An UNPINNED version is a failure, not a skip. That is the whole point: a
          # `bundle update` that brings new filters must not grant a template new
          # capabilities silently, so the run stops and says what to read.
          expect(expected).not_to be_nil,
                                  "Liquid #{::Liquid::VERSION} has not been reviewed. Its filters " \
                                  "are:\n#{actual.join(' ')}\nAdd them to PINNED once somebody has " \
                                  'decided each new one is acceptable template surface.'

          expect(actual).to eq(expected),
                            "Liquid #{::Liquid::VERSION}'s filter surface moved.\n" \
                            "added:   #{(actual - expected).inspect}\n" \
                            "removed: #{(expected - actual).inspect}"
        end

        # The one patch the gem makes globally, asserted absent. `to_number` is private
        # there, so `private_instance_methods` is where it would show.
        it 'has not been monkey-patched with the gem\'s private to_number' do
          all = ::Liquid::StandardFilters.private_instance_methods(false) +
                ::Liquid::StandardFilters.public_instance_methods(false)
          expect(all.map(&:to_s)).not_to include('to_number')
        end

        # `strict_filters`, because Liquid's DEFAULT for an unknown filter is to pass the
        # input straight through — so `{{ 5 | json }}` renders "5" whether or not `json`
        # exists, and an assertion on the output would pass either way. This example needs
        # to tell "not registered" from "registered and harmless", and only the strict mode
        # can.
        it 'has no filter registered globally by this plugin' do
          strict = ::Liquid::Context.new([{}], {}, {}, true)
          strict.strict_filters = true

          expect { ::Liquid::Template.parse('{{ 5 | json }}').render(strict) }
            .to raise_error(::Liquid::UndefinedFilter)
        end

        # THE OVERLAP, stated rather than discovered — and it is DIFFERENT PER MAJOR,
        # which is the whole of OQ-C in one assertion.
        #
        # On Liquid 4 there is no overlap at all: `sum` does not exist there, so the owned
        # one is the only `sum` a template can reach. On Liquid 5 it does, so the owned one
        # shadows it — deliberately, and reproducing Liquid 5's semantics exactly, so a
        # template prints the same number on both majors and an install that upgrades
        # Liquid sees no change.
        #
        # Anything else appearing here would be an accidental shadowing of a core filter,
        # which is why the assertion is an equality rather than an `include`.
        it 'shadows Liquid only where it has to, and the set depends on the major' do
          overlap = Filters.registered_names & actual

          if actual.include?('sum')
            expect(overlap).to eq(['sum']),
                               "expected to shadow only `sum` on Liquid #{::Liquid::VERSION}"
          else
            expect(overlap).to eq([]),
                               "Liquid #{::Liquid::VERSION} has no `sum`, so nothing should be shadowed"
          end
        end

        # And the property that makes the shadowing safe to have at all: the same template
        # gives the same answer on both majors. Without the owned `sum`, this raises on
        # Liquid 4 under `strict_filters` and answers 5 on Liquid 5.
        it 'answers `sum` identically on both majors, which is why it is owned' do
          expect(render('{{ rows | sum: "h" }}', rows: [{ 'h' => 2 }, { 'h' => 3 }])).to eq('5')
        end

        # LINTABLE_REMOVED drives an :error rule per name. If one of them were a filter
        # Liquid provides, the linter would tell an author to stop using a documented
        # Liquid filter — the worst kind of false positive.
        it 'shares no name with LINTABLE_REMOVED, so no lint rule can fire on a core filter' do
          expect(Filters::LINTABLE_REMOVED & actual).to eq([])
        end
      end

      # ----------------------------------------------------------------
      # Inherited rather than reimplemented — OQ-C, measured
      # ----------------------------------------------------------------

      describe 'the inherited filters (OQ-C)' do
        let(:actor) { DropFakes::User.new(id: 1, login: 'a', name: 'A') }
        let(:context) { RenderContext.new(actor: actor) }
        let(:issues) do
          [{ id: 1, subject: 'one', done_ratio: 10, estimated_hours: 2.0 },
           { id: 2, subject: 'two', done_ratio: 50, estimated_hours: 3.0 },
           { id: 3, subject: 'three', done_ratio: 50, estimated_hours: nil }]
            .map { |attrs| Drops::IssueDrop.new(DropFakes::Record.new(attrs), context: context) }
        end

        # This is what makes "inherited" a tested claim rather than an assumption about a
        # gem we do not control: Liquid's `where` reads through `Drop#[]`, which is the same
        # boundary `Support.read` uses, so it already works on the owned drops.
        it "Liquid's own `where` works on a drop, which is why we do not ship one" do
          expect(render('{{ issues | where: "done_ratio", 50 | map: "subject" | join: "," }}',
                        issues: issues)).to eq('two,three')
        end

        it "Liquid's own `where` with one argument keeps the rows where the property is set" do
          expect(render('{{ issues | where: "estimated_hours" | size }}', issues: issues)).to eq('2')
        end

        it "Liquid's own `map` reads a drop property" do
          expect(render('{{ issues | map: "id" | join: "-" }}', issues: issues)).to eq('1-2-3')
        end

        it "Liquid's own `sort_natural` is identical on both majors" do
          expect(render('{{ list | sort_natural | join: "," }}', list: %w[b10 b9 a2]))
            .to eq('a2,b10,b9')
        end

        it "§3.6's `replace_all` is Liquid's own `replace`" do
          expect(render('{{ "a-b-c" | replace: "-", "+" }}')).to eq('a+b+c')
        end
      end

      # ----------------------------------------------------------------
      # Behaviour
      # ----------------------------------------------------------------

      describe 'aggregates' do
        let(:rows) { [{ 'h' => 2 }, { 'h' => nil }, { 'h' => 4 }, { 'h' => 'not a number' }] }

        it 'averages the numbers and ignores the rest' do
          # 3.0, not 1.5: a nil estimate is a field nobody filled in, not a zero.
          expect(render('{{ rows | avg: "h" }}', rows: rows)).to eq('3')
        end

        it 'takes a median, which is not the mean' do
          expect(render('{{ list | median }}', list: [1, 2, 100])).to eq('2')
        end

        it 'averages the two middle values for an even count' do
          expect(render('{{ list | median }}', list: [1, 2, 3, 4])).to eq('2.5')
        end

        it 'answers min and max over a property' do
          expect(render('{{ rows | min: "h" }}/{{ rows | max: "h" }}', rows: rows)).to eq('2/4')
        end

        it 'answers nothing rather than zero for an empty input' do
          expect(render('[{{ list | avg }}][{{ list | median }}][{{ list | min }}]', list: [])).to eq('[][][]')
        end

        # `sum` differs from its four neighbours on purpose — it reproduces Liquid 5's
        # semantics so an install upgrading Liquid sees no change in a printed number.
        it 'sums with Liquid 5 semantics: zero for empty, non-numbers as zero' do
          expect(render('{{ list | sum }}', list: [])).to eq('0')
          expect(render('{{ rows | sum: "h" }}', rows: rows)).to eq('6')
        end

        it 'keeps an integer an integer' do
          expect(render('{{ list | sum }}/{{ list | avg }}', list: [2, 4])).to eq('6/3')
        end

        it 'does not coerce a non-numeric string into a measurement' do
          expect(render('{{ list | avg }}', list: ['12 hours', '4'])).to eq('4')
        end
      end

      describe 'formatting' do
        it 'groups thousands and keeps two places' do
          expect(render('{{ n | currency: "€" }}', n: 1_234.5)).to eq('€1,234.50')
        end

        it 'formats a negative amount with the sign outside the grouping' do
          expect(render('{{ n | currency }}', n: -1_234.5)).to eq('-1,234.50')
        end

        it 'takes a precision, for a currency without decimals' do
          # 1,235 and not 1,234: `Float#round` is half-up. printf's `%.0f` rounds half to
          # EVEN, which would round half a report's amounts down and half up.
          expect(render('{{ n | currency: "¥", 0 }}', n: 1_234.5)).to eq('¥1,235')
        end

        it 'answers nothing for something that is not a number' do
          expect(render('[{{ n | currency }}]', n: 'lots')).to eq('[]')
        end

        it 'formats hours as decimal by default' do
          expect(render('{{ h | duration }}', h: 3.5)).to eq('3.50')
        end

        it 'formats hours as h:mm when asked' do
          expect(render('{{ h | duration: "minutes" }}', h: 3.5)).to eq('3:30')
        end

        # The formatter is absent outside Redmine, and that is a DEGRADATION rather than a
        # silent pass-through: unrendered `h1.` in a document is a defect the reader can
        # see and the diagnostics channel should have named.
        it 'escapes and degrades visibly when Redmine\'s wiki formatter is absent' do
          context = RenderContext.new(actor: DropFakes::User.new(id: 1, login: 'a', name: 'A'))
          template = ::Liquid::Template.parse('{{ text | wiki }}')
          liquid_context = ::Liquid::Context.new(
            [{ 'text' => 'a <b>bold</b> claim' }], {},
            { RenderContext::REGISTER_KEY => context }, true
          )
          liquid_context.add_filters(Filters.modules)

          expect(template.render(liquid_context)).to eq('a &lt;b&gt;bold&lt;/b&gt; claim')
          expect(context.diagnostics).to be_include(:wiki_unavailable)
        end
      end

      describe 'colors' do
        it 'normalises the three spellings to one' do
          expect(render('{{ "abc" | hex_color }}/{{ "#AABBCC" | hex_color }}')).to eq('#aabbcc/#aabbcc')
        end

        # Never a default colour: a black swatch for a typo costs an author an afternoon.
        it 'answers nothing for anything that is not a colour' do
          expect(render('[{{ "nope" | hex_color }}][{{ "#12345" | hex_color }}]')).to eq('[][]')
        end

        # Luminance, not the channel average — the average puts white on green and black
        # on blue, both the wrong way round.
        it 'picks readable text by luminance rather than by average' do
          expect(render('{{ "#00ff00" | contrasting_text_color }}')).to eq('#000000')
          expect(render('{{ "#0000ff" | contrasting_text_color }}')).to eq('#ffffff')
          expect(render('{{ "#ffffff" | contrasting_text_color }}')).to eq('#000000')
          expect(render('{{ "#000000" | contrasting_text_color }}')).to eq('#ffffff')
        end

        it 'moves toward black and toward white by the remaining distance' do
          expect(render('{{ "#808080" | darken: 50 }}')).to eq('#404040')
          expect(render('{{ "#808080" | lighten: 50 }}')).to eq('#c0c0c0')
        end

        it 'clamps rather than wrapping at the ends' do
          expect(render('{{ "#000000" | darken: 200 }}')).to eq('#000000')
          expect(render('{{ "#ffffff" | lighten: 200 }}')).to eq('#ffffff')
        end
      end

      describe 'grouping' do
        let(:rows) do
          [{ 'dept' => 'Ops', 'n' => 1 }, { 'dept' => 'Dev', 'n' => 2 },
           { 'dept' => 'Ops', 'n' => 3 }, { 'dept' => nil, 'n' => 4 }]
        end

        it 'buckets by a property in first-appearance order' do
          # `{% for %}` takes a variable, not a filter expression — hence the `assign`.
          expect(render('{% assign gs = rows | group_by: "dept" %}' \
                        '{% for g in gs %}{{ g.name }}={{ g.size }};{% endfor %}',
                        rows: rows)).to eq('Ops=2;Dev=1;(none)=1;')
        end

        # A nil group is information — 40 issues with no target version IS the finding —
        # and dropping it would stop the group sizes summing to the total, which is how a
        # reader discovers a filter lost rows.
        it 'names the nil bucket rather than dropping it' do
          groups = render('{% assign gs = rows | group_by: "dept" %}' \
                          '{% for g in gs %}{{ g.size }}+{% endfor %}', rows: rows)
          expect(groups.split('+').reject(&:empty?).map(&:to_i).sum).to eq(rows.length)
        end

        it 'exposes the items so a template can render the rows under each heading' do
          expect(render('{% assign gs = rows | group_by: "dept" %}' \
                        '{% for g in gs %}{{ g.items | map: "n" | join: "," }};{% endfor %}',
                        rows: rows)).to eq('1,3;2;4;')
        end
      end

      describe 'custom fields' do
        let(:actor) { DropFakes::User.new(id: 1, login: 'a', name: 'A') }
        let(:fields) do
          { 20 => DropFakes::NamedRecord.new(id: 20, name: 'Department'),
            21 => DropFakes::NamedRecord.new(id: 21, name: 'Vessel') }
        end
        let(:batch) do
          DropFakes::Batch.new(custom_fields: fields,
                               custom_field_values: { 7 => { 20 => 'Ops', 21 => 'Aurora' } })
        end
        let(:issue) do
          Drops::IssueDrop.new(DropFakes::Record.new(id: 7, subject: 's', project: nil),
                               context: RenderContext.new(actor: actor, batch: batch))
        end

        it 'reads a field by name' do
          expect(render('{{ issue | custom_field: "Department" }}', issue: issue)).to eq('Ops')
        end

        it 'reads a field by id, which survives a rename' do
          expect(render('{{ issue | custom_field_by_id: 20 }}', issue: issue)).to eq('Ops')
        end

        it 'lists every field the actor may see' do
          expect(render('{% assign cfs = issue | custom_fields %}' \
                        '{% for cf in cfs %}{{ cf.name }}={{ cf }};{% endfor %}',
                        issue: issue)).to eq('Department=Ops;Vessel=Aurora;')
        end

        # A hidden field and an absent field give the same answer, on purpose: telling
        # them apart is itself a disclosure.
        it 'answers nothing for a field that is not there' do
          expect(render('[{{ issue | custom_field: "Salary" }}][{{ issue | custom_field_by_id: 99 }}]',
                        issue: issue)).to eq('[][]')
        end

        it 'answers nothing rather than field zero when an id argument is not an id' do
          expect(render('[{{ issue | custom_field_by_id: "Department" }}]', issue: issue)).to eq('[]')
        end
      end

      # ----------------------------------------------------------------
      # INV-9 — what a filter must not be able to do
      # ----------------------------------------------------------------

      describe 'INV-9' do
        # The property that makes `avg: "destroy"` harmless. `Support.read` goes through
        # `Drop#[]` and nothing else, so a property name is looked up in the drop's
        # DECLARED surface — never sent to the object.
        it 'resolves a property through the drop protocol, never by sending it' do
          record = DropFakes::Record.new(id: 1, subject: 's')
          issue = Drops::IssueDrop.new(record, context: RenderContext.new(
            actor: DropFakes::User.new(id: 1, login: 'a', name: 'A')
          ))
          expect(record).not_to receive(:public_send)
          expect(render('[{{ list | avg: "object_id" }}]', list: [issue])).to eq('[]')
        end

        it 'exposes no helper from the support module as a filter' do
          %w[read values_of each numbers number numeric_string render_context tidy
             to_data escape_script scalar].each do |helper|
            expect(Filters.registered_names).not_to include(helper)
          end
        end
      end

      # ----------------------------------------------------------------
      # Living in a process with somebody else's global filter registration
      # ----------------------------------------------------------------

      # THE REGRESSION THESE THREE EXIST FOR, AND IT WAS A 500 ON EVERY RENDER.
      #
      # Measured 2026-08-21 on Redmine 6.0-stable with the operator's 41 plugins installed.
      # `Filters::Colors` had a PRIVATE helper named `shift`, and the vendor gem — pulled
      # in by every one of the operator's paid plugins — globally registers 91 filters at require
      # time, `shift` among them. `Strainer.add_filter` inspects a module's private and
      # protected methods and refuses the module outright when one of those names is
      # already an invokable filter:
      #
      #     Liquid::MethodOverrideError: Filter overrides registered public methods as
      #     non public: shift
      #
      # So one private helper made the whole `Colors` module unaddable and took `darken`
      # and `lighten` with it. `registered_names` could not have caught it: it reads
      # `public_instance_methods(false)`, and the hazard is exactly the methods it skips.
      #
      # These run WITHOUT the gem installed, because the failure does not need it — a
      # foreign module publicly defining the name is all it takes, and that is what the
      # first example builds.
      describe 'a foreign filter module that registered the same names first' do
        # THE RULE, and it is mechanical: Liquid inspects a filter module's PRIVATE and
        # PROTECTED methods too. `support.rb`'s header already stated it for the public
        # ones — a helper beside `avg` becomes `{{ x | numeric_values }}` — and this is the
        # other half, which cost a release: `Strainer.add_filter` REFUSES a module whose
        # non-public method collides with a name already registered as a filter.
        #
        # Helpers therefore live in `Support`, which is not a filter module, and a filter
        # module has no non-public instance methods at all. Nothing to collide, nothing to
        # keep in anybody's head.
        it 'gives no filter module a non-public instance method' do
          Filters.modules.each do |mod|
            non_public = mod.private_instance_methods + mod.protected_instance_methods
            expect(non_public).to eq([]),
                                  "#{mod} keeps #{non_public.inspect} — move it to Support: " \
                                  'a foreign plugin registering that name as a filter makes ' \
                                  'this whole module unaddable'
          end
        end

        # NOT VACUOUS, and this is the example that says so. Built to fail the way `Colors`
        # failed, so the rule above cannot quietly become a tautology if `modules` is ever
        # empty or the reflection changes.
        it 'is refused by Liquid when a module does keep one' do
          offender = Module.new do
            def darker(input) = shift(input)
            private

            def shift(input) = input
          end
          foreign = Module.new do
            def shift(input) = input
          end

          expect { ::Liquid::Strainer.create(::Liquid::Context.new, [foreign, offender]) }
            .to raise_error(::Liquid::MethodOverrideError, /non public: shift/)
        end

        # Every filter module has to survive the real shape of the failure: a foreign
        # module that already owns all of ours, added first.
        it 'adds every filter module after a foreign one owning every registered name' do
          foreign = Module.new do
            RedmineReporterDashboards::Liquid::Filters.registered_names.each do |name|
              define_method(name) { |*_args| nil }
            end
          end

          expect { ::Liquid::Strainer.create(::Liquid::Context.new, [foreign] + Filters.modules) }
            .not_to raise_error
        end

        # `darken` and `lighten` are what the move had to keep working.
        it 'still darkens and lightens through the helper that moved' do
          expect(render('{{ "#808080" | darken: 50 }}')).to eq('#404040')
          expect(render('{{ "#808080" | lighten: 50 }}')).to eq('#c0c0c0')
        end
      end
    end
  end
end
