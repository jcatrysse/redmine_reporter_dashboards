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
        def hex_color(input)
          Support.hex_color(input)
        end

        # Black or white, whichever a reader can actually read on this background.
        #
        # The threshold is RELATIVE LUMINANCE, per WCAG's formula, not the average of the
        # three channels: the eye is roughly six times more sensitive to green than to
        # blue, so an averaging version puts white text on `#00ff00` and black on
        # `#0000ff` — both the wrong way round. 0.179 is the crossover where contrast
        # against black and against white are equal.
        def contrasting_text_color(input, dark = '#000000', light = '#ffffff')
          rgb = Support.to_rgb(input)
          return nil if rgb.nil?

          luminance = rgb.zip([0.2126, 0.7152, 0.0722]).sum do |channel, weight|
            linear = channel / 255.0
            weight * (linear <= 0.03928 ? linear / 12.92 : (((linear + 0.055) / 1.055)**2.4))
          end
          luminance > 0.179 ? dark : light
        end

        def darken(input, percent = 10)
          Support.shift_toward(input, -Support.number(percent).to_f)
        end

        def lighten(input, percent = 10)
          Support.shift_toward(input, Support.number(percent).to_f)
        end

        # --- THERE IS NO `private` SECTION HERE, AND THAT IS THE POINT ---
        #
        # `to_rgb`, `shift_toward` and the `HEX` pattern live in `Support`. They were
        # private methods of this module until 2026-08-21, and one of them was named
        # `shift` — which turned every template render into a 500 on an install with the
        # vendor gem present:
        #
        #     Liquid::MethodOverrideError: Filter overrides registered public methods as
        #     non public: shift
        #
        # A filter module's PRIVATE and PROTECTED methods are part of what Liquid
        # inspects. `Strainer.add_filter` refuses the module outright when one of those
        # names is already an invokable filter, and the gem globally registers 91 of them
        # — `shift` among them — the moment any plugin that depends on it is installed.
        # So one
        # private helper made this whole module unaddable and took `darken` and `lighten`
        # with it. `shift` is also in `Filters::REMOVED` ("mutates a shared object
        # mid-render"), so a name this plugin deliberately does not offer was sitting
        # inside a filter module regardless.
        #
        # `Filters.registered_names` could not have caught it: it reads
        # `public_instance_methods(false)`, and the hazard is precisely what it skips.
        # `spec_liquid/filters_spec.rb` now asserts that NO filter module has a non-public
        # instance method at all, which is the rule `support.rb`'s own header already
        # stated and this file was the exception to.
      end
    end
  end
end
