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

  def test_report_pdf_reports_a_dependency_failure_as_an_error_not_a_stack_trace
    @tab.update!(layout: [['report_by_issues']],
                 settings: { 'report_by_issues' => { report_template_id: 4242 } })
    ReporterProjectPagesController.any_instance
                                  .stubs(:reporter_report_for)
                                  .raises(ArgumentError, 'wrong number of arguments (given 0, expected 1..2)')

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id,
                               block: 'report_by_issues' }

    assert_response :internal_server_error
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

  def test_report_pdf_without_configured_query_returns_404
    skip_unless_reporter_report_templates_load
    # report_by_issues is a valid block, but the tab has no query/template configured.
    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }
    assert_response :not_found
  end

  # The settings picker offers in_project_and_global(project). The render path and the
  # PDF export used a bare find_by, so a stored report_template_id kept rendering a
  # template the picker would never have listed — and that a project admin cannot see
  # in order to change it. No query is configured here on purpose: the template is
  # resolved in the same expression, before the guard, so the scope is what is under
  # test and Reporter's own template schema stays out of it.
  def test_report_pdf_resolves_the_template_within_the_project_scope
    skip_unless_reporter_report_templates_load
    @tab.update!(layout: [['report_by_issues']],
                 settings: { 'report_by_issues' => { report_template_id: 4242 } })
    IssueListReportTemplate.expects(:in_project_and_global).with(@project)
                           .returns(IssueListReportTemplate.none)

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }

    assert_response :not_found
  end

  def test_report_pdf_for_spent_time_resolves_the_template_within_the_project_scope
    skip_unless_reporter_report_templates_load
    Role.find(1).add_permission! :view_time_entries
    @tab.update!(layout: [['report_by_spent_time']],
                 settings: { 'report_by_spent_time' => { report_template_id: 4242 } })
    TimeEntriesReportTemplate.expects(:in_project_and_global).with(@project)
                             .returns(TimeEntriesReportTemplate.none)

    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id,
                               block: 'report_by_spent_time' }

    assert_response :not_found
  end

  # at_least_once: with nothing resolvable the widget falls back to its settings
  # form, which asks for the same scope again.
  def test_dashboard_resolves_the_report_template_within_the_project_scope
    skip_unless_reporter_report_templates_load
    @tab.update!(layout: [['report_by_issues']],
                 settings: { 'report_by_issues' => { report_template_id: 4242 } })
    IssueListReportTemplate.expects(:in_project_and_global).with(@project).at_least_once
                           .returns(IssueListReportTemplate.none)

    get :show, params: { project_id: @project.identifier, tab: @tab.id }

    assert_response :success
  end

  private

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
