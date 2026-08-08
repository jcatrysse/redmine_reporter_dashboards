# frozen_string_literal: true

module RedmineReporterDashboards
  # T-40 — the permission model, as DATA rather than as a list of calls in `init.rb`.
  #
  # --- WHY THIS FILE EXISTS, AND WHAT IT REPLACES ---
  #
  # `technical-spec.md` §4 used to answer INV-9 — *template authoring IS code execution* —
  # with a plugin setting, `template_authoring: :admins_only | :project_managers`, and
  # `[OQ-F]` asked which of the two should be the default. **The curator rejected the whole
  # shape on 2026-08-06**: a plugin states who may do what the way Redmine already does,
  # as role permissions an administrator grants per project and per role, not as one global
  # switch with two positions.
  #
  # The rejection was right, and for a reason worth writing down rather than merely
  # obeying. `:project_managers` — the value the spec recommended for upgraded installs —
  # would have **widened a code-execution privilege on upgrade, silently, install-wide**,
  # to whatever every role the operator thinks of as a manager happens to be. That is the
  # failure this project keeps naming, pointed the other way. And `:admins_only` would have
  # made the feature unreachable for the very person it is for. A setting cannot say
  # *"this role, in this project"*; a permission is exactly the vocabulary that can.
  #
  # --- WHY DATA AND NOT THREE `permission` LINES ---
  #
  # Three reasons, all of them mechanical:
  #
  # 1. `spec/permissions/permission_map_spec.rb` can read it. It asserts every registered
  #    action **exists** on the named controller, that the controller actually calls
  #    `authorize`, that every registered permission is labelled in all nine locales, and
  #    that every public controller action is either permission-mapped or listed in
  #    NON_PERMISSION_GUARDS with the guard it really uses. A list of calls inside
  #    `Redmine::Plugin.register` cannot be read without booting Redmine, so those
  #    assertions would live in a suite that only runs in CI.
  # 2. The authoring rule becomes enforcement instead of prose: `Entry#requires` **derives**
  #    `:member` from `authoring: true` — it is not written on the entry at all — so a
  #    code-execution privilege cannot be offered to the Anonymous or Non-member role by an
  #    edit that forgets, and cannot be *un*-offered by one either.
  # 3. PLANNED entries make the *design* reviewable now while keeping the roles screen
  #    honest: a permission an administrator can tick and that guards nothing is a lie in
  #    the interface, so nothing here is registered until the task named in `lands_in`
  #    ships the controller it guards.
  #
  # --- HOW `[OQ-F]`'s REAL WORRY IS ANSWERED WITHOUT A SETTING ---
  #
  # `[OQ-F]` worried about two things and a default could only serve one of them:
  #
  # * *A fresh install must not hand out code execution.* **This plugin grants nothing** — a
  #   plugin can declare a permission, it has no way to tick one — so for every install that
  #   already has roles, authoring starts nowhere and only administrators (whose flag
  #   bypasses the check) can author.
  #
  #   **But "no role holds one until an administrator grants it" is NOT true in general, and
  #   the review of T-40 was right to refuse that sentence.** Redmine's own default-data
  #   loader does this, identically on 5.1, 6.0, 6.1 and 7.0
  #   (`lib/redmine/default_data/loader.rb:51`):
  #
  #       manager.permissions = manager.setable_permissions.collect {|p| p.name}
  #
  #   and `Role#setable_permissions` subtracts only `public_permissions` for a givable role.
  #   So on a **brand-new** install — where `Role.where(builtin: 0)` is empty, which is the
  #   loader's own precondition (`:31`) — loading the default configuration with this plugin
  #   already present grants the **Manager** role every setable permission of ours,
  #   `require: :member` included. Once T-23 registers the authoring four, that is literally
  #   `:project_managers`, arriving from core rather than from a setting.
  #
  #   That is not a reason to bring the setting back: the setting would have produced the
  #   same grant on **every** install rather than only on one ordering, and silently. It is a
  #   reason the diagnostic below must report **our** roles, not only the base plugin's — see
  #   T-27 — and a reason this file does not claim more than it can hold.
  # * *An upgraded install must not break silently.* It does not break silently, and not
  #   because of a default: the preflight page and `import:plan` **name every role that
  #   holds the base plugin's authoring permission and every role that holds ours**, so the
  #   administrator reads the situation instead of discovering it. Naming the roles is
  #   strictly better than defaulting to `:project_managers`, because the default would have
  #   closed the gap by *granting* code execution to roles nobody re-examined — and, per the
  #   paragraph above, it is also the only thing that can surface a Manager role seeded by
  #   core.
  #
  # --- WHAT IS DELIBERATELY *NOT* A PERMISSION ---
  #
  # Each of these was considered and rejected, because an unused checkbox on the roles
  # screen costs an administrator attention every time they read it:
  #
  # * **Exporting a document** as distinct from viewing one. Redmine does not separate
  #   "see the issue list" from "export it as CSV", and the cost of a render is bounded by
  #   FR-32's caps and the engine's own limits, not by a role grant.
  # * **Importing a bundle.** Import *is* authoring — it creates templates whose content is
  #   code — so it requires `add_…` **and** `edit_…` rather than a weaker permission of its
  #   own. Exporting a bundle requires whichever permission lets you read the content in
  #   the editor, because the bundle *is* the content.
  # * **Reading a template's version history**, or rolling back to a version: the same
  #   permission that lets you edit that template (FR-21's audit trail is for the same
  #   person who can change it).
  # * **Revoking a share link.** FR-53 puts that with the link's creator, the template's
  #   owner and admins — ownership, which a permission cannot express.
  # * **Sending to an external e-mail address.** FR-61 makes that an installation-wide
  #   admin setting plus a domain allowlist. It is a policy about the installation, not a
  #   capability of a role in a project.
  # * **A template with no project** (`project_id IS NULL`). Redmine has no role grant
  #   outside a project, so a global template is admin-only, by construction.
  module Permissions
    # `requires` and not `require`: a Struct member called `require` would define a
    # `#require` reader on every entry, shadowing `Kernel#require` for that object.
    #
    # * `name`           the Redmine permission name — a public contract (§1)
    # * `project_module` the `project_module` it is declared inside
    # * `actions`        controller => actions, for REGISTERED entries only (see `covers`)
    # * `read`           Redmine's `read: true` — permitted in a CLOSED project
    # * `requires`       Redmine's `require:` — `nil` or `:loggedin`. **Never written for an
    #                    authoring entry: the reader below derives `:member` from `authoring`**
    # * `group`          for documentation ordering only
    # * `authoring`      INV-9: holding this is a code-execution privilege
    # * `covers`         one line, in the vocabulary an administrator reads
    # * `lands_in`       nil once registered; otherwise the task that registers it
    Entry = Struct.new(:name, :project_module, :actions, :read, :requires,
                       :group, :authoring, :covers, :lands_in,
                       keyword_init: true) do
      # Frozen at construction, all the way down. `Array#freeze` is shallow, so freezing
      # REGISTERED alone left the entries and the action Hashes inside them mutable while
      # every comment in this file called the model frozen data. Redmine copies the action
      # hash rather than keeping it (`AccessControl::Permission#initialize`), so nothing was
      # broken — but "described as frozen and not frozen" is how a shared-mutable-state bug
      # gets written later by somebody who read the comment.
      def initialize(*)
        super
        actions&.each_value(&:freeze)
        actions&.freeze
        freeze
      end

      def registered?
        lands_in.nil?
      end

      # DERIVED, not typed. `require: :member` is how Redmine refuses to OFFER a permission
      # to the Anonymous and Non-member roles (`Role#setable_permissions` subtracts
      # `members_only_permissions` for Non-member and `loggedin_only_permissions` — a
      # superset — for Anonymous), and an authoring permission executes code, so the two
      # facts are one fact.
      #
      # It was hand-typed on each authoring entry until the review of T-40 pointed out that
      # three documents said "derived" while the code said "typed, and asserted to agree".
      # A consistency check between two hand-written fields is not the same control: it
      # cannot stop both being written wrong together. Reading one from the other can.
      def requires
        authoring ? :member : self[:requires]
      end

      # The third argument of Redmine's `permission name, actions, options`. Built here so
      # it is a tested method rather than four lines inside `Redmine::Plugin.register`,
      # where nothing but a running Redmine could look at it.
      #
      # `read: false` and `require: nil` would in fact be equivalent to omitting them —
      # `Permission#initialize` reads `options[:read] || false` and `options[:require]`,
      # identically on 5.1 through 7.0 — so this is not a correctness requirement. It omits
      # them because the three calls it replaced omitted them, and "identical registration"
      # is easier to assert than "equivalent registration".
      def registration_options
        options = {}
        options[:read] = true if read
        options[:require] = requires if requires
        options
      end
    end

    # Ordering only. The roles screen renders permissions in declaration order **within a
    # module**, and sorts the modules themselves alphabetically
    # (`app/views/roles/_form.html.erb`: `perms_by_module.keys.sort`), so no declaration order
    # here can put the reports fieldset below the dashboards one. These groups are the order
    # §4.1's table is written in.
    GROUPS = %i[dashboards reports_consume reports_author reports_schedule
                reports_distribute].freeze

    # The project modules. `:reporter_project_dashboards` pre-exists this work and its name
    # cannot change — an installation has it enabled per project, and a rename silently
    # disables the dashboard everywhere it was on. Reports get a **second** module rather
    # than joining the first, because "we want dashboards, not the reporting surface" is a
    # real answer and a module is how Redmine asks the question.
    DASHBOARDS_MODULE = :reporter_project_dashboards
    REPORTS_MODULE = :reporter_dashboards_reports

    # The one controller T-23 adds, named ONCE. Redmine builds its action strings as
    # `"#{controller}/#{action}"` and compares them against `params[:controller]`, which
    # for a controller in a subdirectory is the namespaced path — so the key has to carry
    # the slash. Written as a constant because a typo in it produces a permission that
    # guards nothing and looks perfectly correct on the roles screen.
    TEMPLATES_CONTROLLER = :'reporter_dashboards/templates'
    SCHEDULES_CONTROLLER = :'reporter_dashboards/schedules'

    # --- ONE ORDERED LIST, AND WHY IT REPLACED TWO -----------------------------------
    #
    # This was `REGISTERED` and `PLANNED` as two literal arrays with
    # `ALL = REGISTERED + PLANNED`. That shape has a defect that only shows up at the
    # moment it matters: promoting an entry MOVES it from the second array to the first,
    # so `ALL`'s order changes — and `ALL`'s order is asserted equal to §4.1's table.
    # T-23 promotes five of the eight authoring/consuming rows but not
    # `view_reporter_dashboards_schedules`, which sits between them in the table, so the
    # concatenation would have reordered a document to suit an implementation detail.
    #
    # So the declaration order IS §4.1's table order, once, and the two constants are
    # derived from it. Promotion now changes exactly the four things §4.1 says it
    # changes — `actions`, `lands_in`, and the labels — and moves nothing.
    ENTRIES = [
      # --- the three that pre-date T-40, live since v0.5.0 ------------------------------
      #
      # UNCHANGED, including the absence of `require: :member` on the two `manage_` ones.
      # Neither is a code-execution privilege, so the rule that derives `:member` for
      # authoring does not reach them — and adding it by hand would do something worse
      # than warn. **The mechanism, stated precisely, because the first version of this
      # comment got it wrong:** nothing is revoked. `Role#permissions=` writes whatever it
      # is given, with no filtering and no validation, and `Role#allowed_to?` keeps
      # honouring an existing grant. What changes is that `app/views/roles/_form.html.erb`
      # renders only `@role.setable_permissions`, so the grant becomes **invisible on the
      # roles screen while still active**, and is then dropped the next time anybody saves
      # that role for an unrelated reason. An active-but-unmanageable permission that
      # disappears later without a trace is a worse failure than either revoking it or
      # leaving it, which is why these two are left exactly as they are. Deliberate, not
      # overlooked.
      #
      # The cost of leaving them, said out loud: a permission with neither `require:` nor
      # `public:` **is** offerable to the Anonymous and Non-member roles, so an
      # administrator can grant "Manage project dashboard widgets" to Anonymous today.
      # Pre-existing behaviour and not a new decision; written here so the next person
      # weighs it rather than rediscovers it.
      Entry.new(
        name: :view_reporter_project_page,
        project_module: DASHBOARDS_MODULE,
        actions: { reporter_project_pages: [:show, :report_pdf] },
        read: true,
        requires: nil,
        group: :dashboards,
        authoring: false,
        covers: 'Open a project dashboard, and export it as a PDF'
      ),
      Entry.new(
        name: :manage_reporter_project_page,
        project_module: DASHBOARDS_MODULE,
        actions: {
          reporter_project_pages: [:update_page, :add_block, :remove_block, :move_block]
        },
        read: false,
        requires: nil,
        group: :dashboards,
        authoring: false,
        covers: 'Add, remove, move and configure the widgets on a project dashboard'
      ),
      Entry.new(
        name: :manage_reporter_project_tabs,
        project_module: DASHBOARDS_MODULE,
        actions: { reporter_project_tabs: [:create, :update, :destroy, :order] },
        read: false,
        requires: nil,
        group: :dashboards,
        authoring: false,
        covers: 'Create, rename, reorder and delete the tabs of a project dashboard'
      ),
      # --- consuming a report ----------------------------------------------------------
      #
      # PROMOTED BY T-23. `#document` is the PDF, and it is deliberately the same grant as
      # `#show`: §4.1 rejected a separate export permission because Redmine does not
      # separate "see the issue list" from "export it as CSV", and the cost of a render is
      # bounded by FR-32's caps and `Render::BatchGuard`, not by a role grant.
      Entry.new(
        name: :view_reporter_dashboards_reports,
        project_module: REPORTS_MODULE,
        actions: { TEMPLATES_CONTROLLER => [:index, :show, :document] },
        read: true,
        requires: nil,
        group: :reports_consume,
        authoring: false,
        covers: 'See the report templates available in a project, and open or download ' \
                'the document one produces'
      ),
      Entry.new(
        name: :view_reporter_dashboards_schedules,
        project_module: REPORTS_MODULE,
        # READ-ONLY, AND THE SPLIT IS THE POINT (§4.1, T-25's Accept:). "an operator can
        # answer *did it run* without being able to change who receives it." So `#index`
        # and `#show` and nothing else: not `#test_send`, which sends mail, and not
        # `#destroy`, which throws away the run history that answers the question.
        actions: { SCHEDULES_CONTROLLER => [:index, :show] },
        read: true,
        requires: nil,
        group: :reports_consume,
        authoring: false,
        covers: 'See a schedule and its run state — last run, status, duration, error — ' \
                'without being able to change it'
      ),
      # --- authoring: every one of these is a code-execution privilege (INV-9) ----------
      #
      # `#preview` is mapped by all three of the authoring template permissions and by
      # nothing else, because a preview RUNS the template — it is the editor's own
      # execution of code the author is writing, and giving it to a consumer would hand
      # `view_…_reports` a code-execution path through the request body.
      #
      # `#import` is mapped by `add_…` and `edit_…` and the controller then requires
      # BOTH (§4.1: "Import **is** authoring… a weaker permission of its own would be a
      # way around the authoring one"). Redmine's `authorize` passes on *any* mapped
      # permission, so the conjunction cannot be expressed in this table — it is a
      # `before_action` in the controller and a test that holds one without the other.
      Entry.new(
        name: :add_reporter_dashboards_templates,
        project_module: REPORTS_MODULE,
        actions: { TEMPLATES_CONTROLLER => [:new, :create, :preview, :import] },
        read: false,
        group: :reports_author,
        authoring: true,
        covers: 'Create a report template. A template is executed server-side, so this ' \
                'is a code-execution privilege',
        lands_in: nil
      ),
      Entry.new(
        name: :edit_own_reporter_dashboards_templates,
        project_module: REPORTS_MODULE,
        actions: {
          TEMPLATES_CONTROLLER => [:edit, :update, :destroy, :preview, :export]
        },
        read: false,
        group: :reports_author,
        authoring: true,
        covers: 'Edit and delete the report templates you authored'
      ),
      Entry.new(
        name: :edit_reporter_dashboards_templates,
        project_module: REPORTS_MODULE,
        actions: {
          TEMPLATES_CONTROLLER => [:edit, :update, :destroy, :preview, :export, :import]
        },
        read: false,
        group: :reports_author,
        authoring: true,
        covers: "Edit and delete any report template in the project, including other " \
                "people's"
      ),
      # THE SAME ACTION SET REDMINE GIVES `manage_public_queries`
      # (`lib/redmine/preparation.rb:49`) minus `destroy`, which makes no visibility
      # decision. Mapping it here is what lets `authorize` pass — and on its own that
      # would be a hole, because Redmine's `authorize` is satisfied by ANY mapped
      # permission, so a role holding only this one could reach `#create`. It cannot:
      # the controller additionally requires `add_…` for new/create and an edit
      # permission for edit/update, and a functional test holds this permission ALONE
      # and asserts 403 on both. Core has the same shape and does not close it; here the
      # actions being reached are a code-execution privilege, so it is closed.
      Entry.new(
        name: :manage_public_reporter_dashboards_templates,
        project_module: REPORTS_MODULE,
        actions: { TEMPLATES_CONTROLLER => [:new, :create, :edit, :update] },
        read: false,
        group: :reports_author,
        authoring: true,
        covers: 'Give a report template a visibility wider than its author — the same ' \
                "decision Redmine's manage_public_queries governs for saved queries"
      ),
      # --- scheduling ------------------------------------------------------------------
      Entry.new(
        name: :manage_reporter_dashboards_schedules,
        project_module: REPORTS_MODULE,
        # `#test_send` IS IN THIS SET AND NOT IN THE VIEWING ONE, because it puts mail on
        # the wire. It is the only action in the plugin that reaches outside Redmine
        # without a schedule firing, and a read permission that could send e-mail would
        # not be a read permission.
        #
        # NOT `authoring: true` even so. A schedule chooses a template, it does not write
        # one, so this is not the code-execution class INV-9 governs — which is exactly why
        # `manage_…_schedules` alone cannot create a template to point at.
        # `#index` AND `#show` ARE HERE TOO, and leaving them out made this permission
        # unusable alone: a role holding it created a schedule and was answered 403 on the
        # redirect to it, with no menu entry either. Redmine's own `manage_public_queries`
        # does not stand alone in that sense; a permission that can change a thing it cannot
        # look at is not a milder permission, it is a broken one.
        #
        # The SPLIT is unaffected, which is what §4.1 is about: `view_…` still grants
        # read-only, and nothing about holding it lets you change who receives a report.
        actions: { SCHEDULES_CONTROLLER => [:index, :show, :new, :create, :edit, :update,
                                            :destroy, :test_send] },
        read: false,
        requires: :member,
        group: :reports_schedule,
        authoring: false,
        covers: 'See, create, edit, disable and delete schedules, choose their ' \
                'recipients, and send a test run'
      ),
      # --- THE CURATOR'S ANSWER TO S-10, 2026-08-08 -------------------------------------
      #
      # `render_as_user_id` decides WHOSE VISIBILITY THE SQL RUNS UNDER, and T-25's first UI
      # let any schedule manager set it to anybody: an independent review posted an
      # administrator's id, pressed "Send a test", and received an admin-visibility report
      # containing a private issue they could not see. The hole was closed narrowly — you may
      # render as yourself — and the question of who *should* be able to do more was put to
      # the curator rather than answered here (§Findings S-10).
      #
      # **The answer is a permission**, which is how Redmine states every other "who may do
      # what, in which project" question. It is granted per role per project, so holding it
      # in one project says nothing about another.
      #
      # --- WHAT THIS PERMISSION HONESTLY IS, AND WHY THE LABEL SAYS SO ---
      #
      # It does not relocate the escalation, it AUTHORISES it. Anyone holding this can bind
      # a schedule to a colleague with wider visibility and read the result, which is the
      # same capability the reviewer demonstrated — the difference is that an administrator
      # now decides who has it, deliberately, on the roles screen.
      #
      # That only works if the checkbox tells the truth, because the roles screen is the one
      # place an administrator reads about it. So the label is *"Render reports as another
      # user — grants access to everything that user can see"* in all nine locales, and not
      # the milder "choose a render identity" that would describe the mechanism while hiding
      # the consequence.
      #
      # --- IT MAPS NO ACTION, AND THAT IS CORRECT ---
      #
      # Every other entry in this file opens a door. This one widens a FIELD: it is asked by
      # `SchedulesController#apply_render_identity` and by `#test_send`, both of which are
      # already behind `manage_…_schedules`. Mapping it to those actions would make it
      # *sufficient* for `authorize` on them, so a role holding only this could reach
      # `#create` and be stopped by nothing but the second guard. `{}` says what is true:
      # holding this alone lets you do nothing at all.
      Entry.new(
        name: :render_reporter_dashboards_reports_as_others,
        project_module: REPORTS_MODULE,
        actions: {},
        read: false,
        requires: :member,
        group: :reports_schedule,
        # NOT `authoring: true`. That flag means code execution (INV-9) and derives
        # `require: :member` from it; this is a visibility privilege, so the requirement is
        # written by hand and the flag stays false rather than being borrowed for its
        # side effect.
        authoring: false,
        covers: 'Bind a schedule to another user\'s render identity, and test-send one. ' \
                'Grants access to everything that user can see'
      ),
      # --- distribution: the two paths that reach outside Redmine's permission model ----
      Entry.new(
        name: :mail_reporter_dashboards_reports,
        project_module: REPORTS_MODULE,
        actions: nil,
        read: false,
        requires: :loggedin,
        group: :reports_distribute,
        authoring: false,
        covers: 'Send a report by e-mail on demand, to Redmine users',
        lands_in: 'T-32'
      ),
      Entry.new(
        name: :share_reporter_dashboards_reports,
        project_module: REPORTS_MODULE,
        actions: nil,
        read: false,
        requires: :member,
        group: :reports_distribute,
        authoring: false,
        covers: 'Create a share link: an expiring, revocable URL that serves a snapshot ' \
                'to whoever holds it',
        lands_in: 'T-28'
      ),
      Entry.new(
        name: :publish_reporter_dashboards_reports,
        project_module: REPORTS_MODULE,
        actions: nil,
        read: false,
        requires: :member,
        group: :reports_distribute,
        authoring: false,
        covers: 'Turn a share link into a PUBLIC link, reachable without a Redmine ' \
                'account. Off by default per template (FR-62)',
        lands_in: 'T-28'
      )
    ].freeze
    # REGISTERED and PLANNED are DERIVED from ENTRIES, in ENTRIES' order, so that
    # promoting an entry is a two-field edit inside the list above and never a move
    # between two lists. `registered?` is `lands_in.nil?`, which is the same question
    # both constants used to answer by which array they were written in.
    #
    # Frozen, and each is a fresh Array rather than a filtered view: `select` returns a
    # new object every call, so a caller that mutated the result would otherwise be
    # mutating nothing and thinking it had.
    REGISTERED = ENTRIES.select(&:registered?).freeze
    PLANNED = ENTRIES.reject(&:registered?).freeze

    # §4.1's table order, which is ENTRIES' order. It was `REGISTERED + PLANNED`, and
    # that is exactly the concatenation the comment on ENTRIES explains T-23 could not
    # keep.
    ALL = ENTRIES

    # Actions that are guarded, and deliberately not by a permission of this plugin's.
    # Both are recorded with the guard they REALLY use, so the parity spec can check the
    # claim against the controller rather than take it on trust — an allowlist entry that
    # nobody verifies is how an unguarded action gets written down as a decision.
    NON_PERMISSION_GUARDS = {
      'reporter_preflight#show' => {
        guard: :require_admin,
        why: 'An installation-wide diagnostic that starts a browser and renders a ' \
             'document. It belongs to whoever administers the installation, and Redmine ' \
             'has no role grant at installation scope.'
      },
      'reporter_preflight#run' => {
        guard: :require_admin,
        why: 'Same surface as #show, and it spawns the engine, which is why it is a POST.'
      },
      'sql_stats#monthly_flow' => {
        guard: :require_login,
        why: 'A JSON endpoint over CORE data, not over anything this plugin owns, so the ' \
             'core permission is the right one: it additionally checks ' \
             ':view_issues on the project and aggregates over Issue.visible. A plugin ' \
             'permission here would be a second, weaker answer to a question core ' \
             'already answers (INV-1).'
      }
    }.freeze

    class << self
      def registered_names
        REGISTERED.map(&:name)
      end

      def planned_names
        PLANNED.map(&:name)
      end

      def authoring_names
        ALL.select(&:authoring).map(&:name)
      end

      def find(name)
        ALL.find { |entry| entry.name == name.to_sym }
      end

      # The registrations `init.rb` performs, grouped the way it declares them:
      #
      #   { project_module => [[name, actions, options], ...] }
      #
      # The option Hash is built HERE and not in `init.rb` so that it can be asserted
      # without booting Redmine. `spec/permissions/permission_map_spec.rb` compares the
      # result against the three literal `permission` calls this replaced, which is the
      # only way to know that turning them into a loop changed nothing — Redmine's roles
      # screen would not have told anybody until an administrator noticed a missing row.
      #
      # Ordering is REGISTERED's, and within a module it is load-bearing: the roles screen
      # renders a module's permissions in declaration order. `group_by` would silently
      # coalesce an interleaved `[D, R, D]` array into two blocks and move the third entry,
      # so the spec asserts each module occupies a single contiguous run of REGISTERED.
      def registrations_by_module
        REGISTERED.group_by(&:project_module).transform_values do |entries|
          entries.map { |entry| [entry.name, entry.actions, entry.registration_options] }
        end
      end

      # Which of OUR registered permission names another plugin has also registered.
      #
      # This is not hypothetical. `technical-spec.md` §7's whole A/B argument is that this
      # plugin and the base plugin can be installed **at the same time**, and Redmine's
      # `AccessControl` keeps permissions in a flat array with no uniqueness check: two
      # plugins registering one name produce two entries, two identical rows on the roles
      # screen, and an action map that is the union of both. Every name this plugin adds is
      # therefore prefixed to make the clash implausible — and the clash is checked at
      # boot anyway, because "implausible" is not a mechanism.
      #
      # Pure on purpose: the caller passes the names, so this is testable without Redmine.
      def collisions(all_permission_names)
        mine = registered_names
        Array(all_permission_names)
          .tally
          .select { |name, count| count > 1 && mine.include?(name) }
          .keys
          .sort
      end

      # The log line for a collision, or `nil` when there is none.
      #
      # Split out from the boot hook so the MESSAGE is testable without Redmine. The review
      # of T-40 found the hook had no test at all — the one new thing in the change that runs
      # inside `after_plugins_loaded` — and the reason was that reaching it meant booting
      # Redmine. Now only four lines of wiring need that.
      #
      # `Array()` above means a registry that answers `nil` — `AccessControl.permissions`
      # returns a bare `@permissions`, which is nil until something has registered — is
      # "no collisions" rather than a `NoMethodError` inside a boot hook.
      def collision_message(all_permission_names)
        clashes = collisions(all_permission_names)
        return nil if clashes.empty?

        "[reporter_dashboards] PERMISSION NAME COLLISION: #{clashes.join(', ')} — another " \
          'plugin registers the same permission name(s). The roles screen will show each ' \
          'one twice and authorization will use the union of both action maps. There is no ' \
          'setting that fixes this: the two plugins have to agree, so please report it with ' \
          'the list of installed plugins.'
      end
    end
  end
end
