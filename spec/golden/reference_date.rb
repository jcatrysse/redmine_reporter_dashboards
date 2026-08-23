# frozen_string_literal: true

require 'date'

module RrdGolden
  # The date the golden aggregation corpus is generated against.
  #
  # The adapter execution fixture is deliberately Time.zone.today-relative: a
  # 400-day sweep, so whatever today happens to be, the database's own
  # day/week/month/year bucketing is made to collide with Ruby's labels for it —
  # including the ISO-week turn of the year. That is right for a self-consistent
  # spec and fatal for an oracle, whose every expected value would change daily,
  # go red for the wrong reason, and get switched off within a week.
  #
  # So the corpus pins the date, and the verifier REFUSES TO RUN unpinned
  # (#require!). Pinning is not a downgrade here:
  #
  #   * DEFAULT is 2025-12-29 — a Monday whose ISO year (2026) differs from its
  #     calendar year (2025). The reference date itself therefore exercises the
  #     TO_CHAR(x, 'IYYY"-W"IW') vs DATE_FORMAT(x, '%x-W%v') divergence, instead
  #     of depending on the sweep to wander into it.
  #   * a 400-day sweep back from it still spans three distinct ISO years
  #     (2024, 2025, 2026), so the week-turn coverage the relative fixture was
  #     built for is kept.
  #
  # Left unset, #date returns nil and the adapter execution specs keep their
  # relative-to-today fixture unchanged. Only the corpus insists on a pin.
  module ReferenceDate
    ENV_VAR = 'RRD_REFERENCE_DATE'
    DEFAULT = '2025-12-29'

    class NotPinned < StandardError; end
    class Malformed < ArgumentError; end

    class << self
      # nil when unset, so callers can tell "no pin" from "pinned to today".
      def date
        raw = ENV[ENV_VAR].to_s.strip
        return nil if raw.empty?

        parse(raw)
      end

      def pinned?
        !date.nil?
      end

      # What the corpus generator and verifier call instead of trusting `today`.
      def require!
        pinned = date
        return pinned if pinned

        raise NotPinned,
              "#{ENV_VAR} is not set. The golden aggregation corpus is an oracle: generated or " \
              'verified against a moving date it changes daily and stops meaning anything. ' \
              "Set #{ENV_VAR}=#{DEFAULT} — the date the committed corpus was generated with."
      end

      private

      # Date.iso8601 accepts the compact 20251229 form as well, which would make two
      # spellings of one date look like two pins. The corpus records the pin in its
      # provenance header, so exactly one spelling is allowed.
      def parse(raw)
        unless /\A\d{4}-\d{2}-\d{2}\z/.match?(raw)
          raise Malformed,
                "#{ENV_VAR}=#{raw.inspect} is not an extended ISO-8601 date. " \
                "Expected YYYY-MM-DD, e.g. #{DEFAULT}."
        end

        # ArgumentError, not Date::Error: Date::Error only exists from Ruby 3.0, and
        # Redmine 5.1 permits Ruby 2.7, where naming it would turn a bad date into a
        # NameError. It subclasses ArgumentError everywhere it does exist.
        begin
          Date.iso8601(raw)
        rescue ArgumentError => e
          raise Malformed, "#{ENV_VAR}=#{raw.inspect} is not a real date (#{e.message})."
        end
      end
    end
  end
end
