# frozen_string_literal: true

require 'securerandom'
require 'digest'

module RedmineReporterDashboards
  # T-28 — the share link. FR-51/52/53, `technical-spec.md` §7b.1.
  #
  # --- THE FOUR DEFECTS THIS REPLACES, EACH ANSWERED BY A DIFFERENT MECHANISM ---
  #
  # The base plugin's link is `Digest::MD5.hexdigest("Object#1…ReportTemplate#3:" +
  # secret_key_base)`. §7b.1 lists what is wrong with it, and it is worth keeping the list
  # next to the code because three of the four are easy to reintroduce:
  #
  #   no expiry              -> `expires_at` is NOT NULL in the schema, and `usable?`
  #                             reads it. Not a default somebody can clear.
  #   no revocation          -> `revoked_at`, and `revoke!` is one column write.
  #   the token IS the key   -> only `token_digest` is stored. The token exists exactly
  #                             once, in the response that created it. A database dump
  #                             yields nothing usable, and a test asserts that.
  #   it bypasses visibility -> a link authorises ONE PRE-COMPUTED DOCUMENT (FR-52). The
  #                             snapshot arm makes no visibility decision at request time
  #                             because there is no query to make one about.
  #
  # --- WHY `use!` IS A CONDITIONAL UPDATE AND NOT read-then-write ---
  #
  # `max_uses` is a promise about the TOTAL number of times a link works. Reading
  # `use_count`, comparing it, then incrementing is the classic lost update: two requests
  # arriving together both read 0, both decide they are under the limit of 1, and the link
  # serves twice. T-25 proved the same class of thing has to be settled by the DATABASE
  # rather than by the process — its runner claims an occurrence with an INSERT and lets a
  # unique index arbitrate. Here the arbiter is a conditional UPDATE whose WHERE clause
  # carries the whole rule, and the number of rows it changed is the answer.
  class ShareLink < RedmineReporterDashboards::Compat.base_record
    include Redmine::I18n

    self.table_name = 'reporter_dashboards_share_links'

    # §7b.1's three. Closed here rather than left open, because a stored string that
    # selects behaviour is the shape T-25's review found mailing one person's data to
    # somebody else's list — see `ReportRun::SOURCES` and `Occurrences`' repeat rule.
    SCOPE_SNAPSHOT = 'snapshot'
    SCOPE_QUERY = 'query'
    SCOPE_ISSUE_IDS = 'issue_ids'
    SCOPE_KINDS = [SCOPE_SNAPSHOT, SCOPE_QUERY, SCOPE_ISSUE_IDS].freeze

    # 32 RANDOM BYTES, which is what §7b.1 specifies. `urlsafe_base64(32)` is 43
    # characters of base64 over 32 bytes of `SecureRandom` — not 32 characters, which is
    # the mistake the name invites.
    TOKEN_BYTES = 32

    # SHA-256 hex is always 64 characters, which is what makes the comparison below
    # fixed-length and therefore constant-time without a length check leaking anything.
    DIGEST_LENGTH = 64

    # The same bound every other string column in this schema carries, and for the same
    # cross-engine reason: `t.string` is unlimited on PostgreSQL and `varchar(255)` on
    # MySQL, so an over-long value saves on one engine and raises on the other.
    MAX_STRING = 255

    # T-28 (increment 2) — A LINK MUST NOT OUTLIVE THE ARTEFACT IT AUTHORISES.
    #
    # `Document::MAX_RETENTION` bounds how long a stored snapshot may live, for the reason
    # written there: *"'off by default, bounded when on' is only true if the bound cannot be
    # omitted"*. A share link whose expiry is beyond it would point at a document the purge
    # task is entitled to collect — a link that works for eleven months and then answers "not
    # found" for a reason nobody can reconstruct.
    #
    # Taken FROM the document store rather than restated, so the two cannot drift apart into
    # a window where one is right and the other is nearly right.
    MAX_LIFETIME = RedmineReporterDashboards::Document::MAX_RETENTION

    belongs_to :template,
               class_name: 'RedmineReporterDashboards::Template',
               foreign_key: 'template_id',
               inverse_of: :share_links
    belongs_to :project, optional: true
    belongs_to :created_by, class_name: 'User', optional: true
    # THE IDENTITY THE CONTENT WAS RENDERED AS, stored explicitly (§7b.1). Optional
    # because a snapshot link does not re-render and may outlive the account that made it —
    # and a link that stopped working when somebody left would be a worse answer than one
    # that records who it was.
    belongs_to :render_as_user, class_name: 'User', optional: true
    belongs_to :rendered_document,
               class_name: 'RedmineReporterDashboards::Document',
               foreign_key: 'rendered_document_id',
               optional: true

    has_many :accesses,
             -> { order(created_at: :desc, id: :desc) },
             class_name: 'RedmineReporterDashboards::ShareLinkAccess',
             foreign_key: 'share_link_id',
             dependent: :delete_all,
             inverse_of: :share_link

    validates :token_digest, presence: true, length: { is: DIGEST_LENGTH }
    validates :scope_kind, inclusion: { in: SCOPE_KINDS }
    validates :expires_at, presence: true
    validates :purpose, length: { maximum: MAX_STRING }, allow_nil: true
    validates :use_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :max_uses, numericality: { only_integer: true, greater_than: 0 },
                         allow_nil: true
    validate :snapshot_has_a_document
    validate :expiry_within_the_lifetime_bound
    validate :expiry_within_the_snapshots_own

    # ------------------------------------------------------------------ minting

    # THE ONLY PLACE A TOKEN EXISTS. `create_with_token!` answers the record AND the plain
    # token, as a pair, because the caller needs the token exactly once — to put in the URL
    # it shows the person who asked for it — and there is nowhere to get it afterwards.
    #
    # Returning the token from a METHOD rather than storing it on the record is the whole
    # design: an attribute would be memoised onto an object that gets serialised into logs,
    # flash messages and error reports, and the one thing this class must never do is let
    # the token reach a second place.
    def self.create_with_token!(attributes)
      token = generate_token
      record = new(attributes)
      record.token_digest = digest_for(token)
      record.save!

      [record, token]
    end

    def self.generate_token
      SecureRandom.urlsafe_base64(TOKEN_BYTES)
    end

    def self.digest_for(token)
      Digest::SHA256.hexdigest(String(token))
    end

    # THE LOOKUP. By digest — which is what the unique index is on — and then a
    # CONSTANT-TIME comparison of the two digests.
    #
    # The second step looks redundant, because a row found by digest necessarily has that
    # digest. It is here for two reasons, and §7b.1 asks for it by name. A future change
    # that makes the lookup fuzzy in any way (a prefix index, a LIKE, a case-insensitive
    # collation — MySQL's default IS case-insensitive, which this schema runs on) would
    # otherwise silently turn an exact match into a near match. And the comparison is the
    # place the rule is written down; deleting it would take the rule with it.
    #
    # `fixed_length_secure_compare` rather than `secure_compare`: both operands are
    # SHA-256 hex and therefore always 64 characters, so there is no length to leak, and
    # the fixed-length form does not hash its inputs again to hide one.
    def self.find_by_token(token)
      digest = digest_for(token)
      return nil unless digest.length == DIGEST_LENGTH

      candidate = find_by(token_digest: digest)
      return nil if candidate.nil?

      return nil unless ActiveSupport::SecurityUtils
                        .fixed_length_secure_compare(candidate.token_digest, digest)

      candidate
    end

    # ------------------------------------------------------------------ state

    def revoked?
      !revoked_at.nil?
    end

    def expired?(now = Time.zone.now)
      expires_at <= now
    end

    def exhausted?
      !max_uses.nil? && use_count >= max_uses
    end

    # THE THREE REFUSALS, EACH NAMED. A caller that only asked `usable?` could not tell a
    # visitor why their link does not work, and "this did not work" is the message this
    # whole task exists to stop shipping. The symbol is also what the access log records,
    # so the audit answers "how many people hit an expired link" without a second concept.
    def refusal(now = Time.zone.now)
      return :revoked if revoked?
      return :expired if expired?(now)
      return :exhausted if exhausted?

      nil
    end

    def usable?(now = Time.zone.now)
      refusal(now).nil?
    end

    def snapshot?
      scope_kind == SCOPE_SNAPSHOT
    end

    # FR-53: *"every share-link access is recorded"* — WHATEVER THE ANSWER WAS. A row is
    # written for a refusal as readily as for a success, which is the point: the question an
    # administrator has is never "how popular is this link", it is "has somebody been trying
    # links at us". `ShareLinkAccess`' own comment carries the argument.
    #
    # It answers the row rather than a boolean, so a caller that wants the id for a log line
    # has it, and it is deliberately NOT wrapped in a rescue: a failure to write the audit
    # row is a failure to serve, and serving unaudited would be the quieter of the two bugs.
    def record_access!(outcome:, ip_address: nil, user_agent: nil)
      accesses.create!(outcome: outcome.to_s, ip_address: ip_address,
                       user_agent: user_agent, created_at: Time.zone.now)
    end

    # HOW LONG A REFUSAL SUPPRESSES THE NEXT IDENTICAL ONE. See `record_refusal!`.
    REFUSAL_COOLDOWN = 60

    # A DEAD LINK IS STILL AN UNAUTHENTICATED WRITE ENDPOINT, and an independent review
    # measured what that costs: twenty requests on a REVOKED link wrote twenty rows, each
    # carrying up to 255 attacker-chosen bytes of `User-Agent`. Revocation stopped the bytes
    # and not the writes, for ever.
    #
    # The care taken over `share_link_id` being NOT NULL — *"a nullable column would let
    # anyone on the internet grow that table with gibberish"* — is undone by one leaked or
    # public token doing exactly that.
    #
    # SO REFUSALS ARE COLLAPSED AND SUCCESSES ARE NOT, and the asymmetry is the whole design:
    #
    #   a SERVED row is a fact about a person receiving data. Every one matters, they are
    #   bounded by `max_uses` where a bound was asked for, and FR-53's *"every access is
    #   recorded"* is about these
    #
    #   a REFUSAL row is a fact about somebody trying. The FIRST one is the interesting
    #   one — it is what tells an administrator "somebody is still using the link you
    #   revoked" — and the two-hundredth from the same link in the same minute adds nothing
    #   except rows. So an identical refusal within `REFUSAL_COOLDOWN` seconds is dropped,
    #   and the signal survives while the growth does not
    #
    # A CHANGE OF REASON ALWAYS WRITES, whatever the cooldown: `expired` following `revoked`
    # is a different fact and losing it would be losing the log's meaning rather than its
    # volume. Answers the row, or nil when it was collapsed.
    def record_refusal!(outcome:, ip_address: nil, user_agent: nil, now: Time.zone.now)
      recent = accesses.where(outcome: outcome.to_s)
                       .where(arel_table_for_accesses[:created_at].gt(now - REFUSAL_COOLDOWN))
                       .exists?
      return nil if recent

      record_access!(outcome: outcome, ip_address: ip_address, user_agent: user_agent)
    end

    def arel_table_for_accesses
      RedmineReporterDashboards::ShareLinkAccess.arel_table
    end

    def revoke!(now = Time.zone.now)
      # ALREADY-REVOKED IS NOT RE-REVOKED. Overwriting `revoked_at` would move the moment
      # it happened, which is the one fact the column exists to carry.
      return false if revoked?

      update_columns(revoked_at: now, updated_at: now)
      true
    end

    # ------------------------------------------------------------------ using

    # CLAIM, THEN SERVE — and the claim is one statement whose WHERE clause is the whole
    # rule. See the class comment for why this is not read-then-write.
    #
    # Answers the refusal reason, or nil when the claim succeeded. A caller that gets nil
    # has consumed one use and must serve; anything else and it must refuse. The row is
    # reloaded so the caller sees the counts it just changed rather than the ones it read.
    def use!(now = Time.zone.now)
      reason = refusal(now)
      return reason if reason

      claimed = self.class
                    .where(id: id, revoked_at: nil)
                    .where(self.class.arel_table[:expires_at].gt(now))
                    .where(max_uses: nil)
                    .or(self.class
                            .where(id: id, revoked_at: nil)
                            .where(self.class.arel_table[:expires_at].gt(now))
                            .where(self.class.arel_table[:use_count]
                                       .lt(self.class.arel_table[:max_uses])))
                    .update_all(['use_count = use_count + 1, last_used_at = :now, ' \
                                 'updated_at = :now', { now: now }])

      # ZERO ROWS MEANS SOMEBODY ELSE GOT THERE FIRST, or the link stopped being usable
      # between the check above and this statement. Both are the same answer to the
      # visitor and neither is an error: `refusal` on the reloaded row says which.
      if claimed.zero?
        reload
        return refusal(now) || :exhausted
      end

      reload
      nil
    end

    # ------------------------------------------------------------------ scopes

    scope :live, lambda { |now = Time.zone.now|
      where(revoked_at: nil).where(arel_table[:expires_at].gt(now))
    }

    # WHAT THE OWNER'S LIST SHOWS. Deliberately every link for the template rather than
    # only the live ones: a revoked link is the thing somebody most wants to confirm is
    # revoked, and an expired one explains why a recipient is complaining.
    scope :for_template, ->(template) { where(template_id: template.id).order(created_at: :desc, id: :desc) }

    # ------------------------------------------------------------------ authorisation

    # WHO MAY REVOKE — FR-53, and it is OWNERSHIP rather than a permission.
    #
    # §Findings and T-28's `Accept:` are explicit: *"revocation stays with the link's
    # creator, the template's owner and admins, which is ownership rather than a
    # permission, and a test asserts a third party holding BOTH permissions still cannot
    # revoke somebody else's link."* So holding `share_…` and `publish_…` is what lets you
    # MAKE links; it is not what lets you take somebody else's back.
    def revocable_by?(user)
      return false if user.nil? || !user.logged?
      return true if user.admin?
      return true if created_by_id == user.id
      # The template's owner, which is `author_id` — the same field `edit_own_…` reads.
      return true if template && template.author_id == user.id

      false
    end

    private

    # A SNAPSHOT WITH NOTHING TO SERVE IS NOT A SNAPSHOT. FR-52's whole claim is that the
    # bytes exist before the link does, so that no visibility decision happens at request
    # time; a `snapshot` row with a NULL document would have to fall back to rendering,
    # which is the opposite behaviour wearing the same name.
    def snapshot_has_a_document
      return unless scope_kind == SCOPE_SNAPSHOT
      return if rendered_document_id.present?

      errors.add(:rendered_document_id, :blank)
    end

    # Measured from `created_at` on a persisted row and from now on a new one — the same
    # rule `Document#expiry_within_the_retention_bound` uses, and for the same reason:
    # re-saving an old link must not fail for the link having been made a long time ago.
    def expiry_within_the_lifetime_bound
      return if expires_at.blank?

      origin = created_at || Time.zone.now
      return if expires_at <= origin + MAX_LIFETIME

      errors.add(:expires_at, :less_than_or_equal_to, count: (origin + MAX_LIFETIME).to_date)
    end

    # A LINK MUST NOT OUTLIVE THE SNAPSHOT IT POINTS AT — the actual document, not the class
    # constant. FOUND BY AN INDEPENDENT REVIEW, which measured a link outliving its document
    # by 300 days and serving it with a `200`: `MAX_LIFETIME` above bounds the link against a
    # CONSTANT, which says nothing about the row it authorises, and the commit message
    # claimed the opposite of what the code did.
    #
    # Checked here AND at serving time (`Document#servable?`), which is not belt-and-braces:
    # this one stops the bad link being created, and that one stops a link created before
    # this validation existed — or one whose document was later re-dated — from serving stale
    # bytes. Neither alone covers both.
    def expiry_within_the_snapshots_own
      return if expires_at.blank? || rendered_document_id.blank?

      document_expiry = rendered_document&.expires_at
      return if document_expiry.blank? || expires_at <= document_expiry

      errors.add(:expires_at, :less_than_or_equal_to, count: document_expiry.to_date)
    end
  end
end
