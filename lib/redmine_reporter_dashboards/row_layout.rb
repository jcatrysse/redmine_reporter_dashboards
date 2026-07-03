# frozen_string_literal: true

module RedmineReporterDashboards
  # Pure, storage-agnostic manipulation of a dashboard layout expressed as an
  # ordered list of rows, each row an ordered list of block ids:
  #
  #   [['issuesassignedtome', 'news'], ['calendar'], ['documents', 'timelog']]
  #
  # Row 1 shows two widgets side by side; row 2 a single full-width widget, etc.
  # "How many widgets per line" is simply how many ids a row holds.
  #
  # This module has no ActiveRecord / Redmine dependency on purpose, so the move
  # semantics and the legacy-format migration are unit-testable in isolation
  # (see spec/row_layout_spec.rb). ReporterProjectTab delegates to it.
  module RowLayout
    DIRECTIONS = %w[up down left right].freeze

    # Regions used by the pre-rows layout format (a Hash keyed by these names).
    # Kept here only to migrate old records forward; the rows model no longer
    # uses fixed regions.
    LEGACY_TOP_ROW = 'top'
    LEGACY_COLUMN_ROWS = [
      ['top-left', 'top-middle', 'top-right'],
      ['left', 'middle', 'right']
    ].freeze

    module_function

    # Coerce any stored value (nil, legacy region Hash, or an Array of rows) into
    # a clean Array-of-Arrays: string ids, no blank ids, no empty rows. Never
    # mutates the argument.
    def normalize(raw)
      rows =
        case raw
        when Array then raw
        when Hash  then rows_from_legacy_hash(raw)
        else []
        end

      rows.map { |row| Array(row).map(&:to_s).reject(&:empty?) }.reject(&:empty?)
    end

    # Legacy layouts were a Hash keyed by fixed regions. Preserve the visual
    # intent: 'top' stacked full width (one row each), while the two column
    # triples become side-by-side rows zipped by index.
    def rows_from_legacy_hash(hash)
      h = hash.transform_keys(&:to_s)
      rows = []
      Array(h[LEGACY_TOP_ROW]).each { |block| rows << [block] }
      LEGACY_COLUMN_ROWS.each do |columns|
        rows.concat(zip_columns(columns.map { |name| Array(h[name]) }))
      end
      rows
    end

    # Interleave parallel columns into rows: row i = [col0[i], col1[i], col2[i]]
    # with blanks removed, so a shorter column simply contributes fewer cells.
    def zip_columns(columns)
      height = columns.map(&:size).max || 0
      (0...height).map { |i| columns.filter_map { |col| col[i] } }
    end

    # Add a block as its own new row at the top. Removes any existing occurrence
    # first so a re-add moves it rather than duplicating.
    def add(rows, block)
      block = block.to_s
      [[block]] + remove(rows, block)
    end

    # Remove a block wherever it is; drop rows left empty.
    def remove(rows, block)
      block = block.to_s
      normalize(rows).map { |row| row - [block] }.reject(&:empty?)
    end

    # Row/column position of a block, or nil when absent.
    def locate(rows, block)
      block = block.to_s
      normalize(rows).each_with_index do |row, r|
        c = row.index(block)
        return [r, c] if c
      end
      nil
    end

    # Move a block one step in a direction. left/right reorder within the row;
    # up/down move the block to the adjacent row (joining it — "more per line")
    # or to a brand new row when moved past the first/last row ("fewer per
    # line"). Returns a normalized Array-of-rows; a no-op returns an equal array.
    def move(rows, block, direction)
      rows = normalize(rows)
      direction = direction.to_s
      pos = locate(rows, block)
      return rows unless pos && DIRECTIONS.include?(direction)

      r, c = pos
      case direction
      when 'left'  then swap_in_row(rows, r, c, c - 1)
      when 'right' then swap_in_row(rows, r, c, c + 1)
      when 'up'    then move_vertical(rows, r, c, -1)
      when 'down'  then move_vertical(rows, r, c, 1)
      end
    end

    def swap_in_row(rows, r, col, target)
      return rows if target.negative? || target >= rows[r].size

      rows = deep_dup(rows)
      rows[r][col], rows[r][target] = rows[r][target], rows[r][col]
      rows
    end

    def move_vertical(rows, r, col, delta)
      rows = deep_dup(rows)
      block = rows[r].delete_at(col)
      target = r + delta

      if target.negative?
        rows.unshift([block])          # new row above the first
      elsif target >= rows.size
        rows.push([block])             # new row below the last
      elsif delta.negative?
        rows[target].push(block)       # join the end of the row above
      else
        rows[target].unshift(block)    # join the start of the row below
      end

      rows.reject(&:empty?)
    end

    # Would this move actually change anything? Used by the view to hide move
    # buttons that would be no-ops (block at an edge).
    def can_move?(rows, block, direction)
      normalized = normalize(rows)
      move(normalized, block, direction) != normalized
    end

    def deep_dup(rows)
      rows.map(&:dup)
    end
  end
end
