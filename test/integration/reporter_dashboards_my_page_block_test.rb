# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-26a increment 3 — the my-page report widgets, rendered the way Redmine renders them.
#
# --- WHY THIS FILE EXISTS AT ALL ---
#
# This plugin ships `app/views/my/blocks/_report_by_{issues,spent_time}.erb`, and those
# paths are not an implementation detail: Redmine core DISCOVERS my-page blocks by globbing
# plugin view directories.
#
#     # redmine/lib/redmine/my_page.rb — THIS LINE is byte-identical on 5.1 and 7.0
#     Dir.glob("#{Redmine::Plugin.directory}/*/app/views/my/blocks/_*.{rhtml,erb}")
#
# The scoping matters: the FILE is not identical across that span (the line after the glob
# moved from `gsub(/^_/, '')` to `delete_prefix('_')`), and an earlier version of this
# comment claimed it was. The glob is the load-bearing half.
#
# So the mere PRESENCE of those files makes this plugin contribute two core my-page blocks
# on every install, with no line in `init.rb` anywhere. And core's
# `MyHelper#render_block_content` rescues **only** `ActionView::MissingTemplate`
# (`app/helpers/my_helper.rb:59`), so anything else propagates: not a broken widget but a
# **500 on `/my/page`** — the very page a user would need in order to remove the block.
# That is §Findings **E-39**, measured, and it is why these partials carry their own rescue.
#
# --- WHAT CHANGED, AND WHAT THIS FILE USED TO BE ---
#
# It used to be a file about a GUARD. The widget rendered one of redmine_reporter's report
# templates, so it named `IssueListReportTemplate` — undefined on a standalone install, and
# unloadable on Redmine 7.0 even where the plugin IS installed (its `enum` uses the keyword
# form Rails 8.0 removed). Every example here was about detecting that and degrading.
#
# None of that is reachable now: the widgets are this plugin's own. `WidgetReport` resolves
# through `Template.visible(actor)` and `Reporting::ReportRun` renders. The rescue stays —
# core's behaviour has not changed and an unknown defect in our own body would take the page
# down exactly the same way — but it is now a backstop rather than the subject.
#
# An integration test is the only level at which any of this is visible: nothing here is
# reachable from a controller test, because the block is discovered from the filesystem and
# rendered through core's helper, in core's view context, where THIS PLUGIN'S HELPERS DO NOT
# EXIST (`include_all_helpers = false`). That last point is the one a unit test cannot make.
class ReporterDashboardsMyPageBlockTest < Redmine::IntegrationTest
  include Redmine::I18n

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers,
           :queries, :time_entries

  BLOCK = 'report_by_issues'
  TIME_BLOCK = 'report_by_spent_time'

  Template = RedmineReporterDashboards::Template

  def setup
    @jsmith = User.find_by!(login: 'jsmith')
    @admin = User.find_by!(login: 'admin')
    @project = Project.find(1)
    # LOCALE IS PINNED, NOT INHERITED. The request locale comes from `User#language`,
    # sourced from Redmine's own BRANCH-VERSIONED `test/fixtures/users.yml`, so an
    # assertion on `l(...)` otherwise depends on what that fixture happens to say on
    # whichever Redmine is checked out — the inheritance §6 forbids.
    @jsmith.update_column(:language, 'en')
    # THE MODULE IS A PRECONDITION OF VISIBILITY, not decoration: `Template.visible` goes
    # through `Project.allowed_to_condition`, which requires the permission's module to be
    # enabled — so without this even an administrator resolves NOTHING and the failure
    # reads like a broken scope.
    @project.enable_module!(:reporter_dashboards_reports)
    Role.find(1).add_permission! :view_reporter_dashboards_reports
    User.current = nil
    log_user('jsmith', 'jsmith')
  end

  def teardown
    User.current = nil
  end

  # THE PREMISE, asserted rather than assumed. If core ever stops globbing plugin view
  # directories this whole file becomes moot, and it should say so out loud rather than keep
  # passing for a reason that has gone away.
  def test_core_discovers_both_partials_as_my_page_blocks
    assert Redmine::MyPage.blocks.key?(BLOCK),
           "core no longer registers this plugin's my/blocks partial — if that is " \
           'deliberate, this file and the guard it covers can go'
    assert_equal 'my/blocks/report_by_issues', Redmine::MyPage.blocks[BLOCK][:partial]
    assert Redmine::MyPage.blocks.key?(TIME_BLOCK),
           'the spent-time block is new in T-26a increment 3 and is registered by its path'
  end

  # ------------------------------------------------------------------ it renders

  # THE END-TO-END CASE, and the one nothing could assert while the render belonged to
  # another plugin: a configured my-page widget renders its report, in its own sandboxed
  # frame, on a Redmine with no base plugin installed at all.
  def test_a_configured_widget_renders_its_report_in_the_sandboxed_frame
    template = my_page_template(name: 'Across projects')
    configure_block(template)

    get '/my/page'

    assert_response :success
    assert_select "#block-#{BLOCK} h3", /Across projects/
    frame = css_select("#block-#{BLOCK} iframe.reporter-report-frame--widget").first
    assert frame, 'the report must be rendered inside the opaque-origin frame'
    assert_equal 'allow-scripts', frame['sandbox'],
                 'allow-same-origin would let template JavaScript read the viewer session'
    assert_includes frame['srcdoc'], "ISSUES=#{Issue.visible(@jsmith).count}"
    assert_no_match(/translation missing/i, response.body)
  end

  # THE SCOPE IS EVERY ISSUE THE VIEWER CAN SEE, because my-page has no project and this
  # widget names no saved query. Asserted against a SECOND project so a single-project
  # answer cannot pass: the count above would be the same either way with one project.
  def test_with_no_query_the_report_covers_every_project_the_viewer_can_see
    other = Project.find(5)
    other.enable_module!(:issue_tracking)
    assert Issue.visible(@jsmith).where(project_id: other.id).exists?,
           'precondition: jsmith must see issues outside project 1'
    configure_block(my_page_template(name: 'Everything'))

    get '/my/page'

    assert_response :success
    frame = css_select("#block-#{BLOCK} iframe").first
    assert_includes frame['srcdoc'], "ISSUES=#{Issue.visible(@jsmith).count}"
    assert_operator Issue.visible(@jsmith).count, :>,
                    Issue.visible(@jsmith).where(project_id: @project.id).count
  end

  # INV-9. The body reaches the page as `srcdoc` ATTRIBUTE data, so a template's own markup
  # can never become an element in MY PAGE's document, where it would run with the viewer's
  # session. Asserted on the rendered page, because that is the surface the claim is about.
  def test_a_script_in_a_template_does_not_become_markup_in_my_page
    configure_block(my_page_template(content: '<script>alert(1)</script>'))

    get '/my/page'

    assert_response :success
    assert_select "#block-#{BLOCK} script", 0
    assert_includes css_select("#block-#{BLOCK} iframe").first['srcdoc'],
                    '<script>alert(1)</script>'
  end

  # ------------------------------------------------------------------ what it offers

  # THE GAP THIS CLOSES. The base plugin's my-page picker was `IssueListReportTemplate.all`
  # — every report template in the instance, offered to every user, because that model has
  # no visibility rule at all (verified against its source, 2026-08-12). Ours is
  # `Template.visible(actor)`: the role permission per project, plus the template's own
  # private/roles/public visibility. The precondition is asserted rather than trusted.
  def test_the_picker_offers_only_templates_the_viewer_may_see
    mine = my_page_template(name: 'Visible to me')
    hidden = Template.create!(project: @project, author: @admin, name: 'Private to admin',
                              content: '<p>x</p>', source: 'issues', output: 'combined',
                              visibility: Template::VISIBILITY_PRIVATE)
    assert_not Template.visible(@jsmith).exists?(hidden.id),
               'precondition: jsmith must not be able to see this template'
    put_block_on_my_page

    get '/my/page'

    assert_response :success
    options = css_select("#block-#{BLOCK} " \
                         "select[name=\"settings[#{BLOCK}][report_template_id]\"] option")
              .map(&:text)
    assert_equal ['', mine.name], options
  end

  # A template in a project this viewer is not a member of must not be offered — the same
  # rule, one level out from the private/public column.
  def test_a_template_in_an_unreachable_project_is_not_offered
    # PROJECT 6, MEASURED: jsmith is a member of 1, 2 and 5 in Redmine's own fixtures, so
    # the obvious "some other project" is one he can reach and this test would be vacuous.
    other = Project.find(6)
    other.enable_module!(:reporter_dashboards_reports)
    foreign = Template.create!(project: other, author: @admin, name: 'Other project',
                               content: '<p>x</p>', source: 'issues', output: 'combined',
                               visibility: Template::VISIBILITY_PUBLIC)
    assert_not @jsmith.member_of?(other), 'precondition: jsmith must not be a member here'
    assert_not Template.visible(@jsmith).exists?(foreign.id),
               'precondition: the template must be genuinely out of reach'
    put_block_on_my_page

    get '/my/page'

    assert_response :success
    assert_select "#block-#{BLOCK} option", text: 'Other project', count: 0
  end

  # A GLOBAL TEMPLATE IS OFFERED WITHOUT A PROJECT AT ALL, which is the case `project: nil`
  # exists for — it used to mean "global only" and now means "no project bound", and this is
  # the half that must keep working either way.
  def test_a_global_template_is_offered
    global = Template.create!(project: nil, author: @admin, name: 'Global report',
                              content: '<p>x</p>', source: 'issues', output: 'combined',
                              visibility: Template::VISIBILITY_PUBLIC)
    put_block_on_my_page

    get '/my/page'

    assert_response :success
    assert_select "#block-#{BLOCK} option", text: global.name, count: 1
  end

  # The dead end an author meets first: they add the widget, the dropdown is empty, and
  # nothing says why. The base plugin's settings partial did worse than that — its heading
  # was `queries.first.is_a?(IssueQuery)`, which RAISES on an empty picker, which on this
  # surface is a 500.
  def test_an_empty_picker_says_why_rather_than_offering_a_blank_form
    put_block_on_my_page

    get '/my/page'

    assert_response :success
    assert_select "#block-#{BLOCK} p.nodata",
                  text: I18n.t(:text_reporter_widget_no_templates)
    assert_select "#block-#{BLOCK} select", 0
    assert_no_match(/translation missing/i, response.body)
  end

  # ------------------------------------------------------------------ the spent-time block

  def test_the_spent_time_block_renders_for_an_actor_who_may_see_hours
    Role.find(1).add_permission! :view_time_entries
    template = my_page_template(name: 'Hours', source: 'time_entries',
                                content: '<p>HOURS={{ time_entries.size }}</p>')
    configure_block(template, block: TIME_BLOCK)

    get '/my/page'

    assert_response :success
    frame = css_select("#block-#{TIME_BLOCK} iframe.reporter-report-frame--widget").first
    assert frame, 'the spent-time report must render inside the opaque-origin frame'
    assert_includes frame['srcdoc'], "HOURS=#{TimeEntry.visible(@jsmith).count}"
  end

  # `:view_time_entries` IS ASKED GLOBALLY HERE, because my-page has no project to ask it
  # about. Refusing renders the placeholder rather than nothing, so the block keeps the
  # contextual controls that carry its own close button.
  def test_the_spent_time_block_is_refused_without_the_time_entries_permission
    # EVERY ROLE, and that is what "globally" means. Measured: five roles grant
    # `view_time_entries` in Redmine's fixtures, two of them BUILTIN (Non member,
    # Anonymous) — and a builtin role applies on every public project this actor is not a
    # member of. Removing it from Manager alone left `allowed_to?(global: true)` true and
    # the widget rendered, which is the version of this test that proves nothing.
    Role.all.each { |role| role.remove_permission! :view_time_entries }
    assert_not @jsmith.allowed_to?(:view_time_entries, nil, global: true),
               'precondition: the actor must not be able to see hours anywhere'
    configure_block(my_page_template(name: 'Hours', source: 'time_entries'),
                    block: TIME_BLOCK)

    get '/my/page'

    assert_response :success
    assert_select "#block-#{TIME_BLOCK} iframe", 0
    assert_select "#block-#{TIME_BLOCK} p.nodata", 1
  end

  # §Findings S-14, ACROSS PROJECTS. The project-scoped notice answers `:none` for a nil
  # project, so used here it would tell a reader their role does not let them see spent time
  # "in this project" over a report drawing on several — a false sentence, which is worse
  # than the silence S-14 exists to remove.
  def test_an_own_only_role_is_told_the_report_mixes_its_own_hours_in
    role = Role.find(1)
    role.add_permission! :view_time_entries
    role.update_column(:time_entries_visibility, 'own')
    assert_equal :own,
                 RedmineReporterDashboards::Reporting::TimeEntryVisibility
                   .state_across_projects(@jsmith),
                 'precondition: the actor must be in the own-only state'
    configure_block(my_page_template(name: 'Hours', source: 'time_entries'),
                    block: TIME_BLOCK)

    get '/my/page'

    assert_response :success
    assert_select "#block-#{TIME_BLOCK} p.warning",
                  text: I18n.t(:text_reporter_time_entries_own_only_across_projects)
  end

  # ------------------------------------------------------------------ it never 500s

  # THE REGRESSION THIS FILE WAS WRITTEN FOR. Core rescues only `ActionView::MissingTemplate`,
  # so any other exception from a block body is a 500 on `/my/page` — and the page that
  # 500s is the one carrying the block's own close button.
  #
  # The failure is injected at the MODULE the partial calls rather than at a database, for
  # the reason HANDOVER §1 records: a failed statement aborts the enclosing PostgreSQL
  # transaction, and transactional fixtures wrap the whole request in one — so every later
  # query in that request fails no matter what the rescue does, and the assertion would be
  # about the harness rather than about the code.
  def test_a_raising_widget_body_is_rescued_and_the_page_still_renders
    configure_block(my_page_template)
    subject = RedmineReporterDashboards::WidgetReport
    subject.stubs(:render_for_my_page).raises(RuntimeError, 'rrd probe failure')

    log = capturing_rails_log { get '/my/page' }

    assert_response :success
    assert_select "#block-#{BLOCK} p.nodata",
                  text: I18n.t(:error_reporter_widget_render_failed)
    assert_includes log, 'rrd probe failure'
  end

  # `ScriptError` IS NOT A `StandardError`, and a bare `rescue` would miss it. A class body
  # that fails to parse raises `SyntaxError` and a bad `require` raises `LoadError`; both
  # reach a view exactly as fatally as a `NameError`.
  def test_a_script_error_in_the_widget_body_is_rescued_too
    configure_block(my_page_template)
    RedmineReporterDashboards::WidgetReport.stubs(:render_for_my_page)
                                           .raises(NotImplementedError, 'rrd script error')

    get '/my/page'

    assert_response :success
    assert_select "#block-#{BLOCK} p.nodata",
                  text: I18n.t(:error_reporter_widget_render_failed)
  end

  # A widget that renders as nothing loses its own contextual controls, and the user is left
  # with a block they can no longer remove. The placeholder keeps the box.
  def test_a_degraded_block_keeps_its_close_button_and_can_be_removed
    configure_block(my_page_template)
    RedmineReporterDashboards::WidgetReport.stubs(:render_for_my_page)
                                           .raises(RuntimeError, 'rrd probe failure')

    get '/my/page'

    assert_response :success
    assert_select "#block-#{BLOCK} .contextual a.icon-close[href*=?]", 'remove_block'

    post '/my/remove_block', params: { block: BLOCK }

    assert_not_includes @jsmith.reload.pref.my_page_layout.values.flatten, BLOCK
  end

  private

  # A real logger, not a Mocha matcher with a side effect in it. Nothing in Mocha's contract
  # says a `with { }` block runs exactly once per call — it is also consulted when composing
  # failure messages — so counting lines inside one depends on an implementation detail of
  # the pinned version, and stubbing `warn` wholesale swallows unrelated warnings.
  def capturing_rails_log
    buffer = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(buffer)
    yield
    buffer.string
  ensure
    Rails.logger = original
  end

  def my_page_template(name: 'My page report', content: '<p>ISSUES={{ issues.size }}</p>',
                       source: 'issues')
    Template.create!(project: @project, author: @admin, name: name, content: content,
                     source: source, output: 'combined',
                     visibility: Template::VISIBILITY_PUBLIC)
  end

  def put_block_on_my_page(block: BLOCK)
    pref = @jsmith.pref
    pref.my_page_layout = { 'left' => [block], 'right' => [] }
    pref.save!
  end

  def configure_block(template, block: BLOCK)
    pref = @jsmith.pref
    pref.my_page_layout = { 'left' => [block], 'right' => [] }
    pref.my_page_settings = { block => { report_template_id: template.id } }
    pref.save!
  end
end
