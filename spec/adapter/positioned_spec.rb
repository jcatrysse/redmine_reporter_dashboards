# frozen_string_literal: true

require_relative 'adapter_helper'

# RedmineReporterDashboards::Positioned replaces the redmineup gem's
# up_acts_as_list, so it is exercised against a REAL database engine rather than a
# stub: the whole point of the concern is the multi-row UPDATE arithmetic, and
# `update_all("position = position - 1")` is SQL, not Ruby. It lives under
# spec/adapter for that reason and skips with the other adapter specs when no
# engine is configured.
#
# Its own table and model, not ReporterProjectTab: the concern is the unit under
# test, and pulling the tab in would drag Redmine::I18n, RowLayout and three
# validations along with it. The functional tests in
# test/functional/reporter_project_tabs_controller_test.rb cover the tab itself.
RSpec.describe 'RedmineReporterDashboards::Positioned', :aggregate_failures do
  before(:all) do
    skip RrdAdapterHarness.skip_reason unless RrdAdapterHarness.configured?

    require 'active_support/concern'
    require_relative '../../lib/redmine_reporter_dashboards/positioned'

    ActiveRecord::Base.connection.create_table(:rrd_positioned_items, force: true) do |t|
      t.integer :project_id
      t.integer :position
      t.string  :label
    end

    unless Object.const_defined?(:RrdPositionedItem, false)
      Object.const_set(:RrdPositionedItem, Class.new(ActiveRecord::Base) do
        self.table_name = 'rrd_positioned_items'
        include RedmineReporterDashboards::Positioned
      end)
    end
  end

  let(:model) { ::RrdPositionedItem }

  before { model.delete_all }

  # Ordered explicitly. Postgres, MySQL and MariaDB do not agree on unordered row
  # order, and this project runs all three.
  def positions(project_id = 1)
    model.where(project_id: project_id).order(:position, :id).pluck(:label, :position)
  end

  def create_items(*labels, project_id: 1)
    labels.map { |label| model.create!(project_id: project_id, label: label) }
  end

  # A nil position cannot be created: the before_save always fills one in, exactly as
  # the vendor gem's before_create did. Loose rows come from a row LEAVING a list, so
  # they are made here the way they arise -- around the callback, not through it.
  def loose_item(label = 'loose', project_id: 1)
    model.create!(project_id: project_id, label: label).tap do |row|
      row.update_column(:position, nil)
    end
  end

  describe 'position assignment' do
    it 'gives the first row in a list position 1, not 0' do
      a, = create_items('a')

      expect(a.position).to eq(1)
    end

    it 'appends each new row at max+1' do
      create_items('a', 'b', 'c')

      expect(positions).to eq([['a', 1], ['b', 2], ['c', 3]])
    end

    it 'scopes the list to project_id, so two projects both start at 1' do
      create_items('a', 'b')
      create_items('x', project_id: 2)

      expect(positions(1)).to eq([['a', 1], ['b', 2]])
      expect(positions(2)).to eq([['x', 1]])
    end

    it 'treats a nil project_id as its own list rather than as "any project"' do
      create_items('a')
      nil_scoped = model.create!(project_id: nil, label: 'orphan')

      expect(nil_scoped.position).to eq(1)
    end

    it 'honours a position set explicitly, so a fixture or import can place a row' do
      row = model.create!(project_id: 1, position: 42, label: 'pinned')

      expect(row.position).to eq(42)
    end

    it 'continues from the highest position, not the row count, after a gap' do
      model.create!(project_id: 1, position: 10, label: 'far')

      expect(create_items('next').first.position).to eq(11)
    end

    # The gem assigns on before_create only, so a row moved to another project keeps
    # a position belonging to its old list.
    it 're-bottoms a row moved to another project' do
      create_items('x', 'y', project_id: 2)
      a, = create_items('a')

      a.update!(project_id: 2)

      expect(a.reload.position).to eq(3)
    end
  end

  describe '#move_higher / #move_lower' do
    it 'swaps with the row above' do
      _a, b = create_items('a', 'b')

      expect(b.move_higher).to be(true)
      expect(positions).to eq([['b', 1], ['a', 2]])
    end

    it 'swaps with the row below' do
      a, = create_items('a', 'b')

      expect(a.move_lower).to be(true)
      expect(positions).to eq([['b', 1], ['a', 2]])
    end

    it 'leaves the receiver holding its new position without a reload' do
      _a, b = create_items('a', 'b')
      b.move_higher

      expect(b.position).to eq(1)
      expect(b.changed?).to be(false)
    end

    it 'is a no-op at the top' do
      a, = create_items('a', 'b')

      expect(a.move_higher).to be(false)
      expect(positions).to eq([['a', 1], ['b', 2]])
    end

    it 'is a no-op at the bottom' do
      _a, b = create_items('a', 'b')

      expect(b.move_lower).to be(false)
      expect(positions).to eq([['a', 1], ['b', 2]])
    end

    it 'is a no-op for a row that is not in the list' do
      loose = loose_item

      expect(loose.move_higher).to be(false)
      expect(loose.move_lower).to be(false)
    end

    it 'never crosses into another project' do
      create_items('x', project_id: 2)
      a, = create_items('a')

      expect(a.move_higher).to be(false)
      expect(positions(2)).to eq([['x', 1]])
    end

    # A gap between positions must not stop a move: the rows either side are still
    # each other's neighbours.
    it 'moves across a gap in the sequence' do
      a = model.create!(project_id: 1, position: 1, label: 'a')
      b = model.create!(project_id: 1, position: 5, label: 'b')

      expect(b.move_higher).to be(true)
      expect(positions).to eq([['b', 1], ['a', 5]])
      expect([a.reload.position, b.reload.position]).to eq([5, 1])
    end
  end

  describe '#first? / #last?' do
    it 'identifies the ends of the list' do
      a, b, c = create_items('a', 'b', 'c')

      expect([a.first?, a.last?]).to eq([true, false])
      expect([b.first?, b.last?]).to eq([false, false])
      expect([c.first?, c.last?]).to eq([false, true])
    end

    it 'reports a lone row as both first and last' do
      a, = create_items('a')

      expect([a.first?, a.last?]).to eq([true, true])
    end

    # Asked of every tab on every settings render. `position == count` would hide the
    # move-right control on a tab that can move right.
    it 'is not fooled by a gap in the sequence' do
      a = model.create!(project_id: 1, position: 1, label: 'a')
      b = model.create!(project_id: 1, position: 9, label: 'b')

      expect([a.first?, a.last?]).to eq([true, false])
      expect([b.first?, b.last?]).to eq([false, true])
    end

    it 'is false both ways for a row that is not in the list' do
      loose = loose_item

      expect([loose.first?, loose.last?]).to eq([false, false])
    end
  end

  describe 'destroy reflow' do
    it 'closes the gap left behind' do
      _a, b, _c = create_items('a', 'b', 'c')

      b.destroy!

      expect(positions).to eq([['a', 1], ['c', 2]])
    end

    it 'leaves other projects untouched' do
      create_items('x', 'y', project_id: 2)
      a, = create_items('a')

      a.destroy!

      expect(positions(2)).to eq([['x', 1], ['y', 2]])
    end

    it 'closes the gap when destroyed through the list rather than directly' do
      create_items('a', 'b', 'c')

      model.where(project_id: 1, label: 'a').destroy_all

      expect(positions).to eq([['b', 1], ['c', 2]])
    end

    it 'does nothing for a row that is not in the list' do
      create_items('a', 'b')
      loose_item.destroy!

      expect(positions).to eq([['a', 1], ['b', 2]])
    end
  end

  describe '#<=>' do
    it 'orders by position' do
      a, b = create_items('a', 'b')

      expect(a <=> b).to eq(-1)
      expect(b <=> a).to eq(1)
      expect(a <=> a).to eq(0)
    end

    it 'sorts a shuffled list back into position order' do
      a, b, c = create_items('a', 'b', 'c')

      expect([c, a, b].sort.map(&:label)).to eq(%w[a b c])
    end

    # Two rows sharing a position is not this code's doing, but the tab bar must
    # still have ONE order rather than reshuffling between requests.
    it 'breaks a tie on id' do
      a = model.create!(project_id: 1, position: 1, label: 'a')
      b = model.create!(project_id: 1, position: 1, label: 'b')

      expect(a <=> b).to eq(-1)
      expect([b, a].sort.map(&:label)).to eq(%w[a b])
    end

    it 'sorts a row with no position last rather than raising' do
      a, = create_items('a')
      loose = loose_item

      expect(a <=> loose).to eq(-1)
      expect([loose, a].sort.map(&:label)).to eq(%w[a loose])
    end

    it 'is incomparable across lists, so a mixed sort raises instead of lying' do
      a, = create_items('a')
      other = create_items('x', project_id: 2).first

      expect(a <=> other).to be_nil
      expect { [a, other].sort }.to raise_error(ArgumentError)
    end

    it 'is incomparable with something that is not the same model' do
      a, = create_items('a')

      expect(a <=> 'a').to be_nil
    end
  end

  describe '#reset_positions_in_list' do
    it 'renumbers 1..n, closing gaps' do
      model.create!(project_id: 1, position: 3, label: 'a')
      model.create!(project_id: 1, position: 9, label: 'b')
      row = model.create!(project_id: 1, position: 20, label: 'c')

      row.reset_positions_in_list

      expect(positions).to eq([['a', 1], ['b', 2], ['c', 3]])
      expect(row.position).to eq(3)
    end

    it 'breaks ties deterministically by id' do
      a = model.create!(project_id: 1, position: 1, label: 'a')
      model.create!(project_id: 1, position: 1, label: 'b')

      a.reset_positions_in_list

      expect(positions).to eq([['a', 1], ['b', 2]])
    end

    it 'renumbers only its own list' do
      model.create!(project_id: 2, position: 7, label: 'x')
      row = model.create!(project_id: 1, position: 4, label: 'a')

      row.reset_positions_in_list

      expect(positions(2)).to eq([['x', 7]])
    end
  end

  describe 'the vendor gem is gone' do
    it 'does not respond to up_acts_as_list' do
      expect(model).not_to respond_to(:up_acts_as_list)
    end

    # Comments stripped: positioned.rb documents WHAT it replaces and why, which a
    # reader needs and a mechanical grep cannot tell from a call. What must not exist
    # is executable code reaching for the gem.
    it 'carries no vendor-gem reference in the concern\'s executable code' do
      source = File.read(File.expand_path('../../lib/redmine_reporter_dashboards/positioned.rb', __dir__),
                        encoding: 'UTF-8')
      code = source.lines.grep_v(/\A\s*#/).join

      expect(code).not_to match(/Redmineup|redmineup|up_acts_as_list/)
    end

    it 'leaves no vendor-gem reference in the tab model at all, comments included' do
      source = File.read(File.expand_path('../../app/models/reporter_project_tab.rb', __dir__),
                        encoding: 'UTF-8')

      expect(source).not_to match(/Redmineup|redmineup|up_acts_as_list/)
    end
  end
end
