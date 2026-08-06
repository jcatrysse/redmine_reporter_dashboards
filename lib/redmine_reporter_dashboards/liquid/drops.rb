# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # The owned drop layer (R6, `technical-spec.md` §3).
    #
    # One require away from the whole vocabulary, because a caller that has to know
    # which of thirteen files to require is a caller that will require twelve.
    #
    # --- THE INVENTORY, AND WHY IT IS A CONSTANT ---
    #
    # §3.1 names the classes to keep and the classes to drop. `CLASSES` below is that
    # decision in executable form: `spec_liquid/drops_spec.rb` asserts the list, so
    # adding a fourteenth drop or quietly reviving `JournalDrop` fails a test rather
    # than passing review. The gem shipped 17; seven were dropped with a reason
    # (`IssueRelation(s)`, `Journal(s)` — OQ-H, narrowed — `News(s)`, whose double-`s`
    # typo is itself disqualifying, and `CustomFieldEnumeration`, folded in).
    module Drops
      # The three bases and the twelve concrete drops.
      #
      # §3.1's header says "13 + 3 bases" and its own list enumerates ELEVEN keeps
      # (`Issue Issues User Users Project Projects Version TimeEntry TimeEntries
      # Attachment CustomFieldValue`). The header and the list disagree, and the list is
      # the specific one, so the list is what was built — plus `CustomFieldValues`, the
      # bracket-lookup sibling that carries the addon's existing
      # `issue.custom_field_value[20]` surface across T-20's deletion of
      # `issue_drop_patch.rb`. That makes twelve. The discrepancy is recorded in
      # `implementation-plan.md` §Findings (F-9) rather than resolved by picking a
      # number that matches.
      BASES = %w[RecordDrop CollectionDrop NamedRefDrop].freeze

      CLASSES = %w[
        IssueDrop IssuesDrop
        UserDrop UsersDrop
        ProjectDrop ProjectsDrop
        VersionDrop
        TimeEntryDrop TimeEntriesDrop
        AttachmentDrop
        CustomFieldValueDrop CustomFieldValuesDrop
      ].freeze

      # What the gem had and this layer deliberately does not, each with the reason
      # §3.1 gives. Asserted by spec, so a later session that "adds the missing
      # JournalDrop" has to delete a line that says why it is missing.
      DROPPED = {
        'IssueRelationDrop' => 'OQ-H, narrowed: not part of the six required capabilities',
        'IssueRelationsDrop' => 'OQ-H, narrowed: not part of the six required capabilities',
        'JournalDrop' => 'OQ-H, narrowed: not part of the six required capabilities',
        'JournalsDrop' => 'OQ-H, narrowed: not part of the six required capabilities',
        'NewsDrop' => 'the dashboard has a native news widget',
        'NewssDrop' => 'the double-s typo is itself disqualifying; native news widget',
        'CustomFieldEnumerationDrop' => 'folded into CustomFieldValueDrop'
      }.freeze
    end
  end
end

require_relative 'drops/string_substitutable'
require_relative 'drops/absolute_url'
require_relative 'drops/named_ref_drop'
require_relative 'drops/record_drop'
require_relative 'drops/collection_drop'
require_relative 'drops/attachment_drop'
require_relative 'drops/custom_field_value_drop'
require_relative 'drops/custom_field_values_drop'
require_relative 'drops/project_drop'
require_relative 'drops/projects_drop'
require_relative 'drops/user_drop'
require_relative 'drops/users_drop'
require_relative 'drops/version_drop'
require_relative 'drops/time_entry_drop'
require_relative 'drops/time_entries_drop'
require_relative 'drops/issue_drop'
require_relative 'drops/issues_drop'
