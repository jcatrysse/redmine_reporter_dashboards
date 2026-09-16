# frozen_string_literal: true

module RedmineReporterDashboards
  # One immutable snapshot of a template's content.
  #
  # `technical-spec.md` calls the table **append-only**, and this class is the second
  # half of that: the migration withholds `updated_at`, and `readonly?` withholds `UPDATE`.
  # FR-21's audit trail exists because authoring a template is a code-execution privilege
  # (INV-9), and an audit trail that can be edited answers no question anybody would ask it.
  #
  # --- WHAT "APPEND-ONLY" DOES AND DOES NOT BUY, STATED PRECISELY ---
  #
  # An earlier version of this comment claimed the two mechanisms "together are a property",
  # and the review of T-36 refuted it by running the obvious bypasses. What is actually true:
  #
  #   BLOCKED by `readonly?`   save, update, update!, update_attribute, touch, increment!,
  #                            decrement! — and `destroy` — all raise
  #                            `ActiveRecord::ReadOnlyRecord` on a persisted row
  #   NOT BLOCKED              `TemplateVersion.where(id: x).update_all(content: '…')`,
  #                            `update_column`/`update_columns`, and raw SQL
  #
  # That is not a hole peculiar to this class: `update_all` and `update_column` bypass every
  # model-level control Rails has, by design, on every model in every application. Saying so
  # is the point — a claim of tamper-proofing that a one-line console command defeats is
  # worse than no claim. The honest statement is that nothing in this plugin's own code can
  # rewrite a version, and that a database-level guarantee would need a trigger this plugin
  # does not install.
  #
  # `destroy` being blocked is a CONSEQUENCE rather than a decision — Rails routes it through
  # the same `readonly?` check, and an earlier version of this comment said the opposite.
  # Deleting a template still removes its versions, because `dependent: :delete_all` issues
  # one bulk DELETE and never instantiates a row; that is what keeps a deleted template's
  # executable content from outliving it.
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

    # `before_save`, NOT `before_validation`. `created_at` is NOT NULL in the migration, and
    # `save(validate: false)` — a Redmine idiom, used in core's own `Project#copy` — skips
    # every validation callback, so stamping there turned a supported call into a
    # `NotNullViolation` from the database. `before_save` runs either way.
    before_save :stamp_created_at
    before_save :stamp_content_digest

    # A new record is still writable, which is what makes the table append-ONLY rather than
    # read-only. See the class comment for exactly which write paths this closes and which
    # two it does not.
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

    # Distinguishes a NULL content from an empty one. `digest_for(nil)` and `digest_for('')`
    # are otherwise the same SHA-256, so an audit trail could not tell "the author saved an
    # empty template" from "no content was recorded" — two different events for anybody
    # reading the trail to answer a question.
    def stamp_content_digest
      self.content_digest = content.nil? ? nil : self.class.digest_for(content)
    end
  end
end
