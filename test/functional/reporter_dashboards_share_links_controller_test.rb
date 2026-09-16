# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-28 increment 3 — the OWNER'S side of a share link, in the full application.
#
# --- THE SHAPE, AND WHY IT IS THE ONE T-25 AND T-32 USE ---
#
# Hold ONE permission, walk every action, assert 403 on what it must not reach. Redmine's
# `authorize` passes on ANY permission mapping an action, so a controller whose two
# permissions map into the same actions — which these do, deliberately — needs the negative
# half written down or the split is decoration.
#
# The three rules, and only one of them is a permission:
#
#   making a link      `share_reporter_dashboards_reports`
#   making it PUBLIC   additionally `publish_reporter_dashboards_reports`, per REQUEST
#   REVOKING           ownership, not a permission (FR-53)
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. There is none here; every
# helper is above the tests.
class ReporterDashboardsShareLinksControllerTest < Redmine::ControllerTest
  # §Findings E-21 — a test case calling `l()` needs the module that defines it, or every
  # assertion about copy errors with `NoMethodError: undefined method 'l'`.
  include Redmine::I18n

  tests ReporterDashboards::ShareLinksController

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  Template = RedmineReporterDashboards::Template
  ShareLink = RedmineReporterDashboards::ShareLink
  Document = RedmineReporterDashboards::Document

  PDF_BYTES = "%PDF-1.4\n#{'0' * 2_000}\n%%EOF"

  class FakeEngine
    def capabilities
      []
    end

    def id
      'fake'
    end

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(bytes: PDF_BYTES, engine: 'fake',
                                                     engine_version: '1.0')
    end
  end

  def setup
    @project = Project.find(1)
    unless @project.module_enabled?(:reporter_dashboards_reports)
      EnabledModule.create!(project: @project, name: 'reporter_dashboards_reports')
      # RELOAD — `module_enabled?` memoises `enabled_modules` WITHOUT the row just created,
      # so `allowed_to?` answers false for everybody on the test side while the controller's
      # freshly loaded project answers true. The two then disagree and the code looks wrong.
      @project.reload
    end
    @owner = User.find(2)      # jsmith — the template's author
    @other = User.find(3)      # dlopper — a colleague with the same role
    @admin = User.find(1)
    @role = Role.find(1)
    @template = Template.create!(project: @project, author_id: @owner.id, name: 'Weekly',
                                 content: '<p>hi</p>', source: 'issues', output: 'combined')
    User.current = nil
  end

  def teardown
    User.current = nil
  end

  # ------------------------------------------------------------------ helpers

  def grant(*permissions)
    # ONE OBJECT — `Role.find(1).permissions = …` then `Role.find(1).save!` saves a second,
    # freshly loaded role and throws the assignment away.
    @role.permissions = (%w[view_issues view_reporter_dashboards_reports] + permissions.map(&:to_s)).uniq
    @role.save!
  end

  # The colleague is put in the SAME role as the owner, explicitly rather than by trusting
  # the fixture: Redmine's fixtures give user 3 a different role in project 1, so `grant`
  # would not reach them and every "a third party cannot…" test would pass for the wrong
  # reason — the permission never arriving rather than the guard refusing.
  def give_other_the_same_role
    Member.where(project_id: @project.id, user_id: @other.id).destroy_all
    Member.create!(project: @project, principal: @other, roles: [@role])
  end

  def with_engine
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, FakeEngine)
      yield
    end
  end

  def create_link(params = {})
    with_engine do
      post :create, params: { project_id: @project.identifier, template_id: @template.id }
                    .merge(params)
    end
  end

  def existing_link(overrides = {})
    document = with_engine do
      RedmineReporterDashboards::Reporting::Snapshot.capture(
        template: @template, render_as: @owner, project: @project, created_by: @owner,
        expires_at: 90.days.from_now
      ).document
    end
    link, = ShareLink.create_with_token!({ template: @template, project: @project,
                                          created_by: @owner,
                                          scope_kind: ShareLink::SCOPE_SNAPSHOT,
                                          rendered_document_id: document.id,
                                          expires_at: 30.days.from_now }.merge(overrides))
    link
  end

  # ------------------------------------------------------------------ the module gate

  def test_a_project_without_the_reports_module_404s_rather_than_403s
    grant(:share_reporter_dashboards_reports)
    @project.disable_module!(:reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    get :index, params: { project_id: @project.identifier, template_id: @template.id }

    assert_response :not_found
  end

  # ------------------------------------------------------------------ reaching the surface

  def test_the_holder_of_the_share_permission_sees_the_list
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    get :index, params: { project_id: @project.identifier, template_id: @template.id }

    assert_response :success
  end

  # THE CONSUMING PERMISSION IS NOT ENOUGH. Reading a report and handing it to the internet
  # are different decisions, which is the whole reason `share_…` exists as its own grant.
  def test_a_reader_without_the_share_permission_is_refused_everywhere
    grant # view_issues + view_…_reports only
    @request.session[:user_id] = @owner.id

    get :index, params: { project_id: @project.identifier, template_id: @template.id }
    assert_response :forbidden

    get :new, params: { project_id: @project.identifier, template_id: @template.id }
    assert_response :forbidden

    create_link
    assert_response :forbidden
  end

  # YOU CANNOT SHARE A REPORT YOU CANNOT OPEN. A private template belonging to somebody else
  # is 404 — not 403, because 403 confirms it exists.
  def test_a_template_this_actor_cannot_see_is_not_shareable
    grant(:share_reporter_dashboards_reports)
    give_other_the_same_role
    @template.update!(visibility: Template::VISIBILITY_PRIVATE)
    @request.session[:user_id] = @other.id

    get :index, params: { project_id: @project.identifier, template_id: @template.id }

    assert_response :not_found
  end

  # SOMEBODY WHO MAY NOT REACH THIS SURFACE LEARNS NOTHING ABOUT WHAT IS ON IT.
  #
  # The permission guard runs BEFORE the template lookup, so the answer is the same whether
  # the id exists or not. Reversed — which is how this shipped — a member holding only
  # `publish_…` got 403 for a template that exists and 404 for one that does not, which is
  # an existence oracle for exactly the person with no right to the surface. Found by an
  # independent review.
  #
  # The assertion is that the TWO ANSWERS ARE THE SAME, not that either is a particular
  # code: what makes an oracle is the difference, and pinning only one of them would leave
  # the other free to drift.
  def test_somebody_without_the_share_permission_cannot_tell_a_real_template_from_a_missing_one
    grant(:publish_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    # `#new` AND NOT `#index`, WHICH IS THE WHOLE REASON THIS TEST WORKS. `publish_…` maps
    # `new`/`create` and nothing else, so on `#index` Redmine's own `authorize` refuses
    # first and the guard order below is never reached — the first version of this test used
    # `#index` and the mutation that reverses the order SURVIVED it. The oracle only exists
    # on an action this permission genuinely maps.
    get :new, params: { project_id: @project.identifier, template_id: @template.id }
    existing = response.status

    get :new, params: { project_id: @project.identifier, template_id: 999_999 }
    missing = response.status

    assert_equal existing, missing,
                 "existing template answered #{existing} and a missing one #{missing} — " \
                 'the difference is an existence oracle'
    assert_equal 403, existing
  end

  # ------------------------------------------------------------------ creating

  def test_creating_a_link_renders_a_snapshot_and_shows_the_url_exactly_once
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    assert_difference 'RedmineReporterDashboards::ShareLink.count', 1 do
      assert_difference 'RedmineReporterDashboards::Document.count', 1 do
        create_link
      end
    end

    assert_response :redirect
    link = ShareLink.order(:id).last
    assert_equal ShareLink::SCOPE_SNAPSHOT, link.scope_kind
    assert_equal @owner.id, link.created_by_id
    assert_equal @owner.id, link.render_as_user_id
    assert_not link.public_link?
    # THE TOKEN IS IN ITS OWN FLASH KEY, never in `:notice` — the notice partial is rendered
    # into every page of the next request, and a credential must not be printable by
    # accident.
    assert_not_nil flash[:reporter_share_url]
    assert_not_include flash[:reporter_share_url].to_s, flash[:notice].to_s
  end

  # THE SNAPSHOT OUTLIVES THE LINK, which is what makes the link's own validation
  # satisfiable. Asserted because two independently computed "30 days from now" differ in
  # whichever direction the clock falls, and the controller adds the grace deliberately.
  def test_the_snapshot_is_kept_longer_than_the_link_that_points_at_it
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    create_link(expires_in_days: '14')

    link = ShareLink.order(:id).last
    assert_operator link.expires_at, :<, link.rendered_document.expires_at
  end

  def test_the_expiry_and_use_limit_from_the_form_are_applied
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    create_link(expires_in_days: '3', max_uses: '2', purpose: 'For the steering group')

    link = ShareLink.order(:id).last
    assert_equal 2, link.max_uses
    assert_equal 'For the steering group', link.purpose
    assert_operator link.expires_at, :<, 4.days.from_now
    assert_operator link.expires_at, :>, 2.days.from_now
  end

  # THERE IS NO SUCH THING AS A LINK THAT NEVER EXPIRES, and the form cannot ask for one:
  # an absent or nonsense value falls back to the default rather than to nil.
  def test_an_absent_or_nonsense_expiry_falls_back_to_the_default_and_never_to_none
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    # ASSERTED ON THE DEFAULT, not merely on "not nil and in the future". The first version
    # checked only those two things and a mutation walked straight through it: any fallback
    # at all — including a wrong one — is non-nil and in the future, so the assertion could
    # not tell the default from an arbitrary number.
    default = ReporterDashboards::ShareLinksController::DEFAULT_EXPIRY_DAYS

    ['', '0', '-5', 'abc'].each do |value|
      create_link(expires_in_days: value)

      link = ShareLink.order(:id).last
      assert_not_nil link.expires_at, "#{value.inspect} produced a link with no expiry"
      assert_operator link.expires_at, :>, (default - 1).days.from_now,
                      "#{value.inspect} did not fall back to the #{default}-day default"
      assert_operator link.expires_at, :<, (default + 1).days.from_now,
                      "#{value.inspect} did not fall back to the #{default}-day default"
    end
  end

  # OVER THE CAP IS CLAMPED, NOT REFUSED. The person filling the form learns nothing from a
  # validation error about a bound they were never shown; the field says what the maximum
  # is, and a larger number gets it.
  def test_an_expiry_over_the_cap_is_clamped
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    create_link(expires_in_days: '4000')

    link = ShareLink.order(:id).last
    max = ReporterDashboards::ShareLinksController::MAX_EXPIRY_DAYS
    assert_operator link.expires_at, :<=, (max + 1).days.from_now
  end

  # A FAILED RENDER CREATES NO LINK. FR-52's shape is that the bytes exist before the grant
  # does, so a link pointing at nothing must be impossible rather than merely unlikely.
  def test_a_render_failure_creates_no_link_and_says_why
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    assert_no_difference 'RedmineReporterDashboards::ShareLink.count' do
      # No engine registered at all, so the run fails at the PDF step.
      RedmineReporterDashboards::Render::Registry.isolated do
        post :create, params: { project_id: @project.identifier, template_id: @template.id }
      end
    end

    assert_response :unprocessable_entity
    assert_not_nil flash.now[:error]
  end

  # ------------------------------------------------------------------ the second permission

  # THE TWO GRANTS ARE NOT ONE GRANT. T-28's `Accept:`: *"'anyone holding this URL' and
  # 'anyone on the internet' are different decisions."* A holder of `share_…` alone who asks
  # for a public link is REFUSED rather than quietly given a private one — somebody who
  # ticked "public" and got private would hand the link out believing it was public.
  def test_share_alone_cannot_make_a_public_link
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    assert_no_difference 'RedmineReporterDashboards::ShareLink.count' do
      create_link(public_link: '1')
    end

    assert_response :forbidden
  end

  def test_both_permissions_together_can_make_a_public_link
    grant(:share_reporter_dashboards_reports, :publish_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    create_link(public_link: '1')

    assert_response :redirect
    assert ShareLink.order(:id).last.public_link?
  end

  # AND THE PUBLISH PERMISSION ALONE REACHES NOTHING, which is the half a reader assumes
  # rather than checks: `publish_…` maps to `#new`/`#create`, so without the explicit
  # `require_share_permission` guard Redmine's `authorize` would let it through.
  def test_publish_alone_cannot_create_anything
    grant(:publish_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    assert_no_difference 'RedmineReporterDashboards::ShareLink.count' do
      create_link(public_link: '1')
    end

    assert_response :forbidden
  end

  # ------------------------------------------------------------------ revoking

  def test_the_creator_can_revoke_their_own_link
    grant(:share_reporter_dashboards_reports)
    link = existing_link
    @request.session[:user_id] = @owner.id

    post :revoke, params: { project_id: @project.identifier, template_id: @template.id,
                            id: link.id }

    assert_response :redirect
    assert link.reload.revoked?
  end

  # THE ONE THE `Accept:` LINE NAMES: *"a test asserts a third party holding BOTH permissions
  # still cannot revoke somebody else's link."* Granted here as the whole setable set, which
  # is stronger: NO permission confers revocation.
  def test_a_third_party_holding_every_permission_cannot_revoke_anothers_link
    # PUBLIC, so the third party can SEE the report. Left private, `find_template`
    # answers 404 before the ownership guard is ever reached and the test would pass
    # for the wrong reason — the visibility check, not the revocation rule.
    @template.update!(visibility: Template::VISIBILITY_PUBLIC)
    give_other_the_same_role
    @role.permissions = @role.setable_permissions.map(&:name)
    @role.save!
    link = existing_link(created_by: @owner)
    @request.session[:user_id] = @other.id

    assert @other.reload.allowed_to?(:share_reporter_dashboards_reports, @project.reload),
           'the fixture must actually grant the permission, or this asserts nothing'

    post :revoke, params: { project_id: @project.identifier, template_id: @template.id,
                            id: link.id }

    assert_response :forbidden
    assert_not link.reload.revoked?
  end

  def test_an_administrator_can_revoke_anybody_s_link
    link = existing_link
    @request.session[:user_id] = @admin.id

    post :revoke, params: { project_id: @project.identifier, template_id: @template.id,
                            id: link.id }

    assert_response :redirect
    assert link.reload.revoked?
  end

  # A LINK OF ANOTHER TEMPLATE IS NOT REACHABLE THROUGH THIS ONE'S URL. Without the
  # `template_id` scope in `find_link`, the id alone would be enough.
  def test_a_link_belonging_to_a_different_template_is_a_404
    grant(:share_reporter_dashboards_reports)
    other_template = Template.create!(project: @project, author_id: @owner.id, name: 'Other',
                                      content: '<p>x</p>', source: 'issues',
                                      output: 'combined')
    link = existing_link
    @request.session[:user_id] = @owner.id

    post :revoke, params: { project_id: @project.identifier,
                            template_id: other_template.id, id: link.id }

    assert_response :not_found
    assert_not link.reload.revoked?
  end

  # ------------------------------------------------------------------ revoke all

  def test_revoke_all_takes_every_live_link_this_actor_owns
    grant(:share_reporter_dashboards_reports)
    a = existing_link
    b = existing_link
    already = existing_link
    already.revoke!
    @request.session[:user_id] = @owner.id

    delete :revoke_all, params: { project_id: @project.identifier,
                                  template_id: @template.id }

    assert_response :redirect
    assert a.reload.revoked?
    assert b.reload.revoked?
  end

  # AND IT LEAVES SOMEBODY ELSE'S ALONE. A revoke-all that took every link on the template
  # would be a permission escalation with a convenient name — the actor here can revoke
  # their own and not the owner's, and the template's author is somebody else.
  def test_revoke_all_does_not_touch_links_this_actor_may_not_revoke
    @template.update!(visibility: Template::VISIBILITY_PUBLIC)
    give_other_the_same_role
    grant(:share_reporter_dashboards_reports)
    theirs = existing_link(created_by: @owner)
    mine = existing_link(created_by: @other)
    @request.session[:user_id] = @other.id

    delete :revoke_all, params: { project_id: @project.identifier,
                                  template_id: @template.id }

    assert_response :redirect
    assert mine.reload.revoked?, 'the actor’s own link was not revoked'
    assert_not theirs.reload.revoked?, 'somebody else’s link was revoked'
  end

  # ------------------------------------------------------------------ INV-1

  # THE SNAPSHOT IS RENDERED AS THE PERSON PRESSING THE BUTTON, AND NOTHING ELSE.
  #
  # FOUND BY AN INDEPENDENT REVIEW, which measured what the absence of this test allowed:
  # changing `render_as: User.current` to `render_as: @template.author` — a two-token edit —
  # left all 834 tests green while turning the action into a privilege escalation. The
  # sharer received the AUTHOR's view of the data, including issues they may not see, and
  # `render_as_user_id` still recorded the sharer, so the audit column lied about the
  # identity the bytes were computed under. Every existing test here had the sharer BE the
  # author, so none of them could tell the two apart.
  #
  # The discriminator is an engine that echoes the render, plus two identities that see a
  # different number of issues.
  class EchoEngine
    def capabilities
      []
    end

    def id
      'echo'
    end

    def render(request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: "%PDF-1.4\n#{request.body}\n#{'0' * 2_000}\n%%EOF", engine: 'echo',
        engine_version: '1.0'
      )
    end
  end

  def visible_count(actor)
    Issue.visible(actor).where(project_id: @project.id).count
  end

  # One private issue and two roles that differ about it — built rather than assumed from
  # the fixtures, because "these two happen to see different things" is exactly the
  # precondition that quietly stops being true when a fixture changes.
  def make_the_two_actors_see_different_issues
    seer = @role
    # `view_…_reports` IS IN BOTH LISTS. Without it `Template#visible?` answers false and
    # `find_template` 404s before anything this test is about has run — which is what the
    # first version of this helper did, and it looked like a routing bug.
    seer.permissions = %w[view_issues view_private_issues
                          view_reporter_dashboards_reports
                          share_reporter_dashboards_reports]
    seer.save!
    blind = Role.find(2)
    blind.permissions = %w[view_issues view_reporter_dashboards_reports
                           share_reporter_dashboards_reports]
    blind.save!

    Member.where(project_id: @project.id, user_id: @owner.id).destroy_all
    Member.where(project_id: @project.id, user_id: @other.id).destroy_all
    Member.create!(project: @project, principal: @owner, roles: [seer])
    Member.create!(project: @project, principal: @other, roles: [blind])

    Issue.where(project_id: @project.id).order(:id).first
         .update_columns(is_private: true, author_id: @owner.id, assigned_to_id: @owner.id)
  end

  def test_the_snapshot_is_rendered_as_the_sharer_and_never_as_the_templates_author
    @template.update!(content: 'COUNT=[{{ issues.size }}]',
                      visibility: Template::VISIBILITY_PUBLIC)
    make_the_two_actors_see_different_issues
    @project.reload

    sharer_sees = visible_count(@other)
    author_sees = visible_count(@owner)
    assert_not_equal sharer_sees, author_sees,
                     'the two actors see the same issues, so this cannot discriminate'

    # dlopper shares a report jsmith wrote. The bytes must be dlopper's view.
    @request.session[:user_id] = @other.id
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:echo, EchoEngine)
      post :create, params: { project_id: @project.identifier, template_id: @template.id }
    end

    assert_response :redirect
    link = ShareLink.order(:id).last
    assert_equal @other.id, link.render_as_user_id
    assert_include "COUNT=[#{sharer_sees}]", link.rendered_document.bytes,
                   'the snapshot holds somebody else’s view of the data'
    assert_not_include "COUNT=[#{author_sees}]", link.rendered_document.bytes
  end

  # ------------------------------------------------------------------ scoping

  # THREE SCOPES, ALL DESTRUCTIVE OR DISCLOSING, AND AN INDEPENDENT REVIEW FOUND ALL THREE
  # UNTESTED. Each is written here against the observable difference the review constructed.

  # `find_template`'s `where(project_id:)`. Without it, an actor holding `share_…` in one
  # project reaches another project's templates — and their share links, `purpose` included.
  # THE ACTOR IS A MEMBER OF BOTH PROJECTS AND THE TEMPLATE IS PUBLIC, WHICH IS THE WHOLE
  # POINT. The first version made neither arrangement, so `Template#visible?` answered false
  # and the request 404'd for a reason that had nothing to do with the scope — the mutation
  # that removes `where(project_id:)` SURVIVED it. Measured, then fixed: a test that passes
  # because a different guard fired is a test of that other guard.
  def test_a_template_from_another_project_is_not_reachable_through_this_project_s_url
    grant(:share_reporter_dashboards_reports)
    other_project = Project.find(2)
    unless other_project.module_enabled?(:reporter_dashboards_reports)
      EnabledModule.create!(project: other_project, name: 'reporter_dashboards_reports')
      other_project.reload
    end
    Member.where(project_id: other_project.id, user_id: @owner.id).destroy_all
    Member.create!(project: other_project, principal: @owner, roles: [@role])
    other_template = Template.create!(project: other_project, author_id: @owner.id,
                                      name: 'Elsewhere', content: '<p>x</p>',
                                      source: 'issues', output: 'combined',
                                      visibility: Template::VISIBILITY_PUBLIC)
    # THE PRECONDITION, ASSERTED: without it the test cannot tell "the scope refused" from
    # "the actor could not see it anyway".
    assert other_template.visible?(@owner.reload),
           'the actor cannot see the other project’s template, so the scope is not what is ' \
           'being tested'
    @request.session[:user_id] = @owner.id

    get :index, params: { project_id: @project.identifier, template_id: other_template.id }

    assert_response :not_found
  end

  # `index`'s `for_template`. Without it the list shows links belonging to other templates —
  # including their `purpose`, which is the field whose own help text promises it is private
  # to its author.
  def test_the_list_shows_only_this_template_s_links
    grant(:share_reporter_dashboards_reports)
    mine = existing_link
    other_template = Template.create!(project: @project, author_id: @owner.id, name: 'Other',
                                      content: '<p>x</p>', source: 'issues',
                                      output: 'combined')
    stranger, = ShareLink.create_with_token!(
      template: other_template, project: @project, created_by: @owner,
      scope_kind: ShareLink::SCOPE_QUERY, purpose: 'NOT-FOR-THIS-LIST',
      expires_at: 30.days.from_now
    )
    @request.session[:user_id] = @owner.id

    get :index, params: { project_id: @project.identifier, template_id: @template.id }

    assert_response :success
    assert_equal [mine.id], assigns(:links).map(&:id)
    assert_not_include stranger.purpose, response.body
  end

  # `revoke_all`'s `for_template`. Without it, "revoke all for this report" revokes the
  # actor's links on EVERY template in the installation — a button whose label promises one
  # report and whose effect is global.
  def test_revoke_all_touches_only_this_template
    grant(:share_reporter_dashboards_reports)
    here = existing_link
    other_template = Template.create!(project: @project, author_id: @owner.id, name: 'Other',
                                      content: '<p>x</p>', source: 'issues',
                                      output: 'combined')
    elsewhere, = ShareLink.create_with_token!(
      template: other_template, project: @project, created_by: @owner,
      scope_kind: ShareLink::SCOPE_QUERY, expires_at: 30.days.from_now
    )
    @request.session[:user_id] = @owner.id

    delete :revoke_all, params: { project_id: @project.identifier,
                                  template_id: @template.id }

    assert_response :redirect
    assert here.reload.revoked?
    assert_not elsewhere.reload.revoked?, 'a link on another report was revoked'
  end

  # AND IT TAKES EXPIRED-BUT-UNREVOKED LINKS TOO, because the index draws a Revoke button
  # for them. `.live` used to be the scope, so after "revoke all" an expired link kept its
  # button on the page somebody opens precisely when they think something has gone wrong.
  def test_revoke_all_includes_an_expired_link_that_still_shows_a_revoke_button
    grant(:share_reporter_dashboards_reports)
    expired = existing_link
    expired.update_columns(expires_at: 1.hour.ago)
    @request.session[:user_id] = @owner.id

    delete :revoke_all, params: { project_id: @project.identifier,
                                  template_id: @template.id }

    assert expired.reload.revoked?
  end

  # ------------------------------------------------------------------ bad input

  # NOTHING EXPENSIVE HAPPENS BEFORE THE FIELDS ARE CHECKED. An independent review measured
  # a 256-character `purpose` driving a full render, a `Document` row and an `Attachment` on
  # disk — with no link, so nothing could ever reach the bytes, and `documents:purge`
  # collects only EXPIRED rows, so they sat for 37 days. Repeatable without bound.
  def test_an_over_long_purpose_is_refused_before_anything_is_rendered
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    assert_no_difference ['RedmineReporterDashboards::Document.count',
                          'RedmineReporterDashboards::ShareLink.count',
                          '::Attachment.count'] do
      create_link(purpose: 'x' * 256)
    end

    assert_response :unprocessable_entity
  end

  # AND A `max_uses` PAST THE COLUMN'S RANGE IS A NUMBER, NOT A 500. `use_count` and
  # `max_uses` are 4-byte integers, so the review's `99999999999` raised an uncaught
  # `ActiveModel::RangeError` and orphaned a snapshot on the way out.
  def test_an_enormous_max_uses_is_clamped_rather_than_raising
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    create_link(max_uses: '99999999999')

    assert_response :redirect
    assert_equal ReporterDashboards::ShareLinksController::MAX_USES_CAP,
                 ShareLink.order(:id).last.max_uses
  end

  # AT THE LIMIT AND ONE PAST IT, for the field that now has one.
  def test_a_purpose_exactly_at_the_limit_is_accepted
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id

    create_link(purpose: 'x' * 255)

    assert_response :redirect
    assert_equal 'x' * 255, ShareLink.order(:id).last.purpose
  end

  # ------------------------------------------------------------------ the list

  def test_the_list_shows_revoked_and_expired_links_too
    grant(:share_reporter_dashboards_reports)
    live = existing_link
    revoked = existing_link
    revoked.revoke!
    @request.session[:user_id] = @owner.id

    get :index, params: { project_id: @project.identifier, template_id: @template.id }

    assert_response :success
    ids = assigns(:links).map(&:id)
    assert_includes ids, live.id
    assert_includes ids, revoked.id, 'a revoked link is the one somebody most wants to see'
  end

  # A BUTTON THAT WOULD ANSWER 403 IS NOT DRAWN. The forged request is refused either way —
  # that is tested above — but offering somebody a control they cannot use is the
  # "capability nobody can reach" defect pointed the other way, and it is the sort of thing
  # that survives forever because nothing fails.
  #
  # Found by an independent review, whose mutation drew the button unconditionally and left
  # the suite green.
  def test_a_non_owner_is_offered_no_revoke_button_at_all
    @template.update!(visibility: Template::VISIBILITY_PUBLIC)
    give_other_the_same_role
    grant(:share_reporter_dashboards_reports)
    link = existing_link(created_by: @owner)
    @request.session[:user_id] = @other.id

    get :index, params: { project_id: @project.identifier, template_id: @template.id }

    assert_response :success
    assert_includes assigns(:links).map(&:id), link.id,
                    'the link is not even listed, so this asserts nothing about the button'
    assert_not_include revoke_path_for(link), response.body
    assert_not_include l(:button_reporter_share_links_revoke_all), response.body
  end

  # ...AND THE OWNER IS. The control for the test above: without it, a page that drew no
  # buttons for anybody would pass it.
  def test_the_owner_is_offered_the_buttons
    grant(:share_reporter_dashboards_reports)
    link = existing_link(created_by: @owner)
    @request.session[:user_id] = @owner.id

    get :index, params: { project_id: @project.identifier, template_id: @template.id }

    assert_response :success
    assert_include revoke_path_for(link), response.body
    assert_include l(:button_reporter_share_links_revoke_all), response.body
  end

  def revoke_path_for(link)
    "/projects/#{@project.identifier}/reporter/templates/#{@template.id}/shares/#{link.id}/revoke"
  end

  # SHOWN ONCE, AND ONCE MEANS ONCE.
  #
  # The first version of this test asserted the token was absent from the list page and
  # failed — correctly, because the list page IS where it is shown, on the single request
  # the redirect lands on. That is the feature: only the digest is stored, so this is the
  # one moment the URL exists anywhere.
  #
  # The claim worth testing is therefore the SECOND visit. A token that survived into it
  # would mean the URL was being reconstructed or cached somewhere, which is the one thing
  # this design must never do.
  def test_the_url_is_shown_on_the_page_after_creation_and_never_again
    grant(:share_reporter_dashboards_reports)
    @request.session[:user_id] = @owner.id
    create_link
    token = flash[:reporter_share_url].to_s.split('/').last
    assert_not token.empty?, 'no token was minted, so this asserts nothing'

    get :index, params: { project_id: @project.identifier, template_id: @template.id }
    assert_response :success
    assert_include token, response.body, 'the URL was not shown even once'

    # The next request. `flash` is swept between requests in a real cycle; a controller test
    # holds one session across calls, so it is cleared explicitly rather than left to a
    # sweep that does not happen here.
    flash.clear
    get :index, params: { project_id: @project.identifier, template_id: @template.id }

    assert_response :success
    assert_not_include token, response.body, 'the token came back on a later visit'
  end
end
