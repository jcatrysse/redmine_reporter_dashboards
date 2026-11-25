# OpenAI review befdeba

Model `gpt-5`, range `6344a92..befdeba`, 25 file(s), 1 request(s), 49953 tokens.

Add a `Resolution:` line under every finding: fixed in <commit>, or why not.

## Part 1 of 1

Major, lib/redmine_reporter_dashboards/aggregation/field_visibility.rb:209 (scrub_sentinels)
- Problem: Sentinel scrubbing compares against ["-1", "__rrd_hidden__"] but result entries may carry the hidden-bucket key as an Integer -1 (DB/type-dependent) or include Integer -1 in b.values. In that case the sentinel is not scrubbed, and templates can see -1 in b.value or in values for “Other”, contrary to the “no value leaks” guarantee.
- Failure scenario: On a MySQL/MariaDB install where the CASE for an id dimension returns an integer, a template like:
  {% sql_aggregate group_by: assignee drill: true assign_to: s %}{% for b in s.buckets %}[{{ b.value }}]{% endfor %}
  will render “[-1]” for the hidden bucket instead of “[]”, exposing the internal marker. Likewise, when a hidden bucket is folded into “Other”, b.values can contain -1.
- Fix: Scrub both integer and string sentinels. For example:
  keys_str = [SqlAggregation::QueryAggregator::HIDDEN_ID_KEY.to_s, SqlAggregation::QueryAggregator::HIDDEN_TEXT_KEY]
  keys_any = [SqlAggregation::QueryAggregator::HIDDEN_ID_KEY, *keys_str]
  ...
  entry['value'] = nil if keys_any.include?(entry['value'])
  entry['values'] = Array(entry['values']).reject { |v| keys_any.include?(v) || keys_str.include?(v.to_s) }
  This makes scrubbing robust across adapters and CASE coercions.
- Resolution: not changed. The kernel stringifies both before the scrub runs on every adapter: `raw_value` returns `key.to_s` and `collapsed_values` maps `to_s` (`query_aggregator.rb`, drill-through descriptors), so an Integer -1 never reaches `value` or `values`. The PostgreSQL tests assert `[]` for both (`test_drill_down_links_do_not_reveal_the_hidden_values`, `test_the_hidden_bucket_folded_into_other_leaves_no_trace_in_its_values`); MySQL/MariaDB were not run, recorded in the plan.
