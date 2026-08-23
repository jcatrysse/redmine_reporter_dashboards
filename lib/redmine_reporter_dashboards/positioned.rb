# frozen_string_literal: true

module RedmineReporterDashboards
  # Ordered-list behaviour for a model with an integer `position` column, owned by
  # this plugin.
  #
  # It replaces `up_acts_as_list scope: :project_id`, which is defined ONLY in the
  # `redmineup` gem (redmineup-1.1.12/lib/redmineup/acts_as_list/list.rb:33) and
  # reaches us transitively through redmine_reporter's Gemfile. That single line is
  # why relaxing the hard `raise` in init.rb is not enough on its own: without an
  # owned replacement the plugin boots happily and then 500s on its own core model
  # the first time anyone opens a project's dashboards.
  #
  # --- Deliberate differences from the gem ---
  #
  # The gem builds its scope by interpolating the value into a SQL string
  # (`"project_id = #{project_id}"`) and does the same in `higher_item` /
  # `lower_item`. Here the scope is an ActiveRecord condition, so the value is
  # bound rather than pasted. `project_id` is an integer column, so the gem's form
  # is not exploitable in practice — but a hand-built SQL fragment carrying a model
  # attribute is not a thing to carry forward when the alternative is shorter.
  #
  # `position` is also assigned in a `before_save` rather than the gem's
  # `before_create`, so a row moved between scopes lands at the bottom of its new
  # list instead of keeping a position that belongs to the old one.
  #
  # --- Contract, kept identical to the gem ---
  #
  #   * positions are 1-based; a first row gets 1, not 0
  #   * `nil` position means "not in the list" (`in_list?`)
  #   * destroying a row closes the gap it leaves
  #   * `move_higher` / `move_lower` swap with the adjacent row and are no-ops at
  #     the ends
  #
  # Everything that writes more than one row does so in a transaction: a half-applied
  # reorder leaves two tabs claiming one position, and the tab bar then renders in an
  # order that depends on the database's whim.
  module Positioned
    extend ActiveSupport::Concern

    included do
      include Comparable

      before_save   :assign_position_at_bottom, unless: :position_assigned?
      before_destroy :close_position_gap
    end

    # Ordered by position, then id: two rows sharing a position (a database written
    # to by an older version, or by something other than this code) must still have
    # ONE defined order, or the tab bar reshuffles between requests.
    def <=>(other)
      return nil unless other.is_a?(self.class) && position_scope_key == other.position_scope_key

      [position || Float::INFINITY, id || Float::INFINITY] <=>
        [other.position || Float::INFINITY, other.id || Float::INFINITY]
    end

    def in_list?
      !position.nil?
    end

    def first?
      in_list? && higher_item.nil?
    end

    # Asked of every tab on every settings render, so it must not be "position ==
    # count": a gap in the sequence would then hide the move-right control on a tab
    # that can perfectly well move right.
    def last?
      in_list? && lower_item.nil?
    end

    def higher_item
      return nil unless in_list?

      position_scope.where(position: ...position).order(position: :desc, id: :desc).first
    end

    def lower_item
      return nil unless in_list?

      position_scope.where(position: (position + 1)..).order(:position, :id).first
    end

    def move_higher
      swap_position_with(higher_item)
    end

    def move_lower
      swap_position_with(lower_item)
    end

    # Renumbers the whole list 1..n in its current order, closing any gaps and
    # breaking any ties. Not needed by the move operations — they swap, so they
    # cannot create a gap — but a database that already contains gaps or ties gets
    # one obvious way to be repaired.
    def reset_positions_in_list
      self.class.transaction do
        position_scope_including_self.order(:position, :id).each_with_index do |record, index|
          wanted = index + 1
          next if record.position == wanted

          self.class.where(id: record.id).update_all(position: wanted)
        end
      end
      reload_position
    end

    # The value that decides which list this row belongs to. Its own method so a
    # second model can include the concern with a different scope by overriding just
    # this and #position_scope.
    def position_scope_key
      project_id
    end

    private

    # Siblings only: a row is never its own higher or lower item, and a new record
    # (id nil) must not exclude every persisted row via `id != NULL`.
    def position_scope
      scope = position_scope_including_self
      id.nil? ? scope : scope.where.not(id: id)
    end

    def position_scope_including_self
      self.class.where(project_id: position_scope_key)
    end

    # A caller may set position explicitly (a fixture, an import, a migration), and
    # only an unset one is filled in — including on create, which is why `persisted?`
    # cannot be the first question asked.
    #
    # The one case where a position that IS set still counts as unassigned: a row
    # moving to another project. Its position belongs to the list it is leaving, so
    # it is re-bottomed in the list it is joining. (The vendor gem assigns on
    # before_create only, so there it silently keeps the old list's number.)
    def position_assigned?
      return false if position.nil?
      return true unless persisted?

      !will_save_change_to_attribute?(:project_id)
    end

    def assign_position_at_bottom
      self.position = (position_scope.maximum(:position) || 0) + 1
    end

    # before_destroy, so the gap closes even when the row is destroyed through an
    # association rather than directly.
    def close_position_gap
      return unless in_list?

      self.class.transaction do
        position_scope.where(position: (position + 1)..)
                      .update_all('position = position - 1')
      end
    end

    def swap_position_with(other)
      return false if other.nil? || !in_list?

      mine = position
      theirs = other.position

      self.class.transaction do
        self.class.where(id: other.id).update_all(position: mine)
        self.class.where(id: id).update_all(position: theirs)
      end

      self.position = theirs
      clear_attribute_change(:position) if respond_to?(:clear_attribute_change, true)
      true
    end

    def reload_position
      return unless persisted?

      self.position = self.class.where(id: id).pick(:position)
      clear_attribute_change(:position) if respond_to?(:clear_attribute_change, true)
    end
  end
end
