# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require File.expand_path(
  '../../lib/redmine_reporter_dashboards/reporting/bundle_import', __dir__
)
# REQUIRED BECAUSE THIS FILE USES IT — and the reason first written here was WRONG, so it
# is corrected rather than quietly deleted.
#
# The claim was that without this line the file passes only inside the full run, because
# `exchange_rake_test.rb` happens to load `bundle_report` first. Negative-tested: with the
# require removed, `bin/rails test <this file>` on its own is **26 runs, 0 failures**. The
# constant AUTOLOADS. Measured in a booted app that had touched nothing:
#
#     loaded before touch? false
#     resolved            : RedmineReporterDashboards::Reporting::BundleReport
#     loaded after touch?  true
#
# So this plugin's `lib/` is on an autoload path after all — see the HANDOVER §1 entry
# this sharpens. The require stays because it states a real dependency of this file rather
# than relying on one, which is cheap; it is not load-bearing, and nothing here should say
# it is.
require File.expand_path(
  '../../lib/redmine_reporter_dashboards/reporting/bundle_report', __dir__
)

# T-29 — FR-56, the two-step bundle import, against a real database.
#
# --- WHY THE FULL APP AND NOT A DOUBLE ---
#
# Every claim FR-56 makes is about a database, and a double cannot fail any of them:
#
#   "one transaction per template"     needs a real SAVEPOINT and a real rollback
#   "one bad template does not abort
#    the bundle"                       needs a real validation failure mid-list
#   "writing nothing"                  needs real statements to subscribe to
#   the overwrite permission           needs a real Role, Member and MemberRole
#   the version snapshot               needs the append-only versions table
#
# T-24's importer test took the same decision for the same reason, and its class comment
# is the precedent this one follows.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods defined after a `private` section are silently NOT RUN — a file can report
# 30 runs while defining 40 test methods and nothing fails. There is no `private` here;
# every helper is above the tests, and the run count is checked against
# `grep -c '^  def test_'`.
class ReporterDashboardsBundleImportTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  BundleImport = RedmineReporterDashboards::Reporting::BundleImport
  Bundle = RedmineReporterDashboards::Reporting::Bundle
  Template = RedmineReporterDashboards::Template
  TemplateVersion = RedmineReporterDashboards::TemplateVersion

  def setup
    @project = Project.find(1)
    # ENABLED, AND ITS ABSENCE MADE THE OVERWRITE PERMISSION TEST VACUOUS. `editable_by?`
    # goes through `user.allowed_to?(…, project)`, which is FALSE for every non-admin when
    # the project does not have the module — so the one test pinning the `edit_own_…` case
    # passed with the actor as the author, and would have passed if the arm had been
    # refusing unconditionally. Found by an independent review; HANDOVER §1's "assert the
    # fixture discriminates", unlearned.
    @project.enable_module!(:reporter_dashboards_reports)
    @admin = User.find(1)
    assert @admin.admin?, 'user 1 must be an administrator'
    @jsmith = User.find_by!(login: 'jsmith')
    @dlopper = User.find_by!(login: 'dlopper')
    @role = Role.find(1)
  end

  # ------------------------------------------------------------------ helpers
  #
  # All above the tests — see the Minitest trap in the class comment.

  def bundle(*templates)
    JSON.generate('format_version' => 1,
                  'exported_at' => '2025-12-29T10:30:20Z',
                  'plugin_version' => '0.5.0',
                  'templates' => templates)
  end

  def entry(overrides = {})
    { 'name' => 'Imported', 'description' => 'from a file',
      'content' => '<h1>{{ project.name }}</h1>', 'source' => 'issues',
      'output' => 'combined', 'orientation' => 'portrait', 'page_size' => 'A4',
      'margins' => '20,15,20,15', 'engine_hint' => nil, 'enabled' => true,
      'failure_document' => false }.merge(overrides)
  end

  def create_template(attributes = {})
    Template.create!({ project: @project, author: @jsmith, name: 'Existing',
                       content: '<p>local</p>', source: 'issues',
                       output: 'combined' }.merge(attributes))
  end

  def importer(actor: @admin, on_conflict: 'skip')
    BundleImport.new(project: @project, actor: actor, on_conflict: on_conflict)
  end

  # EXACTLY these permissions and no others — `add_permission!` accumulates, and a test
  # that adds to whatever the fixture role already holds is a test whose subject is the
  # fixture. The same helper T-23's controller test uses, for the same reason.
  def grant(*permissions)
    @role.permissions = permissions.map(&:to_s)
    @role.save!
    User.current = nil
  end

  # Every statement the block issues, so a claim about WRITING can be made about the SQL
  # rather than about the rows. HANDOVER §1: reading the row back cannot prove a write did
  # not happen, because a write that was rolled back leaves the same row as no write.
  def statements_during
    collected = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      payload = ActiveSupport::Notifications::Event.new(*args).payload
      collected << payload[:sql] unless payload[:name] == 'SCHEMA'
    end
    yield
    collected
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # THE COMMENT IS STRIPPED BEFORE THE VERB IS READ. HANDOVER §1: an SQL assertion anchored
  # at `\A` is defeated by one leading `/* rails */`, and `query_log_tags_enabled` is an
  # ordinary Redmine setting that prepends exactly that to every statement. T-24's central
  # claim was asserted that way and a planted UPDATE survived it.
  def writes_among(statements)
    statements.map { |sql| sql.sub(%r{\A(?:\s|/\*.*?\*/)+}m, '') }
              .select { |sql| sql.match?(/\A(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP)\b/i) }
  end

  # ------------------------------------------------------------------ the plan writes nothing

  def test_plan_issues_no_write_statement_at_all
    create_template(name: 'Imported')
    content = bundle(entry, entry('name' => 'Second'))

    statements = statements_during { importer.plan(content) }

    assert_not_empty statements, 'the plan issued no SQL at all, so this asserts nothing'
    assert_equal [], writes_among(statements),
                 "FR-56: the plan must write nothing.\n#{writes_among(statements).join("\n")}"
  end

  def test_plan_creates_no_template_and_no_version
    content = bundle(entry, entry('name' => 'Second'))

    assert_no_difference ['RedmineReporterDashboards::Template.count',
                          'RedmineReporterDashboards::TemplateVersion.count'] do
      importer.plan(content)
    end
  end

  # THE PLAN AND THE APPLY MUST AGREE, entry for entry. A plan that says "3 new, 1
  # overwritten" and an apply that then does something else is worse than no plan at all,
  # because the operator acted on it — which is why `#decide` is one method called by both
  # rather than two implementations of one rule.
  def test_the_plan_predicts_exactly_what_the_apply_does
    create_template(name: 'Imported')
    content = bundle(entry, entry('name' => 'Fresh'))

    planned = importer(on_conflict: 'rename').plan(content)
    applied = importer(on_conflict: 'rename').apply(content)

    assert_equal planned.outcomes.map(&:action), applied.outcomes.map(&:action)
    assert_equal planned.outcomes.map(&:applied_name), applied.outcomes.map(&:applied_name)
  end

  # ------------------------------------------------------------------ creating

  def test_a_new_template_is_created_owned_by_the_actor_and_private
    report = importer.apply(bundle(entry))

    assert_equal [:create], report.outcomes.map(&:action)
    imported = Template.order(:id).last
    assert_equal 'Imported', imported.name
    assert_equal @project.id, imported.project_id
    assert_equal @admin.id, imported.author_id
    assert_equal Template::VISIBILITY_PRIVATE, imported.visibility
  end

  # THE FILE MAY NOT CHOOSE ANY OF THE THREE — the end-to-end statement of it.
  #
  # WHICH MECHANISM HOLDS THIS WAS ESTABLISHED BY MUTATION, NOT BY READING. Removing the
  # importer's `template.visibility = PRIVATE` and its `template.author_id = actor.id` both
  # SURVIVED: neither field ever arrives, because `Exchange.attributes_from` slices the
  # node to `EXPORTED_FIELDS` and none of the three is in it. The closed field list is the
  # guard; `spec/reporting/bundle_spec.rb`'s "the three fields a bundle cannot carry at
  # all" asserts it directly, and the assignments in `BundleImport#create` are documented
  # redundancy — kept because a field added to `EXPORTED_FIELDS` later would move the
  # property from one mechanism to the other, and said out loud so nobody mistakes this
  # test for proof of the assignment.
  def test_a_bundle_cannot_choose_its_own_visibility_author_or_project
    hostile = entry('visibility' => Template::VISIBILITY_PUBLIC,
                    'author_id' => @dlopper.id, 'project_id' => 2)

    importer.apply(bundle(hostile))

    imported = Template.order(:id).last
    assert_equal Template::VISIBILITY_PRIVATE, imported.visibility
    assert_equal @admin.id, imported.author_id
    assert_equal @project.id, imported.project_id
  end

  # ------------------------------------------------------------------ conflicts

  def test_skip_leaves_the_existing_template_alone_and_says_why
    existing = create_template(name: 'Imported', content: '<p>local</p>')

    report = nil
    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      report = importer(on_conflict: 'skip').apply(bundle(entry))
    end

    assert_equal [:skip], report.outcomes.map(&:action)
    assert_match(/already in this project/, report.outcomes.first.reason)
    assert_equal '<p>local</p>', existing.reload.content
  end

  def test_rename_imports_under_a_free_name_and_keeps_the_original
    existing = create_template(name: 'Imported', content: '<p>local</p>')

    report = importer(on_conflict: 'rename').apply(bundle(entry))

    assert_equal [:rename], report.outcomes.map(&:action)
    assert_equal 'Imported (2)', report.outcomes.first.applied_name
    assert_equal '<p>local</p>', existing.reload.content
    assert Template.exists?(project_id: @project.id, name: 'Imported (2)')
  end

  def test_rename_keeps_counting_when_the_renamed_name_is_also_taken
    create_template(name: 'Imported')
    create_template(name: 'Imported (2)')

    report = importer(on_conflict: 'rename').apply(bundle(entry))

    assert_equal 'Imported (3)', report.outcomes.first.applied_name
  end

  def test_overwrite_replaces_the_content_and_keeps_the_previous_one_in_history
    existing = create_template(name: 'Imported', content: '<p>local</p>')

    report = nil
    assert_difference 'RedmineReporterDashboards::TemplateVersion.count', 1 do
      report = importer(on_conflict: 'overwrite').apply(bundle(entry))
    end

    assert_equal [:update], report.outcomes.map(&:action)
    assert_equal '<h1>{{ project.name }}</h1>', existing.reload.content
    assert_equal '<p>local</p>', existing.versions.order(:id).last.content,
                 'the content that was here must be recoverable'
  end

  # OVERWRITING SOMEBODY ELSE'S TEMPLATE MUST NOT TAKE IT AWAY FROM THEM. A bundle that
  # could flip an existing private template to public would be a disclosure primitive, and
  # one that could reassign `author_id` would move the template out of its author's
  # `edit_own_…` reach.
  def test_overwrite_leaves_the_owner_and_the_visibility_alone
    existing = create_template(name: 'Imported', author: @jsmith,
                               visibility: Template::VISIBILITY_PUBLIC)

    importer(on_conflict: 'overwrite').apply(bundle(entry))

    existing.reload
    assert_equal @jsmith.id, existing.author_id
    assert_equal Template::VISIBILITY_PUBLIC, existing.visibility
  end

  # THE PERMISSION IS THE SAME ONE THE CONTROLLER ASKS, so "may I overwrite this" gets the
  # same answer at a rake prompt as it does over HTTP — including the `edit_own_…` case,
  # where the answer depends on WHO AUTHORED the template rather than on the project.
  def test_overwrite_is_refused_when_the_actor_may_not_edit_that_template
    existing = create_template(name: 'Imported', author: @dlopper,
                               content: '<p>dloppers</p>')
    grant(:edit_own_reporter_dashboards_templates)

    report = importer(actor: @jsmith, on_conflict: 'overwrite').apply(bundle(entry))

    assert_equal [:skip], report.outcomes.map(&:action)
    assert_match(/may not edit/, report.outcomes.first.reason)
    assert_equal '<p>dloppers</p>', existing.reload.content
  end

  # THE POSITIVE HALF, which nothing asserted: overwrite SUCCEEDS for a template the actor
  # authored when they hold `edit_own_…`. Without this the whole arm could be refusing
  # every request and the suite would stay green.
  def test_overwrite_succeeds_for_a_template_the_actor_authored
    existing = create_template(name: 'Imported', author: @jsmith, content: '<p>local</p>')
    grant(:edit_own_reporter_dashboards_templates)

    report = importer(actor: @jsmith, on_conflict: 'overwrite').apply(bundle(entry))

    assert_equal [:update], report.outcomes.map(&:action)
    assert_equal '<h1>{{ project.name }}</h1>', existing.reload.content
  end

  # CREATING NEEDS A PERMISSION, and until an independent review asked, only overwriting
  # had one. The shipped rake task only ever hands this class an administrator, so the hole
  # was unreachable — but "no caller reaches it today" is not a guard.
  def test_creating_is_refused_for_an_actor_who_may_not_add_templates_here
    grant(:view_issues)

    report = nil
    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      report = importer(actor: @jsmith).apply(bundle(entry))
    end

    assert_equal [:skip], report.outcomes.map(&:action)
    assert_match(/may not add/, report.outcomes.first.reason)
  end

  # AND THE POSITIVE HALF, so the guard cannot be refusing everything.
  def test_creating_succeeds_for_an_actor_who_holds_the_add_permission
    grant(:add_reporter_dashboards_templates)

    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      importer(actor: @jsmith).apply(bundle(entry))
    end
  end

  def test_an_unknown_conflict_policy_is_refused_at_construction
    error = assert_raises(ArgumentError) { importer(on_conflict: 'clobber') }

    assert_match(/not a conflict policy/, error.message)
    assert_match(/skip, rename, overwrite/, error.message)
  end

  def test_an_import_without_an_actor_is_refused
    assert_raises(ArgumentError) do
      BundleImport.new(project: @project, actor: nil, on_conflict: 'skip')
    end
  end

  # ------------------------------------------------------------------ FR-56's core claim

  # ONE BAD TEMPLATE DOES NOT ABORT THE BUNDLE. The middle entry has a `page_size` outside
  # the model's closed list, so `save!` raises — and the two either side must still be
  # here afterwards. A single transaction around the whole bundle would leave NONE of
  # them, and would look identical in a test that only counted the failure.
  def test_one_bad_template_does_not_abort_the_rest_of_the_bundle
    content = bundle(entry('name' => 'Good one'),
                     entry('name' => 'Broken', 'page_size' => 'A9'),
                     entry('name' => 'Good two'))

    report = nil
    assert_difference 'RedmineReporterDashboards::Template.count', 2 do
      report = importer.apply(content)
    end

    assert_equal %i[create failed create], report.outcomes.map(&:action)
    assert report.failed?
    assert Template.exists?(project_id: @project.id, name: 'Good one')
    assert Template.exists?(project_id: @project.id, name: 'Good two')
    assert_not Template.exists?(project_id: @project.id, name: 'Broken')
  end

  def test_a_failed_template_is_reported_with_a_reason_rather_than_silently_missing
    report = importer.apply(bundle(entry('name' => 'Broken', 'page_size' => 'A9')))

    outcome = report.outcomes.first
    assert_equal :failed, outcome.action
    assert_not_nil outcome.reason
    assert_match(/page size|page_size|Page size/i, outcome.reason)
  end

  # THE PER-TEMPLATE TRANSACTION, PROVEN ON THE PATH THAT WRITES TWICE.
  #
  # The create path is a single `save!`, so its rollback is trivial and proves little. The
  # OVERWRITE path writes the version snapshot FIRST and then the template — so if the
  # second write fails, a missing savepoint leaves the snapshot behind: an audit row
  # recording a change that never happened. This is the example that would go red if
  # `requires_new: true` were dropped, which is precisely the mutation that otherwise does
  # nothing visible inside a Rails test's own transaction.
  # THE SAVEPOINT, MADE OBSERVABLE — and it was not, which mutation testing found.
  #
  # `requires_new: true` is a NO-OP inside an ordinary Rails transactional test, so the
  # mutation that removed it survived. Measured: a Rails test wraps each example in a
  # transaction marked NON-JOINABLE, and under a non-joinable parent `transaction` opens a
  # real savepoint whether or not `requires_new` is passed (`open_transactions` goes to 2
  # either way). The flag only decides anything under a JOINABLE parent — which is exactly
  # the case it exists for: a CALLER that wraps the whole import in its own transaction.
  #
  # So this example opens that transaction itself. Without `requires_new: true` the
  # importer's per-template transaction joins this one, the failed entry's version snapshot
  # is not rolled back, and an audit row survives recording a change that never happened.
  def test_the_per_template_savepoint_survives_a_caller_wrapped_transaction
    existing = create_template(name: 'Imported', content: '<p>local</p>')
    content = bundle(entry('page_size' => 'A9'))

    report = nil
    assert_no_difference 'RedmineReporterDashboards::TemplateVersion.count' do
      # A JOINABLE outer transaction, the way a controller action or another rake task
      # would open one. The test's own wrapping transaction is not joinable and therefore
      # cannot stand in for it.
      Template.transaction do
        report = importer(on_conflict: 'overwrite').apply(content)
      end
    end

    assert_equal [:failed], report.outcomes.map(&:action)
    assert_equal '<p>local</p>', existing.reload.content
  end

  # OVERWRITE MUST NOT RENAME, and on PostgreSQL this cannot be reached through `#decide` —
  # `find_conflict` matches the name exactly, so the entry's name always equals the
  # existing one and the guard is a no-op. It is NOT a no-op on MySQL and MariaDB, whose
  # default collations are case-INSENSITIVE: `where(name: 'REPORT')` matches a stored
  # `Report` there, and without the guard an overwrite would silently rename somebody's
  # template to the sender's capitalisation.
  #
  # Driven directly for that reason. The engines this project runs disagree about whether
  # the state is reachable, and a guard that is only exercised on one of them is finding
  # S-9's shape again.
  def test_overwrite_never_renames_the_template_it_overwrites
    existing = create_template(name: 'Imported', content: '<p>local</p>')

    importer.send(:overwrite, existing, entry('name' => 'IMPORTED'))

    assert_equal 'Imported', existing.reload.name
    assert_equal '<h1>{{ project.name }}</h1>', existing.content
  end

  def test_a_failure_after_the_version_snapshot_rolls_the_snapshot_back_too
    existing = create_template(name: 'Imported', content: '<p>local</p>')
    content = bundle(entry('page_size' => 'A9'))

    report = nil
    assert_no_difference 'RedmineReporterDashboards::TemplateVersion.count' do
      report = importer(on_conflict: 'overwrite').apply(content)
    end

    assert_equal [:failed], report.outcomes.map(&:action)
    assert_equal '<p>local</p>', existing.reload.content,
                 'the template was left half-overwritten'
  end

  # ------------------------------------------------------------------ two templates, one name

  # `Template` HAS NO UNIQUENESS VALIDATION ON `name` — it copies core's `Query`, which has
  # none — so a project may legitimately hold two templates called the same thing and an
  # export faithfully contains both. The importer used to ask the DATABASE per entry, so the
  # second one collided with the first one THIS RUN had just written and was dropped under
  # the default policy, with a reason that was not what happened.
  def test_a_bundle_carrying_two_templates_with_one_name_imports_both
    content = bundle(entry('name' => 'Same', 'content' => '<p>FIRST</p>'),
                     entry('name' => 'Same', 'content' => '<p>SECOND</p>'))

    report = nil
    assert_difference 'RedmineReporterDashboards::Template.count', 2 do
      report = importer(on_conflict: 'skip').apply(content)
    end

    assert_equal %i[create create], report.outcomes.map(&:action)
    contents = Template.where(project_id: @project.id, name: 'Same').order(:id).pluck(:content)
    assert_equal ['<p>FIRST</p>', '<p>SECOND</p>'], contents,
                 'one of the two templates was silently dropped'
  end

  # AND THE PLAN PREDICTS IT. This is the case the class comment calls "worse than no plan
  # at all": the operator is told two will be imported and presses apply. Before the
  # snapshot, plan said {create, create} and apply did {create, skip}.
  def test_the_plan_predicts_the_apply_for_two_templates_sharing_a_name
    content = bundle(entry('name' => 'Twin'), entry('name' => 'Twin'))

    planned = importer.plan(content)
    applied = importer.apply(content)

    assert_equal planned.outcomes.map(&:action), applied.outcomes.map(&:action)
    assert_equal %i[create create], applied.outcomes.map(&:action)
    assert_equal 2, Template.where(project_id: @project.id, name: 'Twin').count
  end

  # RENAME MUST NOT HAND BOTH ENTRIES THE SAME NEW NAME either, and plan must agree with
  # apply about which names it chose.
  def test_rename_gives_two_colliding_entries_distinct_names_and_the_plan_says_so
    create_template(name: 'Same')
    content = bundle(entry('name' => 'Same'), entry('name' => 'Same'))

    planned = importer(on_conflict: 'rename').plan(content)
    applied = importer(on_conflict: 'rename').apply(content)

    assert_equal ['Same (2)', 'Same (3)'], applied.outcomes.map(&:applied_name)
    assert_equal planned.outcomes.map(&:applied_name), applied.outcomes.map(&:applied_name)
  end

  # ------------------------------------------------------------------ FR-57, end to end

  # THE ROUND TRIP THROUGH THE REAL MODEL, not through the DB-less fake. `bundle_spec.rb`
  # proves the FORMAT round-trips; this proves that what ActiveRecord stores and reads back
  # does too — column defaults, boolean casting and `failure_document?`'s `!!` all sit
  # between the two exports and none of them is exercised by a Struct.
  def test_export_import_export_is_byte_identical_through_the_real_model
    create_template(name: 'Alpha', content: '<p>a</p>', page_size: 'A3')
    create_template(name: 'Beta', content: "<p>Übersicht — 中文</p>", failure_document: true)
    at = '2025-12-29T10:30:20Z'

    first = Bundle.dump(Template.where(project_id: @project.id).order(:name, :id),
                        exported_at: at, plugin_version: '0.5.0')

    # A CLEAN RECEIVING PROJECT, so the import creates rather than skipping — and so the
    # ids it assigns are different from the ids the first export saw, which is what makes
    # "sorted by name, not by id" a claim worth making.
    receiving = Project.generate!
    receiving.enable_module!(:reporter_dashboards_reports)
    BundleImport.new(project: receiving, actor: @admin, on_conflict: 'skip').apply(first)

    second = Bundle.dump(Template.where(project_id: receiving.id).order(:name, :id),
                         exported_at: at, plugin_version: '0.5.0')

    assert_equal first, second, 'FR-57: export -> import -> export must be byte-identical'
  end

  # FR-57 ON THE BUNDLE THAT USED TO BREAK IT. The DB-less round trip cannot fail this way:
  # its "receiving installation" is a stub that rebuilds every entry unconditionally, so it
  # never applies a conflict policy and never drops anything. Only the real importer can.
  def test_export_import_export_is_byte_identical_for_two_templates_sharing_a_name
    create_template(name: 'Same', content: '<p>a</p>')
    create_template(name: 'Same', content: '<p>b</p>', page_size: 'A3')
    at = '2025-12-29T10:30:20Z'

    first = Bundle.dump(Template.where(project_id: @project.id).order(:name, :id),
                        exported_at: at, plugin_version: '0.5.0')
    receiving = Project.generate!
    receiving.enable_module!(:reporter_dashboards_reports)
    BundleImport.new(project: receiving, actor: @admin, on_conflict: 'skip').apply(first)
    second = Bundle.dump(Template.where(project_id: receiving.id).order(:name, :id),
                         exported_at: at, plugin_version: '0.5.0')

    assert_equal first, second
  end

  # ------------------------------------------------------------------ §7 rule 5

  # A FIELD THIS SCHEMA HAS NO COLUMN FOR IS DROPPED, NOT RAISED ON. §7 rule 5: an install
  # one minor behind must degrade rather than crash — and before T-29 this reached
  # `Template.new` and raised `ActiveModel::UnknownAttributeError`, which is a stack trace
  # where the rule asks for a degraded feature.
  # THE COLUMN IS TAKEN AWAY RATHER THAN AN UNKNOWN FIELD ADDED, and the difference is the
  # whole test. The first version passed `some_future_column` — which never reaches the
  # importer at all, because `Exchange.attributes_from` slices the node to
  # `EXPORTED_FIELDS` first. So it exercised nothing, and the mutation "assignable keeps
  # unknown columns" SURVIVED it.
  #
  # The real rule-5 case is a field that IS exported and has NO COLUMN here: a bundle
  # written by a current install, read by one a minor version behind. `failure_document`
  # arrived in migration 008 and is exactly that field.
  #
  # --- WHAT THIS STUB DOES AND DOES NOT REPRODUCE, said plainly ---
  #
  # Stubbing `column_names` feeds the guard the input an older schema would give it, and
  # that is all. It does NOT reproduce the `ActiveModel::UnknownAttributeError` a genuinely
  # absent column causes: attribute assignment consults the attribute type set, not
  # `column_names`, so under this stub `Template.new('failure_document' => true)` succeeds.
  # An earlier version of this file asserted that it raises, and that assertion was simply
  # WRONG — it was deleted rather than weakened. Dropping the column for real is not
  # available: HANDOVER §1 records that DDL inside a test is rolled back by PostgreSQL and
  # implicitly COMMITTED by MySQL, so it would wreck the schema for everything after it on
  # one of the two supported engines.
  #
  # So the observable asserted here is the one the guard actually controls and the one
  # INV-4 requires: the field is dropped and the drop is SAID. That is also what makes the
  # mutation die — a guard that keeps everything logs nothing.
  def test_a_field_this_schema_has_no_column_for_is_dropped_and_the_drop_is_logged
    older_schema = Template.column_names - ['failure_document']
    Template.stubs(:column_names).returns(older_schema)
    log = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |line| log << line }
    subject = BundleImport.new(project: @project, actor: @admin, on_conflict: 'skip',
                               logger: logger)

    report = nil
    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      report = subject.apply(bundle(entry('failure_document' => true)))
    end

    assert_equal [:create], report.outcomes.map(&:action),
                 'an older schema must degrade, not raise'
    assert log.any? { |line| line.include?('failure_document') },
           "the dropped field must be named in the log (INV-4). Saw:\n#{log.join("\n")}"
  end

  # ------------------------------------------------------------------ two thin branches

  # THE TRUNCATION EXISTS BECAUSE `" (2)"` ON A 255-CHARACTER NAME IS 259, which validates
  # nowhere and raises `ValueTooLong` on MySQL — an engine this project runs and this
  # container cannot install (HANDOVER §4). So the branch is asserted on the length rather
  # than left for that CI cell to discover.
  def test_a_rename_at_the_length_limit_truncates_instead_of_overrunning_it
    long = 'N' * Template::MAX_STRING
    create_template(name: long)

    report = importer(on_conflict: 'rename').apply(bundle(entry('name' => long)))

    applied = report.outcomes.first.applied_name
    assert_equal :rename, report.outcomes.first.action
    assert applied.length <= Template::MAX_STRING,
           "the renamed name is #{applied.length} characters and the column takes " \
           "#{Template::MAX_STRING}"
    assert applied.end_with?(' (2)')
    assert Template.exists?(project_id: @project.id, name: applied)
  end

  # A LINTER FAILURE IS NOT AN IMPORT FAILURE. The lint is advice printed beside the
  # decision; if it raises on some pathological body the operator must still be told what
  # the import will do, and the report must not print "0 errors", which is a claim nobody
  # made. `BundleReport` prints `[lint did not run]` for the nil case and nothing reached
  # it until this test.
  def test_a_linter_that_raises_does_not_fail_the_import_and_is_not_reported_as_clean
    RedmineReporterDashboards::TemplateLinter.stubs(:analyse)
                                             .raises(RuntimeError, 'linter exploded')

    report = importer.plan(bundle(entry))

    assert_equal [:create], report.outcomes.map(&:action)
    assert_nil report.outcomes.first.lint_errors
    assert_include '[lint did not run]',
                   RedmineReporterDashboards::Reporting::BundleReport.render(report)
  end

  # AND A LOGGER THAT RAISES MUST NOT ABORT THE BUNDLE — T-25's defect, in the shape it
  # took there: an exception from a log line inside a rescue body leaves the loop, so every
  # LATER item silently does not happen. FR-56's "one bad template does not abort the
  # bundle" is the claim it would break, using the code written to satisfy it.
  def test_a_logger_that_raises_does_not_stop_the_rest_of_the_bundle
    exploding = Object.new
    exploding.define_singleton_method(:warn) { |_line| raise Errno::EPIPE }
    subject = BundleImport.new(project: @project, actor: @admin, on_conflict: 'skip',
                               logger: exploding)
    content = bundle(entry('name' => 'Broken', 'page_size' => 'A9'),
                     entry('name' => 'After the broken one'))

    report = nil
    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      report = subject.apply(content)
    end

    assert_equal %i[failed create], report.outcomes.map(&:action)
    assert Template.exists?(project_id: @project.id, name: 'After the broken one'),
           'the entry after the failure was never imported: the log line took the loop down'
  end

  # ------------------------------------------------------------------ the report

  def test_the_plan_carries_lint_findings_per_template
    # `<script>` in a body is one of `TemplateLinter`'s own rules, so this asks the real
    # linter a question it really answers rather than stubbing a count.
    noisy = entry('name' => 'Noisy', 'content' => "<script>var a = 'x' + b;</script>")

    report = importer.plan(bundle(noisy))

    assert_not_nil report.outcomes.first.lint_errors
    assert_not_nil report.outcomes.first.lint_warnings
  end

  def test_the_rendered_report_never_says_OK_when_a_template_failed
    report = importer.apply(bundle(entry('name' => 'Broken', 'page_size' => 'A9')))
    text = RedmineReporterDashboards::Reporting::BundleReport.render(report)

    assert_match(/FAILED/, text)
    assert_no_match(/\AOK\.\z/, text)
  end

  # A BUNDLE WHERE EVERY TEMPLATE WAS SKIPPED IMPORTED NOTHING, and an operator reading a
  # bare "OK." would believe the opposite. The same reason `PreflightCommand` separates
  # `ok?` from `complete?` and never prints a bare OK when a check was skipped.
  def test_the_rendered_report_says_so_when_everything_was_skipped
    create_template(name: 'Imported')

    report = importer(on_conflict: 'skip').apply(bundle(entry))
    text = RedmineReporterDashboards::Reporting::BundleReport.render(report)

    assert_match(/Nothing was imported/, text)
  end
end
