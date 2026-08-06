# frozen_string_literal: true

# T-18's disposition spec. See `spec_liquid/README.md`: the real Liquid gem, its own
# rspec invocation, and in CI this file runs three times — once under the bundle and
# once each pinned to Liquid 4.0.4 and 5.x.
#
# WHAT THIS FILE IS FOR. `technical-spec.md` §3.2 is an explicit table of decisions
# about `IssueDrop`'s vocabulary: names kept identical, one timezone bug fixed, four
# scalars promoted to references, six vendor probes dropped, `all` not implemented.
# Every one of those is invisible in the code once written — a missing accessor looks
# exactly like an accessor nobody needed — so the table is asserted here rather than
# trusted.
#
# EVERY ASSERTION RENDERS A TEMPLATE. Not `drop.subject`, but
# `Liquid::Template.parse('{{ issue.subject }}').render`. The difference matters: a
# method can be public and still unreachable from a template (`NamedRefDrop`'s `key?`
# defect made every accessor on that class render EMPTY while every direct call
# worked), and it is the template that is the contract.

require 'liquid'

require_relative 'support/drop_fakes'
require_relative '../lib/redmine_reporter_dashboards/liquid/drops'

module RedmineReporterDashboards
  module Liquid
    module Drops
      RSpec.describe 'the owned drop layer' do
        before do
          skip 'run with the real gem: rspec -r liquid spec_liquid' unless defined?(::Liquid::VERSION)
        end

        # --------------------------------------------------------------
        # Fixture
        # --------------------------------------------------------------

        let(:zone) { 'Europe/Brussels' }
        let(:actor) { DropFakes::User.new(id: 7, login: 'jane', name: 'Jane Doe', time_zone: zone) }

        let(:status)   { DropFakes::NamedRecord.new(id: 5, name: 'Closed', is_closed: true) }
        let(:tracker)  { DropFakes::NamedRecord.new(id: 2, name: 'Bug') }
        let(:priority) { DropFakes::NamedRecord.new(id: 4, name: 'High') }
        let(:category) { DropFakes::NamedRecord.new(id: 9, name: 'Backend') }

        let(:project) do
          DropFakes::Record.new(id: 3, name: 'Survey', identifier: 'survey',
                                description: 'Hydrographic survey', status: 1)
        end

        let(:version_record) do
          DropFakes::Record.new(id: 11, name: '2026.1', description: 'first',
                                effective_date: '2026-03-31', status: 'open',
                                sharing: 'none', completed_percent: 42.0,
                                project_id: 3, project: project)
        end

        let(:author)   { DropFakes::User.new(id: 1, login: 'amy', name: 'Amy Ampere') }
        let(:assignee) { DropFakes::User.new(id: 2, login: 'bob', name: 'Bob Bell') }

        let(:created_on) { DropFakes::Time.new('2026-01-02T03:04:05Z') }
        let(:updated_on) { DropFakes::Time.new('2026-02-03T04:05:06Z') }
        let(:closed_on)  { DropFakes::Time.new('2026-03-04T05:06:07Z') }

        let(:issue_record) do
          DropFakes::Record.new(
            { id: 42, subject: 'Broken pump', description: 'It leaks',
              start_date: '2026-01-01', due_date: '2026-01-31', done_ratio: 60,
              estimated_hours: 8.0, created_on: created_on, updated_on: updated_on,
              closed_on: closed_on,
              status: status, tracker: tracker, priority: priority, category: category,
              fixed_version: version_record, project: project,
              author: author, assigned_to: assignee, parent: nil,
              status_id: 5, tracker_id: 2, priority_id: 4, category_id: 9,
              fixed_version_id: 11, parent_id: nil, project_id: 3,
              author_id: 1, assigned_to_id: 2 },
            loaded_associations: %i[status tracker priority category fixed_version
                                    project author assigned_to]
          )
        end

        let(:custom_fields) do
          { 20 => DropFakes::NamedRecord.new(id: 20, name: 'Department'),
            21 => DropFakes::NamedRecord.new(id: 21, name: 'Vessel') }
        end

        let(:batch) do
          DropFakes::Batch.new(custom_fields: custom_fields,
                               custom_field_values: { 42 => { 20 => 'Ops', 21 => %w[Aurora Borealis] } },
                               spent_hours: { 42 => 3.5 })
        end

        let(:context) { RenderContext.new(actor: actor, batch: batch) }
        let(:drop) { IssueDrop.new(issue_record, context: context) }

        # Renders through a REAL template, which is the only thing that proves an
        # accessor is reachable rather than merely defined.
        def render(source, assigns = {})
          ::Liquid::Template.parse(source, error_mode: :strict)
                            .render!({ 'issue' => drop }.merge(assigns))
        end

        # An accessor the disposition table DROPS. `strict_variables` makes Liquid raise
        # on an undefined drop method instead of rendering blank, which is what turns
        # "the accessor is gone" into an assertion — without it, a dropped accessor and
        # an accessor returning nil are the same empty string.
        def expect_unreachable(source)
          template = ::Liquid::Template.parse(source, error_mode: :strict)
          expect { template.render!({ 'issue' => drop }, strict_variables: true) }
            .to raise_error(::Liquid::UndefinedDropMethod), "#{source} is still reachable"
        end

        # --------------------------------------------------------------
        # §3.1 — the inventory
        # --------------------------------------------------------------

        describe 'the class inventory (§3.1)' do
          it 'defines every class it claims to' do
            (Drops::BASES + Drops::CLASSES).each do |name|
              expect(Drops.const_defined?(name, false)).to be(true), "#{name} is missing"
            end
          end

          # The negative half, and it is the half that rots. Nothing stops a later
          # session adding `JournalDrop` back; this makes doing so require deleting the
          # line that records why it went.
          it 'defines none of the seven the gem had and §3.1 drops' do
            Drops::DROPPED.each do |name, reason|
              expect(Drops.const_defined?(name, false)).to be(false),
                                                           "#{name} is back. It was dropped because: #{reason}"
            end
          end
        end

        # --------------------------------------------------------------
        # §3.2 — keep, identical names
        # --------------------------------------------------------------

        describe 'keep, identical names' do
          {
            'id' => '42', 'subject' => 'Broken pump', 'description' => 'It leaks',
            'start_date' => '2026-01-01', 'due_date' => '2026-01-31',
            'done_ratio' => '60', 'estimated_hours' => '8.0'
          }.each do |accessor, expected|
            it "{{ issue.#{accessor} }} renders #{expected.inspect}" do
              expect(render("{{ issue.#{accessor} }}")).to eq(expected)
            end
          end
        end

        # --------------------------------------------------------------
        # §3.2 — keep + fix: the timezone defect
        # --------------------------------------------------------------

        describe 'the three timestamps' do
          # THE DEFECT §3.2 NAMES. The base plugin converts two of these and not the
          # third (`issues_drop.rb:22-28`), so a report printing all three shows one in
          # UTC and two in the viewer's zone with nothing to say which.
          %w[created_on updated_on closed_on].each do |accessor|
            it "converts #{accessor} to the ACTOR's zone" do
              expect(render("{{ issue.#{accessor} }}")).to end_with("@#{zone}")
            end
          end

          it 'converts all three to the SAME zone — which is the whole bug' do
            zones = %w[created_on updated_on closed_on].map do |accessor|
              render("{{ issue.#{accessor} }}").split('@').last
            end
            expect(zones.uniq).to eq([zone])
          end

          it 'reads the zone off the actor and never off an ambient user (INV-1)' do
            other = DropFakes::User.new(id: 8, login: 'kurt', name: 'Kurt', time_zone: 'Pacific/Auckland')
            other_drop = IssueDrop.new(issue_record, context: RenderContext.new(actor: other, batch: batch))
            rendered = ::Liquid::Template.parse('{{ issue.created_on }}')
                                         .render!('issue' => other_drop)
            expect(rendered).to end_with('@Pacific/Auckland')
          end

          it 'leaves a nil timestamp nil rather than inventing one' do
            open_issue = DropFakes::Record.new(issue_record.attributes.merge(closed_on: nil))
            open_drop = IssueDrop.new(open_issue, context: context)
            expect(::Liquid::Template.parse('[{{ issue.closed_on }}]').render!('issue' => open_drop))
              .to eq('[]')
          end

          it 'passes a timestamp through untouched when the actor has no zone' do
            zoneless = DropFakes::User.new(id: 9, login: 'zz', name: 'Zoe', time_zone: nil)
            zoneless_drop = IssueDrop.new(issue_record, context: RenderContext.new(actor: zoneless, batch: batch))
            expect(::Liquid::Template.parse('{{ issue.created_on }}').render!('issue' => zoneless_drop))
              .to eq('2026-01-02T03:04:05Z')
          end
        end

        # --------------------------------------------------------------
        # §3.2 — rename + alias. OQ-B: the `?` spellings are LIVE surface.
        # --------------------------------------------------------------

        describe 'the four predicates' do
          let(:issue_record) do
            DropFakes::Record.new({ id: 42, subject: 's', visible?: true, closed?: true,
                                    overdue?: false, is_private?: true },
                                  loaded_associations: [])
          end

          {
            'visible' => 'true', 'closed' => 'true',
            'overdue' => 'false', 'private' => 'true'
          }.each do |accessor, expected|
            it "{{ issue.#{accessor} }} renders #{expected}" do
              expect(render("{{ issue.#{accessor} }}")).to eq(expected)
            end
          end

          # OQ-B, measured 2026-08-04: Liquid's lexer permits a trailing `?` by design on
          # both 4.x and 5.x, so these spellings PARSE and RESOLVE and may be in real
          # templates. §3.2's guess that they were dead surface was refuted; keeping
          # them is a compatibility requirement, not a courtesy.
          {
            'visible?' => 'true', 'closed?' => 'true',
            'overdue?' => 'false', 'is_private?' => 'true'
          }.each do |accessor, expected|
            it "the gem's spelling {{ issue.#{accessor} }} still renders #{expected}" do
              expect(render("{{ issue.#{accessor} }}")).to eq(expected)
            end
          end

          it 'asks the record whether the ACTOR may see it, not whether anyone may' do
            asked = []
            record = Class.new(DropFakes::Record) do
              define_method(:visible?) { |user| asked << user; true }
            end.new({ id: 1 })
            IssueDrop.new(record, context: context).visible
            expect(asked).to eq([actor])
          end
        end

        # --------------------------------------------------------------
        # §3.2/§3.3 — keep name, fix type
        # --------------------------------------------------------------

        describe 'the named references' do
          {
            'status' => 'Closed', 'tracker' => 'Bug',
            'priority' => 'High', 'category' => 'Backend'
          }.each do |accessor, name|
            it "{{ issue.#{accessor} }} still prints #{name.inspect} — it is a drop now" do
              expect(render("{{ issue.#{accessor} }}")).to eq(name)
            end

            it "{{ issue.#{accessor}.id }} answers, which a String could not" do
              expect(render("{{ issue.#{accessor}.id }}")).not_to be_empty
            end

            it "{% if issue.#{accessor} == #{name.inspect} %} is still true" do
              expect(render("{% if issue.#{accessor} == '#{name}' %}yes{% endif %}")).to eq('yes')
            end
          end

          it 'gives every reference an ABSOLUTE url' do
            expect(render('{{ issue.status.url }}'))
              .to eq('https://redmine.example/rm/issue_statuses/5')
          end

          it 'renders a nil reference as empty rather than as a zero' do
            uncategorised = DropFakes::Record.new(
              { id: 1, category: nil, category_id: nil }, loaded_associations: [:category]
            )
            rendered = ::Liquid::Template.parse('[{{ issue.category }}]')
                                         .render!('issue' => IssueDrop.new(uncategorised, context: context))
            expect(rendered).to eq('[]')
          end

          # §3.3's belt and braces: the escape hatch ships as well.
          {
            'status_id' => '5', 'tracker_id' => '2', 'priority_id' => '4',
            'category_id' => '9', 'fixed_version_id' => '11'
          }.each do |accessor, expected|
            it "{{ issue.#{accessor} }} renders #{expected}" do
              expect(render("{{ issue.#{accessor} }}")).to eq(expected)
            end
          end

          it 'reads a preloaded association without touching the batch' do
            render('{{ issue.status }}{{ issue.tracker }}{{ issue.priority }}{{ issue.category }}')
            expect(batch.asked).to be_empty
          end

          it 'falls back to the batch when the association is NOT preloaded' do
            lonely = DropFakes::Record.new({ id: 1, status_id: 5 }, loaded_associations: [])
            batch_with_ref = DropFakes::Batch.new(
              named_refs: { 'IssueStatus' => {
                5 => DropFakes::NamedRecord.new(id: 5, name: 'Closed', is_closed: true)
              } }
            )
            lonely_drop = IssueDrop.new(lonely, context: RenderContext.new(actor: actor, batch: batch_with_ref))
            rendered = ::Liquid::Template.parse('{{ issue.status }}').render!('issue' => lonely_drop)
            expect(rendered).to eq('Closed')
            expect(batch_with_ref.asked).to eq([[:named_ref, 'IssueStatus', :status_id]])
          end
        end

        # --------------------------------------------------------------
        # VersionDrop — the same five-method contract as NamedRefDrop
        # --------------------------------------------------------------

        describe 'VersionDrop' do
          let(:version) { VersionDrop.new(version_record, context: context) }

          # THE SUBSTITUTABILITY BATTERY, run against `VersionDrop` as well as against
          # `NamedRefDrop`. The two share `StringSubstitutable`, and a module being
          # shared is not evidence that the sharing worked — §3.3 says every one of
          # these five is a claim about Liquid's internals and must be proven by test.
          def expect_identical(source)
            from_string = ::Liquid::Template.parse(source, error_mode: :strict).render!('v' => '2026.1')
            from_drop = ::Liquid::Template.parse(source, error_mode: :strict).render!('v' => version)
            expect(from_drop).to eq(from_string), "#{source.inspect} renders #{from_drop.inspect} " \
                                                  "through the drop and #{from_string.inspect} " \
                                                  "through the String (Liquid #{::Liquid::VERSION})"
            from_drop
          end

          it 'prints as the String it replaces' do
            expect(expect_identical('{{ v }}')).to eq('2026.1')
          end

          it 'compares equal to the String with the drop on the LEFT' do
            expect_identical("{% if v == '2026.1' %}yes{% endif %}")
            expect_identical("{% if v != '2025.4' %}yes{% endif %}")
          end

          # E-8, pinned in the second class as well as the first. The reversed order is
          # `String#==(drop)`, which no drop can influence; the curator's decision on
          # 2026-08-06 was to keep the Drop and have T-19's linter flag the idiom.
          # Asserted AS IT IS so the day the design changes this says what moved.
          it 'is NOT substitutable with the literal on the left — E-8' do
            source = "{% if '2026.1' == v %}yes{% else %}no{% endif %}"
            expect(::Liquid::Template.parse(source).render!('v' => '2026.1')).to eq('yes')
            expect(::Liquid::Template.parse(source).render!('v' => version)).to eq('no'),
                                                                                'E-8 changed; revisit the finding'
          end

          # The second E-8 gap, for the same reason: `size` asks the object, not its
          # string form, and a Drop has no size.
          it 'does not answer `| size` the way the String does — E-8' do
            source = '{{ v | size }}'
            expect(::Liquid::Template.parse(source).render!('v' => '2026.1')).to eq('6')
            expect(::Liquid::Template.parse(source).render!('v' => version)).to eq('0')
          end

          it 'answers `contains` the way the String does' do
            expect_identical("{% if v contains '2026' %}yes{% endif %}")
            expect_identical("{% if v contains 'nope' %}yes{% else %}no{% endif %}")
          end

          it 'survives a filter chain that assumes a string' do
            expect_identical('{{ v | upcase }}')
            expect_identical('{{ v | append: "!" }}')
          end

          it 'hashes with the String so a grouping filter makes one bucket' do
            expect({ '2026.1' => 1 }[version]).to eq(1)
          end

          it 'carries the four fields {% geo_version_map %} existed to provide' do
            expect(::Liquid::Template.parse(
              '{{ v.id }}|{{ v.effective_date }}|{{ v.status }}|{{ v.project.name }}'
            ).render!('v' => version)).to eq('11|2026-03-31|open|Survey')
          end

          it 'builds absolute URLs, including the roadmap and the three issue lists' do
            rendered = ::Liquid::Template.parse(
              '{{ v.url }} {{ v.roadmap_url }} {{ v.open_issues_url }}'
            ).render!('v' => version)
            expect(rendered.split).to all(start_with('https://redmine.example/rm/'))
            expect(rendered).to include('/projects/survey/roadmap')
            expect(rendered).to include('status_id=o')
          end

          it 'is what {{ issue.version }} returns, under both spellings' do
            expect(render('{{ issue.version }}|{{ issue.target_version }}')).to eq('2026.1|2026.1')
            expect(render('{{ issue.version.id }}')).to eq('11')
          end
        end

        # --------------------------------------------------------------
        # §3.2 — the associations
        # --------------------------------------------------------------

        describe 'associations' do
          it 'renders the author and the assignee as people' do
            expect(render('{{ issue.author }}|{{ issue.assignee }}')).to eq('Amy Ampere|Bob Bell')
          end

          it 'gives a person an absolute url' do
            expect(render('{{ issue.author.url }}')).to eq('https://redmine.example/rm/users/1')
          end

          it 'renders the project, and `project_name` folds into `project.name`' do
            expect(render('{{ issue.project.name }}')).to eq('Survey')
            expect_unreachable('{{ issue.project_name }}')
          end

          it 'gives a project a url keyed on its identifier, not its id' do
            expect(render('{{ issue.project.url }}')).to eq('https://redmine.example/rm/projects/survey')
          end

          it 'renders a nil parent as empty' do
            expect(render('[{{ issue.parent }}]')).to eq('[]')
          end
        end

        # --------------------------------------------------------------
        # §3.2 — url, link
        # --------------------------------------------------------------

        describe 'url and link' do
          it 'is ALWAYS absolute, which is what deletes the 38 lines of URL rewriting' do
            expect(render('{{ issue.url }}')).to eq('https://redmine.example/rm/issues/42')
          end

          it 'honours a host_name carrying a path prefix' do
            expect(render('{{ issue.url }}')).to start_with('https://redmine.example/rm/')
          end

          it 'escapes the subject in `link` — a subject is user input (INV-9)' do
            hostile = DropFakes::Record.new({ id: 7, subject: '</a><script>alert(1)</script>' })
            rendered = ::Liquid::Template.parse('{{ issue.link }}')
                                         .render!('issue' => IssueDrop.new(hostile, context: context))
            expect(rendered).not_to include('<script>')
            expect(rendered).to include('&lt;script&gt;')
            expect(rendered).to start_with('<a href="https://redmine.example/rm/issues/7">')
          end
        end

        # --------------------------------------------------------------
        # §3.4 — the batched accessors
        # --------------------------------------------------------------

        describe 'the batched accessors' do
          it 'reads spent_hours through the batch' do
            expect(render('{{ issue.spent_hours }}')).to eq('3.5')
            expect(batch.asked).to eq([:spent_hours])
          end

          it 'answers total_spent_hours from the batch for a LEAF, with no extra work' do
            leaf = Class.new(DropFakes::Record) do
              def leaf?
                true
              end
            end.new({ id: 42, estimated_hours: 8.0 })
            leaf_drop = IssueDrop.new(leaf, context: context)
            expect(::Liquid::Template.parse('{{ issue.total_spent_hours }}|{{ issue.total_estimated_hours }}')
                                     .render!('issue' => leaf_drop)).to eq('3.5|8.0')
          end

          it 'asks the record itself for a PARENT, where the batch cannot answer' do
            parent = Class.new(DropFakes::Record) do
              def leaf?
                false
              end
            end.new({ id: 42, estimated_hours: 8.0, total_spent_hours: 99.0,
                      total_estimated_hours: 40.0 })
            parent_drop = IssueDrop.new(parent, context: context)
            expect(::Liquid::Template.parse('{{ issue.total_spent_hours }}|{{ issue.total_estimated_hours }}')
                                     .render!('issue' => parent_drop)).to eq('99.0|40.0')
          end

          it 'touches NO batch key for a template that only prints columns' do
            render('{{ issue.subject }} {{ issue.due_date }} {{ issue.status }}')
            expect(batch.asked).to be_empty
          end
        end

        # --------------------------------------------------------------
        # Custom fields
        # --------------------------------------------------------------

        describe 'custom fields' do
          it 'resolves {{ issue.custom_field_value[20] }} by id' do
            expect(render('{{ issue.custom_field_value[20] }}')).to eq('Ops')
          end

          it 'resolves a by-id lookup through a Liquid variable' do
            expect(render('{% assign fid = 20 %}{{ issue.custom_field_value[fid] }}')).to eq('Ops')
          end

          it 'resolves by NAME as well' do
            expect(render('{{ issue.custom_field_value["Department"] }}')).to eq('Ops')
          end

          it 'renders a multi-value field as its values' do
            expect(render('{{ issue.custom_field_value[21] | join: "/" }}')).to eq('Aurora/Borealis')
          end

          # A hidden field and an absent field give the SAME answer, on purpose:
          # distinguishing them is itself a disclosure.
          it 'renders a field the batch withheld as empty, exactly like an unknown id' do
            expect(render('[{{ issue.custom_field_value[999] }}][{{ issue.custom_field_value["Nope"] }}]'))
              .to eq('[][]')
          end

          it 'lists the visible fields with their names' do
            expect(render('{% for cfv in issue.custom_field_values %}{{ cfv.name }}={{ cfv }};{% endfor %}'))
              .to eq('Department=Ops;Vessel=Aurora, Borealis;')
          end

          it 'resolves the values once however many accessors read them' do
            render('{{ issue.custom_field_value[20] }}{{ issue.custom_field_value[21] }}')
            expect(batch.asked.count(:custom_field_values)).to eq(1)
          end
        end

        # --------------------------------------------------------------
        # §3.2 — what is DROPPED. The half that rots if nobody asserts it.
        # --------------------------------------------------------------

        describe 'the dropped surface' do
          # All six probes into other RedmineUP paid plugins (`issues_drop.rb:131-157`).
          %w[tags story_points color day_in_state checklists helpdesk_ticket].each do |accessor|
            it "does not reproduce the vendor probe `#{accessor}`" do
              expect_unreachable("{{ issue.#{accessor} }}")
            end
          end

          # OQ-H, narrowed.
          %w[notes journals relations_from relations_to].each do |accessor|
            it "does not carry `#{accessor}` (OQ-H)" do
              expect_unreachable("{{ issue.#{accessor} }}")
            end
          end

          # Dropped from the addon's own subclass, each for the reason §3.2 states.
          %w[images available_statuses spent_time_by_date total_spent_time_by_date
             watchers].each do |accessor|
            it "does not carry `#{accessor}`" do
              expect_unreachable("{{ issue.#{accessor} }}")
            end
          end

          it 'exposes no `file_url` on an attachment — it mints an unexpiring token URL' do
            attachment = DropFakes::Record.new({ id: 3, filename: 'plan.pdf' })
            template = ::Liquid::Template.parse('{{ a.file_url }}')
            expect { template.render!({ 'a' => AttachmentDrop.new(attachment, context: context) },
                                      strict_variables: true) }
              .to raise_error(::Liquid::UndefinedDropMethod)
          end

          it 'exposes no `mail` on a person — the hide_mail preference cannot be honoured here' do
            template = ::Liquid::Template.parse('{{ u.mail }}')
            expect { template.render!({ 'u' => UserDrop.new(author, context: context) },
                                      strict_variables: true) }
              .to raise_error(::Liquid::UndefinedDropMethod)
          end
        end

        # --------------------------------------------------------------
        # INV-1 at the constructor
        # --------------------------------------------------------------

        describe 'INV-1' do
          it 'refuses to build a drop without a RenderContext' do
            expect { IssueDrop.new(issue_record, context: nil) }
              .to raise_error(ArgumentError, /RenderContext/)
          end

          it 'refuses a RenderContext without an actor' do
            expect { RenderContext.new(actor: nil) }.to raise_error(ArgumentError, /actor/)
          end

          it 'refuses a Batch without an actor' do
            expect { Batch.new(actor: nil) }.to raise_error(ArgumentError, /actor/)
          end
        end
      end
    end
  end
end
