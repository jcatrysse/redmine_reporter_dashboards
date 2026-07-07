# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/liquid/version_drop'
require_relative '../../lib/redmine_reporter_dashboards/liquid/custom_field_value_drop'
require_relative '../../lib/redmine_reporter_dashboards/liquid/issue_drop_patch'

# Stand-in for the underlying AR Issue: only #custom_field_value is needed.
# Mirrors Redmine's Acts::Customizable#custom_field_value(id) contract: given a
# field id, return the stored value (a String for a numeric field) or nil.
CFIssue = Struct.new(:values) do
  def custom_field_value(field_id)
    values[field_id.to_i]
  end
end

# Mirrors the shape of Redmineup::Liquid::IssueDrop: stores the wrapped issue in
# @issue and is constructed with IssueDrop.new(issue).
class FakeCFIssueDrop
  def initialize(issue)
    @issue = issue
  end
end
FakeCFIssueDrop.prepend(RedmineReporterDashboards::Liquid::IssueDropPatch)

RSpec.describe RedmineReporterDashboards::Liquid::IssueDropPatch do
  describe '#custom_field_value' do
    let(:issue) { CFIssue.new({ 20 => '12500.5', 21 => '9800', 7 => 'hello' }) }
    let(:drop)  { FakeCFIssueDrop.new(issue) }

    it 'returns a CustomFieldValueDrop for a valid issue' do
      expect(drop.custom_field_value).to be_a(RedmineReporterDashboards::Liquid::CustomFieldValueDrop)
    end

    it 'reads any custom field by integer id (bracket -> liquid_method_missing)' do
      cfv = drop.custom_field_value
      expect(cfv.liquid_method_missing(20)).to eq('12500.5')
      expect(cfv.liquid_method_missing(21)).to eq('9800')
      expect(cfv.liquid_method_missing(7)).to eq('hello')
    end

    it 'accepts a string id too (Liquid may pass either)' do
      expect(drop.custom_field_value.liquid_method_missing('20')).to eq('12500.5')
    end

    it 'returns nil for an id the issue has no value for' do
      expect(drop.custom_field_value.liquid_method_missing(999)).to be_nil
    end

    it 'returns nil defensively when the wrapped object has no custom_field_value' do
      stray = Class.new { include RedmineReporterDashboards::Liquid::IssueDropPatch }.new
      expect(stray.custom_field_value).to be_nil
    end
  end
end
