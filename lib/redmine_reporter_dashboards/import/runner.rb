# frozen_string_literal: true

require 'digest'

require_relative 'survey'
require_relative '../reporting/exchange'

module RedmineReporterDashboards
  module Import
    # T-24 — `rake reporter_dashboards:import:run`, the write half of the migration path.
    #
    # `import:plan` (T-02) surveys and writes nothing. This copies.
    #
    # --- COPY. FORWARD-ONLY. NEVER ADOPT. ---
    #
    # `technical-spec.md` §7's *Adopt vs copy* section settles this and the reason is not a
    # preference: an operator following Redmine's own documented uninstall
    # (`migrate NAME=redmine_reporter VERSION=0`) runs the BASE plugin's down-migrations,
    # which drop `report_templates`. A plugin that had adopted those rows would lose them,
    # and *"nothing inside the new plugin can prevent that"*. So every row is copied into a
    # table this plugin owns, and the original is left exactly where it was.
    #
    # **This class never writes to a `report_*` table**, and that is held by construction
    # rather than by care: the only SQL it issues against them is the `SELECT` in `Survey`,
    # and the writes all go through `RedmineReporterDashboards::Template`, which cannot
    # address another plugin's table.
    #
    # The mechanical evidence is
    # `test/unit/reporter_dashboards_import_runner_test.rb`'s
    # `test_it_issues_no_write_against_reporters_tables`, which subscribes to
    # `sql.active_record` and fails on any writing verb aimed at a `report_*` table. It is
    # in the FULL-APP suite and not in `spec/` because it needs those tables to exist so
    # that a write to them would be observable at all. The first version of this comment
    # cited `spec/import/runner_spec.rb`, which has never existed — the same defect that
    # got T-32's first attempt rejected, repeated one task later.
    #
    # --- IDEMPOTENT, AND "IDEMPOTENT" HAS FOUR OUTCOMES RATHER THAN TWO ---
    #
    # `source_template_id` is the key and `source_digest` is the fingerprint of the content
    # that was copied. Re-running is therefore not "create or overwrite" but a decision:
    #
    #   :created    no copy exists for this source id
    #   :unchanged  a copy exists, and neither side has moved
    #   :updated    the SOURCE moved and the copy did not — a safe fast-forward
    #   :diverged   the COPY was edited here since it was imported. NOT overwritten
    #
    # The fourth is the one the task's `Accept:` line is about: *"`import_status` reports
    # divergence so drift is **visible rather than silent**"*. An importer that overwrote a
    # locally-edited template would destroy the work somebody did after migrating, once,
    # quietly, on a re-run somebody triggered for an unrelated reason. Refusing and NAMING
    # it is the only outcome that cannot lose data.
    #
    # A template imported and then edited here is the EXPECTED state after a migration, not
    # an error — which is why `:diverged` is reported as a count and a list rather than as a
    # failure, and why the task's exit code does not turn non-zero for it.
    module Runner
      # What one source template became. `reason` is only set for the outcomes that need a
      # sentence — a skipped or diverged row is useless without one.
      Outcome = Struct.new(:source_id, :name, :status, :template_id, :reason,
                           keyword_init: true)

      Result = Struct.new(:outcomes, :notes, :dry_run, keyword_init: true) do
        def counts
          outcomes.group_by(&:status).transform_values(&:length)
        end

        def count(status)
          counts.fetch(status, 0)
        end

        # `:skipped` is the only outcome that means "this template did not migrate". The
        # other four all leave a usable copy behind, `:diverged` included — that one has a
        # copy, it is simply not the source's current content.
        def failed?
          count(:skipped).positive?
        end
      end

      # The columns this needs beyond what `Survey` asks for. `content` is the point of the
      # exercise; without it there is nothing to copy and the run reports that rather than
      # importing a set of empty templates.
      REQUIRED_COLUMNS = %w[id type content].freeze
      OPTIONAL_COLUMNS = %w[name project_id].freeze

      class << self
        # `actor` OWNS EVERY IMPORTED TEMPLATE, and it is a required argument for the same
        # reason `RenderContext`'s is. `author_id` decides who `edit_own_…` lets through, so
        # a nil here would either fail validation or — worse, if the column were nullable —
        # produce templates nobody can edit. The rake task passes the administrator running
        # it.
        #
        # `project_id` COMES FROM THE SOURCE ROW and is not remapped. A template belongs to
        # the project it was written for; inventing a different one would silently move
        # somebody's report between projects, and the permission that governs it with it.
        # `rewrite:` — DECISION 2, and it is the flag `technical-spec.md` §7a already named
        # (`import:run [--only] [--rewrite]`) and T-24's first version neither built nor
        # reported. Without it the only way to accept the source's version after editing
        # locally was to DELETE the copy and re-run, which is data loss offered as a
        # documented step.
        #
        # It is NOT a plain overwrite. The local content is written into the template's own
        # version history FIRST, so taking the source's version loses nothing and can be
        # rolled back from the editor — `reporter_dashboards_template_versions` is
        # append-only and exists for exactly this. The flag therefore changes which content
        # is CURRENT, never which content still exists.
        def call(actor:, connection: nil, dry_run: false, project_ids: nil, rewrite: false)
          connection ||= ::ActiveRecord::Base.connection
          notes = []
          rows = read_source(connection, notes, project_ids)

          outcomes = rows.map { |row| import_one(row, actor, dry_run, notes, rewrite) }

          Result.new(outcomes: outcomes, notes: notes, dry_run: dry_run)
        end

        # The divergence report, on its own, writing nothing. `import:status` is this.
        #
        # It is deliberately NOT a second traversal of reporter's tables: it asks OUR
        # templates which source they came from and whether they still match it, so it
        # keeps working after the base plugin has been uninstalled — which is exactly when
        # an operator wants to know what state their migration is in.
        def status(connection: nil)
          connection ||= ::ActiveRecord::Base.connection
          notes = []
          imported = Template.where.not(source_template_id: nil).order(:id).to_a
          sources = source_digests(connection, notes)

          rows = imported.map do |template|
            source_digest = sources[template.source_template_id]
            Outcome.new(source_id: template.source_template_id, name: template.name,
                        template_id: template.id,
                        status: compare(template, source_digest),
                        reason: status_reason(template, source_digest))
          end

          Result.new(outcomes: rows, notes: notes, dry_run: true)
        end

        # THE FINGERPRINT. SHA-256 over the content bytes and nothing else.
        #
        # Not `Digest::MD5` — CLAUDE.md §5 forbids it for anything security-bearing, and
        # while this one is a change detector rather than a token, using the same primitive
        # everywhere means nobody has to work out which is which. Not the whole row either:
        # the question this answers is "has the CONTENT moved", and including `updated_on`
        # would make every touch look like an edit.
        def digest(content)
          ::Digest::SHA256.hexdigest(content.to_s)
        end

        # Who owns the copies. A rake task runs as Anonymous, so the caller has to name
        # somebody — and it must be an ADMINISTRATOR, because an imported template can land
        # in any project the source used and no single non-admin is guaranteed to be a
        # member of all of them. `nil` when there is nobody, so the task can refuse with a
        # sentence instead of raising a validation error per template.
        #
        # `RRD_ACTOR` accepts a login or an id. The id branch is `Integer()`-guarded rather
        # than `to_i`, because `to_i` turns "jsmith" into 0 and `find_by(id: 0)` into a
        # confusing nil.
        def resolve_actor(reference)
          if reference.present?
            # `User.active` ON BOTH BRANCHES. They disagreed: the fallback below used it
            # and this one did not, so `RRD_ACTOR=locked-admin` authored every imported
            # template as an account that cannot log in — and `author_id` is what
            # `edit_own_…` reads, which is the reason this argument exists. Found by an
            # independent review; the mutation that removed `.active` from the fallback had
            # survived, so nothing was testing the property on either side.
            scope = ::User.active.where(admin: true)
            user = if reference.to_s.match?(/\A\d+\z/)
                     scope.find_by(id: Integer(reference, 10))
                   else
                     scope.find_by(login: reference.to_s)
                   end
            return user
          end

          ::User.active.where(admin: true).order(:id).first
        end

        private

        def read_source(connection, notes, project_ids)
          unless Survey.send(:table_exists?, connection, Survey::TEMPLATES)
            notes << "#{Survey::TEMPLATES} does not exist, so there is nothing to import. " \
                     'This is the expected state on an installation that never had the ' \
                     'base plugin.'
            return []
          end

          available = Survey.send(:column_names, connection, Survey::TEMPLATES)
          missing = REQUIRED_COLUMNS - available
          unless missing.empty?
            notes << "#{Survey::TEMPLATES} has no #{missing.join(', ')} column, so nothing " \
                     'could be imported. This is a missing answer, not an empty result.'
            return []
          end

          columns = (REQUIRED_COLUMNS + OPTIONAL_COLUMNS) & available
          sql = +"SELECT #{columns.map { |c| Survey.send(:q, connection, c) }.join(', ')} " \
                 "FROM #{Survey.send(:qt, connection, Survey::TEMPLATES)}"
          # THE ONLY VALUE THAT REACHES THE SQL, and it is cast to Integer first. Every
          # other identifier in this file comes from a frozen constant — same rule as
          # `Survey`, and the reason it is a rule is that this runs against an operator's
          # production database.
          if project_ids
            ids = Array(project_ids).map { |id| Integer(id) }
            # AN EMPTY FILTER IS A NOTE, NOT A CLEAN RUN. `RRD_PROJECTS=` expands to `''`,
            # `''.split(',')` is `[]` and `[]` is truthy — so the task imported nothing and
            # printed "Every template is imported and matches its source." Exactly the
            # clean-verdict-over-nothing `ImportReport` exists to prevent.
            if ids.empty?
              notes << 'a project filter was given but named no project, so nothing was ' \
                       'imported. Remove RRD_PROJECTS to import everything.'
              return []
            end

            sql << " WHERE #{Survey.send(:q, connection, 'project_id')} IN (#{ids.join(', ')})"
          end
          sql << " ORDER BY #{Survey.send(:q, connection, 'id')} " \
                 "LIMIT #{Survey::MAX_TEMPLATES + 1}"

          rows = Survey.send(:select_rows, connection, sql)
          if rows.length > Survey::MAX_TEMPLATES
            rows = rows.first(Survey::MAX_TEMPLATES)
            notes << "more than #{Survey::MAX_TEMPLATES} templates: only the first " \
                     "#{Survey::MAX_TEMPLATES} by id were imported. Re-run to continue."
          end

          rows.map { |row| columns.zip(row).to_h }
        end

        def import_one(row, actor, dry_run, notes, rewrite = false)
          source_id = row['id']
          name = row['name'].presence || "Imported template #{source_id}"
          mapped = Reporting::Exchange::TYPE_MAP[row['type'].to_s]

          # AN UNKNOWN TYPE IS SKIPPED WITH ITS NAME, not guessed at. FR-55's closed map is
          # what stops a file naming a class, and the same map is what stops a DATABASE
          # naming one: `constantize` on `report_templates.type` would be the identical
          # defect with a different input channel.
          unless mapped
            return Outcome.new(source_id: source_id, name: name, status: :skipped,
                               reason: "unknown template type #{row['type'].inspect}. " \
                                       "Known: #{Reporting::Exchange::TYPE_MAP.keys.join(', ')}")
          end

          content = row['content'].to_s
          # AN EMPTY SOURCE IS SKIPPED, and the file's own comment already said so while the
          # code imported it: "without it there is nothing to copy and the run reports that
          # rather than importing a set of empty templates". A NULL `content` produced a
          # template that renders nothing, reported as `created`.
          if content.strip.empty?
            return Outcome.new(source_id: source_id, name: name, status: :skipped,
                               reason: 'the source template has no content')
          end

          # DECISION 3 — A TEMPLATE WHOSE PROJECT IS NOT HERE IS SKIPPED, NOT IMPORTED.
          #
          # `belongs_to :project, optional: true` does no existence check, so a source row
          # naming a project that was never migrated (or has since been deleted) imported
          # cleanly, reported `created`, and produced a template that is INVISIBLE and
          # UNREACHABLE: every surface in this plugin is scoped through a project, so it
          # cannot be opened, edited or deleted through the interface. Found by an
          # independent review.
          #
          # Skipping and naming the project id is what this task does with every other
          # unusable input. Importing it anyway is the "reported success over something
          # nobody can use" shape the whole `ImportReport` verdict exists to refuse.
          #
          # An ARCHIVED project is deliberately NOT refused: the row is real, the template
          # becomes reachable again when somebody unarchives it, and refusing would make a
          # migration depend on the order an operator happens to unarchive things in.
          project_id = row['project_id']
          if project_id.present? && !::Project.exists?(id: project_id)
            return Outcome.new(source_id: source_id, name: name, status: :skipped,
                               reason: "its project (##{project_id}) does not exist here. " \
                                       'Migrate or recreate the project first, then re-run.')
          end

          existing = Template.find_by(source_template_id: source_id)
          return create_copy(row, name, mapped, content, actor, dry_run, notes) if existing.nil?

          refresh_copy(existing, name, mapped, content, dry_run, notes, actor, rewrite)
        end

        def create_copy(row, name, mapped, content, actor, dry_run, notes = [])
          source_id = row['id']
          if name.to_s.length > Template::MAX_STRING
            notes << "source ##{source_id}'s name is longer than " \
                     "#{Template::MAX_STRING} characters and was shortened."
          end
          template = Template.new(
            name: name.to_s[0, Template::MAX_STRING],
            content: content,
            project_id: row['project_id'],
            author_id: actor.id,
            source: mapped['source'],
            output: mapped['output'],
            # PRIVATE TO THE IMPORTER, exactly as a bundle import is (T-23). The source
            # plugin has its own visibility vocabulary and this one does not know how to
            # translate it, so the safe answer is the narrow one — widening is a decision
            # `manage_public_…` exists to govern and an administrator makes it afterwards.
            visibility: Template::VISIBILITY_PRIVATE,
            source_template_id: source_id,
            source_digest: digest(content)
          )

          return Outcome.new(source_id: source_id, name: name, status: :created) if dry_run

          if template.save
            Outcome.new(source_id: source_id, name: name, status: :created,
                        template_id: template.id)
          else
            Outcome.new(source_id: source_id, name: name, status: :skipped,
                        reason: template.errors.full_messages.join(', '))
          end
        end

        # THE FOUR-WAY DECISION. See the class comment; the case that matters is the last.
        def refresh_copy(existing, name, mapped, content, dry_run, notes, actor = nil,
                         rewrite = false)
          source_digest = digest(content)
          local_digest = digest(existing.content)

          if existing.source_digest == source_digest && local_digest == source_digest
            return Outcome.new(source_id: existing.source_template_id, name: existing.name,
                               status: :unchanged, template_id: existing.id)
          end

          # THE COPY WAS EDITED HERE. Whether or not the source also moved, overwriting
          # would throw away somebody's work — so it is reported and left alone, and the
          # note says what an operator can do about it.
          if local_digest != existing.source_digest
            unless rewrite
              notes << "template #{existing.id} (#{existing.name}) has been edited since " \
                       'it was imported, so it was left alone. Re-run with RRD_REWRITE=1 ' \
                       "to take the source's version — your edit is kept in the template's " \
                       'version history and can be rolled back to.'
              return Outcome.new(source_id: existing.source_template_id, name: existing.name,
                                 status: :diverged, template_id: existing.id,
                                 reason: 'edited here since import')
            end

            unless dry_run
              # THE SNAPSHOT COMES FIRST, and it is what makes `rewrite` non-destructive.
              # If this raises, nothing is overwritten — the order is the guarantee.
              existing.versions.create!(content: existing.content, author_id: actor&.id)
            end
            notes << "template #{existing.id} (#{existing.name}) was rewritten from its " \
                     "source. The edit made here is version " \
                     "#{existing.versions.count} in its history."
          end

          return Outcome.new(source_id: existing.source_template_id, name: existing.name,
                             status: :updated, template_id: existing.id) if dry_run

          existing.content = content
          existing.source = mapped['source']
          existing.output = mapped['output']
          existing.source_digest = source_digest

          if existing.save
            Outcome.new(source_id: existing.source_template_id, name: existing.name,
                        status: :updated, template_id: existing.id)
          else
            Outcome.new(source_id: existing.source_template_id, name: existing.name,
                        status: :skipped, template_id: existing.id,
                        reason: existing.errors.full_messages.join(', '))
          end
        end

        # `{source_id => digest}` for every source template still readable. Empty — not an
        # error — when the base plugin is gone, which is a state `#status` must survive.
        def source_digests(connection, notes)
          unless Survey.send(:table_exists?, connection, Survey::TEMPLATES)
            notes << "#{Survey::TEMPLATES} is gone, so the source content cannot be " \
                     'compared. Everything below is reported as source-absent rather than ' \
                     'as up to date.'
            return {}
          end

          rows = Survey.send(:select_rows, connection, <<~SQL)
            SELECT #{Survey.send(:q, connection, 'id')}, #{Survey.send(:q, connection, 'content')}
            FROM #{Survey.send(:qt, connection, Survey::TEMPLATES)}
            ORDER BY #{Survey.send(:q, connection, 'id')}
            LIMIT #{Survey::MAX_TEMPLATES}
          SQL

          rows.to_h { |id, content| [id, digest(content)] }
        end

        def compare(template, source_digest)
          local_digest = digest(template.content)

          return :source_absent if source_digest.nil?
          return :diverged if local_digest != template.source_digest
          return :stale if source_digest != template.source_digest

          :unchanged
        end

        def status_reason(template, source_digest)
          case compare(template, source_digest)
          when :source_absent
            'the source template no longer exists'
          when :diverged then 'edited here since it was imported'
          when :stale then 'the source has changed; re-run import:run to take it'
          end
        end
      end
    end
  end
end
