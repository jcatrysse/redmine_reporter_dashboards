# frozen_string_literal: true

module RedmineReporterDashboards
  # T-28 — one row per attempt on a share link. FR-53.
  #
  # --- WHY REFUSALS ARE LOGGED TOO, AND WHY THAT IS THE POINT ---
  #
  # FR-53 says "every share-link ACCESS is recorded". The reading that logs only successes
  # would make the table useless for the question an administrator actually has, which is
  # never "how popular is this link" — it is *"has somebody been trying links at us"*. An
  # expired or revoked token being presented is the single most interesting row this table
  # can hold, so `outcome` is NOT NULL and carries the refusal reason.
  #
  # --- APPEND-ONLY, EXPRESSED IN THE SCHEMA ---
  #
  # There is no `updated_at`, exactly as `TemplateVersion` has none (migration 003): "a row
  # that can be updated is not an audit trail, and a schema that offers an `updated_at`
  # invites the first person in a hurry to update one." `readonly?` says the same thing to
  # anything holding the object, and the absent column says it to a console session.
  class ShareLinkAccess < RedmineReporterDashboards::Compat.base_record
    self.table_name = 'reporter_dashboards_share_link_accesses'

    # `served` plus `ShareLink#refusal`'s three. Closed, because `outcome` is a stored
    # string that a reader will group by — and a typo'd value would silently become its
    # own category in somebody's count.
    #
    # `not_found` WAS IN THIS LIST AND IS DELIBERATELY GONE (T-28 increment 2). Two reasons,
    # and the first alone settles it: `share_link_id` is NOT NULL, so a token matching no
    # row has nothing to hang a record on — a value a schema cannot store is a lie in a
    # constant, and the enumeration is what tells a reader which categories exist. The
    # second is why the column should not be made nullable to accommodate it: the share
    # endpoint is reachable without an account, so a nullable `share_link_id` would let
    # anyone on the internet write a row per request into this table by presenting
    # gibberish. An unmatched token goes to `Rails.logger` instead, where the same fact is
    # recorded under the log rotation an operator already has.
    OUTCOME_SERVED = 'served'
    OUTCOMES = [OUTCOME_SERVED, 'revoked', 'expired', 'exhausted'].freeze

    MAX_STRING = 255

    belongs_to :share_link,
               class_name: 'RedmineReporterDashboards::ShareLink',
               foreign_key: 'share_link_id',
               inverse_of: :accesses

    validates :outcome, inclusion: { in: OUTCOMES }
    # BOUNDED, BECAUSE BOTH ARE ATTACKER-SUPPLIED. `User-Agent` is a request header of
    # arbitrary length and `ip_address` can be a forwarded-for chain; unbounded, they are a
    # way to write a megabyte per request into this table. Truncated rather than refused —
    # losing the tail of a user agent is nothing, losing the audit row is the thing this
    # table exists to prevent.
    validates :ip_address, :user_agent, length: { maximum: MAX_STRING }, allow_nil: true

    before_validation :truncate_request_fields

    def readonly?
      # ONLY ONCE PERSISTED, so the row can be created and never changed. A blanket
      # `readonly?` would make `create` itself fail.
      persisted?
    end

    def served?
      outcome == OUTCOME_SERVED
    end

    private

    def truncate_request_fields
      self.ip_address = ip_address[0, MAX_STRING] if ip_address.is_a?(String)
      self.user_agent = user_agent[0, MAX_STRING] if user_agent.is_a?(String)
    end
  end
end
