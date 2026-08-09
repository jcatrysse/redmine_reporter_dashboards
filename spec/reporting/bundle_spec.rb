# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/reporting/bundle'

# T-29 — FR-55, FR-56's first half and FR-57. `technical-spec.md` §7b.2.
#
# HOISTED AND NAMESPACED for HANDOVER §1's first trap: a constant assigned inside
# `RSpec.describe` is `Object::…` for the whole process.
module BundleSpecSupport
  # A stand-in for the model, and deliberately not the real one — the whole exchange
  # format is covered in the DB-less suite, which is what keeps it cheap enough to test
  # exhaustively. It answers the two DEGRADING readers because `Exchange` reads those two
  # columns through them (§7 rule 5) rather than off the row.
  FakeTemplate = Struct.new(:id, :name, :description, :content, :source, :output,
                            :orientation, :page_size, :margins, :engine_hint, :enabled,
                            :failure_document, keyword_init: true) do
    def engine_hint_or_nil
      engine_hint
    end

    def failure_document?
      failure_document ? true : false
    end
  end

  DEFAULTS = { description: 'Q report', content: '<h1>{{ project.name }}</h1>',
               source: 'issues', output: 'combined', orientation: 'portrait',
               page_size: 'A4', margins: '20,15,20,15', engine_hint: nil,
               enabled: true, failure_document: false }.freeze

  def self.template(id:, name:, **overrides)
    FakeTemplate.new(**DEFAULTS.merge(id: id, name: name).merge(overrides))
  end

  # THE RECEIVING INSTALLATION. It rebuilds records from parsed attributes and assigns its
  # OWN ids, in bundle order — which is what a real import does and what makes FR-57 a
  # claim worth testing: if the writer sorted by id, the ids being different here would
  # move the templates and the round trip would not close.
  def self.import(parsed, first_id: 900)
    parsed.entries.each_with_index.map do |attributes, index|
      FakeTemplate.new(**DEFAULTS.merge(attributes.transform_keys(&:to_sym))
                                 .merge(id: first_id + index))
    end
  end
end

RSpec.describe RedmineReporterDashboards::Reporting::Bundle do
  # Pinned. CLAUDE.md §6 — and `dump` takes it as a required argument precisely so this is
  # expressible; see the FR-57 note in the class comment.
  let(:exported_at) { '2025-12-29T10:30:20Z' }
  let(:plugin_version) { '0.5.0' }

  def dump(templates)
    described_class.dump(templates, exported_at: exported_at, plugin_version: plugin_version)
  end

  # THE IDS DISAGREE WITH THE NAMES ON PURPOSE. The first version of this fixture used
  # ids 7 and 3 for Quarterly and Annual — so sorting by id and sorting by NAME produced
  # the same list, and the mutation "order by id instead of by name" SURVIVED. A fixture
  # that cannot tell the two rules apart tests neither of them.
  let(:templates) do
    [BundleSpecSupport.template(id: 2, name: 'Quarterly'),
     BundleSpecSupport.template(id: 9, name: 'Annual', page_size: 'A3')]
  end

  describe 'the envelope' do
    it 'is §7b.2\'s four keys, in that order' do
      expect(JSON.parse(dump(templates)).keys)
        .to eq(%w[format_version exported_at plugin_version templates])
    end

    it 'carries the provenance it was given' do
      parsed = JSON.parse(dump(templates))

      expect(parsed['format_version']).to eq(described_class::FORMAT_VERSION)
      expect(parsed['exported_at']).to eq(exported_at)
      expect(parsed['plugin_version']).to eq(plugin_version)
    end

    it 'ends in exactly one newline, so `rake … > bundle.json` is byte-exact' do
      expect(dump(templates)).to end_with("}\n")
      expect(dump(templates)).not_to end_with("\n\n")
    end
  end

  describe 'the template payload' do
    # ONE FIELD LIST, NOT TWO. The bundle takes its fields from `Exchange::EXPORTED_FIELDS`
    # rather than restating them, because the failure mode of a second list is silent:
    # a field missing from BOTH the export and the re-export still round-trips
    # byte-identically, which is exactly how `failure_document` was lost once already.
    it 'is exactly the fields Exchange exports, in Exchange\'s order' do
      first = JSON.parse(dump(templates))['templates'].first

      expect(first.keys)
        .to eq(RedmineReporterDashboards::Reporting::Exchange::EXPORTED_FIELDS)
    end

    it 'reads the two rule-5 columns through their degrading readers' do
      # An install one minor behind: the columns, and therefore the readers, are absent.
      behind = Struct.new(:id, :name, :content, keyword_init: true)
                     .new(id: 1, name: 'Behind', content: 'x')

      payload = JSON.parse(dump([behind]))['templates'].first

      expect(payload['engine_hint']).to be_nil
      expect(payload['failure_document']).to be_nil
    end
  end

  # --- ORDER -----------------------------------------------------------------------------
  describe 'the order it writes templates in' do
    # §Findings S-13's table: value agreement "says nothing about the bucket's label, its
    # ORDER, its existence". Order is what makes FR-57 hold across two installations, so
    # it is asserted on its own rather than left to the round-trip test to imply.
    it 'is by name, not by the id this installation happened to assign' do
      names = JSON.parse(dump(templates))['templates'].map { |t| t['name'] }

      # Annual is id 9 and Quarterly is id 2, so id order is the REVERSE of this. That is
      # what makes the assertion discriminate — see the note on the fixture.
      expect(names).to eq(%w[Annual Quarterly])
    end

    it 'breaks a tie on name with the id, so the sort is total' do
      tied = [BundleSpecSupport.template(id: 9, name: 'Same'),
              BundleSpecSupport.template(id: 2, name: 'Same', page_size: 'A3')]

      sizes = JSON.parse(dump(tied))['templates'].map { |t| t['page_size'] }

      expect(sizes).to eq(%w[A3 A4])
    end
  end

  # --- FR-57 -----------------------------------------------------------------------------
  describe 'export -> import -> export (FR-57)' do
    it 'is byte-identical' do
      first = dump(templates)
      second = dump(BundleSpecSupport.import(described_class.parse(first)))

      expect(second).to eq(first)
    end

    # THE STRONGER HALF, AND THE ONE THAT CANNOT BE SATISFIED BY LUCK. The assertion above
    # pins the whole file, envelope included — so it would also pass if the payload were
    # empty on both sides. This one compares ONLY the templates, so neither half can hide
    # a change in the other. CLAUDE.md's brief for this task puts it exactly: value
    # agreement proves arithmetic and nothing else.
    it 'preserves the template payload independently of the envelope' do
      first = described_class.parse(dump(templates))
      # A DIFFERENT ENVELOPE ON THE SECOND EXPORT, deliberately: two exports taken at
      # different moments legitimately differ in `exported_at`, and FR-57's claim is about
      # the templates surviving, not about a file being frozen in time.
      second = described_class.dump(BundleSpecSupport.import(first),
                                    exported_at: '2099-01-01T00:00:00Z',
                                    plugin_version: '9.9.9')

      expect(JSON.parse(second)['templates']).to eq(JSON.parse(dump(templates))['templates'])
      expect(JSON.parse(second)['exported_at']).not_to eq(exported_at)
    end

    it 'is still byte-identical on a third pass, so it has actually converged' do
      first = dump(templates)
      second = dump(BundleSpecSupport.import(described_class.parse(first)))
      third = dump(BundleSpecSupport.import(described_class.parse(second)))

      expect(third).to eq(first)
    end

    # NON-ASCII IS WHERE A ROUND TRIP USUALLY BREAKS, and it breaks silently: `JSON.generate`
    # emits raw UTF-8 rather than `\uXXXX`, so a writer that escaped on one pass and not the
    # other would produce two files that PARSE the same and differ in bytes.
    it 'survives a template whose name and content are not ASCII' do
      unicode = [BundleSpecSupport.template(id: 1, name: 'Übersicht — Quartal',
                                            content: "<h1>Отчёт 中文</h1> ")]
      first = dump(unicode)

      expect(dump(BundleSpecSupport.import(described_class.parse(first)))).to eq(first)
      expect(JSON.parse(first)['templates'].first['name']).to eq('Übersicht — Quartal')
    end

    it 'keeps a disabled template disabled, rather than reading "false" as true' do
      off = [BundleSpecSupport.template(id: 1, name: 'Off', enabled: false)]

      round_tripped = described_class.parse(dump(off)).entries.first

      expect(round_tripped['enabled']).to be(false)
    end
  end

  # --- READING ---------------------------------------------------------------------------
  describe '.parse' do
    it 'answers EVERY template in the bundle, not the first' do
      parsed = described_class.parse(dump(templates))

      expect(parsed.entries.length).to eq(2)
      expect(parsed.entries.map { |e| e['name'] }).to eq(%w[Annual Quarterly])
    end

    it 'keeps the envelope, which is what `exchange:plan` prints' do
      parsed = described_class.parse(dump(templates))

      expect(parsed.exported_at).to eq(exported_at)
      expect(parsed.plugin_version).to eq(plugin_version)
    end

    # THE SINGLE-TEMPLATE SHAPE `Exchange.dump` HAS WRITTEN SINCE T-23. The editor's Export
    # button produced these for a whole release, so refusing them would break a file
    # somebody exported last month.
    it 'reads the single-template shape this plugin used to write' do
      legacy = JSON.generate('format_version' => 1,
                             'template' => { 'name' => 'Old', 'content' => 'x' })

      expect(described_class.parse(legacy).entries.map { |e| e['name'] }).to eq(['Old'])
    end

    it 'reads the base plugin\'s wrapper and resolves its type through the closed map' do
      legacy = JSON.generate('report_template' => { 'name' => 'Reporter',
                                                    'type' => 'IssueListReportTemplate' })

      entry = described_class.parse(legacy).entries.first

      expect(entry['source']).to eq('issues')
      expect(entry['output']).to eq('combined')
    end

    it 'reads YAML, because that is the format the base plugin wrote' do
      yaml = "templates:\n  - name: From YAML\n    content: hello\n"

      expect(described_class.parse(yaml).entries.first['name']).to eq('From YAML')
    end
  end

  # --- REFUSALS ---------------------------------------------------------------------------
  describe 'what it refuses' do
    def refusal(content)
      described_class.parse(content)
      nil
    rescue described_class::InvalidBundle => e
      e.message
    end

    it 'refuses a YAML alias, which is how a small file becomes a very large object graph' do
      bomb = "a: &x [1,1,1]\nb: *x\ntemplates: []\n"

      expect(refusal(bomb)).to match(/could not be read/)
    end

    it 'refuses a YAML file naming a Ruby class' do
      expect(refusal("--- !ruby/object:Kernel {}\n")).to match(/could not be read/)
    end

    it 'refuses a format_version it does not know, rather than reading it optimistically' do
      future = JSON.generate('format_version' => 99, 'templates' => [])

      expect(refusal(future)).to match(/format_version 99/)
    end

    it 'accepts an ABSENT format_version, because the base plugin wrote none' do
      expect(refusal(JSON.generate('templates' => [{ 'name' => 'X' }]))).to be_nil
    end

    it 'refuses a type outside the closed map, naming what is accepted' do
      unknown = JSON.generate('templates' => [{ 'name' => 'X', 'type' => 'Kernel' }])

      expect(refusal(unknown)).to match(/not a report template type/)
    end

    it 'refuses `templates` that is not a list' do
      expect(refusal(JSON.generate('templates' => { 'name' => 'X' })))
        .to match(/must be a list/)
    end

    it 'refuses an entry that is not a set of fields, and says which one' do
      expect(refusal(JSON.generate('templates' => [{ 'name' => 'ok' }, 'nonsense'])))
        .to match(/template 2 .*String/)
    end

    it 'refuses a template with no name' do
      expect(refusal(JSON.generate('templates' => [{ 'content' => 'x' }])))
        .to match(/no name/)
    end

    it 'refuses a document that is not a bundle at all' do
      expect(refusal(JSON.generate('hello' => 'world'))).to match(/does not contain a report/)
    end

    it 'refuses bytes that are not UTF-8' do
      expect(refusal("\xFF\xFE not text".b)).to match(/not valid UTF-8/)
    end

    # SIZE BOUNDS ARE REFUSALS, NOT CRASHES. A bundle is a file somebody was handed, and
    # `parse` builds one attribute Hash per entry — so the number of entries and the size
    # of the file are both things the sender chooses. Driven by lowering the limit rather
    # than by building a 32 MiB String.
    it 'refuses a file past the byte limit' do
      stub_const("#{described_class}::MAX_BYTES", 16)

      expect(refusal(JSON.generate('templates' => [{ 'name' => 'X' }])))
        .to match(/bytes and the limit is 16/)
    end

    # MEASURED IN BYTES, NOT CHARACTERS, AND THE FIXTURE HAS TO BE ABLE TO TELL. The first
    # version of this bound was only exercised against ASCII, where `length` and `bytesize`
    # are equal — so the mutation "measure size in characters" SURVIVED. This document is
    # under the limit by codepoints and over it by bytes, which is the whole point of the
    # bound: what the process has to hold is bytes.
    it 'counts bytes rather than codepoints, so multi-byte text is not under-measured' do
      document = JSON.generate('templates' => [{ 'name' => '中' * 40 }])
      expect(document.length).to be < document.bytesize
      stub_const("#{described_class}::MAX_BYTES", document.length + 1)

      expect(refusal(document)).to match(/bytes and the limit is/)
    end

    it 'refuses more templates than the limit, naming both numbers' do
      stub_const("#{described_class}::MAX_TEMPLATES", 2)
      many = JSON.generate('templates' => Array.new(3) { |i| { 'name' => "T#{i}" } })

      expect(refusal(many)).to match(/carries 3 templates and the limit is 2/)
    end
  end

  # --- THE FIELDS A BUNDLE MAY NOT CARRY ---------------------------------------------------
  describe 'the three fields a bundle cannot carry at all' do
    # THIS IS THE MECHANISM, and the importer's own `template.visibility = PRIVATE` is the
    # second one. Mutation testing is what established the order of those two: forcing the
    # visibility, the author and the project in `BundleImport#create` all SURVIVED being
    # removed, because none of the three ever arrives — `Exchange.attributes_from` slices
    # the node to `EXPORTED_FIELDS` and these are not in it.
    #
    # So the closed FIELD LIST is what holds the property, it is asserted here, and the
    # assignments in the importer are documented redundancy rather than the guard. Recorded
    # rather than deleted because a future field added to `EXPORTED_FIELDS` would silently
    # move the property from one to the other.
    %w[visibility author_id project_id id lock_version source_template_id].each do |field|
      it "does not export or import #{field}" do
        expect(RedmineReporterDashboards::Reporting::Exchange::EXPORTED_FIELDS)
          .not_to include(field)
      end
    end

    it 'drops them from a file that names them anyway' do
      hostile = JSON.generate(
        'templates' => [{ 'name' => 'Hostile', 'content' => 'x', 'visibility' => 2,
                          'author_id' => 99, 'project_id' => 42, 'id' => 7 }]
      )

      entry = described_class.parse(hostile).entries.first

      expect(entry.keys).not_to include('visibility', 'author_id', 'project_id', 'id')
    end
  end

  # --- THE CONSTRUCT THIS REPLACES ---------------------------------------------------------
  describe 'the source of this module' do
    let(:source) do
      # ENCODING NAMED — HANDOVER §1. Without it this raises `invalid byte sequence in
      # US-ASCII` on a container with no locale and passes on a developer's machine.
      File.read(
        File.expand_path('../../lib/redmine_reporter_dashboards/reporting/bundle.rb',
                         __dir__), encoding: 'UTF-8'
      )
    end

    # The three constructs §7b.2 exists to delete. `Exchange`'s own spec asserts this for
    # `Exchange`; the bundle is the second file in the same feature and would be the
    # obvious place to reintroduce one.
    it 'contains no constantize, no YAML.load and no rescue Exception' do
      code = source.lines.reject { |line| line.match?(/\A\s*#/) }.join

      expect(code).not_to match(/constantize/)
      expect(code).not_to match(/YAML\.load(?!_file_safe)/)
      expect(code).not_to match(/rescue\s+Exception/)
    end

    # ONE TYPE MAP IN THE PLUGIN, AND IT IS `Exchange`'s. The task brief is explicit:
    # "`Reporting::Exchange` already exists from T-23 and already has the closed TYPE_MAP;
    # read it before writing a second one."
    it 'declares no type map of its own' do
      expect(source).not_to match(/TYPE_MAP\s*=/)
    end
  end
end
