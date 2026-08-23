# frozen_string_literal: true

require_relative '../spec_helper'

# T-20 — the two compensating surfaces are retired, and stay retired.
#
# --- WHY A SPEC AND NOT JUST A DELETION ---
#
# Because every one of these files was ADDED for a reason that still sounds good: the
# vendor gem's issue drop was missing a version id, so the addon built a lookup tag,
# then a `VersionDrop`, then a prepend into another plugin's class to hang it off. Each
# step was locally sensible and the result was 295 lines of compensation for a drop
# layer this plugin now owns. A deletion with no test is an invitation to re-derive the
# same chain the next time somebody needs `issue.version.id` in a hurry.
#
# So this file asserts the absence, names the replacement, and — the part that actually
# matters — asserts that nothing in the tree reaches into the host plugin's drop class
# any more. That last one is gate G8's subject, and two allowlist entries went with it.
#
# --- WHERE THE REPLACEMENT IS PROVEN ---
#
# NOT here. `spec_liquid/drops_spec.rb` renders real templates against the real Liquid
# gem and asserts `{{ issue.version }}|{{ issue.target_version }}` and the whole
# `{{ issue.custom_field_value[20] }}` family, on both Liquid majors. This file must not
# grow a second, weaker copy of that: it is about what is GONE.
RSpec.describe 'T-20: the retired compensating surface' do
  ROOT_FOR_RETIRED = File.expand_path('../..', __dir__)

  def read(path)
    File.read(File.join(ROOT_FOR_RETIRED, path), encoding: 'UTF-8')
  end

  # Every `.rb`, `.erb` and `.rake` this plugin ships. `spec/` and `docs/` are excluded
  # on purpose: this file's own text names the deleted constants, and the plan documents
  # name them because describing what was removed is the documents' job.
  def shipped_sources
    Dir.glob(File.join(ROOT_FOR_RETIRED, '{app,lib,config,db}/**/*.{rb,erb,rake}'))
       .push(File.join(ROOT_FOR_RETIRED, 'init.rb'))
       .select { |path| File.file?(path) }
  end

  # WHOLE-LINE COMMENTS ARE STRIPPED, and that is not a loophole — it is the lesson
  # `script/gates/layer_purity.sh` records about its own first run: it failed on the two
  # comments EXPLAINING why the boundary exists, and "a gate that punishes writing down
  # its own rationale teaches people to delete the rationale". This check hit exactly
  # that on its first run, against the note in `lib/redmine_reporter_dashboards.rb` that
  # says which class the removed registration used to prepend into. A trailing comment
  # on a line of code still counts; that line is code.
  def code_of(path)
    File.read(path, encoding: 'UTF-8').gsub(/^[ \t]*#.*$/, '')
  end

  describe 'the deleted files' do
    # Path by path rather than "the directory has N files", because the message a
    # failure prints is the whole value of the assertion.
    {
      'lib/redmine_reporter_dashboards/liquid/version_drop.rb' =>
        'replaced by Drops::VersionDrop, which also carries the four absolute URLs',
      'lib/redmine_reporter_dashboards/liquid/custom_field_value_drop.rb' =>
        'replaced by Drops::CustomFieldValuesDrop (by-id bracket lookup, visibility-filtered)',
      'lib/redmine_reporter_dashboards/liquid/issue_drop_patch.rb' =>
        'the prepend into the host plugin\'s IssueDrop; both accessors are on Drops::IssueDrop now'
    }.each do |path, replacement|
      it "#{path} is gone — #{replacement}" do
        expect(File.exist?(File.join(ROOT_FOR_RETIRED, path))).to be(false)
      end
    end
  end

  describe 'the registration that loaded them' do
    it 'is gone from the plugin module' do
      expect(read('lib/redmine_reporter_dashboards.rb'))
        .not_to match(/def register_issue_target_version_drop/)
    end

    it 'is no longer called from init.rb' do
      expect(read('init.rb')).not_to match(/^\s*RedmineReporterDashboards\.register_issue_target_version_drop/)
    end

    # The three tags still register. A deletion that took a working tag with it would
    # also satisfy every assertion above.
    it 'left the tag registrations alone' do
      source = read('lib/redmine_reporter_dashboards.rb')

      %w[register_sql_aggregate_tag register_version_rollup_tag register_geo_version_map_tag]
        .each { |name| expect(source).to match(/def #{name}\b/) }
    end
  end

  describe 'the coupling it carried' do
    # THE POINT OF THE TASK. `Object.const_get('RedmineReporter::Liquid::Drops::IssueDrop')`
    # was the only place this plugin reached into another plugin's class to change it.
    # A prepend is not an integration: it is a second owner for somebody else's method
    # table, and it broke silently when their class moved.
    it 'no shipped source names the host plugin\'s issue drop class' do
      offenders = shipped_sources.select do |path|
        code_of(path).match?(/RedmineReporter::Liquid::Drops::IssueDrop/)
      end

      expect(offenders).to be_empty,
                           "these still reach into the host plugin's drop class:\n  " \
                           "#{offenders.map { |p| p.sub("#{ROOT_FOR_RETIRED}/", '') }.join("\n  ")}"
    end

    it 'no shipped source prepends into a RedmineReporter class' do
      offenders = shipped_sources.select do |path|
        code_of(path).match?(/prepend\(?\s*RedmineReporterDashboards::Liquid::IssueDropPatch/)
      end

      expect(offenders).to be_empty
    end

    # The allowlist may only shrink (its own header says so). Two entries were removed
    # with the files; asserting their absence is what stops them coming back as
    # "accepted debt" for a file that no longer needs to exist.
    it 'dropped both allowlist entries rather than leaving them stale' do
      allowlist = read('script/gates/zero_reporter.allowlist')

      expect(allowlist).not_to include('liquid/issue_drop_patch.rb')
      expect(allowlist).not_to include('liquid/custom_field_value_drop.rb')
    end
  end

  # A DEFINITION check as well as a path check, because a filename is not the only way a
  # class comes back: a stray copy under a different name would pass the first block.
  #
  # Scoped to `liquid/*.rb` and NOT `liquid/drops/*.rb`, which is the distinction the
  # whole task is about. `Drops::VersionDrop` and `Drops::CustomFieldValueDrop` are the
  # owned replacements and must keep existing; what may not come back is a second one
  # sitting directly in the namespace, which is where the addon's copies lived.
  describe 'the old addresses' do
    it 'define none of the three classes any more' do
      stray = Dir.glob(File.join(ROOT_FOR_RETIRED, 'lib/redmine_reporter_dashboards/liquid/*.rb'))
                 .select do |path|
        File.read(path, encoding: 'UTF-8')
            .match?(/^\s*(?:class|module)\s+(?:VersionDrop|IssueDropPatch|CustomFieldValueDrop)\b/)
      end

      expect(stray).to be_empty,
                       'these belong under liquid/drops/ if they belong anywhere: ' \
                       "#{stray.map { |p| File.basename(p) }.join(', ')}"
    end

    it 'still hold the owned replacements, under drops/' do
      %w[version_drop custom_field_value_drop custom_field_values_drop issue_drop].each do |name|
        expect(File.exist?(File.join(ROOT_FOR_RETIRED,
                                     "lib/redmine_reporter_dashboards/liquid/drops/#{name}.rb")))
          .to be(true), "drops/#{name}.rb is missing — the replacement went with the thing it replaced"
      end
    end
  end
end
