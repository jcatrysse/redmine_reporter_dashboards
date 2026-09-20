# Verification — which project a report is about

Measured 2026-09-18 and re-measured independently twice on 2026-09-19.
Redmine 5.1.13-stable, PostgreSQL 16, Ruby 3.2.6, the stock Redmine test fixtures.
**Only 5.1 was executed.** 6.0, 6.1 and 7.0 are CI's to confirm.

## Fixture facts the numbers depend on

* project 1's descendants are 3, 4, 5, 6 (6 through 5)
* **project 2 has no parent — it is a sibling of project 1, and the only place a row can fall
  outside project 1's subtree.** A measurement that uses project 3 as "elsewhere" proves nothing,
  and one earlier measurement in this repository was a false negative for exactly that reason
* 14 issues are visible to `admin`: 7 in project 1, 1 in project 2
* `Setting.display_subprojects_issues` ships as `1` (`redmine/config/settings.yml:229`)

## The recipe

```ruby
# cd <redmine> && RAILS_ENV=test bundle exec rails runner <this>
actor = User.find_by!(login: 'admin'); User.current = actor
p1 = Project.find(1)
RS  = RedmineReporterDashboards::Reporting::ReportScope
TPL = Struct.new(:source)

gq = IssueQuery.create!(name: 'probe', project: nil, user: User.find(1), visibility: 2)

def shape(scope)
  return '-' if scope.nil?
  "#{scope.count} #{scope.reorder(nil).distinct.pluck(:project_id).sort.inspect}"
end

# What Redmine's own issue list does: refuse a foreign query, then assign the project.
def redmine_list(query, project)
  return :refused if query.project_id && project && query.project_id != project.id
  q = IssueQuery.find(query.id)
  q.project = project
  q.base_scope
end

%w[1 0].each do |flag|
  Setting.display_subprojects_issues = flag
  puts "setting=#{flag}"
  puts "  redmine list, global query, in project 1 : #{shape(redmine_list(gq, p1))}"
  puts "  redmine list, global query, no project   : #{shape(redmine_list(gq, nil))}"
  puts "  plugin project surface                   : " \
       "#{shape(RS.build(template: TPL.new('issues'), actor: actor, project: p1, query_id: gq.id).first)}"
  puts "  plugin my-page                           : " \
       "#{shape(RS.build(template: TPL.new('issues'), actor: actor, project: nil, query_id: gq.id).first)}"
end
Setting.display_subprojects_issues = '1'
```

## What it answers

```
setting=1
  redmine list, global query, in project 1 : 10 [1, 3, 5]
  redmine list, global query, no project   : 11 [1, 2, 3, 5]
  plugin project surface                   : 10 [1, 3, 5]
  plugin my-page                           : 11 [1, 2, 3, 5]
setting=0
  redmine list, global query, in project 1 : 4 [1]
  redmine list, global query, no project   : 11 [1, 2, 3, 5]
  plugin project surface                   : 10 [1, 3, 5]     <- D-1, ignores the setting
  plugin my-page                           : 11 [1, 2, 3, 5]  <- D-2, unbounded
```

`redmine_list` is a stand-in for `QueriesHelper#retrieve_query` (`redmine/app/helpers/queries_helper.rb:345-355`),
which refuses a query belonging to another project and then assigns the current one. The refusal is
why a foreign query cannot be rendered under the wrong project in Redmine itself.
