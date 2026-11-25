# frozen_string_literal: true

# Realistic data for the UX review mockups (docs/ux-review-2026-11). Run AFTER
# .codex/start_server.sh has seeded its users and projects:
#
#   (cd redmine && RAILS_ENV=production bundle exec rails runner \
#      ../docs/ux-review-2026-11/mockup/seed.rb)
#
# LOCAL CHECKOUT ONLY, AND NOT HARMLESS: it rebuilds e2e-project's dashboard tabs when they
# are not exactly Overview/Charts/Versions (delete_all), and it resets the passwords of the
# users it creates (anna, pieter, sofie, tom, viewer). Records are otherwise found by name
# first, so a second run adds nothing. Dates are relative to today on purpose (a live-looking
# project), so a re-run does not reproduce the screenshots byte for byte.
Template = RedmineReporterDashboards::Template
Schedule = RedmineReporterDashboards::Schedule

admin   = User.find_by!(login: 'admin')
manager = User.find_by!(login: 'manager')
project = Project.find_by!(identifier: 'e2e-project')
User.current = admin
password = ENV.fetch('RMP_USER_PASSWORD', ENV.fetch('RMP_ADMIN_PASSWORD', 'Redmine7Test!'))

def ux_user(login, first, last, password)
  user = User.find_by(login: login) || User.new(login: login, firstname: first, lastname: last,
                                                 mail: "#{login}@example.net")
  user.password = user.password_confirmation = password
  user.must_change_passwd = false
  user.status = User::STATUS_ACTIVE
  user.save!(validate: false)
  user
end

developer = Role.find_by(name: 'Developer') || Role.givable.first
devs = [%w[anna Anna Janssens], %w[pieter Pieter Desmet], %w[sofie Sofie Maes], %w[tom Tom Claes]].map do |l, f, n|
  u = ux_user(l, f, n, password)
  Member.create!(principal: u, project: project, roles: [developer]) unless Member.where(user_id: u.id, project_id: project.id).exists?
  u
end

# A reader of the dashboard who may not change anything: core Reporter + the plugin's view
# permissions only.
viewer_role = Role.find_by(name: 'UX dashboard viewer') || Role.new(name: 'UX dashboard viewer', assignable: false)
reporter_role = Role.find_by(name: 'Reporter')
viewer_role.permissions = (reporter_role ? reporter_role.permissions : %i[view_issues]) +
                          %i[view_reporter_project_page view_reporter_dashboards_reports
                             view_reporter_dashboards_schedules view_time_entries view_news]
viewer_role.permissions.uniq!
viewer_role.issues_visibility = 'all'
# Own time entries only, so the time widget shows the S-14 narrowing notice to this reader.
viewer_role.time_entries_visibility = 'own' if viewer_role.respond_to?(:time_entries_visibility=)
viewer_role.save!
viewer = ux_user('viewer', 'Vera', 'Viewer', password)
Member.create!(principal: viewer, project: project, roles: [viewer_role]) unless Member.where(user_id: viewer.id, project_id: project.id).exists?

v1 = Version.find_by(project_id: project.id, name: 'E2E 1.0')
v11 = Version.find_by(project_id: project.id, name: '1.1') ||
      Version.create!(project: project, name: '1.1', effective_date: Date.today + 60, description: 'Reporting polish')
v20 = Version.find_by(project_id: project.id, name: '2.0') ||
      Version.create!(project: project, name: '2.0', effective_date: Date.today + 150, description: 'Redmine 7 release')
versions = [v1, v11, v20].compact

trackers   = project.trackers.to_a
statuses   = IssueStatus.sorted.to_a
priorities = IssuePriority.active.to_a
assignees  = devs + [manager, nil]
subjects = [
  'Export fails for projects with archived subprojects', 'Add CSV export to time report',
  'Chart legend overlaps on small screens', 'Weekly status mail arrives twice',
  'Upgrade to Rails 8.1', 'Gantt shows wrong end date for closed versions',
  'Translate dashboard labels to Dutch', 'Improve PDF page breaks in long tables',
  'Spent time widget ignores the date filter', 'Allow sorting of report templates',
  'Version roadmap: show remaining hours', 'Search returns private issues to reporters',
  'Customer portal: login with SSO', 'Reduce queries on the issue list',
  'Attachment preview for DXF drawings', 'Survey vessel schedule import',
  'Crew rotation report per month', 'Missing audit trail on budget changes',
  'Move nightly backups to object storage', 'Dashboard tab order not saved',
  'Email notifications for watchers of parent issues', 'Activity filter for documents',
  'Timesheet approval workflow', 'Invoice export to accounting', 'Broken link in user guide',
  'Mobile layout of the issue form', 'Custom field for vessel name', 'Duplicate news entries',
  'Planning board drag and drop is slow', 'Report template preview times out',
  'Add hours budget per version', 'Wiki macro for open issues', 'Clean up unused trackers',
  'Weekly KPI mail to management', 'Equipment calibration reminders',
  'Show project manager on overview', 'Import issues from spreadsheet',
  'Holiday calendar per country', 'Dark mode contrast in tables', 'Role overview per project'
]
rng = Random.new(42)
subjects.each_with_index do |subject, i|
  next if Issue.exists?(project_id: project.id, subject: subject)

  tracker = trackers[i % trackers.size]
  issue = Issue.new(project: project, tracker: tracker, subject: subject, author: [manager, admin, *devs][i % 6],
                    priority: priorities[[0, 1, 1, 1, 2, 2, 3][i % 7]] || priorities.first,
                    description: "#{subject}.\n\nSteps and context are in the attached notes.",
                    assigned_to: assignees[i % assignees.size], fixed_version: versions[i % versions.size],
                    start_date: Date.today - rng.rand(5..60), estimated_hours: [2, 4, 8, 16, nil][i % 5])
  issue.due_date = issue.start_date + rng.rand(10..90)
  issue.status = tracker.default_status
  issue.save!
  status = statuses[[0, 0, 1, 1, 1, 2, 3, 4, 4, 0, 1][i % 11]] || statuses.first
  issue.reload
  issue.init_journal(issue.assigned_to || manager, i.even? ? 'Checked with the customer, details above.' : nil)
  issue.status = status
  issue.done_ratio = status.is_closed? ? 100 : [0, 10, 30, 50, 80][i % 5]
  issue.save!
end

activities = TimeEntryActivity.active.to_a
if TimeEntry.where(project_id: project.id, comments: 'UX review time').none?
  Issue.where(project_id: project.id).order(:id).each_with_index do |issue, i|
    next if i % 3 == 2

    (1 + i % 3).times do |k|
      user = issue.assigned_to.is_a?(User) ? issue.assigned_to : devs[i % devs.size]
      TimeEntry.create!(project: project, issue: issue, user: user, author: user,
                        activity: activities[(i + k) % activities.size], hours: [0.5, 1, 1.5, 2, 3, 4, 6][(i + k) % 7],
                        spent_on: Date.today - ((i * 3 + k) % 40), comments: 'UX review time')
    end
  end
end

if News.where(project_id: project.id).none?
  News.create!(project: project, author: manager, title: 'Redmine 7 migration planned for December',
               summary: 'Downtime of about one hour.', description: 'The upgrade runs on a Saturday morning.')
  News.create!(project: project, author: manager, title: 'New weekly status report',
               summary: 'Sent every Monday to the project team.', description: 'See the dashboard.')
end

def ux_query(klass, name, project, user, filters, extra = {})
  q = klass.find_by(project_id: project.id, name: name) || klass.new(project: project, name: name, user: user)
  q.visibility = Query::VISIBILITY_PUBLIC
  q.filters = filters
  extra.each { |k, v| q.send("#{k}=", v) }
  q.save!
  q
end
open_q = ux_query(IssueQuery, 'UX open issues', project, manager, { 'status_id' => { operator: 'o', values: [''] } })
bug_tracker = trackers.find { |t| t.name == 'Bug' } || trackers.first
ux_query(IssueQuery, 'Open bugs', project, manager,
         { 'status_id' => { operator: 'o', values: [''] }, 'tracker_id' => { operator: '=', values: [bug_tracker.id.to_s] } })
time_q = ux_query(TimeEntryQuery, 'Time last 30 days', project, manager, { 'spent_on' => { operator: '>t-', values: ['30'] } })

starter = ->(file) { File.read(File.join(RedmineReporterDashboards::StarterGallery.const_get(:ENTRIES).find { |e| e.file == file }&.then { |e| RedmineReporterDashboards::StarterGallery.path(e) })) }
def ux_template(name, attrs)
  Template.find_by(name: name) || Template.create!(attrs.merge(name: name, visibility: Template::VISIBILITY_PUBLIC))
end
tpl = {}
tpl[:summary] = ux_template('Open work summary', project: project, author: manager, content: starter.call('aggregate-report.liquid'),
                            description: 'Open issues per status, tracker and assignee', source: 'issues', output: 'combined')
tpl[:charts] = ux_template('Status charts', project: project, author: manager, content: starter.call('chart-report.liquid'),
                           description: 'Issues by status and tracker as charts', source: 'issues', output: 'combined')
tpl[:sheet] = ux_template('Issue sheet', project: project, author: manager, content: starter.call('issue-document.liquid'),
                          description: 'One printable page per issue', source: 'issues', output: 'per_record')
tpl[:time] = ux_template('Time by activity', project: project, author: manager, content: starter.call('spent-time-report.liquid'),
                         description: 'Hours per activity and per person', source: 'time_entries', output: 'combined')
tpl[:versions] = ux_template('Release status', project: project, author: manager, content: starter.call('version-status.liquid'),
                             description: 'Progress of every open version', source: 'issues', output: 'combined')

if Schedule.where(template_id: tpl[:summary].id).none?
  s = Schedule.new(project: project, template: tpl[:summary], author: manager, email_subject: 'Weekly open work summary',
                   repeat: 'weekly', start_date: Date.today, enabled: true, render_as: 'author', timezone: 'Europe/Brussels')
  s.save!
  s.recipient_users = [manager, devs.first]
end

# The dashboard: three tabs whose rows hold 1, 2 and 3 widgets.
# Rebuilt only when the tab set is not the expected one, so tab ids stay stable across runs.
unless ReporterProjectTab.where(project_id: project.id).order(:position).pluck(:title) == %w[Overview Charts Versions]
ReporterProjectTab.where(project_id: project.id).delete_all
def ux_tab(project, title, position, layout, settings)
  tab = ReporterProjectTab.new(project: project, title: title)
  tab.layout = layout
  tab.settings = settings
  tab.save!
  tab.update_column(:position, position) if tab.respond_to?(:position)
  tab
end
ux_tab(project, 'Overview', 1,
       [%w[report_by_issues], %w[issuesassignedtome timelog], %w[news activity report_by_issues__1]],
       { 'report_by_issues' => { report_template_id: tpl[:summary].id, query_id: open_q.id } })
ux_tab(project, 'Charts', 2,
       [%w[report_by_issues], %w[report_by_issues__1 report_by_spent_time], %w[report_by_issues__2 report_by_issues__3 report_by_spent_time__1]],
       { 'report_by_issues' => { report_template_id: tpl[:charts].id, query_id: open_q.id },
         'report_by_issues__1' => { report_template_id: tpl[:summary].id },
         'report_by_spent_time' => { report_template_id: tpl[:time].id, query_id: time_q.id },
         'report_by_issues__2' => { report_template_id: tpl[:charts].id } })
ux_tab(project, 'Versions', 3,
       [%w[report_by_issues], %w[report_by_issues__1 report_by_spent_time]],
       { 'report_by_issues' => { report_template_id: tpl[:versions].id } })
end

puts "UX seed: #{Issue.where(project_id: project.id).count} issues, #{TimeEntry.where(project_id: project.id).count} time entries, " \
     "#{Template.where(project_id: project.id).count} templates, #{ReporterProjectTab.where(project_id: project.id).count} tabs"

# A few sent reports, so the "Sent reports" list has rows (an audit row, written as the
# mail controller would after a send).
MailSend = RedmineReporterDashboards::MailSend
if MailSend.where(project_id: project.id).none?
  [[tpl[:summary], 3, 2, 'success'], [tpl[:charts], 1, 4, 'success'], [tpl[:versions], 5, 9, 'success'],
   [tpl[:sheet], 2, 12, 'failed']].each do |t, recipients, days, status|
    at = Time.now - days.days
    MailSend.create!(author_id: manager.id, project_id: project.id, template_id: t.id, template_name: t.name,
                     source: t.source, status: status, recipients_count: recipients, external_count: 0,
                     document_count: status == 'success' ? 1 : 0, created_at: at, finished_at: at + 4,
                     correlation_id: status == 'failed' ? 'b7e2c91f' : nil,
                     error: status == 'failed' ? 'The render engine did not answer within 60 seconds.' : nil)
  end
end
