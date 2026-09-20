# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-26a — the owned report widget's lookup and its frame.
#
# These two modules are the foundation the widget partials will call; the partials
# themselves are the next increment. What is asserted here is everything that does not
# need a rendered page, and specifically the two claims that would be invisible later:
# that the frame is ONE object shared with the template editor, and that the lookup is
# visibility-scoped where the base plugin's was not.
class ReporterDashboardsWidgetReportTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  Template = RedmineReporterDashboards::Template
  Subject  = RedmineReporterDashboards::WidgetReport
  Frame    = RedmineReporterDashboards::ReportFrame

  def setup
    @project = Project.find(1)
    @other   = Project.find(2)
    # THE MODULE IS A PRECONDITION OF VISIBILITY, not decoration. `Template.visible` goes
    # through `Project.allowed_to_condition`, which requires the permission's module to be
    # enabled — so without this even an administrator resolves NOTHING, and the first run
    # of this file failed on exactly that with a diff that read like a broken scope.
    [@project, @other].each { |p| p.enable_module!(:reporter_dashboards_reports) }
    @admin   = User.find_by!(login: 'admin')
    @jsmith  = User.find_by!(login: 'jsmith')
  end

  # ------------------------------------------------------------------ the source map

  def test_each_block_maps_to_a_source_the_template_model_accepts
    Subject::SOURCE_BY_BLOCK.each do |block, source|
      assert_includes Template::SOURCES, source,
                      "#{block} maps to #{source.inspect}, which Template::SOURCES rejects"
    end
  end

  def test_an_unknown_block_has_no_source_and_renders_nothing
    assert_nil Subject.source_for('not_a_block')
    assert_nil Subject.render(project: @project, actor: @admin, block: 'not_a_block',
                              settings: { report_template_id: 1 })
  end

  # A PLACED WIDGET MAY CARRY AN INSTANCE SUFFIX, and the first version of `source_for`
  # answered nil for every one of them — so every second copy of a report widget on a
  # dashboard was dead while the picker went on offering more. Asserted across the whole
  # range a dashboard may hold, and one past it, because the suffix is only a name and
  # nothing here should care how high it goes.
  def test_every_placeable_instance_of_a_block_resolves_its_source
    max = ::RedmineReporterDashboards::ProjectPage::MAX_BLOCK_OCCURS
    Subject::SOURCE_BY_BLOCK.each do |block, source|
      assert_equal source, Subject.source_for(block)
      (1..max).each do |index|
        assert_equal source, Subject.source_for("#{block}__#{index}"),
                     "#{block}__#{index} must resolve the same source as #{block}"
      end
    end
  end

  # The strip must not turn an unrelated name into a known one.
  def test_the_instance_suffix_strip_does_not_invent_a_source
    ['report_by_issues__', 'report_by_issues__x', 'xreport_by_issues__1',
     'report_by_issues__1__2x'].each do |block|
      assert_nil Subject.source_for(block), "#{block} must not resolve a source"
    end
  end

  # ------------------------------------------------------------------ the run

  # THE REGRESSION THIS FILE EXISTED WITHOUT. `#render` was covered only on its two
  # early-return paths, so the one line that actually runs a report was never executed —
  # and `ReportRun::OUTPUT_CLASSES` did not contain `:widget`, so EVERY resolvable
  # template raised `ArgumentError: :widget is not a report output class`. The commit that
  # shipped it cited `Liquid::ExecutionPolicy::OUTPUT_CLASSES`, which is a different
  # constant that did contain it.
  def test_a_resolvable_template_actually_renders
    template = Template.create!(project: @project, author: @admin, name: 'Renders',
                                content: '<p>ISSUES={{ issues.size }}</p>',
                                source: 'issues', output: 'combined',
                                visibility: Template::VISIBILITY_PUBLIC)

    widget = Subject.render(project: @project, actor: @admin, block: 'report_by_issues',
                            settings: { report_template_id: template.id })

    assert_equal template, widget.template
    assert_nil widget.query, 'no query was named, so the report covers the whole project'
    assert widget.outcome.ok?, "expected a clean render, got #{widget.outcome.diagnostic.inspect}"
    assert_equal "<p>ISSUES=#{Issue.visible(@admin).where(project_id: @project.id).count}</p>",
                 widget.outcome.sections.first.body.strip
  end

  # THE TWO CLOSED SETS ARE ONE OBJECT, not two lists that happen to agree. Asserted by
  # identity for the same reason the frame constants below are: matching strings can be
  # edited apart, and this pair already was.
  def test_the_run_and_the_execution_policy_share_one_output_class_set
    assert_same ::RedmineReporterDashboards::Liquid::ExecutionPolicy::OUTPUT_CLASSES,
                ::RedmineReporterDashboards::Reporting::ReportRun::OUTPUT_CLASSES
    assert_includes ::RedmineReporterDashboards::Reporting::ReportRun::OUTPUT_CLASSES, :widget
  end

  # The widget renders under the `:widget` limits — the profile `ExecutionPolicy` has
  # carried since T-17 with nothing in production passing it — and it is NOT bounded by an
  # issue limit, because `{% sql_aggregate %}` reads the relation the render context
  # carries and a limit there produces believable, wrong totals.
  def test_the_run_is_asked_for_the_widget_limits_over_an_unbounded_scope
    template = Template.create!(project: @project, author: @admin, name: 'Limits',
                                content: '<p>x</p>', source: 'issues', output: 'combined',
                                visibility: Template::VISIBILITY_PUBLIC)
    captured = nil
    ::RedmineReporterDashboards::Reporting::ReportRun
      .expects(:new).with { |kwargs| captured = kwargs }
      .returns(stub(call: :outcome))

    Subject.render(project: @project, actor: @admin, block: 'report_by_issues',
                   settings: { report_template_id: template.id })

    assert_equal :widget, captured[:output_class]
    assert_nil captured[:limit]
    assert_equal @admin, captured[:actor]
  end

  # `pdf:` is the ONE argument that separates the dashboard widget from its export, which
  # is what makes "the export shows the same report the widget shows" true rather than
  # asserted. A port nothing looks at is a port a caller can drop — this plugin has lost
  # `asset_resolver:` and `selected_engine_id:` that way — so it is asserted in both
  # directions.
  def test_the_pdf_binding_is_forwarded_and_defaults_to_html
    template = Template.create!(project: @project, author: @admin, name: 'Binding',
                                content: '<p>x</p>', source: 'issues', output: 'combined',
                                visibility: Template::VISIBILITY_PUBLIC)
    run = stub
    ::RedmineReporterDashboards::Reporting::ReportRun.stubs(:new).returns(run)

    run.expects(:call).with(pdf: false).returns(:html)
    Subject.render(project: @project, actor: @admin, block: 'report_by_issues',
                   settings: { report_template_id: template.id })

    run.expects(:call).with(pdf: true).returns(:pdf)
    Subject.render(project: @project, actor: @admin, block: 'report_by_issues',
                   settings: { report_template_id: template.id }, pdf: true)
  end

  # A saved query narrows the report, and the widget's heading links to it — so it has to
  # come back out of the run rather than being resolved a second time by the view.
  def test_a_named_query_is_resolved_and_returned
    template = Template.create!(project: @project, author: @admin, name: 'Queried',
                                content: '<p>{{ issues.size }}</p>', source: 'issues',
                                output: 'combined', visibility: Template::VISIBILITY_PUBLIC)
    query = IssueQuery.create!(project: @project, name: 'Widget query', user: @admin,
                               filters: {})

    widget = Subject.render(project: @project, actor: @admin, block: 'report_by_issues',
                            settings: { report_template_id: template.id, query_id: query.id })

    assert_equal query, widget.query
  end

  # ------------------------------------------------------------------ the lookup

  # THE GAP THIS CLOSES. The base plugin's `in_project_and_global` enforced no visibility,
  # so a widget could render a template its viewer may not see. This asserts the new
  # bound by using an actor who must NOT see the template — and asserts the precondition
  # rather than trusting the fixture, because HANDOVER §1 records a whole round lost to a
  # role that turned out to be `issues_visibility: all`.
  def test_a_template_the_actor_cannot_see_does_not_resolve
    private_template = Template.create!(project: @project, author: @admin, name: 'Private',
                                        content: '<p>x</p>', source: 'issues',
                                        output: 'combined',
                                        visibility: Template::VISIBILITY_PRIVATE)

    assert_not Template.visible(@jsmith).exists?(private_template.id),
               'precondition: jsmith must not be able to see this template'

    assert_nil Subject.template_for(project: @project, actor: @jsmith, source: 'issues',
                                    template_id: private_template.id)
    assert_equal private_template,
                 Subject.template_for(project: @project, actor: @admin, source: 'issues',
                                      template_id: private_template.id)
  end

  # The project-or-global bound, kept from the partial it replaces for the reason that
  # partial's own comment gave: a widget must not render what its settings form refuses
  # to offer, or a project administrator sees a report they cannot change.
  def test_a_template_belonging_to_another_project_does_not_resolve
    foreign = Template.create!(project: @other, author: @admin, name: 'Foreign',
                               content: '<p>x</p>', source: 'issues', output: 'combined')

    assert_nil Subject.template_for(project: @project, actor: @admin, source: 'issues',
                                    template_id: foreign.id)
  end

  def test_a_global_template_resolves_in_every_project
    global = Template.create!(project: nil, author: @admin, name: 'Global',
                              content: '<p>x</p>', source: 'issues', output: 'combined')

    assert_equal global, Subject.template_for(project: @project, actor: @admin,
                                             source: 'issues', template_id: global.id)
    assert_equal global, Subject.template_for(project: @other, actor: @admin,
                                             source: 'issues', template_id: global.id)
  end

  # A time-entry widget must not offer, or resolve, an issue template. `source` is a
  # closed column and this is the one place a widget chooses between its values.
  def test_the_source_bound_separates_the_two_widgets
    issues_template = Template.create!(project: @project, author: @admin, name: 'Issues',
                                       content: '<p>x</p>', source: 'issues',
                                       output: 'combined')

    assert_nil Subject.template_for(project: @project, actor: @admin,
                                    source: 'time_entries', template_id: issues_template.id)
    assert_not_includes Subject.templates_for(project: @project, actor: @admin,
                                             source: 'time_entries'),
                        issues_template
  end

  # A DASHBOARD BOX IS ONE DOCUMENT, so a `per_record` template is refused at the PICKER
  # rather than bounded at the render — see `WidgetReport::OUTPUT`. Both halves, because
  # a template absent from the picker but still resolvable from a stored id is precisely
  # the divergence this module exists to prevent.
  def test_a_per_record_template_is_neither_offered_nor_resolved
    per_record = Template.create!(project: @project, author: @admin, name: 'Per record',
                                  content: '<p>{{ issue.id }}</p>', source: 'issues',
                                  output: 'per_record')

    assert_not_includes Subject.templates_for(project: @project, actor: @admin,
                                              source: 'issues'),
                        per_record
    assert_nil Subject.template_for(project: @project, actor: @admin, source: 'issues',
                                    template_id: per_record.id)
    assert_nil Subject.render(project: @project, actor: @admin, block: 'report_by_issues',
                              settings: { report_template_id: per_record.id })
  end

  # FR-46. Every dashboard carried over from the base plugin holds ITS report_template_id,
  # which cannot resolve here until the importer has run. Nil is the answer; the caller's
  # empty state is the settings form.
  def test_an_unresolvable_or_blank_stored_id_is_nil_rather_than_an_error
    [nil, '', ' ', 999_999].each do |value|
      assert_nil Subject.template_for(project: @project, actor: @admin, source: 'issues',
                                      template_id: value),
                 "#{value.inspect} must resolve to nil, not raise"
    end
  end

  # THE PICKER AND THE LOOKUP ARE ONE DEFINITION. If they diverge, a form offers a
  # template the widget then refuses — which is the bug the old partial's comment
  # described. Asserted by construction: every template the picker offers must resolve.
  def test_every_template_the_picker_offers_also_resolves
    Template.create!(project: @project, author: @admin, name: 'A', content: '<p>a</p>',
                     source: 'issues', output: 'combined')
    Template.create!(project: nil, author: @admin, name: 'B', content: '<p>b</p>',
                     source: 'issues', output: 'combined')

    offered = Subject.templates_for(project: @project, actor: @admin, source: 'issues')
    assert offered.any?, 'precondition: the picker must offer something'

    offered.each do |template|
      assert_equal template,
                   Subject.template_for(project: @project, actor: @admin, source: 'issues',
                                        template_id: template.id),
                   "#{template.name} is offered by the picker but does not resolve"
    end
  end

  # ------------------------------------------------------------------ the frame

  # THE CLAIM THAT WOULD OTHERWISE BE INVISIBLE: the editor and the widget share ONE
  # frame definition. The objection to moving the markup out of the helper was that the
  # CSP and the body must not become separable; this asserts they did not, by identity
  # rather than by comparing two strings that could each drift.
  def test_the_helper_delegates_to_the_one_frame_definition
    helper = ReporterDashboards::TemplatesHelper
    assert_same Frame::CONTENT_SECURITY_POLICY, helper::CONTENT_SECURITY_POLICY
    assert_same Frame::SANDBOX, helper::SANDBOX
  end

  # NO `allow-same-origin`. That one token is the difference between a sandbox and a
  # decoration, so it is asserted as an absence and not only as a presence.
  def test_the_frame_is_an_opaque_origin
    markup = Frame.frame('<p>x</p>', title: 'Report')

    assert_includes markup, 'sandbox="allow-scripts"'
    assert_not_includes markup, 'allow-same-origin'
  end

  def test_the_frame_document_carries_the_policy_and_denies_network_access
    document = Frame.document('<p>body</p>')

    assert_includes document, 'Content-Security-Policy'
    assert_includes document, "default-src 'none'"
    assert_includes document, '<p>body</p>'
    # No connect-src hole, so nothing inside a report can call home.
    assert_not_includes document, 'connect-src'
  end

  # THE BODY IS ATTRIBUTE DATA, NOT MARKUP THE PAGE PARSES (INV-9). A body carrying a
  # script tag must reach the frame escaped in the srcdoc attribute rather than opening a
  # real element in the viewer's own document.
  def test_a_script_in_the_body_does_not_become_markup_in_the_parent_document
    markup = Frame.frame('<script>alert(1)</script>', title: 'Report')

    assert_not_includes markup, '<script>'
    assert_includes markup, '&lt;script&gt;'
  end

  # ------------------------------------------------ T-52: a project on the my-page widget

  def counting_template(name: 'Counts')
    Template.create!(project: nil, author: @admin, name: name,
                     content: 'ISSUES={{ issues.size }}', source: 'issues',
                     output: 'combined', visibility: Template::VISIBILITY_PUBLIC)
  end

  # jsmith's role carries no report permission in the fixture, and `projects_for` asks for
  # exactly that — so without this the picker examples measure the fixture rather than the
  # rule.
  def grant_reports_to_jsmith
    Role.find(1).add_permission!(:view_reporter_dashboards_reports)
    User.current = nil
  end

  def my_page_body(actor, settings)
    widget = Subject.render_for_my_page(actor: actor, block: 'report_by_issues',
                                        settings: settings, logger: Rails.logger)
    [widget, widget&.outcome&.sections&.first&.body.to_s.strip]
  end

  def test_no_project_counts_everything_the_actor_can_see
    template = counting_template
    User.current = @admin

    widget, body = my_page_body(@admin, { report_template_id: template.id })

    assert_nil widget.project
    assert_equal "ISSUES=#{Issue.visible(@admin).count}", body
  end

  # THE POINT OF THE TASK. Project 2 is a SIBLING of project 1, so a widget bounded to
  # project 1 must stop counting it — which is the difference a saved query cannot express.
  def test_a_chosen_project_bounds_the_rows
    template = counting_template
    User.current = @admin
    everywhere = Issue.visible(@admin).count
    here = Issue.visible(@admin).where(project_id: @project.id).count
    assert_operator everywhere, :>, here, 'precondition: rows exist outside project 1'

    widget, body = my_page_body(@admin, { report_template_id: template.id,
                                          project_id: @project.id.to_s })

    assert_equal @project, widget.project
    assert_equal "ISSUES=#{here}", body
  end

  # FAILS CLOSED. The owner asked for one project; a revoked permission must not silently
  # turn that into every project (INV-3).
  def test_a_project_the_actor_may_no_longer_read_renders_nothing_and_says_so
    template = counting_template
    grant_reports_to_jsmith
    User.current = @jsmith
    # Project 1, because that is where jsmith holds the role the grant above touched.
    settings = { report_template_id: template.id, project_id: @project.id.to_s }
    assert Subject.render_for_my_page(actor: @jsmith, block: 'report_by_issues',
                                      settings: settings, logger: Rails.logger).outcome,
           'precondition: jsmith can read this project to begin with'

    @project.disable_module!(:reporter_dashboards_reports)
    widget = Subject.render_for_my_page(actor: @jsmith, block: 'report_by_issues',
                                        settings: settings, logger: Rails.logger)

    assert widget.project_unavailable
    assert_nil widget.outcome, 'a widget whose project is gone must render no report'
  end

  # NOT AN ORACLE. `find` would raise for an id that does not exist and return for one that
  # exists but is forbidden, and the my-page partials turn a raise into a visible error
  # placeholder — so the pair would answer which project ids exist. Both must look the same.
  def test_an_unusable_project_id_answers_the_same_whether_or_not_it_exists
    template = counting_template
    grant_reports_to_jsmith
    User.current = @jsmith
    @other.disable_module!(:reporter_dashboards_reports)
    missing = Project.maximum(:id).to_i + 1000

    forbidden = Subject.render_for_my_page(
      actor: @jsmith, block: 'report_by_issues',
      settings: { report_template_id: template.id, project_id: @other.id.to_s },
      logger: Rails.logger
    )
    nonexistent = Subject.render_for_my_page(
      actor: @jsmith, block: 'report_by_issues',
      settings: { report_template_id: template.id, project_id: missing.to_s },
      logger: Rails.logger
    )

    assert forbidden.project_unavailable
    assert nonexistent.project_unavailable
    assert_equal forbidden.to_h, nonexistent.to_h
  end

  def test_rubbish_in_the_stored_project_id_does_not_raise
    template = counting_template
    User.current = @admin

    %w[abc 0x1 -1 12.5].each do |rubbish|
      widget = Subject.render_for_my_page(
        actor: @admin, block: 'report_by_issues',
        settings: { report_template_id: template.id, project_id: rubbish },
        logger: Rails.logger
      )

      assert widget.project_unavailable, "#{rubbish.inspect} should be unusable, not fatal"
    end
  end

  # THE TEMPLATE LOOKUP IS NOT NARROWED. One keyword would narrow it, and then choosing a
  # project would silently unresolve a widget whose template belongs elsewhere.
  def test_choosing_a_project_still_resolves_a_template_from_another_project
    template = Template.create!(project: @other, author: @admin, name: 'Elsewhere',
                                content: 'ISSUES={{ issues.size }}', source: 'issues',
                                output: 'combined', visibility: Template::VISIBILITY_PUBLIC)
    User.current = @admin

    widget, = my_page_body(@admin, { report_template_id: template.id,
                                     project_id: @project.id.to_s })

    assert_equal template, widget.template
    assert_equal @project, widget.project
  end

  # THE SPENT-TIME NOTICE FOLLOWS THE PROJECT. `state_across_projects` answers `:all` as
  # soon as ANY membership grants it, so over a project-bounded widget it would print
  # nothing where the project-scoped answer is "only your own hours" — S-14's shape.
  def test_the_spent_time_notice_is_the_project_one_when_a_project_is_chosen
    template = Template.new(source: 'time_entries')
    Role.find(1).update_columns(time_entries_visibility: 'own')
    Role.find(1).add_permission!(:view_time_entries)

    assert_equal :text_reporter_time_entries_own_only,
                 Subject.time_entry_notice_key(template, @jsmith, project: @project)
    assert_equal :text_reporter_time_entries_own_only_across_projects,
                 Subject.time_entry_notice_key(template, @jsmith)
  end

  # The picker must not offer a project whose report would then be empty for a permission
  # reason, and must not offer one the actor cannot read at all.
  def test_the_picker_offers_only_projects_the_actor_may_read_reports_in
    grant_reports_to_jsmith
    User.current = @jsmith
    @other.disable_module!(:reporter_dashboards_reports)

    offered = Subject.projects_for(actor: @jsmith)

    assert_includes offered, @project
    assert_not_includes offered, @other
    assert_empty Subject.projects_for(actor: User.anonymous).to_a - Project.where(is_public: true).to_a
  end
end
