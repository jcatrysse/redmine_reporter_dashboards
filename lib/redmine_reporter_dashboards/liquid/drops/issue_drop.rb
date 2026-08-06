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
      #   DROPPED — `notes journals relations_from relations_to` (OQ-H, narrowed: not
      #     part of the six required capabilities) and ALL SIX `respond_to?`/`defined?`
      #     probes into other RedmineUP paid plugins: `tags story_points color
      #     day_in_state checklists helpdesk_ticket` (`issues_drop.rb:131-157`). Vendor
      #     ecosystem coupling with no reason to be reproduced and dead weight
      #     everywhere else.
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

        def description
          record.description
        end

        def start_date
          record.start_date
        end

        def due_date
          record.due_date
        end

        def done_ratio
          record.done_ratio
        end

        def estimated_hours
          record.estimated_hours
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

        def total_estimated_hours
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
          @priority ||= named_ref(reference(:priority, ::IssuePriority, :priority_id),
                                  path: '/enumerations/%d')
        end

        def category
          @category ||= named_ref(reference(:category, ::IssueCategory, :category_id),
                                  path: '/issue_categories/%d')
        end

        # `version` is what the gem called it, so `version` is what it stays called.
        def version
          return @version if defined?(@version)

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
          record.priority_id
        end

        def category_id
          record.category_id
        end

        def fixed_version_id
          record.fixed_version_id
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
          record.assigned_to_id
        end

        # ------------------------------------------------------------------
        # Associations
        # ------------------------------------------------------------------

        def author
          @author ||= (record.author && UserDrop.new(record.author, context: render_context))
        end

        def assignee
          @assignee ||= (record.assigned_to && UserDrop.new(record.assigned_to, context: render_context))
        end

        def project
          @project ||= (record.project && ProjectDrop.new(record.project, context: render_context))
        end

        def parent
          return @parent if defined?(@parent)

          @parent = record.parent && self.class.new(record.parent, context: render_context)
        end

        # ------------------------------------------------------------------
        # The batched collections (§3.4)
        # ------------------------------------------------------------------

        def attachments
          @attachments ||= batch.attachments(id)
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

        def visible_values
          @visible_values ||= batch.custom_field_values(id, record.project)
        end

        def field_name(field_id)
          batch.visible_custom_fields[field_id]&.name.to_s
        end
      end
    end
  end
end
