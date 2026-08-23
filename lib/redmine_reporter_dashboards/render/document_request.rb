# frozen_string_literal: true

require_relative 'capabilities'
require_relative 'page_furniture'

module RedmineReporterDashboards
  module Render
    # Everything an engine needs to draw one document — and NOTHING a credential could
    # travel in.
    #
    # --- The security property is the SHAPE, not a check ---
    #
    # technical-spec.md §11 lists "renderer credential exposure" and answers it like
    # this: "DocumentRequest has no field a credential could travel in — no `cookies:`,
    # `headers:`, `auth:`. Cookie-passing is not discouraged, it is *unrepresentable*."
    #
    # That is a design constraint on THIS FILE, and the way to keep it is to notice what
    # would break it: any general-purpose escape hatch. A `headers:` hash, an
    # `extra_options:` bag, a `url:` the engine fetches while carrying ambient
    # credentials — each of those re-opens it, and each looks harmless in review because
    # the harm is in what someone else puts in later. `body` is a COMPLETE,
    # already-asset-resolved document precisely so the engine never fetches anything on
    # the viewer's behalf.
    #
    # Adding a field here is therefore a security decision, and the spec for it is
    # INV-8. The suite asserts the absence by enumerating the constructor's parameters,
    # so a new one has to be argued rather than merely committed.
    class DocumentRequest
      PAGE_SIZES = %w[A4 A3 A5 Letter Legal Tabloid].freeze
      ORIENTATIONS = %i[portrait landscape].freeze
      MEDIA = %i[print screen].freeze

      DEFAULT_MARGINS_MM = { 'top' => 15, 'right' => 12, 'bottom' => 15, 'left' => 12 }.freeze
      DEFAULT_TIMEOUT_MS = 30_000

      class InvalidRequest < ArgumentError; end

      attr_reader :body, :assets, :page_size, :orientation, :margins_mm, :scale, :media,
                  :print_backgrounds, :page_breaks, :header, :footer, :readiness,
                  :timeout_ms, :pdf_metadata, :tagged, :outline, :correlation_id,
                  :required_capabilities, :essential_capabilities

      def initialize(body:, correlation_id:,
                     assets: {}, page_size: 'A4', orientation: :portrait,
                     margins_mm: DEFAULT_MARGINS_MM, scale: 1.0, media: :print,
                     print_backgrounds: true, page_breaks: true,
                     header: nil, footer: nil, readiness: nil,
                     timeout_ms: DEFAULT_TIMEOUT_MS, pdf_metadata: {},
                     tagged: false, outline: false,
                     required_capabilities: [], essential_capabilities: [])
        @body = body.to_s.freeze
        @assets = assets.freeze
        @page_size = validate_inclusion(page_size.to_s, PAGE_SIZES, 'page_size')
        @orientation = validate_inclusion(orientation.to_sym, ORIENTATIONS, 'orientation')
        @margins_mm = normalize_margins(margins_mm)
        @scale = Float(scale)
        @media = validate_inclusion(media.to_sym, MEDIA, 'media')
        # DEFAULT TRUE, and not the engine's default. Chromium's printToPDF defaults
        # this to false, so a naive swap silently loses every badge and progress-bar
        # colour in the existing templates. Overriding engine defaults that differ
        # across engines is part of the abstraction's job, not the caller's (§5).
        @print_backgrounds = print_backgrounds ? true : false
        @page_breaks = page_breaks ? true : false
        @header = validate_furniture(header, 'header')
        @footer = validate_furniture(footer, 'footer')
        @readiness = readiness
        @timeout_ms = Integer(timeout_ms)
        @pdf_metadata = pdf_metadata.freeze
        @tagged = tagged ? true : false
        @outline = outline ? true : false
        @correlation_id = correlation_id.to_s.freeze
        @required_capabilities =
          Capabilities.validate!(required_capabilities, 'required_capabilities')
        @essential_capabilities =
          Capabilities.validate!(essential_capabilities, 'essential_capabilities')
        validate_essential_subset!
        freeze
      end

      def landscape?
        orientation == :landscape
      end

      def page_furniture?
        [header, footer].compact.any? { |furniture| !furniture.empty? }
      end

      private

      def validate_inclusion(value, allowed, what)
        return value if allowed.include?(value)

        raise InvalidRequest, "#{what} #{value.inspect} is not one of #{allowed.inspect}"
      end

      def normalize_margins(margins)
        given = margins.each_with_object({}) { |(k, v), out| out[k.to_s] = Integer(v) }
        DEFAULT_MARGINS_MM.merge(given).freeze
      end

      def validate_furniture(value, what)
        return nil if value.nil?
        return value if value.is_a?(PageFurniture)

        raise InvalidRequest,
              "#{what} must be a PageFurniture, not #{value.class}. Furniture is structured " \
              'slots plus a closed token set precisely so no template can emit engine-native ' \
              'markup that another engine renders as literal text.'
      end

      # An essential capability that is not also required is a contradiction: the
      # negotiation subtracts `required - available`, so a capability nobody required
      # can never be found missing, and declaring it essential would do nothing.
      def validate_essential_subset!
        stray = essential_capabilities - required_capabilities
        return if stray.empty?

        raise InvalidRequest,
              "#{stray.inspect} declared essential but not required — an essential capability " \
              'that is not required is never checked, which reads as a guarantee and is none.'
      end
    end
  end
end
