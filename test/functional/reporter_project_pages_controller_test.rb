# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ReporterProjectPagesControllerTest < ActionController::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :projects_trackers, :enumerations

  ISSUE_COUNT_MARKER = 'ZZWidgetCount'

  def setup
    @project = Project.find(1)
    Role.find(1).add_permission! :view_issues
    Role.find(1).add_permission! :view_reporter_project_page
    Role.find(1).add_permission! :manage_reporter_project_page
    Role.find(1).add_permission! :manage_reporter_project_tabs

    @project.enable_module!(:reporter_project_dashboards) unless @project.module_enabled?(:reporter_project_dashboards)
    # T-26a — the report widgets render THIS plugin's templates, and `Template.visible`
    # goes through `Project.allowed_to_condition`, which needs BOTH the permission and the
    # module. Without the module even an administrator resolves nothing, and the failure
    # reads like a broken scope rather than a missing precondition.
    @project.enable_module!(:reporter_dashboards_reports)
    Role.find(1).add_permission! :view_reporter_dashboards_reports
    @tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    @request.session[:user_id] = User.find_by!(login: 'jsmith').id
  end

  def test_show
    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :success
  end

  def test_show_renders_tab_order_icons_for_middle_tab
    first_tab = ReporterProjectTab.create!(project: @project, title: 'First')
    middle_tab = ReporterProjectTab.create!(project: @project, title: 'Middle')
    ReporterProjectTab.create!(project: @project, title: 'Last')

    get :show, params: { project_id: @project.identifier, tab: middle_tab.id }
    assert_response :success
    assert_select "a[href*='direction=left']", 1
    assert_select "a[href*='direction=right']", 1
    assert_select 'input[name="reporter_project_tab[title]"][value="Middle"]', 1
  end

  def test_show_renders_nodata_when_layout_empty
    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :success
    assert_select '#reporter-project-page .nodata', 1
    assert_select '#reporter-project-page .reporter-row', 0
  end

  def test_show_renders_block_in_a_row
    @tab.update!(layout: [['activity']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :success
    assert_select '#reporter-project-page .reporter-row #reporter-block-activity', 1
    assert_select '#reporter-project-page .nodata', 0
  end

  def test_show_renders_move_controls_for_multi_widget_row
    @tab.update!(layout: [['activity', 'news']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :success
    # activity (left cell) can move right; news (right cell) can move left.
    assert_select "#reporter-block-activity a[href*='direction=right']", 1
    assert_select "#reporter-block-news a[href*='direction=left']", 1
  end

  def test_show_with_activity_block
    @tab.update!(layout: [['activity']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-activity', 1
    assert_select '#activity-settings', 1
  end

  def test_show_with_activity_block_instance_suffix
    @tab.update!(layout: [['activity__2']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-activity__2', 1
    assert_select '#activity__2-settings', 1
  end

  def test_show_with_timelog_block_uses_block_variable
    @tab.update!(layout: [['timelog']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-timelog', 1
    # Settings div and form field must use the block variable, not the hard-coded string
    assert_select '#timelog-settings', 1
    assert_select 'input[name="settings[timelog][days]"]', 1
  end

  def test_show_with_timelog_block_suffix_uses_block_variable
    @tab.update!(layout: [['timelog__2']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#timelog__2-settings', 1
    assert_select 'input[name="settings[timelog__2][days]"]', 1
    # Must NOT render the old hard-coded id
    assert_select '#timelog-settings', 0
  end

  def test_show_with_activity_block_without_manage_permission
    role = Role.find(1)
    role.remove_permission! :manage_reporter_project_page
    @tab.update!(layout: [['activity']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-activity', 1
    assert_select '#activity-settings', 0
    assert_select '.icon-only.icon-close', 0
    assert_select '.reporter-move-controls', 0
  ensure
    role.add_permission! :manage_reporter_project_page
  end

  def test_update_page_ignores_malformed_settings
    @tab.update!(layout: [['news']])

    compatible_xhr_request :patch, :update_page, project_id: @project.identifier, tab: @tab.id, settings: 'invalid'

    assert_response :success
    assert_equal({}, @tab.reload.block_settings)
  end

  def test_update_page_ignores_unknown_block_settings
    compatible_xhr_request :patch, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { unknown: { limit: '50' } }

    assert_response :success
    assert_equal({}, @tab.reload.block_settings)
  end

  def test_update_page_saves_valid_block_settings
    @tab.update!(layout: [['news']])

    compatible_xhr_request :patch, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { news: { limit: '10' } }

    assert_response :success
    # Stored as an Integer: BlockSettings types the known numeric settings, and every
    # reader either calls to_i or hands it to find_by.
    assert_equal 10, @tab.reload.block_settings('news')[:limit]
  end

  def test_update_page_drops_a_non_numeric_limit
    @tab.update!(layout: [['news']])

    compatible_xhr_request :patch, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { news: { limit: 'all of them' } }

    assert_response :success
    assert_equal({}, @tab.reload.block_settings('news'))
  end

  def test_update_page_drops_a_nested_setting
    @tab.update!(layout: [['news']])

    compatible_xhr_request :patch, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { news: { limit: '10',
                                                                    nested: { deep: { deeper: 'x' } } } }

    assert_response :success
    settings = @tab.reload.block_settings('news')
    assert_equal 10, settings[:limit]
    assert_not settings.key?(:nested)
  end

  # A widget contributed by another plugin cannot have its setting names known here,
  # so an unknown key is kept — as a bounded scalar.
  def test_update_page_keeps_an_unknown_setting_as_a_bounded_scalar
    @tab.update!(layout: [['news']])

    compatible_xhr_request :patch, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { news: { third_party_key: 'x' * 5_000 } }

    assert_response :success
    value = @tab.reload.block_settings('news')[:third_party_key]
    assert_equal RedmineReporterDashboards::BlockSettings::MAX_VALUE_LENGTH, value.length
  end

  # All four write actions used to ignore what save answered: a rejected write looked
  # exactly like a successful one, and the widget redrew from the in-memory object the
  # user had just changed. The size limit on the settings column is the easiest real
  # rejection to produce.
  def test_update_page_reports_a_failed_save_and_reloads
    @tab.update!(layout: [['news']])
    # Past the settings size limit, written with update_column so it bypasses both the
    # sanitizer (which bounds each value) and the validation. Any further legal change
    # then merges onto an already-oversized column, so save really does fail — no stub.
    @tab.update_column(:settings, { 'news' => { 'note' => 'x' * (ReporterProjectTab::MAX_SETTINGS_BYTES + 1) } })

    compatible_xhr_request :patch, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { news: { limit: '5' } }

    assert_response :success
    assert_match 'window.location.reload', @response.body
    assert_match I18n.t(:error_reporter_dashboard_save_failed), flash[:error]
    assert_nil @tab.reload.block_settings('news')[:limit]
  end

  def test_update_page_does_not_reload_on_a_successful_save
    @tab.update!(layout: [['news']])

    compatible_xhr_request :patch, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { news: { limit: '5' } }

    assert_response :success
    assert_no_match 'window.location.reload', @response.body
    assert_nil flash[:error]
  end

  def test_add_block_reports_a_failed_save
    @tab.update!(layout: [['news']])
    ReporterProjectTab.any_instance.stubs(:save).returns(false)

    post :add_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'activity' }

    assert_response :redirect
    assert_match I18n.t(:error_reporter_dashboard_save_failed), flash[:error]
  end

  def test_remove_block_reports_a_failed_save
    @tab.update!(layout: [['news']])
    ReporterProjectTab.any_instance.stubs(:save).returns(false)

    delete :remove_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'news' }

    assert_response :redirect
    assert_match I18n.t(:error_reporter_dashboard_save_failed), flash[:error]
  end

  def test_move_block_reports_a_failed_save
    @tab.update!(layout: [['news'], ['activity']])
    ReporterProjectTab.any_instance.stubs(:save).returns(false)

    patch :move_block, params: { project_id: @project.identifier, tab: @tab.id,
                                block: 'activity', direction: 'up' }

    assert_response :redirect
    assert_match I18n.t(:error_reporter_dashboard_save_failed), flash[:error]
  end

  # A widget whose partial raises must not take the whole dashboard down with it. The
  # concrete case is Redmine 7.0, where reporter's report template classes cannot be
  # loaded, but the guarantee is general: this plugin's block registry globs OTHER
  # plugins' view directories, so a foreign partial raising is a scenario to survive.
  def test_a_widget_that_raises_does_not_break_the_dashboard
    @tab.update!(layout: [['news'], ['activity']])

    raising_instance_method(ReporterProjectPagesHelper, :render_reporter_project_news_block) do
      get :show, params: { project_id: @project.identifier, tab: @tab.id }
    end

    assert_response :success
    # The rest of the page is intact...
    assert_select '#reporter-block-activity'
    # ...and the broken widget keeps its box, so its close button is still reachable
    # and an administrator can remove it from the layout.
    assert_select '#reporter-block-news p.nodata', text: I18n.t(:error_reporter_widget_render_failed)
    assert_select '#reporter-block-news .icon-close', 1
  end

  def test_move_block_ignores_absent_block
    @tab.update!(layout: [['news']])

    patch :move_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'activity', direction: 'up' }

    assert_response :redirect
    assert_equal [['news']], @tab.reload.block_rows
  end

  def test_move_block_reorders_within_row
    @tab.update!(layout: [['news', 'activity']])

    patch :move_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'activity', direction: 'left' }

    assert_response :redirect
    assert_equal [['activity', 'news']], @tab.reload.block_rows
  end

  def test_move_block_up_merges_rows
    @tab.update!(layout: [['news'], ['activity']])

    patch :move_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'activity', direction: 'up' }

    assert_response :redirect
    assert_equal [['news', 'activity']], @tab.reload.block_rows
  end

  def test_add_block
    post :add_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'news' }

    assert_response :redirect
    assert_includes @tab.reload.block_rows.flatten, 'news'
  end

  def test_remove_block
    @tab.update!(layout: [['news']])

    delete :remove_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'news' }

    assert_response :redirect
    refute_includes @tab.reload.block_rows.flatten, 'news'
  end

  def test_show_requires_dashboard_module
    @project.disable_module!(:reporter_project_dashboards)
    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :not_found
  end

  # A GET must not INSERT: a crawler or a monitoring probe used to create rows, the
  # request failed outright against a read-only replica, and two simultaneous first
  # visits each created a "default" tab. The page still looks the same — the unsaved
  # default tab is rendered in the bar — it is simply not persisted.
  def test_show_shows_a_default_tab_without_creating_one
    @project.reporter_project_tabs.destroy_all

    assert_no_difference 'ReporterProjectTab.count' do
      get :show, params: { project_id: @project.identifier }
    end
    assert_response :success
    assert_select '.tabs a.selected', I18n.t(:label_reporter_default_dashboard_tab)
  end

  # The settings box's edit branch needs a persisted record for its update, delete and
  # reorder links, so it is not rendered before the tab exists. The create branch is,
  # which is what keeps "add tab" reachable from an empty dashboard.
  def test_show_without_a_persisted_tab_offers_the_add_tab_form_but_not_the_edit_form
    @project.reporter_project_tabs.destroy_all

    get :show, params: { project_id: @project.identifier }
    assert_response :success
    assert_select '#reporter-dashboard-settings', 0
    assert_select '#reporter-tab-add', 1

    get :show, params: { project_id: @project.identifier, new_tab: '1' }
    assert_response :success
    assert_select '#reporter-dashboard-settings form', 1
  end

  def test_add_block_creates_the_default_tab_when_there_is_none
    @project.reporter_project_tabs.destroy_all

    assert_difference 'ReporterProjectTab.count', 1 do
      post :add_block, params: { project_id: @project.identifier, block: 'news' }
    end
    assert_response :redirect
    tab = @project.reporter_project_tabs.reload.first
    assert_equal I18n.t(:label_reporter_default_dashboard_tab), tab.title
    assert_equal [['news']], tab.block_rows
  end

  def test_update_page_creates_the_default_tab_when_there_is_none
    @project.reporter_project_tabs.destroy_all

    assert_difference 'ReporterProjectTab.count', 1 do
      compatible_xhr_request :patch, :update_page, project_id: @project.identifier,
                                                 settings: { news: { limit: '5' } }
    end
    assert_response :success
  end

  def test_report_pdf_does_not_create_a_tab
    @project.reporter_project_tabs.destroy_all

    assert_no_difference 'ReporterProjectTab.count' do
      get :report_pdf, params: { project_id: @project.identifier, block: 'report_by_issues' }
    end
    assert_response :not_found
  end

  # The count next to an issue widget's title is the number of issues the query
  # matches, not the number of rows the widget shows: a widget limited to 5 rows
  # out of 7 matching issues must still read "(7)".
  def test_show_issue_widget_count_is_the_total_not_the_limit
    generate_marked_issues(7)
    show_issue_query_widget(limit: '5')

    assert_response :success
    assert_widget_count 'issuequery', 7
    assert_select '#reporter-block-issuequery table.issues tbody tr.hascontextmenu', 5
  end

  def test_show_issue_widget_count_matches_rows_when_unlimited
    generate_marked_issues(7)
    show_issue_query_widget(limit: '0')

    assert_response :success
    assert_widget_count 'issuequery', 7
    assert_select '#reporter-block-issuequery table.issues tbody tr.hascontextmenu', 7
  end

  def test_show_issue_widget_count_is_zero_without_matching_issues
    show_issue_query_widget(limit: '5')

    assert_response :success
    assert_widget_count 'issuequery', 0
    assert_select '#reporter-block-issuequery table.issues', 0
    assert_select '#reporter-block-issuequery .nodata', 1
  end

  # Grouping is a plugin addition on top of core's my-page widget. Core renders
  # the per-group badges from the *unlimited* counts, so the widget total has to
  # agree with them rather than with the number of rendered rows.
  def test_show_grouped_issue_widget_count_matches_sum_of_group_badges
    generate_marked_issues(7)
    show_issue_query_widget(limit: '5', group_by: 'tracker')

    assert_response :success
    assert_widget_count 'issuequery', 7
    badges = css_select('#reporter-block-issuequery tr.group span.badge-count').map { |span| span.text.to_i }
    assert badges.any?, 'Expected the grouped list to render group badges'
    assert_equal 7, badges.sum
  end

  # The four built-in issue widgets build an unsaved IssueQuery in the helper;
  # issue_count must work there too (and still ignore the row limit, 10 by
  # default). Asserted as ">= what this test created" rather than an exact number,
  # so the fixtures' own assigned issues (and Setting.display_subprojects_issues?)
  # cannot make it brittle.
  def test_show_assigned_to_me_widget_count_is_the_total_not_the_limit
    generate_marked_issues(12, assigned_to: User.find_by!(login: 'jsmith'))
    @tab.update!(layout: [['issuesassignedtome']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_operator widget_count('issuesassignedtome'), :>=, 12
    assert_select '#reporter-block-issuesassignedtome table.issues tbody tr.hascontextmenu', 10
  end

  def test_report_pdf_unknown_block_returns_404
    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'not_a_block' }
    assert_response :not_found
  end

  # ---------------------------------------------------------------------------
  # T-26a — THE OWNED REPORT WIDGETS.
  #
  # Everything below used to be about redmine_reporter: whether it was installed,
  # whether its classes loaded, and whether `in_project_and_global` had been asked
  # for the right project. Four of these tests SKIPPED on a standalone run, which
  # is exactly the configuration FR-01 is about. Nothing here needs it now — the
  # lookup is `WidgetReport`/`Template.visible` and the render is `ReportRun` — so
  # the skips are gone rather than rewritten, and this whole section runs on every
  # branch of the matrix.
  # ---------------------------------------------------------------------------

  REPORT_BLOCKS = %w[report_by_issues report_by_spent_time].freeze

  def test_report_pdf_without_a_configured_template_returns_404
    # report_by_issues is a valid block, but the tab names no template. Nothing to
    # export is not an error — the dashboard offers the settings form instead.
    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }
    assert_response :not_found
  end

  # THE GAP THIS CLOSES, and it is a gap rather than a port. The base plugin's
  # `in_project_and_global` enforced NO visibility, so a widget — and its PDF export,
  # which is a document leaving the application — could render a template its viewer
  # may not see. The precondition is asserted rather than trusted (HANDOVER §1: a
  # whole round was lost to a fixture role that turned out to be `issues_visibility:
  # all`).
  def test_report_pdf_refuses_a_template_the_viewer_cannot_see
    private_template = rrd_template(visibility: rrd_visibility_private, name: 'Private')
    assert_not RedmineReporterDashboards::Template.visible(User.find_by!(login: 'jsmith'))
                                                  .exists?(private_template.id),
               'precondition: jsmith must not be able to see this template'
    configure_report_widget(private_template)

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_response :not_found
  end

  # Kept from the partial this replaces, for the reason its own comment gave: a widget
  # must not render what its settings form refuses to offer, or a project administrator
  # sees a report they cannot change.
  def test_report_pdf_refuses_a_template_belonging_to_another_project
    foreign = rrd_template(project: Project.find(2), name: 'Foreign')
    configure_report_widget(foreign)

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_response :not_found
  end

  # A dashboard box is one document, so `per_record` templates are not offered here and
  # not resolved here (`WidgetReport::OUTPUT`). Asserted through the EXPORT as well as
  # the picker, because the export is the half that would otherwise draw N documents and
  # send the first.
  def test_report_pdf_refuses_a_per_record_template
    configure_report_widget(rrd_template(output: 'per_record', name: 'Per record'))

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_response :not_found
  end

  def test_report_pdf_for_spent_time_requires_the_time_entries_permission
    Role.find(1).remove_permission! :view_time_entries
    configure_report_widget(rrd_template(source: 'time_entries', name: 'Hours'),
                            block: 'report_by_spent_time')

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id,
                               block: 'report_by_spent_time' }

    assert_response :not_found
  end

  # THE EXPORT AND THE WIDGET RESOLVE THROUGH ONE CALL, and the argument that makes them
  # the same report is `pdf: true` — the only one that differs. Asserted on the call
  # rather than on the bytes, because this plugin has already lost a port (`asset_resolver:`,
  # `selected_engine_id:`) by having nothing look at it.
  #
  # The render itself is stubbed here and in the three tests below. That is deliberate:
  # `pdf: true` resolves and STARTS a render engine, which in this container is a real
  # Chromium that refuses to run as root (HANDOVER §3) — so a controller test that let it
  # run would be asserting the environment. What is under test is this controller's own
  # branches, and they are all about the outcome it is handed.
  def test_report_pdf_asks_for_the_pdf_binding_as_the_current_user
    template = rrd_template
    configure_report_widget(template)
    RedmineReporterDashboards::WidgetReport
      .expects(:render)
      .with(has_entries(project: @project, actor: User.find_by!(login: 'jsmith'),
                        block: 'report_by_issues', pdf: true))
      .returns(rrd_widget(template, documents: [rrd_document]))

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert_equal '%PDF-1.4 stub', response.body
  end

  def test_report_pdf_names_the_file_after_the_template
    template = rrd_template(name: 'Q3 / hours & costs')
    configure_report_widget(template)
    RedmineReporterDashboards::WidgetReport.stubs(:render)
                                           .returns(rrd_widget(template, documents: [rrd_document]))

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_response :success
    assert_match(/filename="Q3_hours_costs\.pdf"/, response.headers['Content-Disposition'])
  end

  # INV-5, at the one entry point that sends bytes: an error is NEVER the document. The
  # base plugin returned the exception message AS the PDF, so a recipient got a file
  # named `.pdf` that was not one.
  def test_report_pdf_reports_a_failure_as_an_error_page_and_sends_no_bytes
    template = rrd_template
    configure_report_widget(template)
    RedmineReporterDashboards::WidgetReport
      .stubs(:render)
      .returns(rrd_widget(template, diagnostic: rrd_diagnostic(origin: :engine,
                                                               code: :engine_crashed)))

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_response :internal_server_error
    assert_not_equal 'application/pdf', response.media_type
    # Neither the engine's own words nor the correlation id reach the reader here; the
    # log line carries them and `error_reporter_pdf_generation_failed` is the sentence.
    assert_no_match(/the browser exited/, response.body)
  end

  # 422 AND NOT 500 FOR A REFUSAL — T-15's point, and the same split
  # `TemplatesController#outcome_status` makes. A member pasting a CDN image URL into a
  # template must not page an operator.
  def test_report_pdf_reports_a_refusal_as_422
    template = rrd_template
    configure_report_widget(template)
    RedmineReporterDashboards::WidgetReport
      .stubs(:render)
      .returns(rrd_widget(template, diagnostic: rrd_diagnostic(origin: :assets,
                                                               code: :asset_unresolved)))

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_response :unprocessable_entity
  end

  # An empty batch is not a file, and `documents.first.bytes` on one is a NoMethodError —
  # a 500 for a request that merely had nothing to draw.
  def test_report_pdf_with_no_documents_is_404_rather_than_a_500
    template = rrd_template
    configure_report_widget(template)
    RedmineReporterDashboards::WidgetReport.stubs(:render).returns(rrd_widget(template))

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_response :not_found
  end

  # --------------------------------------------------------------- the dashboard itself

  # THE WIDGETS ARE ALWAYS OFFERED NOW. They used to leave the picker wherever
  # redmine_reporter was absent, which since T-26a would hide this plugin's own feature
  # from every standalone install — the configuration the project exists to produce.
  def test_report_widgets_are_offered_in_the_picker
    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    REPORT_BLOCKS.each do |block|
      assert_select '#reporter-block-select option[value=?]', block, 1
    end
  end

  def test_a_report_widget_can_be_added_to_a_dashboard
    post :add_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_equal [['report_by_issues']], @tab.reload.block_rows
  end

  # THE END-TO-END CASE, and the one nothing could assert while the render belonged to
  # another plugin: a configured widget renders its report, in its own sandboxed frame,
  # on a Redmine with no base plugin installed at all.
  def test_a_configured_widget_renders_its_report_in_the_sandboxed_frame
    configure_report_widget(rrd_template(name: 'Open work'))

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-report_by_issues h3', /Open work/
    frame = css_select('#reporter-block-report_by_issues iframe.reporter-report-frame--widget').first
    assert frame, 'the report must be rendered inside the opaque-origin frame'
    assert_equal 'allow-scripts', frame['sandbox'],
                 'allow-same-origin would let template JavaScript read the viewer session'
    assert_includes frame['srcdoc'], "ISSUES=#{Issue.visible(User.find_by!(login: 'jsmith'))
                                                     .where(project_id: @project.id).count}"
  end

  # THE SPENT-TIME WIDGET RENDERS TOO, AND NOTHING ASSERTED IT. The independent review of
  # T-26a mutated its registered partial path to a name that does not exist and the suite
  # stayed green — `render_reporter_project_block_content` rescues `ActionView::MissingTemplate`
  # and returns nil, so the box AND ITS CLOSE BUTTON vanish and the widget cannot be removed.
  # `test_a_report_widget_resolves_from_the_block_registry` only pins the path's PREFIX,
  # which the mutant still matched.
  def test_the_spent_time_widget_renders_its_report_in_the_sandboxed_frame
    Role.find(1).add_permission! :view_time_entries
    configure_report_widget(rrd_template(source: 'time_entries', name: 'Hours',
                                         content: '<p>HOURS={{ time_entries.size }}</p>'),
                            block: 'report_by_spent_time')

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-report_by_spent_time h3', /Hours/
    frame = css_select('#reporter-block-report_by_spent_time iframe.reporter-report-frame--widget').first
    assert frame, 'the spent-time report must render inside the opaque-origin frame'
    assert_includes frame['srcdoc'],
                    "HOURS=#{TimeEntry.visible(User.find_by!(login: 'jsmith'))
                                      .where(project_id: @project.id).count}"
    assert_no_match(/translation missing/i, response.body)
  end

  # A SECOND INSTANCE OF A WIDGET IS A FIRST-CLASS CASE, and it was broken.
  #
  # `ProjectPage.block_options` hands the picker `report_by_issues__1` the moment one
  # instance is placed (`MAX_BLOCK_OCCURS` is 15), and `find_block`, the helper and the
  # controller all strip that suffix — but `WidgetReport.source_for` did not, so the user
  # added the widget, chose a template, saved, and the box rendered the settings form for
  # ever with no message. A regression: the partial this replaced never used `block` to
  # resolve. Found by the independent review of T-26a.
  def test_a_second_instance_of_the_widget_renders_like_the_first
    template = rrd_template(name: 'Instance two')
    @tab.update!(layout: [['report_by_issues'], ['report_by_issues__1']],
                 settings: { 'report_by_issues' => { 'report_template_id' => template.id },
                             'report_by_issues__1' => { 'report_template_id' => template.id } })

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-report_by_issues iframe.reporter-report-frame--widget', 1
    assert_select '#reporter-block-report_by_issues__1 iframe.reporter-report-frame--widget', 1,
                  'the second instance must render its report, not its settings form'
  end

  def test_a_second_instance_exports_its_own_pdf
    template = rrd_template(name: 'Instance two')
    @tab.update!(layout: [['report_by_issues__1']],
                 settings: { 'report_by_issues__1' => { 'report_template_id' => template.id } })
    RedmineReporterDashboards::WidgetReport.stubs(:render)
                                           .returns(rrd_widget(template, documents: [rrd_document]))

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id,
                               block: 'report_by_issues__1' }

    assert_response :success
    assert_equal 'application/pdf', response.media_type
  end

  # AT THE LIMIT AND ONE PAST IT (CLAUDE.md Phase 3). The suffix is only a name, so the
  # highest instance a dashboard may hold has to render like any other — and the picker
  # has to stop offering a new one at the cap rather than growing without bound.
  def test_the_highest_placeable_instance_renders_and_the_next_is_refused
    template = rrd_template(name: 'Last instance')
    max = RedmineReporterDashboards::ProjectPage::MAX_BLOCK_OCCURS
    names = ['report_by_issues'] + (1...max).map { |i| "report_by_issues__#{i}" }
    assert_equal max, names.size
    last = names.last
    @tab.update!(layout: names.map { |n| [n] },
                 settings: { last => { 'report_template_id' => template.id } })

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select "#reporter-block-#{last} iframe.reporter-report-frame--widget", 1
    # One past the cap: the picker offers no further instance...
    assert_select '#reporter-block-select option[value^=?]', 'report_by_issues__', 0
    # ...and add_block refuses one that is asked for anyway.
    post :add_block, params: { project_id: @project.identifier, tab: @tab.id,
                               block: "report_by_issues__#{max}" }
    assert_response :unprocessable_entity
    assert_equal max, @tab.reload.block_rows.flatten.count { |n| n.start_with?('report_by_issues') }
  end

  # INV-9. The body reaches the page as `srcdoc` ATTRIBUTE data, so a template's own
  # markup can never become an element in the DASHBOARD's document — where it would run
  # with the viewer's session. Asserted on the rendered page rather than on the frame
  # module, because that is the surface the claim is about.
  def test_a_script_in_a_template_does_not_become_markup_in_the_dashboard
    configure_report_widget(rrd_template(content: '<script>alert(1)</script>'))

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-report_by_issues script', 0
    assert_includes css_select('#reporter-block-report_by_issues iframe').first['srcdoc'],
                    '<script>alert(1)</script>'
  end

  # A widget whose stored template no longer resolves must fall through to the settings
  # form — FR-46, and the state every dashboard imported from the base plugin starts in,
  # because its `report_template_id` names one of THAT plugin's rows.
  def test_an_unresolvable_stored_template_falls_through_to_the_settings_form
    rrd_template
    @tab.update!(layout: [['report_by_issues']],
                 settings: { 'report_by_issues' => { 'report_template_id' => 999_999 } })

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#report_by_issues-settings select[name=?]',
                  'settings[report_by_issues][report_template_id]', 1
  end

  # THE PICKER AND THE LOOKUP ARE ONE DEFINITION, asserted through the rendered form: a
  # template the widget would refuse must not be listed as a choice.
  def test_the_settings_form_offers_only_templates_the_widget_can_render
    usable = rrd_template(name: 'Usable')
    rrd_template(name: 'Per record', output: 'per_record')
    rrd_template(name: 'Hours', source: 'time_entries')
    rrd_template(name: 'Private', visibility: rrd_visibility_private)
    @tab.update!(layout: [['report_by_issues']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    options = css_select('#report_by_issues-settings ' \
                         'select[name="settings[report_by_issues][report_template_id]"] option')
              .map(&:text)
    assert_equal ['', usable.name], options
  end

  # The dead end an author meets first: they add the widget, the dropdown is empty, and
  # nothing says why. Both likely reasons — no template written yet, module not enabled —
  # are things the reader can act on.
  def test_an_empty_picker_says_why_rather_than_offering_a_blank_form
    @tab.update!(layout: [['report_by_issues']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#report_by_issues-settings p.nodata',
                  text: I18n.t(:text_reporter_widget_no_templates)
    assert_select '#report_by_issues-settings select', 0
    assert_no_match(/translation missing/i, response.body)
  end

  # A viewer who cannot manage the dashboard gets the empty state, never the form: the
  # settings form writes to the tab, and offering it to somebody whose POST would be
  # refused is a control that cannot work.
  def test_a_viewer_who_cannot_manage_the_page_sees_no_settings_form
    rrd_template
    @tab.update!(layout: [['report_by_issues']])
    Role.find(1).remove_permission! :manage_reporter_project_page

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-report_by_issues p.nodata', 1
    assert_select '#report_by_issues-settings', 0
  end

  # INV-5 on the PAGE this time: a template that cannot render must not put its error
  # where the report goes, must not take the dashboard down, and must keep its own box —
  # and therefore its close button — so it can still be removed.
  def test_a_template_that_fails_to_render_degrades_inside_its_own_box
    configure_report_widget(rrd_template(content: '{% if %}', name: 'Broken'))

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-report_by_issues iframe', 0
    assert_select '#reporter-block-report_by_issues p.reporter-report-diagnostic', 1
    assert_select "#reporter-block-report_by_issues a[href*='remove']", 1
    assert_no_match(/translation missing/i, response.body)
  end

  # A template the viewer may not see must not render on their dashboard either — the
  # export half of this is asserted above, and both go through one lookup.
  def test_a_widget_does_not_render_a_template_its_viewer_cannot_see
    configure_report_widget(rrd_template(visibility: rrd_visibility_private, name: 'Private'))

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
    assert_select '#reporter-block-report_by_issues h3', text: /Private/, count: 0
    assert_select '#reporter-block-report_by_issues iframe', 0
  end

  # A widget must stay removable whatever it renders — a box that renders as nothing
  # loses its own contextual controls and the dashboard keeps it for ever.
  def test_a_report_widget_can_still_be_removed
    @tab.update!(layout: [['report_by_issues']])

    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_select "#reporter-block-report_by_issues a[href*='remove']", 1

    delete :remove_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_empty @tab.reload.block_rows.flatten
  end

  # `find_block` has to keep answering for a placed widget, or it renders as nothing and
  # takes its close button with it. No `degraded` key any more: nothing about these two
  # depends on another plugin being there.
  def test_a_report_widget_resolves_from_the_block_registry
    REPORT_BLOCKS.each do |block|
      definition = RedmineReporterDashboards::ProjectPage.find_block(block)

      refute_nil definition, "#{block} must resolve so its box and delete control survive"
      assert_equal block, definition[:name]
      assert_match %r{\Areporter_project_pages/report_blocks/}, definition[:partial]
    end
  end

  private

  # T-26a helpers. One place that knows what a usable widget template looks like, so the
  # tests above vary the ONE attribute each is about.
  #
  # The author is the administrator on purpose: `visibility: private` then produces a
  # template jsmith genuinely cannot see, rather than one they own.
  def rrd_template(attributes = {})
    RedmineReporterDashboards::Template.create!(
      { project: @project, author: User.find_by!(login: 'admin'),
        name: 'Widget report', content: '<p>ISSUES={{ issues.size }}</p>',
        source: 'issues', output: 'combined',
        visibility: RedmineReporterDashboards::Template::VISIBILITY_PUBLIC }.merge(attributes)
    )
  end

  def rrd_visibility_private
    RedmineReporterDashboards::Template::VISIBILITY_PRIVATE
  end

  def configure_report_widget(template, block: 'report_by_issues')
    @tab.update!(layout: [[block]],
                 settings: { block => { 'report_template_id' => template.id } })
  end

  # A stand-in for what `ReportRun` hands back, built through the real Structs so a change
  # to either shape fails here rather than passing against a double that has drifted.
  def rrd_widget(template, documents: [], diagnostic: nil)
    outcome = RedmineReporterDashboards::Reporting::ReportRun::Outcome.new(
      sections: [], documents: documents, diagnostic: diagnostic, total_count: 1,
      shown_count: 1, truncated: false, duration_ms: 1, degradations: [],
      pdf_attempted: true
    )
    RedmineReporterDashboards::WidgetReport::Widget.new(template: template, query: nil,
                                                        outcome: outcome)
  end

  def rrd_document
    Struct.new(:bytes).new('%PDF-1.4 stub')
  end

  def rrd_diagnostic(origin:, code:)
    RedmineReporterDashboards::Reporting::Diagnostic.new(
      origin: origin, code: code, template_name: 'Widget report',
      message: 'the browser exited while we were waiting for it',
      correlation_id: 'rrd-test-correlation-id'
    )
  end

  # The "(n)" behind a widget title. Asserted on the extracted heading text so a
  # failure shows the rendered title instead of a bare selector count.
  def assert_widget_count(block, expected)
    assert_match(/\(#{expected}\)/, widget_heading(block))
  end

  def widget_count(block)
    heading = widget_heading(block)
    count = heading[/\((\d+)\)/, 1]
    assert count, "Expected widget #{block} to render a count, got #{heading.inspect}"
    count.to_i
  end

  def widget_heading(block)
    heading = css_select("#reporter-block-#{block} h3").first
    assert heading, "Expected widget #{block} to render a heading"
    heading.text.squish
  end

  # Issues tagged with a marker subject, so the count assertions below depend on
  # what the test creates and not on how many issues the fixtures happen to hold.
  def generate_marked_issues(count, attributes = {})
    Array.new(count) do |index|
      Issue.generate!(attributes.merge(project: @project,
                                       subject: "#{ISSUE_COUNT_MARKER} #{index}"))
    end
  end

  # A saved, project-scoped query matching only the marked issues, rendered
  # through the issuequery widget with the given block settings.
  def show_issue_query_widget(settings)
    query = IssueQuery.create!(project: @project,
                               name: 'Marked issues',
                               user: User.find_by!(login: 'jsmith'),
                               filters: { 'subject' => { operator: '~', values: [ISSUE_COUNT_MARKER] } },
                               column_names: %w[tracker status subject])
    @tab.update!(layout: [['issuequery']],
                 settings: { 'issuequery' => settings.merge(query_id: query.id) })

    get :show, params: { project_id: @project.identifier, tab: @tab.id }
  end

  # Make one instance method of a module raise for the duration of the block.
  #
  # Mocha's any_instance lives in Mocha::ClassMethods, which is mixed into Class and
  # not into Module, so `SomeHelper.any_instance` is a NoMethodError. Helper methods
  # are reached through a module, hence swapping the definition by hand.
  def raising_instance_method(mod, name, error = ArgumentError, message = 'boom')
    original = mod.instance_method(name)
    mod.send(:define_method, name) { |*| raise(error, message) }
    yield
  ensure
    mod.send(:define_method, name, original)
  end

end
