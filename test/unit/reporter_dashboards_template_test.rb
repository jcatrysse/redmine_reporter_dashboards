# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
# `Object#stub` is Minitest::Mock's, and Redmine's test_helper does not load it.
# Needed by the §7 rule 5 examples, which have to take a column AWAY to prove the
# guard degrades rather than raises.
require 'minitest/mock'

# T-22 — the template model, against a real Redmine and a real database.
#
# The DB-less half (`spec/migrations/schema_contract_spec.rb`) asserts what the migrations
# DESCRIBE. This file asserts what the database and ActiveRecord actually DO with it, which
# is a different question: a NOT NULL that the model never trips, an index that exists but
# does not refuse anything, and a validation that reads correctly but never fires all look
# identical from the migration.
class ReporterDashboardsTemplateTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles

  Template = RedmineReporterDashboards::Template

  def setup
    @project = Project.find(1)
    @author = User.find(2)
    @other = User.find(3)
    @role = Role.givable.first
  end

  def test_a_minimal_template_saves_with_the_documented_defaults
    template = Template.create!(project: @project, author_id: @author.id, name: 'Quarterly')

    assert_equal Template::VISIBILITY_PRIVATE, template.visibility
    assert_equal 'issues', template.source
    assert_equal 'combined', template.output
    assert_equal 'portrait', template.orientation
    assert_equal 'A4', template.page_size
    assert_equal 0, template.lock_version
    assert template.enabled
  end

  def test_visibility_uses_redmines_own_three_values
    # The claim §4.1 makes is that an administrator meets ONE concept. That is only true if
    # the integers are core's, so this asserts them against Query's constants rather than
    # against literals of our own.
    assert_equal Query::VISIBILITY_PRIVATE, Template::VISIBILITY_PRIVATE
    assert_equal Query::VISIBILITY_ROLES, Template::VISIBILITY_ROLES
    assert_equal Query::VISIBILITY_PUBLIC, Template::VISIBILITY_PUBLIC
  end

  def test_visibility_outside_the_three_values_is_refused
    template = Template.new(project: @project, author_id: @author.id, name: 'x', visibility: 7)

    assert_not template.valid?
    assert_includes template.errors.attribute_names, :visibility
  end

  def test_a_name_is_required
    assert_not Template.new(project: @project, author_id: @author.id).valid?
  end

  def test_an_author_is_required_because_edit_own_is_answered_from_it
    template = Template.new(project: @project, name: 'x')

    assert_not template.valid?
    assert_includes template.errors.attribute_names, :author_id
  end

  def test_a_template_with_no_project_is_allowed_because_that_is_the_admin_only_case
    # technical-spec.md:663 — "Redmine has no role grant outside a project, so
    # `project_id IS NULL` is admin-only by construction."
    template = Template.create!(author_id: @author.id, name: 'Installation-wide')

    assert_nil template.project_id
    assert template.persisted?
  end

  def test_visible_to_roles_with_no_roles_is_refused_the_way_redmine_refuses_it
    template = Template.new(project: @project, author_id: @author.id, name: 'x',
                            visibility: Template::VISIBILITY_ROLES)

    assert_not template.valid?
    assert_not_empty template.errors[:base]
  end

  def test_visible_to_roles_with_roles_saves
    template = Template.new(project: @project, author_id: @author.id, name: 'x',
                            visibility: Template::VISIBILITY_ROLES)
    template.roles << @role

    assert template.save
    assert_equal [@role.id], template.reload.roles.map(&:id)
  end

  def test_changing_visibility_away_from_roles_clears_the_role_list
    # Mirrors Query's own after_save. Without it a template switched to PRIVATE keeps a
    # role list that means nothing, and switching back silently restores a grant nobody
    # re-approved.
    template = Template.new(project: @project, author_id: @author.id, name: 'x',
                            visibility: Template::VISIBILITY_ROLES)
    template.roles << @role
    template.save!

    template.update!(visibility: Template::VISIBILITY_PRIVATE)

    assert_equal [], template.reload.roles.to_a
  end

  def test_changing_a_roles_template_without_touching_visibility_keeps_its_roles
    # The narrow form of the callback, asserted so a "tidier" unconditional version is a
    # test failure rather than a silent behaviour change.
    template = Template.new(project: @project, author_id: @author.id, name: 'x',
                            visibility: Template::VISIBILITY_ROLES)
    template.roles << @role
    template.save!

    template.update!(name: 'renamed')

    assert_equal [@role.id], template.reload.roles.map(&:id)
  end

  def test_lock_version_refuses_a_lost_update
    template = Template.create!(project: @project, author_id: @author.id, name: 'x')
    first = Template.find(template.id)
    second = Template.find(template.id)

    first.update!(name: 'first wins')

    assert_raises(ActiveRecord::StaleObjectError) { second.update!(name: 'second loses') }
  end

  def test_source_and_output_are_bounded
    assert_not Template.new(project: @project, author_id: @author.id, name: 'x', source: 'wat').valid?
    assert_not Template.new(project: @project, author_id: @author.id, name: 'x', output: 'wat').valid?
    assert Template.new(project: @project, author_id: @author.id, name: 'x',
                        source: 'time_entries', output: 'per_record').valid?
  end

  def test_there_is_no_sti_type_column
    # implementation-plan.md:1979 — "template types by `source` field (T-31), NOT a subclass
    # tree". A column named `type` would be Rails' STI discriminator whether anybody wanted
    # it or not, so its absence is the mechanism rather than the convention.
    assert_not_includes Template.column_names, 'type'
    assert_equal 'reporter_dashboards_templates', Template.table_name
  end

  def test_margins_accept_a_millimetre_quadruple_and_refuse_anything_else
    assert Template.new(project: @project, author_id: @author.id, name: 'x', margins: '20,15,20,15').valid?
    assert Template.new(project: @project, author_id: @author.id, name: 'x', margins: nil).valid?
    assert_not Template.new(project: @project, author_id: @author.id, name: 'x', margins: '20,15,20').valid?
    assert_not Template.new(project: @project, author_id: @author.id, name: 'x', margins: '9999,1,1,1').valid?
    assert_not Template.new(project: @project, author_id: @author.id, name: 'x', margins: 'a,b,c,d').valid?
  end

  def test_source_template_id_is_unique_so_a_second_import_cannot_duplicate_a_row
    Template.create!(project: @project, author_id: @author.id, name: 'imported', source_template_id: 99)

    assert_raises(ActiveRecord::RecordNotUnique) do
      Template.transaction(requires_new: true) do
        Template.create!(project: @project, author_id: @author.id, name: 'imported again',
                         source_template_id: 99)
      end
    end
  end

  def test_many_hand_authored_templates_may_share_a_null_source_template_id
    # The unique index must not punish the normal case. Every engine this plugin runs on
    # treats NULLs in a unique index as distinct; this is the assertion that says so on the
    # engine the run is actually using.
    3.times { |i| Template.create!(project: @project, author_id: @author.id, name: "hand #{i}") }

    assert_equal 3, Template.where(source_template_id: nil).count
  end

  def test_deleting_a_template_deletes_its_versions
    # Keeping the content of a deleted template would keep executable code (INV-9) an
    # operator believed they had removed.
    template = Template.create!(project: @project, author_id: @author.id, name: 'x')
    RedmineReporterDashboards::TemplateVersion.create!(template_id: template.id, content: 'a')

    assert_difference 'RedmineReporterDashboards::TemplateVersion.count', -1 do
      template.destroy
    end
  end

  def test_engine_hint_guard_answers_true_when_the_column_is_there
    assert Template.engine_hint_supported?
  end

  def test_engine_hint_guard_degrades_rather_than_raising_when_the_column_is_absent
    # §7 rule 5, and the only way to prove it is to take the column away. The guard's whole
    # promise is "converts a support incident into a degraded feature".
    RedmineReporterDashboards::Compat.stub(:column_present?, false) do
      assert_not Template.engine_hint_supported?
      assert_nil Template.new.engine_hint_or_nil
    end
  end
end
