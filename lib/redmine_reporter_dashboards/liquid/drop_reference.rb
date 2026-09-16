# frozen_string_literal: true

require_relative 'drops'

module RedmineReporterDashboards
  module Liquid
    # T-37 / FR-72 — THE DROP REFERENCE, GENERATED FROM THE DECLARED SURFACE.
    #
    # `technical-spec.md` §9b.1 clause 2: *"FR-20 already requires every drop to expose
    # only its declared surface. That declaration is therefore a machine-readable API
    # description, and the reference sidebar is **rendered from it at runtime**: every drop,
    # every accessor, its type, whether it is a batch accessor, and a copyable `{{ … }}`
    # snippet. Consequence worth stating plainly: **documentation drift for the drop layer
    # becomes structurally impossible** … Same generator emits the Markdown reference."*
    #
    # --- WHAT IS GENERATED AND WHAT IS DECLARED, BECAUSE THE DIFFERENCE IS THE WHOLE GATE
    #
    # GENERATED: the accessor NAMES. They come from `Liquid::Drop.invokable_methods`, which
    # is what a template can actually reach — public instance methods minus `Drop`'s own.
    # Nothing here lists a name by hand.
    #
    # DECLARED: the TYPE and the BATCH flag, which no method signature carries. Ruby cannot
    # tell that `due_date` is a Date and `done_ratio` an Integer, and it certainly cannot
    # tell that `spent_hours` costs one query for a whole loop while `subject` costs none.
    #
    # THE GATE IS WHAT KEEPS THE SECOND HONEST. `script/gates/drop_reference_parity.sh`
    # compares the two sets in BOTH directions and fails on either: an accessor added to a
    # drop with no entry here is undocumented surface, and an entry here for a method that
    # no longer exists is a reference that lies. Neither can reach a release, which is what
    # §9b.1's "structurally impossible" means in practice — the drift is a red build rather
    # than a stale wiki page.
    #
    # --- WHY THIS IS `liquid/` AND NOT `render/` ---
    #
    # `implementation-plan.md`'s `Touches:` line for T-37 says `render/drop_reference.rb`,
    # and that placement is impossible: `script/gates/layer_purity.sh`'s render arm forbids
    # `render/**` from naming `Liquid` at all, so a file there that reads a drop class would
    # be a G8 failure by construction on its first line. The reference is ABOUT the Liquid
    # drops and belongs beside them; this directory may not name `Render` and does not.
    # Recorded rather than quietly moved (CLAUDE.md §11.3) — see the T-37 status row.
    #
    # --- WHY THE VALUES ARE NOT TRANSLATED ---
    #
    # A type name (`string`, `date`, `url`) and an accessor name are code, and the snippet
    # is code an author copies. The surrounding labels are locale keys in the view; this
    # module is under `lib/` where `layer_purity.sh` keeps Rails — and therefore I18n — out.
    # The same split `_diagnostics.html.erb` and `TemplateLinter` already make.
    module DropReference
      # `to_liquid` is on every drop's invokable list because `Liquid::Drop` defines it, and
      # `{{ issue.to_liquid }}` renders the drop itself. It is the drop PROTOCOL rather than
      # template vocabulary, so it is excluded here — explicitly and in one place, so that
      # "it is missing from the reference" has an answer rather than being a hole.
      PROTOCOL = %w[to_liquid].freeze

      # The closed type vocabulary. A type not in this list is a typo, and the spec asserts
      # that every declared type is one of these — otherwise `type: :sting` documents a
      # field as a word nobody can look up.
      TYPES = %i[string text integer decimal date time boolean url html ref drop collection
                 lookup].freeze

      # One accessor. `batch` means READING IT IN A LOOP COSTS NO EXTRA QUERY — §3.4's batch
      # registry — which is the single most useful thing an author can know about an
      # accessor and cannot see from its name.
      Accessor = Struct.new(:name, :type, :of, :batch, :note, keyword_init: true) do
        def batch?
          batch ? true : false
        end

        # The copyable snippet §9b.1 asks for. `lookup` is the bracket form, which is not a
        # method call and must not be printed as one.
        def snippet(variable)
          return "{{ #{variable}.#{name}[42] }}" if type == :lookup

          "{{ #{variable}.#{name} }}"
        end
      end

      # One drop, as an author meets it. `variable` is what they type — the assign name for
      # a top-level drop, and a plausible local for one reached through another.
      #
      # `note` is the one piece of prose per section, and four sections need it: a drop
      # whose entire surface is a BRACKET LOOKUP or a `{% for %}` has no accessors to list,
      # and a table saying "no accessors of its own" with nothing beside it reads as a gap
      # in the reference rather than as the answer.
      Section = Struct.new(:klass, :variable, :reached_from, :note, :accessors,
                           keyword_init: true) do
        def title
          klass
        end
      end

      # ------------------------------------------------------------------
      # The declaration
      # ------------------------------------------------------------------
      #
      # Key order is the order the reference prints, and it is the order an author meets
      # them: what a report is about first, then the two things every template has, then the
      # drops reached through those, then the bases.
      #
      # `inherits:` merges a base's accessors in rather than repeating them four times.
      # Parity is checked against the MERGED set, because `invokable_methods` includes
      # inherited methods and a per-class comparison would otherwise report every base
      # accessor as undocumented on every subclass.
      DECLARED = {
        'IssueDrop' => {
          variable: 'issue',
          reached_from: 'assigned to a per-issue template; one issue of `issues`',
          inherits: 'RecordDrop',
          accessors: {
            'subject' => { type: :string },
            'description' => { type: :text },
            'start_date' => { type: :date },
            'due_date' => { type: :date },
            'done_ratio' => { type: :integer },
            'estimated_hours' => { type: :decimal },
            'total_estimated_hours' => { type: :decimal,
                                         note: 'this issue and its descendants' },
            'spent_hours' => { type: :decimal, batch: true,
                               note: 'only the hours your role may see' },
            'total_spent_hours' => { type: :decimal,
                                     note: 'this issue and its descendants' },
            'created_on' => { type: :time, note: "in the report actor's own time zone" },
            'updated_on' => { type: :time, note: "in the report actor's own time zone" },
            'closed_on' => { type: :time, note: "in the report actor's own time zone" },
            'status' => { type: :ref, note: 'prints its name; compares with a string' },
            'tracker' => { type: :ref },
            'priority' => { type: :ref },
            'category' => { type: :ref },
            'author' => { type: :drop, of: 'UserDrop' },
            'assignee' => { type: :drop, of: 'UserDrop' },
            'project' => { type: :drop, of: 'ProjectDrop' },
            'parent' => { type: :drop, of: 'IssueDrop' },
            'version' => { type: :drop, of: 'VersionDrop' },
            'target_version' => { type: :drop, of: 'VersionDrop',
                                  note: 'the same object as `version`' },
            'attachments' => { type: :collection, of: 'AttachmentDrop', batch: true },
            'time_entries' => { type: :collection, of: 'TimeEntryDrop', batch: true },
            'subtasks' => { type: :collection, of: 'IssueDrop', batch: true },
            'custom_field_values' => { type: :lookup, of: 'CustomFieldValuesDrop',
                                       batch: true,
                                       note: 'by field id or by field name' },
            'custom_field_value' => { type: :lookup, of: 'CustomFieldValuesDrop',
                                      batch: true,
                                      note: 'the same object as `custom_field_values`' },
            'status_id' => { type: :integer },
            'tracker_id' => { type: :integer },
            'priority_id' => { type: :integer },
            'category_id' => { type: :integer },
            'author_id' => { type: :integer },
            'assigned_to_id' => { type: :integer },
            'project_id' => { type: :integer },
            'parent_id' => { type: :integer },
            'fixed_version_id' => { type: :integer },
            'closed' => { type: :boolean },
            'closed?' => { type: :boolean, note: 'the same as `closed`' },
            'overdue' => { type: :boolean },
            'overdue?' => { type: :boolean, note: 'the same as `overdue`' },
            'private' => { type: :boolean },
            'is_private?' => { type: :boolean, note: 'the same as `private`' },
            'visible' => { type: :boolean, note: 'to the actor this report is rendered as' },
            'visible?' => { type: :boolean, note: 'the same as `visible`' },
            'url' => { type: :url, note: 'absolute, so it survives a PDF and an e-mail' },
            'link' => { type: :html, note: 'an `<a>` element; already escaped' }
          }
        },
        'IssuesDrop' => {
          variable: 'issues',
          reached_from: 'assigned to a combined template',
          note: 'Iterate it with `{% for issue in issues %}`; every accessor above is then ' \
                'available on `issue`, and the loop is what preloads the associations.',
          inherits: 'CollectionDrop',
          # THE THREE ROWS THAT ANSWER "of what". `CollectionDrop` cannot say what its
          # elements are, and a subclass can — so each collection overrides the base's rows
          # with the element type rather than leaving a reader to guess.
          accessors: {
            'first' => { type: :drop, of: 'IssueDrop', note: 'or `first: 5` for the first five' },
            'visible' => { type: :collection, of: 'IssueDrop',
                           note: "already the actor's visible scope; kept for readability" },
            'all' => { type: :collection, of: 'IssueDrop',
                       note: 'REFUSED and recorded as a degradation — iterate instead' }
          }
        },
        'TimeEntryDrop' => {
          variable: 'time_entry',
          reached_from: 'assigned to a per-entry template; one entry of `time_entries`',
          inherits: 'RecordDrop',
          accessors: {
            'spent_on' => { type: :date },
            'hours' => { type: :decimal },
            'comments' => { type: :string },
            'user' => { type: :drop, of: 'UserDrop' },
            'activity' => { type: :ref },
            'activity_id' => { type: :integer },
            'project' => { type: :drop, of: 'ProjectDrop' },
            'project_id' => { type: :integer },
            'issue_id' => { type: :integer,
                            note: 'nil for an entry booked on the project' },
            'created_on' => { type: :time },
            'updated_on' => { type: :time },
            'url' => { type: :url }
          }
        },
        'TimeEntriesDrop' => {
          variable: 'time_entries',
          reached_from: 'assigned to a combined spent-time template',
          note: 'Iterate it with `{% for time_entry in time_entries %}`.',
          inherits: 'CollectionDrop',
          accessors: {
            'first' => { type: :drop, of: 'TimeEntryDrop',
                         note: 'or `first: 5` for the first five' },
            'visible' => { type: :collection, of: 'TimeEntryDrop',
                           note: "already the actor's visible scope; kept for readability" },
            'all' => { type: :collection, of: 'TimeEntryDrop',
                       note: 'REFUSED and recorded as a degradation — iterate instead' }
          }
        },
        'ProjectDrop' => {
          variable: 'project',
          reached_from: "always assigned — the template's own project",
          inherits: 'RecordDrop',
          accessors: {
            'name' => { type: :string },
            'identifier' => { type: :string },
            'description' => { type: :text },
            'status' => { type: :integer, note: '1 active, 5 closed, 9 archived' },
            'url' => { type: :url }
          }
        },
        'UserDrop' => {
          variable: 'user',
          reached_from: 'always assigned — the actor this report is rendered as',
          inherits: 'RecordDrop',
          accessors: {
            'login' => { type: :string },
            'firstname' => { type: :string },
            'lastname' => { type: :string },
            'name' => { type: :string, note: "Redmine's own display order" },
            'url' => { type: :url }
          }
        },
        'VersionDrop' => {
          variable: 'version',
          reached_from: '`issue.version`, and `{% version_rollup %}`',
          accessors: {
            'name' => { type: :string, note: 'prints its name; compares with a string' },
            'description' => { type: :text },
            'effective_date' => { type: :date, note: 'the due date of the version' },
            'status' => { type: :string, note: 'open, locked or closed' },
            'sharing' => { type: :string },
            'completed_percent' => { type: :decimal },
            'project' => { type: :drop, of: 'ProjectDrop' },
            'project_id' => { type: :integer },
            'project_identifier' => { type: :string },
            'project_name' => { type: :string },
            'id' => { type: :integer },
            'include?' => { type: :boolean, note: 'substring of the name, so `contains` works' },
            'url' => { type: :url },
            'roadmap_url' => { type: :url },
            'issues_url' => { type: :url },
            'open_issues_url' => { type: :url },
            'closed_issues_url' => { type: :url },
            'time_url' => { type: :url, note: 'the spent-time report for this version' }
          }
        },
        'AttachmentDrop' => {
          variable: 'attachment',
          reached_from: '`issue.attachments`',
          inherits: 'RecordDrop',
          accessors: {
            'filename' => { type: :string },
            'filesize' => { type: :integer },
            'content_type' => { type: :string },
            'description' => { type: :string },
            'created_on' => { type: :time },
            'author' => { type: :drop, of: 'UserDrop' },
            'url' => { type: :url },
            'download_url' => { type: :url,
                                note: 'a report can only show it if the asset policy resolves it' }
          }
        },
        'CustomFieldValueDrop' => {
          variable: 'field',
          reached_from: '`issue.custom_field_values[42]`',
          accessors: {
            'id' => { type: :integer },
            'name' => { type: :string },
            'value' => { type: :string, note: 'an array for a multiple-value field' }
          }
        },
        'CustomFieldValuesDrop' => {
          variable: 'issue.custom_field_values',
          reached_from: '`issue.custom_field_values` / `issue.custom_field_value`',
          note: 'A BRACKET LOOKUP rather than a set of accessors: ' \
                '`{{ issue.custom_field_values[42] }}` by field id, or by field name. ' \
                'A field your role may not see resolves to nothing at all — not to a ' \
                'blank value, and not to the field name with an empty cell.',
          accessors: {}
        },
        'NamedRefDrop' => {
          variable: 'status',
          reached_from: '`issue.status`, `.tracker`, `.priority`, `.category`, `time_entry.activity`',
          accessors: {
            'id' => { type: :integer },
            'name' => { type: :string },
            'include?' => { type: :boolean, note: 'substring of the name, so `contains` works' },
            'url' => { type: :url, note: 'nil where Redmine has no page for it' }
          }
        },
        'RecordDrop' => {
          variable: 'record',
          reached_from: 'the base of every single-record drop',
          accessors: {
            'id' => { type: :integer }
          }
        },
        'CollectionDrop' => {
          variable: 'issues',
          reached_from: 'the base of every collection drop',
          note: 'A collection is also indexable by id — `{{ issues[42] }}` — and iterating ' \
                'it is what preloads the associations, which is why `all` is refused.',
          accessors: {
            'size' => { type: :integer, note: 'counts in SQL; does not load the records' },
            'first' => { type: :drop, note: 'or `first: 5` for the first five' },
            'visible' => { type: :collection,
                           note: "already the actor's visible scope; kept for readability" },
            'all' => { type: :collection,
                       note: 'REFUSED and recorded as a degradation — iterate instead' }
          }
        },
        'UsersDrop' => {
          variable: 'users',
          reached_from: 'not assigned by any surface today',
          note: 'Shipped for completeness; nothing hands one to a template, so this row ' \
                'exists to make its absence from the vocabulary deliberate.',
          inherits: 'CollectionDrop',
          accessors: {
            'first' => { type: :drop, of: 'UserDrop', note: 'or `first: 5` for the first five' },
            'visible' => { type: :collection, of: 'UserDrop',
                           note: "already the actor's visible scope; kept for readability" },
            'all' => { type: :collection, of: 'UserDrop',
                       note: 'REFUSED and recorded as a degradation — iterate instead' }
          }
        },
        'ProjectsDrop' => {
          variable: 'projects',
          reached_from: 'not assigned by any surface today',
          note: 'Shipped for completeness; nothing hands one to a template.',
          inherits: 'CollectionDrop',
          accessors: {
            'first' => { type: :drop, of: 'ProjectDrop',
                         note: 'or `first: 5` for the first five' },
            'visible' => { type: :collection, of: 'ProjectDrop',
                           note: "already the actor's visible scope; kept for readability" },
            'all' => { type: :collection, of: 'ProjectDrop',
                       note: 'REFUSED and recorded as a degradation — iterate instead' }
          }
        }
      }.freeze

      class << self
        # The reference, as data: one Section per drop, accessors in declared order, names
        # taken from the runtime and metadata from `DECLARED`.
        def sections
          known_declared.map do |klass, spec|
            Section.new(klass: klass, variable: spec[:variable],
                        reached_from: spec[:reached_from], note: spec[:note],
                        accessors: accessors_for(klass))
          end
        end

        # ---------------------------------------------------------------- parity
        #
        # BOTH DIRECTIONS, because they are different defects. An undocumented accessor is
        # surface nobody was told about; a documented accessor that no longer exists is a
        # reference that lies, and an author following it gets an empty render (or, under
        # `strict_variables`, an error) with the documentation insisting it should work.

        # { klass => [names] } — reachable from a template and not in the reference.
        def undocumented
          disagreements { |runtime, declared| runtime - declared }
        end

        # { klass => [names] } — in the reference and not reachable.
        def absent_at_runtime
          disagreements { |runtime, declared| declared - runtime }
        end

        def parity?
          undocumented.empty? && absent_at_runtime.empty?
        end

        # Every accessor of every drop this layer ships, so the checker cannot pass by
        # examining a subset: a drop class with no entry in `DECLARED` at all is itself a
        # finding, not a class to skip.
        def unreferenced_classes
          (Drops::CLASSES + Drops::BASES) - DECLARED.keys
        end

        # THE OTHER DIRECTION OF THE SAME MISTAKE, and it was found by planting it: a key
        # here naming a class that does not exist used to raise `NameError` out of
        # `runtime_names` — and an uncaught Ruby exception exits **1**, which the gate
        # wrapper reads as "findings" rather than as "the reader crashed". So the same typo
        # that should have printed one line printed a backtrace under a FAIL heading, and a
        # reader who fixed the "finding" would have been fixing the wrong thing.
        #
        # It is a finding rather than a raise, and `#sections` and `#disagreements` skip such
        # a key, so every other check still runs and reports.
        def unknown_classes
          DECLARED.keys.reject { |klass| Drops.const_defined?(klass) }
        end

        # ---------------------------------------------------------------- markdown

        # The `docs/` half of §9b.1's "same generator". Deliberately plain Markdown with no
        # front matter and no anchors beyond the headings: it is read on GitHub, in an
        # editor, and by `git diff` when this file changes.
        def markdown
          lines = ['# Report template drop reference', '', BANNER, '']
          sections.each { |section| lines.concat(markdown_section(section)) }
          "#{lines.join("\n").rstrip}\n"
        end

        BANNER = <<~TEXT.strip
          <!-- GENERATED — do not edit. Written by `rake reporter_dashboards:drop_reference`
          from `lib/redmine_reporter_dashboards/liquid/drop_reference.rb`, whose accessor
          names come from the drops themselves at runtime. `script/gates/drop_reference_parity.sh`
          fails the build if this file and the code disagree in either direction. -->
        TEXT

        private

        def markdown_section(section)
          lines = ["## #{section.title}", '',
                   "Reached from: #{section.reached_from}.", '']
          if section.note
            lines << section.note
            lines << ''
          end
          if section.accessors.empty?
            lines << '_No accessors of its own._'
            lines << ''
            return lines
          end

          lines << '| Accessor | Type | Batch | Snippet | Notes |'
          lines << '|---|---|---|---|---|'
          section.accessors.each do |accessor|
            lines << format('| `%s` | %s | %s | `%s` | %s |',
                            accessor.name, type_label(accessor),
                            accessor.batch? ? 'yes' : '',
                            accessor.snippet(section.variable), accessor.note.to_s)
          end
          lines << ''
          lines
        end

        def type_label(accessor)
          accessor.of ? "#{accessor.type} (#{accessor.of})" : accessor.type.to_s
        end

        # DECLARED ORDER, and the runtime set is what decides membership. An accessor
        # declared here and gone from the code does NOT appear — the gate reports it
        # instead, so a stale entry cannot reach a reader even on the run that finds it.
        def accessors_for(klass)
          runtime = runtime_names(klass)

          declared_for(klass).filter_map do |name, spec|
            next unless runtime.include?(name)

            Accessor.new(name: name, type: spec[:type], of: spec[:of],
                         batch: spec[:batch], note: spec[:note])
          end
        end

        # The merged declaration: a subclass's own accessors plus its base's, so a
        # collection drop does not restate `size`, `first`, `visible` and `all`.
        def declared_for(klass)
          spec = DECLARED.fetch(klass, {})
          base = spec[:inherits]
          own = spec[:accessors] || {}
          return own if base.nil?

          (DECLARED.dig(base, :accessors) || {}).merge(own)
        end

        # WHAT A TEMPLATE CAN REACH, asked of the class rather than of a list.
        #
        # `invokable_methods` is Liquid's own answer — public instance methods minus
        # `Drop`'s — and it is memoised per class by the gem, so this is cheap enough to
        # call on an editor request.
        def runtime_names(klass)
          constant = Drops.const_get(klass)
          constant.invokable_methods.to_a.map(&:to_s) - PROTOCOL
        end

        def disagreements
          known_declared.keys.each_with_object({}) do |klass, out|
            difference = yield(runtime_names(klass).sort, declared_for(klass).keys.sort)
            out[klass] = difference unless difference.empty?
          end
        end

        # `DECLARED` minus any key that names no drop class. `#unknown_classes` reports those
        # separately; skipping them here is what lets the rest of the checks still run and
        # print, rather than the first typo taking the whole reader down.
        def known_declared
          DECLARED.reject { |klass, _spec| unknown_classes.include?(klass) }
        end
      end
    end
  end
end
