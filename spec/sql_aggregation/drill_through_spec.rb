# frozen_string_literal: true

require 'logger' # concurrent-ruby >= 1.3.5 no longer requires this; ActiveSupport needs Logger defined
require 'active_support'
require 'active_support/time'
require 'cgi'
require_relative '../spec_helper'

Time.zone ||= 'UTC'

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

require_relative '../../lib/sql_aggregation/drill_through'

# Redmine's SortCriteria, reduced to what Query#as_params calls on it.
class SortCriteriaStub
  def initialize(param)
    @param = param.to_s
  end

  def to_param
    @param
  end
end

ProjectStub = Struct.new(:id, :identifier)

# Stands in for an IssueQuery. #as_params is a VERBATIM transcription of
# Query#as_params for a new record (5.1-stable and 6.1-stable are identical), so
# the specs pin the parameter names Redmine actually produces rather than the
# ones this plugin would like it to produce.
#
# available_filters lives on the class: DrillThrough builds its copy with
# IssueQuery.new(name:, project:) and reads available_filters off that copy.
class DrillQueryStub
  class << self
    attr_accessor :available_filters_config
  end
  self.available_filters_config = {}

  attr_accessor :filters, :column_names, :group_by, :totalable_names, :sort_criteria
  attr_reader :project, :name

  def initialize(name: '_', project: nil, filters: {}, column_names: nil, group_by: nil,
                 totalable_names: [], sort_criteria: SortCriteriaStub.new(''))
    @name            = name
    @project         = project
    @filters         = filters
    @column_names    = column_names
    @group_by        = group_by
    @totalable_names = totalable_names
    @sort_criteria   = sort_criteria
  end

  # Named explicitly, not self.class, so a subclass used to strip one method still
  # sees the filters the example configured.
  def available_filters
    DrillQueryStub.available_filters_config
  end

  def type_for(field)
    available_filters[field] && available_filters[field][:type]
  end

  # Query.operators_by_filter_type, transcribed for the types these specs use.
  # Note what is NOT there: :list_status has no "!*", and a plain :list (a
  # boolean custom field) has only "=" and "!".
  def operators_by_filter_type
    {
      list: ['=', '!'],
      list_status: ['o', '=', '!', 'ev', '!ev', 'cf', 'c', '*'],
      list_optional: ['=', '!', '!*', '*'],
      date: ['=', '>=', '<=', '><', 't-', '!*', '*'],
      date_past: ['=', '>=', '<=', '><', 't-', '!*', '*']
    }
  end

  # Query#as_params, new_record? branch, transcribed.
  def as_params
    params = {}
    filters.each do |field, options|
      params[:f] ||= []
      params[:f] << field
      params[:op] ||= {}
      params[:op][field] = options[:operator]
      params[:v] ||= {}
      params[:v][field] = options[:values]
    end
    params[:c] = column_names
    params[:group_by] = group_by.to_s unless group_by.nil? || group_by.to_s.empty?
    params[:t] = totalable_names.map(&:to_s) if totalable_names.any?
    params[:sort] = sort_criteria.to_param
    params[:set_filter] = 1
    params
  end
end

class SettingStub
  def self.protocol
    'https'
  end

  def self.host_name
    'redmine.example'
  end
end

RSpec.describe SqlAggregation::DrillThrough do
  # Only the filters a real IssueQuery offers; the types drive replace-vs-intersect.
  let(:available_filters) do
    {
      'status_id'      => { type: :list_status },
      'assigned_to_id' => { type: :list_optional },
      'cf_92'          => { type: :list_optional },
      'cf_86'          => { type: :list_optional },
      'created_on'     => { type: :date_past },
      'closed_on'      => { type: :date_past },
      'due_date'       => { type: :date },
      'project_id'     => { type: :list }
    }
  end

  let(:project) { ProjectStub.new(7, 'ops') }

  let(:query) do
    DrillQueryStub.new(
      project: project,
      filters: { 'status_id' => { operator: 'o', values: [''] } },
      column_names: %i[tracker status subject],
      group_by: 'priority',
      totalable_names: %i[estimated_hours],
      sort_criteria: SortCriteriaStub.new('priority:desc,updated_on:desc')
    )
  end

  before do
    stub_const('IssueQuery', DrillQueryStub)
    stub_const('Setting', SettingStub)
    DrillQueryStub.available_filters_config = available_filters
  end

  after { DrillQueryStub.available_filters_config = {} }

  def build(q = query, **opts)
    described_class.build(q, **opts)
  end

  def params_of(url)
    CGI.parse(url.split('?', 2).last)
  end

  # ------------------------------------------------------------------
  # Inherited parameters and path
  # ------------------------------------------------------------------

  describe 'the inherited query' do
    subject(:url) { build.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }]) }

    it 'points at the project-scoped issue list, absolutely' do
      expect(url).to start_with('https://redmine.example/projects/ops/issues?')
    end

    it 'sets set_filter so the long filter form is honoured' do
      expect(params_of(url)['set_filter']).to eq(['1'])
    end

    it 'inherits the query filters' do
      expect(params_of(url)['f[]']).to include('status_id')
      expect(params_of(url)['op[status_id]']).to eq(['o'])
      expect(params_of(url)['v[status_id][]']).to eq([''])
    end

    it 'inherits the columns' do
      expect(params_of(url)['c[]']).to eq(%w[tracker status subject])
    end

    it 'inherits the grouping' do
      expect(params_of(url)['group_by']).to eq(['priority'])
    end

    it 'inherits the totals' do
      expect(params_of(url)['t[]']).to eq(['estimated_hours'])
    end

    it 'inherits the sort order' do
      expect(params_of(url)['sort']).to eq(['priority:desc,updated_on:desc'])
    end

    it 'adds the dimension filter' do
      expect(params_of(url)['f[]']).to include('cf_92')
      expect(params_of(url)['op[cf_92]']).to eq(['='])
      expect(params_of(url)['v[cf_92][]']).to eq(['415'])
    end

    it 'percent-encodes the bracket and operator characters' do
      expect(url).to include('f%5B%5D=cf_92', 'op%5Bcf_92%5D=%3D', 'v%5Bcf_92%5D%5B%5D=415')
    end

    it 'is stable across calls (same filters, same URL)' do
      builder = build
      first   = builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }])
      second  = builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }])
      expect(second).to eq(first)
    end

    it 'does not mutate the report query filters' do
      build.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }])
      expect(query.filters).to eq('status_id' => { operator: 'o', values: [''] })
    end
  end

  describe 'base_url' do
    it 'carries the inherited parameters and no dimension filter' do
      params = params_of(build.base_url)
      expect(params['f[]']).to eq(['status_id'])
      expect(params['set_filter']).to eq(['1'])
    end

    it 'is reported as available' do
      expect(build.available?).to be(true)
    end
  end

  describe 'the path' do
    it 'uses the global issue list for a query without a project' do
      global = DrillQueryStub.new(project: nil, filters: {})
      expect(build(global).base_url).to start_with('https://redmine.example/issues?')
    end

    it 'falls back to the project id when it has no identifier' do
      unnamed = DrillQueryStub.new(project: ProjectStub.new(7, nil), filters: {})
      expect(build(unnamed).base_url).to start_with('https://redmine.example/projects/7/issues?')
    end

    it 'keeps a path prefix in host_name' do
      stub_const('Setting', Class.new do
        def self.protocol
          'https'
        end

        def self.host_name
          'example.eu/redmine'
        end
      end)
      expect(build.base_url).to start_with('https://example.eu/redmine/projects/ops/issues?')
    end
  end

  describe 'a query with no filters at all' do
    let(:query) { DrillQueryStub.new(project: project, filters: {}) }

    it "emits Redmine's blank f[] marker so the issue list does not default to open issues" do
      expect(params_of(build.base_url)['f[]']).to eq([''])
    end

    it 'still adds the dimension filter when there is one' do
      url = build.url_for([{ 'field' => 'status_id', 'operator' => '=', 'values' => ['5'] }])
      expect(params_of(url)['f[]']).to eq(['status_id'])
      expect(params_of(url)['v[status_id][]']).to eq(['5'])
    end
  end

  # ------------------------------------------------------------------
  # Merging: replace vs intersect
  # ------------------------------------------------------------------

  describe 'merging into an inherited filter on the same field' do
    it 'replaces a non-date filter (the bucket is a subset by construction)' do
      url    = build.url_for([{ 'field' => 'status_id', 'operator' => '=', 'values' => ['5'] }])
      params = params_of(url)
      expect(params['f[]'].count('status_id')).to eq(1)
      expect(params['op[status_id]']).to eq(['='])
      expect(params['v[status_id][]']).to eq(['5'])
    end

    context 'with an absolute inherited date range' do
      let(:query) do
        DrillQueryStub.new(project: project,
                           filters: { 'created_on' => { operator: '><', values: %w[2026-02-10 2026-04-20] } })
      end

      it 'intersects instead of replacing' do
        url = build.url_for([{ 'field' => 'created_on', 'operator' => '><',
                               'values' => %w[2026-03-01 2026-05-31] }])
        expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-01 2026-04-20])
      end

      it 'intersects an open-ended bucket range' do
        url = build.url_for([{ 'field' => 'created_on', 'operator' => '>=', 'values' => ['2026-03-01'] }])
        expect(params_of(url)['op[created_on]']).to eq(['><'])
        expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-01 2026-04-20])
      end
    end

    it 'returns no URL when the bucket and the inherited range are disjoint' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '><', values: %w[2026-08-05 2026-08-20] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-06-01 2026-06-30] }])
      expect(url).to be_nil
    end

    it 'still links a range that only touches at one day' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '><', values: %w[2026-06-30 2026-08-20] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-06-01 2026-06-30] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-06-30 2026-06-30])
    end

    it 'intersects a one-sided inherited >= range' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '>=', values: ['2026-03-15'] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-03-01 2026-03-31] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-15 2026-03-31])
    end

    it 'intersects a one-sided inherited <= range' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '<=', values: ['2026-03-15'] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-03-01 2026-03-31] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-01 2026-03-15])
    end

    it 'keeps an inherited single-day = filter, which is never wider than the bucket' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '=', values: ['2026-03-15'] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-03-01 2026-03-31] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-15 2026-03-15])
    end

    it 'treats an inherited "is set" filter as no constraint' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '*', values: [''] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-03-01 2026-03-31] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-01 2026-03-31])
    end

    it 'refuses a "none" bucket when the query filters that date to a range' do
      # The mirror image of the case below: a NULL date is inside no range, so the
      # two cannot both hold.
      q = DrillQueryStub.new(project: project,
                             filters: { 'due_date' => { operator: '><', values: %w[2026-01-01 2026-12-31] } })
      url = build(q).url_for([{ 'field' => 'due_date', 'operator' => '!*', 'values' => [''] }])
      expect(url).to be_nil
    end

    it 'keeps a "none" bucket when the query also asks for "none"' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'due_date' => { operator: '!*', values: [''] } })
      url = build(q).url_for([{ 'field' => 'due_date', 'operator' => '!*', 'values' => [''] }])
      expect(params_of(url)['op[due_date]']).to eq(['!*'])
    end

    it 'refuses the combination of an inherited "none" and a bucket range' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'due_date' => { operator: '!*', values: [''] } })
      url = build(q).url_for([{ 'field' => 'due_date', 'operator' => '><',
                               'values' => %w[2026-03-01 2026-03-31] }])
      expect(url).to be_nil
    end

    context 'with a relative inherited date range' do
      let(:query) do
        DrillQueryStub.new(project: project,
                           filters: { 'created_on' => { operator: 't-', values: ['30'] } })
      end

      it 'falls back to the bucket range' do
        url = build.url_for([{ 'field' => 'created_on', 'operator' => '><',
                               'values' => %w[2026-03-01 2026-03-31] }])
        expect(params_of(url)['op[created_on]']).to eq(['><'])
        expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-01 2026-03-31])
      end

      it 'logs the fallback at debug level' do
        expect(Rails.logger).to receive(:debug).with(/relative operator "t-".*can\s*show more issues/m)
        build.url_for([{ 'field' => 'created_on', 'operator' => '><',
                         'values' => %w[2026-03-01 2026-03-31] }])
      end
    end

    it 'falls back to the bucket range when an absolute operator carries an unparseable date' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '><', values: ['', 'not-a-date'] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-03-01 2026-03-31] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-01 2026-03-31])
    end

    it 'recognises a date field by name when the query cannot type it' do
      untyped = { 'created_on' => {} }
      DrillQueryStub.available_filters_config = untyped
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '><', values: %w[2026-02-10 2026-04-20] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-03-01 2026-05-31] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-01 2026-04-20])
    end
  end

  describe 'a bucket whose own dates cannot be read' do
    # Reachable for a date-format custom field holding something that is not a
    # date: the dimension groups on the raw stored value, so the bucket filter
    # carries that value verbatim.
    let(:available_filters) { { 'cf_92' => { type: :date }, 'created_on' => { type: :date_past } } }

    it 'refuses the element instead of falling back to the inherited range' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'cf_92' => { operator: '><', values: %w[2026-01-01 2026-12-31] } })
      url = build(q).url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['not-a-date'] }])
      expect(url).to be_nil
    end

    it 'refuses it even when the query does not filter that field at all' do
      q = DrillQueryStub.new(project: project, filters: {})
      url = build(q).url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['not-a-date'] }])
      expect(url).to be_nil
    end

    it 'refuses it when the inherited filter is only "is set"' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'cf_92' => { operator: '*', values: [''] } })
      url = build(q).url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['whatever'] }])
      expect(url).to be_nil
    end

    it 'still links a value that IS a date' do
      q = DrillQueryStub.new(project: project, filters: {})
      url = build(q).url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['2026-03-15'] }])
      expect(params_of(url)['op[cf_92]']).to eq(['='])
      expect(params_of(url)['v[cf_92][]']).to eq(['2026-03-15'])
    end

    it 'names the field and the value it refused' do
      q = DrillQueryStub.new(project: project, filters: {})
      allow(Rails.logger).to receive(:warn)
      expect(Rails.logger).to receive(:warn).with(/"cf_92" is a date filter but the bucket value/)
      build(q).url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['not-a-date'] }])
    end
  end

  describe 'date values Redmine would not accept' do
    it 'does not read a bare day number as a bound' do
      # Date.parse("30") is the 30th of the current month; Redmine rejects the
      # value outright. Treating it as relative keeps the bucket range instead.
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '>=', values: ['30'] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-03-01 2026-03-31] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-01 2026-03-31])
    end

    it 'ignores an impossible calendar date' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '>=', values: ['2026-02-31'] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-03-01 2026-03-31] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-01 2026-03-31])
    end

    it 'accepts an ISO timestamp, which Redmine also accepts' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '>=', values: ['2026-03-15T09:00:00Z'] } })
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '><',
                                'values' => %w[2026-03-01 2026-03-31] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-15 2026-03-31])
    end
  end

  describe 'the operator produced by a merge' do
    # A type table that allows the one-sided operators but not the two-sided one,
    # so the operator the INTERSECTION synthesises is the one Redmine refuses.
    before do
      allow_any_instance_of(DrillQueryStub).to receive(:operators_by_filter_type)
        .and_return(date_past: ['>=', '<=', '!*', '*'], list_optional: ['=', '!', '!*', '*'])
    end

    it 'is validated again, so a merge cannot smuggle one past the type check' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '<=', values: ['2026-06-30'] } })
      # The bucket operator itself is allowed; >< only appears after intersecting.
      url = build(q).url_for([{ 'field' => 'created_on', 'operator' => '>=', 'values' => ['2026-03-01'] }])
      expect(url).to be_nil
    end

    it 'says which operator it refused' do
      q = DrillQueryStub.new(project: project,
                             filters: { 'created_on' => { operator: '<=', values: ['2026-06-30'] } })
      allow(Rails.logger).to receive(:warn)
      expect(Rails.logger).to receive(:warn).with(/does not allow the operator "><" on "created_on"/)
      build(q).url_for([{ 'field' => 'created_on', 'operator' => '>=', 'values' => ['2026-03-01'] }])
    end
  end

  # ------------------------------------------------------------------
  # Two filters (crosstab cells)
  # ------------------------------------------------------------------

  describe 'two filters' do
    it 'ANDs them as two independent filters' do
      url = build.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] },
                           { 'field' => 'cf_86', 'operator' => '=', 'values' => ['345'] }])
      params = params_of(url)
      expect(params['f[]']).to include('cf_92', 'cf_86')
      expect(params['v[cf_92][]']).to eq(['415'])
      expect(params['v[cf_86][]']).to eq(['345'])
    end

    it 'refuses two different non-date filters on one field' do
      url = build.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] },
                           { 'field' => 'cf_92', 'operator' => '=', 'values' => ['416'] }])
      expect(url).to be_nil
    end

    it 'accepts two identical filters on one field' do
      filter = { 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }
      expect(build.url_for([filter, filter.dup])).not_to be_nil
    end

    it 'intersects two date filters on one field (a period x age crosstab)' do
      url = build.url_for([{ 'field' => 'created_on', 'operator' => '><',
                             'values' => %w[2026-03-01 2026-03-31] },
                           { 'field' => 'created_on', 'operator' => '><',
                             'values' => %w[2026-03-10 2026-04-10] }])
      expect(params_of(url)['v[created_on][]']).to eq(%w[2026-03-10 2026-03-31])
    end

    it 'ignores nil entries, so a stage without a filter is the report query itself' do
      expect(build.url_for([nil])).to eq(build.base_url)
    end
  end

  # ------------------------------------------------------------------
  # Validation and refusals
  # ------------------------------------------------------------------

  describe 'validation' do
    it 'returns nil for a field that is not an available filter' do
      expect(build.url_for([{ 'field' => 'cf_404', 'operator' => '=', 'values' => ['1'] }])).to be_nil
    end

    it 'logs the unavailable field once per render' do
      builder = build
      expect(Rails.logger).to receive(:warn).once.with(/"cf_404" is not an available issue-list filter/)
      3.times { builder.url_for([{ 'field' => 'cf_404', 'operator' => '=', 'values' => [(rand * 10).to_i.to_s] }]) }
    end

    it 'refuses an operator Redmine does not allow on that filter type' do
      # status_id is :list_status, which has no "none" operator.
      expect(build.url_for([{ 'field' => 'status_id', 'operator' => '!*', 'values' => [''] }])).to be_nil
    end

    it 'logs the refused operator once per render' do
      builder = build
      expect(Rails.logger).to receive(:warn).once.with(/does not allow the operator "!\*" on "status_id"/)
      2.times { builder.url_for([{ 'field' => 'status_id', 'operator' => '!*', 'values' => [''] }]) }
    end

    it 'refuses the "none" operator on a boolean custom field, which is a plain list' do
      DrillQueryStub.available_filters_config =
        available_filters.merge('cf_92' => { type: :list })
      expect(build.url_for([{ 'field' => 'cf_92', 'operator' => '!*', 'values' => [''] }])).to be_nil
      expect(build.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['1'] }])).not_to be_nil
    end

    it 'allows every operator when the query cannot list them' do
      stripped = Class.new(DrillQueryStub) do
        undef_method :operators_by_filter_type
      end
      stub_const('IssueQuery', stripped)
      q = stripped.new(project: project, filters: {})
      url = described_class.build(q).url_for([{ 'field' => 'status_id', 'operator' => '!*', 'values' => [''] }])
      expect(url).to include('op%5Bstatus_id%5D=%21%2A')
    end

    it 'allows the operator when the field has no type at all' do
      DrillQueryStub.available_filters_config = { 'cf_92' => {} }
      url = build.url_for([{ 'field' => 'cf_92', 'operator' => '!*', 'values' => [''] }])
      expect(url).not_to be_nil
    end

    it 'refuses an operator this plugin never generates' do
      expect(Rails.logger).to receive(:warn).with(/refusing drill-through operator/)
      expect(build.url_for([{ 'field' => 'status_id', 'operator' => 'DROP', 'values' => ['1'] }])).to be_nil
    end

    it 'refuses a descriptor without a field' do
      expect(build.url_for([{ 'field' => '', 'operator' => '=', 'values' => ['1'] }])).to be_nil
    end

    it 'accepts symbol keys as well as string keys' do
      url = build.url_for([{ field: 'cf_92', operator: '=', values: ['415'] }])
      expect(params_of(url)['v[cf_92][]']).to eq(['415'])
    end

    it 'stringifies numeric values' do
      url = build.url_for([{ 'field' => 'status_id', 'operator' => '=', 'values' => [5] }])
      expect(params_of(url)['v[status_id][]']).to eq(['5'])
    end

    it 'keeps the single blank value the "none" operator needs' do
      url = build.url_for([{ 'field' => 'assigned_to_id', 'operator' => '!*', 'values' => [''] }])
      expect(url).to include('op%5Bassigned_to_id%5D=%21%2A')
      expect(params_of(url)['v[assigned_to_id][]']).to eq([''])
    end

    it 'defaults an empty values array to the single blank value' do
      url = build.url_for([{ 'field' => 'assigned_to_id', 'operator' => '*', 'values' => [] }])
      expect(params_of(url)['v[assigned_to_id][]']).to eq([''])
    end
  end

  describe 'inherit:' do
    it 'inherits everything by default' do
      params = params_of(build.base_url)
      expect(params.keys).to include('c[]', 't[]', 'group_by', 'sort')
    end

    it 'inherits the filters only for :filters_only' do
      params = params_of(build(query, inherit: :filters_only).base_url)
      expect(params.keys).to include('f[]', 'op[status_id]', 'set_filter')
      expect(params.keys).not_to include('c[]', 't[]', 'group_by', 'sort')
    end

    it 'falls back to :all for an unknown level' do
      expect(params_of(build(query, inherit: :banana).base_url).keys).to include('c[]')
    end

    it 'is not reported as a degradation — it was asked for' do
      builder = build(query, inherit: :filters_only)
      builder.base_url
      expect(builder.degraded?).to be_falsey
    end
  end

  describe 'the URL length cap' do
    let(:many) { (1..200).map(&:to_s) }

    it 'returns nil rather than a truncated URL' do
      builder = build
      expect(builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => many }])).to be_nil
    end

    it 'names the field, the real length and the cap when it gives up' do
      allow(Rails.logger).to receive(:warn)
      expect(Rails.logger).to receive(:warn)
        .with(/for cf_92 is still \d+ characters with filters alone, over the 2000 cap/)
      build.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => many }])
    end

    it 'gives up only once per render, however many elements ask' do
      builder = build
      allow(Rails.logger).to receive(:warn)
      expect(Rails.logger).to receive(:warn).once.with(/with filters alone/)
      2.times { builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => many }]) }
    end

    context 'when only the cosmetic parameters are in the way' do
      # 241 characters in full, 194 without the inherited columns and totals.
      let(:builder) { build(query, max_url_length: 200) }
      let(:url)     { builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }]) }

      it 'keeps the link' do
        expect(url).not_to be_nil
      end

      it 'drops the columns and totals, which are cosmetic' do
        expect(params_of(url).keys).not_to include('c[]', 't[]')
      end

      it 'keeps every filter, which is what correctness depends on' do
        expect(params_of(url)['f[]']).to include('status_id', 'cf_92')
        expect(params_of(url)['v[cf_92][]']).to eq(['415'])
      end

      it 'reports the degradation' do
        url
        expect(builder.degraded?).to be(true)
      end

      it 'logs what it dropped and why, once' do
        allow(Rails.logger).to receive(:warn)
        expect(Rails.logger).to receive(:warn).once.with(/retrying without the inherited c\/t/)
        builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }])
        builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['416'] }])
      end
    end

    it 'sheds grouping and sort too when columns alone are not enough' do
      builder = build(query, max_url_length: 170)
      expect(params_of(builder.base_url).keys).not_to include('sort', 'group_by')
      expect(params_of(builder.base_url)['f[]']).to eq(['status_id'])
    end

    # Walking down the ladder is not a degradation; handing out a shortened URL is.
    # With nothing left to shed there is no ladder, so a refusal stands alone.
    it 'does not report a degradation when it only gave up' do
      builder = described_class.new(query, max_url_length: 100, inherit: :filters_only)
      expect(builder.base_url).to be_nil
      expect(builder.degraded?).to be_falsey
    end

    it 'does report one when the base URL itself had to be shortened' do
      builder = build(query, max_url_length: 170)
      expect(builder.base_url).not_to be_nil
      expect(params_of(builder.base_url).keys).not_to include('c[]')
      expect(builder.degraded?).to be(true)
    end

    it 'reports no degradation when the whole URL fits' do
      builder = build
      builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }])
      expect(builder.degraded?).to be_falsey
    end

    it 'links to the union when the values fit' do
      url = build.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => %w[580 581] }])
      expect(params_of(url)['v[cf_92][]']).to eq(%w[580 581])
    end

    it 'is configurable' do
      builder = build(query, max_url_length: 100_000)
      url     = builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => many }])
      expect(params_of(url)['v[cf_92][]'].length).to eq(200)
    end

    it 'ignores a non-positive cap and uses the default' do
      builder = build(query, max_url_length: 0)
      expect(builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => many }])).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # Failure modes
  # ------------------------------------------------------------------

  describe '.build' do
    it 'returns nil for a nil query' do
      expect(described_class.build(nil)).to be_nil
    end

    it 'returns nil when the query cannot be copied' do
      report_query = query # build it before IssueQuery.new starts raising
      allow(DrillQueryStub).to receive(:new).and_raise(StandardError, 'no db')
      expect(described_class.build(report_query)).to be_nil
    end

    it 'returns nil when the host settings are unreadable' do
      stub_const('Setting', Class.new { def self.protocol; raise StandardError, 'no settings'; end })
      expect(described_class.build(query)).to be_nil
    end

    # The base URL needs no validation, so it survives; every element URL is
    # refused instead, which is the safe direction.
    it 'keeps the base URL but refuses every element when available_filters blows up' do
      allow_any_instance_of(DrillQueryStub).to receive(:available_filters).and_raise(StandardError, 'boom')
      builder = described_class.build(query)
      expect(builder.base_url).to include('set_filter=1')
      expect(builder.url_for([{ 'field' => 'status_id', 'operator' => '=', 'values' => ['5'] }])).to be_nil
    end
  end

  describe 'url_for' do
    it 'returns nil instead of raising when serialisation fails' do
      builder = build
      allow_any_instance_of(DrillQueryStub).to receive(:as_params).and_raise(StandardError, 'boom')
      expect(builder.url_for([{ 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }])).to be_nil
    end

    it 'accepts nil as the whole descriptor list' do
      expect(build.url_for(nil)).to eq(build.base_url)
    end
  end
end
