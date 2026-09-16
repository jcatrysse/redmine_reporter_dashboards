# frozen_string_literal: true

module RedmineReporterDashboards
  module Render
    # A CLOSED map from engine id to adapter — never `constantize`.
    #
    # FR-55 and CLAUDE.md §5 both name `YAML.load_file` + `constantize` as a forbidden
    # construct, and the reason applies here as much as to template import: an engine id
    # that reaches a class lookup is arbitrary class instantiation from configuration.
    # Registration is explicit, in Ruby, at load time.
    #
    # An UNKNOWN id raises rather than falling back to a default. A silent fallback
    # means a deployment that asks for one engine and quietly gets another — and then
    # reports the wrong engine in the PDF metadata, which is exactly the stamp that
    # exists so a document can say who drew it.
    module Registry
      class UnknownEngine < ArgumentError; end
      class DuplicateEngine < ArgumentError; end

      class << self
        def register(id, adapter)
          key = id.to_sym
          if registry.key?(key) && !registry[key].equal?(adapter)
            raise DuplicateEngine,
                  "engine #{key.inspect} is already registered to #{registry[key].inspect}. " \
                  'Two adapters answering to one id means the id no longer identifies anything.'
          end

          registry[key] = adapter
        end

        def fetch(id)
          registry.fetch(id.to_sym) do
            raise UnknownEngine,
                  "no render engine registered as #{id.inspect}. Known: #{ids.inspect}. " \
                  'Engines are registered explicitly rather than resolved from a class name.'
          end
        end

        def registered?(id)
          registry.key?(id.to_sym)
        end

        def ids
          registry.keys.sort
        end

        # For tests and for a boot that re-registers. Deliberately explicit rather than
        # letting `register` overwrite: see DuplicateEngine above.
        #
        # `reset!` DESTROYS GLOBAL STATE, and in a suite with `config.order = :random`
        # that is a defect waiting for a seed: the adapters register when their files are
        # required, so a spec that resets the registry and does not put it back leaves
        # every later example looking at an empty map. That happened — two adapter
        # examples failed on one seed and passed on the next, which reads as a
        # registration bug and is a test-isolation one. Prefer `isolated`, which is the
        # same reset with the restore attached to it.
        def reset!
          @registry = {}
        end

        def isolated
          saved = registry.dup
          @registry = {}
          yield
        ensure
          @registry = saved
        end

        private

        def registry
          @registry ||= {}
        end
      end
    end
  end
end
