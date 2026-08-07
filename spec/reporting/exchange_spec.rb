# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/reporting/exchange'

# T-23 — FR-55 / `technical-spec.md` §7b.2, the import that replaces
# `YAML.load_file` + `constantize` + `rescue Exception`.
#
# Every example here is a thing the construct it replaces got wrong. The three that
# matter most are the last three: a YAML file naming a Ruby class, a YAML file using an
# alias, and a `type` this plugin does not know. The old import would have instantiated
# the first, expanded the second and resolved the third.
# HOISTED AND NAMESPACED — HANDOVER §1's first trap. A constant assigned inside
# `RSpec.describe` is assigned at the FILE'S TOP LEVEL, because the block is a closure
# whose lexical scope is the file: `FakeTemplate` in a describe is `Object::FakeTemplate`
# for the whole process. `unless defined?` makes the collision SILENT — the second file to
# want that name quietly reuses the first file's class and passes in isolation, which is
# how two of T-16's examples went red in the randomised full run for a reason that had
# nothing to do with charts.
module ExchangeSpecSupport
  # A stand-in for the model. Deliberately not the real one: this must be readable and
  # writable without ActiveRecord, and answering the ten exported fields is the whole
  # contract. `engine_hint_or_nil` is here because `Exchange.export` reads `engine_hint`
  # through the model's DEGRADING reader (§7 rule 5), not off the column.
  FakeTemplate = Struct.new(:name, :description, :content, :source, :output, :orientation,
                            :page_size, :margins, :engine_hint, :enabled,
                            keyword_init: true) do
    def engine_hint_or_nil
      engine_hint
    end
  end

  # An install whose schema is one minor version behind: the column, and therefore the
  # reader, is not there at all.
  SchemaBehindTemplate = Struct.new(:name, :description, :content, :source, :output,
                                    :orientation, :page_size, :margins, :enabled,
                                    keyword_init: true)
end

RSpec.describe RedmineReporterDashboards::Reporting::Exchange do
  def template(overrides = {})
    ExchangeSpecSupport::FakeTemplate.new(
      **{ name: 'Quarterly', description: 'Q report',
          content: '<h1>{{ project.name }}</h1>', source: 'issues',
          output: 'combined', orientation: 'portrait', page_size: 'A4',
          margins: '20,15,20,15', engine_hint: nil, enabled: true }.merge(overrides)
    )
  end

  describe '.export' do
    it 'is a plain Hash, which is what T-23 asks for' do
      expect(described_class.export(template)).to be_a(Hash)
    end

    it 'carries the format version and exactly the exported fields' do
      exported = described_class.export(template)

      expect(exported['format_version']).to eq(described_class::FORMAT_VERSION)
      expect(exported['template'].keys).to eq(described_class::EXPORTED_FIELDS)
    end

    it 'exports NONE of one installation`s bookkeeping' do
      # `id`, `lock_version`, `project_id`, `author_id`, the timestamps and
      # `source_template_id` identify a row in ONE database. Importing them elsewhere
      # would make the copy claim to be the original, which is what T-24's drift
      # detection then has to unpick.
      keys = described_class.export(template)['template'].keys

      expect(keys).not_to include('id', 'lock_version', 'project_id', 'author_id',
                                  'created_at', 'updated_at', 'source_template_id',
                                  'source_digest', 'visibility')
    end
  end

  describe '.dump and round-tripping' do
    it 'produces JSON that parses back to the same attributes' do
      parsed = described_class.parse(described_class.dump(template))

      expect(parsed['name']).to eq('Quarterly')
      expect(parsed['content']).to eq('<h1>{{ project.name }}</h1>')
      expect(parsed['output']).to eq('combined')
    end

    # §7b.2's own acceptance clause: export → import → export is byte-identical. It is
    # asserted at the level this class owns — the attribute Hash — because the second
    # export runs against a record built from the first, and building that record is the
    # controller's job.
    it 'export -> import -> export is byte-identical' do
      first = described_class.dump(template)
      round_tripped = template(described_class.parse(first).transform_keys(&:to_sym))

      expect(described_class.dump(round_tripped)).to eq(first)
    end

    it 'ends with a newline, so the file is a well-formed text file' do
      expect(described_class.dump(template)).to end_with("\n")
    end

    # §7 rule 5, on the export path. A user who rolls the plugin back one minor version
    # while keeping the schema — or forward without migrating — must not crash, and
    # `engine_hint_or_nil` exists for exactly that. Reading the field with `public_send`
    # put a NoMethodError on the one install the rule was written for.
    it 'exports an install whose engine_hint column is not there yet' do
      behind = ExchangeSpecSupport::SchemaBehindTemplate.new(
        name: 'A', description: nil, content: 'x', source: 'issues', output: 'combined',
        orientation: 'portrait', page_size: 'A4', margins: nil, enabled: true
      )

      expect { described_class.export(behind) }.not_to raise_error
      expect(described_class.export(behind)['template']['engine_hint']).to be_nil
    end
  end

  describe '.parse — the formats it accepts' do
    it 'reads our own JSON bundle' do
      json = '{"format_version":1,"template":{"name":"A","content":"x"}}'

      expect(described_class.parse(json)['name']).to eq('A')
    end

    it 'reads a YAML bundle, which is what the base plugin wrote' do
      yaml = "---\nname: A\ncontent: x\ntype: IssueListReportTemplate\n"
      parsed = described_class.parse(yaml)

      expect(parsed['name']).to eq('A')
      expect(parsed['source']).to eq('issues')
      expect(parsed['output']).to eq('combined')
    end

    it "reads T-29's multi-template shape, taking the first" do
      json = '{"templates":[{"name":"A"},{"name":"B"}]}'

      expect(described_class.parse(json)['name']).to eq('A')
    end

    it 'reads a bare attribute Hash with no wrapper at all' do
      expect(described_class.parse('{"name":"A"}')['name']).to eq('A')
    end

    it 'accepts a bundle with NO format_version, because the base plugin wrote none' do
      expect { described_class.parse("---\nname: A\n") }.not_to raise_error
    end

    it 'refuses a format_version it does not know rather than guessing' do
      expect { described_class.parse('{"format_version":99,"template":{"name":"A"}}') }
        .to raise_error(described_class::InvalidBundle, /format_version/)
    end
  end

  describe '.parse — the closed type map' do
    it 'maps every legacy type name to a source and an output' do
      described_class::TYPE_MAP.each do |type, expected|
        parsed = described_class.parse({ 'name' => 'A', 'type' => type }.to_json)

        expect(parsed.slice('source', 'output')).to eq(expected)
      end
    end

    it 'separates the two axes reporter conflated' do
      # One `type` value, two columns out — finding S-2's whole point. `issue` is per
      # record and `issue_list` is not, and no single three-valued column could say so.
      expect(described_class.parse('{"name":"A","type":"issue"}')['output'])
        .to eq('per_record')
      expect(described_class.parse('{"name":"A","type":"issue_list"}')['output'])
        .to eq('combined')
    end

    it 'REFUSES an unknown type instead of resolving it' do
      # This is the `constantize` line. The old import would have tried to load the
      # named class; this one names what it accepts and stops.
      expect { described_class.parse('{"name":"A","type":"Kernel"}') }
        .to raise_error(described_class::InvalidBundle, /not a report template type/)
    end

    it 'refuses a type that names a real, dangerous constant just as flatly' do
      expect { described_class.parse('{"name":"A","type":"ActiveRecord::Base"}') }
        .to raise_error(described_class::InvalidBundle)
    end

    it 'lets the explicit columns win when a file carries both spellings' do
      json = '{"name":"A","type":"issue","source":"issues","output":"combined"}'

      expect(described_class.parse(json)['output']).to eq('combined')
    end
  end

  describe '.parse — what the old import would have executed' do
    it 'does not instantiate a class named by the YAML' do
      # `!ruby/object:` is the construct `YAML.load_file` honours and `safe_load`
      # refuses. The refusal is typed, so the caller can say why.
      yaml = "---\nname: A\ncontent: !ruby/object:Struct {}\n"

      expect { described_class.parse(yaml) }
        .to raise_error(described_class::InvalidBundle, /could not be read/)
    end

    it 'refuses a YAML alias, so a small file cannot expand into a huge object graph' do
      yaml = "---\na: &anchor\n  name: A\nb: *anchor\nname: A\n"

      expect { described_class.parse(yaml) }
        .to raise_error(described_class::InvalidBundle, /could not be read/)
    end

    it 'raises InvalidBundle and never lets Psych`s own error escape' do
      expect { described_class.parse("---\n\tbad: [") }
        .to raise_error(described_class::InvalidBundle)
    end

    it 'lets a non-StandardError past, because `rescue Exception` is the defect' do
      # The construct being replaced swallowed `SignalException` and `NoMemoryError`.
      # Driven by making the decode step raise one: it must reach the caller untouched.
      allow(JSON).to receive(:parse).and_raise(NotImplementedError, 'boom')

      expect { described_class.parse('{"name":"A"}') }
        .to raise_error(NotImplementedError, 'boom')
    end

    it 'names no constant resolution anywhere in its own source' do
      # The mechanical half of "constantize appears nowhere" (CLAUDE.md §5). A grep is
      # weak evidence about behaviour and strong evidence about a construct, and this
      # is a construct.
      source = File.read(
        File.expand_path('../../lib/redmine_reporter_dashboards/reporting/exchange.rb',
                         __dir__), encoding: 'UTF-8'
      )
      code = source.lines.reject { |line| line.strip.start_with?('#') }.join

      expect(code).not_to match(/constantize|Object\.const_get|YAML\.load_file|rescue Exception/)
    end
  end

  describe '.parse — refusals a person has to read' do
    it 'refuses a file that is not UTF-8' do
      expect { described_class.parse("\xff\xfe{\"name\":\"A\"}".b) }
        .to raise_error(described_class::InvalidBundle, /UTF-8/)
    end

    it 'refuses a document that is not a Hash' do
      expect { described_class.parse('[1,2,3]') }
        .to raise_error(described_class::InvalidBundle, /does not contain a report template/)
    end

    it 'refuses a template with no name, which cannot be saved anyway' do
      expect { described_class.parse('{"template":{"content":"x"}}') }
        .to raise_error(described_class::InvalidBundle, /no name/)
    end

    it 'reads an em-dash without depending on the container`s locale' do
      # HANDOVER §1: `File.read` on a UTF-8 source fails where LANG is unset, and an
      # uploaded file is exactly that case. The encoding is named rather than inherited.
      json = { 'template' => { 'name' => 'Q — 2026', 'content' => 'x' } }.to_json

      expect(described_class.parse(json.b)['name']).to eq('Q — 2026')
    end
  end

  describe 'the boolean coercion' do
    it 'reads the string "false" as false, which ActiveRecord would not' do
      # A string column cast of "false" is TRUE in ActiveRecord, so a hand-written YAML
      # saying `enabled: "false"` would silently enable a template somebody disabled.
      expect(described_class.parse('{"name":"A","enabled":"false"}')['enabled']).to be(false)
    end

    it 'reads a real YAML boolean unchanged' do
      expect(described_class.parse("---\nname: A\nenabled: false\n")['enabled']).to be(false)
      expect(described_class.parse("---\nname: A\nenabled: true\n")['enabled']).to be(true)
    end

    it 'leaves `enabled` absent rather than inventing a default' do
      expect(described_class.parse('{"name":"A"}')).not_to have_key('enabled')
    end
  end
end
