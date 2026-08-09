# frozen_string_literal: true

require 'json'
require 'yaml'
require 'date'

module RedmineReporterDashboards
  # T-23's composition namespace. It names the Liquid layer and the render layer, which
  # is why it is neither of them: `script/gates/layer_purity.sh` forbids `liquid/**` from
  # naming `Render` and forbids `render/**` from naming a model, and SOMETHING has to put
  # a template, a scope and a PDF engine in the same sentence. That something is the
  # composition root, and in a Rails plugin the composition root is application code.
  #
  # The gate has an arm for this directory too, and it is a real boundary rather than a
  # formality: `reporting/**` may name both layers and may NOT hold the network or read
  # request state (`Net::HTTP`, `Faraday`, `cookie`, `session`). Composing the two layers
  # is the job; becoming a third render path or a second place that knows about HTTP is
  # the decay this arm exists to stop.
  module Reporting
    # The template exchange — FR-55, `technical-spec.md` §7b.2.
    #
    # --- WHAT THIS REPLACES, LITERALLY ---
    #
    # The base plugin's import is `YAML.load_file(file)` followed by
    # `attributes['type'].constantize`, wrapped in `rescue Exception`. Every one of those
    # three is a named defect in CLAUDE.md §5, and they compose into the worst version of
    # themselves: `YAML.load_file` will instantiate whatever classes the file names,
    # `constantize` will resolve whatever string survives, and `rescue Exception` hides
    # the result — including the `SignalException` that was trying to stop the process.
    #
    # So: `YAML.safe_load` with two permitted classes and no aliases, a **closed Hash**
    # from type name to a pair of field values, and `rescue StandardError` around the
    # parse with a typed refusal coming back out. `constantize` appears nowhere in this
    # file and a spec greps for it.
    #
    # --- CANONICAL FORMAT IS JSON ---
    #
    # §7b.2: JSON "has no class-instantiation surface at all". YAML is accepted for
    # READING so that a bundle exported from the base plugin still imports, and that
    # asymmetry is the whole design — we read the format the old plugin wrote, and we
    # write the one that cannot carry a class.
    #
    # --- WHAT T-29 ADDS, AND WHY IT IS NOT HERE ---
    #
    # §7b.2's full bundle is `{format_version, exported_at, plugin_version, templates:
    # [...]}` with `import:plan` / `import:run`, per-template transactions and
    # `--on-conflict`. T-29 owns that. This class reads and writes ONE template, which is
    # what the editor's Import/Export buttons need, and `parse` already accepts the
    # `templates:` array form so that T-29 wraps this rather than writing a second reader.
    module Exchange
      # Bumped when a field is added, removed or given a new meaning. A bundle whose
      # version this code does not know is REFUSED rather than read optimistically: the
      # failure mode of guessing is a template that imports with a field silently dropped.
      FORMAT_VERSION = 1

      # Everything a template IS, as data. Deliberately not `Template.column_names`:
      # that would export `id`, `lock_version`, timestamps and `source_template_id` — the
      # bookkeeping of ONE installation — and importing them would make the copy claim to
      # be the original. A closed list is also the only way a new column is a decision
      # rather than an accident.
      EXPORTED_FIELDS = %w[
        name description content source output orientation page_size margins
        engine_hint enabled failure_document
      ].freeze

      # THE CLOSED TYPE MAP. `technical-spec.md` §7b.2 asks for
      # `{'issue' => …, 'issue_list' => …, 'time_entries' => …}`; the three class names
      # are here as well because a bundle exported by the base plugin carries the CLASS
      # name (`ReportTemplate.available_types`), and refusing those would mean the
      # migration path this plugin exists to provide does not work on real files.
      #
      # Note what the map produces: a pair of ORDINARY STRING VALUES for two columns. It
      # does not produce a class, it cannot produce a class, and that is the difference
      # between this and `constantize`. Reporter's three types conflated two axes
      # (finding S-2), so one input maps to two outputs.
      TYPE_MAP = {
        'issue' => { 'source' => 'issues', 'output' => 'per_record' },
        'IssueReportTemplate' => { 'source' => 'issues', 'output' => 'per_record' },
        'issue_list' => { 'source' => 'issues', 'output' => 'combined' },
        'IssueListReportTemplate' => { 'source' => 'issues', 'output' => 'combined' },
        'time_entries' => { 'source' => 'time_entries', 'output' => 'combined' },
        'TimeEntriesReportTemplate' => { 'source' => 'time_entries',
                                         'output' => 'combined' }
      }.freeze

      # `Date` and `Time` only, and `aliases: false`. The two classes are what §7b.2
      # permits; aliases are refused because a YAML alias is how a small file expands
      # into a very large object graph (the "billion laughs" shape), and nothing this
      # plugin exports uses one.
      YAML_PERMITTED_CLASSES = [Date, Time].freeze

      # The refusal. A typed error rather than `nil` or `false`, because every caller has
      # to say WHY to the person holding the file — "that did not work" is the message
      # this whole task exists to stop shipping.
      class InvalidBundle < StandardError; end

      class << self
        # `engine_hint` GOES THROUGH THE MODEL'S DEGRADING READER, not through the
        # column. §7 rule 5: an install whose schema is one minor version behind must not
        # crash, and `engine_hint_supported?` plus `engine_hint_or_nil` exist for exactly
        # that. Reading it with `public_send` put a `NoMethodError` on the export path of
        # the one install the rule was written for — `ReportRun#resolve_engine` already
        # got this right, which is what made the inconsistency worth fixing rather than
        # arguing about.
        # Both entries are §7 rule 5 columns, read through the guard rather than off the
        # row, so an export from an install one minor behind answers `nil`/`false` instead
        # of raising. `failure_document` was added by T-30 and was MISSING FROM THE LIST
        # ABOVE at first — which this comment says out loud must be a decision rather than
        # an accident, and it silently turned the flag off on every export → import
        # round trip. FR-57's byte-identity still held, so no gate saw it; the independent
        # review did.
        DEGRADING_READERS = { 'engine_hint' => :engine_hint_or_nil,
                              'failure_document' => :failure_document? }.freeze

        # A plain Hash. Not JSON, not YAML, not a string: T-23's `Accept:` says "export
        # is a plain Hash", and the reason is that the serialisation belongs to the
        # caller — the controller writes JSON, T-29's bundle writer nests it, and a test
        # compares it field by field without parsing anything.
        def export(template)
          {
            'format_version' => FORMAT_VERSION,
            'template' => attributes(template)
          }
        end

        # ONE TEMPLATE AS DATA, WITHOUT THE ENVELOPE — and it is public because T-29's
        # `Bundle` is the second caller.
        #
        # The alternative was for `Bundle` to build its own field list, and that is the
        # defect this method exists to prevent: two lists drift, and the way they drift is
        # silent. `failure_document` was already missing from `EXPORTED_FIELDS` once (see
        # `DEGRADING_READERS` above) and no gate saw it, because a field that is absent
        # from BOTH the export and the re-export still round-trips byte-identically. A
        # second list would have made that failure mode permanent rather than a one-off.
        def attributes(template)
          EXPORTED_FIELDS.each_with_object({}) do |field, hash|
            reader = DEGRADING_READERS.fetch(field, field)
            hash[field] = template.respond_to?(reader) ? template.public_send(reader) : nil
          end
        end

        # Canonical bytes for the download. `JSON.pretty_generate` and a trailing newline
        # so the file is readable and diffable, and so §7b.2's round-trip test
        # (export → import → export is byte-identical) has something byte-stable to
        # compare. A Hash's key order is its insertion order in every Ruby this plugin
        # supports, and `EXPORTED_FIELDS` fixes that order.
        def dump(template)
          "#{JSON.pretty_generate(export(template))}\n"
        end

        # Read a bundle and answer the attributes for ONE template.
        #
        # `content` is bytes. The encoding is NAMED rather than inherited: HANDOVER §1
        # records that Ruby's default external encoding follows the locale, so a file
        # containing an em-dash raises `invalid byte sequence in US-ASCII` on a bare
        # container and works on a developer's machine. An uploaded file is the exact
        # case that warning is about.
        def parse(content)
          text = String(content).dup.force_encoding(Encoding::UTF_8)
          unless text.valid_encoding?
            raise InvalidBundle, 'the file is not valid UTF-8 text'
          end

          raw = decode(text)
          raise InvalidBundle, 'the file does not contain a report template' unless raw.is_a?(Hash)

          check_format_version!(raw)
          attributes_from(template_node(raw))
        end

        # §7 RULE 5 ON THE IMPORT SIDE, and it was missing on both callers until T-29.
        #
        # The EXPORT side has read its two rule-5 columns through the model's degrading
        # readers since T-23 (`DEGRADING_READERS` above), so an install one minor behind
        # exports `nil`/`false` instead of raising. The import side had no counterpart:
        # a bundle written by a current install and read by an older one reached
        # `Template.new('failure_document' => false)` and raised
        # `ActiveModel::UnknownAttributeError` — a stack trace where rule 5 asks for a
        # degraded feature, on exactly the install the rule exists for.
        #
        # `columns` is passed IN rather than read off the model, so this file stays free of
        # ActiveRecord and keeps being covered by the DB-less suite — which is where the
        # whole exchange format is tested. It answers both halves because DROPPING A FIELD
        # HAS TO BE VISIBLE (INV-4): the template that arrives is genuinely not the
        # template that was sent, and both callers log the difference.
        def assignable(attributes, columns)
          kept = attributes.select { |field, _| columns.include?(field) }
          [kept, attributes.keys - kept.keys]
        end

        # Bytes -> parsed document, with the JSON-then-YAML rule and the typed refusal.
        # Public for T-29's `Bundle`, which needs the WHOLE document rather than one
        # template out of it — and must not open a second decoding path to get it, since
        # the safe-YAML rules (two permitted classes, no aliases) are the entire security
        # content of this file.
        def decode!(content)
          text = String(content).dup.force_encoding(Encoding::UTF_8)
          raise InvalidBundle, 'the file is not valid UTF-8 text' unless text.valid_encoding?

          decode(text)
        end

        # The three readers below are public for the same single reason: `Bundle` composes
        # them in a different order (every template, not the first one) and must reuse the
        # closed type map, the field list and the version rule rather than restate them.
        #
        # `attributes_from` and `check_format_version!` were private until T-29 and their
        # behaviour is unchanged — only their visibility. `spec/reporting/exchange_spec.rb`
        # already covers both through `.parse`, and `spec/reporting/bundle_spec.rb` covers
        # them again through the bundle.
        def check_format_version!(raw)
          version = raw['format_version']
          # ABSENT IS ACCEPTED AND UNKNOWN IS NOT, which looks inconsistent and is not: a
          # bundle exported by the BASE plugin has no `format_version` at all, and that is
          # precisely the file this import exists to read. A version we do not recognise
          # is a file written by a NEWER version of this plugin, and reading it
          # optimistically is how a field gets silently dropped.
          return if version.nil?
          return if version.to_i == FORMAT_VERSION

          raise InvalidBundle,
                "this file says format_version #{version.inspect}, and this version of " \
                "the plugin reads #{FORMAT_VERSION}"
        end

        def attributes_from(node)
          attributes = node.slice(*EXPORTED_FIELDS)
          attributes.merge!(resolved_type(node))

          if attributes['name'].to_s.strip.empty?
            raise InvalidBundle, 'the template in this file has no name'
          end

          # `enabled` arrives as a string from YAML written by hand. Coerced here rather
          # than left to ActiveRecord, whose boolean cast reads "false" as TRUE when the
          # value arrives as a bare string — which would silently enable a template
          # somebody disabled.
          attributes['enabled'] = truthy?(attributes['enabled']) if attributes.key?('enabled')

          attributes
        end

        private

        # JSON first, YAML second, and the ORDER is not an optimisation. Every JSON
        # document is also valid YAML, so trying YAML first would route our own canonical
        # format through the more dangerous parser for no reason. `JSON.parse` builds only
        # Hash, Array, String, Numeric, true/false/nil — there is no class surface to
        # close.
        def decode(text)
          JSON.parse(text)
        rescue JSON::ParserError
          safe_load_yaml(text)
        end

        def safe_load_yaml(text)
          YAML.safe_load(text, permitted_classes: YAML_PERMITTED_CLASSES, aliases: false)
        rescue Psych::Exception => e
          # NOT `rescue Exception`. Psych's disallowed-class and alias refusals are both
          # `Psych::Exception`, so this catches exactly the file being wrong and lets a
          # SignalException or a NoMemoryError past, which is the whole point of the rule.
          raise InvalidBundle, "the file could not be read as JSON or YAML: #{e.message}"
        end

        # Four shapes, one reader: our own `{'template' => {...}}`, T-29's
        # `{'templates' => [{...}]}`, the base plugin's bare attribute Hash, and its
        # `{'report_template' => {...}}` wrapper.
        def template_node(raw)
          node = raw['template'] ||
                 raw['report_template'] ||
                 Array(raw['templates']).first ||
                 raw

          raise InvalidBundle, 'the file does not contain a report template' unless node.is_a?(Hash)

          node
        end

        # Rails' own `FALSE_VALUES`, written out rather than required.
        # `ActiveModel::Type::Boolean` would do this and pulling ActiveModel in here
        # would make a plain data reader depend on Rails — which is what keeps this file
        # testable in the DB-less suite, where the whole exchange format is covered.
        FALSE_VALUES = [false, nil, 0, '0', 'f', 'F', 'false', 'FALSE', 'False',
                        'off', 'OFF', 'Off', ''].freeze

        def truthy?(value)
          !FALSE_VALUES.include?(value)
        end

        # The closed lookup. An unknown type is a REFUSAL naming what was offered and
        # what is accepted — the base plugin's `constantize` would have tried to load it.
        def resolved_type(node)
          type = node['type']
          return {} if type.nil?
          # A file that carries BOTH the legacy `type` and the new columns is answering
          # the same question twice. The explicit columns win, because they are this
          # plugin's own vocabulary and the legacy name is a translation of it.
          return {} if node.key?('source') && node.key?('output')

          mapped = TYPE_MAP[type.to_s]
          unless mapped
            raise InvalidBundle,
                  "#{type.inspect} is not a report template type this plugin knows. " \
                  "Accepted: #{TYPE_MAP.keys.join(', ')}"
          end

          mapped.dup
        end
      end
    end
  end
end
