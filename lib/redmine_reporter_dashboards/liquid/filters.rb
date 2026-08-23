# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # The owned filter set (`technical-spec.md` §3.6), and the one rule that makes it
    # safe to have one at all.
    #
    # --- REGISTRATION IS PER-RENDER, NEVER GLOBAL ---
    #
    # This is the whole reason this module exists rather than each file calling
    # `Liquid::Template.register_filter` at the bottom of itself.
    #
    # The vendor gem registers **four filter modules globally at require time** and
    # additionally monkey-patches a private `to_number` into `Liquid::StandardFilters`
    # unconditionally (`patches/liquid_patch.rb:29-31`); the base plugin does the same
    # (`filters.rb:184`). **Never do this.** Other plugins share the process, and a
    # global filter registration means every Liquid template rendered anywhere in this
    # Redmine — by any plugin, now or after an upgrade — silently gains 55 filters it did
    # not ask for, one of which invokes an arbitrary named method on an arbitrary object.
    # A name collision with another plugin's filter is decided by load order.
    #
    # So `MODULES` is a LIST and `TemplateRenderer` passes it to `Context#add_filters`
    # per render. `script/gates/single_parse.sh` already fails on a global
    # `register_filter` anywhere in this repository, which is what keeps this a property
    # of the code rather than of somebody's memory.
    #
    # --- THE INVENTORY IS A CONSTANT SO IT CAN BE ASSERTED ---
    #
    # `OWNED`, `INHERITED`, `REMOVED` and `DEFERRED` below are the four answers §3.6
    # gives about any filter, in executable form. `spec_liquid/filters_spec.rb` checks
    # that every name in `OWNED` is registered and that no name in `REMOVED` is —
    # because a security removal that nobody asserts is a security removal somebody
    # re-adds as a convenience, and the reason would not be in the diff.
    module Filters
      # In registration order, which is also override order: a later module wins. The
      # only overlap with `Liquid::StandardFilters` is `sum`, and `Aggregates` explains
      # why it is deliberate.
      def self.modules
        [Output, Aggregates, Formatting, Colors, Grouping, CustomFields].freeze
      end

      # What a template can call that this plugin implements. Grouped the way §3.6 groups
      # them so the two can be read side by side.
      OWNED = {
        'json' => 'FR-19. JSON plus script-context escaping; the mandatory one',
        'js' => 'FR-19. The scalar form, for a value inside a JS string literal',
        'avg' => 'mean over a property, non-numbers dropped rather than counted as zero',
        'median' => 'the middle value — what an age or a duration actually wants',
        'min' => 'smallest numeric value of a property',
        'max' => 'largest numeric value of a property',
        'sum' => "OQ-C: Liquid 5 has it and Liquid 4 does not, so it is owned for " \
                 "cross-major parity and reproduces Liquid 5's semantics exactly",
        'currency' => 'a number with thousands separators and a caller-supplied symbol',
        'duration' => "hours in Redmine's own `timespan_format`",
        'wiki' => "Redmine's own wiki/textile/markdown formatter; degrades visibly",
        'utc' => 'a time in UTC, so one chart axis cannot mix zones',
        'hex_color' => 'normalise `abc` / `#AABBCC` to `#aabbcc`; nil for anything else',
        'contrasting_text_color' => 'black or white by WCAG relative luminance',
        'darken' => 'toward black by a percentage of the remaining distance',
        'lighten' => 'toward white, likewise',
        'group_by' => 'buckets by a property, first-appearance order, nil named `(none)`',
        'group_by_custom_field' => 'the same, keyed on a custom field',
        'where_custom_field' => "Liquid's `where` reads a property; a custom field is a lookup",
        'custom_field' => 'one custom field by name',
        'custom_field_by_id' => 'one custom field by id — survives a rename',
        'custom_fields' => 'every field the actor may see, with ids and names'
      }.freeze

      # Provided by `Liquid::StandardFilters` on BOTH 4.0.4 and 5.13.0, measured, and
      # already working on the owned drops — so reimplementing them would be two
      # behaviours to keep in step for nothing. `spec_liquid/filters_spec.rb` asserts each
      # still works through a drop, so "inherited" is tested rather than assumed.
      #
      # `replace_all` is the interesting entry: §3.6 says the removed `regex_replace` is
      # "replaced by literal `replace_all`/`replace_first`", and Liquid's own `replace`
      # IS the replace-all. Adding an alias would be a second spelling of a filter that
      # already exists, so the removal's replacement is a documentation change and not
      # code.
      INHERITED = {
        'where' => 'identical on both majors; resolves through `Drop#[]` already',
        'sort_natural' => 'identical on both majors',
        'replace' => "§3.6's `replace_all` — Liquid's `replace` already replaces all",
        'replace_first' => 'Liquid provides it',
        'map' => 'Liquid provides it, and it reads through `Drop#[]`',
        'size' => 'Liquid provides it',
        'join' => 'Liquid provides it',
        'sort' => 'Liquid provides it',
        'uniq' => 'Liquid provides it',
        'compact' => 'Liquid provides it',
        'date' => 'Liquid provides it',
        'default' => 'Liquid provides it'
      }.freeze

      # REMOVED, each with the security reason §3.6 states. Asserted absent by spec: a
      # removal nobody checks is a removal somebody re-adds as a convenience, and the
      # reason would not be in the diff.
      REMOVED = {
        'call_method' => 'invokes an arbitrary named method on an arbitrary object from ' \
                         'inside a template — the sharpest single instance of INV-9. ' \
                         'Removal is a security requirement, not scope',
        'regex_replace' => 'a template-supplied regular expression is a ReDoS primitive ' \
                           'against a renderer with a wall-clock budget. Use `replace`',
        'regex_replace_once' => 'as `regex_replace`: a template-supplied regexp is a ReDoS ' \
                                'primitive. Use `replace_first`',
        'md5' => 'exists to mint the unexpiring capability token FR-51 replaces',
        'file_url' => 'resolves to the anonymous unexpiring-token attachment URL ' \
                      '(`filters.rb:151-153`) — a permanent unauthenticated link to a ' \
                      "file whose issue may be private. Replaced by `| inline`",
        'jsonify' => "the gem's spelling; it escapes correctly but is gem-coupled. `json`",
        'random' => 'non-deterministic output defeats golden testing outright and has no ' \
                    'place in a document that may be an audit record',
        'shuffle' => 'as `random`: non-deterministic output has no place in an audit record',
        'push' => 'mutates a shared object mid-render — a correctness hazard, not a filter',
        'pop' => 'as `push`: mutates a shared object mid-render',
        'shift' => 'as `push`: mutates a shared object mid-render',
        'unshift' => 'as `push`: mutates a shared object mid-render',
        'ceil' => 'Liquid-core duplicate',
        'floor' => 'Liquid-core duplicate',
        'round' => 'Liquid-core duplicate',
        'modulo' => 'Liquid-core duplicate',
        'dasherize' => 'cosmetic string munging; CSS and a template can do it',
        'underscore' => 'cosmetic string munging; CSS and a template can do it',
        'ljust' => 'cosmetic padding; alignment belongs in the stylesheet',
        'rjust' => 'cosmetic padding; alignment belongs in the stylesheet',
        'multi_line' => "cosmetic; Liquid's `newline_to_br` covers the real case",
        'encode' => 'cosmetic; `url_encode` and `json` cover the real cases',
        'tagged_with' => 'reaches into another RedmineUP paid plugin',
        'attachment' => 'attachment plumbing, superseded by the batched accessors',
        'container' => "the gem's internal helper for an object this plugin does not have",
        'container_currency' => "the gem's internal helper",
        'args_to_options' => "the gem's internal helper",
        'as_liquid' => "the gem's internal helper",
        'item_property' => "the gem's internal helper",
        'groupable?' => "the gem's internal helper",
        'inline_options' => "the gem's internal helper",
        'parse_comparison' => "the gem's internal helper",
        'parse_condition' => "the gem's internal helper",
        'parse_binary_comparison' => "the gem's internal helper",
        'parse_inline_attachments' => "the gem's internal helper",
        'sort_input' => "the gem's internal helper",
        'convert_to_brightness_value' => "the gem's internal helper",
        'textile' => '`wiki` goes through Redmine\'s configured formatter instead',
        'textilize' => "as `textile`: `wiki` goes through Redmine's configured formatter",
        'plus_days' => "Liquid's `date` plus arithmetic covers it",
        'date_range' => 'a range is two dates; the aggregator owns period windows',
        'concat' => 'Liquid provides it',
        'first' => 'Liquid provides it',
        'where_exp' => 'evaluates a template-supplied expression — INV-9',
        'time' => "Liquid's `date`"
      }.freeze

      # The subset of `REMOVED` that Liquid itself does NOT provide — so a template using
      # one is an error the linter can state, rather than a name that quietly falls
      # through to a core filter.
      #
      # THIS LIST EXISTS BECAUSE `REMOVED` IS NOT SAFE TO LINT ON DIRECTLY. Six of its
      # entries (`ceil floor round modulo concat first`) were removed as *duplicates* —
      # Liquid provides them, so `{{ x | round }}` is correct and flagging it would be
      # the worst kind of false positive: a linter telling an author to stop using a
      # documented Liquid filter. `spec_liquid/filters_spec.rb` asserts this list does
      # not intersect `Liquid::StandardFilters` on EITHER major, which is what stops a
      # future entry from reintroducing that mistake.
      LINTABLE_REMOVED = %w[
        call_method regex_replace regex_replace_once md5 file_url jsonify
        random shuffle push pop shift unshift tagged_with where_exp
        textile textilize dasherize underscore ljust rjust multi_line encode
        plus_days date_range container container_currency args_to_options as_liquid
        item_property inline_options sort_input convert_to_brightness_value attachment
        parse_comparison parse_condition parse_binary_comparison
        parse_inline_attachments time
      ].freeze

      # DEFERRED, with the task that owns it. §3.6 lists `| inline` among the filters to
      # reimplement and it is not here, deliberately.
      #
      # `| inline` embeds asset bytes in the document. WHICH mechanism it may use —
      # `data:` URI, request upload, or refuse — is `asset_policy`, and **T-33** builds
      # it: three models, one policy, `:bundled` by default, and an explicit requirement
      # that "an author must not be able to widen egress by editing a document".
      #
      # Implementing it here would mean a second embedding path that does not consult
      # that policy, which is precisely the shape T-33's acceptance list forbids — and it
      # would be rewritten by T-33 anyway. Nothing loses a capability by waiting: the
      # owned render path is not wired up yet, and the `file_url` it replaces was never
      # registered by this plugin in the first place.
      DEFERRED = {
        'inline' => 'T-33 owns `asset_policy`; a second embedding path would bypass it'
      }.freeze

      # Every filter name a template can call inside this plugin's renders — owned plus
      # whatever Liquid brings. Used by the linter to tell "unknown filter" from
      # "removed on purpose", so an author who writes `| md5` is told WHY rather than
      # being told it does not exist.
      def self.owned_names
        OWNED.keys
      end

      def self.registered_names
        modules.flat_map { |mod| mod.public_instance_methods(false).map(&:to_s) }.sort
      end
    end
  end
end

require_relative 'filters/escaping'
require_relative 'filters/support'
require_relative 'filters/output'
require_relative 'filters/aggregates'
require_relative 'filters/formatting'
require_relative 'filters/colors'
require_relative 'filters/grouping'
require_relative 'filters/custom_fields'
