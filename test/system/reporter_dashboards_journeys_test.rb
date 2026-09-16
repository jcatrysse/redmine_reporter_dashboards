# frozen_string_literal: true

require File.expand_path('../system_test_case', __dir__)

# THE DASHBOARD AND SHARING JOURNEYS, IN A REAL BROWSER — R-02 / C-07.
#
# --- WHAT MAKES THESE BROWSER-ONLY ---
#
# Both journeys hang off Rails' UJS attributes, and those are the part no other kind of test
# in this repository can reach:
#
#   `data-method`   the move controls and the revoke control are `<a>` elements. The server
#                   routes them as POST and DELETE. NOTHING makes that true except a script
#                   intercepting the click and building a form — and whether that script is
#                   present, and under what name, is a fact about the HOST APPLICATION that
#                   differs across the four supported Redmine branches. A controller test
#                   issues the verb itself and can never observe the difference.
#   `data-confirm`  revoking raises a native dialog. A controller test does not have one; a
#                   real browser refuses to continue until it is answered.
#
# --- WHY THE SHARE LINK IS SEEDED RATHER THAN CREATED THROUGH THE UI ---
#
# Minting one renders a PDF first — FR-52's ordering, so a render that fails produces no link
# rather than a link pointing at nothing — and a render needs an engine. Driving that through
# a browser would make this file a test of the PDF stack, which `render-conformance` already
# owns and does better. The creation half is covered by the controller suite. What is left
# here is the half only a browser can answer, and it is the half that matters to a person who
# has just realised they shared the wrong thing: does the Revoke control actually revoke, and
# does the URL stop serving afterwards.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. The helpers are under one.
class ReporterDashboardsJourneysSystemTest < ReporterDashboardsSystemTestCase
  def setup
    super
    @template = Template.create!(project: @project, author: @author, name: 'Weekly',
                                 content: '<p>body</p>')
  end

  # --- the dashboard --------------------------------------------------------------------

  # THE SETTINGS BOX IS `display: none` UNTIL A SCRIPT REVEALS IT — the same design as the
  # chart form, and invisible to every other kind of test for the same reason: a controller
  # test sees the markup and cannot tell a browser would keep it hidden.
  def test_the_settings_box_is_hidden_until_its_toggle_is_pressed
    create_tab('Alpha')
    visit project_reporter_page_path(@project)

    assert_no_selector '#reporter-dashboard-settings', visible: true
    find('#reporter-dashboard-settings-toggle').click
    assert_selector '#reporter-dashboard-settings', visible: true
  end

  def test_a_dashboard_tab_can_be_created_from_the_settings_form
    visit project_reporter_page_path(@project, new_tab: 1)
    find('#reporter-dashboard-settings-toggle').click

    fill_in 'reporter_project_tab_title', with: 'Delivery'
    within('form[action$="/tabs"]') { find('input[type=submit]').click }

    eventually('the tab was not stored') do
      ReporterProjectTab.where(project_id: @project.id, title: 'Delivery').exists?
    end
  end

  # THE MOVE CONTROL IS AN `<a>` THAT HAS TO BECOME A POST. If the host application's UJS
  # layer is absent or renamed on a branch, this click is a GET to a POST-only route and the
  # tab does not move — silently, because the page still renders. That is the failure this
  # example exists for, and it is invisible to `post :order`.
  #
  # The settings box shows the SELECTED tab, so Beta is selected before its control is
  # pressed — `?tab=` is what `find_tab` reads.
  def test_the_move_control_reorders_tabs
    first_tab = create_tab('Alpha')
    second_tab = create_tab('Beta')
    assert_operator first_tab.position, :<, second_tab.position, 'precondition'

    visit project_reporter_page_path(@project, tab: second_tab.id)
    find('#reporter-dashboard-settings-toggle').click
    within('#reporter-dashboard-settings') { find('a.reporter-move-control').click }

    eventually('the move control did not reorder — a data-method link went out as a GET') do
      second_tab.reload.position < first_tab.reload.position
    end
  end

  # --- sharing --------------------------------------------------------------------------

  def test_revoking_a_share_link_takes_the_confirmation_and_stops_the_url_serving
    link, token = seed_share_link
    assert_nil link.revoked_at, 'precondition: the link is live'

    visit project_reporter_template_share_links_path(@project, @template)

    # THE CONFIRM DIALOG IS PART OF THE CONTROL. `accept_confirm` fails the example if no
    # dialog appears, so this asserts the `data-confirm` is still wired as well as the
    # `data-method` — a Revoke that fires without asking is its own defect on a page whose
    # whole purpose is undoing something.
    #
    # BY ITS `href`, NOT BY `a[data-method="post"]`. The first version used the attribute
    # selector with `match: :first` and clicked REDMINE'S SIGN-OUT LINK, which carries the
    # same attribute and sits higher in the document. The example then failed with "unable
    # to find modal dialog", which is a true statement about the wrong element — the kind of
    # green-looking wrong a selector this loose produces once it stops failing.
    revoke = revoke_project_reporter_template_share_link_path(@project, @template, link)
    accept_confirm { find("a[href='#{revoke}']").click }

    eventually('Revoke did not revoke — a data-method link went out as a GET') do
      !link.reload.revoked_at.nil?
    end

    # AND THE URL STOPS SERVING. Asserted from the anonymous side, because that is who holds
    # a share link: the session is cleared first, so this is the recipient's request and not
    # the author's.
    Capybara.reset_sessions!
    visit "/reporter/s/#{token}"

    assert_no_selector 'iframe, embed, object'
    assert_no_text token
  end

  # --- the states a confused user actually meets ------------------------------------------

  def test_a_member_without_the_report_permission_is_refused_the_template_list
    @role.permissions = @role.permissions - [:view_reporter_dashboards_reports]
    @role.save!

    visit project_reporter_templates_path(@project)

    assert_no_selector '#content table.list'
    assert_text(/403|not authorized|autoris|Zugriff|toegang/i)
  end

  def test_the_template_list_says_something_when_there_is_nothing_in_it
    Template.where(project_id: @project.id).destroy_all

    visit project_reporter_templates_path(@project)

    assert_selector '#content'
    assert_no_selector '#content table.list tbody tr'
  end

  private

  def create_tab(title)
    ReporterProjectTab.create!(project_id: @project.id, title: title)
  end

  # `SCOPE_QUERY`, which needs no rendered document — see the file header for why a snapshot
  # is not built here. The revoke control does not read the scope kind, so this seeds the
  # cheapest link that is a link.
  def seed_share_link
    ShareLink.create_with_token!(
      template: @template, project: @project, created_by: @author,
      scope_kind: ShareLink::SCOPE_QUERY, expires_at: 7.days.from_now
    )
  end
end
