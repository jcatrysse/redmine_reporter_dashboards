# frozen_string_literal: true

require 'logger'
require_relative 'spec_helper'

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

# Stand-in for ActionController::Parameters: the sanitizer reaches for
# #to_unsafe_h, which is what tells nested Parameters apart from a plain Hash.
# Deliberately NOT a Hash, like the real class.
class ParametersStub
  def initialize(hash)
    @hash = hash
  end

  def to_unsafe_h
    @hash
  end
end

require_relative '../lib/redmine_reporter_dashboards/block_settings'

RSpec.describe RedmineReporterDashboards::BlockSettings do
  def sanitize(hash, block: 'news')
    described_class.sanitize(ParametersStub.new(hash), block: block)
  end

  before { allow(Rails.logger).to receive(:warn) }

  describe 'the known integer settings' do
    it 'stores them as integers' do
      expect(sanitize({ 'limit' => '25', 'query_id' => '7', 'report_template_id' => '3',
                      'days' => '30' }))
        .to eq('limit' => 25, 'query_id' => 7, 'report_template_id' => 3, 'days' => 30)
    end

    # This is how the selects say "nothing chosen"; dropping the key instead would
    # leave the previous value in place, so clearing a widget's query would not work.
    it 'keeps an empty value as an explicit nil' do
      expect(sanitize({ 'query_id' => '' })).to eq('query_id' => nil)
    end

    it 'drops a value that is not a number' do
      expect(sanitize({ 'limit' => '10; DROP TABLE issues' })).to eq({})
      expect(sanitize({ 'query_id' => 'me' })).to eq({})
      expect(sanitize({ 'days' => '-5' })).to eq({})
    end

    it 'drops a number too long for any reader to want' do
      expect(sanitize({ 'limit' => '9' * 40 })).to eq({})
    end

    it 'says which setting it ignored and why' do
      expect(Rails.logger).to receive(:warn).with(/ignoring setting "limit" for widget "news".*number/)
      sanitize({ 'limit' => 'lots' })
    end
  end

  describe 'columns' do
    it 'keeps a list of column names' do
      expect(sanitize({ 'columns' => %w[tracker status cf_12 project.name] }))
        .to eq('columns' => %w[tracker status cf_12 project.name])
    end

    it 'drops entries that are not column names and keeps the rest' do
      expect(sanitize({ 'columns' => ['status', '<script>', 'tracker'] }))
        .to eq('columns' => %w[status tracker])
    end

    it 'drops the blank entry the columns picker posts for an empty selection' do
      expect(sanitize({ 'columns' => [''] })).to eq('columns' => [])
    end

    it 'caps the list' do
      result = sanitize({ 'columns' => Array.new(200) { |i| "cf_#{i}" } })
      expect(result['columns'].length).to eq(described_class::MAX_LIST_ITEMS)
    end

    it 'refuses a nested structure inside the list' do
      expect(sanitize({ 'columns' => [{ 'a' => 'b' }] })).to eq('columns' => [])
    end
  end

  describe 'group_by' do
    it 'keeps a column name' do
      expect(sanitize({ 'group_by' => 'assigned_to' })).to eq('group_by' => 'assigned_to')
    end

    it 'keeps an empty selection as nil, so grouping can be turned off' do
      expect(sanitize({ 'group_by' => '' })).to eq('group_by' => nil)
    end

    it 'drops anything that is not a column name' do
      expect(sanitize({ 'group_by' => 'status; --' })).to eq({})
    end
  end

  # Widgets contributed by other plugins are discovered by globbing their view
  # directories, so their setting names cannot be known here. They are accepted, but
  # only as bounded scalars or flat lists of them.
  describe 'a setting this module does not know' do
    it 'keeps a scalar' do
      expect(sanitize({ 'sort' => 'priority:desc,updated_on' }))
        .to eq('sort' => 'priority:desc,updated_on')
      expect(sanitize({ 'show_totals' => true})).to eq('show_totals' => true)
      expect(sanitize({ 'threshold' => 4})).to eq('threshold' => 4)
    end

    it 'keeps a flat list' do
      expect(sanitize({ 'tags' => %w[a b] })).to eq('tags' => %w[a b])
    end

    it 'truncates an over-long value rather than dropping it' do
      result = sanitize({ 'note' => 'x' * 5_000 })
      expect(result['note'].length).to eq(described_class::MAX_VALUE_LENGTH)
    end

    it 'refuses a nested hash' do
      expect(sanitize({ 'nested' => { 'a' => { 'b' => 'c' } } })).to eq({})
    end

    it 'refuses a nested list' do
      expect(sanitize({ 'nested' => [%w[a b], %w[c d]] })).to eq({})
    end

    it 'caps a list' do
      expect(sanitize({ 'tags' => Array.new(500, 'x') })['tags'].length)
        .to eq(described_class::MAX_LIST_ITEMS)
    end
  end

  describe 'setting names' do
    it 'refuses a name that is not a plain identifier' do
      expect(sanitize({ 'DROP TABLE' => '1', 'a-b' => '1', 'Limit' => '1' })).to eq({})
    end

    it 'refuses an over-long name' do
      expect(sanitize({('k' * 100) => '1' })).to eq({})
    end

    it 'caps how many settings one widget can hold' do
      many = (1..100).each_with_object({}) { |i, h| h["key_#{i}"] = 'v' }
      expect(sanitize(many).size).to eq(described_class::MAX_KEYS)
    end
  end

  describe 'the input itself' do
    it 'returns an empty hash for anything that is not a settings hash' do
      expect(described_class.sanitize(nil, block: 'news')).to eq({})
      expect(described_class.sanitize('news', block: 'news')).to eq({})
      expect(described_class.sanitize([], block: 'news')).to eq({})
    end

    it 'accepts a plain Hash as well as Parameters' do
      expect(described_class.sanitize({ 'limit' => '5' }, block: 'news')).to eq('limit' => 5)
    end

    it 'answers with String keys, which the model symbolizes on merge' do
      expect(sanitize({ 'limit' => '5' }).keys).to eq(['limit'])
    end
  end
end
