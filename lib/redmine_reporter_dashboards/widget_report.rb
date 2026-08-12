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
    # the base plugin. The full report is still one click away on the template's own page,
    # where a per-record run has somewhere to put N documents.
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
      def source_for(block)
        SOURCE_BY_BLOCK[block.to_s]
      end

      # The templates the settings form may offer, and the same scope `#template_for`
      # resolves against — one definition, so the picker and the lookup cannot disagree.
      def templates_for(project:, actor:, source:)
        Template.visible(actor)
                .where(project_id: [nil, project&.id], source: source.to_s, output: OUTPUT)
                .order(:name)
      end

      # The stored template, or nil.
      #
      # NIL IS A NORMAL ANSWER AND THE CALLER MUST TREAT IT AS ONE (FR-46). A dashboard
      # carried over from the base plugin holds ITS `report_template_id`, which will not
      # resolve here until the importer has run — and the honest response to that is the
      # settings form, which is already the partial's empty state. Erroring, or rendering
      # somebody else's report because the id happened to collide, are the two wrong
      # answers.
      def template_for(project:, actor:, source:, template_id:)
        return nil if template_id.blank?

        templates_for(project: project, actor: actor, source: source)
          .find_by(id: template_id)
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
