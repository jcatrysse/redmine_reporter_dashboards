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

ISSUE_REPORT = <<~'LIQUID'
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

TIME_REPORT = <<~'LIQUID'
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
if activity && issue && TimeEntry.where(project_id: project.id, comments: 'E2E plugin time').none?
  [[manager, 2.5], [manager, 1.0], [admin, 3.0]].each do |user, hours|
    TimeEntry.create!(project: project, issue: issue, user: user, author: user,
                      activity: activity, hours: hours, spent_on: issue.start_date || Date.today,
                      comments: 'E2E plugin time')
  end
end

if Schedule.where(template_id: issue_report.id).none?
  schedule = Schedule.new(project: project, template: issue_report, author: manager,
                          email_subject: 'E2E daily issue report', repeat: 'daily',
                          start_date: Date.today, enabled: true, render_as: 'author',
                          timezone: 'UTC')
  schedule.save!
  schedule.recipient_users = [manager] # needs the schedule's id
end

# To-do lists of redmine_issue_todo_lists2 in a report (Jan, 2026-10-07, round 2). The
# template is seeded always: without the todo plugin it must render with every list empty.
# The list, and the member who may read reports but not to-do lists, only when it is there.
TODO_REPORT = <<~'LIQUID'
  <h1>E2E to-do lists</h1>
  <table>
    <thead><tr><th>Issue</th><th>To-do lists</th><th>Count</th></tr></thead>
    <tbody>
    {% for issue in issues %}
      <tr><td>#{{ issue.id }} {{ issue.subject }}</td>
          <td>{% for list in issue.todolists_with_positions.items %}{{ list.title | escape }} (position {{ list.position }}){% unless forloop.last %}, {% endunless %}{% endfor %}</td>
          <td>{{ issue.todolists_with_positions.size }}</td></tr>
    {% endfor %}
    </tbody>
  </table>
LIQUID
e2e_template('E2E to-do lists',
             project: project, author: manager, content: TODO_REPORT,
             description: 'The to-do lists each issue is on', source: 'issues', output: 'combined',
             visibility: Template::VISIBILITY_PUBLIC)

if Object.const_defined?(:IssueTodoList)
  list = IssueTodoList.find_by(project_id: project.id, title: 'E2E sprint') ||
         IssueTodoList.create!(project: project, title: 'E2E sprint', description: 'Seeded for e2e')
  ['E2E assigned issue', 'E2E unassigned issue'].each_with_index do |subject, index|
    listed = Issue.find_by!(project_id: project.id, subject: subject)
    next if IssueTodoListItem.where(issue_todo_list_id: list.id, issue_id: listed.id).exists?

    IssueTodoListItem.create!(issue_todo_list: list, issue: listed, position: index + 1)
  end

  # Every permission of "E2E full" except the todo plugin's own: reports yes, to-do lists no.
  # Not `modules_permissions`: that also returns every permission without a module.
  todo_permissions = Redmine::AccessControl.permissions
                                           .select { |p| p.project_module.to_s == 'issue_todo_lists' }
                                           .map(&:name)
  listless_role = Role.find_by(name: 'E2E without to-do lists') ||
                  Role.new(name: 'E2E without to-do lists', assignable: true)
  listless_role.permissions = Role.find_by!(name: 'E2E full').permissions - todo_permissions
  listless_role.issues_visibility = 'all'
  listless_role.save!
  listless = User.find_by(login: 'listless') ||
             User.new(login: 'listless', firstname: 'Listless', lastname: 'E2E', mail: 'listless@example.net')
  listless.password = listless.password_confirmation =
    ENV.fetch('RMP_USER_PASSWORD', ENV.fetch('RMP_ADMIN_PASSWORD', 'Redmine7Test!'))
  listless.must_change_passwd = false
  listless.status = User::STATUS_ACTIVE
  listless.save!(validate: false)
  unless Member.where(user_id: listless.id, project_id: project.id).exists?
    Member.create!(principal: listless, project: project, roles: [listless_role])
  end
end

# The base plugin's accessors, restored 2026-11-25 (Jan, option A): GEOxyz's journal idioms,
# a relation into the private project, and, when installed, redmine_tags, redmine_agile,
# redmine_checklists and redmine_contacts_helpdesk data. Who sees what is the scenario's
# question (test/e2e/base_accessors.mjs), so the template prints everything it can.
BASE_REPORT = <<~'LIQUID'
  <h1>E2E base accessors</h1>
  {% for issue in issues %}{% if issue.subject == "E2E assigned issue" %}
  <h2>#{{ issue.id }} {{ issue.subject }}</h2>
  <p>Description: {{ issue.description | size }} characters</p>
  <h3>Journals ({{ issue.journals.all | size }})</h3>
  {% for journal in issue.journals.all %}<div class="journal"><em>{{journal.created_on | date: "%a, %b %d, %y"}} - {{journal.user.name}}</em> {{journal.notes | textilize }}</div>{% endfor %}
  {% assign last_comment = issue.journals.all|sort:'created_on'|reverse|first %}
  <p>Last comment: {{ last_comment.notes }}</p>
  <h3>Relations</h3>
  {% for r in issue.relations_from %}<p>{{ r.relation_type }} #{{ r.issue_to.id }} {{ r.issue_to.subject }}</p>{% endfor %}
  <h3>Other plugins</h3>
  <p>Tags: [{{ issue.tags | join: ", " }}] Story points: [{{ issue.story_points }}] Colour: [{{ issue.color }}]</p>
  <p>Checklist: {% for c in issue.checklists %}[{{ c.subject }} {% if c.is_done %}done{% else %}open{% endif %}]{% endfor %}</p>
  <p>Helpdesk: [{{ issue.helpdesk_ticket.from_address }}]</p>
  {% endif %}{% endfor %}
LIQUID
e2e_template('E2E base accessors',
             project: project, author: manager, content: BASE_REPORT,
             description: "The base plugin's journals, relations and plugin accessors",
             source: 'issues', output: 'combined', visibility: Template::VISIBILITY_PUBLIC)

assigned = Issue.find_by!(project_id: project.id, subject: 'E2E assigned issue')
if assigned.journals.where(notes: 'E2E private note, *manager only*').none?
  assigned.reload.init_journal(manager, 'E2E private note, *manager only*')
  assigned.current_journal.private_notes = true
  assigned.save!
end
hidden = Issue.find_by!(project_id: private_project.id, subject: 'E2E private issue')
unless IssueRelation.where(issue_from_id: assigned.id, issue_to_id: hidden.id).exists?
  Setting.cross_project_issue_relations = '1'
  IssueRelation.create!(issue_from: assigned, issue_to: hidden, relation_type: 'blocks')
end
assigned.reload
if assigned.respond_to?(:tag_list) && assigned.tag_list.empty?
  assigned.tag_list = 'e2e, customer'
  assigned.save!
end
if assigned.respond_to?(:agile_data) && assigned.agile_data.story_points.nil?
  assigned.agile_data.update!(story_points: 3)
  AgileColor.create!(container: assigned, color: 'green') if Object.const_defined?(:AgileColor)
end
if Object.const_defined?(:Checklist) && Checklist.where(issue_id: assigned.id).none?
  Checklist.create!(issue_id: assigned.id, subject: 'E2E order parts', is_done: true, position: 1)
  Checklist.create!(issue_id: assigned.id, subject: 'E2E fit parts', is_done: false, position: 2)
end
if Object.const_defined?(:HelpdeskTicket) && Object.const_defined?(:Contact) &&
   HelpdeskTicket.where(issue_id: assigned.id).none?
  contact = Contact.find_by(email: 'client@e2e.example') ||
            Contact.create!(first_name: 'E2E', last_name: 'Client', email: 'client@e2e.example',
                            projects: [project], visibility: 0)
  HelpdeskTicket.create!(issue_id: assigned.id, contact: contact, from_address: 'client@e2e.example',
                         ticket_date: Time.now.utc)
end

# "notesless": every permission of "E2E full" except private notes, checklists and the helpdesk
# (and with redmine_view_issue_description, also without the right to open an issue: "closed").
password = ENV.fetch('RMP_USER_PASSWORD', ENV.fetch('RMP_ADMIN_PASSWORD', 'Redmine7Test!'))
def e2e_member(login, role_name, without, project, password)
  role = Role.find_by(name: role_name) || Role.new(name: role_name, assignable: true)
  role.permissions = Role.find_by!(name: 'E2E full').permissions - without
  role.issues_visibility = 'all'
  role.save!
  user = User.find_by(login: login) ||
         User.new(login: login, firstname: login.capitalize, lastname: 'E2E', mail: "#{login}@example.net")
  user.password = user.password_confirmation = password
  user.must_change_passwd = false
  user.status = User::STATUS_ACTIVE
  user.save!(validate: false)
  Member.create!(principal: user, project: project, roles: [role]) unless Member.where(user_id: user.id, project_id: project.id).exists?
end
e2e_member('notesless', 'E2E without private notes',
           %i[view_private_notes view_checklists view_helpdesk_tickets], project, password)
if Redmine::AccessControl.permission(:view_issue_description)
  e2e_member('closed', 'E2E may not open issues', %i[view_issue_description view_watched_issues], project, password)
end

puts "E2E plugin seed: #{Template.count} templates, #{Schedule.count} schedules, " \
     "#{TimeEntry.where(project_id: project.id).count} time entries"
