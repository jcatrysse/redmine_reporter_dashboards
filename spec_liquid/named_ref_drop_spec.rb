# frozen_string_literal: true

# See `spec_liquid/README.md`: the real Liquid gem, its own rspec invocation.
require 'liquid'

require_relative '../lib/redmine_reporter_dashboards/liquid/drops/named_ref_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # THE REQUIRED SPEC. `technical-spec.md` §3.3 marks `NamedRefDrop` `[UNVERIFIED]`
      # until this file is green, and T-18's Accept list repeats it: *"Every one of those
      # five is a claim about Liquid's internals and must be proven by test, not by
      # reasoning."*
      #
      # The claim under test is SUBSTITUTABILITY: a template that used to receive a
      # String must render byte-identically now that it receives a drop. So every
      # example below renders the SAME source twice — once with the String, once with
      # the drop — and compares the outputs. Asserting the drop's output against a
      # literal I typed would only prove I can predict Liquid; comparing against the
      # String proves the property the templates in the wild actually depend on.
      #
      # --- ON BOTH LIQUID 4.x AND 5.x ---
      #
      # `RRD_LIQUID_VERSION` reports which one is loaded, and `spec_liquid/README.md`
      # plus the CI job run it twice. One version passing is not the claim: §3.3 says
      # "under both", because the lexer, the comparison operators and `Drop`'s method
      # dispatch all changed between them.
      RSpec.describe NamedRefDrop do
        before do
          skip 'run with the real gem: rspec -r liquid spec_liquid' unless defined?(::Liquid::VERSION)
        end

        # A status, which is the reference every template touches.
        let(:drop) do
          described_class.new(id: 5, name: 'Closed', url: 'https://redmine.example/issue_statuses/5',
                              attributes: { 'is_closed' => true })
        end
        let(:string) { 'Closed' }

        # Renders `source` with `issue.status` bound to `value`, through a real template.
        # Nothing is stubbed: if Liquid changes how it prints or compares a Drop, this
        # notices.
        def render(source, value)
          template = ::Liquid::Template.parse(source, error_mode: :strict)
          template.render!({ 'status' => value })
        end

        # The comparison that IS the claim. Two renders of one source, one output.
        def expect_identical(source)
          from_string = render(source, string)
          from_drop = render(source, drop)

          expect(from_drop).to eq(from_string),
                               "#{source.inspect} renders #{from_drop.inspect} through the drop and " \
                               "#{from_string.inspect} through the String (Liquid #{::Liquid::VERSION})"
          from_drop
        end

        it 'reports which Liquid it is proving this against' do
          # Not decoration: a green run whose version nobody recorded is a green run
          # that proves "under both" only if somebody remembered to do it twice.
          expect(::Liquid::VERSION).to match(/\A[45]\./)
          RSpec.configuration.reporter.message("  [NamedRefDrop] proven against Liquid #{::Liquid::VERSION}")
        end

        describe 'to_s — {{ issue.status }}' do
          it 'prints the name and nothing else' do
            expect(expect_identical('{{ status }}')).to eq('Closed')
          end

          it 'prints identically inside surrounding text' do
            expect_identical('Status: [{{ status }}] end')
          end

          it 'survives a filter chain that assumes a string' do
            expect_identical('{{ status | upcase }}')
            expect_identical('{{ status | append: "!" }}')
            expect_identical('{{ status | prepend: ">" }}')
            expect_identical('{{ status | downcase | capitalize }}')
          end
        end

        describe '== — {% if issue.status == "Closed" %}' do
          it 'is true against its own name' do
            expect(expect_identical('{% if status == "Closed" %}yes{% else %}no{% endif %}'))
              .to eq('yes')
          end

          it 'is false against a different name' do
            expect(expect_identical('{% if status == "New" %}yes{% else %}no{% endif %}'))
              .to eq('no')
          end

          # --- A MEASURED LIMITATION, NOT A PASSING TEST (finding E-8) ---
          #
          # §3.3's table protects `{% if issue.status == "Closed" %}`, and that works.
          # THE REVERSED FORM DOES NOT, and it is a real idiom:
          #
          #     {% if "Closed" == issue.status %}   ->  drop: no,  String: yes
          #
          # Ruby asks the LEFT operand, so this is `String#==(drop)`, which answers
          # false for anything that is not a String. Nothing this class can define
          # changes that: the fixes are monkey-patching String (forbidden) or making the
          # drop a String subclass, which forfeits the Drop protocol and with it
          # `{{ status.id }}` — the whole reason the class exists. See E-8.
          #
          # Asserted as it IS rather than as it should be, so that the day somebody
          # changes the design this test says what moved instead of quietly going green.
          it 'is NOT substitutable with the literal on the left — measured, see E-8' do
            source = '{% if "Closed" == status %}yes{% else %}no{% endif %}'

            expect(render(source, string)).to eq('yes')
            expect(render(source, drop)).to eq('no'),
                                            'the reversed-comparison limitation changed; E-8 needs revisiting'
          end

          it 'answers != the way the String does' do
            expect_identical('{% if status != "New" %}yes{% else %}no{% endif %}')
          end

          it 'compares equal to another drop with the same name' do
            other = described_class.new(id: 99, name: 'Closed')

            expect(drop == other).to be(true)
            expect(drop == described_class.new(id: 5, name: 'New')).to be(false)
          end
        end

        describe 'eql?/hash — hash-keyed grouping' do
          # A filter that groups by status must not produce two buckets for "Closed"
          # depending on whether the value arrived as a drop or a string.
          it 'hashes to the same bucket as its name' do
            expect(drop.hash).to eq(string.hash)
            expect(drop.eql?(string)).to be(true)
          end

          it 'collapses into one key when used as a Hash key' do
            counts = Hash.new(0)
            counts[string] += 1
            counts[drop] += 1

            expect(counts.keys.length).to eq(1)
            expect(counts.values).to eq([2])
          end

          it 'does not collide with a different name' do
            expect(drop.hash).not_to eq(described_class.new(id: 1, name: 'New').hash)
          end
        end

        describe 'include? — {% if issue.status contains "Clo" %}' do
          it 'matches a substring of the name' do
            expect(expect_identical('{% if status contains "Clo" %}yes{% else %}no{% endif %}'))
              .to eq('yes')
          end

          it 'does not match a substring that is not there' do
            expect(expect_identical('{% if status contains "Open" %}yes{% else %}no{% endif %}'))
              .to eq('no')
          end
        end

        describe 'to_liquid — the drop protocol' do
          it 'returns itself, so Liquid does not unwrap it into something else' do
            expect(drop.to_liquid).to equal(drop)
          end

          # The reason the class exists at all: everything above is compatibility, and
          # THIS is the new capability. A String can never answer these.
          it 'exposes what a String could not' do
            expect(render('{{ status.id }}', drop)).to eq('5')
            expect(render('{{ status.url }}', drop)).to eq('https://redmine.example/issue_statuses/5')
            expect(render('{{ status.name }}', drop)).to eq('Closed')
          end

          it 'exposes caller-supplied attributes, which is what dissolves geo_version_map' do
            version = described_class.new(
              id: 7, name: '2.1.0', url: 'https://redmine.example/versions/7',
              attributes: { 'effective_date' => '2026-03-01', 'status' => 'open' }
            )

            template = ::Liquid::Template.parse('{{ v.effective_date }}|{{ v.status }}',
                                                error_mode: :strict)
            expect(template.render!({ 'v' => version })).to eq('2026-03-01|open')
          end

          # Liquid's Drop routes unknown keys to `liquid_method_missing`. Overriding
          # Ruby's `method_missing` instead would expose every method this object
          # happens to have to template authors, which is the arbitrary-invocation
          # hazard `Liquid::Drop` exists to close.
          it 'answers nothing for a key it does not have, rather than raising' do
            expect(render('[{{ status.nonsense }}]', drop)).to eq('[]')
          end

          # The first draft defined `key?` and `attributes` as conveniences, and `key?`
          # broke the protocol outright — Liquid asks `respond_to?(:key?)` to decide
          # whether a value is hash-like, then asked `key?('id')`, got false, and
          # returned nil without ever trying the method. `{{ status.id }}` rendered
          # EMPTY. Every public method on this class is part of the contract.
          it 'does not expose its own Ruby internals to a template' do
            expect(render('[{{ status.instance_variable_get }}]', drop)).to eq('[]')
            expect(render('[{{ status.attributes }}]', drop)).to eq('[]')
            expect(render('[{{ status.hash }}]', drop)).to eq('[]')
          end
        end

        # --- THE SECOND MEASURED LIMITATION (finding E-8) --------------------------
        describe 'filters that ask the value about itself' do
          # `| size` asks the OBJECT, not its string form. A Drop has no size, so it
          # answers 0 where the String answers its length. Outside §3.3's five methods,
          # and recorded rather than fixed: adding `size` here would be building the
          # better idea instead of reporting that the table is short one row.
          it 'answers size 0 where the String answers its length — measured, see E-8' do
            expect(render('{{ status | size }}', string)).to eq('6')
            expect(render('{{ status | size }}', drop)).to eq('0'),
                                                        'the size limitation changed; E-8 needs revisiting'
          end
        end

        describe 'the escape hatch that ships anyway' do
          # Five one-line accessors, kept deliberately: they are what an author reaches
          # for if drop-versus-String semantics bite in a shape this file did not
          # enumerate.
          it 'answers id, name and url directly in Ruby too' do
            expect(drop.id).to eq(5)
            expect(drop.name).to eq('Closed')
            expect(drop.url).to start_with('https://')
          end

          # `url` is ALWAYS absolute, which is what makes the base plugin's 38 lines of
          # Nokogiri-or-regexp URL rewriting unnecessary.
          it 'carries an absolute url or none at all' do
            expect(drop.url).to match(%r{\Ahttps?://})
            expect(described_class.new(id: 1, name: 'x').url).to be_nil
          end
        end

        describe 'names that are not simple words' do
          # A status called "Closed" is the easy case. Redmine installs have statuses
          # with quotes, angle brackets and non-ASCII in them, and substitutability has
          # to hold for those too — they are the ones where a difference would surface
          # as a broken document rather than a wrong branch.
          ['In Progress', 'Réouvert', 'A "quoted" name', '<b>bold</b>', 'a & b', ''].each do |name|
            it "is substitutable for #{name.inspect}" do
              value = described_class.new(id: 1, name: name)
              template = ::Liquid::Template.parse('[{{ s }}]', error_mode: :strict)

              expect(template.render!({ 's' => value })).to eq(template.render!({ 's' => name }))
            end
          end
        end
      end
    end
  end
end
