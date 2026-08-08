# frozen_string_literal: true

module RedmineReporterDashboards
  module Reporting
    # T-32 / FR-61 — who an ad-hoc report may be mailed to, and how often.
    #
    # --- WHY THIS IS A SETTING AND NOT A PERMISSION ---
    #
    # `technical-spec.md` §4.1 lists "sending to an external address" under *deliberately
    # not permissions*: **"admin setting + domain allowlist … a policy about the
    # installation, not a capability of a role"**. A role grant says what a person may do
    # inside a project; whether this Redmine may put a report into a mailbox it does not
    # own is a property of the deployment, and no per-project answer to it is meaningful.
    #
    # --- IT IS BUILT THE WAY `Assets::Policy` IS BUILT, AND FOR THE SAME REASON ---
    #
    # Redmine performs NO validation on plugin settings — an administrator can save any
    # string — so every value is coerced and bounded on the way OUT, and anything replaced
    # is RECORDED in `dropped` rather than silently corrected. FR-15's rule
    # ("over-limit input is dropped with a log line rather than stored") applied to a
    # settings block.
    #
    # --- THE COLLAPSE, WHICH IS THE ONE BEHAVIOUR THAT MUST FAIL CLOSED ---
    #
    # FR-64 makes an empty asset allowlist behave exactly as `:bundled`. The same rule is
    # applied here and it is the more important of the two: *external addresses enabled with
    # an empty allowlist means external addresses OFF*, not "any domain". An operator who
    # ticks the box and saves an empty list has expressed an intention and configured
    # nothing, and the reading that turns that into "mail anywhere" is precisely the
    # spoofing-relay finding §7b.5 exists to close.
    #
    # `#collapsed?` exists so the settings page can SAY so, because a control that fails
    # closed silently is a control an administrator believes is on.
    class MailPolicy
      DEFAULT_RATE_LIMIT = 12
      MAX_RATE_LIMIT = 500
      DEFAULT_RATE_WINDOW_MINUTES = 60
      MAX_RATE_WINDOW_MINUTES = 24 * 60

      # A conservative, deliberately boring hostname shape — the same one `Assets::Policy`
      # uses for its allowlist. It is not an RFC-complete grammar and does not try to be:
      # anything it refuses is reported to the administrator by name rather than accepted
      # on a guess.
      DOMAIN = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/.freeze

      attr_reader :external_enabled, :domains, :rate_limit, :rate_window_minutes, :dropped

      def initialize(external_enabled: false, domains: [], rate_limit: DEFAULT_RATE_LIMIT,
                     rate_window_minutes: DEFAULT_RATE_WINDOW_MINUTES, dropped: [],
                     requested_external: false)
        @external_enabled = external_enabled ? true : false
        @domains = Array(domains).freeze
        @rate_limit = rate_limit
        @rate_window_minutes = rate_window_minutes
        @dropped = Array(dropped).freeze
        @requested_external = requested_external ? true : false
        freeze
      end

      class << self
        def from_settings(settings, logger: nil)
          source = settings || {}
          dropped = []

          requested = truthy?(fetch(source, 'mail_external_addresses'))
          domains = coerce_domains(fetch(source, 'mail_external_domains'), dropped)
          limit = coerce_integer(fetch(source, 'mail_rate_limit'), 'mail_rate_limit',
                                 DEFAULT_RATE_LIMIT, MAX_RATE_LIMIT, dropped)
          window = coerce_integer(fetch(source, 'mail_rate_window_minutes'),
                                  'mail_rate_window_minutes',
                                  DEFAULT_RATE_WINDOW_MINUTES, MAX_RATE_WINDOW_MINUTES,
                                  dropped)

          # THE COLLAPSE. Enabled AND non-empty, or off.
          enabled = requested && domains.any?

          dropped.each do |entry|
            next unless logger.respond_to?(:warn)

            logger.warn("[reporter_dashboards] mail setting #{entry[:key]}=" \
                        "#{entry[:value].inspect} dropped: #{entry[:reason]}")
          end

          new(external_enabled: enabled, domains: domains, rate_limit: limit,
              rate_window_minutes: window, dropped: dropped, requested_external: requested)
        end

        def current(logger: nil)
          from_settings(RedmineReporterDashboards.plugin_settings, logger: logger)
        end

        private

        # A settings Hash reaches this class with String keys from Redmine and Symbol keys
        # from a test that built one. Reading only one of the two is how a spec passes
        # against a shape production never produces.
        def fetch(source, key)
          return source[key] if source.key?(key)

          source[key.to_sym]
        end

        # Redmine's own checkbox posts '1'/'0' and a default Hash carries true/false, so
        # both spellings have to be read. Anything else is false, which is the fail-closed
        # direction for a switch that turns egress on.
        def truthy?(raw)
          return true if raw == true
          return false if raw.nil? || raw == false

          %w[1 true yes on].include?(raw.to_s.strip.downcase)
        end

        def coerce_domains(raw, dropped)
          entries = case raw
                    when nil then []
                    when Array then raw
                    else raw.to_s.split(/[\s,;]+/)
                    end

          entries.filter_map do |entry|
            candidate = entry.to_s.strip.downcase.sub(/\A@/, '').sub(/\.\z/, '')
            next if candidate.empty?
            next candidate if candidate.match?(DOMAIN)

            dropped << { key: 'mail_external_domains', value: entry,
                         reason: 'not a hostname' }
            nil
          end.uniq
        end

        def coerce_integer(raw, key, default, maximum, dropped)
          return default if raw.nil? || raw.to_s.strip.empty?

          value = Integer(raw.to_s.strip, 10)
          # ZERO IS A LEGITIMATE LIMIT and is not clamped up to the default: an
          # administrator who sets the rate limit to 0 has turned ad-hoc mail off, which is
          # a thing they may reasonably want and which no other control expresses.
          # NEGATIVE is not, because it is not a smaller number of sends, it is a typo.
          return default if value.negative? && record(dropped, key, raw, 'negative')
          return maximum if value > maximum && record(dropped, key, raw, "above #{maximum}")

          value
        rescue ArgumentError, TypeError
          dropped << { key: key, value: raw, reason: "not an integer; using #{default}" }
          default
        end

        # Answers true so the guards above read as one expression. A `record` that answered
        # nil would make `value.negative? && record(...)` fall through to `value`, which is
        # the bug this method's return value exists to not have.
        def record(dropped, key, raw, reason)
          dropped << { key: key, value: raw, reason: reason }
          true
        end
      end

      # The administrator asked for external addresses and got none, because the allowlist
      # is empty. The settings page prints a warning on this.
      def collapsed?
        @requested_external && !external_enabled
      end

      # FR-61's gate, for one address. `false` for every address when external addresses
      # are off, which is the default and is what makes "recipients are Redmine users"
      # true by construction rather than by the form not offering a field.
      def external_permitted?(address)
        return false unless external_enabled

        domain = domain_of(address)
        return false if domain.nil?

        # EXACT MATCH, NOT A SUFFIX MATCH. `end_with?('example.com')` also accepts
        # `notexample.com`, and a subdomain is a different mail destination that an
        # administrator listing `example.com` has not named. If they want the subdomain
        # they list it — the same rule `Assets::Policy` applies to hosts.
        domains.include?(domain)
      end

      def domain_of(address)
        text = address.to_s.strip.downcase
        # ONE `@`, and the domain is what follows it. `a@b@c` is not an address, and
        # splitting on the LAST `@` would accept it while reading the allowlist check as
        # having passed.
        return nil unless text.count('@') == 1

        local, domain = text.split('@', 2)
        # A NON-EMPTY LOCAL PART IS REQUIRED, and its absence was a real defect found by
        # the spec rather than by reading: `@example.com` has exactly one `@` and a domain
        # that matches the allowlist, so it was ACCEPTED — an undeliverable string recorded
        # in the audit as a recipient, and one `Mail::Address` may parse into something
        # other than what was checked. The local part's internal grammar is deliberately
        # not policed here; the MTA owns that, and the question this method answers is
        # which DOMAIN the administrator is being asked to permit.
        return nil if local.to_s.strip.empty?

        domain = domain.to_s.sub(/\.\z/, '')
        domain.match?(DOMAIN) ? domain : nil
      end

      def rate_limited?(count)
        count >= rate_limit
      end
    end
  end
end
