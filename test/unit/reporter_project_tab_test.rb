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

  def test_title_is_stripped
    tab = ReporterProjectTab.create!(project: @project, title: "  Overview \t ")
    assert_equal 'Overview', tab.title
  end

  # Stripped before the presence check, so whitespace is not a title.
  def test_title_of_only_whitespace_is_invalid
    tab = ReporterProjectTab.new(project: @project, title: '   ')
    assert_not tab.valid?
    assert tab.errors[:title].any?
  end

  def test_title_longer_than_the_limit_is_invalid
    tab = ReporterProjectTab.new(project: @project,
                                 title: 'x' * (ReporterProjectTab::MAX_TITLE_LENGTH + 1))
    assert_not tab.valid?
    assert tab.errors[:title].any?
  end

  def test_title_at_the_limit_is_valid
    tab = ReporterProjectTab.new(project: @project,
                                 title: 'x' * ReporterProjectTab::MAX_TITLE_LENGTH)
    assert tab.valid?
  end

  # An upgrade must not make an existing tab unsavable. The column allows 255
  # characters, so a title of 61-255 may already be in a database; validating it
  # unconditionally would have failed every later save of that tab — every add_block,
  # move_block and settings change — leaving the dashboard read-only.
  def test_an_existing_over_long_title_does_not_block_other_changes
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.update_column(:title, 'x' * (ReporterProjectTab::MAX_TITLE_LENGTH + 30))
    tab.reload

    tab.add_block('news')
    assert tab.save, tab.errors.full_messages.join(', ')
  end

  # Same, for a stored title that also carries surrounding whitespace: stripping it
  # would mark the attribute changed and switch the length check back on, so the strip
  # is conditional too.
  def test_an_existing_over_long_padded_title_does_not_block_other_changes
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.update_column(:title, "  #{'x' * (ReporterProjectTab::MAX_TITLE_LENGTH + 30)}  ")
    tab.reload

    tab.add_block('news')
    assert tab.save, tab.errors.full_messages.join(', ')
  end

  # Grandfathered, not ignored: the moment anyone edits the title it has to be valid.
  def test_editing_an_existing_over_long_title_still_requires_a_valid_one
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.update_column(:title, 'x' * (ReporterProjectTab::MAX_TITLE_LENGTH + 30))
    tab.reload

    tab.title = 'y' * (ReporterProjectTab::MAX_TITLE_LENGTH + 1)
    assert_not tab.valid?
    assert tab.errors[:title].any?

    tab.title = 'Renamed'
    assert tab.valid?
  end

  # The size check has to measure what will actually be written, and settings belonging
  # to widgets that are no longer on the dashboard are dropped on the way there.
  def test_settings_of_removed_widgets_do_not_count_towards_the_size_limit
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.save!
    # 'activity' is not on the dashboard, so its settings are pruned before validation.
    tab.update_column(:settings,
                      { 'activity' => { 'note' => 'x' * (ReporterProjectTab::MAX_SETTINGS_BYTES + 1) } })
    tab.reload

    assert tab.valid?
    assert tab.save
    assert_equal({}, tab.reload.block_settings)
  end

  # The backstop behind the per-widget limits in BlockSettings: settings is a
  # YAML column loaded and re-dumped on every render, so the total has a ceiling.
  def test_settings_larger_than_the_limit_is_invalid
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.save!
    tab.update_block_settings('news', { 'note' => 'x' * (ReporterProjectTab::MAX_SETTINGS_BYTES + 1) })

    assert_not tab.valid?
    assert tab.errors[:settings].any?
  end

  def test_settings_within_the_limit_is_valid
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.save!
    tab.update_block_settings('news', { 'note' => 'x' * 1_000 })

    assert tab.valid?
  end
end
