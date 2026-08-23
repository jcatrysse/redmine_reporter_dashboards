# frozen_string_literal: true

module RedmineReporterDashboards
  # The permission model, as DATA rather than as a list of calls in `init.rb`.
  #
  # WHY DATA. `spec/permissions/permission_map_spec.rb` reads this table and asserts that
  # every registered action exists on the named controller, that the controller calls
  # `authorize`, that every permission is labelled in all nine locales, and that every
  # public controller action is either permission-mapped or listed in NON_PERMISSION_GUARDS
  # with the guard it really uses. A list of calls inside `Redmine::Plugin.register` cannot
  # be read without booting Redmine.
  #
  # It also makes the authoring rule enforcement instead of prose: `Entry#requires` DERIVES
  # `:member` from `authoring: true`, so a code-execution privilege cannot be offered to the
  # Anonymous or Non-member role by an edit that forgets — or un-offered by one.
  #
  # THIS PLUGIN GRANTS NOTHING. A plugin can declare a permission; it has no way to tick
  # one. But Redmine's own default-data loader gives the Manager role every setable
  # permission, ours included, on a brand-new install
  # (`lib/redmine/default_data/loader.rb`, identical on 5.1 through 7.0). That is why the
  # preflight page reports which of OUR roles hold an authoring permission, not only the
  # base plugin's: on a fresh install nobody necessarily chose it.
  #
  # WHAT IS DELIBERATELY NOT A PERMISSION, because an unused checkbox on the roles screen
  # costs an administrator attention every time they read it:
  #
  #   * exporting a document, as distinct from viewing one — Redmine does not separate
  #     "see the issue list" from "export it as CSV";
  #   * importing a bundle — import IS authoring, so it requires `add_…` AND `edit_…`;
  #   * reading or rolling back a template's version history — same permission as editing it;
  #   * revoking a share link — that belongs to the creator, the template's owner and admins,
  #     which is ownership, and a permission cannot express it;
  #   * sending to an external address — an installation-wide setting plus a domain
  #     allowlist, because it is a policy about the installation rather than a role;
  #   * a template with no project — Redmine has no role grant outside a project, so a
  #     global template is admin-only by construction.
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
    # * `settings_tab`   this permission's surface is reachable from the project SETTINGS
    #                    tab, so its registration additionally maps core's
    #                    `projects#settings`. See `SETTINGS_TAB_ACTIONS` for why this is a
    #                    BOOLEAN and not a second action hash
    Entry = Struct.new(:name, :project_module, :actions, :read, :requires,
                       :group, :authoring, :covers, :lands_in, :settings_tab,
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

      # What Redmine is actually handed, as distinct from `actions`, which stays this
      # plugin's own controllers only.
      #
      # WHY THE SPLIT. `spec/permissions/permission_map_spec.rb` asserts that every
      # controller in `actions` has a file here, that every action is public, and that
      # `authorize` runs for it. Those three assertions are the reason the permission map
      # cannot rot, and they can only read controllers this repository contains. Merging a
      # CORE action into `actions` would have made all three either fail or learn to skip
      # entries — and a check that learns to skip is a check that stops holding.
      # FROZEN, LIKE `actions` IS. `Entry#initialize` freezes the action hash and each of
      # its values, and `registration_dsl_spec.rb` asserts that of what `init.rb` actually
      # hands Redmine — which is this, not `actions`. `merge` returns a NEW and unfrozen
      # hash, so the first draft of this method quietly handed out a mutable action map and
      # that spec caught it. Built per call rather than memoised because the Entry is frozen
      # at construction; it runs once per permission at boot.
      def registered_actions
        return actions unless settings_tab

        (actions || {}).merge(SETTINGS_TAB_ACTIONS).freeze
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
    # THE ONE CORE ACTION THIS PLUGIN MAPS, and a BOOLEAN on the entry rather than a second
    # action hash, deliberately.
    #
    # Redmine has no registration API for a project settings TAB: `project_settings_tabs`
    # is a helper method and adding an entry means patching it. Core's own convention for
    # the permission that owns a tab is to map `projects#settings` as well — see
    # `manage_members` and `manage_versions` in `lib/redmine/preparation.rb` — because
    # `ProjectsController` has `before_action :authorize`, so a role holding only our
    # permission could otherwise see the tab in the list and get a 403 opening the page it
    # lives on.
    #
    # A generic `core_actions:` field would have been more flexible and is the wrong shape:
    # it would let a later edit map `projects#destroy` or `projects#update` and hand a
    # reader-level role the project form, with nothing in this file objecting. A boolean
    # that expands to exactly one action cannot be misused that way, and the flag's name
    # says what it is FOR rather than what it does.
    SETTINGS_TAB_ACTIONS = { projects: [:settings].freeze }.freeze

    TEMPLATES_CONTROLLER = :'reporter_dashboards/templates'
    SCHEDULES_CONTROLLER = :'reporter_dashboards/schedules'
    MAIL_CONTROLLER = :'reporter_dashboards/mail'
    # T-28. The MANAGEMENT surface, not the public one: `reporter_dashboards/shares` is the
    # token endpoint and is deliberately mapped to no permission at all (see
    # `NON_PERMISSION_GUARDS`), because "may whoever holds this token have these bytes" has
    # no person in it.
    SHARE_LINKS_CONTROLLER = :'reporter_dashboards/share_links'

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
        covers: 'Create, rename, reorder and delete the tabs of a project dashboard',
        settings_tab: true
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
                'the document one produces',
        settings_tab: true
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
                'without being able to change it',
        settings_tab: true
      ),
      # --- authoring: every one of these is a code-execution privilege (INV-9) ----------
      #
      # AND ONE OF THEM IS EXCLUDED FROM THE UPGRADE DIAGNOSTIC — read
      # `Permissions::AuthoringAudit::NOT_AUTHORING_IN_PRACTICE` before adding a fifth.
      # `manage_public_reporter_dashboards_templates` carries this flag and cannot write a
      # template body on its own (its own entry below says why), so the diagnostic that
      # lists "who can run server-side code" would have warned about people who cannot —
      # curator decision #4, 2026-08-13. The flag itself is unchanged and still derives
      # `require: :member`; only the AUDIT is narrower. A permission added here is included
      # by default, because that exclusion is a subtraction from this list rather than a
      # second list — which is the property to preserve if you change either.
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
      # --- PROMOTED BY T-32 ------------------------------------------------------------
      #
      # `require: :loggedin` AND NOT `:member`, which §4.1 states and which is the whole
      # difference between this row and its two neighbours. A logged-in non-member can
      # legitimately mail themselves a report they can already read — that is the point of
      # the weaker requirement — and Redmine still refuses to OFFER it to the **Anonymous**
      # role, because `Role#setable_permissions` subtracts `loggedin_only_permissions` for
      # Anonymous. An anonymous visitor able to make this installation send mail is a
      # spam relay, so the requirement is load-bearing rather than descriptive, and
      # `permission_map_spec.rb` asserts the value rather than trusting it.
      #
      # `#index` IS MAPPED TOO, and leaving it out would repeat the defect
      # `manage_…_schedules` had: a permission that can do a thing but cannot look at what
      # it did is broken rather than milder. The audit list is also the only surface that
      # answers FR-61's "visible to admins" — the controller narrows a non-admin to their
      # own rows, which is a record-level decision no permission can express.
      #
      # WHAT MAPPING IT DOES NOT DO is make it sufficient. `authorize` passes on any mapped
      # permission, so `MailController` additionally requires
      # `view_reporter_dashboards_reports` on every action: mailing a report is a way of
      # reading it, and a holder of this permission alone must not be able to read one.
      Entry.new(
        name: :mail_reporter_dashboards_reports,
        project_module: REPORTS_MODULE,
        actions: { MAIL_CONTROLLER => [:index, :new, :create] },
        read: false,
        requires: :loggedin,
        group: :reports_distribute,
        # NOT `authoring: true`. Mailing a report runs a template that somebody else
        # wrote and this actor was already permitted to open; it creates no code and
        # writes none. The flag would additionally derive `require: :member`, which is
        # precisely the value §4.1 says this row must not have.
        authoring: false,
        covers: 'Send a report by e-mail on demand, to Redmine users',
        settings_tab: true
      ),
      # T-28 PROMOTES BOTH, and they map to the SAME action set on purpose. Redmine cannot
      # express "this one action additionally needs a second permission", so `#create` is
      # mapped to both and the controller carries the real rule: `share_…` is what lets you
      # reach the form at all, and `publish_…` is checked separately, per request, only when
      # the form asks for a PUBLIC link. That is the same shape `TemplatesController` uses
      # for `manage_public_…` and the same reason — a conjunction the permission model has
      # no word for.
      #
      # `#index` and `#revoke`/`#revoke_all` are mapped here too, but the controller does
      # NOT let `share_…` revoke somebody else's link: revocation is OWNERSHIP (FR-53), and
      # a test asserts a third party holding every grantable permission still cannot.
      Entry.new(
        name: :share_reporter_dashboards_reports,
        project_module: REPORTS_MODULE,
        actions: {
          SHARE_LINKS_CONTROLLER => [:index, :new, :create, :revoke, :revoke_all]
        },
        read: false,
        requires: :member,
        group: :reports_distribute,
        authoring: false,
        covers: 'Create a share link: an expiring, revocable URL that serves a snapshot ' \
                'to whoever holds it'
      ),
      Entry.new(
        name: :publish_reporter_dashboards_reports,
        project_module: REPORTS_MODULE,
        # THE SAME TWO ACTIONS, because Redmine's map answers "may this actor reach this
        # action" and the public/private distinction is a property of the REQUEST BODY
        # rather than of the route. Mapping `publish_…` to a route of its own would have
        # meant a second create endpoint whose only difference was a boolean — two ways to
        # do one thing, and the one without a caller is the one that drifts.
        actions: { SHARE_LINKS_CONTROLLER => [:new, :create] },
        read: false,
        requires: :member,
        group: :reports_distribute,
        authoring: false,
        # "Off by default PER TEMPLATE" is what FR-62 and §7b.6 say, and it is NOT what
        # this is — there is no per-template flag anywhere. It is off per ROLE (nothing
        # grants this) and decided per LINK. Found by an independent review; the
        # discrepancy is §Findings **S-28**s MINOR and is the curators to resolve in one
        # direction or the other. The line below describes the CODE, because a `covers:`
        # string is read by an administrator on the roles screen.
        covers: 'Turn a share link into a PUBLIC link, reachable without a Redmine ' \
                'account. Granted to no role by default; chosen per link (FR-62)'
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
      },
      'reporter_dashboards/shares#show' => {
        guard: :find_link,
        why: 'T-28. A share link is the one endpoint in this plugin where the question ' \
             'is not "may this person do this" but "may whoever holds this token have ' \
             'these bytes" — and there is no person in that question. The bytes were ' \
             'frozen by a render that ran as a NAMED identity inside that identity\'s own ' \
             'visible scope (FR-52), so serving them makes no query, resolves no ' \
             'permission and reads no issue: there is no visibility decision here to get ' \
             'wrong. A plugin permission would additionally make the capability useless, ' \
             'since FR-62\'s public link is opened by somebody with no account to hold ' \
             'one. What guards it is the token itself: `find_link` resolves it by digest ' \
             'with a constant-time comparison and refuses on its own when nothing matches.'
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
          entries.map { |entry| [entry.name, entry.registered_actions, entry.registration_options] }
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
