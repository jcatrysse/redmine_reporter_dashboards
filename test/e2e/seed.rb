# frozen_string_literal: true

# Plugin seed for the end-to-end run (.codex/start_server.sh runs it after .codex/e2e/seed.rb,
# so the users admin/manager/reporter/outsider and the projects e2e-project/e2e-private exist).
# Idempotent: every record is found by name before it is created, so a second start leaves the
# database as the first one did.
Template = RedmineReporterDashboards::Template
Schedule = RedmineReporterDashboards::Schedule

admin    = User.find_by!(login: 'admin')
manager  = User.find_by!(login: 'manager')
project  = Project.find_by!(identifier: 'e2e-project')
private_project = Project.find_by!(identifier: 'e2e-private')
User.current = admin

ISSUE_REPORT = <<~LIQUID
  {% sql_aggregate from: issues, group_by: status, drill: true, assign_to: by_status %}
  {% sql_aggregate from: issues, group_by: tracker, assign_to: by_tracker %}
  {% version_rollup assign_to: versions %}

  <h1>E2E issue report: {{ project.name }}</h1>
  <p>{{ by_status.total }} issues in scope</p>

  <div class="rrd-card">
    {% chart id: status, from: by_status, title: "Issues by status", y_title: "Issues" %}
  </div>
  <div class="rrd-card">
    {% chart id: tracker, from: by_tracker, type: pie, title: "Issues by tracker" %}
  </div>

  {% mermaid id: flow %}
  graph LR
    A[New] --> B{Reviewed?}
    B -->|yes| C[Closed]
    B -->|no| A
  {% endmermaid %}

  <table>
    <thead><tr><th>Status</th><th>Issues</th></tr></thead>
    <tbody>
    {% for bucket in by_status.buckets %}
      <tr><td>{{ bucket.label }}</td><td>{{ bucket.count }}</td></tr>
    {% endfor %}
    </tbody>
  </table>

  <h2>Issues</h2>
  <ul>
  {% for issue in issues %}
    <li>#{{ issue.id }} {{ issue.subject }} ({{ issue.status.name }})</li>
  {% endfor %}
  </ul>
LIQUID

TIME_REPORT = <<~LIQUID
  {% sql_aggregate from: time_entries, group_by: activity, measure: hours, assign_to: by_activity %}
  <h1>E2E time report: {{ project.name }}</h1>
  {% for bucket in by_activity.buckets %}
    <p>{{ bucket.label }}: {{ bucket.value }} h</p>
  {% endfor %}
LIQUID

def e2e_template(name, attrs)
  Template.find_by(name: name) || Template.create!(attrs.merge(name: name))
end

issue_report = e2e_template('E2E issue report',
                            project: project, author: manager, content: ISSUE_REPORT,
                            description: 'Charts, a diagram and a status table',
                            source: 'issues', output: 'combined',
                            visibility: Template::VISIBILITY_PUBLIC)
e2e_template('E2E time report',
             project: project, author: manager, content: TIME_REPORT,
             description: 'Hours per activity', source: 'time_entries', output: 'combined',
             visibility: Template::VISIBILITY_PUBLIC)
e2e_template('E2E private draft',
             project: project, author: manager, content: '<p>Only the author sees this.</p>',
             description: 'Private to its author', source: 'issues', output: 'combined',
             visibility: Template::VISIBILITY_PRIVATE)
e2e_template('E2E report in the private project',
             project: private_project, author: manager, content: ISSUE_REPORT,
             description: 'Must stay invisible to outsiders', source: 'issues', output: 'combined',
             visibility: Template::VISIBILITY_PUBLIC)

# Time entries for the time report and the timelog widget.
activity = TimeEntryActivity.where(active: true).order(:position).first
issue = Issue.where(project_id: project.id).order(:id).first
if activity && issue && TimeEntry.where(project_id: project.id).none?
  [[manager, 2.5], [manager, 1.0], [admin, 3.0]].each do |user, hours|
    TimeEntry.create!(project: project, issue: issue, user: user, author: user,
                      activity: activity, hours: hours, spent_on: issue.start_date || Date.today,
                      comments: 'E2E time')
  end
end

if Schedule.where(template_id: issue_report.id).none?
  schedule = Schedule.new(project: project, template: issue_report, author: manager,
                          email_subject: 'E2E daily issue report', repeat: 'daily',
                          start_date: Date.today, enabled: true, render_as: 'author',
                          timezone: 'UTC')
  schedule.recipient_users = [manager]
  schedule.save!
end

puts "E2E plugin seed: #{Template.count} templates, #{Schedule.count} schedules, " \
     "#{TimeEntry.where(project_id: project.id).count} time entries"
