# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
# NO `require 'minitest/mock'` — Ruby 3.4 ships minitest 6, which no longer provides it,
# and the require made the whole file fail to LOAD on the Redmine 7.0 CI job. Mocha is what
# Redmine's own suite loads and what the stub below uses; see the fuller note in
# `reporter_dashboards_schedule_test.rb`.

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
    # technical-spec.md — "Redmine has no role grant outside a project, so
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
    # implementation-plan.md — "template types by `source` field (T-31), NOT a subclass
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

  def test_a_template_created_private_WITH_roles_does_not_keep_them
    # The hole in core's own callback, closed deliberately. `saved_change_to_visibility?` is
    # false here because 0 is the column default, so core's form would leave the join row —
    # inert while the template is private, and LIVE the moment somebody switches it to ROLES,
    # granting a role nobody chose in that edit.
    template = Template.new(project: @project, author_id: @author.id, name: 'x',
                            visibility: Template::VISIBILITY_PRIVATE)
    template.roles << @role
    template.save!

    assert_equal [], template.reload.roles.to_a
  end

  def test_a_public_template_does_not_keep_a_role_list_either
    template = Template.new(project: @project, author_id: @author.id, name: 'x',
                            visibility: Template::VISIBILITY_PUBLIC)
    template.roles << @role
    template.save!

    assert_equal [], template.reload.roles.to_a
  end

  def test_string_columns_are_length_validated_so_the_answer_does_not_depend_on_the_engine
    # `t.string` is unlimited `character varying` on PostgreSQL and `varchar(255)` on
    # MySQL/MariaDB, so without a validation an over-long value saves on one engine and
    # raises ActiveRecord::ValueTooLong on another. At the limit and one past it.
    at_limit = 'x' * Template::MAX_STRING
    past = 'x' * (Template::MAX_STRING + 1)

    assert Template.new(project: @project, author_id: @author.id, name: at_limit).valid?
    assert_not Template.new(project: @project, author_id: @author.id, name: past).valid?
    assert_not Template.new(project: @project, author_id: @author.id, name: 'x',
                            engine_hint: past).valid?
  end

  def test_engine_hint_guard_answers_true_when_the_column_is_there
    assert Template.engine_hint_supported?
  end

  def test_engine_hint_guard_degrades_rather_than_raising_when_the_column_is_absent
    # §7 rule 5, and the only way to prove it is to take the column away. BOTH states are
    # asserted against a non-degraded value: an example that only checks the stubbed-absent
    # side passes even if the reader ignores the guard and returns the column directly.
    template = Template.create!(project: @project, author_id: @author.id, name: 'x',
                                engine_hint: 'chromium_cdp')

    assert Template.engine_hint_supported?
    assert_equal 'chromium_cdp', template.engine_hint_or_nil

    RedmineReporterDashboards::Compat.stubs(:column_present?).returns(false)

    assert_not Template.engine_hint_supported?
    assert_nil template.engine_hint_or_nil, 'the guard is not consulted by the reader'
  end
  # ---------------------------------------------------------------- T-30 / FR-59

  def test_the_failure_document_flag_is_off_by_default
    template = Template.create!(project: @project, author_id: @author.id, name: 'x')

    assert_equal false, template.failure_document?, 'FR-59 says default off'
    assert_equal false, template.reload.failure_document?
  end

  def test_the_failure_document_flag_reads_true_once_it_is_set
    template = Template.create!(project: @project, author_id: @author.id, name: 'x',
                                failure_document: true)

    assert_equal true, template.reload.failure_document?
  end

  # A NIL IN THE COLUMN MUST READ AS OFF, not as nil. The column is NOT NULL with a
  # default, so this cannot happen through the form — it can happen through an install
  # that migrated while rows existed, and a predicate answering nil would make
  # `if template.failure_document?` right and `failure_document? == false` wrong in the
  # same codebase.
  def test_a_nil_in_the_column_reads_as_off_rather_than_as_nil
    template = Template.new(project: @project, author_id: @author.id, name: 'x')
    template[:failure_document] = nil

    assert_equal false, template.failure_document?
  end

  # §7 rule 5, exactly as `engine_hint` does it: BOTH states asserted against a
  # non-degraded value, because an example that only checks the stubbed-absent side passes
  # even when the reader ignores the guard.
  def test_the_failure_document_guard_degrades_rather_than_raising_when_the_column_is_absent
    template = Template.create!(project: @project, author_id: @author.id, name: 'x',
                                failure_document: true)

    assert Template.failure_document_supported?
    assert_equal true, template.failure_document?

    RedmineReporterDashboards::Compat.stubs(:column_present?).returns(false)

    assert_not Template.failure_document_supported?
    assert_equal false, template.failure_document?,
                 'the guard is not consulted by the reader'
  end
end
