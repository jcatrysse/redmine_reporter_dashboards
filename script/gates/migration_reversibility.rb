# frozen_string_literal: true

# T-36 — the migration reversibility reader. Gate G11's static half.
#
# `implementation-plan.md:2131` asks for "no `up`/`down` pair and no `execute` in a `change`
# block anywhere — **a grep gate**". This is not a grep, and the difference is the point.
#
# --- WHY IT PARSES ---
#
# The questions §7's rules ask cannot be answered by matching text:
#
#   * "does this migration define `down`?"  A regexp cannot tell `def down` from the word
#     `down` in a comment explaining why there isn't one — and this repository's comments
#     are full of exactly that sentence.
#   * "is there an `execute` inside the `change` block?"  Requires knowing which method
#     body a call is in.
#   * "does any migration touch template content?"  Requires knowing that a call has no
#     receiver and is not, say, `t.update` on a table definition.
#
# The repository has been bitten twice by scanners that could not tell one construct from
# another (§Findings E-14, and the ES5 "shorthand method" regexp deleted from
# `mermaid_boot_spec.rb`). `RubyVM::AbstractSyntaxTree` is Ruby's own parser, needs no gem
# and exists on every Ruby in the CI matrix (3.2 → 3.4).
#
# --- THE FAILURE MODE OF READING AN AST, AND WHAT ANSWERS IT ---
#
# It is the opposite of a regexp's: a construct the reader never learned makes it return
# NOTHING, and every rule built on it passes vacuously. `spec/migrations/reversibility_spec.rb`
# answers that with `spec/migrations/fixtures/`, a directory of migrations that each break
# exactly one rule. If you extend this reader, extend those fixtures — a construct that is
# not in them is a construct this gate cannot see.
#
# Usage:
#   ruby script/gates/migration_reversibility.rb [dir ...]     # prints findings, exit 1 if any
#   require_relative '.../migration_reversibility'             # MigrationReversibility.scan(paths)

require 'set'

module MigrationReversibility
  # Rule ids are stable strings: the allowlist keys on them, and so does the spec.
  RULES = {
    'migration_version'  => 'declares ActiveRecord::Migration[<= 6.1]',
    'no_up_down'         => 'defines `change`, never an `up`/`down` pair',
    'no_irreversible'    => 'never declares itself irreversible',
    'no_execute'         => 'never calls `execute` or a raw exec_/select_ statement',
    'no_data_statement'  => 'never reads or writes rows (§7 rule 3)',
    'no_model_constant'  => 'never names a model constant (§7 rule 3)',
    'index_name_length'  => 'every index name fits the shortest engine limit',
    'no_conditional_ddl' => 'no `if`/`unless`/`case` around DDL in a `change` block',
    'no_dynamic_dispatch' => 'no send/define_method/eval/constantize — a name a parser cannot read',
    'no_uninvertible_ddl' => 'no DDL Rails cannot invert, and no if_not_exists/if_exists'
  }.freeze

  # The newest `ActiveRecord::Migration[...]` version declarable on EVERY Rails in the
  # support span. MEASURED: activerecord-6.1.7.10's
  # `lib/active_record/migration/compatibility.rb:16` is `V6_1 = Current`, so 6.1 is the
  # newest constant that exists there; Rails 7.2 and 8.1 both still ship V4_2 … their own.
  # A migration declaring [7.2] raises `ArgumentError: Unknown migration version` on
  # Redmine 5.1 before a single statement runs.
  MAX_MIGRATION_VERSION = Gem::Version.new('6.1')

  # 62, not 63. PostgreSQL's identifier limit is 63 bytes and MySQL's is 64, so 63 would
  # be the exact edge on the tighter engine — and this project's first migration run hit
  # precisely that wall with a 64-character derived name, failing on PostgreSQL while it
  # would have succeeded on MySQL. One character of margin removes the off-by-one argument.
  MAX_INDEX_NAME = 62

  # Raw SQL and raw result reads. `execute` is named by §7 rule 1; the rest are the same
  # thing wearing different names, and a rule that only knows one spelling is a rule
  # somebody routes around without meaning to.
  EXECUTE_METHODS = %i[
    execute exec_query exec_update exec_delete exec_insert
    select_all select_one select_value select_values select_rows
  ].to_set.freeze

  # Row-level reads and writes. §7 rule 3: "A schema migration may not read or write
  # template content" — enforced as "may not read or write ROWS at all", which is stronger,
  # simpler to check, and costs nothing because no migration in this plugin needs to.
  #
  # SPLIT BY RECEIVER, and the split is a real finding rather than tidiness. The first
  # version required a receiverless call, so `connection.update("UPDATE …")` and
  # `Foo.connection.insert(…)` — the two forms anyone actually writes — were invisible.
  # Names that unambiguously touch rows fire on ANY receiver; names that a migration might
  # legitimately call on an Array (`first`, `select`, `count`) fire only when receiverless,
  # where the receiver can only be the migration itself.
  DATA_METHODS_ANY_RECEIVER = %i[
    update_all delete_all destroy_all insert insert_all upsert upsert_all
    create create! save save! update update! find_by find_by! find_each find_in_batches
  ].to_set.freeze

  DATA_METHODS_RECEIVERLESS = %i[
    destroy find first last pluck where count exists? select
  ].to_set.freeze

  # A name a parser cannot follow. `define_method(:down)` defines a method this reader's
  # `DEFN` scan cannot see; `send(:execute, …)` reaches a forbidden method by a computed
  # name; `constantize`/`const_get` reach a model without ever writing a constant. Each is
  # a hole the review of T-36 walked through, and none has a legitimate use in a migration
  # that only creates tables. Refused outright — the same call `technical-spec.md` §4.1
  # makes about `define_method` in a controller: "its name can be computed, so no parser
  # can promise to know" what it does.
  DYNAMIC_DISPATCH = %i[
    send public_send __send__ define_method define_singleton_method
    eval instance_eval class_eval module_eval instance_exec class_exec
    constantize safe_constantize const_get const_set
  ].to_set.freeze

  # DDL whose inverse Rails cannot compute. `CommandRecorder` raises
  # `IrreversibleMigration` for these at down-time — which is §7 rule 1's forbidden outcome
  # arriving by accident rather than by declaration, and only on the day somebody rolls
  # back. Named here so it arrives at review time instead.
  #
  # `change_column` has no recorded inverse at all. `remove_column` is invertible only when
  # the type is given. `drop_table` is invertible only with a block describing the table.
  # `change_column_default` needs `from:`/`to:`.
  UNINVERTIBLE_DDL = %i[
    change_column change_column_null remove_columns remove_belongs_to
  ].to_set.freeze

  # Constants a migration may legitimately name, as FULL paths.
  #
  # `ActiveRecord` alone is deliberately NOT here, and that is the interesting part: a bare
  # allowlist entry for the namespace would wave through
  # `ActiveRecord::Base.connection.execute("DELETE FROM …")`, which is a data statement
  # dressed as infrastructure and reaches template content just as surely as a model does.
  # Only the superclass reference a migration actually needs is permitted.
  CONSTANT_ALLOWLIST = %w[
    ActiveRecord::Migration
    Time Date DateTime
  ].to_set.freeze

  Finding = Struct.new(:file, :line, :rule, :message, keyword_init: true) do
    def to_s
      "#{file}:#{line}: [#{rule}] #{message}"
    end
  end

  module_function

  # Every migration under the given directories, sorted by numeric prefix so a finding list
  # reads in migration order.
  #
  # `**` IS LOAD-BEARING. `ActiveRecord::MigrationContext#migration_files` globs
  # `"#{paths}/**/[0-9]*_*.rb"` — recursively — and Redmine's plugin migrator inherits it
  # (`lib/redmine/plugin.rb`, `MigrationContext < ActiveRecord::MigrationContext`). A reader
  # that globs one level therefore reports CLEAN on a tree where `db/migrate/sub/008.rb`
  # runs on every install: the gate would not be wrong about that file, it would not know
  # it exists. Same fix in `spec/migrations/schema_recorder.rb` and in the shell wrapper's
  # `find`, because all three have to agree with Rails about what a migration is.
  def migration_files(dirs)
    Array(dirs).flat_map { |dir| Dir[File.join(dir, '**', '*.rb')] }
               .select { |path| File.basename(path) =~ /\A\d+_/ }
               .sort_by { |path| File.basename(path).to_i }
  end

  def scan(dirs, allowlist: {})
    migration_files(dirs).flat_map { |path| scan_file(path, allowlist: allowlist) }
  end

  # `allowlist` maps a basename to the Set of rule ids that file is excused from. An
  # exemption without a reason is how a gate becomes a formality, so the reason lives in
  # the allowlist FILE and the loader below refuses a line that has none.
  def scan_file(path, allowlist: {})
    # HANDOVER §1: name the encoding. Ruby's default external encoding follows the locale,
    # and a bare container has none — so reading any file in this repo that contains an
    # em-dash raises `invalid byte sequence in US-ASCII`. It passes on a developer machine
    # and fails in a minimal container.
    source = File.read(path, encoding: 'UTF-8')
    tree = RubyVM::AbstractSyntaxTree.parse(source)
    exempt = allowlist[File.basename(path)] || Set.new

    findings = []
    findings.concat(check_version(path, tree))
    findings.concat(check_methods(path, tree))
    findings.concat(check_calls(path, tree))
    findings.concat(check_constants(path, tree))
    findings.concat(check_index_names(path, tree))
    findings.concat(check_conditional_ddl(path, tree))
    findings.reject { |f| exempt.include?(f.rule) }
  rescue SyntaxError => e
    [Finding.new(file: path, line: 0, rule: 'parse',
                 message: "could not be parsed, so NOTHING about it was checked: #{e.message}")]
  end

  # --- rule implementations -------------------------------------------------

  def check_version(path, tree)
    # The superclass is `ActiveRecord::Migration[6.1]` — an INDEX call (`[]`) on a COLON2
    # constant, whose argument is a float or a string literal.
    node = find_node(tree) do |n|
      n.type == :CLASS && n.children[1] && index_call_on_migration?(n.children[1])
    end
    unless node
      return [Finding.new(file: path, line: 1, rule: 'migration_version',
                          message: 'no `class X < ActiveRecord::Migration[...]` found — a ' \
                                   'migration whose superclass this reader cannot see is a ' \
                                   'migration nothing below has checked')]
    end

    version = migration_version_argument(node.children[1])
    if version.nil?
      return [Finding.new(file: path, line: node.first_lineno, rule: 'migration_version',
                          message: 'the ActiveRecord::Migration[...] version is not a literal, ' \
                                   'so it cannot be checked against the support span')]
    end

    return [] if Gem::Version.new(version) <= MAX_MIGRATION_VERSION

    [Finding.new(file: path, line: node.first_lineno, rule: 'migration_version',
                 message: "declares ActiveRecord::Migration[#{version}]; the newest version " \
                          "that exists on every Rails in the span is #{MAX_MIGRATION_VERSION}. " \
                          'Redmine 5.1 runs Rails 6.1, where anything newer raises ' \
                          '`ArgumentError: Unknown migration version` before the migration runs.')]
  end

  def check_methods(path, tree)
    findings = []
    defs = collect_nodes(tree) { |n| n.type == :DEFN }
    names = defs.map { |n| n.children[0] }

    %i[up down].each do |forbidden|
      defs.select { |n| n.children[0] == forbidden }.each do |node|
        findings << Finding.new(
          file: path, line: node.first_lineno, rule: 'no_up_down',
          message: "defines `#{forbidden}`. §7 rule 1: every migration is a reversible " \
                   '`change`, or declares `reversible do |dir|` explicitly. An `up`/`down` ' \
                   'pair is two implementations that drift.'
        )
      end
    end

    unless names.include?(:change)
      findings << Finding.new(
        file: path, line: 1, rule: 'no_up_down',
        message: 'defines no `change` method. A migration with nothing to reverse is not ' \
                 'reversible, it is unexamined.'
      )
    end

    findings
  end

  def check_calls(path, tree)
    findings = []

    each_call(tree) do |node, method|
      if method == :irreversible ||
         (method == :raise && mentions_irreversible?(node))
        findings << Finding.new(
          file: path, line: node.first_lineno, rule: 'no_irreversible',
          message: '§7 rule 1: "`irreversible` is not permitted for any migration in the ' \
                   '0.x line — there is nothing in this schema that justifies it."'
        )
      end

      # Deliberately NOT restricted to receiverless calls, unlike the data rule below:
      # `connection.execute` and `ActiveRecord::Base.connection.execute` are the two forms
      # a migration actually reaches for, and both have a receiver. There is no legitimate
      # `execute` in this plugin's migrations under any spelling.
      if EXECUTE_METHODS.include?(method)
        findings << Finding.new(
          file: path, line: node.first_lineno, rule: 'no_execute',
          message: "calls `#{method}`. Raw SQL is not recorded by Rails' CommandRecorder, so " \
                   'a `change` block containing one has a `down` that silently does less ' \
                   'than its `up` did.'
        )
      end

      if DATA_METHODS_ANY_RECEIVER.include?(method) ||
         (DATA_METHODS_RECEIVERLESS.include?(method) && receiverless?(node))
        findings << Finding.new(
          file: path, line: node.first_lineno, rule: 'no_data_statement',
          message: "calls `#{method}`. §7 rule 3: a schema migration may not read or write " \
                   'template content — so it reads and writes no rows at all, and the ' \
                   'importer is a rake task precisely so a schema rollback cannot destroy ' \
                   'imported data (FR-70).'
        )
      end

      if DYNAMIC_DISPATCH.include?(method)
        findings << Finding.new(
          file: path, line: node.first_lineno, rule: 'no_dynamic_dispatch',
          message: "calls `#{method}`. A migration that dispatches by a computed name is a " \
                   'migration no parser can read: `define_method(:down)` defines a method ' \
                   "this reader's `def` scan cannot see, `send(:execute, …)` reaches a " \
                   'forbidden method without naming it, and `constantize` reaches a model ' \
                   'without ever writing a constant. None of the three has a use in a ' \
                   'migration that creates tables.'
        )
      end

      if UNINVERTIBLE_DDL.include?(method) && receiverless?(node)
        findings << Finding.new(
          file: path, line: node.first_lineno, rule: 'no_uninvertible_ddl',
          message: "calls `#{method}`, which Rails' CommandRecorder cannot invert — it raises " \
                   '`IrreversibleMigration` at down-time. That is §7 rule 1\'s forbidden ' \
                   'outcome arriving by accident rather than by declaration, and only on ' \
                   'the day somebody rolls back. Use `reversible do |dir|` and say what ' \
                   'each direction does.'
        )
      end

      if %i[remove_column drop_table].include?(method) && receiverless?(node)
        findings.concat(check_recoverable_removal(path, node, method))
      end

      if receiverless?(node) && DDL_METHODS.include?(method)
        args = call_arguments(node)
        %i[if_not_exists if_exists].each do |flag|
          next unless args && hash_argument_present?(args, flag)

          findings << Finding.new(
            file: path, line: node.first_lineno, rule: 'no_uninvertible_ddl',
            message: "passes `#{flag}:` to `#{method}`. Rails records the command and inverts " \
                     'it UNCONDITIONALLY, so the guard applies to the up direction only: ' \
                     "`create_table :x, if_not_exists: true` becomes a plain `drop_table :x` " \
                     'on the way down, and drops a table this migration did not create. ' \
                     'That is the exact hazard FR-69 clause 2 exists to prevent, one table over.'
          )
        end
      end
    end

    findings
  end

  # `remove_column :t, :c` without a type, and `drop_table :t` without a block, are both
  # irreversible: the recorder has nothing to rebuild from. Rails raises at down-time, which
  # is the wrong time to find out.
  def check_recoverable_removal(path, node, method)
    args = call_arguments(node)
    positional = args ? args.children.compact.count { |c| c.is_a?(RubyVM::AbstractSyntaxTree::Node) && c.type != :HASH } : 0

    case method
    when :remove_column
      return [] if positional >= 3

      [Finding.new(file: path, line: node.first_lineno, rule: 'no_uninvertible_ddl',
                   message: 'calls `remove_column` without a type. Rails can only invert it ' \
                            'when the column type is given — otherwise the down direction ' \
                            'raises IrreversibleMigration.')]
    when :drop_table
      return [] if node.children.compact.any? { |c| c.is_a?(RubyVM::AbstractSyntaxTree::Node) && c.type == :ITER }

      [Finding.new(file: path, line: node.first_lineno, rule: 'no_uninvertible_ddl',
                   message: 'calls `drop_table` without a block. Rails can only invert it when ' \
                            'the block describes the table to rebuild — otherwise the down ' \
                            'direction raises IrreversibleMigration.')]
    else
      []
    end
  end

  # Every constant the file names, as a FULL path, each reported once.
  #
  # `A::B` parses as `COLON2` whose left child is `CONST(A)` and whose right child is the
  # plain Symbol `:B` — so a naive scan for `CONST` nodes reports `A` and never sees `B`,
  # which is how `ActiveRecord::Base` would have looked identical to `ActiveRecord`. The
  # nested `CONST` is therefore collected as part of its path and not reported separately.
  def check_constants(path, tree)
    # Node identity CANNOT be `object_id` here. `RubyVM::AbstractSyntaxTree::Node#children`
    # builds fresh wrapper objects on every call, so the same source node visited by two
    # traversals is two different Ruby objects — which made `ActiveRecord::Migration[6.1]`
    # report a spurious bare `ActiveRecord` on every migration in the tree. Source position
    # is the stable identity.
    skip = Set.new
    collect_nodes(tree) { |n| n.type == :COLON2 }.each do |node|
      left = node.children[0]
      skip << node_key(left) if left.is_a?(RubyVM::AbstractSyntaxTree::Node)
    end
    # A `class Foo < Bar` statement NAMES Foo, it does not reference it. Reporting the
    # migration's own class name made every file in the tree fail the rule.
    collect_nodes(tree) { |n| %i[CLASS MODULE].include?(n.type) }.each do |node|
      name_node = node.children[0]
      skip << node_key(name_node) if name_node.is_a?(RubyVM::AbstractSyntaxTree::Node)
    end

    collect_nodes(tree) { |n| %i[CONST COLON2 COLON3].include?(n.type) }.filter_map do |node|
      next if skip.include?(node_key(node))

      name = constant_path(node)
      next if name.nil? || CONSTANT_ALLOWLIST.include?(name)

      Finding.new(
        file: path, line: node.first_lineno, rule: 'no_model_constant',
        message: "names the constant `#{name}`. A migration that references a model — or " \
                 'reaches a connection through one — can read or write its rows, and §7 ' \
                 'rule 3 forbids that; it also pins the migration to whatever that class ' \
                 'looks like TODAY rather than to what it looked like when it ran.'
      )
    end
  end

  def constant_path(node)
    case node.type
    when :CONST  then node.children[0].to_s
    when :COLON3 then node.children[0].to_s
    when :COLON2
      left = node.children[0]
      right = node.children[1].to_s
      return right if left.nil?

      prefix = left.is_a?(RubyVM::AbstractSyntaxTree::Node) ? constant_path(left) : nil
      prefix ? "#{prefix}::#{right}" : right
    end
  end

  def check_index_names(path, tree)
    findings = []

    each_call(tree) do |node, method|
      # `t.index` inside a `create_table` block is the SAME statement as `add_index`, and
      # the first version of this rule could not see it — it required a receiverless
      # `add_index`, so a 74-character name written as `t.index` sailed through and aborted
      # the migration on PostgreSQL at install time.
      inline = method == :index && node.type == :CALL
      next unless (method == :add_index && receiverless?(node)) || inline

      args = call_arguments(node)
      next unless args && args.type == :LIST

      # `t.index [:a, :b]` has no table argument — the table is the block's own. Its derived
      # name therefore cannot be computed here, so an inline index MUST carry a literal
      # `name:`; that is stricter than Rails and deliberately so.
      table = inline ? nil : literal_value(args.children[0])
      columns_node = inline ? args.children[0] : args.children[1]

      if hash_argument_present?(args, :name)
        explicit = hash_argument_value(args, :name)
        if explicit.nil?
          findings << Finding.new(
            file: path, line: node.first_lineno, rule: 'index_name_length',
            message: 'passes a computed `name:` to an index. This reader cannot measure a ' \
                     'name it cannot read, and a name nobody measured is how a migration ' \
                     'that installs on MySQL aborts on PostgreSQL. Use a literal.'
          )
          next
        end
        name = explicit
      elsif inline
        findings << Finding.new(
          file: path, line: node.first_lineno, rule: 'index_name_length',
          message: '`t.index` inside `create_table` with no `name:`. The name Rails derives ' \
                   'depends on the enclosing table, which this reader cannot see from the ' \
                   'call — and an unmeasured index name is exactly how migration 002 first ' \
                   'aborted on PostgreSQL. Pass an explicit short `name:`.'
        )
        next
      else
        name = derived_index_name(table, columns_node)
        if name.nil?
          findings << Finding.new(
            file: path, line: node.first_lineno, rule: 'index_name_length',
            message: 'passes a non-literal table or column list to `add_index`, so the name ' \
                     'Rails will derive cannot be measured here. Pass an explicit short ' \
                     '`name:`.'
          )
          next
        end
      end

      next if name.length <= MAX_INDEX_NAME

      findings << Finding.new(
        file: path, line: node.first_lineno, rule: 'index_name_length',
        message: "index name #{name.inspect} is #{name.length} characters. PostgreSQL " \
                 "truncates identifiers at 63 and MySQL at 64, so anything over #{MAX_INDEX_NAME} " \
                 'installs on one engine and aborts on the other — which is how this plugin ' \
                 'first failed to migrate. Pass an explicit short `name:`.'
      )
    end

    findings
  end

  # A `change` body whose DDL depends on run-time state has a `down` whose meaning depends
  # on the state at down-time: Rails records the commands the block HAPPENED to emit and
  # inverts those, so a conditional is neither preserved nor reasoned about.
  #
  # `db/migrate/001` is the one file this is allowed for, and it is allowlisted WITH the
  # measurement that justifies it rather than waved through.
  def check_conditional_ddl(path, tree)
    change = find_node(tree) { |n| n.type == :DEFN && n.children[0] == :change }
    return [] unless change

    collect_nodes(change) { |n| %i[IF UNLESS CASE CASE2 CASE3].include?(n.type) }
      .select { |n| collect_nodes(n) { |c| c.type == :FCALL || c.type == :VCALL }.any? { |c| ddl_call?(c) } }
      .map do |node|
        Finding.new(
          file: path, line: node.first_lineno, rule: 'no_conditional_ddl',
          message: 'DDL inside a conditional in a `change` block. Rails records only the ' \
                   'commands the block emitted on THIS run and inverts those, so the down ' \
                   'direction asks the database a different question than the up direction ' \
                   'did — reversibility becomes emergent rather than declared. Use ' \
                   '`reversible do |dir|` and say what each direction does.'
        )
      end
  end

  DDL_METHODS = %i[
    create_table create_join_table drop_table rename_table
    add_column remove_column rename_column change_column
    add_index remove_index rename_index
    add_reference remove_reference add_timestamps remove_timestamps
  ].to_set.freeze

  def ddl_call?(node)
    DDL_METHODS.include?(call_method_name(node))
  end

  # --- AST helpers ----------------------------------------------------------
  #
  # Kept small and shared, because the reader's own bugs are the risk: a helper that
  # quietly returns nil for a node type it does not know makes every rule above pass.

  def children_nodes(node)
    node.children.select { |c| c.is_a?(RubyVM::AbstractSyntaxTree::Node) }
  end

  # Stable identity for a node across traversals — see `check_constants`. Two wrappers for
  # the same source construct share a type and an exact source span; nothing else in a
  # parsed file does.
  def node_key(node)
    [node.type, node.first_lineno, node.first_column, node.last_lineno, node.last_column]
  end

  def collect_nodes(node, &block)
    found = []
    found << node if block.call(node)
    children_nodes(node).each { |child| found.concat(collect_nodes(child, &block)) }
    found
  end

  def find_node(node, &block)
    collect_nodes(node, &block).first
  end

  # FCALL is `foo(args)` with no receiver; VCALL is bare `foo`; CALL has a receiver.
  def call_method_name(node)
    case node.type
    when :FCALL, :VCALL then node.children[0]
    when :CALL          then node.children[1]
    end
  end

  def receiverless?(node)
    %i[FCALL VCALL].include?(node.type)
  end

  # The argument LIST, which does NOT live at the same index for the three call shapes:
  #
  #   FCALL  [:method, args]              -> children[1]
  #   CALL   [receiver, :method, args]    -> children[2]
  #   VCALL  [:method]                    -> no arguments at all
  #
  # Both of the reader's own bugs so far were this: `check_index_names` read `children[2]`
  # of an FCALL, got `nil`, and every `add_index` in the tree silently passed the length
  # rule. Found by planting a 64-character index name and watching the reader say nothing
  # — which is the failure mode of reading an AST, and the reason the fixtures exist.
  def call_arguments(node)
    case node.type
    when :FCALL then node.children[1]
    when :CALL  then node.children[2]
    end
  end

  def each_call(tree)
    collect_nodes(tree) { |n| %i[FCALL VCALL CALL].include?(n.type) }.each do |node|
      name = call_method_name(node)
      yield node, name if name
    end
  end

  def index_call_on_migration?(node)
    return false unless node.type == :CALL && node.children[1] == :[]

    receiver = node.children[0]
    receiver && receiver.type == :COLON2 && receiver.children[1] == :Migration
  end

  def migration_version_argument(node)
    args = node.children[2]
    return nil unless args && args.type == :LIST

    literal = args.children[0]
    return nil unless literal

    case literal.type
    when :FLOAT, :STR, :LIT, :SYM then literal.children[0].to_s
    end
  end

  # `ActiveRecord::IrreversibleMigration` parses as `COLON2` whose SECOND child is a plain
  # Symbol, not a node — so a search for a `CONST` node by that name finds nothing and the
  # rule passes on the one construct it exists to catch. Measured, by planting
  # `raise ActiveRecord::IrreversibleMigration` and watching the reader stay silent.
  def mentions_irreversible?(node)
    collect_nodes(node) do |n|
      (n.type == :CONST && n.children[0] == :IrreversibleMigration) ||
        (n.type == :COLON2 && n.children[1] == :IrreversibleMigration) ||
        (n.type == :COLON3 && n.children[0] == :IrreversibleMigration)
    end.any?
  end

  def literal_value(node)
    return nil unless node

    case node.type
    when :SYM, :STR, :LIT then node.children[0].to_s
    end
  end

  # Whether a trailing keyword hash carries the key AT ALL, literal value or not. Separate
  # from `hash_argument_value` because "absent" and "present but unreadable" have to lead to
  # different findings: the first is fine for `add_index`, the second is a name nobody
  # measured.
  def hash_argument_present?(args, key)
    hash = args.children.compact.find { |c| c.is_a?(RubyVM::AbstractSyntaxTree::Node) && c.type == :HASH }
    return false unless hash

    list = hash.children[0]
    return false unless list && list.type == :LIST

    list.children.compact.each_slice(2).any? { |k, _| k && literal_value(k) == key.to_s }
  end

  # The `name:` value of a trailing keyword hash, when it is a literal.
  def hash_argument_value(args, key)
    hash = args.children.compact.find { |c| c.is_a?(RubyVM::AbstractSyntaxTree::Node) && c.type == :HASH }
    return nil unless hash

    list = hash.children[0]
    return nil unless list && list.type == :LIST

    pairs = list.children.compact
    pairs.each_slice(2) do |k, v|
      next unless k && v
      return literal_value(v) if literal_value(k) == key.to_s
    end
    nil
  end

  # Rails' own derivation, from `ActiveRecord::ConnectionAdapters::SchemaStatements#index_name`:
  # `"index_#{table_name}_on_#{Array(column_name) * '_and_'}"`. Replicated rather than
  # required, because this reader must run without ActiveRecord loaded.
  def derived_index_name(table, columns_node)
    return nil if table.nil? || columns_node.nil?

    columns =
      case columns_node.type
      when :LIST  then columns_node.children.compact.filter_map { |c| literal_value(c) }
      when :ARRAY then columns_node.children.compact.filter_map { |c| literal_value(c) }
      else Array(literal_value(columns_node))
      end
    return nil if columns.empty?

    "index_#{table}_on_#{columns.join('_and_')}"
  end

  # --- allowlist ------------------------------------------------------------

  # `<basename> <rule-id> # reason`. A line without a reason is refused: an exemption
  # nobody had to justify is how a gate becomes a formality.
  def load_allowlist(path)
    return {} unless File.exist?(path)

    # A plain Hash. `Hash.new { |h, k| h[k] = Set.new }` looks convenient and makes every
    # LOOKUP a write, so a caller that loads the allowlist, scans, and then inspects it sees
    # an entry for every file scanned — which reads as "these are all exempt".
    allow = {}
    File.readlines(path, encoding: 'UTF-8').each_with_index do |line, index|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?('#')

      body, _, reason = line.partition('#')
      file, rule = body.split
      if file.nil? || rule.nil?
        raise ArgumentError, "#{path}:#{index + 1}: expected `<file> <rule-id> # reason`"
      end
      if reason.strip.empty?
        raise ArgumentError, "#{path}:#{index + 1}: exemption for #{file} #{rule} has no reason"
      end
      unless RULES.key?(rule)
        raise ArgumentError, "#{path}:#{index + 1}: unknown rule id #{rule.inspect}; " \
                             "known ids: #{RULES.keys.join(', ')}"
      end

      (allow[file] ||= Set.new) << rule
    end
    allow
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('../..', __dir__)
  dirs = ARGV.empty? ? [File.join(root, 'db', 'migrate')] : ARGV

  # EXIT 2, not 1, and the distinction is the whole three-valued discipline
  # `docs/plan/HANDOVER.md` §1 draws: 0 = clean, 1 = findings, anything else = this reader
  # did not run to completion and therefore knows NOTHING about db/migrate. A malformed
  # allowlist exiting 1 would be reported by the shell wrapper as "there are findings",
  # which is a conclusion nobody computed.
  begin
    allowlist = MigrationReversibility.load_allowlist(
      File.join(root, 'script', 'gates', 'migration_reversibility.allowlist')
    )
  rescue ArgumentError => e
    warn "ERROR: the allowlist could not be read, so nothing was checked: #{e.message}"
    exit 2
  end

  findings = MigrationReversibility.scan(dirs, allowlist: allowlist)
  findings.each { |f| puts f.to_s }
  exit(findings.empty? ? 0 : 1)
end
