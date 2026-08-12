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
end
