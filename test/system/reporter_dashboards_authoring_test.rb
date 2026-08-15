# frozen_string_literal: true

require File.expand_path('../system_test_case', __dir__)

# THE AUTHORING JOURNEY, IN A REAL BROWSER — R-02 / C-07.
#
# --- WHY THIS FILE EXISTS AT ALL ---
#
# An independent review found the suite had controller, model and Rack-level integration
# tests and no browser anywhere, and pointed at this repository's own history for proof that
# the gap is not theoretical: T-23's editor 404'd on every press of Preview, and no
# controller test could see it.
#
# The reason is written into `_editor.html.erb`, above the button:
#
#     `formaction` sends this form's own body (the UNSAVED content) to the preview action,
#     and `formmethod: 'post'` changes the verb without changing the body — which still
#     carries Rails' hidden `_method=patch` on the edit and preview pages, so
#     `Rack::MethodOverride` rewrites the request to PATCH before routing.
#
# Every part of that sentence is the browser's behaviour, not the application's. A controller
# test names an action and a verb and reaches it by construction; it cannot get the pair
# wrong, so it cannot notice when the pair IS wrong. `post :preview` passes against an editor
# whose button 404s for every author who ever presses it.
#
# --- WHAT THIS FILE IS DELIBERATELY NOT ---
#
# Not a second copy of `reporter_dashboards_templates_controller_test.rb`. The review asked
# for "a deliberately small system suite for the primary journeys, not a duplicate of every
# controller example", and every example below is here because it asserts something only a
# browser can produce: a form submitted the way a form is submitted, or markup a script
# revealed. Authorisation, visibility, bounds and failure typing stay where they are tested
# properly and fast.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. The helpers are under one.
class ReporterDashboardsAuthoringSystemTest < ReporterDashboardsSystemTestCase
  def setup
    super
    @template = Template.create!(project: @project, author: @author, name: 'Weekly',
                                 content: '<p>saved body</p>')
  end

  # --- preview, which is the whole reason for the file --------------------------------------

  def test_preview_of_a_new_template_renders_the_unsaved_body_and_saves_nothing
    before = Template.count

    visit new_project_reporter_template_path(@project)
    fill_in 'template_name', with: 'Draft'
    fill_in_editor('<p>UNSAVED-NEW-BODY</p>')
    click_on_preview

    assert_text 'UNSAVED-NEW-BODY'
    assert_equal before, Template.count, 'preview persisted a template'
  end

  # THE ONE THAT 404'd. The edit page carries Rails' hidden `_method=patch`, so the Preview
  # button's `formmethod: 'post'` reaches the server as PATCH via `Rack::MethodOverride`. The
  # route declares both verbs for exactly that reason, and this is what proves it still does.
  def test_preview_from_the_edit_page_survives_the_method_override
    visit edit_project_reporter_template_path(@project, @template)

    assert_equal 'patch', find('#reporter-template-form input[name="_method"]', visible: :all).value,
                 'the edit form no longer carries the hidden verb this test is about'

    fill_in_editor('<p>UNSAVED-EDIT-BODY</p>')
    click_on_preview

    assert_text 'UNSAVED-EDIT-BODY'
    assert_equal '<p>saved body</p>', @template.reload.content, 'preview wrote to the record'
  end

  # PREVIEW KEEPS THE EDITOR, and the partial's own comment says why: an earlier version
  # rendered a bare result, so the only way back was the browser's Back button, which loses
  # the render you just looked at.
  def test_preview_comes_back_with_the_editor_still_on_the_page
    visit edit_project_reporter_template_path(@project, @template)
    fill_in_editor('<p>STILL-EDITING</p>')
    click_on_preview

    assert_selector '#reporter-template-form'
    assert_equal '<p>STILL-EDITING</p>', editor.value,
                 'the editor came back empty or holding the saved body'
  end

  def test_a_template_can_be_written_saved_and_reopened
    visit new_project_reporter_template_path(@project)
    fill_in 'template_name', with: 'Written in a browser'
    fill_in_editor('<p>ROUND-TRIP</p>')
    click_on_save

    # `eventually` and BY NAME. This read `Template.order(:id).last` immediately after the
    # click and got the fixture from `setup` — Capybara waits for the page, not for the row,
    # so the assertion raced the POST and failed roughly two runs in three. See the helper in
    # `system_test_case.rb`.
    eventually('the template was never saved') do
      Template.exists?(project_id: @project.id, name: 'Written in a browser')
    end
    saved = Template.find_by!(project_id: @project.id, name: 'Written in a browser')

    visit edit_project_reporter_template_path(@project, saved)
    assert_equal '<p>ROUND-TRIP</p>', editor.value
  end

  # --- the chart form, which is the only JavaScript the authoring chrome loads --------------

  # `chart_form.js` REVEALS ITS OWN FIELDSET — it ships with `hidden` so the feature is absent
  # rather than broken when the script does not run. That design is invisible to every other
  # kind of test: a controller test sees the markup and cannot tell that a browser would keep
  # it hidden, and a static read of the view sees `hidden` and cannot tell that it is removed.
  def test_the_chart_form_is_revealed_by_its_script
    visit edit_project_reporter_template_path(@project, @template)

    assert_selector '#reporter-chart-form', visible: true,
                    text: '', wait: Capybara.default_max_wait_time
  end

  def test_the_chart_form_writes_one_line_of_liquid_into_the_editor
    visit edit_project_reporter_template_path(@project, @template)
    fill_in_editor('')

    within '#reporter-chart-form' do
      fill_in 'rrd-chart-id', with: 'c1'
      fill_in 'rrd-chart-from', with: 'by_status'
      find('button, input[type=button], input[type=submit]', match: :first).click
    end

    assert_match(/\{%\s*chart\s+id:\s*c1,\s*from:\s*by_status/, editor.value)
  end

  private

  def editor
    find('#template_content')
  end

  def fill_in_editor(body)
    # `set` rather than `fill_in` on a value that may be empty: Capybara's `fill_in` with an
    # empty string is a no-op on some drivers, and one of these tests clears the field on
    # purpose.
    editor.set(body)
  end

  # THE PREVIEW BUTTON BY ITS `name`, not by its label. The label is translated, and this
  # suite must mean the same thing on a runner whose default locale is not English —
  # CLAUDE.md §6. `name: 'preview'` is the attribute `_editor.html.erb` sets and the one the
  # controller reads.
  def click_on_preview
    find('#reporter-template-form input[name="preview"]').click
  end

  # The saving button is the one WITHOUT `name="preview"`, which is `commit` — Rails' default
  # for `submit_tag`. Selected the same way and for the same reason: `l(:button_create)` is
  # not available in a system test (it raised `NoMethodError` on the first run of this file)
  # and would have been the wrong thing anyway.
  def click_on_save
    find('#reporter-template-form input[name="commit"]').click
  end
end
