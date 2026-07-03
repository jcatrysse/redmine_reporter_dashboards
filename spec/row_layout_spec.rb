# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/row_layout'

RSpec.describe RedmineReporterDashboards::RowLayout do
  M = RedmineReporterDashboards::RowLayout

  describe '.normalize' do
    it 'returns [] for nil' do
      expect(M.normalize(nil)).to eq([])
    end

    it 'passes a clean rows array through unchanged' do
      expect(M.normalize([['a', 'b'], ['c']])).to eq([['a', 'b'], ['c']])
    end

    it 'stringifies ids and drops blanks and empty rows' do
      expect(M.normalize([[:a, '', nil], [], ['b']])).to eq([['a'], ['b']])
    end

    it 'does not mutate its argument' do
      input = [['a'], []]
      M.normalize(input)
      expect(input).to eq([['a'], []])
    end

    it 'converts a legacy region hash: top stacks full width, triples zip side by side' do
      legacy = {
        'top' => ['a', 'b'],
        'top-left' => ['c'], 'top-middle' => ['d'], 'top-right' => [],
        'left' => ['e', 'f'], 'middle' => [], 'right' => ['g']
      }
      expect(M.normalize(legacy)).to eq([
        ['a'], ['b'],        # top → one full-width row each
        ['c', 'd'],          # top triple zipped (top-right empty → omitted)
        ['e', 'g'],          # bottom triple, row 0 (middle empty → omitted)
        ['f']                # bottom triple, row 1 (only left had a 2nd)
      ])
    end

    it 'tolerates a partial/empty legacy hash' do
      expect(M.normalize({ 'top' => [], 'left' => ['x'] })).to eq([['x']])
    end
  end

  describe '.add' do
    it 'adds a block as a new top row' do
      expect(M.add([['a']], 'b')).to eq([['b'], ['a']])
    end

    it 'moves an existing block to a new top row instead of duplicating' do
      expect(M.add([['a', 'b'], ['c']], 'c')).to eq([['c'], ['a', 'b']])
    end

    it 'starts a layout from empty' do
      expect(M.add([], 'a')).to eq([['a']])
    end
  end

  describe '.remove' do
    it 'removes a block and drops the emptied row' do
      expect(M.remove([['a'], ['b', 'c']], 'a')).to eq([['b', 'c']])
    end

    it 'keeps siblings when removing one of several in a row' do
      expect(M.remove([['a', 'b', 'c']], 'b')).to eq([['a', 'c']])
    end

    it 'is a no-op for an absent block' do
      expect(M.remove([['a']], 'zzz')).to eq([['a']])
    end
  end

  describe '.move left/right (within a row)' do
    it 'swaps with the left neighbour' do
      expect(M.move([['a', 'b', 'c']], 'b', 'left')).to eq([['b', 'a', 'c']])
    end

    it 'swaps with the right neighbour' do
      expect(M.move([['a', 'b', 'c']], 'b', 'right')).to eq([['a', 'c', 'b']])
    end

    it 'is a no-op at the left edge' do
      expect(M.move([['a', 'b']], 'a', 'left')).to eq([['a', 'b']])
    end

    it 'is a no-op at the right edge' do
      expect(M.move([['a', 'b']], 'b', 'right')).to eq([['a', 'b']])
    end
  end

  describe '.move up/down (across rows)' do
    it 'up joins the end of the row above (more per line)' do
      expect(M.move([['a', 'b'], ['c']], 'c', 'up')).to eq([['a', 'b', 'c']])
    end

    it 'down joins the start of the row below' do
      expect(M.move([['a', 'b'], ['c']], 'a', 'down')).to eq([['b'], ['a', 'c']])
    end

    it 'up splits a widget onto its own new row above (fewer per line)' do
      expect(M.move([['a', 'b']], 'b', 'up')).to eq([['b'], ['a']])
    end

    it 'down splits a widget onto its own new row below' do
      expect(M.move([['a', 'b']], 'a', 'down')).to eq([['b'], ['a']])
    end

    it 'up is a no-op for a lone widget already at the top' do
      expect(M.move([['a'], ['b']], 'a', 'up')).to eq([['a'], ['b']])
    end

    it 'down is a no-op for a lone widget already at the bottom' do
      expect(M.move([['a'], ['b']], 'b', 'down')).to eq([['a'], ['b']])
    end
  end

  describe '.move guards' do
    it 'returns the layout unchanged for an unknown direction' do
      expect(M.move([['a', 'b']], 'a', 'sideways')).to eq([['a', 'b']])
    end

    it 'returns the layout unchanged for an absent block' do
      expect(M.move([['a', 'b']], 'zzz', 'left')).to eq([['a', 'b']])
    end

    it 'does not mutate its argument' do
      input = [['a', 'b'], ['c']]
      M.move(input, 'c', 'up')
      expect(input).to eq([['a', 'b'], ['c']])
    end
  end

  describe '.can_move?' do
    it 'is false at a horizontal edge but true toward an in-row neighbour' do
      expect(M.can_move?([['a', 'b']], 'a', 'left')).to be(false)
      expect(M.can_move?([['a', 'b']], 'b', 'right')).to be(false)
      expect(M.can_move?([['a', 'b']], 'a', 'right')).to be(true)
      expect(M.can_move?([['a', 'b']], 'b', 'left')).to be(true)
    end

    it 'is false for a lone widget at the vertical extremes' do
      expect(M.can_move?([['a'], ['b']], 'a', 'up')).to be(false)
      expect(M.can_move?([['a'], ['b']], 'b', 'down')).to be(false)
    end

    it 'is true when a non-lone widget can split off' do
      expect(M.can_move?([['a', 'b']], 'b', 'up')).to be(true)
      expect(M.can_move?([['a', 'b']], 'a', 'down')).to be(true)
    end

    it 'is false for an absent block' do
      expect(M.can_move?([['a']], 'zzz', 'up')).to be(false)
    end
  end

  describe 'reachability: any arrangement is achievable with the 4 moves' do
    it 'collapses three stacked widgets into one line' do
      rows = [['a'], ['b'], ['c']]
      rows = M.move(rows, 'b', 'up')   # [[a,b],[c]]
      rows = M.move(rows, 'c', 'up')   # [[a,b,c]]
      expect(rows).to eq([['a', 'b', 'c']])
    end

    it 'explodes one line into three single-widget rows' do
      rows = [['a', 'b', 'c']]
      rows = M.move(rows, 'c', 'down') # [[a,b],[c]]
      rows = M.move(rows, 'b', 'up')   # [[b],[a],[c]]
      expect(rows.map(&:size)).to eq([1, 1, 1])
      expect(rows.flatten.sort).to eq(%w[a b c])
    end
  end
end
