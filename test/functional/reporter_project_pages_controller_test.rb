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

    compatible_xhr_request :post, :update_page, project_id: @project.identifier, tab: @tab.id, settings: 'invalid'

    assert_response :success
    assert_equal({}, @tab.reload.block_settings)
  end

  def test_update_page_ignores_unknown_block_settings
    compatible_xhr_request :post, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { unknown: { limit: '50' } }

    assert_response :success
    assert_equal({}, @tab.reload.block_settings)
  end

  def test_update_page_saves_valid_block_settings
    @tab.update!(layout: [['news']])

    compatible_xhr_request :post, :update_page, project_id: @project.identifier, tab: @tab.id,
                                                settings: { news: { limit: '10' } }

    assert_response :success
    assert_equal '10', @tab.reload.block_settings('news')[:limit]
  end

  def test_move_block_ignores_absent_block
    @tab.update!(layout: [['news']])

    post :move_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'activity', direction: 'up' }

    assert_response :redirect
    assert_equal [['news']], @tab.reload.block_rows
  end

  def test_move_block_reorders_within_row
    @tab.update!(layout: [['news', 'activity']])

    post :move_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'activity', direction: 'left' }

    assert_response :redirect
    assert_equal [['activity', 'news']], @tab.reload.block_rows
  end

  def test_move_block_up_merges_rows
    @tab.update!(layout: [['news'], ['activity']])

    post :move_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'activity', direction: 'up' }

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

    post :remove_block, params: { project_id: @project.identifier, tab: @tab.id, block: 'news' }

    assert_response :redirect
    refute_includes @tab.reload.block_rows.flatten, 'news'
  end

  def test_show_requires_dashboard_module
    @project.disable_module!(:reporter_project_dashboards)
    get :show, params: { project_id: @project.identifier, tab: @tab.id }
    assert_response :not_found
  end

  def test_show_creates_default_tab_when_module_enabled_without_tabs
    @project.reporter_project_tabs.destroy_all

    assert_difference 'ReporterProjectTab.count', 1 do
      get :show, params: { project_id: @project.identifier }
    end
    assert_response :success
    assert_select '.tabs a.selected', I18n.t(:label_reporter_default_dashboard_tab)
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
    # report_by_issues is a valid block, but the tab has no query/template configured.
    get :report_pdf, params: { project_id: @project.identifier, tab: @tab.id, block: 'report_by_issues' }
    assert_response :not_found
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
end
