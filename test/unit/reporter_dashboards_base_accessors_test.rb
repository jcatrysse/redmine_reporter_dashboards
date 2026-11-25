# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# The base plugin's issue accessors, restored on 2026-11-25 (Jan, option A): `journals`,
# `notes`, `relations_from`, `relations_to`, `tags`, `story_points`, `color`, `day_in_state`,
# `checklists`, `helpdesk_ticket`, and the `textilize` and `tagged_with` filters — rendered
# here against a real Redmine, through `ReportRun`, as a report is rendered.
#
# THE QUESTION IS WHO SEES WHAT. The base plugin read every journal with notes, private
# ones included, and every relation whose other issue the ambient user could see. Here each
# answer is the report ACTOR's: two actors render the same issue and see different journals
# and different relations.
#
# THE PLUGIN-DEPENDENT HALVES ARE DEFINED CONDITIONALLY, NOT SKIPPED, as in
# `reporter_dashboards_todo_lists_test.rb`: CI runs this plugin alone, and a `skip` would
# count a configuration that is absent, not unsupported, against G10. With the plugins
# installed (`redmine_tags`, `redmine_agile`, `redmine_checklists`,
# `redmine_contacts_helpdesk`, `redmine_view_issue_description`) the other halves run.
class ReporterDashboardsBaseAccessorsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :issues, :issue_statuses, :trackers, :projects_trackers,
           :enumerations, :user_preferences

  Template = RedmineReporterDashboards::Template
  ReportRun = RedmineReporterDashboards::Reporting::ReportRun
  Batch = RedmineReporterDashboards::Liquid::Batch

  JOURNALS = '{% for issue in issues %}{{ issue.id }}:' \
             '{% for j in issue.journals %}[{{ j.notes }}]{% endfor %};{% endfor %}'

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @admin = User.find_by!(login: 'admin')
    @manager = User.find(2)   # jsmith: Manager in project 1, Developer in project 2
    @developer = User.find(3) # dlopper: Developer in project 1, nothing in project 2
    Role.find(1).add_permission!(:view_private_notes)
    Role.find(2).remove_permission!(:view_private_notes)
    # With redmine_view_issue_description installed, no fixture role may OPEN an issue
    # until granted; the journal and relation cases are about other rules, so they grant it.
    if Batch.openable_rule?
      [Role.find(1), Role.find(2), Role.anonymous, Role.non_member].each do |role|
        role.add_permission!(:view_issue_description)
      end
    end
    User.current = nil

    # Deterministic rows, whatever earlier tests or fixtures left in these tables.
    Journal.where(journalized_type: 'Issue', journalized_id: [1, 2, 3]).delete_all
    IssueRelation.where(issue_from_id: [1, 2, 3, 4]).or(IssueRelation.where(issue_to_id: [1, 2, 3, 4])).delete_all
    @public_note = journal(1, @developer, 'Public *note*', Time.utc(2026, 1, 5, 23, 30))
    @private_note = journal(1, @manager, 'Manager only', Time.utc(2026, 1, 7, 9, 0), private_notes: true)
    @last_note = journal(1, @admin, 'Last word', Time.utc(2026, 1, 9, 9, 0))
    journal(1, @admin, '', Time.utc(2026, 1, 8, 9, 0)) # no notes: never listed
  end

  def teardown
    User.current = nil
  end

  def journal(issue_id, user, notes, at, private_notes: false)
    created = Journal.create!(journalized: Issue.find(issue_id), user: user, notes: notes,
                              private_notes: private_notes)
    created.update_columns(created_on: at)
    created
  end

  def render(actor, issue_ids, content)
    template = Template.create!(project: @project, author: @admin, name: "base-#{SecureRandom.hex(4)}",
                                content: content, source: 'issues', output: 'combined',
                                visibility: Template::VISIBILITY_PUBLIC)
    scope = Issue.visible(actor).where(id: issue_ids).order(:id)
    outcome = ReportRun.new(template: template, actor: actor, scope: scope,
                            guard: RedmineReporterDashboards::Render::BatchGuard.new)
                       .call(pdf: false)
    assert_nil outcome.diagnostic, outcome.diagnostic&.message
    outcome.sections.first.body.strip
  end

  def statements(&block)
    seen = []
    counter = lambda do |_name, _start, _finish, _id, payload|
      seen << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)
    seen
  end

  # ------------------------------------------------------------------
  # journals and notes: core's visibility, asked as the actor
  # ------------------------------------------------------------------

  def test_a_private_note_is_hidden_from_a_viewer_without_view_private_notes
    assert_equal '1:[Public *note*][Last word];', render(@developer, [1], JOURNALS)
  end

  def test_a_private_note_is_shown_with_view_private_notes
    assert_equal '1:[Public *note*][Manager only][Last word];', render(@manager, [1], JOURNALS)
  end

  # Core's third rule: a private note is visible to its own author.
  def test_a_private_note_is_shown_to_its_author_without_the_permission
    journal(1, @developer, 'My own private', Time.utc(2026, 1, 10, 9, 0), private_notes: true)
    assert_equal '1:[Public *note*][Last word][My own private];', render(@developer, [1], JOURNALS)
  end

  def test_anonymous_reads_the_public_notes_of_a_public_issue_only
    assert_equal '1:[Public *note*][Last word];', render(User.anonymous, [1], JOURNALS)
  end

  def test_notes_lists_the_same_journals_as_strings
    assert_equal 'Public *note*|Last word',
                 render(@developer, [1], '{% for issue in issues %}{{ issue.notes | join: "|" }}{% endfor %}')
  end

  # GEOxyz's templates, unchanged (the survey of Jan's ten templates): `journals.all`,
  # `| date`, `user.name`, `| textilize`, the last-comment idiom and `| size`. The date is
  # in the actor's zone: 23:30 UTC on the 5th is the 6th in Brussels.
  def test_the_geoxyz_journal_idioms_render_unchanged
    @developer.pref.update!(time_zone: 'Brussels')
    out = render(@developer, [1],
                 '{% for issue in issues %}' \
                 '{% for journal in issue.journals.all %}<em>{{journal.created_on | date: "%a, %b %d, %y"}} - ' \
                 '{{journal.user.name}}</em> {{journal.notes | textilize }}{% endfor %}' \
                 "{% assign last_comment = issue.journals.all|sort:'created_on'|reverse|first %}" \
                 '|{{ last_comment.notes }}|{{ issue.journals.all | size }}{% endfor %}')

    assert_includes out, '<em>Tue, Jan 06, 26 - Dave Lopper</em> <p>Public <strong>note</strong></p>'
    assert_includes out, '<em>Fri, Jan 09, 26 - Redmine Admin</em> <p>Last word</p>'
    assert out.end_with?('|Last word|2'), out
  end

  # `textilize` goes through Redmine's sanitising formatter, not the bare RedCloth3 the base
  # plugin called: author HTML in a note is escaped, not passed into the report.
  def test_textilize_escapes_markup_in_a_note
    journal(1, @developer, '<script>alert(1)</script>', Time.utc(2026, 1, 11, 9, 0))
    out = render(@developer, [1], '{% for issue in issues %}{{ issue.journals.last.notes | textilize }}{% endfor %}')
    assert_not_includes out, '<script>'
    assert_includes out, '&lt;script&gt;'
  end

  # ------------------------------------------------------------------
  # relations: only to issues the actor may see
  # ------------------------------------------------------------------

  RELATIONS = '{% for issue in issues %}' \
              '{% for r in issue.relations_from %}{{ r.relation_type }}>{{ r.issue_to.id }} {% endfor %}' \
              '|{% for r in issue.relations_to %}{{ r.issue_from.id }}>{{ r.relation_type }} {% endfor %}' \
              '{% endfor %}'

  def build_relations
    IssueRelation.create!(issue_from: Issue.find(1), issue_to: Issue.find(2), relation_type: 'relates')
    # Issue 4 is in project 2, where the developer is no member.
    with_settings(cross_project_issue_relations: '1') do
      IssueRelation.create!(issue_from: Issue.find(1), issue_to: Issue.find(4), relation_type: 'blocks')
      IssueRelation.create!(issue_from: Issue.find(4), issue_to: Issue.find(1), relation_type: 'precedes', delay: 2)
    end
  end

  def test_a_relation_to_a_hidden_issue_is_left_out
    build_relations
    assert_not Issue.find(4).visible?(@developer), 'precondition: issue 4 is hidden from the developer'
    assert_equal 'relates>2 |', render(@developer, [1], RELATIONS)
  end

  def test_a_viewer_who_sees_both_ends_sees_every_relation
    build_relations
    assert_equal 'relates>2 blocks>4 |4>precedes', render(@manager, [1], RELATIONS)
  end

  def test_the_related_issue_answers_like_any_issue
    build_relations
    out = render(@manager, [1], each_issue('{% for r in issue.relations_to %}{{ r.delay }}/' \
                                           '{{ r.issue_from.subject }}/{{ r.issue_from.status }}{% endfor %}'))
    issue = Issue.find(4)
    assert_equal "2/#{issue.subject}/#{issue.status.name}", out
  end

  # ------------------------------------------------------------------
  # An issue outside the scope: the parent (independent review, 2026-11-25)
  # ------------------------------------------------------------------

  PARENT = '{% for issue in issues %}[{{ issue.parent.id }}][{{ issue.parent.subject }}]' \
           '[{{ issue.parent.journals.size }}][{{ issue.parent.notes | join: "," }}]{% endfor %}'

  def private_parent_of_issue2
    parent = Issue.create!(project: @project, tracker: Tracker.find(1), author: @admin,
                           subject: 'Private parent', is_private: true)
    Issue.find(2).update!(parent_issue_id: parent.id)
    journal(parent.id, @admin, 'Parent note', Time.utc(2026, 1, 13, 9, 0))
    parent
  end

  # The developer sees issue 2 (it is assigned to them) but not its private parent: not the
  # parent, and so not its notes either.
  def test_a_parent_the_actor_may_not_see_is_absent
    parent = private_parent_of_issue2
    assert_not parent.visible?(@developer), 'precondition: the parent is hidden from the developer'
    assert Issue.find(2).visible?(@developer), 'precondition: the child is visible'

    assert_equal '[][][][]', render(@developer, [2], PARENT)
  end

  # The parent is not in the report's scope, and its journals are still its own — not an
  # empty answer from the scope's memo.
  def test_a_visible_parent_outside_the_scope_answers_its_own_journals
    parent = private_parent_of_issue2
    assert_equal "[#{parent.id}][Private parent][1][Parent note]", render(@manager, [2], PARENT)
  end

  # ------------------------------------------------------------------
  # FR-48: query count does not scale with the number of issues
  # ------------------------------------------------------------------

  EVERYTHING = '{% for issue in issues %}{{ issue.id }}{{ issue.description | size }}' \
               '{% for j in issue.journals %}{{ j.notes }}{{ j.user.name }}{{ j.attachments | size }}{% endfor %}' \
               '{{ issue.notes | size }}' \
               '{% for r in issue.relations_from %}{{ r.issue_to.subject }}{{ r.issue_to.status }}{% endfor %}' \
               '{% for r in issue.relations_to %}{{ r.issue_from.subject }}{% endfor %}' \
               '{{ issue.tags | join: "," }}{{ issue.story_points }}{{ issue.color }}{{ issue.day_in_state }}' \
               '{{ issue.checklists | size }}{{ issue.helpdesk_ticket.from_address }}' \
               '{{ issue.helpdesk_ticket.messages | size }}{{ issue.attachments | size }}{% endfor %}'

  def test_the_restored_accessors_cost_the_same_queries_for_three_issues_as_for_seven
    build_relations
    [2, 3, 7, 8].each { |id| journal(id, @admin, "note on #{id}", Time.utc(2026, 1, 12, 9, 0)) }
    IssueRelation.create!(issue_from: Issue.find(7), issue_to: Issue.find(8), relation_type: 'relates')

    render(@manager, [1, 2, 3], EVERYTHING) # warm-up: schema, settings, roles
    few = statements { render(@manager, [1, 2, 3], EVERYTHING) }
    many = statements { render(@manager, [1, 2, 3, 7, 8, 11, 12], EVERYTHING) }

    assert_equal few.length, many.length,
                 "3 issues: #{few.length} queries, 7 issues: #{many.length}\n#{(many - few).join("\n")}"
  end

  # ------------------------------------------------------------------
  # Without the providing plugins: empty, and no query names their tables
  # ------------------------------------------------------------------

  def each_issue(body)
    "{% for issue in issues %}#{body}{% endfor %}"
  end

  unless Batch.related_available?(:tags)
    def test_without_redmine_tags_an_issue_has_no_tags
      queries = statements do
        assert_equal '1:;', render(@admin, [1], each_issue('{{ issue.id }}:{{ issue.tags | join: "," }};'))
      end
      assert_empty queries.grep(/taggings/)
    end

    def test_tagged_with_answers_empty_without_redmine_tags
      assert_equal '', render(@admin, [1, 2], '{% assign t = issues | tagged_with: "urgent" %}' \
                                              '{% for i in t %}{{ i.id }}{% endfor %}')
    end
  end

  unless Batch.related_available?(:story_points)
    def test_without_redmine_agile_story_points_color_and_day_in_state_are_nil
      queries = statements do
        assert_equal '[][][]', render(@admin, [1], each_issue('[{{ issue.story_points }}]' \
                                                              '[{{ issue.color }}][{{ issue.day_in_state }}]'))
      end
      assert_empty queries.grep(/agile_/)
    end
  end

  unless Batch.related_available?(:checklists)
    def test_without_redmine_checklists_there_are_no_checklists
      queries = statements { assert_equal '0', render(@admin, [1], each_issue('{{ issue.checklists | size }}')) }
      assert_empty queries.grep(/checklists/)
    end
  end

  unless Batch.related_available?(:helpdesk_ticket)
    def test_without_the_helpdesk_plugin_there_is_no_ticket
      queries = statements { assert_equal '[]', render(@admin, [1], each_issue('[{{ issue.helpdesk_ticket }}]')) }
      assert_empty queries.grep(/helpdesk_tickets|journal_messages/)
    end
  end

  # ------------------------------------------------------------------
  # With the providing plugins installed
  # ------------------------------------------------------------------

  if Batch.related_available?(:tags)
    def test_redmine_tags_tags_and_tagged_with
      [[1, 'urgent, customer'], [2, 'urgent'], [3, '']].each do |id, list|
        issue = Issue.find(id)
        issue.tag_list = list
        issue.save!
      end
      assert_equal '1:customer,urgent;2:urgent;3:;',
                   render(@developer, [1, 2, 3], '{% for issue in issues %}{{ issue.id }}:' \
                                                 '{{ issue.tags | join: "," }};{% endfor %}')
      assert_equal '1|12|3',
                   render(@developer, [1, 2, 3],
                          '{% assign a = issues | tagged_with: "urgent, customer" %}' \
                          '{% for i in a %}{{ i.id }}{% endfor %}|' \
                          '{% assign b = issues | tagged_with: "urgent", "any" %}' \
                          '{% for i in b %}{{ i.id }}{% endfor %}|' \
                          '{% assign c = issues | tagged_with: "urgent", "exclude" %}' \
                          '{% for i in c %}{{ i.id }}{% endfor %}')
    end
  end

  if Batch.related_available?(:story_points)
    def test_redmine_agile_story_points_color_and_day_in_state
      issue = Issue.find(1)
      issue.agile_data.update!(story_points: 5)
      AgileColor.create!(container: issue, color: 'green')
      issue.reload
      issue.init_journal(@admin)
      issue.status_id = 2
      issue.save!
      issue.journals.order(:id).last.update_columns(created_on: Time.utc(2026, 1, 20, 9, 0))

      out = render(@developer, [1, 2], '{% for issue in issues %}{{ issue.id }}:{{ issue.story_points }}/' \
                                       '{{ issue.color }}/{{ issue.day_in_state | date: "%Y-%m-%d" }};{% endfor %}')
      created = Issue.find(2).created_on.utc.strftime('%Y-%m-%d')
      assert_equal "1:5/green/2026-01-20;2://#{created};", out
    end
  end

  if Batch.related_available?(:checklists)
    def test_redmine_checklists_follow_view_checklists_in_the_project
      Checklist.create!(issue_id: 1, subject: 'Order parts', is_done: true, position: 1)
      Checklist.create!(issue_id: 1, subject: 'Fit', is_done: false, position: 2)
      Role.find(1).add_permission!(:view_checklists)
      Role.find(2).remove_permission!(:view_checklists)
      source = each_issue('{% for c in issue.checklists %}{{ c.subject }}={{ c.id_done }};{% endfor %}')

      assert_equal 'Order parts=true;Fit=false;', render(@manager, [1], source)
      assert_equal '', render(@developer, [1], source)
    end
  end

  if Batch.related_available?(:helpdesk_ticket)
    def test_the_helpdesk_ticket_follows_view_helpdesk_tickets_and_its_contact_view_contacts
      @project.enable_module!(:contacts_helpdesk)
      @project.enable_module!(:contacts)
      Role.find(1).add_permission!(:view_helpdesk_tickets, :view_contacts)
      Role.find(2).add_permission!(:view_helpdesk_tickets)
      Role.find(2).remove_permission!(:view_contacts)
      contact = Contact.create!(first_name: 'Ann', last_name: 'Client', email: 'ann@acme.test',
                                projects: [@project], visibility: 0)
      ticket = HelpdeskTicket.create!(issue_id: 1, contact: contact, from_address: 'ann@acme.test',
                                      ticket_date: Time.utc(2026, 1, 4, 9, 0))
      # The plugin computes the times itself on save; the drop answers them in minutes.
      minutes = ticket.reload.reaction_time.nil? ? '' : (ticket.reaction_time.to_i / 60).to_s
      source = '{% for issue in issues %}[{{ issue.helpdesk_ticket.from_address }}|' \
               '{{ issue.helpdesk_ticket.reaction_time }}|{{ issue.helpdesk_ticket.contact.name }}]{% endfor %}'

      assert_equal "[ann@acme.test|#{minutes}|Ann Client]", render(@manager, [1], source)
      assert_equal "[ann@acme.test|#{minutes}|]", render(@developer, [1], source)
      Role.find(2).remove_permission!(:view_helpdesk_tickets)
      assert_equal '[||]', render(User.find(3), [1], source) # fresh: the old object caches its roles
    end
  end

  # ------------------------------------------------------------------
  # redmine_issue_field_visibility: core fields hidden from the actor (2026-11-25)
  # ------------------------------------------------------------------

  FIELDS = '{% for issue in issues %}[{{ issue.estimated_hours }}][{{ issue.total_estimated_hours }}]' \
           '[{{ issue.assigned_to_id }}][{{ issue.assignee.name }}][{{ issue.priority }}]{% endfor %}'

  # Issue 3 is assigned to the developer; the Developer role hides the estimate and the
  # assignee, the Manager role hides nothing.
  def assert_field_visibility_per_actor
    issue = Issue.find(3)
    issue.update_columns(estimated_hours: 4.5)
    priority = issue.priority.name
    assert_equal "[][][][][#{priority}]", render(User.find(3), [3], FIELDS)
    assert_equal "[4.5][4.5][3][Dave Lopper][#{priority}]", render(User.find(2), [3], FIELDS)
    assert_equal "[4.5][4.5][3][Dave Lopper][#{priority}]", render(@admin, [3], FIELDS)
  end

  if Batch.field_visibility_rule?
    def test_a_core_field_hidden_by_redmine_issue_field_visibility_reads_empty
      with_settings(plugin_redmine_issue_field_visibility: {
                      'hiddenfields' => { '2' => { 'estimated_hours' => '1', 'assigned_to_id' => '1' } }
                    }) do
        assert_field_visibility_per_actor
      end
    end
  else
    # Without the plugin its rule is simulated by the one method the batch calls, with the
    # actor passed in; the constant is removed again in `ensure`.
    def test_a_core_field_hidden_by_redmine_issue_field_visibility_reads_empty
      rule = Module.new do
        def self.hidden_core_fields(user, project = nil)
          return [] if user.admin? || project.nil?

          user.roles_for_project(project).map(&:id) == [2] ? %w[estimated_hours assigned_to_id] : []
        end
      end
      Object.const_set(:RedmineIssueFieldVisibility, rule)
      assert Batch.field_visibility_rule?
      assert_field_visibility_per_actor
    ensure
      Object.send(:remove_const, :RedmineIssueFieldVisibility) if Object.const_defined?(:RedmineIssueFieldVisibility)
    end

    def test_without_redmine_issue_field_visibility_every_core_field_reads
      Issue.find(3).update_columns(estimated_hours: 4.5)
      assert_match(/\A\[4\.5\]\[4\.5\]\[3\]\[Dave Lopper\]\[.+\]\z/, render(User.find(3), [3], FIELDS))
    end
  end

  # ------------------------------------------------------------------
  # Custom fields: core's visible_custom_field_values
  # ------------------------------------------------------------------

  def test_custom_fields_follow_the_role_and_the_trackers_enabled_fields
    restricted = IssueCustomField.create!(name: 'RRD restricted', field_format: 'string', is_for_all: true,
                                          visible: false, role_ids: [1], tracker_ids: [1])
    other_tracker = IssueCustomField.create!(name: 'RRD other tracker', field_format: 'string',
                                             is_for_all: true, visible: true, tracker_ids: [2])
    open_field = IssueCustomField.create!(name: 'RRD open', field_format: 'string', is_for_all: true,
                                          visible: true, tracker_ids: [1])
    [[restricted, 'secret'], [other_tracker, 'stale'], [open_field, 'plain']].each do |field, value|
      CustomValue.create!(customized_type: 'Issue', customized_id: 1, custom_field_id: field.id, value: value)
    end
    source = each_issue('{% for cfv in issue.custom_field_values %}{{ cfv.name }}={{ cfv }};{% endfor %}')

    manager = render(User.find(2), [1], source)
    developer = render(User.find(3), [1], source)

    assert_includes manager, 'RRD restricted=secret;'
    assert_includes manager, 'RRD open=plain;'
    assert_includes developer, 'RRD open=plain;'
    assert_not_includes developer, 'RRD restricted'
    # Issue 1 is a tracker-1 issue: core shows no value of a field enabled only for tracker 2.
    assert_not_includes manager, 'RRD other tracker'
    # Nothing beyond core's own answer, for either actor. (Core also lists available fields
    # with no stored value; the drop lists stored values only, which is not a visibility
    # question.)
    { User.find(2) => manager, User.find(3) => developer }.each do |user, out|
      core = Issue.find(1).visible_custom_field_values(user).map { |v| v.custom_field.name }
      assert_empty out.scan(/([^;=]+)=/).flatten - core, "#{user.login} sees a field core does not show"
    end
  end

  # ------------------------------------------------------------------
  # redmine_view_issue_description: see it, but not open it
  # ------------------------------------------------------------------

  OPENABLE = '{% for issue in issues %}{{ issue.id }}:[{{ issue.description | size }}]' \
             '[{{ issue.journals.size }}][{{ issue.notes | size }}][{{ issue.attachments | size }}];{% endfor %}'

  if Batch.openable_rule? && Batch.related_available?(:helpdesk_ticket)
    # redmine_view_issue_description's helpdesk rule: `view_helpdesk_tickets` alone is not
    # enough for an issue the viewer may not open.
    def test_the_helpdesk_ticket_needs_the_issue_to_be_openable
      @project.enable_module!(:contacts_helpdesk)
      @project.enable_module!(:contacts)
      contact = Contact.create!(first_name: 'Ann', last_name: 'Client', email: 'ann@acme.test',
                                projects: [@project], visibility: 0)
      HelpdeskTicket.create!(issue_id: 1, contact: contact, from_address: 'ann@acme.test',
                             ticket_date: Time.utc(2026, 1, 4, 9, 0))
      Role.find(2).add_permission!(:view_helpdesk_tickets)
      source = each_issue('[{{ issue.helpdesk_ticket.from_address }}]')
      assert_equal '[ann@acme.test]', render(User.find(3), [1], source)

      Role.find(2).remove_permission!(:view_issue_description)
      assert_equal '[]', render(User.find(3), [1], source)
    end
  end

  if Batch.openable_rule?
    # With the real plugin: a role without `view_issue_description` sees the issue in the
    # report and reads none of its description, notes or attachments.
    def test_a_viewer_who_may_not_open_the_issue_reads_no_description_notes_or_attachments
      Role.find(2).add_permission!(:view_issues)
      Role.find(2).remove_permission!(:view_issue_description)
      Role.find(1).add_permission!(:view_issue_description)
      issue = Issue.find(1)
      assert issue.visible?(@developer), 'precondition: the developer sees the issue'
      assert_not issue.detail_access_granted?(@developer), 'precondition: and may not open it'

      assert_equal '1:[0][0][0][0];', render(@developer, [1], OPENABLE)
      assert_match(/\A1:\[[1-9]\d*\]\[3\]\[3\]\[\d+\];\z/, render(@manager, [1], OPENABLE))
    end
  else
    # Without the plugin, its rule is simulated by the two methods the batch calls, so the
    # gate itself is proven here too; `Issue` is restored in `ensure`.
    def test_a_viewer_who_may_not_open_the_issue_reads_no_description_notes_or_attachments
      Attachment.create!(container: Issue.find(1), file: uploaded_test_file('testfile.txt', 'text/plain'),
                         author: @admin)
      developer = @developer
      Issue.define_singleton_method(:vid_openable_ids) do |issues, user|
        user == developer ? [] : issues.map(&:id)
      end
      Issue.define_method(:detail_access_granted?) { |_user| true }
      assert Batch.openable_rule?

      assert_equal '1:[0][0][0][0];', render(@developer, [1], OPENABLE)
      assert_match(/\A1:\[[1-9]\d*\]\[3\]\[3\]\[[1-9]\d*\];\z/, render(@manager, [1], OPENABLE))
    ensure
      if Issue.singleton_class.method_defined?(:vid_openable_ids, false)
        Issue.singleton_class.send(:remove_method, :vid_openable_ids)
      end
      Issue.send(:remove_method, :detail_access_granted?) if Issue.method_defined?(:detail_access_granted?, false)
    end

    def test_without_the_plugin_every_visible_issue_is_open
      assert_not Batch.openable_rule?
      assert_match(/\A1:\[[1-9]\d*\]\[2\]\[2\]\[\d+\];\z/, render(@developer, [1], OPENABLE))
    end
  end
end
