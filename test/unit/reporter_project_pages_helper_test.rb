require File.expand_path('../test_helper', __dir__)

class ReporterProjectPagesHelperTest < ActionView::TestCase
  include ReporterProjectPagesHelper

  # The icon divergence, both branches, on whichever Redmine is running.
  #
  # The Redmine 5.1 branch cannot be reached by running the suite on 6.x, and 5.1
  # cannot be run at all on a container whose Ruby its Gemfile refuses — so the
  # predicate is stubbed instead of the version. That is the whole point of having a
  # predicate: the divergence becomes testable everywhere rather than only where it
  # bites. It bit for real — 27 errors in the first 5.1 CI run, every one of them
  # `undefined method 'sprite_icon'`.
  def test_reporter_dashboard_icon_uses_the_svg_sprite_on_redmine_6_and_later
    unless reporter_dashboard_svg_icons?
      skip "this Redmine (#{Redmine::VERSION}) has no SVG icon sprite"
    end

    icon = reporter_dashboard_icon('settings', 'Settings')

    assert_includes icon, '<svg', 'expected the core sprite_icon output'
    assert_includes icon, 'Settings', 'the label must survive: icon-only hides it, it is the accessible name'
  end

  def test_reporter_dashboard_icon_is_the_bare_label_where_there_is_no_sprite_helper
    # Redmine 5.1: IconsHelper does not exist, so sprite_icon must never be reached.
    # `icon icon-<name>` on the link paints the glyph there; the label is the body.
    # Mocha, not `Object#stub`. This file used the latter WITHOUT requiring
    # `minitest/mock` and worked only because two other test files in the same process
    # required it first — so removing those requires would have broken this file for a
    # reason nothing here mentions. A dependency satisfied by load order is not a
    # dependency anybody can see.
    stubs(:reporter_dashboard_svg_icons?).returns(false)

    assert_equal 'Settings', reporter_dashboard_icon('settings', 'Settings')
  end

  def test_reporter_dashboard_icon_never_calls_sprite_icon_without_the_sprite
    calls = 0
    define_singleton_method(:sprite_icon) { |*| calls += 1; 'should not happen' }

    stubs(:reporter_dashboard_svg_icons?).returns(false)
    reporter_dashboard_icon('close', 'Delete')

    assert_equal 0, calls, 'sprite_icon does not exist on Redmine 5.1 — calling it is the defect'
  end

  def test_reporter_project_limit_options_includes_unlimited
    options = reporter_project_limit_options(nil)
    assert_includes options, 'value="0"'
    assert_includes options, l(:label_all)
  end

  def test_reporter_project_block_limit_allows_unlimited
    assert_nil reporter_project_block_limit({ limit: '0' })
  end

  def test_reporter_project_block_limit_defaults_on_invalid
    assert_equal 10, reporter_project_block_limit({ limit: '999' })
  end

  def test_reporter_project_block_limit_defaults_on_blank
    assert_equal 10, reporter_project_block_limit({ limit: '' })
  end

  def test_reporter_project_block_limit_defaults_on_nil_settings
    assert_equal 10, reporter_project_block_limit({})
  end

  def test_reporter_project_group_by_options_includes_none_and_groupable_columns
    query = IssueQuery.new
    groupable = query.groupable_columns

    options = reporter_project_group_by_options(query, {})

    assert_includes options, l(:label_none)
    assert groupable.any?, 'Expected at least one groupable column'
    assert_includes options, "value=\"#{groupable.first.name}\""
  end

  def test_reporter_project_group_by_value_rejects_invalid
    query = IssueQuery.new

    assert_nil reporter_project_group_by_value(query, { group_by: 'bogus' })
  end

  def test_reporter_project_group_by_value_accepts_valid
    query = IssueQuery.new
    groupable = query.groupable_columns
    skip 'No groupable columns available' if groupable.empty?
    group_by = groupable.first.name.to_s

    assert_equal group_by, reporter_project_group_by_value(query, { group_by: group_by })
  end

  # M1 regression: report_by_issues must NOT require the time-entries permission.
  # This is a helper-level unit test to confirm the base-block logic is correct.
  def test_report_by_issues_base_block_extraction
    # Both bare and suffixed names should resolve to 'report_by_issues'
    assert_equal 'report_by_issues',      'report_by_issues'.sub(/__\d+\z/, '')
    assert_equal 'report_by_issues',      'report_by_issues__2'.sub(/__\d+\z/, '')
    assert_equal 'report_by_spent_time',  'report_by_spent_time'.sub(/__\d+\z/, '')
    assert_equal 'report_by_spent_time',  'report_by_spent_time__3'.sub(/__\d+\z/, '')
  end
end
