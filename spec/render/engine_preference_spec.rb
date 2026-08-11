# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/render/engine_preference'

# FR-50 — the install-wide engine choice, as a value object.
#
# Everything here is about the COERCION and the OFFERED SET, because those are the two
# things a settings form can get wrong in a way nothing else notices: Redmine performs no
# validation on plugin settings, so a value that is not an engine id is stored happily and
# the only place it can be refused is on the way out (FR-15).
#
# The precedence — hint, then this, then the declared default — is asserted in
# `spec/reporting/report_run_spec.rb`, where the decision is actually made.
module EnginePreferenceSpecSupport
  # A CATALOGUE STUB, not a Struct pretending to be one: `EnginePreference` asks a catalogue
  # for `default_engine_id` and `[]`, and an entry for eight fields. Hand-rolled so an
  # example can build an engine the shipped `config/capabilities.yml` does not have —
  # `pending` verification and `deprecated` both need one, and the shipped file has neither
  # any more (all three engines were promoted to `corpus` on 2026-08-11).
  Entry = Struct.new(:id, :label, :needs_service, :renders_offline, :install, :trade,
                     :verification, :deprecated, :capabilities, keyword_init: true) do
    def deprecated?
      deprecated ? true : false
    end
  end

  class Catalogue
    def initialize(entries, default_id: nil)
      @entries = entries
      @default_id = default_id
    end

    attr_reader :default_id

    def [](id)
      @entries.find { |entry| entry.id == id.to_s }
    end

    def default_engine_id
      @default_id
    end
  end

  def self.entry(id, **overrides)
    Entry.new({ id: id, label: "#{id} label", needs_service: false, renders_offline: true,
                install: "install #{id}", trade: "trade #{id}", verification: 'corpus',
                deprecated: false,
                capabilities: %i[javascript timeout] }.merge(overrides))
  end

  def self.catalogue(default_id: 'alpha')
    Catalogue.new([entry('alpha'), entry('beta', needs_service: true, renders_offline: false),
                   entry('gamma', verification: 'pending', deprecated: true)],
                  default_id: default_id)
  end

  # A logger that records rather than one that swallows: FR-15 says an out-of-range value is
  # "dropped with a log line", so the LINE is part of the requirement.
  class Recorder
    attr_reader :lines

    def initialize
      @lines = []
    end

    def warn(line)
      @lines << line
    end
  end
end

RSpec.describe RedmineReporterDashboards::Render::EnginePreference do
  # NO `Support = EnginePreferenceSpecSupport` SHORTHAND. A constant assigned inside an
  # `RSpec.describe` block is assigned at the FILE's top level — the block is a closure whose
  # lexical scope is the file — so it would define `Object::Support` for the whole process,
  # and the collision passes in isolation and fails only in the randomised full run. That
  # has cost this project two examples once already (HANDOVER §1).
  def support
    EnginePreferenceSpecSupport
  end

  def build(value, ids: %w[alpha beta gamma], catalogue: :default, logger: nil)
    catalogue = support.catalogue if catalogue == :default
    described_class.from_settings({ 'render_engine' => value }, logger: logger,
                                                               catalogue: catalogue,
                                                               registered_ids: ids)
  end

  describe 'the coercion table (FR-15)' do
    it 'treats an absent key as no preference, and does NOT call it a dropped value' do
      preference = described_class.from_settings({}, catalogue: support.catalogue,
                                                    registered_ids: %w[alpha])

      expect(preference.selected_id).to be_nil
      expect(preference.dropped).to be_empty
      expect(preference).not_to be_dropped
    end

    ['', '   ', "\t\n"].each do |blank|
      it "treats #{blank.inspect} as no preference rather than as a bad value" do
        preference = build(blank)

        expect(preference.selected_id).to be_nil
        expect(preference.dropped).to be_empty
      end
    end

    it 'accepts a registered id' do
      expect(build('beta').selected_id).to eq('beta')
    end

    it 'accepts a Symbol, because a caller inside this plugin will pass one' do
      expect(build(:alpha).selected_id).to eq('alpha')
    end

    it 'strips surrounding whitespace, which is what a copied value carries' do
      expect(build('  alpha  ').selected_id).to eq('alpha')
    end

    # THE IDS ARRIVE UNSORTED HERE ON PURPOSE. The refusal names the engines that exist, and
    # that sentence goes into a log line and onto the settings page — so its order is a
    # property, not an accident of however the registry happened to hand them over. The
    # mutation run is why the argument is spelled: with the class-level sort deleted this
    # example was the only thing that could notice, and it could not, because it passed an
    # already-sorted list.
    it 'DROPS an id no engine is registered under, and names the ones that exist, in order' do
      logger = support::Recorder.new
      preference = build('chromium_cpd', ids: %w[gamma alpha beta], logger: logger)

      expect(preference.selected_id).to be_nil
      expect(preference.dropped.length).to eq(1)
      expect(preference.dropped.first[:reason]).to include('alpha, beta, gamma')
      expect(logger.lines.join).to include('render setting render_engine="chromium_cpd" dropped')
    end

    # THE BOUND FR-15 ASKS FOR, and the reason it is on the VALUE rather than on the id: a
    # POST can put 40 KB here, and it would land in a log line and on the settings page.
    it 'DROPS an over-long value and truncates it in what it records' do
      preference = build('a' * 500)

      expect(preference.selected_id).to be_nil
      expect(preference.dropped.first[:value].length)
        .to eq(described_class::MAX_LENGTH + 1) # + the ellipsis
      expect(preference.dropped.first[:reason]).to include('longer than')
    end

    # A CRAFTED POST, which is the only way these arrive: Redmine's settings controller
    # hands `params[:settings]` straight to `Setting.plugin_<id>=`.
    [['an Array', %w[alpha beta]], ['a Hash', { 'id' => 'alpha' }], ['an Integer', 7]].each do |label, value|
      it "refuses #{label} by type rather than by stringifying it" do
        preference = build(value)

        expect(preference.selected_id).to be_nil
        expect(preference.dropped.first[:reason]).to include('single value')
        # NOT the stringified value: `["alpha", "beta"].to_s` in a log line reads as
        # though it nearly worked.
        expect(preference.dropped.first[:value]).to eq(value.class.name)
      end
    end

    # A `needs_service` ENGINE IS SELECTABLE, and this is the whole point of FR-50. T-34's
    # rule is that nobody may have one chosen FOR them by auto-detection; choosing it
    # deliberately is what this setting IS.
    it 'accepts an engine that needs a service, because choosing it is the decision' do
      preference = build('beta')

      expect(preference.selected_id).to eq('beta')
      expect(preference.dropped).to be_empty
      expect(preference).to be_needs_service
    end
  end

  describe 'what it offers' do
    it 'offers every REGISTERED engine, in a stable order' do
      expect(build(nil, ids: %w[gamma alpha beta]).offers.map(&:id)).to eq(%w[alpha beta gamma])
    end

    # THE SAME CLAIM, MADE OF THE CONSTRUCTOR, and the mutation run is why it is here:
    # `from_settings` normalises the id list before `new` does, so mutating the instance-level
    # sort SURVIVED the example above — it was measuring the class method's sort twice.
    # `new` is public and ordering is its guarantee too (CLAUDE.md §6: a collection assertion
    # has an explicit order, and a `<select>` whose options move between requests is a
    # different page each time).
    it 'orders them in the CONSTRUCTOR too, however they arrive there' do
      preference = described_class.new(registered_ids: %w[gamma alpha beta],
                                      catalogue: support.catalogue)

      expect(preference.offers.map(&:id)).to eq(%w[alpha beta gamma])
    end

    it 'never offers an engine that is only in the catalogue' do
      preference = build(nil, ids: %w[alpha])

      expect(preference.offers.map(&:id)).to eq(%w[alpha])
    end

    # An adapter another plugin registered. Being unknown to the catalogue is not evidence
    # of anything — `EngineCatalogue#auto_selectable?` argues the same from the other side —
    # so it is offered, with no facts invented about it.
    it 'offers a registered engine the catalogue has never heard of, and claims nothing' do
      offer = build(nil, ids: %w[alpha zeta]).offers.find { |o| o.id == 'zeta' }

      expect(offer.known).to be(false)
      expect(offer.label).to be_nil
      expect(offer.missing_capabilities).to be_empty
      expect(build('zeta', ids: %w[alpha zeta]).selected_id).to eq('zeta')
    end

    it 'carries the four facts §5.2 clause 4 asks for, from the catalogue' do
      offer = build(nil).offers.find { |o| o.id == 'beta' }

      expect(offer.needs_service).to be(true)
      expect(offer.renders_offline).to be(false)
      expect(offer.install).to eq('install beta')
      expect(offer.label).to eq('beta label')
    end

    # COMPUTED, so a capability added to the closed vocabulary appears without anybody
    # editing a view, and an engine cannot look more capable than it is by omission.
    it 'computes what an engine CANNOT do from the closed vocabulary' do
      offer = build(nil).offers.find { |o| o.id == 'alpha' }
      all = RedmineReporterDashboards::Render::Capabilities::ALL

      expect(offer.missing_capabilities).to eq(all - %i[javascript timeout])
      expect(offer.missing_capabilities).not_to include(:javascript)
    end

    it 'reports deprecation and an unverified engine, which is what INV-7 is about' do
      offer = build(nil).offers.find { |o| o.id == 'gamma' }

      expect(offer.deprecated).to be(true)
      expect(offer.verification).to eq('pending')
    end
  end

  describe 'the effective engine' do
    it 'is the selection when there is one' do
      expect(build('beta').effective_id).to eq('beta')
    end

    it 'is the declared default when there is not' do
      expect(build(nil).effective_id).to eq('alpha')
      expect(build(nil).default_id).to eq('alpha')
    end

    it 'is the declared default when the selection was refused' do
      expect(build('nope').effective_id).to eq('alpha')
    end

    it 'is nil when nothing is declared, so the caller can look for one itself' do
      preference = build(nil, catalogue: support.catalogue(default_id: nil))

      expect(preference.effective_id).to be_nil
      expect(preference).not_to be_needs_service
    end

    it 'answers needs_service? about the DEFAULT when nothing was selected' do
      preference = build(nil, catalogue: support.catalogue(default_id: 'beta'))

      expect(preference).to be_needs_service
    end
  end

  # A CATALOGUE THAT WILL NOT LOAD MUST NOT TAKE THE RENDER PATH DOWN — `ReportRun` asks
  # this object for the selected id on every render, and the settings page builds one on
  # every view. `catalogue: nil` is a DIFFERENT state from "you did not say", which is why
  # the keyword's default is the `:load` sentinel (§Findings E-27's `FROM_ENV` lesson).
  describe 'when config/capabilities.yml cannot be read' do
    it 'still honours the operator\'s explicit choice, and says the advice is gone' do
      preference = build('beta', catalogue: nil)

      expect(preference.selected_id).to eq('beta')
      expect(preference).not_to be_catalogue_readable
      expect(preference.default_id).to be_nil
      expect(preference.offers.map(&:known)).to all(be(false))
    end

    it 'logs it rather than raising, when the real file is the one that will not parse' do
      logger = support::Recorder.new
      allow(RedmineReporterDashboards::Render::EngineCatalogue)
        .to receive(:load).and_raise(RedmineReporterDashboards::Render::EngineCatalogue::InvalidCatalogue,
                                     'broken')

      preference = described_class.from_settings({ 'render_engine' => 'alpha' },
                                                logger: logger, registered_ids: %w[alpha])

      expect(preference.selected_id).to eq('alpha')
      expect(logger.lines.join).to include('capabilities.yml could not be read')
    end
  end

  # THE REAL FILE, not a stub — the one assertion that the shipped catalogue and the
  # shipped registry agree well enough for this screen to be honest.
  describe 'against the shipped catalogue' do
    it 'declares the same default the catalogue does' do
      preference = described_class.from_settings({}, registered_ids: %w[chromium_cdp gotenberg])

      expect(preference.default_id).to eq('chromium_cdp')
      expect(preference.offer_for('gotenberg').needs_service).to be(true)
      expect(preference.offer_for('chromium_cdp').needs_service).to be(false)
    end
  end
end
