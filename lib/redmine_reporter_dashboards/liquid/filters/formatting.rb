# frozen_string_literal: true

require 'cgi'

require_relative 'support'

module RedmineReporterDashboards
  module Liquid
    module Filters
      # `currency duration wiki utc` — the four that turn a value into something a
      # reader recognises.
      module Formatting
        THOUSANDS = /(\d)(?=(\d{3})+(?!\d))/.freeze

        # `{{ 1234.5 | currency: "€" }}` -> `€1,234.50`
        #
        # THE SYMBOL IS AN ARGUMENT AND HAS NO DEFAULT, and that is a deliberate refusal
        # rather than an omission. Redmine has no instance currency setting to read, and
        # the gem's version took one off a "container" object this plugin does not have.
        # Inventing a plugin setting for it is a settings decision — a new key, nine
        # locale files, an admin form — and it belongs to whoever needs it, not to a
        # filter that would otherwise guess euros for a Canadian install.
        #
        # So with no argument this formats the number and says nothing about what it
        # measures, which is honest. `precision: 2` because money has two decimal places
        # in the currencies that have decimals at all; an author with yen passes 0.
        def currency(input, symbol = nil, precision = 2)
          number = Support.number(input)
          return nil if number.nil?

          places = Integer(precision)
          # `.round(places)` BEFORE formatting. `format('%.0f', 1234.5)` answers "1234" —
          # printf rounds half to even, so half the amounts in a report would round down
          # and half up with nothing to say which. `Float#round` is half-up, which is what
          # a reader checking a total by hand expects.
          text = format("%.#{places}f", number.round(places))
          whole, fraction = text.split('.')
          grouped = whole.sub('-', '').gsub(THOUSANDS) { "#{Regexp.last_match(1)}," }
          grouped = "-#{grouped}" if number.negative?
          [symbol, [grouped, fraction].compact.join('.')].compact.join
        end

        # Hours as Redmine writes them, which means READING REDMINE'S OWN SETTING rather
        # than choosing a format here. `timespan_format` is `'decimal'` (3.50) or
        # `'minutes'` (3:30), it is an instance-wide preference somebody already set, and
        # a report that disagrees with every other page in the application is a report
        # that looks wrong even when its number is right.
        #
        # Outside Redmine — the drop specs run against the bare Liquid gem — it falls
        # back to decimal, which is the format that needs no locale.
        def duration(input, format_name = nil)
          hours = Support.number(input)
          return nil if hours.nil?

          case format_name || redmine_timespan_format
          when 'minutes' then format('%d:%02d', hours.to_i, ((hours.abs % 1) * 60).round)
          else format('%.2f', hours)
          end
        end

        # Redmine wiki/textile/markdown -> HTML, through Redmine's own formatter, so the
        # markup a report renders is the markup the issue page renders.
        #
        # WHEN THE FORMATTER IS ABSENT THIS DEGRADES VISIBLY. Not silently: returning the
        # raw text would put unrendered `h1.` and `*bold*` into a document, and returning
        # empty would lose a description. So the text is HTML-escaped and passed through,
        # AND a `Degradation(:wiki_unavailable)` is recorded — the reader of the
        # diagnostics is told the formatting was lost (INV-4).
        def wiki(input)
          text = input.to_s
          return '' if text.empty?
          unless defined?(::Redmine::WikiFormatting)
            degrade(:wiki_unavailable,
                    'Redmine::WikiFormatting is not available in this process, so wiki ' \
                    'markup was rendered as escaped plain text')
            return CGI.escapeHTML(text)
          end

          ::Redmine::WikiFormatting.to_html(::Setting.text_formatting, text).to_s
        end

        # UTC, for a chart axis or an ISO timestamp. A report whose x-axis mixes zones
        # because half its values came from a drop and half from a tag is a report with
        # an invisible off-by-one hour in it.
        def utc(input)
          return input if input.nil?
          return input.utc if input.respond_to?(:utc)
          return input.in_time_zone('UTC') if input.respond_to?(:in_time_zone)

          input
        end

        private

        def redmine_timespan_format
          return 'decimal' unless defined?(::Setting) && ::Setting.respond_to?(:timespan_format)

          ::Setting.timespan_format.to_s
        end

        def degrade(code, detail)
          context = Support.render_context(@context)
          context&.diagnostics&.degrade(code, detail: detail)
        end
      end
    end
  end
end
