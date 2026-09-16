# frozen_string_literal: true

module RedmineReporterDashboards
  module Render
    # Header and footer as STRUCTURED SLOTS, never as HTML (technical-spec.md §5).
    #
    # The reason is not tidiness. A template that emits engine-native footer markup —
    # wkhtmltopdf's `[page]`, Chromium's `class="pageNumber"`, a `@bottom-right` rule —
    # is soldered to the engine that understands it, and swapping engines silently
    # changes the footer into literal text or nothing at all. Slots plus a CLOSED token
    # set can be compiled to whatever each engine speaks, and the template author never
    # names an engine.
    #
    # The last four tokens exist so a PDF someone e-mails you six months later can say
    # which engine drew it and how long it took.
    class PageFurniture
      TOKENS = %w[
        page pages title date time datetime project template
        plugin_version engine render_duration_ms
      ].freeze

      TOKEN_PATTERN = /\{\{\s*([a-z_]+)\s*\}\}/.freeze

      DEFAULT_FONT_SIZE_PT = 9
      DEFAULT_HEIGHT_MM = 12

      class UnknownToken < ArgumentError; end

      attr_reader :left, :center, :right, :font_size_pt, :height_mm, :separator

      def initialize(left: '', center: '', right: '',
                     font_size_pt: DEFAULT_FONT_SIZE_PT, height_mm: DEFAULT_HEIGHT_MM,
                     separator: false)
        @left = validate_slot(left, :left)
        @center = validate_slot(center, :center)
        @right = validate_slot(right, :right)
        @font_size_pt = Integer(font_size_pt)
        @height_mm = Integer(height_mm)
        @separator = separator ? true : false
        freeze
      end

      def empty?
        left.empty? && center.empty? && right.empty?
      end

      def slots
        { 'left' => left, 'center' => center, 'right' => right }.freeze
      end

      # Every token used across the three slots, for an engine adapter to resolve.
      def tokens_used
        slots.values.flat_map { |slot| slot.scan(TOKEN_PATTERN).flatten }.uniq.freeze
      end

      def to_h
        { 'left' => left, 'center' => center, 'right' => right,
          'font_size_pt' => font_size_pt, 'height_mm' => height_mm,
          'separator' => separator }.freeze
      end

      private

      # Literal text plus tokens from the closed set. An unknown token RAISES rather
      # than passing through: passing it through means it reaches the reader as
      # `{{pgae}}` in a document they were told was finished, and the author never
      # learns. Raising here is caught by the caller and becomes a typed Failure.
      def validate_slot(text, slot)
        value = text.to_s
        unknown = value.scan(TOKEN_PATTERN).flatten.reject { |token| TOKENS.include?(token) }
        return value.freeze if unknown.empty?

        raise UnknownToken,
              "page furniture #{slot} slot uses #{unknown.map { |t| "{{#{t}}}" }.join(', ')}, " \
              "which is not in the closed token set. Known: #{TOKENS.map { |t| "{{#{t}}}" }.join(' ')}"
      end
    end
  end
end
