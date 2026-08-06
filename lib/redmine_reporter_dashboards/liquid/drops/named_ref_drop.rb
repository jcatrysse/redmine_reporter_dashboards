# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A reference to a named record — a status, a tracker, a priority, an assignee —
      # that a template can still treat as the String it used to be.
      #
      # --- THE PROBLEM THIS SOLVES, AND WHY IT IS NOT "ADD `status_id`" ---
      #
      # Today `{{ issue.status }}` is a String. Every template in the wild does
      # `{% if issue.status == "Closed" %}`, and any change that breaks that breaks every
      # install at once. But a String cannot answer `{{ issue.status.id }}`, so the base
      # plugin grew a second vocabulary of `*_id` accessors, and `{% geo_version_map %}`
      # — 295 lines of tag — exists mostly to build a lookup from version NAME to
      # `{id, effective_date, status, project}` because the drop could not carry it.
      #
      # The rejected alternative was "keep Strings, add `*_id` only". It has zero
      # compatibility risk and it hard-codes the vocabulary forever: no `status.url`, no
      # dissolving that tag, and two tags plus 295 lines survive for nothing.
      #
      # So: an object that IS substitutable for the String, in the five ways a template
      # can actually observe the difference.
      #
      # --- EVERY ONE OF THESE IS A CLAIM ABOUT LIQUID'S INTERNALS ---
      #
      # `technical-spec.md` §3.3 is emphatic and it is right: each row below is an
      # assertion about how Liquid compares, prints and looks inside a value, and it
      # differs between 4.x and 5.x in ways nobody should be predicting from memory.
      #
      #   to_s        `name`                  {{ issue.status }}
      #   ==(other)   `name == other`         {% if issue.status == "Closed" %}
      #   eql?/hash   delegate to `name`      hash-keyed grouping filters
      #   include?    `name.include?(s)`      {% if issue.status contains "Clo" %}
      #   to_liquid   `self`                  the drop protocol itself
      #
      # `spec_liquid/named_ref_drop_spec.rb` renders each idiom through a REAL Liquid
      # template on 4.0.x and 5.x and asserts byte-equality with what the String does.
      # Reasoning about it was explicitly not accepted as evidence.
      #
      # --- AND THE ESCAPE HATCH SHIPS ANYWAY ---
      #
      # The `*_id` accessors are kept as well, deliberately. Five one-line methods are
      # cheap, and they are what a template author reaches for if drop-versus-String
      # semantics bite in a shape the spec did not enumerate. Belt and braces where the
      # cost of being wrong is every install's templates.
      class NamedRefDrop < ::Liquid::Drop
        attr_reader :id, :name, :url

        def initialize(id:, name:, url: nil, attributes: {})
          @id = id
          @name = name.to_s
          # ALWAYS ABSOLUTE, which is what makes the base plugin's 38 lines of
          # Nokogiri-or-regexp URL rewriting unnecessary: a drop that emits a relative
          # path forces something downstream to rewrite it for the PDF, and that
          # something has to guess which attributes are URLs.
          @url = url
          # Extra fields a caller wants to expose — `effective_date`, `status`,
          # `project` for a version. This is what dissolves `{% geo_version_map %}`:
          # the map that tag builds is just these attributes, per name.
          @attributes = attributes.transform_keys(&:to_s).freeze
          super()
        end

        # --- The five substitutability methods -------------------------------------

        def to_s
          name
        end

        # A String on either side. `name == other` rather than `other == name` because
        # the reverse asks the STRING to compare itself to a Drop, and String#== answers
        # false for anything that is not a String — which is the whole failure mode.
        # Liquid's `==` operator evaluates left-to-right with the drop on the left in
        # every idiom that matters, and the spec asserts both orders anyway.
        def ==(other)
          return name == other if other.is_a?(String)
          return name == other.name if other.is_a?(self.class)

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

        # `{% if issue.status contains "Clo" %}` compiles to `include?`.
        def include?(other)
          name.include?(other.to_s)
        end

        def to_liquid
          self
        end

        # --- The drop protocol -------------------------------------------------------

        # `liquid_method_missing` rather than `method_missing`: Liquid's Drop already
        # routes unknown keys here, and overriding the Ruby one would expose every
        # method this object happens to have to template authors — which is the
        # arbitrary-invocation hazard the Drop base class exists to close.
        #
        # --- AND NOTHING ELSE MAY BE PUBLIC HERE. MEASURED, NOT ASSUMED ---
        #
        # The first draft of this class also defined `key?` and `attributes`, which
        # looked like ordinary conveniences and broke the drop protocol outright:
        # `{{ status.id }}` rendered EMPTY. Liquid's `VariableLookup` asks
        # `object.respond_to?(:key?)` to decide whether a value is hash-like, and having
        # answered yes, it then asked `key?('id')` — which consulted the attributes hash,
        # found nothing, and returned nil without ever trying the method. Defining a
        # method called `key?` was enough to make every accessor on this class
        # unreachable from a template.
        #
        # Two rules follow. Every public method here is part of the contract, and adding
        # one is a decision about what templates can reach — `attributes` was also
        # exposed to authors as `{{ status.attributes }}`, which is exactly the internals
        # leak `Liquid::Drop` exists to prevent. And this is why §3.3 says the five
        # methods must be PROVEN rather than reasoned about: nothing about `key?`
        # suggests it is load-bearing until a template renders blank.
        def liquid_method_missing(method)
          @attributes[method.to_s]
        end

        def inspect
          "#<NamedRefDrop #{name.inspect} id=#{id.inspect}>"
        end
      end
    end
  end
end
