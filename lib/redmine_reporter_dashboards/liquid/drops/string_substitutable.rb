# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    module Drops
      # The five methods that make a drop SUBSTITUTABLE for the String it replaces.
      #
      # `technical-spec.md` §3.3 specifies them for `NamedRefDrop`, and they are
      # extracted here because `VersionDrop` needs exactly the same contract for exactly
      # the same reason: the gem's `IssueDrop#version` returned `fixed_version.name`, a
      # String, and `{% if issue.version == "2026.1" %}` is in templates today. Two
      # copies of a contract that is only correct because a spec proves it is two things
      # to keep in step, and the second copy is the one nobody re-proves.
      #
      # | Method     | Behaviour           | Protects                                |
      # |------------|---------------------|-----------------------------------------|
      # | `to_s`     | `name`              | `{{ issue.status }}`                    |
      # | `==(other)`| `name == other`     | `{% if issue.status == "Closed" %}`     |
      # | `eql?`/`hash` | delegate to `name` | hash-keyed grouping filters           |
      # | `include?` | `name.include?(s)`  | `{% if issue.status contains "Clo" %}`  |
      # | `to_liquid`| `self`              | the drop protocol                       |
      #
      # EVERY ONE IS A CLAIM ABOUT LIQUID'S INTERNALS, and §3.3 is emphatic that they
      # must be proven by test rather than by reasoning: each is an assertion about how
      # Liquid compares, prints and looks inside a value, and those differ between 4.x
      # and 5.x. `spec_liquid/named_ref_drop_spec.rb` renders every idiom against the
      # String it replaces, under both majors, and `spec_liquid/drops_spec.rb` runs the
      # same battery against `VersionDrop` — because a module being shared is not
      # evidence that the sharing worked.
      #
      # The including class must answer `name`.
      module StringSubstitutable
        def to_s
          name
        end

        # THE DROP HAS TO BE ON THE LEFT, and that is a MEASURED LIMITATION rather than
        # a preference — §Findings E-8, decided by the curator on 2026-08-06.
        #
        # `{% if issue.status == "Closed" %}` works: Ruby asks the left operand, which is
        # this method. `{% if "Closed" == issue.status %}` does NOT: that asks
        # `String#==(drop)`, which answers false for anything that is not a String, and
        # nothing this class can do reaches it. The only two fixes are monkey-patching
        # String (forbidden) or making these classes String subclasses — which would
        # forfeit the Drop protocol and with it `{{ status.id }}` and `{{ status.url }}`.
        #
        # The decision was to keep the Drop and have T-19's linter flag the reversed
        # idiom at authoring time. The gap is pinned by a spec that asserts it AS IT IS,
        # in both classes, so a change in either direction reports itself.
        def ==(other)
          return name == other if other.is_a?(String)
          return name == other.name if other.is_a?(StringSubstitutable)

          false
        end

        # Delegated to `name` so a drop and its string group into the same bucket. A
        # filter that groups by status must not produce two buckets for "Closed"
        # depending on whether the value came through a drop.
        def eql?(other)
          self == other
        end

        def hash
          name.hash
        end

        # `{% if issue.status contains "Clo" %}` compiles to Ruby's `include?`, with the
        # drop as the receiver. Arity 1, exactly like `String#include?`: the substitution
        # claim is that this behaves as the String did, and a defaulted argument would be
        # a different method that happens to share a name.
        def include?(other)
          name.include?(other.to_s)
        end

        def to_liquid
          self
        end
      end
    end
  end
end
