require File.expand_path('../test_helper', __dir__)

class ReporterProjectTabTest < ActiveSupport::TestCase
  fixtures :projects

  def setup
    @project = Project.find(1)
  end

  def test_defaults
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    assert_equal RedmineReporterDashboards::ProjectPage.default_layout, tab.block_layout
    assert_equal({}, tab.block_settings)
    tab.block_layout.each_value do |blocks|
      assert_empty blocks
    end
  end

  def test_block_layout_does_not_dirty_record_on_read
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.reload
    _layout = tab.block_layout
    # Pure getter must not mark the record as changed
    assert_not tab.changed?, 'block_layout should not mark the record dirty'
  end

  def test_block_layout_merges_new_groups
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.block_layout = { 'left' => ['news'] }
    tab.save!
    layout = tab.block_layout
    assert_equal ['news'], layout['left']
    assert_equal [], layout['top-middle']
    assert_equal [], layout['middle']
  end

  def test_add_block_persists_to_layout
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.save!
    assert_includes tab.reload.block_layout['top'], 'news'
  end

  def test_add_and_remove_block
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.save!
    assert_includes tab.block_layout['top'], 'news'

    tab.remove_block('news')
    tab.save!
    refute_includes tab.block_layout['top'], 'news'
  end

  def test_add_block_moves_existing_block_to_top
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.layout = { 'left' => ['news'], 'top' => [] }
    tab.save!

    tab.add_block('news')
    tab.save!

    assert_includes tab.reload.block_layout['top'], 'news'
    refute_includes tab.block_layout['left'], 'news'
  end

  def test_order_blocks_ignores_unknown_group
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    layout = tab.block_layout.deep_dup
    tab.order_blocks('unknown', ['news'])
    assert_equal layout, tab.block_layout
  end

  def test_order_blocks_reorders_within_group
    tab = ReporterProjectTab.create!(project: @project, title: 'Overview')
    tab.add_block('news')
    tab.add_block('activity')
    tab.save!

    top_blocks = tab.block_layout['top']
    assert_equal 2, top_blocks.size

    reversed = top_blocks.reverse
    tab.order_blocks('top', reversed)
    tab.save!

    assert_equal reversed, tab.reload.block_layout['top']
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
