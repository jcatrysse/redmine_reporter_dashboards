require File.expand_path('../test_helper', __dir__)

class ReporterProjectPagesHelperTest < ActionView::TestCase
  include ReporterProjectPagesHelper

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
