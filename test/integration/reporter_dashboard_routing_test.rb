# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Pins the HTTP verb of every dashboard route.
#
# It has to be an integration test: ActionController::TestCase generates the path from
# the parameters and never checks that the verb matches a route, so a controller test
# passes whatever verb it is handed. These assertions are the only thing that would
# notice a route quietly going back to POST — and a route whose verb changes without
# its callers changing is a dashboard control that silently stops working.
class ReporterDashboardRoutingTest < Redmine::RoutingTest
  def test_dashboard_page_routes
    should_route 'GET /projects/ecookbook/reporter' =>
                 'reporter_project_pages#show', project_id: 'ecookbook'
    should_route 'PATCH /projects/ecookbook/reporter' =>
                 'reporter_project_pages#update_page', project_id: 'ecookbook'
    should_route 'GET /projects/ecookbook/reporter/report_pdf' =>
                 'reporter_project_pages#report_pdf', project_id: 'ecookbook'
  end

  # add_block creates a widget; remove_block deletes one; move_block and update_page
  # change an existing tab.
  def test_widget_routes_use_the_verb_that_matches_what_they_do
    should_route 'POST /projects/ecookbook/reporter/add_block' =>
                 'reporter_project_pages#add_block', project_id: 'ecookbook'
    should_route 'DELETE /projects/ecookbook/reporter/remove_block' =>
                 'reporter_project_pages#remove_block', project_id: 'ecookbook'
    should_route 'PATCH /projects/ecookbook/reporter/move_block' =>
                 'reporter_project_pages#move_block', project_id: 'ecookbook'
  end

  def test_tab_routes
    should_route 'POST /projects/ecookbook/reporter/tabs' =>
                 'reporter_project_tabs#create', project_id: 'ecookbook'
    should_route 'PATCH /projects/ecookbook/reporter/tabs/7' =>
                 'reporter_project_tabs#update', project_id: 'ecookbook', id: '7'
    should_route 'DELETE /projects/ecookbook/reporter/tabs/7' =>
                 'reporter_project_tabs#destroy', project_id: 'ecookbook', id: '7'
    # Tab ordering keeps POST: it has its own endpoint and did not change.
    should_route 'POST /projects/ecookbook/reporter/tabs/7/order' =>
                 'reporter_project_tabs#order', project_id: 'ecookbook', id: '7'
  end

  def test_sql_stats_route
    should_route 'GET /sql/stats/monthly_flow' => 'sql_stats#monthly_flow'
  end

  # T-14. GET shows the page and runs NOTHING; POST is what starts a browser. The verb
  # is the control here, so it is pinned here — a GET that launched an engine is a GET a
  # crawler or a prefetching proxy can fire, and a controller test would never notice
  # the route drifting, because it generates the path from the parameters.
  def test_render_preflight_routes
    should_route 'GET /admin/reporter_dashboards/preflight' => 'reporter_preflight#show'
    should_route 'POST /admin/reporter_dashboards/preflight' => 'reporter_preflight#run'
  end

  # T-28 — THE ONLY ROUTE IN THIS PLUGIN OUTSIDE A PROJECT, and the only one an anonymous
  # visitor reaches. The token alphabet is `SecureRandom.urlsafe_base64`'s, so the
  # constraint has to accept `-` and `_` — a constraint that quietly rejected them would
  # 404 roughly half of all minted links, at random, with nothing in any log to say why.
  def test_share_link_route
    should_route 'GET /reporter/s/abcDEF123_-x' =>
                 'reporter_dashboards/shares#show', token: 'abcDEF123_-x'
  end

  # THE NEGATIVE HALF OF THE CONSTRAINT, and without it the constraint can be deleted with
  # nothing going red — an independent review measured exactly that. A test that only pins
  # what is ACCEPTED passes just as happily with no constraint at all.
  #
  # Read off the route set rather than by issuing a request, because a catch-all elsewhere
  # in Redmine could answer these and make the assertion pass for the wrong reason.
  def test_the_share_route_refuses_anything_outside_the_tokens_own_alphabet
    %w[a+b a%20b a/b a$b a!b].each do |candidate|
      assert_not recognises?("/reporter/s/#{candidate}"),
                 "#{candidate.inspect} was accepted as a token"
    end
  end

  def test_the_share_route_accepts_every_character_a_token_can_contain
    # `SecureRandom.urlsafe_base64`'s alphabet, all four classes of it. A constraint that
    # quietly rejected `-` or `_` would 404 roughly half of all minted links, at random.
    assert recognises?('/reporter/s/abcXYZ019_-')
  end

  # The negative half: each of these paths must be reachable by ONE verb. Read off the
  # route set rather than by issuing a request, so a catch-all route elsewhere in
  # Redmine cannot make the assertion pass for the wrong reason.
  def test_each_dashboard_path_accepts_exactly_one_verb
    assert_equal ['POST'],   verbs_for('/projects/:project_id/reporter/add_block')
    assert_equal ['DELETE'], verbs_for('/projects/:project_id/reporter/remove_block')
    assert_equal ['PATCH'],  verbs_for('/projects/:project_id/reporter/move_block')
    assert_equal %w[GET PATCH].sort, verbs_for('/projects/:project_id/reporter').sort
    assert_equal %w[GET POST].sort, verbs_for('/admin/reporter_dashboards/preflight').sort
    # GET AND NOTHING ELSE. A share link has to be a URL somebody can open, so it cannot be
    # a POST — and the cost of that is real rather than theoretical: a crawler or a
    # prefetching proxy following the link consumes a `max_uses` slot. That is the cost the
    # link's own controls exist to bound, and it is a deliberate trade rather than an
    # oversight, so the verb is pinned here.
    assert_equal ['GET'], verbs_for('/reporter/s/:token')
  end

  private

  # Does the route set recognise this path as a GET at all? `recognize_path` raises
  # `RoutingError` when nothing matches, which is the answer rather than an error here.
  def recognises?(path)
    Rails.application.routes.recognize_path(path, method: :get)
    true
  rescue ActionController::RoutingError
    false
  end

  def verbs_for(spec)
    Rails.application.routes.routes
         .select { |route| route.path.spec.to_s.sub(/\(\.:format\)\z/, '') == spec }
         .map { |route| route.verb.to_s }
  end
end
