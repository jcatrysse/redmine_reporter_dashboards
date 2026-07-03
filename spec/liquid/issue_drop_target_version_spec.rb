# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/liquid/version_drop'
require_relative '../../lib/redmine_reporter_dashboards/liquid/issue_drop_patch'

# Stand-in for the underlying AR Issue: only #fixed_version is needed.
TargetVersionIssue = Struct.new(:fixed_version)
TargetVersionVersion = Struct.new(:id, :name, :project)

# Mirrors the shape of Redmineup::Liquid::IssueDrop: an object that stores the
# wrapped issue in @issue and is constructed with IssueDrop.new(issue).
class FakeReporterIssueDrop
  def initialize(issue)
    @issue = issue
  end
end
FakeReporterIssueDrop.prepend(RedmineReporterDashboards::Liquid::IssueDropPatch)

RSpec.describe RedmineReporterDashboards::Liquid::IssueDropPatch do
  let(:version) { TargetVersionVersion.new(7, '1.0', nil) }

  it 'returns a VersionDrop wrapping the issue fixed_version' do
    drop = FakeReporterIssueDrop.new(TargetVersionIssue.new(version))
    tv = drop.target_version

    expect(tv).to be_a(RedmineReporterDashboards::Liquid::VersionDrop)
    expect(tv.id).to eq(7)
    expect(tv.name).to eq('1.0')
  end

  it 'returns nil when the issue has no target version' do
    drop = FakeReporterIssueDrop.new(TargetVersionIssue.new(nil))
    expect(drop.target_version).to be_nil
  end

  it 'returns nil defensively when the wrapped object has no fixed_version' do
    stray = Class.new { include RedmineReporterDashboards::Liquid::IssueDropPatch }.new
    expect(stray.target_version).to be_nil
  end
end
