# frozen_string_literal: true

require 'cgi'

require_relative 'record_drop'
require_relative 'attachment_drop'
require_relative 'custom_field_value_drop'
require_relative 'custom_field_values_drop'
require_relative 'project_drop'
require_relative 'time_entry_drop'
require_relative 'user_drop'
require_relative 'version_drop'
require_relative 'todo_lists_drop'
require_relative 'list_drop'
require_relative 'journal_drop'
require_relative 'issue_relation_drop'
require_relative 'helpdesk_ticket_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # The issue, and the class `technical-spec.md` §3.2 writes an explicit disposition
      # table for. That table is reproduced here accessor by accessor, because the
      # decisions are not obvious from the code and every one of them was argued:
      #
      #   KEEP, IDENTICAL NAMES — the cheapest possible compatibility decision (R-10):
      #     id subject description start_date due_date done_ratio estimated_hours
      #     spent_hours total_spent_hours total_estimated_hours created_on updated_on
      #
      #   KEEP + FIX — `closed_on`, which the base plugin does NOT convert to the
      #     viewer's timezone while converting its two siblings (`issues_drop.rb:22-28`).
      #     Three date accessors, two timezones, same row of the same table. All three
      #     go through `RecordDrop#in_actor_zone` here.
      #
      #   KEEP + FIX — `url`, always ABSOLUTE. See `AbsoluteUrl`: this is what makes
      #     `Report#build_content`'s 38 lines of Nokogiri-or-regexp URL rewriting
      #     unnecessary.
      #
      #   RENAME + ALIAS — `visible? closed? overdue? is_private?` become
      #     `visible closed overdue private`, and the `?` spellings are RETAINED as
      #     aliases. Mandatory, not optional: OQ-B was measured on 2026-08-04 and the
      #     original guess was wrong — `{{ issue.closed? }}` parses and resolves on both
      #     Liquid 4.x and 5.x, so those spellings are live surface that may be in real
      #     templates. Dropping them would be a breaking change.
      #
      #   KEEP NAME, FIX TYPE — `tracker status priority category` become
      #     `NamedRefDrop`s and `version` becomes a `VersionDrop`, each substitutable
      #     for the String it replaces (§3.3). The `*_id` accessors ship as well: five
      #     one-line methods, and the escape hatch if drop-versus-String semantics bite
      #     in a shape the spec did not enumerate.
      #
      #   RESTORED, 2026-11-25 (Jan, option A) — `notes journals relations_from
      #     relations_to` and the six probes into other plugins, `tags story_points color
      #     day_in_state checklists helpdesk_ticket` (`issues_drop.rb:120-157` in the
      #     vendor gem). They were dropped here as vendor coupling (OQ-H, narrowed); GEOxyz
      #     runs redmine_tags, redmine_agile, redmine_checklists and
      #     redmine_contacts_helpdesk, and its templates use them. Same names, same meaning,
      #     with two differences that are the point of this plugin: every one answers AS THE
      #     ACTOR (private notes, hidden relation targets, the checklist and helpdesk
      #     permissions), and every one is batched (`BatchRelated`). Without the providing
      #     plugin each answers empty or nil, where the base plugin answered `false`.
      #
      #   GATED — `description`, `attachments`, `notes` and `journals` are empty for an issue
      #     the actor may see but not OPEN under redmine_view_issue_description, which is that
      #     plugin's rule for exactly these four (`Batch#openable?`). Without it, unchanged.
      #
      #   DROPPED FROM THE ADDON'S OWN SUBCLASS — `images` (returns a drop whose
      #     `file_url` mints unexpiring token URLs — an explicit non-goal, replaced by
      #     `| inline`), and `available_statuses spent_time_by_date
      #     total_spent_time_by_date watchers`, each an unbatched N+1 superseded by the
      #     aggregator. `project_name` folds into `project.name`.
      #
      # WHAT IS PUBLIC HERE IS WHAT A TEMPLATE CAN REACH. `Liquid::Drop.invokable_methods`
      # is every public instance method minus `Drop`'s own, so adding one is a decision
      # about the template vocabulary and not a convenience — see `NamedRefDrop`'s
      # comment for what happens when that is got wrong.
      class IssueDrop < RecordDrop
        # ------------------------------------------------------------------
        # Keep, identical names
        # ------------------------------------------------------------------

        def subject
          record.subject
        end

        # nil for an issue the actor may not open (redmine_view_issue_description).
        def description
          openable? && !hidden?('description') ? record.description : nil
        end

        def start_date
          hidden?('start_date') ? nil : record.start_date
        end

        def due_date
          hidden?('due_date') ? nil : record.due_date
        end

        def done_ratio
          record.done_ratio
        end

        def estimated_hours
          hidden?('estimated_hours') ? nil : record.estimated_hours
        end

        # ------------------------------------------------------------------
        # Keep + fix: the three timestamps, all three in the actor's zone
        # ------------------------------------------------------------------

        def created_on
          in_actor_zone(record.created_on)
        end

        def updated_on
          in_actor_zone(record.updated_on)
        end

        # THE FIX. Its two siblings above were converted and this one was not.
        def closed_on
          in_actor_zone(record.closed_on)
        end

        # ------------------------------------------------------------------
        # Spent and estimated time
        # ------------------------------------------------------------------

        # Through the batch, so a 500-issue loop costs one query rather than 500 — and
        # through `TimeEntry.visible(actor)` inside it, so a viewer without
        # :view_time_entries in this project reads 0.0 rather than somebody's hours.
        def spent_hours
          batch.spent_hours(id)
        end

        # Self plus descendants, which is what Redmine means by "total".
        #
        # A LEAF SHORT-CIRCUITS, and that is the whole reason this is not simply
        # delegated: for an issue with no children the total IS the issue's own figure,
        # so the batched value answers it with no query at all. Only a parent pays, and
        # only for the accessor that asks. `leaf?` is `rgt - lft == 1` on the row that is
        # already loaded — no query of its own.
        def total_spent_hours
          return spent_hours if leaf?

          record.total_spent_hours.to_f
        end

        # Hidden with `estimated_hours`, as redmine_issue_field_visibility hides the total.
        def total_estimated_hours
          return nil if hidden?('estimated_hours')
          return estimated_hours if leaf?

          record.total_estimated_hours
        end

        # ------------------------------------------------------------------
        # Rename + alias. See the class comment: the `?` spellings are LIVE surface.
        # ------------------------------------------------------------------

        # Always true for an issue that reached a template through a visibility-scoped
        # collection, and asked anyway rather than answered `true` — because an issue
        # can also arrive by id through `{{ issues[42] }}`, and `Issue#visible?` is
        # Redmine's own answer rather than an inference from how the object got here.
        def visible
          record.visible?(actor)
        end

        def closed
          record.closed?
        end

        def overdue
          record.overdue?
        end

        # A public instance method called `private`. It shadows nothing: `Kernel#private`
        # is a private instance method, and the bare `private` further down this class
        # body is `Module#private` called on the class object, which is a different
        # receiver entirely.
        def private
          record.is_private?
        end

        alias visible? visible
        alias closed? closed
        alias overdue? overdue
        # `is_private?`, not `private?` — that is the spelling the gem shipped
        # (`issues_drop.rb:36-53`) and therefore the spelling a template would carry.
        alias is_private? private

        # ------------------------------------------------------------------
        # Keep name, fix type: the named references
        # ------------------------------------------------------------------

        # `is_closed` comes off the STATUS row, not off `issue.closed?`. The two agree
        # today — Redmine's `Issue#closed?` is `status.is_closed` — and sourcing it from
        # the status is what keeps them agreeing: `{{ issue.status.is_closed }}` is a
        # question about the status, and answering it from the issue would make the same
        # drop answer differently depending on which issue produced it.
        def status
          @status ||= begin
            row = reference(:status, ::IssueStatus, :status_id)
            named_ref(row, path: '/issue_statuses/%d',
                           attributes: { 'is_closed' => row && row.is_closed })
          end
        end

        def tracker
          @tracker ||= named_ref(reference(:tracker, ::Tracker, :tracker_id),
                                 path: '/trackers/%d')
        end

        def priority
          return nil if hidden?('priority_id')

          @priority ||= named_ref(reference(:priority, ::IssuePriority, :priority_id),
                                  path: '/enumerations/%d')
        end

        def category
          return nil if hidden?('category_id')

          @category ||= named_ref(reference(:category, ::IssueCategory, :category_id),
                                  path: '/issue_categories/%d')
        end

        # `version` is what the gem called it, so `version` is what it stays called.
        def version
          return @version if defined?(@version)
          return @version = nil if hidden?('fixed_version_id')

          target = reference(:fixed_version, ::Version, :fixed_version_id)
          @version = target && VersionDrop.new(target, context: render_context)
        end

        # The addon's own spelling for the same thing (`issue_drop_patch.rb`). Kept as
        # an alias rather than dropped, because T-20 deletes that patch and a template
        # written against this plugin's shipped surface must not break when its
        # implementation moves. One fact, two spellings, and the second one is an alias
        # rather than a second method — which is the difference between compatibility
        # and a vocabulary with two of everything.
        alias target_version version

        # The `*_id` escape hatch — §3.3's belt and braces. Read off the issue's own
        # columns, so none of them costs a query even when nothing is preloaded.
        def status_id
          record.status_id
        end

        def tracker_id
          record.tracker_id
        end

        def priority_id
          hidden?('priority_id') ? nil : record.priority_id
        end

        def category_id
          hidden?('category_id') ? nil : record.category_id
        end

        def fixed_version_id
          hidden?('fixed_version_id') ? nil : record.fixed_version_id
        end

        def parent_id
          record.parent_id
        end

        def project_id
          record.project_id
        end

        def author_id
          record.author_id
        end

        def assigned_to_id
          hidden?('assigned_to_id') ? nil : record.assigned_to_id
        end

        # ------------------------------------------------------------------
        # Associations
        # ------------------------------------------------------------------

        def author
          @author ||= (record.author && UserDrop.new(record.author, context: render_context))
        end

        def assignee
          return nil if hidden?('assigned_to_id')

          @assignee ||= (record.assigned_to && UserDrop.new(record.assigned_to, context: render_context))
        end

        def project
          @project ||= (record.project && ProjectDrop.new(record.project, context: render_context))
        end

        def parent
          return @parent if defined?(@parent)

          # Only a parent the ACTOR may see (independent review, 2026-11-25): a private parent
          # of a visible subtask printed its subject, and with the restored accessors its tags,
          # notes and helpdesk ticket too. `visible?` is core's answer, asked as the actor.
          found = record.parent
          @parent = found && visible_to_actor?(found) ? self.class.new(found, context: render_context) : nil
        end

        # ------------------------------------------------------------------
        # The batched collections (§3.4)
        # ------------------------------------------------------------------

        # Empty for an issue the actor may not open (redmine_view_issue_description).
        def attachments
          @attachments ||= (openable? ? batch.attachments(id) : [])
                           .map { |a| AttachmentDrop.new(a, context: render_context) }
        end

        def time_entries
          @time_entries ||= batch.time_entries(id)
                                 .map { |e| TimeEntryDrop.new(e, context: render_context) }
        end

        def subtasks
          @subtasks ||= batch.subtasks(id)
                             .map { |i| self.class.new(i, context: render_context) }
        end

        # The to-do lists of redmine_issue_todo_lists2 holding this issue that the VIEWER
        # may see (Jan, 2026-10-07). Empty when that plugin is not installed.
        def todolists_with_positions
          @todolists_with_positions ||= TodoListsDrop.new(
            batch.todo_lists(id).map { |item| TodoListDrop.new(item, context: render_context) }
          )
        end

        # ------------------------------------------------------------------
        # Restored from the base plugin (Jan, 2026-11-25). See the class comment.
        # ------------------------------------------------------------------

        # The notes of the journals below, oldest first: an Array of Strings, as the base
        # plugin returned it.
        def notes
          @notes ||= batch.journals(id).map(&:notes)
        end

        # The journals with notes the actor may read, oldest first. `all`, `size`, `each`,
        # `first`, `last`; at most `BatchRelated::JOURNALS_PER_ISSUE` (the most recent).
        def journals
          @journals ||= JournalsDrop.new(
            batch.journals(id).map { |journal| JournalDrop.new(journal, context: render_context, issue: self) }
          )
        end

        # Relations in which this issue is `issue_from`, each only when the actor may see
        # `issue_to`.
        def relations_from
          @relations_from ||= relation_list(:from) { |other| { issue_from: self, issue_to: other } }
        end

        # Relations in which this issue is `issue_to`, each only when the actor may see
        # `issue_from`.
        def relations_to
          @relations_to ||= relation_list(:to) { |other| { issue_from: other, issue_to: self } }
        end

        # redmine_tags: the tag names, alphabetical. `[]` without that plugin.
        def tags
          batch.tags(id)
        end

        # redmine_agile: the story points, nil when not set or without that plugin.
        def story_points
          batch.story_points(id)
        end

        # redmine_agile: the issue's colour, nil when not set or without that plugin.
        def color
          batch.color(id)
        end

        # redmine_agile: when the issue entered its current status — the last status change
        # the actor may see, else its creation — in the actor's zone. nil without that plugin.
        def day_in_state
          in_actor_zone(batch.day_in_state(id, record.created_on))
        end

        # redmine_checklists: the items in their order, each `{ subject, is_done, is_section }`
        # plus `id_done`, the base plugin's misspelling of `is_done`, kept because templates
        # carry it. `[]` without `view_checklists` in the issue's project, or without that plugin.
        def checklists
          @checklists ||= batch.checklists(id, record.project).map do |item|
            done = item.is_done ? true : false
            { 'subject' => item.subject.to_s, 'is_done' => done, 'id_done' => done,
              'is_section' => item.respond_to?(:is_section) && item.is_section ? true : false }
          end
        end

        # redmine_contacts_helpdesk: the ticket, when the actor holds `view_helpdesk_tickets`
        # in the issue's project. nil otherwise, or without that plugin.
        def helpdesk_ticket
          return @helpdesk_ticket if defined?(@helpdesk_ticket)

          ticket = helpdesk_allowed? && batch.helpdesk_ticket(id, record.project)
          @helpdesk_ticket = ticket ? HelpdeskTicketDrop.new(ticket, context: render_context) : nil
        end

        # ------------------------------------------------------------------
        # Custom fields
        # ------------------------------------------------------------------

        # A list, ordered the way Redmine orders its fields, of the fields this actor
        # may see on this issue. See `CustomFieldValueDrop`: a field the viewer may not
        # see is ABSENT, name included, rather than present and blank.
        def custom_field_values
          @custom_field_values ||= visible_values.map do |field_id, value|
            CustomFieldValueDrop.new(id: field_id, name: field_name(field_id), value: value)
          end
        end

        # `{{ issue.custom_field_value[20] }}` — the addon's by-id accessor, carried
        # forward. See `CustomFieldValuesDrop`.
        def custom_field_value
          @custom_field_value ||= CustomFieldValuesDrop.new(
            values: visible_values,
            names: visible_values.keys.each_with_object({}) { |fid, out| out[fid] = field_name(fid) }
          )
        end

        # ------------------------------------------------------------------
        # Presentation
        # ------------------------------------------------------------------

        def url
          absolute("/issues/#{id}")
        end

        # An anchor, with the subject ESCAPED. `link` is the one accessor here that
        # emits markup, and a subject is user input: Liquid does not auto-escape, so an
        # issue titled `</a><script>…` would otherwise be an injection into every report
        # that prints a link (INV-9, FR-19). The escaping is here rather than left to the
        # template because a template author cannot escape markup this method produced.
        def link
          %(<a href="#{CGI.escapeHTML(url)}">#{CGI.escapeHTML(to_s)}</a>)
        end

        # `#42 Subject`, which is how Redmine itself names an issue.
        def to_s
          "##{id} #{subject}"
        end

        private

        # `leaf?` comes from awesome_nested_set and reads two columns already on the
        # loaded row. Guarded because the drop specs run against plain objects and
        # because an issue whose nested-set columns are not loaded should pay the query
        # rather than answer wrongly.
        def leaf?
          record.respond_to?(:leaf?) && record.leaf?
        end

        # Core's `visible_custom_field_values`: a field the actor may see in this project
        # AND one enabled for this issue's project and tracker (`available_custom_fields`) —
        # a stored value of a field since removed from the tracker is not shown by core.
        def visible_values
          @visible_values ||= begin
            available = batch.available_custom_field_ids(own(:project), own(:tracker_id))
            values = batch.custom_field_values(id, record.project)
            available.nil? ? values : values.select { |field_id, _| available.include?(field_id) }
          end
        end

        def openable?
          batch.openable?(id)
        end

        # redmine_issue_field_visibility: the core fields it hides for the ACTOR's roles in
        # this issue's project read as nil here — the reader, the `*_id` and the reference
        # alike. Asked once per project and render (`Batch#hidden_core_fields`).
        def hidden?(field)
          batch.hidden_core_fields(own(:project)).include?(field)
        end

        # A column or association read defensively: an issue always has these, but the drop
        # specs' fake records carry only what each example needs.
        def own(name)
          record.respond_to?(name) ? record.public_send(name) : nil
        end

        def visible_to_actor?(issue)
          !issue.respond_to?(:visible?) || issue.visible?(actor)
        end

        # redmine_view_issue_description's own helpdesk rule (`vid_helpdesk_access?`):
        # `view_helpdesk_tickets` AND the description grant for this tracker. The permission
        # is the batch's; the grant is asked here, of the record, AS THE ACTOR.
        def helpdesk_allowed?
          return false unless openable?
          return true unless record.respond_to?(:description_access_granted?)

          record.description_access_granted?(actor) == true
        end

        def relation_list(side)
          IssueRelationsDrop.new(
            batch.relations(id)[side].map do |relation, other|
              IssueRelationDrop.new(relation, context: render_context,
                                              **yield(self.class.new(other, context: render_context)))
            end
          )
        end

        def field_name(field_id)
          batch.visible_custom_fields[field_id]&.name.to_s
        end
      end
    end
  end
end
