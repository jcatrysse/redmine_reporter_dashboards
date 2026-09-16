# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-37 / FR-73 — THE GALLERY AS A SURFACE. *"Start from an example, never from empty."*
#
# `spec/starter_gallery_spec.rb` covers the manifest, the lint and the thumbnails' provenance
# DB-lessly. What it cannot reach is the page: whether the five entries are offered, whether
# `?starter=` really prefills the editor, and whether an id that is not one of the five can
# make this controller read a file it should not.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods defined after a `private` section are silently not run. There is no `private`
# here; the two helpers are above the tests.
class ReporterDashboardsStarterGalleryTest < ActionController::TestCase
  tests ReporterDashboards::TemplatesController

  include Redmine::I18n

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  Gallery = RedmineReporterDashboards::StarterGallery

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @jsmith = User.find_by!(login: 'jsmith')
    role = Role.find(1)
    role.permissions = %w[view_issues view_reporter_dashboards_reports
                          add_reporter_dashboards_templates]
    role.save!
    User.current = nil
    @request.session[:user_id] = @jsmith.id
  end

  def get_new(params = {})
    get :new, params: { project_id: @project.identifier }.merge(params)
  end

  # ------------------------------------------------------------------ the offer

  def test_the_new_page_offers_every_starter
    get_new

    assert_response :success
    assert_select 'div#reporter-starter-gallery li.reporter-starter', count: Gallery.entries.length

    Gallery.entries.each do |entry|
      assert_select "a[href=?]",
                    new_project_reporter_template_path(@project, starter: entry.id)
    end
  end

  # THE THUMBNAIL PATH IS ASSERTED, AND IT IS THE ONE THING HERE THAT DIFFERS PER REDMINE.
  # `image_tag(..., plugin:)` is Redmine's own helper override, and 7.0 ships Propshaft while
  # 5.1 does not — the two produce different URLs from the same call. Both are correct; what
  # would not be is the `plugin:` option landing in the markup as an ATTRIBUTE, which is
  # exactly what happens when the call is made outside a view context (measured while
  # reviewing this task, through `ActionController::Base.helpers`, and it looked like a real
  # defect until it was probed in a rendered page).
  #
  # So this asserts the SHAPE that is common to every branch: a plugin asset URL naming this
  # plugin, and no stray attribute. The four Redmine branches in CI each render this view.
  def test_the_thumbnail_is_served_through_redmines_own_plugin_asset_path
    get_new

    assert_select 'img.reporter-starter-thumbnail', count: Gallery.entries.length
    assert_select 'img.reporter-starter-thumbnail' do |images|
      images.each do |image|
        assert_include 'redmine_reporter_dashboards', image['src']
        assert_include 'starters/', image['src']
        assert_nil image['plugin'], 'the plugin: option leaked into the markup as an attribute'
        assert_not_empty image['alt'].to_s, 'a thumbnail with no alt text'
      end
    end
  end

  def test_each_starter_is_named_and_described_in_the_readers_language
    get_new

    Gallery.entries.each do |entry|
      assert_include ERB::Util.html_escape(l(entry.name_key)), response.body, entry.id
      assert_include ERB::Util.html_escape(l(entry.description_key)), response.body, entry.id
    end
  end

  # A missing translation renders as the KEY, which looks like a bug to the reader and hides
  # the gap from review (§10). The spec checks every locale file has the keys; this checks the
  # page is not printing them raw.
  def test_no_locale_key_leaks_into_the_page
    get_new

    assert_not_include 'label_reporter_starter_', response.body
    assert_not_include 'text_reporter_starter_', response.body
  end

  # ------------------------------------------------------------------ applying one

  def test_a_starter_prefills_the_editor_with_its_body
    entry = Gallery.find('chart-report')

    get_new(starter: entry.id)

    assert_response :success
    assert_equal Gallery.body(entry), assigns(:template).content
    assert_equal entry.source, assigns(:template).source
    assert_equal entry.output, assigns(:template).output
    assert_equal l(entry.name_key), assigns(:template).name
  end

  def test_the_prefilled_body_is_in_the_textarea
    get_new(starter: 'aggregate-report')

    assert_select 'textarea[name=?]', 'template[content]', text: /sql_aggregate/
  end

  # THE FIRST THING AN AUTHOR SEES THE LINT PANEL SAY IS "NOTHING FOUND", because a starter
  # is clean. That is the panel earning its place rather than being a scold.
  def test_a_prefilled_starter_lints_clean_on_the_page
    get_new(starter: 'version-status')

    assert_empty assigns(:lint).findings
    assert_select 'p#reporter-template-lint-clean'
  end

  # The gallery collapses once a starter is applied: five links that would replace what the
  # author is now looking at do not belong beside their code.
  def test_the_gallery_collapses_to_one_line_once_a_starter_is_applied
    get_new(starter: 'issue-document')

    assert_select 'p#reporter-starter-applied'
    assert_select 'div#reporter-starter-gallery', false
    assert_select 'a[href=?]', new_project_reporter_template_path(@project)
  end

  def test_nothing_is_written_by_looking_at_a_starter
    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      Gallery.entries.each { |entry| get_new(starter: entry.id) }
    end
  end

  # ------------------------------------------------------------------ an id that is not one

  # THE ID NEVER BECOMES A PATH. `StarterGallery.find` is a lookup in a frozen Hash, so each
  # of these is a plain miss rather than a file read — but the assertion is about the RESPONSE,
  # because that is what an attacker sees: no 500, no content from another file, and the
  # editor still usable.
  def test_an_unknown_starter_is_said_out_loud_rather_than_ignored
    get_new(starter: 'no-such-starter')

    assert_response :success
    assert_nil assigns(:starter)
    assert_nil assigns(:template).content
    assert_select 'div.flash.warning'
    assert_include ERB::Util.html_escape(l(:text_reporter_starter_unknown)), response.body
  end

  def test_a_traversal_in_the_starter_id_reads_no_file
    ['../../config/database.yml', '..%2f..%2fGemfile', 'issue-document.liquid',
     'issue-document/../../Gemfile', '/etc/passwd'].each do |attempt|
      get_new(starter: attempt)

      assert_response :success, attempt
      assert_nil assigns(:starter), attempt
      assert_nil assigns(:template).content, attempt
      assert_not_include 'adapter:', response.body, attempt
      assert_not_include 'source :rubygems', response.body, attempt
    end
  end

  def test_a_blank_starter_parameter_is_simply_no_starter
    get_new(starter: '')

    assert_response :success
    assert_nil assigns(:starter)
    assert_select 'div#reporter-starter-gallery'
    assert_select 'div.flash.warning', false
  end

  # ------------------------------------------------------------------ end to end

  # THE POINT OF THE WHOLE FEATURE: a starter is applied and saved without an edit, and what
  # is stored is what the file says. A gallery that prefilled a body the model then refused
  # would be an onboarding path that ends in a validation error.
  def test_a_starter_can_be_created_unchanged
    entry = Gallery.find('spent-time-report')
    get_new(starter: entry.id)
    prefilled = assigns(:template)

    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      post :create, params: { project_id: @project.identifier,
                              template: { name: prefilled.name, content: prefilled.content,
                                          source: prefilled.source, output: prefilled.output,
                                          orientation: 'portrait', page_size: 'A4',
                                          enabled: '1' } }
    end

    created = RedmineReporterDashboards::Template.order(:id).last
    assert_equal Gallery.body(entry), created.content
    assert_equal 'time_entries', created.source
  end

  # The gallery is on the NEW page and nowhere else: an author editing a saved template is not
  # choosing where to start from, and a link that replaced their body would be a trap.
  def test_the_gallery_is_not_on_the_edit_page
    template = RedmineReporterDashboards::Template.create!(
      project: @project, author: @jsmith, name: 'Existing', content: '<p>x</p>',
      source: 'issues', output: 'combined'
    )
    Role.find(1).add_permission!(:edit_reporter_dashboards_templates)
    User.current = nil

    get :edit, params: { project_id: @project.identifier, id: template.id }

    assert_response :success
    assert_select 'div#reporter-starter-gallery', false
  end
end
