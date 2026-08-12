# frozen_string_literal: true

module RedmineReporterDashboards
  # T-26a — the OWNED report widget: this plugin's own templates on the dashboard and on
  # my-page, so the base plugin can be uninstalled (FR-01).
  #
  # --- WHAT THIS REPLACES, AND WHY IT IS ASSEMBLY RATHER THAN NEW MACHINERY ---
  #
  # Both report widgets used to resolve a base-plugin class
  # (`IssueListReportTemplate.in_project_and_global(project)`) and then render a partial
  # that iframed the base plugin's own `report_content_report_template_path`. The queries
  # were already core Redmine, so that lookup and that route were the ONLY dependencies.
  #
  # Everything the owned path needs already existed and was already used by the template
  # editor's preview:
  #
  #   * `Reporting::ReportScope.build` resolves scope AND query from a `query_id`
  #   * `Reporting::ReportRun#call(pdf: false)` renders as the ACTOR and returns sections
  #   * `Liquid::ExecutionPolicy` already declared the `:widget` output class — "Small,
  #     many per page, and rendered while somebody waits" — and `ReportRun` already
  #     accepted `output_class:`. **Nothing in production had ever passed `:widget`.** The
  #     limits were built for this and left unused; this is the caller they were waiting
  #     for, which is also why no new limit had to be invented here.
  #   * `ReportFrame` builds the opaque-origin sandbox
  #
  # --- VISIBILITY IS TIGHTER THAN WHAT IT REPLACES, NOT LOOSER ---
  #
  # `Template.visible(actor)` is the entry point, so a widget cannot render a template its
  # viewer may not see. The base plugin's `in_project_and_global` enforced no visibility at
  # all — reports were treated as non-private — so this closes a gap rather than porting
  # one. The `project_id: [nil, project.id]` bound is kept from the old behaviour for the
  # reason its comment gave: a widget must not render what its own settings form refuses to
  # offer, or a project administrator sees a report they cannot change.
  #
  # An ACTOR IS REQUIRED and is never read ambiently from `User.current` here (INV-1). The
  # caller passes it, because a widget renders for whoever is looking at the page and a
  # future scheduled or shared surface must not inherit a different answer by accident.
  module WidgetReport
    # `source` values, keyed by the block that offers them. The block names are a public
    # contract — they are stored in existing dashboards — so they stay as they were even
    # though the templates behind them are now ours.
    SOURCE_BY_BLOCK = {
      'report_by_issues' => 'issues',
      'report_by_spent_time' => 'time_entries'
    }.freeze

    # A WIDGET IS ONE BOX, SO IT RENDERS ONE DOCUMENT — which makes `per_record` templates
    # unofferable here rather than bounded here.
    #
    # A `per_record` template produces one document PER ROW. On a dashboard that is either
    # N iframes in a box sized for one, or a silent bound — and a silent bound over the
    # scope is the worse of the two, because `{% sql_aggregate %}` reads the scope the
    # render context carries, so limiting it to "the first document's row" would make every
    # figure in the widget correct-looking and wrong. Bounding by DOCUMENTS instead (the
    # preview's answer) still shows one row's report where the reader asked for the
    # project's, with a truncation notice nobody has room for.
    #
    # So the bound is at the PICKER: a widget offers, and resolves, only `combined`
    # templates. An existing setting naming a per-record template stops resolving and falls
    # through to the settings form, which is the same answer FR-46 gives an id imported from
    # the base plugin. A per-record report is still available on the template's own page,
    # where a run has somewhere to put N documents — the widget does not link there, see
    # `_report.html.erb`.
    OUTPUT = 'combined'

    # What a caller needs to draw the widget, which is three things and not one.
    #
    # `outcome` is `ReportRun`'s, untouched — it already carries `sections`, the
    # degradations, the diagnostic and the counts, and a second vocabulary for those is how
    # two views come to disagree about what a failure looks like. The other two are what the
    # heading names: the template (its own name) and the saved query the scope came from,
    # which is `nil` when the widget names none and the report covers the whole project.
    Widget = Struct.new(:template, :query, :outcome, keyword_init: true)

    class << self
      # THE INSTANCE SUFFIX IS STRIPPED, and the first version of this method did not do
      # it. A dashboard may hold up to `MAX_BLOCK_OCCURS` copies of a widget, named
      # `report_by_issues__1` upward, and answering nil for those made every second copy
      # unrenderable. `ProjectPage.base_block_name` rather than a fifth local `sub`.
      def source_for(block)
        SOURCE_BY_BLOCK[ProjectPage.base_block_name(block)]
      end

      # The templates the settings form may offer, and the same scope `#template_for`
      # resolves against — one definition, so the picker and the lookup cannot disagree.
      #
      # `project: nil` MEANS "NO PROJECT CONTEXT", NOT "GLOBAL TEMPLATES ONLY" (T-26a
      # increment 3). The project bound exists for the project dashboard's reason — a widget
      # must not offer what its own settings form cannot change — and my-page has no project
      # for that argument to be about. There the honest bound is `Template.visible(actor)`
      # alone, which is already the permission model: `Project.allowed_to_condition` for
      # `view_reporter_dashboards_reports` (so the role AND the reports module, per project)
      # plus the template's own private/roles/public visibility.
      #
      # This is a deliberate change of meaning rather than a new argument, and it is safe
      # because nothing passed nil before: both dashboard partials always have a project.
      # The base plugin's answer to the same question was `IssueListReportTemplate.all` —
      # every template in the instance, to every user, with no visibility model to filter by
      # (verified against its source, 2026-08-12) — so this is a narrowing, not a port.
      def templates_for(project:, actor:, source:)
        scope = Template.visible(actor).where(source: source.to_s, output: OUTPUT)
        scope = scope.where(project_id: [nil, project.id]) if project

        scope.order(:name)
      end

      # The stored template, or nil.
      #
      # NIL IS A NORMAL ANSWER AND THE CALLER MUST TREAT IT AS ONE (FR-46). A dashboard
      # carried over from the base plugin holds ITS `report_template_id`, which names a row
      # in a different table — so it either fails to resolve, and the honest response is the
      # settings form that is already the partial's empty state, or it COLLIDES with one of
      # ours and renders an unrelated report.
      #
      # **THIS IS A BARE PRIMARY-KEY LOOKUP WITH NO PROVENANCE CHECK, DELIBERATELY, AND THE
      # TRANSLATION HAPPENS ONE LAYER UP.** Both tables' ids start at 1, so a carried-over
      # setting usually still resolves — to an unrelated report of ours. That is §Findings
      # **S-29**, and the answer is `Import::WidgetSettings`, which repoints every widget
      # during `import:run` using the `source_template_id` the importer already records.
      #
      # It is NOT answered here on purpose: this method is asked on every dashboard render
      # and cannot tell a stale id from a current one without a provenance rule, while the
      # importer knows exactly which sources it copied and gets to say so once, reportably,
      # and to leave a marker. A lookup that guessed would be making a migration decision on
      # every page view.
      #
      # An earlier version of this comment claimed the id "will not resolve here until the
      # importer has run", which was wrong twice: nothing consulted `source_template_id`,
      # and the importer did not rewrite `reporter_project_tabs.settings` at all. Found by
      # the independent review of T-26a. Nothing leaks either way: `Template.visible(actor)`
      # bounds whatever resolves.
      def template_for(project:, actor:, source:, template_id:)
        return nil if template_id.blank?

        templates_for(project: project, actor: actor, source: source)
          .find_by(id: template_id)
      end

      # §Findings S-14 ON A SURFACE WITH NO PROJECT — the locale KEY, not the sentence.
      #
      # A key rather than a translated string because the my-page partial has `l` (through
      # `ApplicationHelper`) and does not have our helper, so the view translates and this
      # module decides. `nil` for an issue template and for an actor who sees everything, so
      # the caller renders it unconditionally rather than behind a branch a later edit can
      # get wrong.
      #
      # The project-scoped version is `TemplatesHelper#reporter_time_entry_visibility_notice`
      # and the two are NOT interchangeable: that one asks `TimeEntryVisibility.state`, which
      # answers `:none` for a nil project — so used here it would tell a reader their role
      # does not let them see spent time "in this project" over a report drawing on four.
      def time_entry_notice_key(template, actor)
        return nil unless template.respond_to?(:source) && template.source.to_s == 'time_entries'

        case Reporting::TimeEntryVisibility.state_across_projects(actor)
        when :own then :text_reporter_time_entries_own_only_across_projects
        when :none then :text_reporter_time_entries_not_visible_anywhere
        end
      end

      # MY-PAGE IS THE SAME WIDGET WITH NO PROJECT, and this is the whole of the difference.
      #
      # `project: nil` means the templates are bounded by `Template.visible(actor)` alone
      # and the data by the saved query — or, with no query, by everything the actor can
      # see. The user asking for this put it exactly right: the query defines the input, so
      # there is nothing for a project selector to add that a query does not already say,
      # and a second way of saying it is a second thing that can disagree.
      def render_for_my_page(actor:, block:, settings:, logger: Rails.logger)
        render(project: nil, actor: actor, block: block, settings: settings, logger: logger)
      end

      # Whether this actor may be shown the block at all. Only the spent-time widget has an
      # extra condition, and it is core's `:view_time_entries` asked GLOBALLY, because
      # my-page has no project to ask it about — the same rule the project dashboard applies
      # per project, stated once here so the two surfaces cannot come to disagree.
      def block_permitted?(block, actor)
        return true unless ProjectPage.base_block_name(block) == 'report_by_spent_time'

        actor.respond_to?(:allowed_to?) && actor.allowed_to?(:view_time_entries, nil, global: true)
      end

      # WHAT A MY-PAGE PARTIAL'S RESCUE REPORTS WITH — the half a pre-check cannot cover.
      #
      # ERROR with a truncated backtrace, matching `ReporterProjectPagesHelper`'s
      # `reporter_project_block_error` rather than inventing a second regime for the same
      # event: an arbitrary exception from a widget body is an unknown defect, so it is
      # loud, every time. It answers nil so an ERB `<% %>` block that calls it appends
      # nothing to the buffer.
      #
      # It is here rather than in a helper because a my-page partial cannot reach one.
      def log_my_page_failure(error)
        Rails.logger.error(
          '[reporter_dashboards] my-page report widget could not be rendered: ' \
          "#{error.class}: #{error.message}\n" \
          "#{Array(error.backtrace).first(5).join("\n")}"
        )
        nil
      end

      # Render the widget, or nil when its settings do not yet name a resolvable template.
      #
      # `pdf:` decides which BINDING is produced, not which report: `false` is the HTML the
      # dashboard shows, `true` is the same template over the same scope as PDF bytes for
      # the widget's export link. One method for both, because "the export shows the same
      # report the widget shows" is only true while the two resolve identically — and the
      # base-plugin version of this proved that by resolving them in two places and drifting
      # (see the controller's own comment about `in_project_and_global`).
      def render(project:, actor:, block:, settings:, pdf: false, logger: Rails.logger)
        source = source_for(block)
        return nil if source.nil?

        template = template_for(project: project, actor: actor, source: source,
                                template_id: settings_value(settings, :report_template_id))
        return nil if template.nil?

        run(template: template, actor: actor, project: project,
            query_id: settings_value(settings, :query_id), pdf: pdf, logger: logger)
      end

      private

      # `report_template_id` KEEPS ITS NAME, and that is FR-46 rather than inertia: it is
      # the key already stored in every existing dashboard and already emitted by
      # `_report_settings.html.erb`. Renaming it would orphan both for no gain — the
      # VALUE changes meaning (it names one of our templates now, not the base plugin's),
      # and an old value simply fails to resolve, which `#template_for` documents as a
      # normal answer.
      #
      # Settings arrive from `BlockSettings`/`my_page_settings` and are read with either
      # key shape depending on the surface, which is why this is asked once here rather
      # than at four call sites.
      def settings_value(settings, key)
        return nil if settings.nil?

        settings[key] || settings[key.to_s]
      end

      # NO `limit:`, and that is the difference from a preview rather than an omission. A
      # widget's whole purpose is a figure about the project, and `{% sql_aggregate %}`
      # reads the relation the render context carries — so a limit here would produce
      # believable, wrong totals. What bounds a widget is the `:widget` execution policy
      # (a 5 s cooperative deadline and the smallest output caps in the table) and the drop
      # layer's own collection cap, which records a VISIBLE `unbounded_collection`
      # degradation rather than trimming in silence.
      def run(template:, actor:, project:, query_id:, pdf:, logger:)
        scope, query = Reporting::ReportScope.build(template: template, actor: actor,
                                                   project: project, query_id: query_id)
        outcome = Reporting::ReportRun.new(template: template, actor: actor, scope: scope,
                                          query: query, output_class: :widget,
                                          guard: Render::BatchGuard.new(logger: logger),
                                          logger: logger).call(pdf: pdf)
        Widget.new(template: template, query: query, outcome: outcome)
      end
    end
  end
end
