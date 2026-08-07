# frozen_string_literal: true

# T-36 — §7's reversibility rules, as a spec.
#
# It drives `script/gates/migration_reversibility.rb`, the same file
# `script/gates/migration_reversibility.sh` runs, so the gate and the suite cannot disagree
# about what the rules are. That is the same discipline T-37's `Accept:` list asks for
# between the editor's lint panel and the rake task: one object, two callers, asserted by a
# test that runs both.
#
# What this file CANNOT answer is whether the migrations actually reverse against a
# database — that is `script/migrate_updown.sh` and the `migrate-updown` CI job. A migration
# can pass every rule here and still fail there. Both halves are gate G11.
#
# No Rails, no ActiveRecord, no database: the reader parses text.

require 'tempfile'

require_relative '../spec_helper'
require_relative '../../script/gates/migration_reversibility'

RSpec.describe MigrationReversibility do
  # METHODS, NOT CONSTANTS, AND THE REASON IS A REAL FAILURE THIS FILE CAUSED.
  #
  # A constant assigned inside an `RSpec.describe` block is NOT scoped to the example
  # group — the block is a closure whose lexical scope is the file's top level, so
  # `FIXTURES = ...` here defines `Object::FIXTURES` for the whole process. The first
  # version of this file did exactly that, and `spec/charts/golden_svg_spec.rb:50` also
  # defines `FIXTURES` (a Hash of chart fixtures). Whichever loaded second won, and in the
  # randomised full run two of T-16's examples went red for a reason that had nothing to
  # do with charts. In isolation both files passed.
  #
  # That is CLAUDE.md §Phase 2's "passes locally, fails in CI" list, arriving from the
  # cheapest possible source. `spec/shipped_templates_lint_spec.rb:36` already defines a
  # top-level `ROOT`, so the same collision was waiting there too.
  def plugin_root
    File.expand_path('../..', __dir__)
  end

  def migrations_dir
    File.join(plugin_root, 'db', 'migrate')
  end

  def fixtures_dir
    File.join(__dir__, 'fixtures')
  end

  def allowlist_path
    File.join(plugin_root, 'script', 'gates', 'migration_reversibility.allowlist')
  end

  def scan(dir, allowlist: {})
    described_class.scan([dir], allowlist: allowlist)
  end

  # ---------------------------------------------------------------------------
  # The reader itself. This block exists because the failure mode of reading an AST is
  # returning NOTHING — and a rule that fires on nothing is indistinguishable from a rule
  # that found nothing wrong. Every assertion below is a concrete, known value.
  # ---------------------------------------------------------------------------
  describe 'the reader itself' do
    it 'finds every migration in db/migrate, in numeric order' do
      files = described_class.migration_files([migrations_dir]).map { |p| File.basename(p) }

      expect(files.first).to eq('001_create_reporter_dashboards_tables.rb')
      expect(files.size).to be >= 7
      expect(files).to eq(files.sort_by { |f| f.to_i })
    end

    it 'reads the argument list of a receiverless call, which is NOT where a CALL keeps it' do
      # The reader's own first bug: `add_index` is an FCALL, whose arguments are at
      # children[1]; reading children[2] returned nil and every index silently passed the
      # length rule. Asserted directly so a refactor cannot reintroduce it quietly.
      tree = RubyVM::AbstractSyntaxTree.parse('add_index :t, [:a, :b], name: "x"')
      call = described_class.find_node(tree) { |n| n.type == :FCALL }

      args = described_class.call_arguments(call)
      expect(args).not_to be_nil
      expect(described_class.literal_value(args.children[0])).to eq('t')
      expect(described_class.hash_argument_value(args, :name)).to eq('x')
    end

    it 'derives an index name the way Rails does' do
      tree = RubyVM::AbstractSyntaxTree.parse('add_index :issues, [:project_id, :status_id]')
      call = described_class.find_node(tree) { |n| n.type == :FCALL }
      args = described_class.call_arguments(call)

      expect(described_class.derived_index_name('issues', args.children[1]))
        .to eq('index_issues_on_project_id_and_status_id')
    end

    it 'reads a qualified constant as a full path, not as its first segment' do
      # The second bug: `A::B` is a COLON2 whose right child is a plain Symbol, so a scan
      # for CONST nodes sees only `A` — which made `ActiveRecord::Base` indistinguishable
      # from the allowlisted `ActiveRecord::Migration`.
      tree = RubyVM::AbstractSyntaxTree.parse('ActiveRecord::Base.connection')
      colon = described_class.find_node(tree) { |n| n.type == :COLON2 }

      expect(described_class.constant_path(colon)).to eq('ActiveRecord::Base')
    end

    it 'identifies a node by source position, because children re-wraps on every call' do
      # The third bug, and the least guessable: `Node#children` builds fresh wrappers, so
      # `object_id` is not stable across two traversals.
      tree = RubyVM::AbstractSyntaxTree.parse('ActiveRecord::Migration')
      first = described_class.collect_nodes(tree) { |n| n.type == :CONST }.first
      second = described_class.collect_nodes(tree) { |n| n.type == :CONST }.first

      expect(first.object_id).not_to eq(second.object_id)
      expect(described_class.node_key(first)).to eq(described_class.node_key(second))
    end

    it 'reports a file it could not parse instead of passing it' do
      findings = described_class.scan_file(File.join(fixtures_dir, '017_syntax_error.rb'))

      expect(findings.map(&:rule)).to eq(['parse'])
      expect(findings.first.message).to include('NOTHING about it was checked')
    end
  end

  # ---------------------------------------------------------------------------
  # One fixture per rule. See fixtures/README.md.
  # ---------------------------------------------------------------------------
  describe 'the rules, against a migration that breaks each one' do
    def rules_for(fixture)
      described_class.scan_file(File.join(fixtures_dir, fixture)).map(&:rule).uniq
    end

    it 'rejects an up/down pair' do
      expect(rules_for('010_up_down_pair.rb')).to contain_exactly('no_up_down')
    end

    it 'rejects `execute` in a change block' do
      expect(rules_for('011_executes.rb')).to include('no_execute')
    end

    it 'rejects a migration that names a model constant (§7 rule 3)' do
      expect(rules_for('012_touches_content.rb')).to include('no_model_constant')
    end

    it 'rejects a migration version newer than the oldest Rails in the span' do
      expect(rules_for('013_too_new.rb')).to include('migration_version')
    end

    it 'rejects an index name longer than the tighter engine allows' do
      expect(rules_for('014_long_index.rb')).to include('index_name_length')
    end

    it 'rejects a migration declaring itself irreversible' do
      expect(rules_for('015_irreversible.rb')).to include('no_irreversible')
    end

    it 'rejects DDL inside a conditional in a change block' do
      expect(rules_for('016_conditional.rb')).to contain_exactly('no_conditional_ddl')
    end

    it 'rejects raw SQL reached through a connection rather than called bare' do
      # `ActiveRecord::Base.connection.execute` has a RECEIVER, so a receiverless-only
      # check would wave it through. The execute rule is deliberately not restricted that
      # way; the data rule is.
      expect(rules_for('018_connection_execute.rb')).to include('no_execute')
    end

    it 'rejects a raw result read' do
      expect(rules_for('019_reads_content.rb')).to include('no_execute')
    end

    it 'rejects a row-level write' do
      expect(rules_for('020_data_statement.rb')).to include('no_data_statement')
    end

    # The meta-test that stops a new rule being added without a fixture. A rule with no
    # fixture is a rule nobody has watched fire.
    it 'has a fixture that fires EVERY declared rule' do
      fired = Dir[File.join(fixtures_dir, '*.rb')]
              .flat_map { |path| described_class.scan_file(path).map(&:rule) }
              .uniq

      expect(described_class::RULES.keys - fired).to eq([]),
                                                       'every rule id needs a fixture in ' \
                                                       'spec/migrations/fixtures/ — see its README'
    end
  end

  # ---------------------------------------------------------------------------
  # The real tree.
  # ---------------------------------------------------------------------------
  describe 'db/migrate' do
    it 'has no findings once the committed allowlist is applied' do
      allowlist = described_class.load_allowlist(allowlist_path)
      findings = scan(migrations_dir, allowlist: allowlist)

      expect(findings.map(&:to_s)).to eq([])
    end

    it 'has exactly one exemption, and it is 001 conditional DDL' do
      # Pinned so that adding a second exemption is a deliberate edit to this spec rather
      # than a line nobody reviewed. The list must shrink, never grow.
      allowlist = described_class.load_allowlist(allowlist_path)

      expect(allowlist.keys).to eq(['001_create_reporter_dashboards_tables.rb'])
      expect(allowlist['001_create_reporter_dashboards_tables.rb'].to_a).to eq(['no_conditional_ddl'])
    end

    it 'WOULD fail without that exemption, so the exemption is load-bearing rather than decorative' do
      findings = scan(migrations_dir, allowlist: {})

      expect(findings.map(&:rule)).to eq(['no_conditional_ddl'])
      expect(findings.first.file).to end_with('001_create_reporter_dashboards_tables.rb')
    end

    it 'refuses an exemption with no reason' do
      Tempfile.create(['allowlist', '.txt']) do |file|
        file.write("001_create_reporter_dashboards_tables.rb no_conditional_ddl\n")
        file.flush

        expect { described_class.load_allowlist(file.path) }
          .to raise_error(ArgumentError, /has no reason/)
      end
    end

    it 'refuses an exemption naming a rule that does not exist' do
      Tempfile.create(['allowlist', '.txt']) do |file|
        file.write("001_create_reporter_dashboards_tables.rb no_such_rule # because\n")
        file.flush

        expect { described_class.load_allowlist(file.path) }
          .to raise_error(ArgumentError, /unknown rule id/)
      end
    end

    it 'declares a migration version that exists on every Rails in the span' do
      # MEASURED: activerecord-6.1.7.10's compatibility.rb has `V6_1 = Current`, so 6.1 is
      # the newest constant Redmine 5.1 knows. Rails 7.2 and 8.1 both still ship V4_2 and
      # everything up to their own. Anything above 6.1 raises before the migration runs.
      versions = Dir[File.join(migrations_dir, '*.rb')].map do |path|
        File.read(path, encoding: 'UTF-8')[/ActiveRecord::Migration\[([\d.]+)\]/, 1]
      end

      expect(versions).to all(be_a(String))
      versions.each do |version|
        expect(Gem::Version.new(version)).to be <= described_class::MAX_MIGRATION_VERSION
      end
    end
  end
end
