# frozen_string_literal: true

require 'json'

require_relative 'exchange'

module RedmineReporterDashboards
  module Reporting
    # T-29 — the versioned exchange BUNDLE. FR-55, FR-57, `technical-spec.md` §7b.2.
    #
    # --- WHAT THIS IS ON TOP OF `Exchange` ---
    #
    # §7b.2's bundle is `{format_version, exported_at, plugin_version, templates: [...]}`.
    # `Exchange` (T-23) already reads and writes ONE template and already holds the three
    # things that carry this format's security: the closed TYPE_MAP, the safe-YAML rules
    # and the field list. Its own comment says T-29 should "wrap this rather than writing
    # a second reader", and that is exactly what this module does — every template in a
    # bundle goes through `Exchange.attributes` on the way out and
    # `Exchange.attributes_from` on the way in.
    #
    # **There is no second type map and `constantize` still appears nowhere.** A spec
    # greps this file for both.
    #
    # --- FR-57: WHY BYTE-IDENTITY IS A PROPERTY OF THE WRITER, NOT A HOPE ---
    #
    # *"Export → import → export is byte-identical."* Four separate things have to be
    # true for that, and each is a decision made here rather than an accident:
    #
    #   ORDER      the templates are sorted by (name, id) on the way out, so a re-export
    #              cannot depend on the ids the receiving installation happened to assign.
    #              Ties keep their relative order, because import creates in bundle order
    #              and the second sort key then agrees with the first sort's outcome.
    #   KEY ORDER  a Ruby Hash preserves insertion order, `EXPORTED_FIELDS` fixes it for
    #              the template body, and `envelope` fixes it for the four outer keys.
    #   ENCODING   UTF-8, named. `JSON.generate` emits non-ASCII raw rather than escaped,
    #              so a template named `Übersicht` survives the round trip as the same
    #              bytes instead of as `Ü`.
    #   TIME       `exported_at` is an ARGUMENT. A bundle that stamped itself from the
    #              clock could not be byte-identical to anything, including itself one
    #              second later — so the claim would be untestable and the test that
    #              "proved" it would have had to ignore the field.
    #
    # The last one is worth being exact about, because it is the difference between a
    # claim and a slogan. What FR-57 asserts, and what the round-trip test measures, is
    # that the TEMPLATE PAYLOAD survives export → import → export unchanged. Two exports
    # taken at different moments legitimately differ in `exported_at`, and
    # `spec/reporting/bundle_spec.rb` asserts the payload halves are identical
    # INDEPENDENTLY of the envelope, so that neither half can hide a change in the other.
    module Bundle
      # The same number as `Exchange::FORMAT_VERSION`, and deliberately not a second
      # constant with its own value: the envelope and the template body are versioned
      # together because they are written and read together. If they ever need to move
      # apart, that is a decision with a migration behind it, not a second literal.
      FORMAT_VERSION = Exchange::FORMAT_VERSION

      # The same refusal type. A caller catching "this file is not a bundle" should not
      # have to catch two classes to find out.
      InvalidBundle = Exchange::InvalidBundle

      # A BOUND ON WHAT IS READ, because a bundle is a file somebody was handed.
      #
      # `Exchange.parse` reads one template out of a document and is bounded by that;
      # a bundle is a LIST, so the same file can ask this process to build ten million
      # attribute hashes. Neither limit is a guess about legitimate use — a hand-moved
      # export of a project's report templates is tens, not thousands — and both refuse
      # with a sentence naming the number, so an operator who genuinely has more knows
      # what to say to whoever raises it.
      MAX_TEMPLATES = 1_000
      # 32 MiB of JSON. Template content is HTML and Liquid, so this is generous by two
      # orders of magnitude for the bundle sizes this feature exists to move.
      MAX_BYTES = 32 * 1024 * 1024

      # What a parsed bundle IS. The envelope is kept rather than discarded because
      # `import:plan` prints it — an operator deciding whether to apply a file wants to
      # know when it was written and by which version, and a reader that threw that away
      # would make them open the file in an editor to find out.
      Parsed = Struct.new(:format_version, :exported_at, :plugin_version, :entries,
                          keyword_init: true)

      class << self
        # `templates` is any enumerable of template records. `exported_at` and
        # `plugin_version` are REQUIRED and have no defaults — see FR-57 above; a default
        # here would be a clock read, and CLAUDE.md §6 forbids one in anything a test
        # asserts on.
        def export(templates, exported_at:, plugin_version:)
          envelope(exported_at, plugin_version,
                   ordered(templates).map { |template| Exchange.attributes(template) })
        end

        # The canonical bytes. `JSON.pretty_generate` plus a trailing newline, which is
        # what `Exchange.dump` already writes for a single template — so the two formats
        # are diffable with the same tools and a reviewer reading a bundle in a pull
        # request sees one template per block rather than one line of 40 KB.
        def dump(templates, exported_at:, plugin_version:)
          "#{JSON.pretty_generate(export(templates, exported_at: exported_at,
                                                    plugin_version: plugin_version))}\n"
        end

        # Read a bundle and answer EVERY template in it.
        #
        # This is the one behavioural difference from `Exchange.parse`, which answers the
        # first: a bundle whose second template was silently ignored is the failure mode
        # §7b.2's two-step import exists to prevent, and it would look exactly like a
        # successful import of a smaller file.
        def parse(content)
          refuse_oversize(content)
          raw = Exchange.decode!(content)
          raise InvalidBundle, 'the file does not contain a report bundle' unless raw.is_a?(Hash)

          Exchange.check_format_version!(raw)
          nodes = template_nodes(raw)

          Parsed.new(
            format_version: raw['format_version'] || FORMAT_VERSION,
            exported_at: raw['exported_at'],
            plugin_version: raw['plugin_version'],
            entries: nodes.map { |node| Exchange.attributes_from(node) }
          )
        end

        private

        # SORTED BY NAME AND THEN BY ID — and the second key is what makes it total.
        # Sorting by name alone leaves ties to `Enumerable#sort_by`, which is not stable
        # in Ruby, so two templates sharing a name could swap places between two exports
        # of the same data and break FR-57 for a reason that has nothing to do with
        # importing. §Findings S-13's table names this exact class of defect: an oracle
        # that compares values "says nothing about the bucket's label, its order, its
        # existence".
        def ordered(templates)
          templates.to_a.sort_by { |template| [template.name.to_s, template.id.to_i] }
        end

        def envelope(exported_at, plugin_version, templates)
          {
            'format_version' => FORMAT_VERSION,
            'exported_at' => exported_at,
            'plugin_version' => plugin_version,
            'templates' => templates
          }
        end

        # A BUNDLE MUST SAY `templates`, and a single-template file is read too.
        #
        # The second half is not generosity: `Exchange.dump` has been writing
        # `{'format_version', 'template'}` since T-23 and the editor's Export button
        # produces one, so an operator who exported a template last month and feeds it to
        # `import:plan` today gets their template rather than a refusal. The base
        # plugin's two shapes are read for the same reason and by the same code.
        def template_nodes(raw)
          list = raw['templates']

          if list.nil?
            single = raw['template'] || raw['report_template']
            return [single] if single.is_a?(Hash)
            # A BARE ATTRIBUTE HASH IS ONLY A TEMPLATE IF IT LOOKS LIKE ONE. `Exchange`
            # accepts `raw` itself as a last resort, which is right for a reader whose
            # whole job is "one template"; here it would turn every malformed document
            # into a one-template bundle whose single entry then fails on a missing name,
            # reporting a confusing error instead of "this is not a bundle".
            return [raw] if raw.key?('name')

            raise InvalidBundle, 'the file does not contain a report bundle'
          end

          unless list.is_a?(Array)
            raise InvalidBundle,
                  "'templates' is #{list.class} in this file and a bundle's templates " \
                  'must be a list'
          end

          refuse_count(list.length)
          list.each_with_index do |node, index|
            next if node.is_a?(Hash)

            raise InvalidBundle,
                  "template #{index + 1} in this file is #{node.class} rather than a " \
                  'set of template fields'
          end

          # RETURNED EXPLICITLY. `each_with_index` happens to answer the receiver, so
          # falling off the end of the loop would work by coincidence — and would stop
          # working the day somebody appends a line to this method.
          list
        end

        def refuse_count(count)
          return if count <= MAX_TEMPLATES

          raise InvalidBundle,
                "this bundle carries #{count} templates and the limit is #{MAX_TEMPLATES}"
        end

        # MEASURED IN BYTES, NOT CHARACTERS. `String#length` on UTF-8 counts codepoints,
        # so a file of multi-byte text would be measured at up to a quarter of its real
        # size — and the whole point of the bound is what the process has to hold.
        def refuse_oversize(content)
          size = content.respond_to?(:bytesize) ? content.bytesize : content.to_s.bytesize
          return if size <= MAX_BYTES

          raise InvalidBundle,
                "this file is #{size} bytes and the limit is #{MAX_BYTES}"
        end
      end
    end
  end
end
