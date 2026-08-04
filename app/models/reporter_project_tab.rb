# frozen_string_literal: true

class ReporterProjectTab < ApplicationRecord
  include Redmine::I18n

  belongs_to :project
  up_acts_as_list scope: :project_id

  serialize :layout, coder: YAML
  serialize :settings, coder: YAML

  # Backstop for the per-widget limits in BlockSettings: those bound one widget, this
  # bounds the column. A dashboard can hold many widgets, each with a legal number of
  # legal settings, and `settings` is loaded, YAML-parsed and re-dumped on every
  # render — so the total gets a ceiling too. 64 KB is orders of magnitude above what
  # the widgets actually store (a few ids, a limit, a column list).
  MAX_SETTINGS_BYTES = 64 * 1024

  # A tab label, not a free-text field: it has to fit a tab in the bar, and the column
  # is a varchar(255) that would silently truncate (MySQL) or raise (PostgreSQL) past
  # its own limit. 60 matches the width of the inputs that edit it.
  MAX_TITLE_LENGTH = 60

  # Presence is unconditional — a blank title must never be stored, whatever the row
  # looked like before. The LENGTH check applies only while the title is being changed,
  # so an upgrade cannot make an existing tab unsavable: the column allows 255
  # characters, a title of 61-255 may already be in someone's database, and validating
  # it would have failed every later save of that tab — every add_block, move_block and
  # settings change — turning the dashboard read-only. Grandfathered instead: keep it,
  # but the moment anyone edits the title it has to be a valid one.
  validates :title, presence: true
  validates :title, length: { maximum: MAX_TITLE_LENGTH }, if: :title_changed?
  validate :settings_within_size_limit

  before_validation :strip_title
  before_validation :set_defaults
  # Before validation, not before save: the size check below has to measure what will
  # actually be written, and this is what decides that. Settings belonging to widgets
  # that are no longer on the dashboard are dropped either way.
  before_validation :clear_unused_block_settings

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

  # Only while the title is being changed. Stripping unconditionally would mark a
  # stored title that merely has surrounding whitespace as changed, which would in turn
  # switch the length validation on for a row nobody edited — exactly the upgrade
  # breakage the `if: :title_changed?` above exists to avoid. Historical whitespace is
  # left alone; the next edit cleans it.
  def strip_title
    self.title = title.strip if title.is_a?(String) && title_changed?
  end

  def set_defaults
    self.layout = RedmineReporterDashboards::RowLayout.normalize(layout)
    self.settings ||= {}
  end

  def clear_unused_block_settings
    used_blocks = block_rows.flatten
    settings.keep_if { |block, _| used_blocks.include?(block) } if settings
  end

  # Measured on the YAML, because that is what the column actually holds. Uses
  # Rails' own :too_long message, which every Redmine locale already translates.
  def settings_within_size_limit
    size = YAML.dump(settings || {}).bytesize
    return if size <= MAX_SETTINGS_BYTES

    errors.add(:settings, :too_long, count: MAX_SETTINGS_BYTES)
  end
end
