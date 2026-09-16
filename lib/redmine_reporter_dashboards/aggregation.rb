# frozen_string_literal: true

require_relative 'aggregation/query_aggregator'
require_relative 'aggregation/drill_through'
# T-31's owned time-entry aggregator. NOT a kernel file — it is not in
# `spec/golden/baseline.rb`'s `KERNEL_FILES`, carries no byte-identity obligation, and
# declares its own namespace properly (`RedmineReporterDashboards::Aggregation::…`) rather
# than the legacy `SqlAggregation`, because nothing freezes it.
require_relative 'aggregation/time_entry_aggregator'

module RedmineReporterDashboards
  # The namespace assignment T-08 asks for, and nothing else.
  #
  # The two files under `aggregation/` are **byte-identical** to their v0.5.0 blobs —
  # `spec/golden/baseline_spec.rb` asserts it against raw `git show` output, and the
  # `corpus` CI job runs that from the plugin checkout on every pull request. They
  # therefore still open `module SqlAggregation`, because changing the module line
  # would be changing a byte.
  #
  # So the new name is an ASSIGNMENT rather than a re-declaration. Four lines, no
  # behaviour, nothing to review. `RedmineReporterDashboards::Aggregation::QueryAggregator`
  # and `SqlAggregation::QueryAggregator` are the same object: `.equal?` is true, a
  # constant memo on one is visible through the other, and `is_a?` answers identically.
  # A `class ... < SqlAggregation::QueryAggregator` wrapper would not have that
  # property, and the whole point of a byte-identical port is that nothing observable
  # moves with it.
  #
  # --- Why the files could move at all ---
  #
  # `technical-spec.md` §1.1 puts them at `aggregation/`, and this repository's HANDOVER
  # carried a trap saying a plugin's `lib/` is Zeitwerk-managed, which would make a path
  # that does not match `SqlAggregation` a boot error. **That trap does not apply here
  # and the move measured it**: `init.rb:20-21` has told Zeitwerk to `ignore` this
  # plugin's whole `lib/` since the initial commit, so nothing under it is autoloaded and
  # every file is reached by an explicit `require`. The constraint is real for `app/`,
  # which is why the trap was written; it is not real for `lib/`.
  #
  # Re-indenting the two files to sit under a nested module is explicitly a LATER,
  # separate, mechanical commit (T-08: "only after `corpus` has been green a full
  # release cycle, and reverted rather than fixed if it goes red").
  module Aggregation
    QueryAggregator = ::SqlAggregation::QueryAggregator
    DrillThrough    = ::SqlAggregation::DrillThrough
    # `TimeEntryAggregator` needs no assignment: it is declared inside this module by its
    # own file, which is what a file NOT under a byte-identity gate is free to do.
  end
end
