# frozen_string_literal: true

module RedmineReporterDashboards
  module Assets
    # `asset_policy` — three values, `:bundled` the default (technical-spec.md §5.1,
    # FR-64).
    #
    # | value       | local files    | same-origin Redmine URLs        | third-party URLs |
    # |-------------|----------------|---------------------------------|------------------|
    # | `:bundled`  | inline/upload  | rewritten to disk, NEVER fetched | refused          |
    # | `:redmine`  | inline/upload  | fetched, allowlisted host only   | refused          |
    # | `:external` | inline/upload  | as `:redmine`                    | fetched, allowlist-only |
    #
    # --- THE TWO PROPERTIES THAT ARE NOT PREFERENCES ---
    #
    # **Per install, never per template.** There is no constructor argument, no register,
    # no Liquid variable and no tag parameter through which a document can reach this
    # object. Template authoring is already a code-execution privilege (INV-9); if it
    # were also a network privilege, the two would compound. T-33's acceptance list
    # states it directly — "a test asserts an author cannot widen egress from template
    # content" — and `spec/assets/resolver_spec.rb` is where that is asserted.
    #
    # **An empty allowlist fails CLOSED.** §5.1: "an empty allowlist makes `:external`
    # behave exactly as `:bundled` — misconfiguration fails closed". This implementation
    # extends that to `:redmine` for the same reason and with no loss: under `:bundled` a
    # same-origin reference is rewritten to the file on disk, which is strictly better
    # than fetching it. So `effective_mode` collapses ANY upgraded mode with an empty
    # allowlist, and `collapsed?` exists so the settings page can SAY SO rather than
    # leaving an operator to believe a switch took effect (INV-4).
    #
    # --- WHY `from_settings` COERCES AND `new` RAISES ---
    #
    # They answer to different people. `new` is called by this plugin's own code, where a
    # bad mode is a programming error and must be loud. `from_settings` is fed a Hash an
    # operator typed into a web form, where FR-15 applies: typed, bounded, and
    # "over-limit input is dropped with a log line rather than stored". Redmine performs
    # no validation on plugin settings, so this is the only place it can happen.
    class Policy
      MODES = %i[bundled redmine external].freeze
      DEFAULT_MODE = :bundled

      # §5.1's figures. `inline_max_bytes` is the point above which base64 growth costs
      # more than a second round trip; `asset_max_bytes` is a hard refusal.
      DEFAULT_INLINE_MAX_BYTES = 512 * 1024
      DEFAULT_ASSET_MAX_BYTES = 8 * 1024 * 1024

      # Ceilings an operator may lower and not raise. A 300 MB "asset" is a memory
      # exhaustion primitive against a renderer with a wall-clock budget, and the person
      # who would raise it is the person who has not thought about that yet.
      MAX_INLINE_MAX_BYTES = 4 * 1024 * 1024
      MAX_ASSET_MAX_BYTES = 32 * 1024 * 1024
      MIN_BYTES = 1

      # §5.1: "2 s connect, 5 s total", "redirect count 0", "https only". Constants
      # rather than settings, deliberately: each is a security property, and a setting
      # is a thing an operator can be talked into changing.
      CONNECT_TIMEOUT_S = 2
      TOTAL_TIMEOUT_S = 5
      MAX_REDIRECTS = 0
      FETCH_SCHEME = 'https'

      # HOSTS, NOT PATTERNS (§5.1, in those words). `*.example.com` is rejected rather
      # than interpreted, because a pattern language in an allowlist is a place for a
      # mistake to hide — `*.example.com` matching `evil.example.com.attacker.net` is the
      # canonical one. A trailing dot is stripped; anything else non-hostname is dropped.
      HOST_RE = /\A[a-z0-9](?:[a-z0-9\-.]*[a-z0-9])?\z/

      # An allowlist an operator can paste from anywhere: newlines, commas, or spaces.
      ALLOWLIST_SEPARATORS = /[\s,;]+/

      class InvalidPolicy < ArgumentError; end

      attr_reader :mode, :allowlist, :inline_max_bytes, :asset_max_bytes, :dropped

      def initialize(mode: DEFAULT_MODE, allowlist: [],
                     inline_max_bytes: DEFAULT_INLINE_MAX_BYTES,
                     asset_max_bytes: DEFAULT_ASSET_MAX_BYTES,
                     dropped: [])
        @mode = mode.to_sym
        unless MODES.include?(@mode)
          raise InvalidPolicy,
                "#{mode.inspect} is not an asset policy. Known: #{MODES.inspect}. " \
                'Use Policy.from_settings for operator input — it coerces and logs ' \
                'instead of raising, which is what FR-15 asks for.'
        end

        @allowlist = normalize_allowlist(allowlist)
        @inline_max_bytes = Integer(inline_max_bytes)
        @asset_max_bytes = Integer(asset_max_bytes)
        # A threshold above the hard cap can never fire, which reads as "inline
        # everything" and is not what either number means.
        if @inline_max_bytes > @asset_max_bytes
          raise InvalidPolicy,
                "inline_max_bytes (#{@inline_max_bytes}) is above asset_max_bytes " \
                "(#{@asset_max_bytes}); the threshold would never be reached and the " \
                'refusal would happen first.'
        end

        @dropped = Array(dropped).freeze
        freeze
      end

      class << self
        # The operator-facing constructor. Every key is optional, every bad value is
        # replaced by the default and RECORDED in `dropped` — which the caller logs and
        # the settings view shows. Nothing raises: a typo in a text field must not take
        # the render path down.
        def from_settings(settings, logger: nil)
          source = stringify(settings)
          dropped = []

          mode = coerce_mode(source['asset_policy'], dropped)
          allowlist = coerce_allowlist(source['asset_allowlist'], dropped)
          inline_max = coerce_bytes(source['inline_max_bytes'], 'inline_max_bytes',
                                    DEFAULT_INLINE_MAX_BYTES, MAX_INLINE_MAX_BYTES, dropped)
          asset_max = coerce_bytes(source['asset_max_bytes'], 'asset_max_bytes',
                                   DEFAULT_ASSET_MAX_BYTES, MAX_ASSET_MAX_BYTES, dropped)
          # The cross-field rule, applied here rather than raised: lower the threshold to
          # the cap, and say so.
          if inline_max > asset_max
            dropped << { key: 'inline_max_bytes', value: inline_max,
                         reason: "above asset_max_bytes (#{asset_max}); lowered to it" }
            inline_max = asset_max
          end

          dropped.each do |entry|
            logger&.warn(
              "[reporter_dashboards] asset setting #{entry[:key]}=#{entry[:value].inspect} " \
              "dropped: #{entry[:reason]}"
            )
          end

          new(mode: mode, allowlist: allowlist, inline_max_bytes: inline_max,
              asset_max_bytes: asset_max, dropped: dropped)
        end

        # The default, as an object. Used wherever a policy is needed and none has been
        # configured — which must be the safe one, not a nil that a caller interprets.
        def bundled
          new
        end

        private

        def stringify(settings)
          return {} if settings.nil?
          return {} unless settings.respond_to?(:each_pair) || settings.respond_to?(:each)

          settings.to_h { |key, value| [key.to_s, value] }
        rescue StandardError
          {}
        end

        def coerce_mode(raw, dropped)
          return DEFAULT_MODE if raw.nil? || raw.to_s.strip.empty?

          candidate = raw.to_s.strip.downcase.to_sym
          return candidate if MODES.include?(candidate)

          dropped << { key: 'asset_policy', value: raw,
                       reason: "not one of #{MODES.inspect}; using #{DEFAULT_MODE}" }
          DEFAULT_MODE
        end

        def coerce_allowlist(raw, dropped)
          entries =
            if raw.is_a?(Array)
              raw
            else
              raw.to_s.split(ALLOWLIST_SEPARATORS)
            end

          entries.each_with_object([]) do |entry, out|
            host = entry.to_s.strip.downcase.sub(/\.\z/, '')
            next if host.empty?

            if HOST_RE.match?(host)
              out << host
            else
              dropped << { key: 'asset_allowlist', value: entry,
                           reason: 'not a bare hostname — hosts, not patterns, no scheme, ' \
                                   'no port, no path (§5.1)' }
            end
          end
        end

        def coerce_bytes(raw, key, default, ceiling, dropped)
          return default if raw.nil? || raw.to_s.strip.empty?

          value = Integer(raw.to_s.strip, 10)
          if value < MIN_BYTES
            dropped << { key: key, value: raw, reason: "below #{MIN_BYTES}; using #{default}" }
            return default
          end
          if value > ceiling
            dropped << { key: key, value: raw, reason: "above the #{ceiling}-byte ceiling; clamped" }
            return ceiling
          end

          value
        rescue ArgumentError, TypeError
          dropped << { key: key, value: raw, reason: "not an integer; using #{default}" }
          default
        end
      end

      # What the policy ACTUALLY does, which is not always what it says. §5.1's
      # fail-closed rule lives here and nowhere else, so no caller can forget it.
      def effective_mode
        return DEFAULT_MODE if mode != DEFAULT_MODE && allowlist.empty?

        mode
      end

      def collapsed?
        effective_mode != mode
      end

      def bundled?
        effective_mode == DEFAULT_MODE
      end

      # `classification` is a `Reference` classification, and only two of them can
      # reach the network at all.
      def may_fetch?(classification)
        case effective_mode
        when :redmine then classification == :same_origin
        when :external then %i[same_origin third_party].include?(classification)
        else false
        end
      end

      def allows_host?(host)
        return false if host.nil?

        allowlist.include?(host.to_s.downcase.sub(/\.\z/, ''))
      end

      # BOTH conditions, in one place. A permitted class with an unlisted host is a
      # refusal, and so is a listed host in a class the mode does not permit — the
      # allowlist is not a bypass of the mode.
      def fetch_allowed?(classification, host)
        may_fetch?(classification) && allows_host?(host)
      end

      def to_h
        { 'mode' => mode.to_s, 'effective_mode' => effective_mode.to_s,
          'collapsed' => collapsed?, 'allowlist' => allowlist,
          'inline_max_bytes' => inline_max_bytes, 'asset_max_bytes' => asset_max_bytes }.freeze
      end

      private

      def normalize_allowlist(list)
        Array(list).map { |host| host.to_s.strip.downcase.sub(/\.\z/, '') }
                   .reject(&:empty?)
                   .tap do |hosts|
          bad = hosts.reject { |host| HOST_RE.match?(host) }
          unless bad.empty?
            raise InvalidPolicy,
                  "#{bad.inspect} are not bare hostnames. §5.1: hosts, not patterns. " \
                  'Use Policy.from_settings for operator input.'
          end
        end.uniq.freeze
      end
    end
  end
end
