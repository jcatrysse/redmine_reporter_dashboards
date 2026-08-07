# frozen_string_literal: true

module RedmineReporterDashboards
  # One immutable snapshot of a template's content.
  #
  # `technical-spec.md:1199` calls the table **append-only**, and this class is the second
  # half of that: the migration withholds `updated_at`, and `readonly?` withholds `UPDATE`.
  # Either alone is a convention; together they are a property. FR-21's audit trail exists
  # because authoring a template is a code-execution privilege (INV-9), and an audit trail
  # that can be edited answers no question anybody would ask it.
  #
  # `destroy` is deliberately NOT blocked. A template's versions are deleted with the
  # template (`dependent: :delete_all`), because keeping the content of a deleted template
  # would keep executable code an operator believed they had removed.
  class TemplateVersion < RedmineReporterDashboards::Compat.base_record
    self.table_name = 'reporter_dashboards_template_versions'

    # There is no `updated_at` column, so Rails must not try to write one. Setting this to
    # false rather than listing `record_timestamps` per-call means no caller can forget.
    self.record_timestamps = false

    belongs_to :template,
               class_name: 'RedmineReporterDashboards::Template',
               foreign_key: 'template_id',
               inverse_of: :versions
    # Nullable: an import or a rake task writes versions with no human author, and
    # inventing one would make the trail lie.
    belongs_to :author, class_name: 'User', optional: true

    validates :template_id, presence: true

    before_validation :stamp_created_at, on: :create
    before_validation :stamp_content_digest

    # Blocks `save`, `update`, `update_attribute` and `touch` on a persisted row —
    # `ActiveRecord::ReadOnlyRecord` is raised rather than silently ignored. A new record
    # is still writable, which is what makes the table append-ONLY rather than read-only.
    def readonly?
      persisted?
    end

    # SHA-256 of the content as bytes. Named `digest_for` rather than computed inline so a
    # caller comparing an imported bundle against a stored version uses the same function
    # (T-24's drift report) instead of a second, subtly different one.
    def self.digest_for(content)
      require 'digest'
      ::Digest::SHA256.hexdigest(content.to_s)
    end

    private

    # `record_timestamps = false` switches off Rails' own stamping, and the column is
    # NOT NULL, so this class does it. `Time.now` is deliberately not used: Redmine sets
    # `config.active_record.default_timezone = :local` (config/application.rb:37), and
    # `Time.zone.now` is the only reading that agrees with every other timestamp Redmine
    # writes.
    def stamp_created_at
      self.created_at ||= Time.zone.now
    end

    def stamp_content_digest
      self.content_digest = self.class.digest_for(content)
    end
  end
end
