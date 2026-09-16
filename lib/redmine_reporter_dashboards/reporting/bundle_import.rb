# frozen_string_literal: true

require_relative 'bundle'
require_relative '../template_linter'

module RedmineReporterDashboards
  module Reporting
    # T-29 — FR-56, the two-step import. `technical-spec.md` §7b.2.
    #
    # *"Import is two steps: `plan` reports per template whether it is new, updated or
    # skipped, plus lint findings and unknown drop paths, WRITING NOTHING; then apply
    # applies it, one transaction per template, so one bad template does not abort the
    # bundle — each failure is reported with a reason (`rescue StandardError`, never
    # `Exception`). Conflicts are explicit: `--on-conflict skip|rename|overwrite`."*
    #
    # --- WHY `plan` AND `apply` ARE ONE CLASS AND NOT TWO ---
    #
    # They must answer the SAME question. A plan that says "3 new, 1 overwritten" and an
    # apply that then does something else is worse than no plan at all, because the
    # operator acted on it. So the decision — which entry conflicts with what, and what
    # the conflict policy does about it — is `#decide`, called by both, and the only
    # difference between the two entry points is whether the decision is then carried out.
    # `test/unit/reporter_dashboards_bundle_import_test.rb`'s
    # `test_the_plan_predicts_exactly_what_the_apply_does` asserts the two agree entry by
    # entry. (That citation named a spec file that does not exist until it was checked —
    # HANDOVER §1: if a comment says "asserted in X", open X.)
    #
    # --- "WRITING NOTHING" IS ASSERTED, NOT PROMISED ---
    #
    # T-02's `import:plan` established the control this copies:
    # `spec/adapter/import_survey_spec.rb` subscribes to `sql.active_record` and fails on
    # any statement that is not a SELECT. `#plan` has the same control in
    # `test/unit/reporter_dashboards_bundle_import_test.rb`'s
    # `test_plan_issues_no_write_statement_at_all`, which additionally STRIPS a leading
    # `/* rails */` before reading the verb — HANDOVER §1 records that an SQL assertion
    # anchored at `\A` is defeated by exactly that comment, and T-24's central claim was
    # asserted this way while a planted UPDATE survived it. A comment saying "read-only" is
    # exactly the control CLAUDE.md §7 calls "specified as mechanical and implemented as a
    # comment".
    class BundleImport
      # A CLOSED SET, and `else` is not a branch — the shape T-25's review found reporting
      # success while mailing one person's data to somebody else's list. An unknown policy
      # is refused at construction rather than falling through to a default, because every
      # default here is somebody's data being overwritten or silently not imported.
      CONFLICT_SKIP = 'skip'
      CONFLICT_RENAME = 'rename'
      CONFLICT_OVERWRITE = 'overwrite'
      CONFLICT_POLICIES = [CONFLICT_SKIP, CONFLICT_RENAME, CONFLICT_OVERWRITE].freeze
      DEFAULT_CONFLICT_POLICY = CONFLICT_SKIP

      # How many `Name (2)`, `Name (3)` … a rename will try before giving up. Bounded
      # because the loop queries per attempt: an unbounded search over a pathological
      # project is a rake task that never returns, and refusing at 100 with a sentence is
      # information where a hang is not.
      MAX_RENAME_ATTEMPTS = 100

      # One template's outcome. `action` is from the closed set below; `reason` is filled
      # in for everything that is not a plain success, because "skipped" with no reason is
      # the report this task exists to replace.
      #
      #   :create     it is not here yet
      #   :update     it is here and the policy says overwrite
      #   :rename     it is here and the policy says rename
      #   :skip       it is here and the policy says skip
      #   :failed     it could not be applied — validation, permission, or a raise
      Outcome = Struct.new(:name, :applied_name, :action, :reason, :template_id,
                           :lint_errors, :lint_warnings, keyword_init: true) do
        def failed?
          action == :failed
        end
      end

      Report = Struct.new(:outcomes, :notes, :planned, :bundle, keyword_init: true) do
        def failed?
          outcomes.any?(&:failed?)
        end

        def counts
          outcomes.group_by(&:action).transform_values(&:length)
        end
      end

      attr_reader :project, :actor, :on_conflict

      def initialize(project:, actor:, on_conflict: DEFAULT_CONFLICT_POLICY, logger: nil)
        # AN ACTOR IS REQUIRED (INV-1). `author_id` is what `edit_own_…` reads, so an
        # import with no actor would create templates nobody owns — and the overwrite arm
        # below has a permission check that would have nothing to ask about.
        raise ArgumentError, 'a bundle import needs an actor (INV-1)' if actor.nil?

        policy = on_conflict.to_s
        unless CONFLICT_POLICIES.include?(policy)
          raise ArgumentError,
                "#{on_conflict.inspect} is not a conflict policy. " \
                "Accepted: #{CONFLICT_POLICIES.join(', ')}"
        end

        @project = project
        @actor = actor
        @on_conflict = policy
        @logger = logger
      end

      # WRITES NOTHING. See the class comment for the assertion that holds this.
      def plan(content)
        parsed = Bundle.parse(content)
        notes = []
        state = initial_state

        outcomes = parsed.entries.map do |entry|
          decision = decide(entry, notes, state)
          lint = lint_counts(entry)

          Outcome.new(name: entry['name'], applied_name: decision[:applied_name],
                      action: decision[:action], reason: decision[:reason],
                      template_id: decision[:existing]&.id,
                      lint_errors: lint[:errors], lint_warnings: lint[:warnings])
        end

        Report.new(outcomes: outcomes, notes: notes, planned: true, bundle: parsed)
      end

      # ONE TRANSACTION PER TEMPLATE, which is the whole of FR-56's second half.
      #
      # The loop is what makes "one bad template does not abort the bundle" true: each
      # entry is applied inside its own savepoint and its own rescue, so a validation
      # error, a permission refusal or an unforeseen raise costs exactly that entry. A
      # single transaction around the whole bundle would be the opposite behaviour and
      # would look identical in a green test.
      def apply(content)
        parsed = Bundle.parse(content)
        notes = []

        state = initial_state
        outcomes = parsed.entries.map { |entry| apply_entry(entry, notes, state) }

        Report.new(outcomes: outcomes, notes: notes, planned: false, bundle: parsed)
      end

      private

      attr_reader :logger

      def apply_entry(entry, notes, state)
        decision = decide(entry, notes, state)
        lint = lint_counts(entry)

        outcome =
          # `requires_new: true` FORCES A SAVEPOINT. Without it a nested `transaction`
          # inside an outer one (which is every Rails test, and any caller that wrapped
          # the import) is a no-op, so a rollback would discard the OUTER transaction's
          # work or nothing at all — and the per-template isolation this method exists for
          # would quietly not exist.
          template_class.transaction(requires_new: true) do
            carry_out(decision, entry)
          end

        outcome.lint_errors = lint[:errors]
        outcome.lint_warnings = lint[:warnings]
        outcome
      rescue StandardError => e
        # `StandardError`, NEVER `Exception` — CLAUDE.md §5's first forbidden construct and
        # §7b.2's own wording. A `SignalException` or a `NoMemoryError` must leave this
        # loop, because continuing to import templates while the process is being killed
        # is how a half-applied bundle happens.
        warn_line("[exchange] template #{entry['name'].inspect} could not be imported: " \
                  "#{e.class}: #{e.message}")
        Outcome.new(name: entry['name'], action: :failed, reason: e.message,
                    lint_errors: lint[:errors], lint_warnings: lint[:warnings])
      end

      def carry_out(decision, entry)
        case decision[:action]
        when :skip
          Outcome.new(name: entry['name'], action: :skip, reason: decision[:reason],
                      template_id: decision[:existing]&.id)
        when :update
          overwrite(decision[:existing], entry)
        when :rename
          create(entry, decision[:applied_name], action: :rename,
                        reason: decision[:reason])
        when :create
          create(entry, entry['name'], action: :create)
        else
          # THE CLOSED SET, CLOSED AT THE POINT OF USE TOO. `#decide` produces these four
          # and nothing else; if a fifth is ever added, this is the line that says so
          # rather than the import silently doing nothing for it.
          raise ArgumentError, "#{decision[:action].inspect} is not an import action"
        end
      end

      # A CONFLICT IS A TEMPLATE THAT WAS HERE BEFORE THIS RUN STARTED, and the snapshot is
      # what makes that sentence true. Read ONCE, before the first entry.
      #
      # --- THE TWO DEFECTS THIS FIXES, both found by an independent review ---
      #
      # `decide` used to ask the DATABASE per entry. Two consequences, and both are the
      # kind that look like nothing in a green suite:
      #
      # 1. **A bundle carrying two templates with the SAME NAME lost one.** `Template` has
      #    no uniqueness validation on `name` (it copies core's `Query`, which has none), so
      #    two templates in one project may legitimately share a name and an export
      #    faithfully contains both. On import the second one collided with the FIRST ONE
      #    THIS RUN HAD JUST CREATED, took the `skip` branch, and was dropped — with the
      #    reason *"a template called X is already in this project"*, which was not what
      #    happened. FR-57's byte-identity fails on exactly that bundle. Measured:
      #    2 templates in, `{create: 1, skip: 1}`, 1 landed.
      #
      # 2. **`plan` did not predict `apply`** on the same bundle — the thing this class's
      #    own comment calls "worse than no plan at all". `plan` writes nothing, so its
      #    second entry saw no conflict and said `create`; `apply`'s second entry saw the
      #    row the first had just written and said `skip`. Measured: plan `{create: 2}`,
      #    apply `{create: 1, skip: 1}`.
      #
      # Snapshotting closes both at once, and it closes them the same way for both entry
      # points, which is why they cannot drift apart again. A within-bundle duplicate is
      # NOT a conflict: the source had two templates with that name, so the destination
      # gets two. `claimed` exists only so that RENAME cannot hand two entries the same new
      # name — it is about the names this run has spoken for, not about conflicts.
      def initial_state
        preexisting = template_class.where(project_id: project&.id)
                                    .order(:id)
                                    .each_with_object({}) do |template, map|
          map[template.name.to_s] ||= template
        end

        { preexisting: preexisting, claimed: {} }
      end

      # THE DECISION, MADE ONCE AND USED TWICE. See the class comment.
      def decide(entry, notes, state)
        name = entry['name'].to_s
        existing = state[:preexisting][name]

        if existing.nil?
          state[:claimed][name] = true
          return { action: :create, applied_name: name }
        end

        case on_conflict
        when CONFLICT_SKIP
          { action: :skip, existing: existing, applied_name: name,
            reason: "a template called #{name.inspect} was already in this project " \
                    'before this import started' }
        when CONFLICT_RENAME
          renamed = free_name(name, state)
          state[:claimed][renamed] = true if renamed
          if renamed.nil?
            { action: :skip, existing: existing, applied_name: name,
              reason: "no free name was found after #{MAX_RENAME_ATTEMPTS} attempts" }
          else
            { action: :rename, existing: existing, applied_name: renamed,
              reason: "renamed from #{name.inspect}" }
          end
        else
          decide_overwrite(existing, name, notes)
        end
      end

      # OVERWRITE IS THE ONE ARM THAT NEEDS A PERMISSION, and it needs it because it is
      # the only one that writes to a record that was already here. Everything else
      # creates a row this actor authors.
      #
      # `editable_by?` is the same predicate the controller's `require_edit_permission`
      # uses, so "may I overwrite this" gets the same answer at a rake prompt as it does
      # over HTTP — including the `edit_own_…` case, where the answer depends on who
      # authored the template rather than on the project alone. A refusal is a SKIP with a
      # reason rather than a failure: the operator asked to import a bundle, and one
      # template they may not touch is not a broken bundle.
      # UNSCOPED BY VISIBILITY, on purpose — `initial_state` reads every template in the
      # project rather than `Template.visible(actor)`. A private template somebody else
      # authored is still a name that is taken; answering "no conflict" for it would create
      # a second template with the same name whose duplicate its owner cannot see. A
      # conflict is a fact about the project, not about the actor.
      def decide_overwrite(existing, name, notes)
        unless existing.editable_by?(actor)
          return { action: :skip, existing: existing, applied_name: name,
                   reason: 'you may not edit the template already in this project ' \
                           'under that name' }
        end

        # CONDITIONAL, because this note is written at DECISION time and the overwrite can
        # still fail. `apply` rolls the version snapshot back with the rest of the entry's
        # savepoint, so an unconditional "is kept" would be a report of something that did
        # not happen — on exactly the entry a reader is most likely to check.
        notes << "#{name}: if this is overwritten, the content already here is kept in " \
                 "the template's version history and can be rolled back to."
        { action: :update, existing: existing, applied_name: name }
      end

      # CREATING NEEDS A PERMISSION TOO, and until an independent review asked, only
      # OVERWRITING had one. The asymmetry was defensible-by-accident — the only shipped
      # caller is a rake task whose `resolve_actor` requires an active administrator — but
      # "no caller can reach it today" is not a guard, and this class is exactly the kind of
      # thing a later controller action picks up. Measured before the fix: a non-member
      # holding only `view_issues` created a template in a project they are not in.
      #
      # A project-less template is administrator-only by construction, because Redmine has
      # no role grant outside a project (technical-spec.md §4.1) — the same rule
      # `Template#editable_by?` applies.
      def creatable?
        return true if actor.admin?
        return false if project.nil?

        actor.allowed_to?(:add_reporter_dashboards_templates, project)
      end

      def create(entry, name, action:, reason: nil)
        unless creatable?
          return Outcome.new(name: entry['name'], applied_name: name, action: :skip,
                             reason: 'you may not add report templates to this project')
        end

        template = template_class.new(assignable(entry))
        template.name = name
        # NEVER FROM THE FILE, ANY OF THE THREE. `project_id` decides which project's
        # permissions are checked, `author_id` decides who `edit_own_…` lets through, and
        # `visibility` decides who else can see it. T-23's `#import` makes exactly these
        # three decisions for exactly these reasons: a bundle is a file somebody was
        # handed, and letting the sender choose any of them would let them decide who in
        # the receiving organisation can read — or edit — what they sent.
        template.project_id = project&.id
        template.author_id = actor.id
        template.visibility = template_class::VISIBILITY_PRIVATE

        template.save!

        Outcome.new(name: entry['name'], applied_name: name, action: action,
                    reason: reason, template_id: template.id)
      end

      def overwrite(existing, entry)
        # THE SNAPSHOT COMES FIRST, and the ORDER is the guarantee — T-24's `refresh_copy`
        # took the same decision in the same words. If writing the version history raises,
        # the content has not been replaced yet; and because both statements are inside
        # this entry's savepoint, a failure after it leaves neither.
        existing.versions.create!(content: existing.content, author_id: actor.id)

        # THE THREE FIELDS THE FILE MAY NOT SET ARE NOT IN THIS ASSIGNMENT, and here that
        # matters more than on the create path. Overwriting somebody else's template must
        # not change who owns it or who can see it: a bundle that could flip an existing
        # private template to public would be a disclosure primitive, and one that could
        # reassign `author_id` would take the template away from its author.
        # `reject` AND NOT `Hash#except`, which is Ruby 3.0 core. This plugin declares a 2.7
        # floor and `.codex/check_ruby_floor.sh` is a CI job — it caught this line, exactly
        # as it caught an endless method definition in T-31. ActiveSupport would supply
        # `except` at runtime here, which is precisely what makes the mistake invisible
        # without the gate.
        existing.attributes = assignable(entry).reject { |field, _| field == 'name' }
        existing.save!

        Outcome.new(name: entry['name'], applied_name: existing.name, action: :update,
                    template_id: existing.id)
      end

      # §7 RULE 5, ON THE IMPORT SIDE. The export side has read these two columns through
      # the model's degrading readers since T-23 (`Exchange::DEGRADING_READERS`) and the
      # import side did not — so a bundle exported by a current install and imported into
      # one whose schema is a minor behind raised `ActiveModel::UnknownAttributeError`,
      # which is a stack trace where rule 5 asks for a degraded feature.
      #
      # Dropping a field is VISIBLE (INV-4) rather than silent, because the template that
      # arrives is genuinely not the template that was sent.
      def assignable(entry)
        kept, dropped = Exchange.assignable(entry, template_class.column_names)

        unless dropped.empty?
          warn_line("[exchange] this installation's schema has no #{dropped.join(', ')} " \
                    "column, so #{entry['name'].inspect} was imported without it")
        end

        kept
      end

      def free_name(name, state)
        2.upto(MAX_RENAME_ATTEMPTS + 1) do |suffix|
          candidate = "#{name} (#{suffix})"
          # THE LENGTH BOUND IS THE MODEL'S. A name at the 255-character limit plus " (2)"
          # is 259, which validates nowhere and raises `ValueTooLong` on MySQL — so the
          # suffix replaces the tail rather than being appended past it. The same
          # truncate-then-decorate order `download_filename` uses, for the same reason.
          candidate = "#{name[0, template_class::MAX_STRING - suffix.to_s.length - 3]} (#{suffix})" \
            if candidate.length > template_class::MAX_STRING
          # BOTH SETS: what was here before, and what this run has already spoken for.
          # Without the second, two identically-named entries in one bundle would both be
          # renamed to `Name (2)` — and `plan` and `apply` would disagree about it, which
          # is the defect the snapshot exists to remove.
          taken = state[:preexisting].key?(candidate) || state[:claimed].key?(candidate)
          return candidate unless taken
        end

        nil
      end

      def lint_counts(entry)
        analysis = RedmineReporterDashboards::TemplateLinter.analyse(entry['content'].to_s)
        { errors: analysis.errors.length, warnings: analysis.warnings.length }
      rescue StandardError => e
        # A LINTER FAILURE IS NOT AN IMPORT FAILURE. The lint is advice printed beside the
        # decision; if it raises on some pathological body, the operator should still be
        # told what the import will do. HANDOVER §1: anything a rescue body calls is part
        # of the rescue's correctness, so this one only assigns and logs.
        warn_line("[exchange] the template linter raised on #{entry['name'].inspect}: " \
                  "#{e.class}: #{e.message}")
        { errors: nil, warnings: nil }
      end

      # NON-THROWING, AND THAT IS THE WHOLE POINT OF IT BEING ONE METHOD.
      #
      # HANDOVER §1, twice in one task: *"AN OPTIONAL LOG LINE IS A RESCUE PATH"* and
      # *"anything a rescue body calls is part of the rescue's correctness, including
      # logging, including a second rescue's own logging. The fix is one non-throwing choke
      # point, not six `begin`s."*
      #
      # Both rescue bodies in this class call this method. `logger.warn` can raise —
      # `Errno::EPIPE` from a closed log pipe, `ENOSPC` from a full log volume — and a raise
      # from inside `apply_entry`'s rescue would leave `#apply` entirely, so the REST OF THE
      # BUNDLE WOULD NOT BE IMPORTED. That is FR-56's "one bad template does not abort the
      # bundle" violated by the code written to satisfy it, which is exactly what T-25's
      # runner shipped before an independent review measured it with a raising logger.
      def warn_line(line)
        logger.warn(line) if logger.respond_to?(:warn)
      rescue StandardError
        # A log line that cannot be written is not a reason to stop importing. There is
        # nowhere to report this to — the reporting channel is the thing that failed.
        nil
      end

      # RESOLVED AT CALL TIME, NOT AT LOAD TIME, and that is not a style choice.
      # `Template` is an ActiveRecord model under `app/models`, so it is AUTOLOADED — and
      # a `Template = RedmineReporterDashboards::Template` in this class body would force
      # that autoload at `require` time. `TemplatesController` can write the short form
      # because a controller class is loaded lazily, long after boot; this file is
      # reachable from a rake task that requires it directly, and touching an autoloaded
      # constant from a file being required is how a plugin turns a missing require into a
      # boot failure that names the wrong thing.
      def template_class
        RedmineReporterDashboards::Template
      end
    end
  end
end
