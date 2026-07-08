# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/liquid/version_drop'

# Minimal stand-ins so the drop can be exercised without booting Redmine.
VersionDropProject = Struct.new(:identifier, :name)
VersionDropVersion = Struct.new(:id, :name, :description, :effective_date, :status, :completed_percent, :project)

# Setting stub declaring the class methods the drop calls (satisfies
# verify_partial_doubles); examples override the return values.
class VersionDropSettingStub
  def self.protocol; end
  def self.host_name; end
end

RSpec.describe RedmineReporterDashboards::Liquid::VersionDrop do
  let(:project) { VersionDropProject.new('geoxyz', 'GEOxyz') }
  let(:version) do
    VersionDropVersion.new(42, '2025.1', 'Spring release', Date.new(2025, 3, 31), 'open', 60, project)
  end

  subject(:drop) { described_class.new(version) }

  before do
    stub_const('Setting', VersionDropSettingStub)
    allow(Setting).to receive(:protocol).and_return('https')
    allow(Setting).to receive(:host_name).and_return('redmine.geoxyz.eu')
  end

  describe 'scalar attributes' do
    it 'exposes the version metadata' do
      expect(drop.id).to eq(42)
      expect(drop.name).to eq('2025.1')
      expect(drop.description).to eq('Spring release')
      expect(drop.effective_date).to eq(Date.new(2025, 3, 31))
      expect(drop.status).to eq('open')
      expect(drop.completed_percent).to eq(60)
      expect(drop.project_identifier).to eq('geoxyz')
      expect(drop.project_name).to eq('GEOxyz')
    end

    it 'returns a nil effective_date unchanged (not coerced)' do
      version.effective_date = nil
      expect(drop.effective_date).to be_nil
    end

    it 'returns nil project_identifier and project_name when the version has no project' do
      version.project = nil
      expect(drop.project_identifier).to be_nil
      expect(drop.project_name).to be_nil
    end
  end

  describe 'absolute URLs' do
    it 'builds the version url' do
      expect(drop.url).to eq('https://redmine.geoxyz.eu/versions/42')
    end

    it 'builds the roadmap url from the project identifier' do
      expect(drop.roadmap_url).to eq('https://redmine.geoxyz.eu/projects/geoxyz/roadmap')
    end

    it 'builds issues urls for all/open/closed statuses' do
      base = 'https://redmine.geoxyz.eu/projects/geoxyz/issues?set_filter=1&fixed_version_id=42'
      expect(drop.issues_url).to        eq("#{base}&status_id=*")
      expect(drop.open_issues_url).to   eq("#{base}&status_id=o")
      expect(drop.closed_issues_url).to eq("#{base}&status_id=c")
    end

    it 'builds a time_entries url with percent-encoded bracket/operator chars' do
      expect(drop.time_url).to eq(
        'https://redmine.geoxyz.eu/projects/geoxyz/time_entries?set_filter=1' \
        '&f%5B%5D=issue.fixed_version_id' \
        '&op%5Bissue.fixed_version_id%5D=%3D' \
        '&v%5Bissue.fixed_version_id%5D%5B%5D=42'
      )
    end

    it 'contains no raw bracket or space characters in the time url (valid href)' do
      expect(drop.time_url).not_to match(/[\[\] ]/)
    end

    it 'honours the configured protocol and host (incl. a path prefix)' do
      allow(Setting).to receive(:protocol).and_return('http')
      allow(Setting).to receive(:host_name).and_return('example.com/redmine')
      expect(drop.url).to eq('http://example.com/redmine/versions/42')
      expect(drop.roadmap_url).to eq('http://example.com/redmine/projects/geoxyz/roadmap')
    end

    it 'reads the host settings only once (base built once)' do
      expect(Setting).to receive(:host_name).once.and_return('redmine.geoxyz.eu')
      allow(Setting).to receive(:protocol).and_return('https')
      drop.url
      drop.roadmap_url
      drop.issues_url
      drop.time_url
    end
  end
end
