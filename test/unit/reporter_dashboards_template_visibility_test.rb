# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-23 — visibility and ownership on the template model, plus finding **S-8**.
#
# --- WHY THE SCOPE AND THE PREDICATE ARE COMPARED AGAINST EACH OTHER ---
#
# `Template.visible(user)` answers "which rows may this actor see" in SQL and
# `Template#visible?(user)` answers "may this actor see THIS row" in Ruby. Core carries
# the same duplication (`Query.visible` / `Query#visible?`) and for the same reason: a
# controller holding one record must not run a query to find out. Two implementations of
# one rule is exactly the shape that drifts, so a matrix of every actor against every
# template asserts they agree — which is a stronger statement than either on its own, and
# the one thing neither can make alone.
class ReporterDashboardsTemplateVisibilityTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  Template = RedmineReporterDashboards::Template

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)

    @author = User.find_by!(login: 'jsmith')          # member of project 1, role 1
    @colleague = User.find_by!(login: 'dlopper')       # member of project 1
    @outsider = User.find_by!(login: 'rhill')         # not a member of project 1
    @admin = User.find_by!(login: 'admin')
    @anonymous = User.anonymous

    @member_role = Role.find(1)
    @member_role.add_permission!(:view_reporter_dashboards_reports)

    @other_role = Role.create!(name: 'Auditors',
                               permissions: [:view_reporter_dashboards_reports])
  end

  # Roles assigned BEFORE the save: `Template` copies core's rule that a ROLES-visible
  # record naming no roles is invalid (`app/models/query.rb:276`), so create-then-assign
  # raises on the create rather than on the assignment.
  def template(visibility, author: @author, roles: [])
    record = Template.new(project: @project, author: author,
                          name: "t#{visibility}-#{roles.map(&:id).join('-')}-#{author.id}",
                          content: 'x', visibility: visibility)
    record.roles = roles
    record.save!
    record
  end

  # ------------------------------------------------------------------ the two answers agree

  # THIS EXAMPLE FOUND A REAL DISAGREEMENT ON ITS FIRST RUN, which is the reason it is
  # written as a matrix rather than as five separate assertions. For an ADMINISTRATOR the
  # scope answered "not visible" for another author's private template while the predicate
  # answered "visible" — core's own `Query` has the same split, and here it would have let
  # an administrator edit and delete a template their index did not list. The scope was
  # changed, and `Template.visible` records why next to the divergence.
  def test_the_scope_and_the_predicate_agree_for_every_actor_and_every_template
    templates = {
      private_own: template(Template::VISIBILITY_PRIVATE, author: @author),
      private_other: template(Template::VISIBILITY_PRIVATE, author: @colleague),
      public: template(Template::VISIBILITY_PUBLIC, author: @colleague),
      roles_mine: template(Template::VISIBILITY_ROLES, author: @colleague,
                           roles: [@member_role]),
      roles_theirs: template(Template::VISIBILITY_ROLES, author: @colleague,
                             roles: [@other_role])
    }
    actors = { author: @author, colleague: @colleague, outsider: @outsider,
               admin: @admin, anonymous: @anonymous }

    actors.each do |actor_name, actor|
      visible_ids = Template.visible(actor).pluck(:id)

      templates.each do |template_name, record|
        assert_equal visible_ids.include?(record.id), record.visible?(actor),
                     "#{actor_name} and #{template_name}: the scope says " \
                     "#{visible_ids.include?(record.id)} and the predicate says " \
                     "#{record.visible?(actor)}"
      end
    end
  end

  def test_an_administrator_sees_every_template_in_the_project
    # The consequence of the divergence above, pinned so that "fixing" the scope back to
    # core's shape fails HERE with a reason rather than only in the matrix.
    others_private = template(Template::VISIBILITY_PRIVATE, author: @colleague)

    assert_include others_private, Template.visible(@admin)
    assert others_private.visible?(@admin)
    assert others_private.editable_by?(@admin)
  end

  def test_an_author_always_sees_their_own_private_template
    record = template(Template::VISIBILITY_PRIVATE, author: @author)

    assert record.visible?(@author)
    assert_include record, Template.visible(@author)
  end

  def test_nobody_else_sees_a_private_template
    record = template(Template::VISIBILITY_PRIVATE, author: @colleague)

    assert_not record.visible?(@author)
    assert_not_include record, Template.visible(@author)
  end

  def test_a_non_member_sees_nothing_in_a_project_they_have_no_permission_in
    record = template(Template::VISIBILITY_PUBLIC, author: @author)

    assert_not record.visible?(@outsider)
    assert_not_include record, Template.visible(@outsider)
  end

  # THE ANONYMOUS ARM, REACHED. The first version of this test asserted the right thing
  # and never got near it: Anonymous held no role with `view_reporter_dashboards_reports`,
  # so both answers were "no" from the PERMISSION gate — replacing `author_id` with
  # `user.id` in the anonymous arm of `.visible` would not have failed it. Found by the
  # independent review of T-23. The project is made public and the builtin Anonymous role
  # is granted the view permission, so the only thing left deciding is authorship.
  def test_anonymous_never_matches_on_authorship
    # `User.anonymous` is a real row with a real id, so a template authored by it — which
    # nothing can create, but a restore or a user deletion could produce — must not become
    # visible to every unauthenticated visitor.
    @project.update_columns(is_public: true)
    Role.anonymous.add_permission!(:view_reporter_dashboards_reports)
    User.current = nil
    record = template(Template::VISIBILITY_PRIVATE, author: @anonymous)

    # The control: with the gate open, Anonymous DOES see a public one. Without this the
    # test could go back to passing for the old reason at any time.
    assert template(Template::VISIBILITY_PUBLIC, author: @author).visible?(@anonymous)

    assert_not record.visible?(@anonymous)
    assert_not_include record, Template.visible(@anonymous)
  end

  # THE CROSS-PROJECT ROLE LEAK, which the agreement matrix could not see.
  #
  # The `Auditors` role in the matrix is granted to nobody in any project, so both the
  # scope and the predicate answered "no" for a reason unrelated to the bug. Here the
  # actor holds the named role in a DIFFERENT project — which is what the missing
  # `templates.project_id = m.project_id` clause let through: the EXISTS matched via a
  # membership somewhere else entirely, so the index listed a template whose page 404'd.
  def test_a_roles_template_does_not_match_a_role_held_in_another_project
    elsewhere = Project.find(2)
    # `jsmith` is already a member of project 2 in the fixtures, so the role is ADDED to
    # the existing membership rather than a second one created — `Member` validates one
    # row per user per project.
    membership = Member.find_by(project: elsewhere, user: @author) ||
                 Member.create!(project: elsewhere, user: @author, roles: [@other_role])
    membership.roles << @other_role unless membership.roles.include?(@other_role)
    @author.reload
    record = template(Template::VISIBILITY_ROLES, author: @colleague,
                      roles: [@other_role])

    assert_not_include record, Template.visible(@author),
                       'a role held in another project made a ROLES template visible here'
    assert_not record.visible?(@author)
  end

  def test_a_roles_template_does_match_the_same_role_held_here
    # The control for the example above: with the role held in THIS project, both answers
    # are yes. Without it, deleting the whole roles arm would pass the negative test.
    Member.create!(project: @project, user: @outsider, roles: [@other_role])
    @outsider.reload
    record = template(Template::VISIBILITY_ROLES, author: @colleague,
                      roles: [@other_role])

    assert_include record, Template.visible(@outsider)
    assert record.visible?(@outsider)
  end

  def test_visible_refuses_a_nil_actor_rather_than_defaulting_to_User_current
    # INV-1: `Query.visible` defaults to `User.current` and this deliberately does not. A
    # caller that forgets gets an ArgumentError, not a plausible answer for whoever
    # happens to be logged in.
    assert_raises(ArgumentError) { Template.visible(nil) }
  end

  def test_the_predicate_answers_false_for_nil_rather_than_raising
    # The asymmetry is deliberate. A missing actor in a SCOPE is a bug at the call site;
    # a nil record-level actor is an ordinary "no" and must fail closed.
    assert_not template(Template::VISIBILITY_PUBLIC).visible?(nil)
  end

  # ------------------------------------------------------------------ ownership

  # `regrant` RELOADS THE USER, and the first version of this test did not — which cost
  # two false failures that read as a broken permission check.
  #
  # `User#allowed_to?` resolves through `roles_for_project`, which memoises the Role
  # OBJECTS in `@projects_by_role`. `add_permission!` writes the database and leaves that
  # memo holding a Role whose `permissions` array is the old one, so the second half of a
  # before/after assertion answers with the first half's data. `User#reload` is what
  # clears it (`app/models/user.rb`), and reloading the RECORD is not the same thing.
  def regrant(&block)
    block.call
    @author.reload
    @colleague.reload
  end

  def test_editable_by_needs_the_permission_as_well_as_the_authorship
    record = template(Template::VISIBILITY_PRIVATE, author: @author)
    regrant { @member_role.remove_permission!(:edit_own_reporter_dashboards_templates) }

    assert_not record.editable_by?(@author)

    regrant { @member_role.add_permission!(:edit_own_reporter_dashboards_templates) }
    assert record.reload.editable_by?(@author)
  end

  def test_edit_own_does_not_reach_another_author
    record = template(Template::VISIBILITY_PUBLIC, author: @colleague)
    regrant { @member_role.add_permission!(:edit_own_reporter_dashboards_templates) }

    assert_not record.editable_by?(@author)
  end

  def test_edit_any_reaches_another_author
    record = template(Template::VISIBILITY_PUBLIC, author: @colleague)
    regrant { @member_role.add_permission!(:edit_reporter_dashboards_templates) }

    assert record.editable_by?(@author)
  end

  def test_deleting_is_the_same_grant_as_editing
    record = template(Template::VISIBILITY_PRIVATE, author: @author)
    regrant { @member_role.add_permission!(:edit_own_reporter_dashboards_templates) }

    assert_equal record.editable_by?(@author), record.deletable_by?(@author)
    assert record.deletable_by?(@author)
  end

  def test_a_global_template_is_admin_only_by_construction
    # Redmine has no role grant outside a project, so there is nothing to check a
    # permission against (§4.1, "Deliberately not permissions").
    record = Template.create!(project: nil, author: @author, name: 'global', content: 'x')
    regrant { @member_role.add_permission!(:edit_reporter_dashboards_templates) }

    assert_not record.editable_by?(@author)
    assert record.editable_by?(@admin)
  end

  def test_visibility_editable_by_is_the_manage_public_grant
    record = template(Template::VISIBILITY_PRIVATE, author: @author)

    assert_not record.visibility_editable_by?(@author)

    regrant { @member_role.add_permission!(:manage_public_reporter_dashboards_templates) }
    assert record.reload.visibility_editable_by?(@author)
  end

  # ------------------------------------------------------------------ finding S-8

  # Core's `Role` declares `has_and_belongs_to_many :queries` and that — not the Query
  # side — is what deletes `queries_roles` rows when a role goes. Nothing outside this
  # plugin knows about `reporter_dashboards_templates_roles`, so without the reciprocal
  # declaration its rows survive the role for ever.
  def test_deleting_a_role_deletes_its_template_visibility_rows
    record = template(Template::VISIBILITY_ROLES, author: @author, roles: [@other_role])
    join_rows = lambda do
      ActiveRecord::Base.connection
                        .select_value('SELECT COUNT(*) FROM ' \
                                      'reporter_dashboards_templates_roles ' \
                                      "WHERE template_id = #{record.id}").to_i
    end

    assert_equal 1, join_rows.call

    @other_role.destroy

    assert_equal 0, join_rows.call, 'the role is gone and its join row is not — S-8'
  end

  def test_the_reciprocal_association_is_actually_declared_on_Role
    # `load_patches` rescues and only WARNS, so a patch that failed to load leaves no
    # failure anywhere — the association would simply be absent and the test above would
    # be the only sign. Asserting the declaration separately says which of the two broke.
    assert Role.new.respond_to?(:reporter_dashboards_templates),
           'Role has no reporter_dashboards_templates association — role_patch.rb did ' \
           'not load, and load_patches only logs a warning when that happens'
  end

  def test_deleting_a_role_leaves_the_template_itself_alone
    record = template(Template::VISIBILITY_ROLES, author: @author, roles: [@other_role])

    @other_role.destroy

    assert Template.exists?(record.id),
           'a template whose named role was deleted must survive: its author has to ' \
           'choose again, which is a visible degradation rather than a deletion'
  end
end
