require File.expand_path('../test_helper', __dir__)

class ReporterProjectTabTest < ActiveSupport::TestCase
  fixtures :projects

  def setup
    @project = Project.find(1)
  end

  def test_defaults
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    assert_equal [], tab.block_rows
    assert_equal({}, tab.block_settings)
  end

  def test_block_rows_does_not_dirty_record_on_read
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.reload
    _rows = tab.block_rows
    # Pure getter must not mark the record as changed
    assert_not tab.changed?, 'block_rows should not mark the record dirty'
  end

  def test_legacy_region_hash_layout_converts_to_rows
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    # A record saved under the old region-hash format is converted on read.
    tab.layout = { 'top' => ['news'], 'left' => ['activity'], 'middle' => [] }

    assert_equal [['news'], ['activity']], tab.block_rows
  end

  def test_save_migrates_legacy_layout_to_rows
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.layout = { 'top' => ['news'], 'left' => ['activity'] }
    tab.save!

    assert_equal [['news'], ['activity']], tab.reload.layout
  end

  def test_add_block_persists_as_top_row
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.save!
    assert_equal [['news']], tab.reload.block_rows
  end

  def test_add_and_remove_block
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.save!
    assert_includes tab.block_rows.flatten, 'news'

    tab.remove_block('news')
    tab.save!
    refute_includes tab.block_rows.flatten, 'news'
    assert_equal [], tab.reload.block_rows
  end

  def test_add_block_moves_existing_block_to_top_row
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.update!(layout: [['activity'], ['news']])

    tab.add_block('news')
    tab.save!

    assert_equal [['news'], ['activity']], tab.reload.block_rows
  end

  def test_add_block_rejects_invalid_block
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    assert_nil tab.add_block('definitely_not_a_block')
    assert_equal [], tab.block_rows
  end

  def test_move_block_left_reorders_within_row
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.update!(layout: [['news', 'activity']])

    tab.move_block('activity', 'left')
    tab.save!

    assert_equal [['activity', 'news']], tab.reload.block_rows
  end

  def test_move_block_up_merges_into_row_above
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.update!(layout: [['news'], ['activity']])

    tab.move_block('activity', 'up')
    tab.save!

    assert_equal [['news', 'activity']], tab.reload.block_rows
  end

  def test_move_block_down_splits_onto_new_row
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.update!(layout: [['news', 'activity']])

    tab.move_block('news', 'down')
    tab.save!

    assert_equal [['activity'], ['news']], tab.reload.block_rows
  end

  def test_move_block_ignores_unknown_direction
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.update!(layout: [['news', 'activity']])

    tab.move_block('news', 'sideways')
    tab.save!

    assert_equal [['news', 'activity']], tab.reload.block_rows
  end

  def test_can_move_block_reports_edges
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.update!(layout: [['news', 'activity']])

    assert_not tab.can_move_block?('news', 'left')
    assert tab.can_move_block?('news', 'right')
    assert tab.can_move_block?('news', 'down')
  end

  def test_clear_unused_block_settings_on_remove
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.save!
    tab.update_block_settings('news', { limit: '5' })
    tab.save!

    tab.remove_block('news')
    tab.save!

    assert_equal({}, tab.reload.block_settings)
  end

  def test_update_block_settings_symbolizes_keys
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.save!
    tab.update_block_settings('news', { 'limit' => '10' })

    assert_equal '10', tab.block_settings('news')[:limit]
  end
end
