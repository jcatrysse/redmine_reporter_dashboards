# frozen_string_literal: true

class ReporterProjectTab < ApplicationRecord
  include Redmine::I18n

  belongs_to :project
  up_acts_as_list scope: :project_id

  serialize :layout, coder: YAML
  serialize :settings, coder: YAML

  validates :title, presence: true

  before_validation :set_defaults
  before_save :clear_unused_block_settings

  # Pure getter: returns the layout as a normalized ordered Array of rows, each
  # row an ordered Array of block ids. Legacy region-hash layouts are converted
  # on the fly (see RowLayout). Does NOT write to self.layout — callers that
  # need to persist mutations must do so explicitly (add/remove/move below).
  def block_rows
    RedmineReporterDashboards::RowLayout.normalize(layout)
  end

  def block_settings(block = nil)
    self.settings ||= {}
    if block
      self.settings[block] ||= {}
    else
      self.settings
    end
  end

  def update_block_settings(block, updates)
    block = block.to_s
    merged = block_settings(block).merge(updates.symbolize_keys)
    self.settings[block] = merged
  end

  def add_block(block)
    block = block.to_s.underscore
    rows = block_rows
    existing = rows.flatten
    # If already present, move it; otherwise validate (prevents invalid or over-counted blocks).
    return unless existing.include?(block) || RedmineReporterDashboards::ProjectPage.valid_block?(block, existing)

    self.layout = RedmineReporterDashboards::RowLayout.add(rows, block)
  end

  def remove_block(block)
    block = block.to_s.underscore
    self.layout = RedmineReporterDashboards::RowLayout.remove(block_rows, block)
  end

  # Move a block one step up/down/left/right (see RowLayout#move). Unknown
  # directions or absent blocks leave the layout untouched.
  def move_block(block, direction)
    block = block.to_s.underscore
    self.layout = RedmineReporterDashboards::RowLayout.move(block_rows, block, direction)
  end

  def can_move_block?(block, direction)
    RedmineReporterDashboards::RowLayout.can_move?(block_rows, block.to_s, direction)
  end

  private

  def set_defaults
    self.layout = RedmineReporterDashboards::RowLayout.normalize(layout)
    self.settings ||= {}
  end

  def clear_unused_block_settings
    used_blocks = block_rows.flatten
    settings.keep_if { |block, _| used_blocks.include?(block) } if settings
  end
end
