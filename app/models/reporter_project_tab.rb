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

  def groups
    RedmineReporterDashboards::ProjectPage.groups
  end

  # Pure getter: returns the stored layout merged with the current default groups
  # so new groups added to ProjectPage::GROUPS appear as empty arrays on old records.
  # Does NOT write to self.layout — callers that need to persist mutations must
  # do so explicitly (see add_block / remove_block / order_blocks below).
  def block_layout
    RedmineReporterDashboards::ProjectPage.default_layout.deep_dup.merge(self.layout || {})
  end

  def block_layout=(value)
    self.layout = value
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
    current_layout = block_layout
    existing = current_layout.values.flatten
    # If already present, move it; otherwise validate (prevents invalid or over-counted blocks).
    return unless existing.include?(block) || RedmineReporterDashboards::ProjectPage.valid_block?(block, existing)

    # Remove from any existing group, then prepend to the first group.
    current_layout.each_value { |v| v.delete(block) }
    group = groups.first
    current_layout[group] ||= []
    current_layout[group].unshift(block)
    self.layout = current_layout
  end

  def remove_block(block)
    block = block.to_s.underscore
    current_layout = block_layout
    current_layout.each_value { |v| v.delete(block) }
    self.layout = current_layout
    current_layout
  end

  def order_blocks(group, blocks)
    group = group.to_s
    current_layout = block_layout
    if groups.include?(group) && blocks.present?
      blocks = blocks.map(&:underscore) & current_layout.values.flatten
      blocks.each { |b| current_layout.each_value { |v| v.delete(b) } }
      current_layout[group] = blocks
      self.layout = current_layout
    end
  end

  private

  def set_defaults
    self.layout = RedmineReporterDashboards::ProjectPage.default_layout.deep_dup.merge(self.layout || {})
    self.settings ||= {}
  end

  def clear_unused_block_settings
    used_blocks = block_layout.values.flatten
    settings.keep_if { |block, _| used_blocks.include?(block) } if settings
  end
end
