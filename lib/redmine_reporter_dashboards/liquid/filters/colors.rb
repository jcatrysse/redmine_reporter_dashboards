# frozen_string_literal: true

require_relative 'support'

module RedmineReporterDashboards
  module Liquid
    module Filters
      # `hex_color contrasting_text_color darken lighten` — enough colour arithmetic to
      # build a legend, and no more.
      #
      # EVERY ONE RETURNS nil FOR AN INPUT IT CANNOT PARSE, never a default colour. A
      # filter that answered `#000000` for a typo would put a black swatch in a legend
      # and the author would spend an afternoon looking for it in their data. nil renders
      # empty, the CSS declaration is invalid, and the browser falls back visibly.
      module Colors
        HEX = /\A#?(\h{3}|\h{6})\z/.freeze

        # `abc` / `#abc` / `aabbcc` / `#AABBCC` -> `#aabbcc`. Three-digit form expanded,
        # because `darken` cannot work on it and two spellings of one colour is how a
        # palette ends up with two entries for the same swatch.
        def hex_color(input)
          match = HEX.match(input.to_s.strip)
          return nil if match.nil?

          digits = match[1].downcase
          digits = digits.chars.map { |char| char * 2 }.join if digits.length == 3
          "##{digits}"
        end

        # Black or white, whichever a reader can actually read on this background.
        #
        # The threshold is RELATIVE LUMINANCE, per WCAG's formula, not the average of the
        # three channels: the eye is roughly six times more sensitive to green than to
        # blue, so an averaging version puts white text on `#00ff00` and black on
        # `#0000ff` — both the wrong way round. 0.179 is the crossover where contrast
        # against black and against white are equal.
        def contrasting_text_color(input, dark = '#000000', light = '#ffffff')
          rgb = to_rgb(input)
          return nil if rgb.nil?

          luminance = rgb.zip([0.2126, 0.7152, 0.0722]).sum do |channel, weight|
            linear = channel / 255.0
            weight * (linear <= 0.03928 ? linear / 12.92 : (((linear + 0.055) / 1.055)**2.4))
          end
          luminance > 0.179 ? dark : light
        end

        def darken(input, percent = 10)
          shift(input, -Support.number(percent).to_f)
        end

        def lighten(input, percent = 10)
          shift(input, Support.number(percent).to_f)
        end

        private

        def to_rgb(input)
          normalised = hex_color(input)
          return nil if normalised.nil?

          normalised[1..].scan(/\h{2}/).map { |pair| pair.to_i(16) }
        end

        # Toward white or toward black by a percentage of the REMAINING distance, which
        # is what "10% lighter" means to a designer. A flat `+25` per channel saturates
        # a bright colour and does almost nothing to a dark one.
        def shift(input, percent)
          rgb = to_rgb(input)
          return nil if rgb.nil?

          ratio = percent.clamp(-100.0, 100.0) / 100.0
          moved = rgb.map do |channel|
            target = ratio.negative? ? 0 : 255
            (channel + ((target - channel) * ratio.abs)).round.clamp(0, 255)
          end
          format('#%02x%02x%02x', *moved)
        end
      end
    end
  end
end
