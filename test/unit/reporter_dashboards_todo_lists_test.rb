# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# `issue.todolists_with_positions` — the to-do lists of redmine_issue_todo_lists2 in a report
# template, offered by THIS plugin (Jan's decision, 2026-10-07, round 2).
#
# THE QUESTION IS WHO MAY SEE A LIST. The issue ids come from the viewer's visible scope, but
# that says nothing about the lists: a developer may see an issue in a project where their
# role may not view to-do lists. The answer has to be the todo plugin's own rule
# (`IssueTodoList.visible(actor)`), asked as the report's actor, and the two actors below
# see the SAME issue with DIFFERENT lists.
#
# THE TWO HALVES ARE DEFINED CONDITIONALLY, NOT SKIPPED. The todo plugin is optional and CI
# runs this plugin alone, so the with-plugin cases cannot run there; a `skip` would add to
# G10's inventory for a configuration that is not unsupported, merely absent. So each half
# exists only in the configuration it describes, and the case that holds in both runs always.
class ReporterDashboardsTodoListsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :issues, :issue_statuses, :trackers, :projects_trackers,
           :enumerations

  Template = RedmineReporterDashboards::Template
  ReportRun = RedmineReporterDashboards::Reporting::ReportRun
  Batch = RedmineReporterDashboards::Liquid::Batch

  LISTS = '{% for issue in issues %}{{ issue.id }}:' \
          '{% for l in issue.todolists_with_positions.items %}[{{ l.title }}@{{ l.position }}]{% endfor %}' \
          '({{ issue.todolists_with_positions.size }});{% endfor %}'

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @admin = User.find_by!(login: 'admin')
    User.current = nil
    build_lists if respond_to?(:build_lists, true)
  end

  def teardown
    User.current = nil
  end

  def render(actor, issue_ids, content: LISTS)
    template = Template.create!(project: @project, author: @admin, name: "todo-#{SecureRandom.hex(4)}",
                                content: content, source: 'issues', output: 'combined',
                                visibility: Template::VISIBILITY_PUBLIC)
    scope = Issue.visible(actor).where(id: issue_ids).order(:id)
    outcome = ReportRun.new(template: template, actor: actor, scope: scope,
                            guard: RedmineReporterDashboards::Render::BatchGuard.new)
                       .call(pdf: false)
    assert_nil outcome.diagnostic, outcome.diagnostic&.message
    outcome.sections.first.body.strip
  end

  def statements_on(table)
    statements = []
    counter = lambda do |_name, _start, _finish, _id, payload|
      statements << payload[:sql] if payload[:sql].to_s.include?(table)
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    statements
  end

  # Holds with and without the todo plugin: an issue on no list the viewer may see renders
  # an empty list and a zero, and the report does not fail.
  def test_an_issue_on_no_visible_list_renders_an_empty_list
    assert_equal '2:(0);', render(@admin, [2])
  end

  if Batch.todo_lists_available?
    def build_lists
      @project.enable_module!(:issue_todo_lists)
      Role.find(1).add_permission!(:view_issue_todo_lists)    # Manager: jsmith on project 1
      Role.find(2).remove_permission!(:view_issue_todo_lists) # Developer: dlopper on project 1
      @manager = User.find(2)
      @developer = User.find(3)
      @sprint = IssueTodoList.create!(project: @project, title: 'Sprint 12')
      @backlog = IssueTodoList.create!(project: @project, title: 'Backlog')
      IssueTodoListItem.create!(issue_todo_list: @sprint, issue_id: 1, position: 2)
      IssueTodoListItem.create!(issue_todo_list: @backlog, issue_id: 1, position: 5)
      IssueTodoListItem.create!(issue_todo_list: @backlog, issue_id: 3, position: 1)
    end

    def test_a_viewer_with_the_permission_sees_the_lists_and_positions
      assert_equal '1:[Backlog@5][Sprint 12@2](2);3:[Backlog@1](1);', render(@manager, [1, 3])
    end

    def test_a_viewer_without_the_permission_sees_the_issue_but_no_list
      assert @developer.allowed_to?(:view_issues, @project), 'precondition: the developer sees the issues'
      assert_equal '1:(0);3:(0);', render(@developer, [1, 3])
    end

    def test_a_list_in_a_project_without_the_module_is_not_shown
      @project.enabled_module_names = @project.enabled_module_names - ['issue_todo_lists']
      assert_equal '1:(0);', render(@manager, [1])
    end

    # The case that matters: the LIST's project decides, not the issue's. jsmith is Manager
    # in project 1 and Developer in project 2, and a project-2 list holds a project-1 issue.
    def test_a_list_in_another_project_follows_the_permission_there
      onlinestore = Project.find(2)
      onlinestore.enable_module!(:issue_todo_lists)
      elsewhere = IssueTodoList.create!(project: onlinestore, title: 'Elsewhere')
      IssueTodoListItem.create!(issue_todo_list: elsewhere, issue_id: 1, position: 1)

      assert_equal '1:[Backlog@5][Sprint 12@2](2);', render(@manager, [1])

      Role.find(2).add_permission!(:view_issue_todo_lists)
      Role.find(1).remove_permission!(:view_issue_todo_lists)
      assert_equal '1:[Elsewhere@1](1);', render(User.find(2), [1])
    end

    # A text item has no issue; it belongs to no issue's lists and breaks nothing.
    def test_a_text_item_on_the_same_list_is_ignored
      IssueTodoListItem.create!(issue_todo_list: @sprint, issue_id: nil, position: 3)
      assert_equal '1:[Backlog@5][Sprint 12@2](2);', render(@manager, [1])
    end

    # A share link or a public report renders as anonymous: the issue is public, the lists are not.
    def test_anonymous_sees_the_public_issue_but_no_list
      assert_equal '1:(0);', render(User.anonymous, [1])
    end

    def test_the_admin_sees_every_list
      assert_equal '1:[Backlog@5][Sprint 12@2](2);', render(@admin, [1])
    end

    # FR-48: one query for the items of the whole report, however many issues it holds.
    def test_the_lists_cost_one_query_per_report_not_one_per_issue
      render(@manager, [1]) # warm-up
      one = statements_on('issue_todo_list_items') { render(@manager, [1]) }
      three = statements_on('issue_todo_list_items') { render(@manager, [1, 2, 3]) }

      assert_equal 1, one.length, one.join("\n")
      assert_equal one.length, three.length, three.join("\n")
    end

    def test_the_url_names_the_lists_project_and_id
      out = render(@manager, [3], content: '{% for issue in issues %}' \
                                           '{{ issue.todolists_with_positions.first.url }}{% endfor %}')
      assert out.end_with?("/projects/ecookbook/issue_todo_lists/#{@backlog.id}"), out
    end
  else
    # Without the todo plugin nothing touches its tables: the accessor answers before asking.
    def test_without_the_todo_plugin_no_query_names_its_tables
      assert_not Batch.todo_lists_available?
      queries = statements_on('issue_todo_list') { render(@admin, [1, 2, 3]) }
      assert_equal [], queries
    end
  end
end
