# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-26 — the my-page widget, rendered the way Redmine renders it.
#
# --- WHY THIS FILE EXISTS AT ALL ---
#
# This plugin ships `app/views/my/blocks/_report_by_issues.erb`, and that path is not
# an implementation detail: Redmine core DISCOVERS my-page blocks by globbing plugin
# view directories.
#
#     # redmine/lib/redmine/my_page.rb — THIS LINE is byte-identical on 5.1 and 7.0
#     Dir.glob("#{Redmine::Plugin.directory}/*/app/views/my/blocks/_*.{rhtml,erb}")
#
# The scoping matters: the FILE is not identical across that span (the line after the
# glob moved from `gsub(/^_/, '')` to `delete_prefix('_')`), and an earlier version of
# this comment claimed the file was. The glob is the load-bearing half.
#
# So the mere presence of that file makes THIS plugin contribute a core my-page block
# named `report_by_issues` on every install, whether or not redmine_reporter is there.
# The partial then calls `IssueListReportTemplate` — a redmine_reporter constant —
# unconditionally, on line 14, before any guard.
#
# Core's `MyHelper#render_block_content` rescues **only** `ActionView::MissingTemplate`
# (`app/helpers/my_helper.rb:59`). Anything else propagates, so the exception does not
# degrade to a broken widget: it takes `/my/page` down with a 500 — and with it the very
# page the user would need in order to remove the block again.
#
# TWO configurations reach that raise, and the second is the one that matters most:
#
#   1. **Standalone** (no redmine_reporter): `IssueListReportTemplate` is undefined →
#      `NameError`. This is the supported standalone configuration T-06 was written for;
#      T-06 fixed it for the PROJECT dashboard by putting those partials where core's
#      glob cannot see them; T-26a then removed the raise from that surface entirely, by
#      making the project-dashboard widgets this plugin's own — they live in
#      `app/views/reporter_project_pages/report_blocks/` and name no base-plugin class.
#      The my-page surface has NOT had either treatment: core's `MyPage` offers no
#      directory the glob misses, so the guard has to be in the partial until the my-page
#      widget is owned too (T-26a increment 3).
#   2. **Redmine 7.0 with redmine_reporter INSTALLED.** Reporter's report-template
#      classes use the keyword form of `enum`, removed in Rails 8.0, so referencing
#      `IssueListReportTemplate` raises there too. MEASURED on Redmine 7.0.0.stable /
#      Rails 8.1.3.1: `enum status: {...}` → `ArgumentError: wrong number of arguments
#      (given 0, expected 1..2)`, while `enum :status, {...}` is accepted.
#
# Deleting this plugin's partial does NOT fix case 2 — reporter ships its own
# `my/blocks/_report_by_issues.erb`, which core would then glob instead and which makes
# the same unguarded call. Only a guard that WINS the view load path helps, and this
# plugin's override does win it (it sorts after redmine_reporter).
#
# An integration test is the only level at which any of this is visible: nothing here
# is reachable from a controller test, because the block is discovered from the
# filesystem and rendered through core's helper.
class ReporterDashboardsMyPageBlockTest < Redmine::IntegrationTest
  include Redmine::I18n

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers,
           :queries

  BLOCK = 'report_by_issues'

  ISSUE_CLASS = 'IssueListReportTemplate'

  def setup
    @jsmith = User.find_by!(login: 'jsmith')
    # LOCALE IS PINNED, NOT INHERITED. The request locale comes from `User#language`,
    # sourced from Redmine's own BRANCH-VERSIONED `test/fixtures/users.yml`, so an
    # assertion on `l(...)` otherwise depends on what that fixture happens to say on
    # whichever Redmine is checked out — the inheritance §6 forbids.
    # `test/functional/reporter_preflight_controller_test.rb:416-426` records this from an
    # earlier review round; this file was missing it.
    @jsmith.update_column(:language, 'en')
    User.current = nil
    log_user('jsmith', 'jsmith')
    # BOTH memoised answers, both ends. `ReporterReportTemplates` caches its verdict for
    # the life of the process, so a test that stubs presence would otherwise leak its
    # answer into whatever ran next — and the leak is order-dependent, which is the
    # shape §6 forbids.
    RedmineReporterDashboards::ReporterReportTemplates.reset!
  end

  def teardown
    User.current = nil
    RedmineReporterDashboards::ReporterReportTemplates.reset!
    remove_planted_class
  end

  # THE PREMISE, asserted rather than assumed. If core ever stops globbing plugin
  # view directories this whole file becomes moot, and it should say so out loud
  # rather than keep passing for a reason that has gone away.
  def test_core_discovers_this_plugins_partial_as_a_my_page_block
    assert Redmine::MyPage.blocks.key?(BLOCK),
           'core no longer registers this plugin\'s my/blocks partial — if that is ' \
           'deliberate, this file and the guard it covers can go'
    assert_equal 'my/blocks/report_by_issues',
                 Redmine::MyPage.blocks[BLOCK][:partial]
  end

  # THE REGRESSION. With the block on the user's page, `/my/page` must render.
  #
  # `assert_response :success` is the whole point: before the guard this raised
  # `NameError` out of the partial, through core's MissingTemplate-only rescue, and
  # `/my/page` returned 500 for that user on every single page load.
  def test_my_page_renders_when_the_report_block_is_on_it_and_reporter_is_unavailable
    skip_if_reporter_report_templates_load

    put_block_on_my_page

    get '/my/page'

    assert_response :success
  end

  # AND THE WIDGET SAYS WHY, rather than rendering as nothing.
  #
  # A widget that renders empty loses its own contextual controls, so nobody can take
  # it off the dashboard any more — the same argument `reporter_project_pages_helper.rb`
  # makes for the project dashboard's placeholder. The box stays, carrying its reason.
  def test_the_unavailable_block_renders_a_labelled_placeholder_not_an_empty_box
    skip_if_reporter_report_templates_load

    put_block_on_my_page

    get '/my/page'

    assert_response :success
    # `block-<name>` is core's wrapper id (`MyHelper#render_block`), and the assertion is
    # pinned to the SENTENCE a user reads rather than to a key name, by equality.
    assert_select "#block-#{BLOCK} p.nodata",
                  text: l(:text_reporter_widget_requires_plugin, plugin: 'redmine_reporter'),
                  count: 1
  end

  # THE BOX SURVIVES, and this is the assertion that makes the placeholder load-bearing
  # rather than decorative. `MyHelper#render_block` wraps a block only `if
  # content.present?`, so had the guard rendered nil this element — and the close button
  # inside it — would be absent, and the block would be unremovable through the UI.
  def test_the_unavailable_block_keeps_its_close_button
    skip_if_reporter_report_templates_load

    put_block_on_my_page

    get '/my/page'

    assert_response :success
    assert_select "#block-#{BLOCK} .contextual a.icon-close", count: 1
  end

  # THE FLOW A USER TAKES NEXT. The placeholder is only worth having if the block can
  # still be removed afterwards — that is the reason it is a placeholder rather than nil.
  #
  # `POST my/remove_block` with a `block` param is core's route (`config/routes.rb:104`);
  # the first version of this test invented `DELETE /my/page/:block` and got a 404, which
  # would have read as a broken flow rather than a wrong test.
  def test_the_unavailable_block_can_still_be_removed_from_the_page
    skip_if_reporter_report_templates_load

    put_block_on_my_page

    post '/my/remove_block', params: { block: BLOCK }, xhr: true

    assert_response :success
    assert_not_include BLOCK, @jsmith.reload.pref.my_page_layout.values.flatten
  end

  # --- THE CONFIGURATION THIS WAS ACTUALLY REPORTED ON: Redmine 7.0 WITH reporter ---
  #
  # The two cases above run with redmine_reporter absent, which is not the install that
  # prompted this work. Here presence is stubbed TRUE while the classes still do not
  # resolve, which is exactly what Redmine 7.0 + redmine_reporter is: `installed?` says
  # yes, and `IssueListReportTemplate` raises because reporter's `enum` keyword form was
  # removed in Rails 8.0.
  #
  # It is stubbed rather than staged because the real article is a paid third-party
  # plugin that is not in this tree. What the stub does NOT fake is the failure itself:
  # the classes are genuinely unresolvable in this process, so `load_error` is a real
  # exception from a real failed constant lookup, not a canned one.
  def test_my_page_renders_when_reporter_is_installed_but_its_classes_do_not_load
    skip_if_reporter_report_templates_load

    RedmineReporterDashboards.stubs(:reporter_present?).returns(true)
    put_block_on_my_page

    get '/my/page'

    assert_response :success
    # A DIFFERENT sentence from the not-installed case, and that distinction is the
    # point: "needs a plugin you have not installed" is wrong and actively misleading
    # for an operator who HAS installed it.
    assert_select "#block-#{BLOCK} p.nodata",
                  text: l(:error_reporter_widget_render_failed),
                  count: 1
    assert_select "#block-#{BLOCK} p.nodata",
                  text: l(:text_reporter_widget_requires_plugin, plugin: 'redmine_reporter'),
                  count: 0
  end

  # AND IT IS LOGGED, once, with the reason — because the placeholder deliberately does
  # not put the exception on the page (INV-5: an error is not the document). If nothing
  # were logged, an operator would have a blank-looking widget and nothing to go on.
  def test_the_load_failure_is_logged_with_its_cause
    skip_if_reporter_report_templates_load

    RedmineReporterDashboards.stubs(:reporter_present?).returns(true)

    # THREE asks, because the claim in the source is "once". This is asked on every
    # render of every my-page carrying the widget, and a per-render line would bury the
    # log it is supposed to draw attention to. One ask cannot tell "once" from
    # "every time".
    logged = capturing_rails_log do
      3.times { RedmineReporterDashboards::ReporterReportTemplates.usable?(ISSUE_CLASS) }
    end

    lines = logged.lines.grep(/report template classes do not load/)
    assert_equal 1, lines.size,
                 "expected exactly one WARN across three asks, got: #{logged.inspect}"
    assert_match(/NameError/, logged)
  end

  # --- A GUARD WHOSE ONLY SIGNATURE IS THE LOG, SO THE LOG IS WHERE IT IS ASSERTED ---
  #
  # `usable?` asks the plugin REGISTRY before it touches a reporter constant, and
  # `reporter_presence.rb` states why: absence must be a positive question, never
  # inferred from a swallowed `NameError`. Deleting that first line changes no page
  # outcome at all — the partial re-asks `reporter_present?` for its wording, and
  # `load_error` returns non-nil either way — so a behavioural test cannot see it.
  # MEASURED: mutating `usable?` to drop the registry question left all seven of the
  # other examples green.
  #
  # What it DOES change is this: a standalone install, where the base plugin is not
  # installed and nothing is wrong, would log "is installed but ... its report template
  # classes do not load" on the first my-page render. A false sentence, in every
  # operator's log, for a supported configuration.
  def test_a_standalone_install_is_not_told_the_base_plugin_failed_to_load
    skip_if_reporter_report_templates_load
    skip_if_reporter_is_really_installed

    subject = RedmineReporterDashboards::ReporterReportTemplates
    logged = capturing_rails_log do
      assert_not subject.usable?(ISSUE_CLASS),
                 'the widgets must not be offered when the base plugin is absent'
    end

    assert_empty logged.lines.grep(/report template classes do not load/),
                 'a standalone install was told the base plugin failed to load, which is ' \
                 'false — the registry question must come before any constant lookup'
  end

  # --- THE GUARD MUST OPEN, NOT JUST CLOSE ---
  #
  # Every example above is about the UNAVAILABLE path, and an independent review showed
  # what that costs: mutating this partial's guard to `<% if false %>` survived the whole
  # 931-test suite. Nothing could tell the shipped guard from a hardcoded refusal, which
  # is a live regression risk for an install running the base plugin on a Redmine where
  # it works.
  #
  # The discriminator has to be chosen carefully, because in THIS tree the widget can
  # never fully render: `my/report` needs the base plugin's
  # `report_content_report_template_path` and the else-branch needs its
  # `my/report_settings` partial, and neither exists here. So the body is entered and
  # then fails — and the DOM it produces is the SAME placeholder the closed guard
  # produces. Asserting on the page cannot separate them.
  #
  # What separates them is the ERROR log that only `log_render_failure` writes, and it
  # is only reachable from inside the guarded body. A closed guard cannot produce it.
  def test_the_guard_opens_when_the_class_resolves_and_the_body_is_entered
    skip_if_reporter_is_really_installed

    plant_issue_class(table: 'queries')
    put_block_on_my_page

    logged = capturing_rails_log { get '/my/page' }

    # THE PAGE-LEVEL CLAIM LIVES HERE, because this failure mode issues no SQL and so is
    # not masked by transactional fixtures (see the SQL example below for why that
    # matters). Before the rescue, this configuration returned 404 and the block vanished
    # with its own close button.
    assert_response :success
    assert_select "#block-#{BLOCK} p.nodata",
                  text: l(:error_reporter_widget_render_failed), count: 1
    assert_select "#block-#{BLOCK} .contextual a.icon-close", count: 1
    assert_match(/my-page report widget could not be rendered/, logged,
                 'the guarded body was never entered — a closed guard produces the same ' \
                 'placeholder, so this log line is the only thing that tells them apart')
  end

  # BLOCKER 1's REGRESSION at the SQL end: the base plugin is installed, its classes
  # RESOLVE, and its tables are not migrated — any Redmine where the plugin is present
  # and `rake redmine:plugins:migrate` has not been run yet. `usable?` answers true, the
  # body is entered, and `find_by` raises.
  #
  # --- WHAT THIS ASSERTS, AND WHY IT IS NOT `assert_response :success` ---
  #
  # The rescue fires here and the widget degrades — that is what is asserted. The page
  # still ends 500 in THIS test, and the cause is the test harness rather than the
  # plugin. MEASURED, rather than assumed, because the first version of this test simply
  # expected 200 and the honest reading of the failure was not obvious:
  #
  #     RESCUED: ActiveRecord::StatementInvalid
  #     AFTERWARDS RAISES: ActiveRecord::StatementInvalid: PG::InFailedSqlTransaction:
  #       ERROR: current transaction is aborted, commands ignored until end of
  #       transaction block
  #
  # A failed statement aborts the enclosing PostgreSQL transaction, and transactional
  # fixtures wrap the whole request in one — so every later query in the request fails no
  # matter what this plugin does. Rails does not wrap a production request in a
  # transaction, so there the page completes. Asserting 200 here would be asserting a
  # property of the harness; asserting the degradation is asserting the plugin.
  #
  # The page-level claim is therefore made by
  # `test_the_guard_opens_when_the_class_resolves_and_the_body_is_entered`, whose failure
  # mode issues no SQL and which does return 200.
  def test_a_failure_inside_the_widget_body_is_rescued_and_named
    skip_if_reporter_is_really_installed

    plant_issue_class(table: 'no_such_table_for_rrd_probe')
    put_block_on_my_page
    assert RedmineReporterDashboards::ReporterReportTemplates.usable?(ISSUE_CLASS),
           'precondition: the guard must be OPEN, or this proves nothing about the rescue'

    logged = capturing_rails_log { get '/my/page' }

    assert_match(/my-page report widget could not be rendered/, logged,
                 'the widget body raised and nothing rescued it — this is the 500 the ' \
                 'pre-check alone did not prevent')
    assert_match(/StatementInvalid/, logged,
                 'the log must name the cause; the page deliberately does not (INV-5)')
  end

  # THE SUCCESS MEMO, asserted where it is made. `load_error` stores `false` on success
  # precisely so a working install does not walk the constant again on every my-page
  # render; dropping the `|| false` reintroduces that per-render walk and changes no
  # value anywhere, so only the constructor-level claim can see it.
  def test_a_resolving_class_is_not_looked_up_twice
    skip_if_reporter_is_really_installed

    plant_issue_class(table: 'queries')
    subject = RedmineReporterDashboards::ReporterReportTemplates
    assert subject.usable?(ISSUE_CLASS)

    subject.expects(:resolve).never

    3.times { assert subject.usable?(ISSUE_CLASS) }
  end

  # ASKING IS PER CLASS. An earlier version asked about both report-template classes at
  # once, so a broken time-entry class disabled the healthy issue widget. Nothing tested
  # it either way, and dropping the second class from the list was a surviving mutant.
  def test_a_broken_second_class_does_not_disable_the_issue_widget
    skip_if_reporter_is_really_installed

    plant_issue_class(table: 'queries')
    subject = RedmineReporterDashboards::ReporterReportTemplates

    assert subject.usable?(ISSUE_CLASS),
           'the issue widget must not be held hostage by the time-entry class'
    assert_not subject.usable?('TimeEntriesReportTemplate'),
               'precondition: the other class is genuinely absent in this run'
  end

  # A NAME OUTSIDE THE KNOWN SET IS A PROGRAMMING ERROR, not a false answer. Returning
  # false for a typo'd class name would silently disable a widget for ever.
  def test_an_unknown_class_name_raises_rather_than_answering_false
    error = assert_raises(ArgumentError) do
      RedmineReporterDashboards::ReporterReportTemplates.load_error('NoSuchTemplate')
    end
    assert_match(/NoSuchTemplate/, error.message)
  end

  private

  # A real logger, not a Mocha matcher with a side effect in it. Nothing in Mocha's
  # contract says a `with { }` block runs exactly once per call — it is also consulted
  # when composing failure messages — so counting lines inside one depends on an
  # implementation detail of the pinned version, and stubbing `warn` wholesale swallows
  # unrelated warnings for the duration.
  def capturing_rails_log
    buffer = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(buffer)
    yield
    buffer.string
  ensure
    Rails.logger = original
  end

  # Stands in for the base plugin's class: present, resolving, and backed by whichever
  # table the caller names — an existing one to reach the body, a missing one to make the
  # body fail the way an unmigrated install does.
  def plant_issue_class(table:)
    klass = Class.new(ActiveRecord::Base) { self.abstract_class = false }
    klass.table_name = table
    Object.const_set(ISSUE_CLASS, klass)
    @planted = true
    RedmineReporterDashboards.stubs(:reporter_present?).returns(true)
    RedmineReporterDashboards::ReporterReportTemplates.reset!
  end

  def remove_planted_class
    return unless @planted

    Object.send(:remove_const, ISSUE_CLASS) if Object.const_defined?(ISSUE_CLASS, false)
    @planted = nil
  end

  # The planting examples CREATE the broken-dependency condition, so they must stand down
  # when a real base plugin is installed rather than clobber its class with a stub.
  def skip_if_reporter_is_really_installed
    return unless RedmineReporterDashboards.reporter_present?

    skip 'the base plugin is really installed here, so planting a stand-in for its ' \
         'report-template class would clobber the real one. These examples cover the ' \
         'guard against a stand-in; the real article is the base plugin\'s own suite.'
  end

  # The mirror image of `skip_unless_reporter_report_templates_load`: these examples are
  # about the UNAVAILABLE case, so they are the ones that must stand down when a working
  # redmine_reporter is present. Stated as a skip with its reason, never a silent pass.
  def skip_if_reporter_report_templates_load
    return unless reporter_report_template_load_error.nil?

    skip 'redmine_reporter is installed and its report template classes load on this ' \
         'Redmine, so the unavailable-widget path is not reachable here. This file ' \
         'covers the standalone and the Rails-8.0-enum configurations.'
  end

  def put_block_on_my_page
    pref = @jsmith.pref
    pref.my_page_layout = { 'left' => [BLOCK], 'right' => [] }
    pref.save!
  end
end
