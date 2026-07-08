# frozen_string_literal: true

require 'logger'
require 'active_support'
require 'active_support/time'
require_relative '../spec_helper'

Time.zone ||= 'UTC'

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

require_relative '../../lib/sql_aggregation/query_aggregator'

# Chainable scope stub for version_rollup. Every chain ends in count/sum/minimum/
# maximum; the terminal looks up a canned result by a label derived from the
# conditions/joins applied, so the spec verifies that each metric is built from
# the RIGHT query (open uses where.not(status_id), overdue adds a due filter, cost
# joins custom_values for a given field id, etc.).
class RollupScope
  def initialize(data, flags = {})
    @data  = data
    @flags = flags
  end

  def unscope(*)
    self
  end

  def joins(assoc)
    fork(join: assoc)
  end

  def where(cond = nil, *_)
    return self if cond.nil? # `where.not` style: `.where` then `.not`
    return fork(status_eq: true)   if cond.is_a?(Hash) && cond.key?(:status_id)
    return fork(unassigned: true)  if cond.is_a?(Hash) && cond.key?(:assigned_to_id)
    return fork(est_nil: true)     if cond.is_a?(Hash) && cond.key?(:estimated_hours)
    if cond.is_a?(Hash) && cond[:custom_values].is_a?(Hash)
      return fork(cf_id: cond[:custom_values][:custom_field_id])
    end
    return fork(due: true)         if cond.is_a?(String) && cond.include?('due_date')

    self
  end

  # `where.not(...)`
  def not(cond = nil, *_)
    return fork(excluded: true) if cond.is_a?(Hash) && cond.key?(:status_id)
    return fork(value_ok: true) if cond.is_a?(Hash) && cond[:custom_values].is_a?(Hash)

    self
  end

  def group(_field)
    fork(grouped: true)
  end

  def count
    lookup(:count)
  end

  def sum(_col)
    lookup(:sum)
  end

  def minimum(_col)
    lookup(:start)
  end

  def maximum(_col)
    lookup(:due_max)
  end

  private

  def fork(extra)
    RollupScope.new(@data, @flags.merge(extra))
  end

  def lookup(kind)
    key =
      if @flags[:join] == :time_entries then :spent
      elsif @flags[:cf_id] then :"cost_#{@flags[:cf_id]}"
      elsif kind == :start then :start
      elsif kind == :due_max then :due_max
      elsif kind == :sum && @flags[:excluded] then :done
      elsif kind == :sum then :est
      elsif @flags[:status_eq] then :closed
      elsif @flags[:est_nil] then :noest
      elsif @flags[:excluded] && @flags[:due] then :overdue
      elsif @flags[:excluded] && @flags[:unassigned] then :unassigned
      elsif @flags[:excluded] then :open
      else :total
      end
    @data.fetch(key, {})
  end
end

RSpec.describe SqlAggregation::QueryAggregator do
  describe '.version_rollup' do
    before do
      stub_const('IssueStatus', Class.new do
        def self.where(*)
          self
        end

        def self.pluck(*)
          [3, 4] # closed status ids
        end
      end)
      stub_const('CustomValue', Class.new do
        def self.table_name
          'custom_values'
        end
      end)
    end

    # Two versions (id 1, 2) plus a nil (no target version) bucket.
    let(:data) do
      {
        total:      { 1 => 4, 2 => 2, nil => 1 },
        open:       { 1 => 3, 2 => 2, nil => 1 },
        closed:     { 1 => 1 },
        done:       { 1 => 120, 2 => 40, nil => 0 },
        overdue:    { 1 => 1 },
        unassigned: { 2 => 1 },
        noest:      { 2 => 1 },
        est:        { 1 => 150.0, 2 => 80.0 },
        spent:      { 1 => 95.0, 2 => 120.0 },
        start:      { 1 => Date.new(2026, 1, 1) },
        due_max:    { 1 => Date.new(2026, 12, 31) },
        cost_20:    { 1 => 30_000.0, 2 => 5_000.0 },
        cost_21:    { 1 => 17_000.0, 2 => 7_500.0 }
      }
    end
    let(:scope) { RollupScope.new(data) }

    subject(:rows) { described_class.version_rollup(scope, closed_statuses: ['Closed'], cost_field_ids: [20, 21]) }

    it 'returns one row per version bucket present in totals' do
      expect(rows.map { |r| r['version_id'] }).to match_array([1, 2, nil])
    end

    it 'maps counts from the correctly-conditioned queries' do
      v1 = rows.find { |r| r['version_id'] == 1 }
      expect(v1['total']).to eq(4)
      expect(v1['open']).to eq(3)
      expect(v1['closed']).to eq(1)
      expect(v1['overdue_open']).to eq(1)
      expect(v1['open_done_sum']).to eq(120)
    end

    it 'defaults missing per-version metrics to zero' do
      v2 = rows.find { |r| r['version_id'] == 2 }
      expect(v2['closed']).to eq(0)        # no closed bucket for v2
      expect(v2['overdue_open']).to eq(0)
      expect(v2['unassigned_open']).to eq(1)
      expect(v2['no_estimate']).to eq(1)
    end

    it 'returns hours as floats' do
      v1 = rows.find { |r| r['version_id'] == 1 }
      expect(v1['est_hours']).to eq(150.0)
      expect(v1['spent_hours']).to eq(95.0)
    end

    it 'returns MIN start_date and MAX due_date (or nil)' do
      v1 = rows.find { |r| r['version_id'] == 1 }
      v2 = rows.find { |r| r['version_id'] == 2 }
      expect(v1['start_date']).to eq(Date.new(2026, 1, 1))
      expect(v1['due_date']).to eq(Date.new(2026, 12, 31))
      expect(v2['start_date']).to be_nil
    end

    it 'sums each cost custom field per version, keyed by id string' do
      v1 = rows.find { |r| r['version_id'] == 1 }
      expect(v1['cost']).to eq('20' => 30_000.0, '21' => 17_000.0)
    end

    it 'omits cost keys for versions/fields without values' do
      nil_row = rows.find { |r| r['version_id'].nil? }
      expect(nil_row['cost']).to eq({})
    end

    it 'returns an empty array when there are no issues' do
      empty = RollupScope.new(total: {})
      expect(described_class.version_rollup(empty)).to eq([])
    end

    it 'skips the cost queries when no cost_field_ids are given' do
      rows = described_class.version_rollup(scope, closed_statuses: ['Closed'], cost_field_ids: [])
      expect(rows).to all(include('cost' => {}))
    end
  end
end
