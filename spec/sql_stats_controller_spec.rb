# frozen_string_literal: true

require 'logger' # concurrent-ruby >= 1.3.5 no longer requires this; ActiveSupport needs Logger defined
require 'active_support'
require 'active_support/time'      # loads all time core extensions (months.ago etc.)
require_relative 'spec_helper'

Time.zone ||= 'UTC'

unless defined?(ActiveRecord)
  module ActiveRecord
    class RecordNotFound < StandardError; end
  end
end

# Minimal ApplicationController stub.
# before_action is a no-op so callbacks don't run in unit tests.
# require_login and render are defined for verify_partial_doubles compatibility.
unless defined?(ApplicationController)
  class ApplicationController
    class << self
      attr_reader :accepted_api_auth_actions

      def accept_api_auth(*actions)
        @accepted_api_auth_actions ||= []
        @accepted_api_auth_actions.concat(actions)
      end

      def before_action(*)
      end
    end

    attr_accessor :params

    def require_login
      true
    end

    def render(options = {})
      @last_render = options
    end

    def last_render
      @last_render
    end
  end
end

require_relative '../lib/sql_aggregation/query_aggregator'
require_relative '../app/controllers/sql_stats_controller'

# Plain struct for project — avoids RSpec double scoping issues inside class defs
ProjectRecord = Struct.new(:id, :identifier)

# Chainable Issue scope stub — uses class-level instance vars (no constants) to
# avoid "already initialized constant" warnings when stub_const re-creates the class.
class IssueStub
  class << self
    attr_accessor :grouped_result, :count_result, :in_group

    def reset(grouped_result: {}, count_result: 0)
      @grouped_result = grouped_result
      @count_result   = count_result
      @in_group       = false
      self
    end

    def where(*)
      @in_group = false
      self
    end

    def not(*)
      self
    end

    def unscope(*)
      self
    end

    def group(*)
      @in_group = true
      self
    end

    def count
      @in_group ? (@grouped_result || {}) : (@count_result || 0)
    end
  end
end

# Chainable IssueStatus stub
class IssueStatusStub
  class << self
    attr_accessor :closed_ids

    def where(*)
      self
    end

    def pluck(*)
      @closed_ids || [3, 4]
    end
  end
end

RSpec.describe SqlStatsController do
  # Build project and user stubs using class-level instance vars instead of
  # inner constants to avoid "already initialized constant" warnings on re-stub.
  def build_project_stub(raise_not_found: false)
    record = ProjectRecord.new(7, 'it-support')
    Class.new do
      @record          = record
      @raise_not_found = raise_not_found

      # Controller uses Project.visible.find_by!(identifier:) — stub the chain.
      def self.visible
        self
      end

      def self.find_by!(*)
        raise ActiveRecord::RecordNotFound if @raise_not_found

        @record
      end
    end
  end

  def build_user_stub(allowed: true)
    allowed_val = allowed
    Class.new do
      @allowed = allowed_val
      @user    = Class.new do
        def initialize(allowed); @allowed = allowed; end

        def allowed_to?(*)
          @allowed
        end
      end.new(allowed_val)

      def self.current
        @user
      end
    end
  end

  before do
    stub_const('Issue', IssueStub)
    stub_const('IssueStatus', IssueStatusStub)
    IssueStub.reset
    IssueStatusStub.closed_ids = [3, 4]
    stub_const('Project', build_project_stub)
    stub_const('User', build_user_stub)
  end

  let(:controller) { described_class.new }

  def rendered
    controller.last_render
  end

  describe '#monthly_flow' do
    context 'happy path with default months' do
      before { controller.params = { project_id: 'it-support' } }

      it 'renders JSON with the expected top-level keys' do
        controller.monthly_flow
        expect(rendered[:json]).to include(:labels, :created, :closed, :open_now,
                                           :project, :months, :generated_at)
      end

      it 'defaults to 6 months when months param is absent' do
        controller.monthly_flow
        expect(rendered[:json][:months]).to eq(6)
        expect(rendered[:json][:labels].length).to eq(6)
      end

      it 'sets project to the project identifier' do
        controller.monthly_flow
        expect(rendered[:json][:project]).to eq('it-support')
      end

      it 'fills integer zeros for months with no data' do
        controller.monthly_flow
        expect(rendered[:json][:created]).to all(eq(0))
        expect(rendered[:json][:closed]).to all(eq(0))
      end

      it 'includes a generated_at ISO8601 timestamp' do
        controller.monthly_flow
        expect(rendered[:json][:generated_at]).to match(/\A\d{4}-\d{2}-\d{2}T/)
      end
    end

    context 'months param: absent or zero defaults to 6' do
      it 'defaults to 6 when months param is absent (nil)' do
        controller.params = { project_id: 'it-support' }
        controller.monthly_flow
        expect(rendered[:json][:months]).to eq(6)
      end

      it 'defaults to 6 when months=0' do
        controller.params = { project_id: 'it-support', months: '0' }
        controller.monthly_flow
        expect(rendered[:json][:months]).to eq(6)
      end

      it 'defaults to 6 when months is negative' do
        controller.params = { project_id: 'it-support', months: '-3' }
        controller.monthly_flow
        expect(rendered[:json][:months]).to eq(6)
      end
    end

    context 'months param: valid range and capping' do
      it 'caps months at 24 when value exceeds maximum' do
        controller.params = { project_id: 'it-support', months: '30' }
        controller.monthly_flow
        expect(rendered[:json][:months]).to eq(24)
        expect(rendered[:json][:labels].length).to eq(24)
      end

      it 'uses exact value for months within range' do
        controller.params = { project_id: 'it-support', months: '3' }
        controller.monthly_flow
        expect(rendered[:json][:months]).to eq(3)
        expect(rendered[:json][:labels].length).to eq(3)
      end

      it 'uses months=1' do
        controller.params = { project_id: 'it-support', months: '1' }
        controller.monthly_flow
        expect(rendered[:json][:months]).to eq(1)
        expect(rendered[:json][:labels].length).to eq(1)
      end
    end

    context 'labels' do
      before { controller.params = { project_id: 'it-support', months: '3' } }

      it 'returns labels in ascending chronological order (oldest first)' do
        controller.monthly_flow
        labels = rendered[:json][:labels]
        expect(labels).to eq(labels.sort)
      end

      it 'returns YYYY-MM formatted labels' do
        controller.monthly_flow
        rendered[:json][:labels].each do |label|
          expect(label).to match(/\A\d{4}-\d{2}\z/)
        end
      end
    end

    context 'project not found' do
      before do
        stub_const('Project', build_project_stub(raise_not_found: true))
        controller.params = { project_id: 'missing' }
      end

      it 'renders 404 with error key' do
        controller.monthly_flow
        expect(rendered[:json]).to eq({ error: 'Project not found' })
        expect(rendered[:status]).to eq(:not_found)
      end
    end

    context 'user lacks view_issues permission' do
      before do
        stub_const('User', build_user_stub(allowed: false))
        controller.params = { project_id: 'it-support' }
      end

      it 'renders 403 with error key' do
        controller.monthly_flow
        expect(rendered[:json]).to eq({ error: 'Forbidden' })
        expect(rendered[:status]).to eq(:forbidden)
      end
    end

    context 'no closed issue statuses exist' do
      before do
        IssueStatusStub.closed_ids = []
        controller.params = { project_id: 'it-support', months: '2' }
      end

      it 'returns closed array with all zeros' do
        controller.monthly_flow
        expect(rendered[:json][:closed]).to eq([0, 0])
      end
    end

    context 'no issues in date range' do
      before do
        IssueStub.reset(grouped_result: {}, count_result: 0)
        controller.params = { project_id: 'it-support', months: '2' }
      end

      it 'returns created array with all zeros' do
        controller.monthly_flow
        expect(rendered[:json][:created]).to eq([0, 0])
      end

      it 'returns closed array with all zeros' do
        controller.monthly_flow
        expect(rendered[:json][:closed]).to eq([0, 0])
      end

      it 'returns open_now of zero' do
        controller.monthly_flow
        expect(rendered[:json][:open_now]).to eq(0)
      end
    end
  end
end
