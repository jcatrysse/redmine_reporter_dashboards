# frozen_string_literal: true

require 'logger' # concurrent-ruby >= 1.3.5 no longer requires this; ActiveSupport needs Logger defined
require 'active_support'
require 'active_support/core_ext/object/blank' # Object#present?, as used by the patch
require_relative 'spec_helper'

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

require_relative '../lib/reporter_list_patch'

# Chainable AR scope stand-in: ReporterListPatch decides between the scope it was
# handed and query.base_scope by duck-typing on where/group.
class PatchScopeStub
  def where(*); self; end
  def group(*); self; end
end

class PatchQueryStub
  attr_reader :base_scope

  def initialize(scope)
    @base_scope = scope
  end

  def self.registry
    @registry ||= {}
  end

  def self.find_by(id:)
    registry[id]
  end
end

PatchReport = Struct.new(:name, :filename, :content, :link_params, :orientation)

# The Reporter class the patch prepends into: generate_reports(issues, query_id)
# renders the template through liquidize().
class ReporterTemplateStub
  attr_reader :liquidize_calls, :super_calls, :queries_seen

  def initialize(raise_in_liquidize: false)
    @raise_in_liquidize = raise_in_liquidize
    @liquidize_calls    = []
    @super_calls        = 0
    @queries_seen       = []
  end

  def generate_reports(_issues, _query_id = nil)
    @super_calls += 1
    [:fallback]
  end

  def liquidize(scope)
    @liquidize_calls << scope
    # What a Liquid tag would see mid-render.
    @queries_seen << Thread.current[SqlAggregation::ScopeResolution::QUERY_THREAD_KEY]
    raise StandardError, 'liquid blew up' if @raise_in_liquidize

    '<html>'
  end

  def name;        'Report';  end
  def filename;    'r.pdf';   end
  def orientation; 'portrait'; end

  def public_link_params(_issues, _query_id)
    { query_id: 1 }
  end
end

RSpec.describe ReporterListPatch do
  let(:key)   { SqlAggregation::ScopeResolution::QUERY_THREAD_KEY }
  let(:scope) { PatchScopeStub.new }
  let(:query) { PatchQueryStub.new(scope) }

  before do
    stub_const('IssueQuery', PatchQueryStub)
    stub_const('Report', PatchReport)
    PatchQueryStub.registry.clear
    PatchQueryStub.registry[42] = query
    Thread.current[key] = nil
  end

  after { Thread.current[key] = nil }

  def template(**opts)
    Class.new(ReporterTemplateStub) { prepend ReporterListPatch }.new(**opts)
  end

  it 'renders through liquidize with the scope, not the loaded Array' do
    subject = template
    subject.generate_reports([Object.new], 42)

    expect(subject.liquidize_calls).to eq([scope])
    expect(subject.super_calls).to eq(0)
  end

  it 'exposes the report query to the Liquid tags for the duration of the render' do
    subject = template
    subject.generate_reports([Object.new], 42)

    expect(subject.queries_seen).to eq([query])
  end

  it 'clears the thread-local afterwards' do
    template.generate_reports([Object.new], 42)

    expect(Thread.current[key]).to be_nil
  end

  it 'clears the thread-local even when liquidize raises' do
    subject = template(raise_in_liquidize: true)

    expect { subject.generate_reports([Object.new], 42) }.not_to raise_error
    expect(Thread.current[key]).to be_nil
    expect(subject.super_calls).to eq(1) # degraded to the unpatched path
  end

  it 'restores a previous value instead of blindly clearing' do
    outer = PatchQueryStub.new(scope)
    Thread.current[key] = outer

    template.generate_reports([Object.new], 42)

    expect(Thread.current[key]).to be(outer)
  end

  it 'uses the AR scope it was handed and still publishes the query' do
    subject = template
    subject.generate_reports(scope, 42)

    expect(subject.liquidize_calls).to eq([scope])
    expect(subject.queries_seen).to eq([query])
  end

  it 'still renders when the query has been deleted, with no query published' do
    subject = template
    subject.generate_reports(scope, 999)

    expect(subject.liquidize_calls).to eq([scope])
    expect(subject.queries_seen).to eq([nil])
  end

  it 'falls back to the unpatched path without a query_id' do
    subject = template
    expect(subject.generate_reports([Object.new])).to eq([:fallback])
    expect(subject.liquidize_calls).to be_empty
  end

  it 'falls back to the unpatched path when there is no scope to render' do
    subject = template
    expect(subject.generate_reports([Object.new], 999)).to eq([:fallback])
  end

  it 'returns one Report built from the rendered html' do
    reports = template.generate_reports([Object.new], 42)

    expect(reports.length).to eq(1)
    expect(reports.first.content).to eq('<html>')
  end
end
