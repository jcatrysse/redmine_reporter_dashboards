# frozen_string_literal: true

# T-40 — the parity gate that keeps the permission model honest.
#
# --- WHAT THIS FILE IS FOR ---
#
# The permission model is the answer to the curator's 2026-08-06 decision: *"the plugin
# must provide permissions in the normal Redmine way, so roles can be given exactly what
# they may and may not do"*, replacing the rejected `template_authoring` setting. A model
# written only in `technical-spec.md` is a comment, and CLAUDE.md §Phase 2 names
# "specified as mechanical, implemented as a comment" as a review failure. So the model is
# data (`lib/redmine_reporter_dashboards/permissions.rb`) and this file is the mechanism.
#
# The assertion that matters most is the LAST one: every public action of every controller
# in the plugin is either mapped by a declared permission or listed in
# `NON_PERMISSION_GUARDS` with the guard it really uses. It guards nothing new today — the
# three live permissions already cover the two dashboard controllers — and that is the
# point: T-23, T-25, T-28 and T-32 each add a controller, and none of them can add an
# unguarded action without this file going red.
#
# --- WHY IT PARSES INSTEAD OF GREPPING ---
#
# "Which methods of this controller are public actions" is not a question a regexp can
# answer: it has to know where `private` is, that `def self.x` is not an action, and that
# `def` inside a `private def` form is already private. This project has been bitten twice
# by scanners that could not tell one construct from another (§Findings E-14, and the ES5
# "shorthand method" regexp deleted from `spec/charts/mermaid_boot_spec.rb`), and the
# lesson both times was the same: ask a real parser. `RubyVM::AbstractSyntaxTree` is Ruby's
# own, needs no gem, and is available on every Ruby in the CI matrix (3.2 → 3.4).
#
# The risk in reading an AST is the opposite of a regexp's: a node type renamed by a newer
# Ruby makes the extraction return NOTHING, and every assertion built on it goes green for
# the wrong reason. `describe 'the AST reader itself'` exists to make that impossible — it
# asserts concrete, known values from a real controller, so an extraction that stopped
# working FAILS instead of passing vacuously.
#
# No Redmine, no Rails, no database: `permissions.rb` is plain data and the controllers are
# read as text, so this runs in the DB-less suite.

require 'fileutils'
require 'tmpdir'
require 'yaml'

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/permissions'

module RedmineReporterDashboards
  # The plugin root, from `spec/permissions/`.
  PERMISSION_SPEC_ROOT = File.expand_path('../..', __dir__)

  # The nine locales of CLAUDE.md §10, named rather than globbed: a locale file that
  # disappeared should fail here too, not quietly shrink the parity check to eight.
  PERMISSION_SPEC_LOCALES = %w[de en es hu it pl pt-BR ru zh].freeze

  # A controller read as source. Everything it answers comes from Ruby's own parser.
  class ControllerSource
    VISIBILITY_MARKERS = %i[public private protected].freeze

    attr_reader :name

    # `root` is a seam for the fixtures under `spec/permissions/fixtures/controllers/`.
    # They are read as TEXT and never loaded, and they carry the constructs `app/controllers/`
    # happens not to contain — which is the only way the reader's answers about those
    # constructs are behaviour rather than reading.
    def initialize(name, root: self.class.controllers_root)
      @name = name.to_s
      @root = root
    end

    def self.controllers_root
      File.join(PERMISSION_SPEC_ROOT, 'app', 'controllers')
    end

    def self.fixtures_root
      File.join(__dir__, 'fixtures', 'controllers')
    end

    def self.fixture(name)
      new(name, root: fixtures_root)
    end

    # RECURSIVE, and the review of T-40 is why: a non-recursive glob missed
    # `app/controllers/reporter_dashboards/templates_controller.rb` entirely, so two
    # completely unguarded actions in a namespaced controller passed the coverage gate —
    # while `#exist?` resolved the same namespaced key happily, meaning such a controller
    # could be permission-MAPPED and invisible to the coverage check at the same time. T-23
    # onward are exactly the tasks that add controllers, and a namespace is the obvious
    # shape for them.
    def self.all
      Dir[File.join(controllers_root, '**', '*_controller.rb')]
        .sort
        .map { |path| new(path.sub("#{controllers_root}/", '').sub(/_controller\.rb\z/, '')) }
    end

    def path
      File.join(@root, "#{@name}_controller.rb")
    end

    def exist?
      File.file?(path)
    end

    # Public instance methods that become actions.
    #
    # `private def foo` needs no special case and gets none: the statement in the class
    # body is the `private` CALL, and the `def` is its argument, so `foo` is never reached
    # by the top-level loop. A bare `private` / `protected` / `public` flips the mode for
    # what follows, which is how the four controllers here are written.
    #
    # **A `def` nested inside anything is counted as PUBLIC, not skipped.** The review of
    # T-40 found the first version walked only direct statements of the class body, so
    #
    #   if Rails::VERSION::MAJOR >= 6
    #     def legacy_export ... end
    #   end
    #
    # was an unguarded, routable action the coverage gate could not see — and a version
    # conditional is a construct a plugin spanning three Rails majors is *likely* to write.
    # Nesting is therefore searched, and a nested `def` is assumed public because there is no
    # reliable way to know its visibility: over-reporting an action costs one
    # NON_PERMISSION_GUARDS entry, under-reporting one costs an unguarded endpoint.
    def public_actions
      visibility = :public
      actions = []

      class_body_statements.each do |node|
        case node.type
        when :VCALL
          marker = node.children[0]
          visibility = marker if VISIBILITY_MARKERS.include?(marker)
        when :DEFN
          actions << node.children[0] if visibility == :public
        when :FCALL
          # `private def foo` / `protected def foo`: the DEFN is this call's argument, and
          # descending into it would report a private helper as an action — which is what the
          # nesting search would otherwise do, undoing the case the comment above documents.
          next if %i[private protected].include?(node.children[0])

          actions.concat(nested_definitions(node)) if visibility == :public
        else
          actions.concat(nested_definitions(node)) if visibility == :public
        end
      end

      actions
    end

    # `define_method` in a controller body. Not resolved — REPORTED, so the coverage
    # assertion can refuse it: the name may be computed, so no parser can promise to know
    # what action it creates, and silently ignoring it is what let it become an unguarded
    # endpoint in the reviewer's reproduction.
    def define_method_calls
      class_body_statements.count do |node|
        call = unwrap_block(node)
        call && call.type == :FCALL && call.children[0] == :define_method
      end
    end

    # The symbols passed to `before_action` in the class body — the guards, in the order
    # they run. Only top-level arguments are read, so the `:current_user_admin?` inside
    # `unless:` is correctly NOT counted as a guard.
    def before_action_symbols
      filter_calls(:before_action).flat_map { |call| call[:symbols] }
    end

    # Which actions a `before_action :guard` actually covers, honouring `only:` and
    # `except:`. `nil` means "every action".
    #
    # The first version of this file asked only *"does this controller mention `authorize`
    # anywhere"*, which the review broke with two lines — `before_action :authorize, only:
    # [:create]` plus `skip_before_action :authorize, only: [:order]` left three of four
    # mapped actions unauthorized and the suite green.
    def actions_guarded_by(guard)
      calls = filter_calls(:before_action).select { |call| call[:symbols].include?(guard) }

      # ABSENT is not UNSCOPED, and conflating the two put the review's finding straight back:
      # with `nil` meaning "every action", a controller that had **deleted** its
      # `before_action :authorize` answered "everything is covered" and the per-action
      # assertion skipped it. `[]` for a guard that never runs; `nil` only for one that runs
      # unscoped.
      return [] if calls.empty?

      covered = calls.reduce(nil) { |acc, call| merge_coverage(acc, call) }

      filter_calls(:skip_before_action).each do |call|
        next unless call[:symbols].include?(guard)

        covered = subtract_coverage(covered, call)
      end

      covered
    end

    private

    # A `before_action` / `skip_before_action` call, reduced to what matters: which guards it
    # names, and the `only:`/`except:` lists that scope it.
    def filter_calls(method_name)
      class_body_statements.filter_map do |node|
        call = unwrap_block(node)
        next unless call && call.type == :FCALL && call.children[0] == method_name

        args = arguments(call)
        { symbols: args.filter_map { |a| symbol_literal(a) },
          only: symbol_list_option(args, :only),
          except: symbol_list_option(args, :except) }
      end
    end

    # `covered` is nil for "all actions" and an Array otherwise. nil is NOT the empty set
    # here, which is the distinction the first version of these two methods got wrong: it
    # started from `public_actions` whenever `covered` was nil, so `only: [:create]` widened
    # to everything instead of narrowing to one action.
    def merge_coverage(covered, call)
      added = coverage_of(call)

      return nil if added.nil? # an unscoped guard covers every action

      (covered || []) | added
    end

    def subtract_coverage(covered, call)
      removed = coverage_of(call)
      base = covered || public_actions

      removed.nil? ? [] : base - removed
    end

    # Which actions one filter call applies to: nil for all of them, otherwise the list.
    def coverage_of(call)
      return call[:only] if call[:only]
      return public_actions - call[:except] if call[:except]

      nil
    end

    def symbol_list_option(args, key)
      hash = args.find { |a| a.is_a?(RubyVM::AbstractSyntaxTree::Node) && a.type == :HASH }
      return nil unless hash

      pairs = hash.children[0]
      return nil unless pairs

      children = pairs.children.compact
      children.each_slice(2) do |name, value|
        next unless symbol_literal(name) == key

        return symbol_values(value)
      end

      nil
    end

    def symbol_values(node)
      return [] unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      single = symbol_literal(node)
      return [single] if single

      node.type == :LIST || node.type == :ARRAY ? node.children.filter_map { |c| symbol_literal(c) } : []
    end

    def nested_definitions(node)
      return [] unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
      # A singleton class body (`class << self`) and a `def self.x` define class methods,
      # never actions, so neither is descended into.
      return [] if %i[SCLASS DEFS].include?(node.type)

      found = node.type == :DEFN ? [node.children[0]] : []
      node.children.each { |child| found.concat(nested_definitions(child)) }
      found
    end

    def source
      File.read(path, encoding: 'UTF-8')
    end

    def class_body_statements
      tree = RubyVM::AbstractSyntaxTree.parse(source)
      klass = first_node(tree) { |node| node.type == :CLASS }
      raise "no class definition found in #{path}" unless klass

      # CLASS => [cpath, superclass, SCOPE]; SCOPE => [locals, args, body].
      statements(klass.children[2].children[2])
    end

    def statements(node)
      return [] if node.nil?

      node.type == :BLOCK ? node.children.compact : [node]
    end

    def arguments(call_node)
      list = call_node.children[1]
      list.nil? ? [] : list.children.compact
    end

    # A call with a block is an `ITER` wrapping the call, so `define_method(:x) { }` and
    # `before_action { }` are not `FCALL` statements. Missing that made `define_method_calls`
    # answer zero for a controller that had one — a false "nothing to refuse".
    def unwrap_block(node)
      return nil unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
      return node unless node.type == :ITER

      inner = node.children[0]
      inner.is_a?(RubyVM::AbstractSyntaxTree::Node) ? inner : nil
    end

    # A symbol literal, without hardcoding the node type: Ruby 3.4 split `NODE_LIT` into
    # `NODE_SYM` and friends, so both names are accepted — and the type is still checked,
    # because a `VCALL` node also carries a single Symbol child and a bare method call is
    # not a symbol argument.
    def symbol_literal(node)
      return nil unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
      return nil unless %i[LIT SYM].include?(node.type)

      value = node.children[0]
      value.is_a?(Symbol) ? value : nil
    end

    def first_node(node, &block)
      return nil unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
      return node if block.call(node)

      node.children.each do |child|
        found = first_node(child, &block)
        return found if found
      end

      nil
    end
  end

  RSpec.describe Permissions do
    def locale_data(locale)
      path = File.join(PERMISSION_SPEC_ROOT, 'config', 'locales', "#{locale}.yml")
      YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: true).values.first
    end

    # "controller#action" for everything a REGISTERED permission maps.
    def mapped_endpoints
      described_class::REGISTERED.flat_map do |entry|
        entry.actions.flat_map do |controller, actions|
          Array(actions).map { |action| "#{controller}##{action}" }
        end
      end
    end

    def all_endpoints
      ControllerSource.all.flat_map do |controller|
        controller.public_actions.map { |action| "#{controller.name}##{action}" }
      end
    end

    def routes_source
      File.read(File.join(PERMISSION_SPEC_ROOT, 'config', 'routes.rb'), encoding: 'UTF-8')
    end

    # "controller#action" for every route the plugin declares. `config/routes.rb` is a plain
    # list of `to: 'controller#action'` strings, and the example below FAILS if a line ever
    # takes another form, so this reader cannot silently miss a route.
    def routed_endpoints
      routes_source.scan(/\bto:\s*'([a-z0-9_\/]+#\w+)'/).flatten.uniq
    end

    # ------------------------------------------------------------------
    # The meta-test. Without it, an AST reader broken by a newer Ruby would return empty
    # collections and every assertion below would pass while checking nothing.
    describe 'the AST reader itself' do
      let(:tabs) { ControllerSource.new(:reporter_project_tabs) }

      it 'finds exactly the public actions of a controller, and none of its helpers' do
        expect(tabs.public_actions).to eq(%i[create update destroy order])
      end

      it 'does not mistake a private helper for an action' do
        # `find_tab`, `require_manage_tabs` and `tab_params` all live after `private`.
        expect(tabs.public_actions).not_to include(:find_tab, :require_manage_tabs,
                                                  :tab_params)
      end

      it 'reads the before_action guards in order' do
        expect(tabs.before_action_symbols)
          .to eq(%i[find_project_by_project_id require_dashboard_module authorize
                    require_manage_tabs find_tab])
      end

      it 'does not count a symbol passed to `unless:` as a guard' do
        pages = ControllerSource.new(:reporter_project_pages)

        expect(pages.before_action_symbols).to include(:authorize)
        expect(pages.before_action_symbols).not_to include(:current_user_admin?)
      end

      it 'sees every controller in the plugin' do
        expect(ControllerSource.all.map(&:name))
          .to eq(%w[reporter_dashboards/templates reporter_preflight
                    reporter_project_pages reporter_project_tabs sql_stats])
      end

      # T-23's controller is the first one in a subdirectory, which is the case the
      # recursive glob was written for before there was anything to find. This pins the
      # answer so a reader that stopped descending would fail loudly instead of reporting
      # four controllers and full coverage.
      it 'reads the namespaced controller T-23 added, with its exact action set' do
        templates = ControllerSource.new('reporter_dashboards/templates')

        expect(templates.exist?).to be(true)
        expect(templates.public_actions.sort)
          .to eq(%i[create destroy document edit export import index new preview show
                    update])
      end

      it 'sees a controller in a SUBDIRECTORY, under its namespaced name' do
        # The non-recursive glob this replaced missed a namespaced controller entirely, so
        # two unguarded actions in one passed the coverage gate. T-23 onward are the tasks
        # that add controllers, and a namespace is the obvious shape for them.
        Dir.mktmpdir('rrd-controllers') do |dir|
          FileUtils.mkdir_p(File.join(dir, 'reporter_dashboards'))
          File.write(File.join(dir, 'reporter_dashboards', 'templates_controller.rb'),
                     "class TemplatesController < ApplicationController\n" \
                     "  def index; end\n" \
                     "end\n")
          File.write(File.join(dir, 'plain_controller.rb'),
                     "class PlainController < ApplicationController\n  def show; end\nend\n")

          found = Dir[File.join(dir, '**', '*_controller.rb')]
                  .sort
                  .map { |path| path.sub("#{dir}/", '').sub(/_controller\.rb\z/, '') }

          expect(found).to eq(%w[plain reporter_dashboards/templates])
          expect(ControllerSource.new('reporter_dashboards/templates', root: dir)
                                 .public_actions).to eq([:index])
        end
      end

      # --- the constructs app/controllers/ does not contain -----------------------------
      #
      # Read from fixtures for exactly one reason: an assertion made only against the four
      # real controllers proves the reader handles the four real controllers. The review of
      # T-40 broke the first version with constructs none of them uses.
      describe 'the awkward definitions' do
        let(:awkward) { ControllerSource.fixture(:awkward_definitions) }

        it 'counts a `def` nested inside a conditional as an action' do
          # An unguarded, routable action the first version of this reader could not see.
          expect(awkward.public_actions).to include(:conditionally_defined)
        end

        it 'counts an action defined after `protected` and then `public`' do
          expect(awkward.public_actions).to include(:public_after_protected)
        end

        it 'never counts a class method, however it is written' do
          expect(awkward.public_actions).not_to include(:class_level_helper, :also_class_level)
        end

        it 'never counts an inline `private def` or a helper after a bare `private`' do
          expect(awkward.public_actions).not_to include(:inline_private_helper,
                                                       :protected_helper,
                                                       :tail_private_helper)
        end

        it 'reports a `define_method` rather than resolving or ignoring it' do
          # The name can be computed, so no parser can promise to know the action it makes.
          # Reporting it is what lets the coverage assertion refuse it.
          expect(awkward.define_method_calls).to eq(1)
        end

        it 'answers the exact action set, so nothing above passes by accident' do
          # `defined_by_method` is deliberately NOT here: `define_method` creates no `def`,
          # its name can be computed, and the reader refuses the construct rather than
          # pretending to resolve it — see `#define_method_calls` and the coverage example
          # that fails on a non-zero count.
          expect(awkward.public_actions.sort)
            .to eq(%i[conditionally_defined plain_action public_after_protected])
        end
      end

      describe 'the scoped and skipped guards' do
        let(:partial) { ControllerSource.fixture(:partially_guarded) }

        it 'honours `only:` — a guard covers the listed actions and no others' do
          expect(partial.actions_guarded_by(:authorize)).to eq([:create])
        end

        it 'honours `skip_before_action`, which the first version never read at all' do
          # :order is in `only:` of the skip, so it is NOT covered even though `authorize`
          # appears in the file — the exact two lines the review used to defeat this gate.
          expect(partial.actions_guarded_by(:authorize)).not_to include(:order)
        end

        it 'treats an unscoped guard as covering everything' do
          expect(partial.actions_guarded_by(:find_project_by_project_id)).to be_nil
        end

        it 'honours `except:`' do
          awkward = ControllerSource.fixture(:awkward_definitions)

          expect(awkward.actions_guarded_by(:everything_but))
            .to eq(awkward.public_actions - [:plain_action])
        end

        it 'honours `only:` with a %i[] list' do
          awkward = ControllerSource.fixture(:awkward_definitions)

          expect(awkward.actions_guarded_by(:only_for_two).sort)
            .to eq(%i[defined_by_method plain_action])
        end

        it 'answers nil for the real controllers, whose authorize is unscoped' do
          expect(ControllerSource.new(:reporter_project_tabs).actions_guarded_by(:authorize))
            .to be_nil
        end

        it 'answers EMPTY, not nil, for a guard the controller never runs' do
          # The distinction that matters most in this file. nil means "runs for every action";
          # a guard that is absent covers nothing, and reading absence as nil is how deleting
          # `before_action :authorize` outright would have slipped past the per-action check.
          expect(ControllerSource.new(:reporter_project_tabs)
                                 .actions_guarded_by(:never_declared)).to eq([])
          expect(partial.actions_guarded_by(:not_here_either)).to eq([])
        end
      end
    end

    # ------------------------------------------------------------------
    describe 'the shape of the map' do
      it 'has no duplicate permission name, registered or planned' do
        names = described_class::ALL.map(&:name)

        expect(names).to eq(names.uniq)
      end

      it 'uses names Redmine accepts as permission names' do
        described_class::ALL.each do |entry|
          expect(entry.name.to_s).to match(/\A[a-z][a-z0-9_]*\z/),
                                     "#{entry.name.inspect} is not a plain lowercase " \
                                     'permission name'
        end
      end

      it 'namespaces every name it adds, because a collision is a real authorization bug' do
        # technical-spec.md §7 makes simultaneous installation with redmine_reporter a
        # design goal, and AccessControl has no uniqueness check. The three pre-existing
        # names carry `reporter_`; everything T-40 adds carries the full plugin noun.
        described_class::PLANNED.each do |entry|
          expect(entry.name.to_s).to include('reporter_dashboards'),
                                     "#{entry.name} could collide with another plugin"
        end

        described_class::REGISTERED.each do |entry|
          expect(entry.name.to_s).to include('reporter')
        end
      end

      it 'declares a group the documentation knows how to order' do
        described_class::ALL.each do |entry|
          expect(described_class::GROUPS).to include(entry.group)
        end
      end

      it 'says what each permission covers, in one line an administrator could read' do
        described_class::ALL.each do |entry|
          expect(entry.covers.to_s.strip).not_to be_empty, "#{entry.name} has no `covers`"
        end
      end

      it 'uses only the two `require:` values Redmine has' do
        described_class::ALL.each do |entry|
          expect([nil, :loggedin, :member]).to include(entry.requires),
                                               "#{entry.name} has requires: " \
                                               "#{entry.requires.inspect}"
        end
      end
    end

    # ------------------------------------------------------------------
    # INV-9, mechanically. This is what replaces the `template_authoring` setting: not a
    # default, but a rule Redmine's own machinery enforces once the data says `:member`.
    describe 'authoring is a code-execution privilege' do
      let(:authoring) { described_class::ALL.select(&:authoring) }

      it 'has authoring permissions to talk about' do
        expect(authoring).not_to be_empty
      end

      it 'never offers one to the Anonymous or Non-member role' do
        # `require: :member` is how Redmine refuses to LIST a permission for those two
        # built-in roles: `Role#setable_permissions` subtracts `members_only_permissions`
        # for Non-member and `loggedin_only_permissions` — a superset — for Anonymous. A
        # label saying "executes server-side code" is a warning; this is the control.
        authoring.each do |entry|
          expect(entry.registration_options[:require]).to eq(:member),
                                                         "#{entry.name} is a code-execution " \
                                                         'privilege and must register with ' \
                                                         'require: :member'
        end
      end

      it 'derives that from `authoring`, rather than trusting it to be typed' do
        # The load-bearing half: no authoring entry WRITES `requires`, so the value comes
        # from the derivation and this example fails if the derivation is removed. Until the
        # review of T-40, the field was hand-typed on every entry and the example above
        # merely asserted that two hand-written fields agreed — which cannot catch both being
        # wrong together, and which three documents were already describing as "derived".
        authoring.each do |entry|
          expect(entry[:requires]).to be_nil,
                                      "#{entry.name} writes requires: " \
                                      "#{entry[:requires].inspect} — leave it unset and let " \
                                      'authoring: true derive it'
          expect(entry.requires).to eq(:member)
        end
      end

      it 'derives `:member` for an authoring entry that says nothing about `require:`' do
        entry = described_class::Entry.new(name: :probe, project_module: :m, actions: nil,
                                          read: false, group: :reports_author,
                                          authoring: true, covers: 'probe')

        expect(entry.requires).to eq(:member)
        expect(entry.registration_options).to eq(require: :member)
      end

      it 'leaves a non-authoring entry`s own `require:` alone' do
        expect(described_class.find(:mail_reporter_dashboards_reports).requires)
          .to eq(:loggedin)
      end

      it 'never marks one `read: true`, which would permit it in a closed project' do
        authoring.each do |entry|
          expect(entry.read).to be(false), "#{entry.name} must not be read: true"
        end
      end

      it 'keeps every authoring permission in the reports module' do
        authoring.each do |entry|
          expect(entry.project_module).to eq(described_class::REPORTS_MODULE)
        end
      end

      it 'is granted by nothing in THIS PLUGIN — which is all this can honestly assert' do
        # NAMED CAREFULLY, because its predecessor was called "grants none of them by
        # default — which is `:admins_only` by construction" and could not test that. The
        # review of T-40 refuted the claim outright: Redmine's own default-data loader runs
        # `manager.permissions = manager.setable_permissions.collect(&:name)`
        # (`lib/redmine/default_data/loader.rb:51`, identical on 5.1 → 7.0), and
        # `setable_permissions` subtracts only `public_permissions` for a givable role. So a
        # fresh install that loads the default configuration WITH this plugin present grants
        # the Manager role every setable permission of ours, `require: :member` included.
        #
        # A grep of this repository can never see that — the grant is in core. What it can
        # see, and what this example is now honestly named for, is that the plugin itself
        # never grants anything. `init.rb` is listed EXPLICITLY: it is a file, so
        # `{app,lib,db,init.rb}/**/*.rb` expanded to `init.rb/**/*.rb` and matched nothing,
        # which left the one file where a plugin would actually do this unchecked.
        candidates = Dir[File.join(PERMISSION_SPEC_ROOT, '{app,lib,db}', '**', '*.rb')] +
                     [File.join(PERMISSION_SPEC_ROOT, 'init.rb')]

        offenders = candidates.select { |path| File.file?(path) }.select do |path|
          File.read(path, encoding: 'UTF-8')
              .match?(/add_permission|roles_permissions|permissions\s*<</)
        end

        expect(offenders).to be_empty,
                             "these files could grant a permission to a role: #{offenders}"
      end

      it 'checks init.rb, which the glob it replaced silently skipped' do
        # The bug was invisible because a glob that matches nothing looks exactly like a glob
        # that matches nothing offending. Pinned so it cannot come back.
        expect(Dir[File.join(PERMISSION_SPEC_ROOT, '{app,lib,db,init.rb}', '**', '*.rb')])
          .not_to include(File.join(PERMISSION_SPEC_ROOT, 'init.rb'))
        expect(File.file?(File.join(PERMISSION_SPEC_ROOT, 'init.rb'))).to be(true)
      end
    end

    # ------------------------------------------------------------------
    describe 'read: true' do
      # Redmine's `read: true` means "still permitted in a CLOSED project"
      # (`Project#allows_to?` → `AccessControl.read_action?`). Only consuming permissions
      # carry it.
      #
      # DECISION RECORDED, not hidden (§4.1): `view_reporter_dashboards_reports` is
      # `read: true`, and opening a report runs a template and may start a PDF engine — more
      # expensive than any `read: true` in Redmine core, all of which are cheap reads. Kept
      # deliberately: reading last quarter's report out of a project the organisation has
      # since frozen is the main thing a closed project's reports are FOR, and the cost is
      # bounded by T-17's execution policy and FR-32's caps rather than by this flag. The
      # authoring permissions are asserted NOT to be `read: true` above, which is where the
      # closed-project line actually matters.
      it 'is set only on consuming permissions' do
        offenders = described_class::ALL.select(&:read)
                                       .reject { |e| %i[dashboards reports_consume].include?(e.group) }
                                       .map(&:name)

        expect(offenders).to be_empty,
                             "read: true on a non-consuming permission: #{offenders}"
      end

      it 'is set on the ones that read, so a closed project is not read-blind' do
        expect(described_class::ALL.select(&:read).map(&:name))
          .to eq(%i[view_reporter_project_page view_reporter_dashboards_reports
                    view_reporter_dashboards_schedules])
      end
    end

    # ------------------------------------------------------------------
    describe 'the registered permissions' do
      it 'maps only controllers that exist' do
        described_class::REGISTERED.each do |entry|
          entry.actions.each_key do |controller|
            expect(ControllerSource.new(controller).exist?).to be(true),
                                                               "#{entry.name} maps " \
                                                               "#{controller}, which has " \
                                                               'no controller file'
          end
        end
      end

      it 'maps only actions that exist and are public' do
        described_class::REGISTERED.each do |entry|
          entry.actions.each do |controller, actions|
            available = ControllerSource.new(controller).public_actions

            Array(actions).each do |action|
              expect(available).to include(action),
                                   "#{entry.name} maps #{controller}##{action}, which is " \
                                   "not a public action (public: #{available.inspect})"
            end
          end
        end
      end

      it 'has `authorize` covering every mapped action, not merely mentioned somewhere' do
        # The permission map is inert without `authorize`, and this is the assertion that
        # catches "declared the permission, never checked it" — which reads as a working
        # permission right up to the moment somebody tries the wrong role.
        #
        # PER ACTION, because per controller was not enough: the review of T-40 added
        # `only: [:create]` plus `skip_before_action :authorize, only: [:order]` and left
        # three of the four mapped actions unauthorized with the suite still green. The plan
        # already promises this shape for T-23 ("a permission test per entry point rather
        # than per controller"), so the gate must not be weaker than the promise.
        described_class::REGISTERED.each do |entry|
          entry.actions.each do |controller, actions|
            covered = ControllerSource.new(controller).actions_guarded_by(:authorize)
            next if covered.nil? # unscoped: every action

            Array(actions).each do |action|
              expect(covered).to include(action),
                                 "#{controller}##{action} is mapped by #{entry.name} but " \
                                 'authorize does not run for it (only:/except:/' \
                                 'skip_before_action)'
            end
          end
        end
      end

      it 'is labelled in all nine locales' do
        described_class::REGISTERED.each do |entry|
          PERMISSION_SPEC_LOCALES.each do |locale|
            label = locale_data(locale)["permission_#{entry.name}"]

            expect(label.to_s.strip).not_to be_empty,
                                            "#{locale}.yml has no permission_" \
                                            "#{entry.name} — an absent key falls back to " \
                                            'English silently (CLAUDE.md §10)'
          end
        end
      end

      it 'has its project MODULE labelled in all nine locales too' do
        # The module is what the fieldset legend on the roles screen shows, through
        # `l_or_humanize(mod, prefix: 'project_module_')` — in `roles/_form` and again in
        # `projects/settings/_modules`. Nothing asserted this until the review of T-40, which
        # meant the new reports module could be promoted with nine missing legends and the
        # nine-label assertion above would still pass: it only covers permission keys.
        described_class::REGISTERED.map(&:project_module).uniq.each do |project_module|
          PERMISSION_SPEC_LOCALES.each do |locale|
            label = locale_data(locale)["project_module_#{project_module}"]

            expect(label.to_s.strip).not_to be_empty,
                                            "#{locale}.yml has no project_module_" \
                                            "#{project_module}"
          end
        end
      end
    end

    # ------------------------------------------------------------------
    # Docs/code parity, in the style of `drop_reference_parity`. §4.1's table is the contract
    # T-23/T-25/T-28/T-32 implement, and a table that has drifted from the data is worse than
    # no table: the next session reads the prose, not the Struct.
    describe 'technical-spec.md §4.1' do
      let(:table) do
        spec = File.read(File.join(PERMISSION_SPEC_ROOT, 'docs', 'plan',
                                   'technical-spec.md'), encoding: 'UTF-8')
        section = spec[/^#### The set[^\n]*\n(.*?)^#### /m, 1]
        raise 'the §4.1 permission table is gone' if section.nil?

        section
      end

      it 'lists exactly the permissions in the map, in the same order' do
        listed = table.scan(/^\| \*{0,2}`([a-z_]+)`\*{0,2} \|/).flatten.map(&:to_sym)

        expect(listed).to eq(described_class::ALL.map(&:name))
      end

      it 'names the task each unregistered permission is waiting for' do
        rows = table.lines.grep(/^\| \*{0,2}`[a-z_]+`/)

        described_class::PLANNED.each do |entry|
          row = rows.find { |line| line.include?("`#{entry.name}`") }

          expect(row).to include("| #{entry.lands_in} |"),
                         "§4.1's row for #{entry.name} does not say #{entry.lands_in}"
        end
      end

      it 'marks the live ones live' do
        rows = table.lines.grep(/^\| \*{0,2}`[a-z_]+`/)

        described_class::REGISTERED.each do |entry|
          row = rows.find { |line| line.include?("`#{entry.name}`") }

          expect(row).to include('**live**')
        end
      end
    end

    # ------------------------------------------------------------------
    # The refactor check. `init.rb` used to carry three literal `permission` calls; T-40
    # turned them into a loop over this data. Those three calls are reproduced here as the
    # expectation, so "the loop registers exactly what the literals did" is an assertion
    # rather than a claim in a commit message.
    describe '.registrations_by_module' do
      # THE DASHBOARDS HALF IS STILL THE THREE LITERALS, VERBATIM. T-40 turned three
      # `permission` calls into a loop and this is what proved the loop changed nothing;
      # T-23 adds a second module and must not disturb the first, so the first block below
      # is unchanged from T-40's expectation and the second is the new registration.
      it 'reproduces the three registrations init.rb used to make literally, and adds ' \
         "T-23's five" do
        expect(described_class.registrations_by_module).to eq(
          reporter_project_dashboards: [
            [:view_reporter_project_page,
             { reporter_project_pages: [:show, :report_pdf] },
             { read: true }],
            [:manage_reporter_project_page,
             { reporter_project_pages: [:update_page, :add_block, :remove_block,
                                       :move_block] },
             {}],
            [:manage_reporter_project_tabs,
             { reporter_project_tabs: [:create, :update, :destroy, :order] },
             {}]
          ],
          reporter_dashboards_reports: [
            [:view_reporter_dashboards_reports,
             { :'reporter_dashboards/templates' => [:index, :show, :document] },
             { read: true }],
            [:add_reporter_dashboards_templates,
             { :'reporter_dashboards/templates' => [:new, :create, :preview, :import] },
             { require: :member }],
            [:edit_own_reporter_dashboards_templates,
             { :'reporter_dashboards/templates' => [:edit, :update, :destroy, :preview,
                                                    :export] },
             { require: :member }],
            [:edit_reporter_dashboards_templates,
             { :'reporter_dashboards/templates' => [:edit, :update, :destroy, :preview,
                                                    :export, :import] },
             { require: :member }],
            [:manage_public_reporter_dashboards_templates,
             { :'reporter_dashboards/templates' => [:new, :create, :edit, :update] },
             { require: :member }]
          ]
        )
      end

      # T-23. The action key has to carry the namespace, because Redmine compares
      # `"#{controller}/#{action}"` against `params[:controller]` and for a controller in
      # a subdirectory that is `reporter_dashboards/templates`. A key of `:templates`
      # would produce a permission that guards nothing and looks perfectly correct on the
      # roles screen — the exact failure this whole file exists to make impossible.
      it 'names a namespaced controller with its full path, not its basename' do
        keys = described_class::REGISTERED.flat_map { |entry| entry.actions.keys }.uniq

        expect(keys).to include(:'reporter_dashboards/templates')
        expect(keys).not_to include(:templates)
      end

      it 'registers nothing that is only planned' do
        registered = described_class.registrations_by_module.values.flatten(1).map(&:first)

        expect(registered & described_class.planned_names).to be_empty
      end

      it 'omits an option rather than passing a false or nil one' do
        # Not a correctness requirement — `Permission#initialize` reads `options[:read] ||
        # false` and `options[:require]`, so `read: false` / `require: nil` would behave
        # identically on 5.1 → 7.0. It omits them because the three calls this replaced
        # omitted them, and "identical" is a stronger thing to assert than "equivalent".
        expect(described_class.find(:manage_reporter_project_tabs).registration_options)
          .to eq({})
      end

      it 'gives each project module a single contiguous run of REGISTERED' do
        # `group_by` would silently coalesce an interleaved [D, R, D] array into two blocks
        # and move the third entry relative to REGISTERED — and within a module the roles
        # screen renders in declaration order, so that reorder would be visible to an
        # administrator and invisible here.
        modules = described_class::REGISTERED.map(&:project_module)

        expect(modules.chunk_while { |a, b| a == b }.map(&:first).uniq.size)
          .to eq(modules.uniq.size)
      end

      it 'passes `require:` through for the entries that will need it' do
        # No REGISTERED entry does today — see permissions.rb on why the two `manage_`
        # dashboard permissions deliberately keep no `require: :member`. The first one that
        # needs it is an authoring permission, so the mapping is asserted from a PLANNED
        # entry rather than from a hand-built stand-in.
        expect(described_class.find(:add_reporter_dashboards_templates)
                              .registration_options).to eq(require: :member)
      end
    end

    # ------------------------------------------------------------------
    describe 'the planned permissions' do
      it 'names the task that will register each one' do
        plan = File.read(File.join(PERMISSION_SPEC_ROOT, 'docs', 'plan',
                                   'implementation-plan.md'), encoding: 'UTF-8')

        described_class::PLANNED.each do |entry|
          expect(entry.lands_in).to match(/\AT-\d\d\z/), "#{entry.name} has no task id"
          expect(plan).to include("**#{entry.lands_in} "),
                          "#{entry.lands_in} (for #{entry.name}) is not a task in the plan"
        end
      end

      it 'maps no action, because the controllers it guards do not exist yet' do
        # Inventing controller and action names for code nobody has written would make a
        # public contract out of a guess. The promoting task owns those names.
        described_class::PLANNED.each do |entry|
          expect(entry.actions).to be_nil, "#{entry.name} maps actions but is not registered"
        end
      end

      it 'carries no locale label yet, so the roles screen cannot advertise it' do
        # A label for a permission nobody can hold is a claim the plugin does not honour;
        # and requiring all nine at promotion time is what keeps CLAUDE.md §10 from being
        # satisfied one locale at a time.
        described_class::PLANNED.each do |entry|
          PERMISSION_SPEC_LOCALES.each do |locale|
            expect(locale_data(locale)).not_to have_key("permission_#{entry.name}"),
                                               "#{locale}.yml labels #{entry.name}, which " \
                                               'is not registered'
          end
        end
      end

      it 'is not registered' do
        expect(described_class.registered_names & described_class.planned_names).to be_empty
      end
    end

    # ------------------------------------------------------------------
    # The gate that bites in T-23. Today it is satisfied; the value is entirely in what it
    # refuses tomorrow.
    describe 'every action is accounted for' do
      it 'leaves no public controller action unguarded' do
        accounted = mapped_endpoints + described_class::NON_PERMISSION_GUARDS.keys

        expect(all_endpoints - accounted).to be_empty,
                                            'these actions are guarded by no plugin ' \
                                            'permission and are not listed in ' \
                                            'NON_PERMISSION_GUARDS'
      end

      it 'never accounts for one action twice' do
        overlap = mapped_endpoints & described_class::NON_PERMISSION_GUARDS.keys

        expect(overlap).to be_empty,
                           "#{overlap} is both permission-mapped and listed as guarded " \
                           'without a permission'
      end

      it 'has no stale entry in NON_PERMISSION_GUARDS' do
        expect(described_class::NON_PERMISSION_GUARDS.keys - all_endpoints).to be_empty
      end

      it 'checks the guard each allowlist entry claims, against the controller' do
        # An allowlist nobody verifies is how an unguarded action gets written down as a
        # decision. Every entry names the guard it really uses, and here it is looked up —
        # per action, so `only:`/`except:`/`skip_before_action` cannot hollow it out either.
        described_class::NON_PERMISSION_GUARDS.each do |endpoint, note|
          controller_name, action = endpoint.split('#')
          controller = ControllerSource.new(controller_name)
          covered = controller.actions_guarded_by(note[:guard])

          expect(controller.before_action_symbols).to include(note[:guard]),
                                                     "#{endpoint} claims #{note[:guard]}, " \
                                                     'which the controller does not run'
          expect(covered.nil? || covered.include?(action.to_sym)).to be(true),
                                                                    "#{endpoint} claims " \
                                                                    "#{note[:guard]}, which " \
                                                                    'does not run for that ' \
                                                                    'action'
          expect(note[:why].to_s.strip).not_to be_empty, "#{endpoint} has no reason"
        end
      end

      # ------------------------------------------------------------------
      # T-23. `authorize` is necessary and NOT sufficient on the templates controller,
      # and these examples are the mechanical half of saying so.
      #
      # Redmine's `authorize` passes when the actor holds ANY permission mapping the
      # action. Three consequences follow on this controller and each one is a hole
      # unless a second guard closes it:
      #
      #   * `manage_public_…` maps `#create`, so it alone would reach a code-execution
      #     endpoint — `require_create_permission` is what refuses it;
      #   * `import` needs `add_…` AND `edit_…`, a conjunction the permission model
      #     cannot express at all — `require_import_permissions` is that conjunction;
      #   * `edit_own_…` maps `#update`, and "own" is a property of the RECORD, which no
      #     permission can see — `require_edit_permission` asks the record.
      #
      # The functional suite proves each one by holding the permission and reading the
      # status code. This proves the guard is WIRED TO THE RIGHT ACTIONS, which is the
      # half a functional test passes vacuously if somebody narrows an `only:`.
      describe 'the second guard on the templates controller' do
        let(:templates) { ControllerSource.new('reporter_dashboards/templates') }

        it 'runs `authorize` for every action, unscoped' do
          # nil means "no only:, no except:, no skip_before_action" — which is the shape
          # the review of T-40 defeated when it was merely "authorize appears somewhere".
          expect(templates.actions_guarded_by(:authorize)).to be_nil
        end

        it 'requires add_… for exactly the two actions that create a template' do
          expect(templates.actions_guarded_by(:require_create_permission))
            .to eq(%i[new create])
        end

        it 'requires an edit permission for everything that changes or reveals content' do
          expect(templates.actions_guarded_by(:require_edit_permission))
            .to eq(%i[edit update destroy export])
        end

        it 'requires BOTH authoring permissions for import' do
          expect(templates.actions_guarded_by(:require_import_permissions))
            .to eq([:import])
        end

        it 'requires an authoring permission for preview, which executes the request body' do
          expect(templates.actions_guarded_by(:require_preview_permission))
            .to eq([:preview])
        end

        it 'resolves the preview base for exactly the same action as it guards' do
          # The preview guard is split across two filters with an ivar between them:
          # `find_preview_base` sets `@preview_base` and `require_preview_permission`
          # branches on it. If the two `only:` lists ever drift, the guard silently falls
          # through to the WEAKER id-less branch — which is the disclosure hole this pair
          # was written to close.
          expect(templates.actions_guarded_by(:find_preview_base))
            .to eq(templates.actions_guarded_by(:require_preview_permission))
        end

        it 'never lets a consuming-only action fall under an authoring guard' do
          # `index`, `show` and `document` are what `view_…_reports` maps, and a second
          # guard on any of them would silently require authoring to READ a report.
          authoring_guards = %i[require_create_permission require_edit_permission
                                require_import_permissions require_preview_permission]
          covered = authoring_guards.flat_map { |g| templates.actions_guarded_by(g) || [] }

          expect(covered & %i[index show document]).to be_empty
        end
      end

      it 'refuses a `define_method` in a controller body' do
        # An action whose name may be computed is an action no parser can promise to see, so
        # the honest answer is to refuse the construct rather than to ignore it and report
        # full coverage. If a later task genuinely needs one, it changes this example and
        # says why — which is a decision, not an omission.
        offenders = ControllerSource.all.reject { |c| c.define_method_calls.zero? }
                                    .map(&:name)

        expect(offenders).to be_empty,
                             "define_method in a controller body hides an action from the " \
                             "coverage check: #{offenders}"
      end

      it 'routes only to actions it can see' do
        # Reachability is a ROUTE property, and nothing here read `config/routes.rb` until
        # the review of T-40 pointed that out. A route to an action this file cannot enumerate
        # is an endpoint the coverage assertion above silently does not cover.
        expect(routed_endpoints - all_endpoints).to be_empty,
                                                   'config/routes.rb routes to actions that ' \
                                                   'are not public methods of a controller ' \
                                                   'this gate can see'
      end

      it 'accounts for every ROUTED action, not only every visible one' do
        accounted = mapped_endpoints + described_class::NON_PERMISSION_GUARDS.keys

        expect(routed_endpoints - accounted).to be_empty
      end

      it 'reads every line of config/routes.rb, or fails rather than skipping one' do
        # The recognised form is `to: 'controller#action'`. A `resources` block or a
        # `controller:`/`action:` hash would be a route this reader does not see — and a
        # scanner that cannot tell one construct from another is confidently wrong
        # (§Findings E-14). So every substantive line must match, and an unrecognised one
        # fails here instead of disappearing.
        unrecognised = routes_source.lines
                                    .map(&:strip)
                                    .reject { |line| line.empty? || line.start_with?('#') }
                                    .reject { |line| line.match?(/\bto:\s*'[a-z0-9_\/]+#\w+'/) }

        expect(unrecognised).to be_empty,
                                'these routes are in a form this gate cannot read: ' \
                                "#{unrecognised}"
      end
    end

    # ------------------------------------------------------------------
    describe '.collisions' do
      it 'is empty when every name appears once' do
        names = described_class.registered_names + %i[view_issues edit_issues]

        expect(described_class.collisions(names)).to be_empty
      end

      it 'names a permission another plugin registered as well' do
        names = described_class.registered_names + [:view_reporter_project_page]

        expect(described_class.collisions(names)).to eq([:view_reporter_project_page])
      end

      it 'ignores a duplicate that is not ours — that is the other plugin\'s problem' do
        names = described_class.registered_names + %i[view_issues view_issues]

        expect(described_class.collisions(names)).to be_empty
      end

      it 'reports every one of ours that clashes, sorted' do
        names = described_class.registered_names +
                %i[manage_reporter_project_tabs view_reporter_project_page]

        expect(described_class.collisions(names))
          .to eq(%i[manage_reporter_project_tabs view_reporter_project_page])
      end

      it 'is empty for an empty registry rather than raising' do
        expect(described_class.collisions([])).to be_empty
      end

      it 'is empty for a NIL registry rather than raising' do
        # `AccessControl.permissions` returns a bare `@permissions`, unset until something
        # registers, so this is the half-initialised case — and it happens inside a boot hook,
        # where a NoMethodError is the worst place for one.
        expect(described_class.collisions(nil)).to be_empty
      end
    end

    # ------------------------------------------------------------------
    # The boot hook's message. Split out of `RedmineReporterDashboards` so it is testable
    # without booting Redmine — the review of T-40 found the hook was the one new thing in
    # the change with no test at all.
    describe '.collision_message' do
      it 'is nil when there is no collision, so the hook logs nothing' do
        expect(described_class.collision_message(described_class.registered_names)).to be_nil
      end

      it 'is nil for a nil registry' do
        expect(described_class.collision_message(nil)).to be_nil
      end

      it 'names every colliding permission' do
        names = described_class.registered_names +
                %i[view_reporter_project_page manage_reporter_project_tabs]

        message = described_class.collision_message(names)

        expect(message).to include('view_reporter_project_page',
                                   'manage_reporter_project_tabs')
      end

      it 'says what the consequence is and that no setting fixes it' do
        # FR-74's discipline: a diagnostic names the remediation. Here the honest remediation
        # is "there is none locally", so it says that rather than implying a knob exists.
        message = described_class.collision_message(described_class.registered_names +
                                                    [:view_reporter_project_page])

        expect(message).to include('roles screen', 'union of both action maps',
                                   'no setting that fixes this')
      end

      it 'is prefixed like every other line this plugin logs' do
        message = described_class.collision_message(described_class.registered_names +
                                                    [:view_reporter_project_page])

        expect(message).to start_with('[reporter_dashboards] ')
      end
    end

    # ------------------------------------------------------------------
    describe '.find' do
      it 'finds a registered entry by name, given a symbol or a string' do
        expect(described_class.find(:view_reporter_project_page).group).to eq(:dashboards)
        expect(described_class.find('view_reporter_project_page').registered?).to be(true)
      end

      it 'finds a planned entry and reports it as not registered' do
        # `add_…` used to be this example's subject and T-23 registered it, which is the
        # promotion working. A still-planned entry replaces it rather than the example
        # being deleted: "PLANNED entries answer registered? => false" is the property,
        # not the particular permission that happened to be planned in 2026-08.
        entry = described_class.find(:share_reporter_dashboards_reports)

        expect(entry.registered?).to be(false)
        expect(entry.lands_in).to eq('T-28')
      end

      it 'finds a permission T-23 promoted and reports it as registered' do
        entry = described_class.find(:add_reporter_dashboards_templates)

        expect(entry.registered?).to be(true)
        expect(entry.lands_in).to be_nil
        expect(entry.actions).to eq(:'reporter_dashboards/templates' =>
                                      [:new, :create, :preview, :import])
      end

      it 'answers nil for a name it does not have' do
        expect(described_class.find(:view_issues)).to be_nil
      end
    end
  end
end
