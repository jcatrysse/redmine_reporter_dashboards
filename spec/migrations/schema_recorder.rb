# frozen_string_literal: true

# T-36 — records what the migrations DESCRIBE, without a database.
#
# Run as a subprocess: `ruby spec/migrations/schema_recorder.rb db/migrate` prints JSON on
# stdout. `schema_contract_spec.rb` is the only caller.
#
# --- WHY A SUBPROCESS, AND WHY THAT IS NOT LAZINESS ---
#
# To load a migration file this process has to define `ActiveRecord::Migration`, because
# that is what every migration's superclass expression names. Defining it inside the RSpec
# process would put a STUB of ActiveRecord in the same process as `spec/adapter/`, which
# requires the REAL one whenever `RRD_ADAPTER_URL` is set — and which of the two wins would
# depend on filename order.
#
# That is §Findings E-7 exactly: the Liquid stub and the real gem could not share a process,
# 218 of 1332 examples failed, and the fix was a separate run rather than a cleverer stub.
# A subprocess is the same fix, one dependency over, and it costs one `Open3.capture3`.
#
# --- WHY EXECUTE THE DSL RATHER THAN PARSE IT ---
#
# `script/gates/migration_reversibility.rb` parses, because its questions are about the
# SHAPE of the code ("is there a `down`?"). This one's questions are about the SCHEMA
# ("is `start_date` a date?"), and the authority on what a migration describes is the
# migration's own DSL. Parsing `t.date :start_date, :end_date` correctly means
# reimplementing Rails' argument handling — multiple names per call, options hashes,
# `t.timestamps` expanding to two columns — and a reimplementation that drifts is a spec
# asserting something nobody wrote.

require 'json'

# The minimum surface a migration's class body and `change` method touch. Deliberately
# small: anything a migration calls that is not here raises NoMethodError, loudly, rather
# than being silently recorded as nothing — a recorder that swallows an unknown DDL call
# would report a smaller schema than the migration describes, and every assertion built on
# it would pass.
#
# The stub IS the recorder rather than a separate object the DDL is replayed into, because
# a migration's `change` calls `create_table` with no receiver: the only thing that can
# answer those calls is the instance itself.
module ActiveRecord
  class Migration
    def self.[](_version)
      self
    end

    attr_reader :recorded_tables, :recorded_indexes

    def initialize
      @recorded_tables = {}
      @recorded_indexes = []
    end

    def create_table(name, **options)
      recorder = TableRecorder.new
      yield recorder if block_given?

      columns = recorder.columns
      # Rails adds the implicit primary key unless `id: false`. Recorded, because
      # `technical-spec.md:1202` makes the PRESENCE of an id on the recipients table a
      # requirement and its ABSENCE on the visibility join table a deliberate choice.
      unless options[:id] == false
        columns = [{ 'name' => 'id', 'type' => 'primary_key', 'null' => false, 'default' => nil }] + columns
      end

      @recorded_tables[name.to_s] = { 'columns' => columns, 'id' => options[:id] != false }

      recorder.indexes.each do |index|
        @recorded_indexes << index.merge(
          'table' => name.to_s,
          'name' => index['name'] ||
                    "index_#{name}_on_#{index['columns'].join('_and_')}"
        )
      end
    end

    def add_index(table, columns, **options)
      @recorded_indexes << {
        'table' => table.to_s,
        'columns' => Array(columns).map(&:to_s),
        'unique' => options.fetch(:unique, false),
        # Rails' own derivation when no name is given, from
        # `SchemaStatements#index_name`: "index_#{table}_on_#{columns * '_and_'}".
        'name' => (options[:name] || "index_#{table}_on_#{Array(columns).join('_and_')}").to_s,
        'explicit_name' => !options[:name].nil?
      }
    end

    # 001 asks this. Answering `false` is what makes its guarded `create_table` run, so the
    # recorder sees the table it describes — which is the schema question, separate from
    # the reversibility question the gate asks about the same line.
    def table_exists?(_name)
      false
    end

    def reversible
      yield DirectionStub.new if block_given?
    end

    # `dir.up { ... }` must RUN its block, and `dir.down { ... }` must not.
    #
    # §7 rule 1 explicitly sanctions `reversible do |dir| ... end` as the second legal form
    # of a migration, so it is a form this recorder will meet. The first version stubbed
    # BOTH directions as no-ops, so a migration written that way recorded **zero tables**
    # and `schema_contract_spec.rb` would have asserted happily against a schema it could
    # not see. The recorder describes the UP direction — that is what "the schema this
    # migration describes" means — so `up` yields and `down` does not.
    class DirectionStub
      def up
        yield if block_given?
      end

      def down; end
    end
  end
end

# Captures one `create_table ... do |t| ... end` block.
class TableRecorder
  TYPES = %i[
    integer bigint string text boolean date datetime time float decimal binary
    references belongs_to
  ].freeze

  attr_reader :columns, :indexes

  def initialize
    @columns = []
    @indexes = []
  end

  TYPES.each do |type|
    define_method(type) do |*names, **options|
      names.flatten.each { |name| @columns << column(name, type, options) }
    end
  end

  # Expands exactly as Rails does — two columns, both NOT NULL when `null: false` is
  # passed. `template_versions` asserts the ABSENCE of `updated_at`, so getting this
  # expansion right is what makes that assertion mean anything.
  def timestamps(**options)
    @columns << column('created_at', :datetime, options)
    @columns << column('updated_at', :datetime, options)
  end

  # `t.index` inside `create_table` is the same statement as `add_index`, and ignoring it
  # made every inline index invisible to `schema_contract_spec.rb` — including its name,
  # which is the thing that aborted migration 002 on PostgreSQL the first time it ran.
  # Recorded onto the table being built; the caller stitches the table name in.
  def index(columns, **options)
    @indexes << {
      'columns' => Array(columns).map(&:to_s),
      'unique' => options.fetch(:unique, false),
      'name' => options[:name] && options[:name].to_s,
      'explicit_name' => !options[:name].nil?
    }
  end

  private

  def column(name, type, options)
    {
      'name' => name.to_s,
      'type' => type.to_s,
      'null' => options.key?(:null) ? options[:null] : true,
      'default' => options[:default].nil? ? nil : options[:default].to_s
    }
  end
end

dirs = ARGV.empty? ? ['db/migrate'] : ARGV
# Recursive, because `ActiveRecord::MigrationContext` is — see the same note in
# `script/gates/migration_reversibility.rb`.
files = dirs.flat_map { |dir| Dir[File.join(dir, '**', '*.rb')] }
            .select { |path| File.basename(path) =~ /\A\d+_/ }
            .sort_by { |path| File.basename(path).to_i }

result = { 'migrations' => [], 'tables' => {}, 'indexes' => [] }

files.each do |path|
  # HANDOVER §1: name the encoding. A bare container has no locale, and every file in this
  # repository contains an em-dash.
  source = File.read(path, encoding: 'UTF-8')
  before = ActiveRecord::Migration.subclasses

  eval(source, TOPLEVEL_BINDING, path) # rubocop:disable Security/Eval

  defined_here = ActiveRecord::Migration.subclasses - before
  # Rails runs exactly one migration class per file — `MigrationProxy#migration` takes the
  # constant named after the filename. Two subclasses in one file means one of them never
  # runs, and picking one arbitrarily (`.first`, i.e. whatever order `Class#subclasses`
  # happens to return) would make this recorder describe a schema the database will not
  # have. Refused rather than guessed.
  raise "#{path}: defined no ActiveRecord::Migration subclass" if defined_here.empty?

  if defined_here.size > 1
    raise "#{path}: defines #{defined_here.size} ActiveRecord::Migration subclasses " \
          "(#{defined_here.map(&:name).join(', ')}). Rails runs one per file, so this " \
          'recorder cannot say which schema the database will end up with.'
  end

  klass = defined_here.first

  instance = klass.new
  instance.change

  result['migrations'] << {
    'file' => File.basename(path),
    'class' => klass.name,
    'version' => source[/ActiveRecord::Migration\[([\d.]+)\]/, 1]
  }
  result['tables'].merge!(instance.recorded_tables)
  result['indexes'].concat(instance.recorded_indexes)
end

puts JSON.pretty_generate(result)
