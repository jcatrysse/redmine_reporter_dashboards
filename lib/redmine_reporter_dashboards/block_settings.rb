# frozen_string_literal: true

module RedmineReporterDashboards
  # Sanitizer for the per-widget settings a dashboard editor posts.
  #
  # The controller used to hand `params[:settings][block].to_unsafe_hash` straight
  # to the model, having checked only that the BLOCK NAME was known. Nothing looked
  # at the keys or the values, and `ReporterProjectTab#settings` is a YAML-serialized
  # column — so a `manage_reporter_project_page` user could persist arbitrarily many
  # keys, arbitrarily long values and arbitrarily deep nesting into it. Nobody reads
  # those keys, but everybody pays for them: they are loaded, parsed and re-dumped on
  # every dashboard render, and they grow without limit.
  #
  # (`to_unsafe_hash` yields only Hash, Array and String, so this was never object
  # injection. It was an unbounded write, and unread keys that a later block or a
  # third-party partial might pick up.)
  #
  # --- Why not a strict per-block allowlist ---
  #
  # `ProjectPage.additional_blocks` discovers widgets by globbing
  # `plugins/*/app/views/reporter_project_pages/blocks/_*.erb`, so ANY plugin can add
  # a widget with settings of its own, and this file cannot know their names. A closed
  # allowlist would silently break those widgets the moment it shipped.
  #
  # So there are two tiers:
  #
  #   KNOWN keys — the ones the core widgets and the report widgets read — are typed.
  #                A non-integer `limit` or a `columns` entry that is not a column
  #                name is dropped, rather than stored and read back later.
  #   OTHER keys — accepted, because a third-party widget may need them, but only as
  #                a scalar or a flat list of scalars, and BOUNDED: key length, value
  #                length, list size and the number of keys per widget.
  #
  # Everything dropped is logged with the widget and the key, so an admin whose
  # setting did not stick can find out why. ReporterProjectTab also caps the
  # serialized size of the whole settings column, which is the backstop for many
  # widgets each holding a legal number of legal keys.
  module BlockSettings
    # Per widget. The core widgets use at most four keys; the headroom is for
    # third-party ones.
    MAX_KEYS = 20

    MAX_KEY_LENGTH   = 40
    MAX_VALUE_LENGTH = 255
    MAX_LIST_ITEMS   = 60

    # Digits only, and short enough that no reader's `to_i` is ever handed a
    # thousand-digit number.
    INTEGER_KEYS       = %w[limit days query_id report_template_id].freeze
    MAX_INTEGER_DIGITS = 10

    # Redmine column / group-by names: `status`, `spent_hours`, `cf_12`,
    # `project.name`. The readers validate these against the query's own
    # available_columns and groupable_columns as well; this only keeps junk out of
    # the stored YAML.
    NAME_RE = /\A[A-Za-z0-9_.:-]{1,60}\z/

    # `columns` is the only known key that legitimately holds a list.
    NAME_LIST_KEYS = %w[columns].freeze
    NAME_KEYS      = %w[group_by].freeze

    # A widget setting name: what a form field name can be.
    KEY_RE = /\A[a-z0-9_]+\z/

    # `nil` is this module's internal "drop the key" signal, so a setting whose VALUE
    # is legitimately nil — which is how the selects say "nothing chosen", and it has
    # to be storable or clearing a widget's query would silently keep the old one —
    # needs its own token on the way out. #sanitize turns it back into nil.
    NIL_SETTING = :__rrd_nil_setting__

    class << self
      # raw   — an ActionController::Parameters or Hash holding ONE widget's settings
      # block — the widget id, for the log lines
      #
      # Returns a Hash with String keys, safe to merge into the stored settings.
      def sanitize(raw, block: nil)
        pairs = to_pairs(raw)
        return {} if pairs.empty?

        clean = {}
        pairs.each do |key, value|
          key = key.to_s
          next unless usable_key?(key, block)

          if clean.size >= MAX_KEYS
            reject_setting(block, key, "more than #{MAX_KEYS} settings for one widget")
            next
          end

          sanitized = sanitize_value(key, value, block)
          next if sanitized.nil?

          clean[key] = sanitized == NIL_SETTING ? nil : sanitized
        end
        clean
      end

      private

      # Accepts ActionController::Parameters (which is not a Hash), a plain Hash, or
      # anything else — in which case there is nothing to read.
      def to_pairs(raw)
        if raw.respond_to?(:to_unsafe_h)
          raw.to_unsafe_h.to_a
        elsif raw.is_a?(Hash)
          raw.to_a
        else
          []
        end
      end

      def usable_key?(key, block)
        if key.length > MAX_KEY_LENGTH
          reject_setting(block, key.slice(0, MAX_KEY_LENGTH),
                         "setting name longer than #{MAX_KEY_LENGTH} characters")
          return false
        end
        unless key.match?(KEY_RE)
          reject_setting(block, key, 'setting name is not a plain lowercase identifier')
          return false
        end

        true
      end

      # nil means "drop this key"; NIL_SETTING means "store it as nil".
      def sanitize_value(key, value, block)
        if INTEGER_KEYS.include?(key)
          integer_value(key, value, block)
        elsif NAME_LIST_KEYS.include?(key)
          name_list_value(key, value, block)
        elsif NAME_KEYS.include?(key)
          name_value(key, value, block)
        else
          open_value(key, value, block)
        end
      end

      # Stored as an Integer rather than the form's String: every reader either calls
      # to_i or hands it to find_by, and options_for_select compares with to_s on both
      # sides, so the preselected option is unaffected.
      def integer_value(key, value, block)
        raw = value.to_s.strip
        return NIL_SETTING if raw.empty?

        unless raw.match?(/\A\d{1,#{MAX_INTEGER_DIGITS}}\z/)
          reject_setting(block, key, "expected a number, got #{raw.slice(0, 40).inspect}")
          return nil
        end

        raw.to_i
      end

      def name_value(key, value, block)
        raw = value.to_s.strip
        return NIL_SETTING if raw.empty?

        unless raw.match?(NAME_RE)
          reject_setting(block, key, "#{raw.slice(0, 40).inspect} is not a column name")
          return nil
        end

        raw
      end

      def name_list_value(key, value, block)
        list = bounded_list(key, Array(value), block)

        # An empty result is meaningful: it is how the columns picker says "nothing
        # chosen", and the readers fall back to their defaults on `.presence`.
        list.filter_map do |entry|
          name = entry.to_s.strip
          next if name.empty?
          next reject_setting(block, key, "#{name.slice(0, 40).inspect} is not a column name") unless
            name.match?(NAME_RE)

          name
        end
      end

      # A key this module does not know: a third-party widget's own. Scalars and flat
      # lists of scalars only, so nothing nested reaches the YAML column.
      def open_value(key, value, block)
        case value
        when NilClass
          NIL_SETTING
        when String, Symbol, Numeric, TrueClass, FalseClass
          scalar_value(key, value, block)
        when Array
          open_list_value(key, value, block)
        else
          reject_setting(block, key, "#{value.class} is not a storable setting value — only " \
                                     'text, numbers, booleans and flat lists of those are')
        end
      end

      def open_list_value(key, value, block)
        list = bounded_list(key, value, block)
        if list.any? { |entry| entry.is_a?(Hash) || entry.is_a?(Array) }
          return reject_setting(block, key, 'nested lists and hashes are not storable settings')
        end

        list.filter_map { |entry| entry.nil? ? nil : scalar_value(key, entry, block) }
      end

      def bounded_list(key, list, block)
        return list if list.size <= MAX_LIST_ITEMS

        reject_setting(block, key,
                       "more than #{MAX_LIST_ITEMS} entries — keeping the first #{MAX_LIST_ITEMS}")
        list.first(MAX_LIST_ITEMS)
      end

      def scalar_value(key, value, block)
        return value if value.is_a?(Numeric) || value == true || value == false

        text = value.to_s
        return text if text.length <= MAX_VALUE_LENGTH

        reject_setting(block, key, "value longer than #{MAX_VALUE_LENGTH} characters — truncated")
        text.slice(0, MAX_VALUE_LENGTH)
      end

      # Always returns nil, so callers can `return reject_setting(...)` and
      # `next reject_setting(...)` and read as "drop it, and say why".
      def reject_setting(block, key, reason)
        Rails.logger.warn("[reporter_dashboards] ignoring setting #{key.inspect} " \
                          "for widget #{block.to_s.inspect}: #{reason}")
        nil
      end
    end
  end
end
