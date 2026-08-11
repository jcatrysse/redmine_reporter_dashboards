# frozen_string_literal: true

require_relative 'capabilities'
require_relative 'engine_catalogue'
require_relative 'registry'

module RedmineReporterDashboards
  module Render
    # FR-50 / technical-spec.md §5.2 clause 4 — WHICH ENGINE THIS INSTALLATION RENDERS
    # WITH, and the one line per engine an operator needs in order to choose.
    #
    # --- WHY A SETTING EXISTS AT ALL (§Findings E-27 row 2) ---
    #
    # Until now the only way to reach `:gotenberg` was a template's `engine_hint`, and
    # there is no form field for that either — the documented route was to EXPORT a
    # template, add a line and import it again. An install-wide choice is the missing half:
    # the engine is a property of the DEPLOYMENT (a container somebody runs, a package
    # somebody installed), and a per-document field is the wrong shape for it.
    #
    # --- THE PRECEDENCE, AND WHY THE HINT STILL WINS ---
    #
    #   1. the template's `engine_hint`, when it names a REGISTERED engine
    #   2. this setting, when it names a REGISTERED engine
    #   3. the `default: true` engine declared in `config/capabilities.yml`
    #   4. any registered engine the catalogue does not say `needs_service`
    #
    # A hint outranks the setting because a hint is a statement about a DOCUMENT — "this
    # report needs a modern JavaScript engine", "this one must render on the compatibility
    # engine" — and a setting is a statement about the installation. The narrower claim
    # wins, which is also what keeps a template portable: it renders the same way wherever
    # it is imported, and an install-wide preference cannot silently change what an
    # existing document looks like.
    #
    # --- WHAT THIS CLASS MAY NOT DO ---
    #
    # It reads a Hash. It does not read `Setting`, it does not know Redmine exists, and it
    # is not allowed to (mechanism E5, enforced for `render/**` by `layer_purity.sh`). The
    # one Redmine read lives in `RedmineReporterDashboards.render_engine_preference`,
    # exactly where `Assets::Policy`'s does.
    #
    # --- FR-15: TYPED, BOUNDED, AND DROPPED RATHER THAN STORED ---
    #
    # Redmine performs no validation on plugin settings, and `Setting.plugin_<id>=` stores
    # whatever Hash a POST carries. So every value is coerced HERE, on the way out:
    #
    #   absent / '' / whitespace  -> no preference. The declared default renders. NOT a
    #                               dropped value: "no choice" is the documented state, and
    #                               warning about it would train an operator to ignore
    #                               warnings.
    #   a registered engine id    -> that engine, `needs_service` or not. Choosing one IS
    #                               the decision T-34's rule refuses to make FOR an
    #                               operator; it was never a rule against choosing.
    #   anything else             -> DROPPED, with a reason naming the ids that exist, and
    #                               one log line. Never rendered with.
    #
    # THE OFFERED SET COMES OFF THE REGISTRY, NEVER OFF INPUT. `Registry` is a closed map
    # written in Ruby (FR-55: no `constantize`), so an id that is not in it cannot become an
    # adapter whatever a form posts — and an id that IS in it is offered even when
    # `config/capabilities.yml` has never heard of it, because another plugin may register
    # an adapter and being unknown to the catalogue is not evidence of anything.
    # `EngineCatalogue#auto_selectable?` argues the same thing from the other side.
    class EnginePreference
      SETTING_KEY = 'render_engine'

      # "No choice", spelled the way a `<select>` posts it. `init.rb` declares this as the
      # default, so a fresh install and an install that deliberately chose the default are
      # ONE state rather than two.
      NO_PREFERENCE = ''

      # A bound on the VALUE, not a claim about ids. Nothing here is protected by the
      # length — the id still has to be in the registry — but a 40 KB paste must not reach
      # the log or the page, and FR-15 asks for bounded.
      MAX_LENGTH = 64

      # Reported as the ASSET MODEL rather than as three absences — see `#offer`.
      ASSET_CAPABILITIES = %i[asset_inline asset_upload asset_http].freeze

      # What an operator needs in order to choose, per engine, GENERATED — §5.2 clause 4's
      # own list: "what it needs installed, whether it needs a service, whether it can
      # render offline, and which capabilities it lacks".
      #
      # `known` is false for an engine the registry has and the catalogue does not. The
      # view then offers the id and says nothing about it, which is the honest rendering:
      # inventing facts about somebody else's adapter would be worse than a blank line.
      Offer = Struct.new(:id, :known, :label, :needs_service, :renders_offline, :install,
                         :trade, :verification, :deprecated, :asset_models,
                         :missing_capabilities, keyword_init: true)

      attr_reader :selected_id, :default_id, :offers, :dropped

      class << self
        # The operator-facing constructor: coerces, records, logs, and never raises.
        #
        # `catalogue:` takes the sentinel `:load` rather than defaulting to
        # `EngineCatalogue.load`, so a test can pass `nil` to mean "the catalogue is
        # unreadable" and have that be a DIFFERENT state from "you did not say". That
        # distinction is §Findings E-27's `FROM_ENV` lesson applied one class over: an
        # argument whose absence and whose explicit nil mean the same thing cannot be
        # tested for one of them.
        def from_settings(settings, logger: nil, catalogue: :load, registered_ids: nil)
          source = stringify(settings)
          catalogue = safe_catalogue(logger) if catalogue == :load
          ids = normalise_ids(registered_ids.nil? ? Registry.ids : registered_ids)
          dropped = []

          selected = coerce_id(source[SETTING_KEY], ids, dropped)
          dropped.each do |entry|
            logger&.warn(
              "[reporter_dashboards] render setting #{entry[:key]}=#{entry[:value].inspect} " \
              "dropped: #{entry[:reason]}"
            )
          end

          new(selected_id: selected, registered_ids: ids, catalogue: catalogue,
              dropped: dropped)
        end

        private

        # A CATALOGUE THAT WILL NOT LOAD MUST NOT TAKE THE RENDER PATH DOWN, and this
        # object is on it — `ReportRun` asks for the selected id on every render.
        # `Reporting::ReportRun#auto_detected_engine_id` makes the same choice for the same
        # reason: degrade to "no advice", loudly, rather than 500 every report and the
        # settings page with it.
        def safe_catalogue(logger)
          EngineCatalogue.load
        rescue StandardError => e
          logger&.warn('[reporter_dashboards] config/capabilities.yml could not be read ' \
                       "(#{e.class}); the engine list will carry no advice and no declared " \
                       'default')
          nil
        end

        def stringify(settings)
          return {} if settings.nil?
          return {} unless settings.respond_to?(:each_pair) || settings.respond_to?(:each)

          settings.to_h { |key, value| [key.to_s, value] }
        rescue StandardError
          {}
        end

        def normalise_ids(ids)
          Array(ids).map(&:to_s).reject(&:empty?).uniq.sort
        end

        def coerce_id(raw, ids, dropped)
          return nil if raw.nil?

          # A crafted POST can put an Array or a Hash here. Refused by TYPE and recorded,
          # rather than `to_s`-ed into a string that then fails the registry check for the
          # wrong reason — the operator needs to know their value was not an engine id at
          # all, and `["a", "b"].to_s` in a log line reads as if it nearly worked.
          unless raw.is_a?(String) || raw.is_a?(Symbol)
            dropped << { key: SETTING_KEY, value: raw.class.name,
                         reason: 'an engine id has to be a single value, and this is not one' }
            return nil
          end

          value = raw.to_s.strip
          return nil if value.empty?

          if value.length > MAX_LENGTH
            dropped << { key: SETTING_KEY, value: "#{value[0, MAX_LENGTH]}…",
                         reason: "longer than #{MAX_LENGTH} characters, so it is not an " \
                                 'engine id' }
            return nil
          end

          return value if ids.include?(value)

          dropped << { key: SETTING_KEY, value: value,
                       reason: 'no render engine is registered under that name. Known: ' \
                               "#{ids.join(', ')}" }
          nil
        end
      end

      def initialize(selected_id: nil, registered_ids: [], catalogue: nil, dropped: [])
        @selected_id = selected_id&.to_s&.freeze
        @dropped = Array(dropped).freeze
        @default_id = catalogue&.default_engine_id&.to_s&.freeze
        @catalogue_readable = !catalogue.nil?
        @offers = build_offers(normalise(registered_ids), catalogue)
        freeze
      end

      # The engine this installation renders with, absent a template hint. Nil when neither
      # the setting nor a declared default resolves — which `ReportRun` answers by looking
      # for any engine that does not need a service.
      def effective_id
        selected_id || default_id
      end

      # Whether the chosen engine needs a service. The settings page says so out loud: T-34's
      # rule is that nobody may have `:gotenberg` chosen FOR them, and the other half of that
      # rule is that an operator who chooses it deliberately is told what they have taken on,
      # in the place where they took it on.
      def needs_service?
        offer_for(effective_id)&.needs_service ? true : false
      end

      def offer_for(id)
        return nil if id.nil?

        offers.find { |offer| offer.id == id.to_s }
      end

      # True when a value was saved that this object refused to use. The view lists them;
      # without that an operator sees the dropdown showing the default and concludes their
      # choice was stored — the "looks like it worked when it did not" failure the asset
      # half of the same page already guards against.
      def dropped?
        !dropped.empty?
      end

      def catalogue_readable?
        @catalogue_readable
      end

      private

      def normalise(ids)
        Array(ids).map(&:to_s).reject(&:empty?).uniq.sort
      end

      # SORTED, and that is a determinism decision rather than a cosmetic one: `Registry.ids`
      # is already sorted, a catalogue is sorted by id, and a `<select>` whose option order
      # depends on registration order would move under a test with `config.order = :random`
      # (CLAUDE.md §6).
      def build_offers(ids, catalogue)
        ids.map { |id| offer(id, catalogue && catalogue[id]) }.freeze
      end

      def offer(id, entry)
        if entry.nil?
          return Offer.new(id: id, known: false, asset_models: [].freeze,
                           missing_capabilities: [].freeze).freeze
        end

        Offer.new(
          id: id, known: true, label: entry.label, needs_service: entry.needs_service,
          renders_offline: entry.renders_offline, install: entry.install,
          trade: entry.trade, verification: entry.verification,
          deprecated: entry.deprecated?,
          # THE ASSET MODEL IS ITS OWN ANSWER, NOT AN ABSENCE. A UX review measured what
          # putting it in the "cannot do" list reads as: the reference engine shown lacking
          # `:asset_http` — the capability INV-8 exists to keep it from having — and
          # gotenberg shown unable to do `:asset_inline` one screen away from a README
          # paragraph saying its upload model "changes nothing about how you write a
          # template". So the three `asset_*` capabilities are reported as a MODEL here and
          # excluded from the absence list below.
          asset_models: Array(entry.asset_models).map(&:to_s).freeze,
          # "which capabilities it lacks" — COMPUTED from the closed vocabulary, so a
          # capability added to `Capabilities::ALL` appears here without anybody editing a
          # view, and an engine cannot look more capable than it is by omission.
          missing_capabilities: (Capabilities::ALL - entry.capabilities - ASSET_CAPABILITIES).freeze
        ).freeze
      end
    end
  end
end
