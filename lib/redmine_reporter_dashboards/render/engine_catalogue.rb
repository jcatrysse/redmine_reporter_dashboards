# frozen_string_literal: true

require 'yaml'
require_relative 'capabilities'

module RedmineReporterDashboards
  module Render
    # Reads `config/capabilities.yml` — DoR-5's file — and validates it.
    #
    # --- DATA, NEVER BEHAVIOUR ---
    #
    # `YAML.safe_load` with no permitted classes and no aliases. Nothing in the file
    # becomes an object, a class or a method: an engine id here does NOT make an adapter
    # exist, and `Registry` remains a closed map written in Ruby. That separation is the
    # same one FR-55 draws for template import, and it exists because `YAML.load_file`
    # plus `constantize` is arbitrary class instantiation from file content — a
    # construct CLAUDE.md §5 names outright.
    #
    # --- VALIDATION IS THE POINT OF HAVING A CLASS AT ALL ---
    #
    # A YAML file read with `[]` is a hash of typos waiting to be a support claim. Every
    # capability is checked against the closed vocabulary, every role and verification
    # state against a closed set, and every asset model against the three §5.1 allows.
    # A file that does not validate raises at load — loudly, at boot or in the suite,
    # rather than silently answering `nil` to a question about what an engine can do.
    class EngineCatalogue
      DEFAULT_PATH = File.expand_path('../../../config/capabilities.yml', __dir__)

      ROLES = %w[reference compatibility documented].freeze

      # `corpus`  the conformance corpus has been run against it, and the matrix
      #           generator REFUSES to emit its column without a run
      # `pending` an adapter is planned and not written; the column exists and says so
      # `documented` no adapter ships; the declaration is design intent, not a result
      VERIFICATIONS = %w[corpus pending documented].freeze

      ASSET_MODELS = %w[inline upload fetch].freeze

      class InvalidCatalogue < StandardError; end

      Engine = Struct.new(:id, :label, :role, :default, :verification, :verification_note,
                          :needs_service, :renders_offline, :install, :version_floor,
                          :asset_models, :deprecated, :deprecation, :trade, :capabilities,
                          keyword_init: true) do
        # Plain defs, not endless ones: the plugin declares Redmine 5.1 support and
        # 5.1 runs on Ruby 2.7, where `def foo = expr` is a syntax error.
        # `.codex/check_ruby_floor.sh` is the gate, and it found these.
        def corpus_verified?
          verification == 'corpus'
        end

        def deprecated?
          deprecated ? true : false
        end
      end

      class << self
        def load(path = DEFAULT_PATH)
          @cache ||= {}
          @cache[path] ||= new(path)
        end

        def reset!
          @cache = {}
        end
      end

      attr_reader :path, :engines, :asset_models

      def initialize(path = DEFAULT_PATH)
        @path = path
        raw = YAML.safe_load(File.read(path, encoding: 'UTF-8'), permitted_classes: [],
                                                                 aliases: false)
        raise InvalidCatalogue, "#{source_name} is empty" unless raw.is_a?(Hash)

        @asset_models = validate_asset_models(raw['asset_models'])
        @engines = build_engines(raw['engines'])
        freeze
      end

      def source_name
        "`config/#{File.basename(path)}`"
      end

      def ids
        engines.map(&:id)
      end

      def [](id)
        engines.find { |engine| engine.id == id.to_s }
      end

      def default_engine
        engines.find(&:default)
      end

      private

      def build_engines(raw)
        raise InvalidCatalogue, "#{source_name} declares no engines" unless raw.is_a?(Hash) && !raw.empty?

        list = raw.map { |id, attrs| build_engine(id, attrs) }
        defaults = list.count(&:default)
        unless defaults == 1
          raise InvalidCatalogue,
                "#{source_name} marks #{defaults} engines as the default; exactly one has to be. " \
                'Zero means an install has nothing to fall back on, and two means the fallback ' \
                'depends on hash order.'
        end

        list.sort_by(&:id).freeze
      end

      def build_engine(id, attrs)
        raise InvalidCatalogue, "engine #{id.inspect} has no attributes" unless attrs.is_a?(Hash)

        Engine.new(
          id: id.to_s,
          label: fetch!(attrs, 'label', id),
          role: closed(attrs, 'role', ROLES, id),
          default: attrs['default'] ? true : false,
          verification: closed(attrs, 'verification', VERIFICATIONS, id),
          verification_note: squish(attrs['verification_note']),
          needs_service: attrs['needs_service'] ? true : false,
          renders_offline: attrs['renders_offline'] ? true : false,
          install: squish(fetch!(attrs, 'install', id)),
          version_floor: fetch!(attrs, 'version_floor', id),
          asset_models: engine_asset_models(attrs, id),
          deprecated: attrs['deprecated'] ? true : false,
          deprecation: squish(attrs['deprecation']),
          trade: squish(fetch!(attrs, 'trade', id)),
          capabilities: engine_capabilities(attrs, id)
        ).freeze
      end

      # THE CLOSED VOCABULARY, enforced. `Capabilities.validate!` raises on anything
      # outside it, which turns a mistyped capability from "an engine that silently
      # cannot do a thing it can" into a failure at load.
      def engine_capabilities(attrs, id)
        list = Array(fetch!(attrs, 'capabilities', id)).map(&:to_sym)
        Capabilities.validate!(list, "#{source_name}: engine #{id}")
      rescue Capabilities::UnknownCapability => e
        raise InvalidCatalogue, e.message
      end

      def engine_asset_models(attrs, id)
        list = Array(fetch!(attrs, 'asset_models', id)).map(&:to_s)
        unknown = list - ASSET_MODELS
        unless unknown.empty?
          raise InvalidCatalogue,
                "engine #{id}: #{unknown.inspect} is not one of the three asset models " \
                "#{ASSET_MODELS.inspect} (technical-spec.md §5.1). There is no fourth: the " \
                'shape is what the abstraction adopts, because no packaging standard exists.'
        end
        list.freeze
      end

      def validate_asset_models(raw)
        raise InvalidCatalogue, "#{source_name} declares no asset_models" unless raw.is_a?(Hash)

        missing = ASSET_MODELS - raw.keys
        unless missing.empty?
          raise InvalidCatalogue,
                "#{source_name} is missing the #{missing.join(', ')} asset model(s). All three " \
                'are described together on purpose — the policy table in §5.1 reads across them.'
        end

        raw.transform_values do |model|
          { 'capability' => model['capability'].to_s,
            'egress' => model['egress'] ? true : false,
            'description' => squish(model['description']) }.freeze
        end.freeze
      end

      def fetch!(attrs, key, id)
        value = attrs[key]
        return value unless value.nil?

        raise InvalidCatalogue, "engine #{id} has no #{key}, and every engine needs one"
      end

      def closed(attrs, key, allowed, id)
        value = fetch!(attrs, key, id).to_s
        return value if allowed.include?(value)

        raise InvalidCatalogue,
              "engine #{id}: #{key} #{value.inspect} is not one of #{allowed.inspect}"
      end

      # YAML folded scalars keep their newlines when a line is indented; the strings
      # here go into single table cells, and a stray newline breaks the table.
      def squish(text)
        return nil if text.nil?

        text.to_s.gsub(/\s+/, ' ').strip.freeze
      end
    end
  end
end
