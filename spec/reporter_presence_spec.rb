# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/reporter_presence'

# Boot-time detection of the OPTIONAL redmine_reporter plugin.
#
# The case that matters is the negative one. This plugin used to `raise` in init.rb
# when reporter was absent, which made it uninstallable without a paid third-party
# plugin. Detection has to answer "no" cleanly — and answer it by ASKING, not by
# rescuing a NameError, which is the style that let the vendor-gem coupling hide for
# a release line.
RSpec.describe RedmineReporterDashboards::ReporterPresence do
  # A stand-in registry, so the question can be put in a process where no Redmine
  # exists at all: the standalone case, which is the whole point.
  before(:all) do
    @redmine_was_defined = Object.const_defined?(:Redmine)

    unless @redmine_was_defined
      Object.const_set(:Redmine, Module.new)
      ::Redmine.const_set(:Plugin, Class.new do
        class << self
          attr_accessor :installed_plugins

          def installed?(name)
            Array(installed_plugins).include?(name.to_sym)
          end
        end
      end)
    end
  end

  # Only what this file created is removed, so running inside a booted Redmine (or
  # after another spec defined it) cannot tear down somebody else's constant.
  after(:all) { Object.send(:remove_const, :Redmine) unless @redmine_was_defined }

  before { described_class.reset! }
  after  { described_class.reset! }

  def registry(*names)
    ::Redmine::Plugin.installed_plugins = names
  end

  describe '.present?' do
    it 'is true when the registry lists reporter' do
      registry(:redmine_reporter, :redmine_reporter_dashboards)

      expect(described_class.present?).to be(true)
    end

    it 'is false when the registry lists other plugins but not reporter' do
      registry(:redmine_reporter_dashboards, :redmine_agile)

      expect(described_class.present?).to be(false)
    end

    it 'is false rather than raising when the registry is empty' do
      registry

      expect(described_class.present?).to be(false)
    end

    it 'returns an actual boolean, not whatever the registry happened to hand back' do
      registry
      allow(::Redmine::Plugin).to receive(:installed?).and_return(nil)

      expect(described_class.present?).to be(false)
    end

    it 'is false when there is no plugin registry at all' do
      allow(::Redmine::Plugin).to receive(:respond_to?).with(:installed?).and_return(false)

      expect(described_class.present?).to be(false)
    end
  end

  # The memo is what makes it safe to ask from a render path.
  describe 'memoisation' do
    it 'asks the registry once for a positive answer' do
      expect(::Redmine::Plugin).to receive(:installed?).once.and_return(true)

      expect(Array.new(3) { described_class.present? }).to eq([true, true, true])
    end

    # The bug this guards: `@present ||= detect` would re-ask forever on false.
    it 'asks the registry once for a negative answer too' do
      expect(::Redmine::Plugin).to receive(:installed?).once.and_return(false)

      expect(Array.new(3) { described_class.present? }).to eq([false, false, false])
    end
  end

  describe '.reset!' do
    it 'makes the next ask re-detect, so a development reload sees a new registry' do
      registry
      expect(described_class.present?).to be(false)

      registry(:redmine_reporter)
      expect(described_class.present?).to be(false) # still the memo

      described_class.reset!

      expect(described_class.present?).to be(true)
    end

    it 'is safe to call before anything has been detected' do
      expect { described_class.reset! }.not_to raise_error
    end
  end

  it 'names the plugin it looks for, rather than matching on a substring' do
    registry(:redmine_reporter_dashboards)

    expect(described_class::PLUGIN_ID).to eq(:redmine_reporter)
    expect(described_class.present?).to be(false)
  end
end
