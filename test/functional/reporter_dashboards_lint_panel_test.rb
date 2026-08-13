# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-37 / FR-71 — THE EDITOR'S LINT PANEL, AND THE PARITY CLAUSE THAT KEEPS IT HONEST.
#
# T-37's `Accept:` line: *"the editor's findings panel is fed by **the same linter object**
# the rake task calls — asserted by a test that runs both over one fixture and compares the
# finding lists, so the two can never diverge; findings carry **line and column** and are
# listed in a server-rendered panel beside the editor, each one naming its position."*
#
# --- WHY THIS IS A SEPARATE FILE ---
#
# `reporter_dashboards_templates_controller_test.rb` is 2 000 lines about permissions and
# visibility, and its subject is what a role reaches. This file's subject is one panel and
# the promise that two surfaces cannot drift, which is a different question and would be
# invisible at the bottom of that file.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods defined after a `private` section are silently not run. There is no
# `private` here; every helper is above the tests.
class ReporterDashboardsLintPanelTest < ActionController::TestCase
  # NAMED EXPLICITLY: the controller is namespaced and the test class is not, so Rails'
  # inference would look for a class that does not exist.
  tests ReporterDashboards::TemplatesController

  include Redmine::I18n

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  Template = RedmineReporterDashboards::Template
  Linter = RedmineReporterDashboards::TemplateLinter
  LintReport = RedmineReporterDashboards::LintReport

  # A body carrying FOUR DIFFERENT RULES at four different positions, including two on one
  # line so the collapsing and the `count` are exercised, and one indented so a column of
  # 1 cannot pass by accident.
  #
  # `\n` rather than a heredoc: the assertions below are about exact lines and columns, and
  # a heredoc's indentation handling is one more thing between the test and the number.
  DIRTY_BODY = "<p>[page] and [topage]</p>\n" \
               "<script>\n" \
               "  xAxes: []\n" \
               "  window.status = 'x';\n" \
               "  var s = \"{{ issue.subject }}\";\n" \
               "</script>\n"

  CLEAN_BODY = "<h1>{{ project.name }}</h1>\n<p>{{ issue.subject }}</p>\n"

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @jsmith = User.find_by!(login: 'jsmith')
    @role = Role.find(1)
    @role.permissions = %w[view_issues view_reporter_dashboards_reports
                           add_reporter_dashboards_templates
                           edit_reporter_dashboards_templates
                           manage_public_reporter_dashboards_templates]
    @role.save!
    User.current = nil
    @request.session[:user_id] = @jsmith.id
  end

  # ------------------------------------------------------------------ helpers

  def create_template(attributes = {})
    attributes = attributes.dup
    roles = attributes.delete(:roles)
    record = Template.new({ project: @project, author: @jsmith, name: 'Report',
                            content: CLEAN_BODY, source: 'issues',
                            output: 'combined' }.merge(attributes))
    record.roles = Array(roles)
    record.save!
    record
  end

  def template_params(overrides = {})
    { name: 'Report', content: CLEAN_BODY, output: 'combined',
      orientation: 'portrait', page_size: 'A4', enabled: '1' }.merge(overrides)
  end

  # THE RAKE TASK'S OWN DATA STEP, called the way the task calls it. `LintReport.analyse`
  # is what `rake reporter_dashboards:lint_templates` maps its rows through, and
  # `test/unit/reporter_dashboards_lint_rake_test.rb` is what proves the task really calls
  # it — so between the two files there is no gap where a second linter could live.
  def rake_findings(body)
    LintReport.analyse([['#1 Report', body]]).first.analysis.findings
  end

  # ------------------------------------------------------------------ the parity clause

  # THE CLAUSE, ASSERTED AS AN EQUALITY OF LISTS AND NOT OF TEXT. Two surfaces that agree
  # on a paragraph while disagreeing about a finding is exactly the drift this is for, so
  # the comparison is over the Findings themselves — rule, severity, line, column, excerpt,
  # message and count, all seven, because `Struct#==` compares every member.
  def test_the_panel_and_the_rake_task_report_the_same_finding_list
    template = create_template(content: DIRTY_BODY)

    get :edit, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_equal rake_findings(DIRTY_BODY), assigns(:lint).findings
  end

  # …AND THE LIST IS NOT EMPTY, because two empty lists are also equal. The test above
  # would pass against a panel that linted nothing at all and a rake task that did the
  # same, which is the shape of vacuous test this project keeps finding in its own work.
  def test_the_fixture_really_produces_findings_so_the_parity_test_cannot_be_vacuous
    findings = rake_findings(DIRTY_BODY)

    assert_equal 4, findings.length, 'the fixture body stopped producing four findings'
    assert_includes findings.map(&:rule), 'footer.engine_page_token'
    assert_includes findings.map(&:rule), 'chartjs2.scales_axes'
    assert_includes findings.map(&:rule), 'handshake.window_status'
    assert_includes findings.map(&:rule), 'script.unfiltered_interpolation'
  end

  # The same equality on the PREVIEW path, which lints the request body rather than the
  # stored one. This is the surface an author actually uses, and it is a different code
  # path — `preview_subject` builds an unsaved copy.
  def test_the_preview_lints_the_submitted_body_and_not_the_stored_one
    template = create_template(content: CLEAN_BODY)

    post :preview, params: { project_id: @project.identifier, id: template.id,
                             template: template_params(content: DIRTY_BODY) }

    assert_response :success
    assert_equal rake_findings(DIRTY_BODY), assigns(:lint).findings
    assert_equal CLEAN_BODY, template.reload.content
  end

  # ------------------------------------------------------------------ line and column

  def test_every_finding_carries_a_line_and_a_column
    template = create_template(content: DIRTY_BODY)

    get :edit, params: { project_id: @project.identifier, id: template.id }

    assigns(:lint).findings.each do |finding|
      assert_kind_of Integer, finding.line, finding.rule
      assert_kind_of Integer, finding.column, finding.rule
      assert_operator finding.column, :>=, 1, finding.rule
    end
  end

  # THE NUMBER IS IN THE PAGE, not merely on the object. A panel that computed a column and
  # rendered only the line would satisfy every assertion above it.
  def test_the_panel_prints_the_position_of_each_finding
    template = create_template(content: DIRTY_BODY)

    get :edit, params: { project_id: @project.identifier, id: template.id }

    positions = assigns(:lint).findings.map(&:position)
    assert_includes positions, '3:3', 'the indented xAxes finding lost its column'
    positions.each { |position| assert_include position, response.body }
  end

  def test_the_panel_prints_the_rule_and_the_authors_own_line
    template = create_template(content: DIRTY_BODY)

    get :edit, params: { project_id: @project.identifier, id: template.id }

    assert_include 'chartjs2.scales_axes', response.body
    assert_include ERB::Util.html_escape('<p>[page] and [topage]</p>'), response.body
  end

  # `collapse` keeps one row per (rule, line) with a count, so the row has to say so or the
  # panel understates the work by exactly the factor the collapsing saved.
  def test_a_line_carrying_a_rule_twice_says_how_many_times
    template = create_template(content: DIRTY_BODY)

    get :edit, params: { project_id: @project.identifier, id: template.id }

    footer = assigns(:lint).findings.find { |f| f.rule == 'footer.engine_page_token' }
    assert_equal 2, footer.count
    assert_include ERB::Util.html_escape(l(:text_reporter_lint_repeated, count: 2)), response.body
  end

  # ------------------------------------------------------------------ where it appears

  def test_the_panel_is_on_the_new_form_of_a_template_that_does_not_exist_yet
    get :new, params: { project_id: @project.identifier }

    assert_response :success
    assert_select 'div#reporter-template-lint'
    assert_select 'p#reporter-template-lint-clean'
  end

  def test_the_panel_is_on_the_edit_form
    template = create_template(content: DIRTY_BODY)

    get :edit, params: { project_id: @project.identifier, id: template.id }

    assert_select 'div#reporter-template-lint table.list tbody tr', minimum: 4
  end

  def test_the_panel_is_on_the_preview_page
    post :preview, params: { project_id: @project.identifier,
                             template: template_params(content: DIRTY_BODY) }

    assert_response :success
    assert_select 'div#reporter-template-lint table.list tbody tr', minimum: 4
  end

  # A REJECTED SAVE RE-RENDERS THE EDITOR, so it needs the panel too — and if `@lint` were
  # nil there the partial would raise, which is a 500 on an ordinary validation error.
  def test_the_panel_survives_a_rejected_create
    post :create, params: { project_id: @project.identifier,
                            template: template_params(name: '', content: DIRTY_BODY) }

    assert_response :unprocessable_entity
    assert_select 'div#reporter-template-lint table.list tbody tr', minimum: 4
  end

  def test_the_panel_survives_a_rejected_update
    template = create_template

    patch :update, params: { project_id: @project.identifier, id: template.id,
                             template: template_params(name: '', content: DIRTY_BODY) }

    assert_response :unprocessable_entity
    assert_select 'div#reporter-template-lint table.list tbody tr', minimum: 4
  end

  # A preview refused BEFORE it ran — a page size the render would raise on — still shows
  # the findings, because the author is looking at the editor and one problem must not take
  # the other list away.
  def test_a_preview_refused_for_a_bad_page_size_still_shows_the_findings
    post :preview, params: { project_id: @project.identifier,
                             template: template_params(content: DIRTY_BODY, page_size: 'A9') }

    assert_response :unprocessable_entity
    assert_nil assigns(:outcome)
    assert_select 'div#reporter-template-lint table.list tbody tr', minimum: 4
  end

  # ------------------------------------------------------------------ the clean state

  # AN EMPTY PANEL IS INDISTINGUISHABLE FROM ONE THAT DID NOT RUN, and the author has just
  # been told this template executes server-side code. "Nothing found" is the sentence they
  # are looking for.
  def test_a_clean_template_says_so_rather_than_showing_an_empty_table
    template = create_template(content: CLEAN_BODY)

    get :edit, params: { project_id: @project.identifier, id: template.id }

    assert_empty assigns(:lint).findings
    assert_select 'p#reporter-template-lint-clean'
    assert_select 'div#reporter-template-lint table.list', false
  end

  def test_the_panel_names_the_rake_task_so_the_other_surface_can_be_found
    get :new, params: { project_id: @project.identifier }

    assert_include 'reporter_dashboards:lint_templates', response.body
  end

  # ------------------------------------------------------------------ the bound

  # A bad paste produces hundreds of findings and a page that renders all of them is a page
  # nobody can fix the first one from. AT the bound and one past it, and the count above
  # the table stays COMPLETE — the truncation is stated, never a quietly shorter list.
  def test_the_panel_is_bounded_and_says_so
    cap = ReporterDashboards::TemplatesHelper::PANEL_MAX_FINDINGS
    body = (1..(cap + 5)).map { |n| "<p>line #{n} [page]</p>" }.join("\n")
    template = create_template(content: body)

    get :edit, params: { project_id: @project.identifier, id: template.id }

    assert_equal cap + 5, assigns(:lint).findings.length
    assert_select 'div#reporter-template-lint table.list tbody tr', count: cap
    assert_include ERB::Util.html_escape(l(:text_reporter_template_lint_more, count: 5)),
                   response.body
  end

  def test_exactly_at_the_bound_nothing_is_hidden
    cap = ReporterDashboards::TemplatesHelper::PANEL_MAX_FINDINGS
    body = (1..cap).map { |n| "<p>line #{n} [page]</p>" }.join("\n")
    template = create_template(content: body)

    get :edit, params: { project_id: @project.identifier, id: template.id }

    assert_select 'div#reporter-template-lint table.list tbody tr', count: cap
    assert_not_include ERB::Util.html_escape(l(:text_reporter_template_lint_more, count: 0)),
                       response.body
  end

  # ------------------------------------------------------------------ the editor on the preview

  # §9b.2: the diagnostics belong *"in the editor, next to the code"*. Before T-37 the
  # preview page had no code on it, so the author's next move was the browser's Back
  # button — which loses the render they were reading.
  def test_the_preview_page_carries_the_editor_form
    template = create_template(content: CLEAN_BODY)

    post :preview, params: { project_id: @project.identifier, id: template.id,
                             template: template_params(content: '<p>UNSAVED</p>') }

    assert_response :success
    assert_select 'form#reporter-template-form textarea[name=?]', 'template[content]',
                  text: /UNSAVED/
    assert_select "form#reporter-template-form[action=?]",
                  "/projects/#{@project.identifier}/reporter/templates/#{template.id}"
  end

  def test_the_preview_of_an_unsaved_draft_posts_back_to_the_collection
    post :preview, params: { project_id: @project.identifier,
                             template: template_params(content: '<p>DRAFT</p>') }

    assert_response :success
    assert_select "form#reporter-template-form[action=?]",
                  "/projects/#{@project.identifier}/reporter/templates"
  end

  # THE DATA LOSS THIS PAGE WOULD OTHERWISE HAVE HAD.
  #
  # A preview renders a `dup` of the stored template, and `dup` drops the id — so a HABTM
  # read through that id answers EMPTY. With the editor now on this page, the visibility
  # fieldset would have rendered every role unticked, and pressing Save from the preview
  # page would have cleared the role list of a `visibility: roles` template. Quietly, on
  # the one page whose entire promise is that it changes nothing.
  def test_a_preview_keeps_the_role_list_of_a_roles_visible_template
    template = create_template(visibility: Template::VISIBILITY_ROLES,
                               roles: [Role.find(1), Role.find(2)])

    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      post :preview, params: { project_id: @project.identifier, id: template.id,
                               template: template_params }
    end

    assert_equal [1, 2], assigns(:template).role_ids.sort
    assert_select 'input[type=checkbox][name=?][checked=checked]', 'template[role_ids][]',
                  count: 2
    assert_equal [1, 2], template.reload.role_ids.sort
  end

  # The failure report is ABOVE the form, because an author who has just pressed Preview
  # lands at the top of the page and "what happened" must not be below the fold.
  def test_a_failed_preview_shows_the_diagnostics_above_the_editor
    post :preview, params: { project_id: @project.identifier,
                             template: template_params(content: '{% if %}broken') }

    assert_response :success
    assert_select 'div#reporter-report-diagnostic'
    diagnostic_at = response.body.index('reporter-report-diagnostic')
    form_at = response.body.index('reporter-template-form')
    assert_operator diagnostic_at, :<, form_at,
                    'the diagnostics panel is below the editor form'
  end

  # …and the PDF section is never silent about its own outcome, which is the one thing
  # §9b.2 forbids: no "it looked fine" by omission.
  def test_the_pdf_section_says_that_it_failed_even_though_the_panel_is_elsewhere
    post :preview, params: { project_id: @project.identifier,
                             template: template_params(content: '{% if %}broken') }

    assert_include ERB::Util.html_escape(l(:text_reporter_preview_pdf_failed)), response.body
  end
end
