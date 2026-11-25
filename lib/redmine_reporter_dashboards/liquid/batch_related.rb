# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    # The batch keys behind the accessors the base plugin (on the vendor gem) offered and
    # this plugin first dropped: the issue's journals and
    # notes, its relations, and the data of four other plugins GEOxyz runs — redmine_tags,
    # redmine_agile, redmine_checklists and redmine_contacts_helpdesk. Jan, 2026-11-25
    # (option A): same names, same meaning, so the existing templates keep working.
    #
    # Included into `Batch`, so every key here has the same two properties as the others
    # there: ONE query (or a fixed handful) per key per render, however many issues the
    # report holds, and every query answered AS THE ACTOR. What the base plugin did instead
    # is the reason this is not a copy of it: `issue.journals` there was every journal with
    # notes, private notes included, read by whoever rendered the template.
    #
    # --- THE OTHER PLUGINS ARE OPTIONAL, AND NAMED BY ASSOCIATION, NOT BY CONSTANT ---
    #
    # Each plugin is detected by what it adds to `Issue` (an association and the accessor
    # the base plugin called), and its model is reached through that association's
    # reflection. Two reasons. Without the plugin there is nothing to load and the accessor
    # answers empty or nil, as `todolists_with_positions` does. And redmine_tags' models
    # live in the vendor gem's namespace, which this plugin does not name (G8): the
    # reflection hands over the class without the name being written here.
    module BatchRelated
      # `issue.journals.all` and `issue.notes` are bounded: at most this many journals per
      # issue — the most recent ones, kept in chronological order — so `| reverse | first`
      # is still the last comment. Beyond it the render records a visible degradation.
      JOURNALS_PER_ISSUE = 500

      # And at most this many journal rows per render, across all issues, because the
      # per-issue bound alone multiplies by MAX_MATERIALISED_RECORDS.
      JOURNAL_ROWS = 20_000

      # The same two bounds for relations, checklist items and helpdesk messages.
      RELATED_PER_ISSUE = 500
      RELATED_ROWS = 20_000

      # ------------------------------------------------------------------
      # redmine_view_issue_description: who may OPEN the issue
      # ------------------------------------------------------------------

      # Whether the actor may open this issue, which is what redmine_view_issue_description
      # requires for its description, its journals and its attachments
      # (`Issue#detail_access_granted?`: admin, `view_issue_description` for the tracker,
      # assignee, or watcher with `view_watched_issues`). Without that plugin, true: core
      # has no such rule, and the issue is already one the actor may see.
      #
      # Answered for the whole report at once by the plugin's own batch method
      # (`Issue.vid_openable_ids`), which preloads what the check reads.
      def openable?(issue_id)
        return true unless self.class.openable_rule?

        related_resolve(:openable, issue_id) do |id_set|
          ::Issue.vid_openable_ids(::Issue.where(id: id_set).to_a, @actor)
                 .index_with(true)
        end[issue_id] == true
      end

      # ------------------------------------------------------------------
      # Journals and notes (core)
      # ------------------------------------------------------------------

      # The journals WITH NOTES the actor may read, oldest first, as the base plugin
      # offered them (`where.not(notes: [nil, ''])`). Core's own rules, asked as the actor:
      # `Journal.visible` is the issue's visibility plus private notes (visible to their
      # author and to `view_private_notes`). Nothing for an issue the actor may not open
      # under redmine_view_issue_description.
      def journals(issue_id)
        related_resolve(:journals, issue_id) do |id_set|
          openable = id_set.select { |id| openable?(id) }
          next {} if openable.empty?

          table = ::Journal.arel_table
          rows = ::Journal.visible(@actor)
                          .where(journalized_type: 'Issue', journalized_id: openable)
                          .where.not(notes: [nil, ''])
                          .preload(:user)
                          .reorder(table[:journalized_id].asc, table[:created_on].desc, table[:id].desc)
                          .limit(JOURNAL_ROWS + 1).to_a
          bounded_newest(rows, :journalized_id, JOURNAL_ROWS, JOURNALS_PER_ISSUE, :journals)
        end[issue_id] || []
      end

      # Ids of the attachments each journal added (core's `Journal#attachments` reads the
      # `attachment` details), for the journals already loaded above. Two queries for the
      # whole report.
      def journal_attachments(journal_id, issue_id)
        related_resolve(:journal_attachments, issue_id) do |id_set|
          journal_ids = id_set.flat_map { |id| journals(id) }.map(&:id)
          next {} if journal_ids.empty?

          pairs = ::JournalDetail.where(journal_id: journal_ids, property: 'attachment')
                                 .where.not(value: [nil, '']).pluck(:journal_id, :prop_key)
          found = ::Attachment.where(id: pairs.map { |_, att| att.to_i }).preload(:author)
                              .index_by(&:id)
          pairs.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(jid, att), out|
            attachment = found[att.to_i]
            out[jid] << attachment if attachment
          end
        end[journal_id] || []
      end

      # redmine_agile's `day_in_state` (its `IssuePatch#day_in_state`): when the issue
      # entered its current status, which is the most recent status change, or `created_on`
      # (passed in) when there was none. Only status changes in journals the actor may read
      # count. nil without redmine_agile.
      def day_in_state(issue_id, created_on)
        return nil unless self.class.related_available?(:day_in_state)
        # redmine_view_issue_description hides an unopenable issue's history; this is part of it.
        return nil unless openable?(issue_id)

        related_resolve(:day_in_state, issue_id) do |id_set|
          ::Journal.visible(@actor)
                   .where(journalized_type: 'Issue', journalized_id: id_set)
                   .joins(:details)
                   .where(::JournalDetail.table_name => { property: 'attr', prop_key: 'status_id' })
                   .group(:journalized_id).maximum(:created_on)
        end[issue_id] || created_on
      end

      # ------------------------------------------------------------------
      # Relations (core)
      # ------------------------------------------------------------------

      # `{ from: [[relation, other_issue], …], to: [...] }`, each relation only when the
      # issue on its other end is one the actor may see (`Issue.visible`), the base
      # plugin's own filter (`other_issue.visible?`), but asked as the actor. The other
      # issues come preloaded with what `IssueDrop` reads.
      def relations(issue_id)
        related_resolve(:relations, issue_id) do |id_set|
          rows = ::IssueRelation.where(issue_from_id: id_set)
                                .or(::IssueRelation.where(issue_to_id: id_set))
                                .order(:id).limit(RELATED_ROWS + 1).to_a
          rows = cap_rows(rows, RELATED_ROWS, :relations)
          endpoints = rows.flat_map { |rel| [rel.issue_from_id, rel.issue_to_id] }.uniq
          visible = ::Issue.visible(@actor).where(id: endpoints)
                           .preload(:status, :tracker, :priority, :category, :fixed_version,
                                    :project, :author, :assigned_to)
                           .index_by(&:id)
          relation_sides(rows, id_set, visible)
        end[issue_id] || { from: [], to: [] }
      end

      # ------------------------------------------------------------------
      # redmine_tags
      # ------------------------------------------------------------------

      # The tag names, alphabetical. redmine_tags has no permission of its own for reading
      # tags: whoever sees the issue sees them, as on the issue page.
      def tags(issue_id)
        return [] unless self.class.related_available?(:tags)

        related_resolve(:tags, issue_id) do |id_set|
          tagging = ::Issue.reflect_on_association(:taggings).klass
          tag = ::Issue.reflect_on_association(:tags).klass
          tagging.joins(:tag)
                 .where(taggable_type: 'Issue', taggable_id: id_set)
                 .order(tag.arel_table[:name].asc, tag.arel_table[:id].asc)
                 .pluck(:taggable_id, tag.arel_table[:name])
                 .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(issue, name), out|
                   out[issue] << name.to_s unless out[issue].include?(name.to_s)
                 end
        end[issue_id] || []
      end

      # ------------------------------------------------------------------
      # redmine_agile
      # ------------------------------------------------------------------

      # `issue.story_points` (its `agile_data` row) and `issue.color` (its `agile_color`
      # row). Raw values, as the base plugin returned them; redmine_agile has no read
      # permission for either beyond seeing the issue.
      def story_points(issue_id)
        return nil unless self.class.related_available?(:story_points)

        related_resolve(:story_points, issue_id) do |id_set|
          one_to_one_values(:agile_data, :story_points, id_set)
        end[issue_id]
      end

      def color(issue_id)
        return nil unless self.class.related_available?(:color)

        related_resolve(:color, issue_id) { |id_set| one_to_one_values(:agile_color, :color, id_set) }[issue_id]
      end

      # ------------------------------------------------------------------
      # redmine_checklists
      # ------------------------------------------------------------------

      # The checklist items in their own order (`position`), only where the actor holds
      # `view_checklists` in the issue's project — the permission redmine_checklists itself
      # uses to show them.
      def checklists(issue_id, project)
        return [] unless self.class.related_available?(:checklists)
        return [] unless allowed_in?(:view_checklists, project)

        related_resolve(:checklists, issue_id) do |id_set|
          klass = ::Issue.reflect_on_association(:checklists).klass
          rows = klass.where(issue_id: id_set).reorder(:issue_id, :position, :id)
                      .limit(RELATED_ROWS + 1).to_a
          bounded_oldest(cap_rows(rows, RELATED_ROWS, :checklists), :issue_id, RELATED_PER_ISSUE, :checklists)
        end[issue_id] || []
      end

      # ------------------------------------------------------------------
      # redmine_contacts_helpdesk
      # ------------------------------------------------------------------

      # The issue's helpdesk ticket, only where the actor holds `view_helpdesk_tickets` in
      # the issue's project (`HelpdeskTicket#visible?`: the issue visible AND that
      # permission). Its contact comes along only when the actor may see that contact.
      def helpdesk_ticket(issue_id, project)
        return nil unless self.class.related_available?(:helpdesk_ticket)
        return nil unless allowed_in?(:view_helpdesk_tickets, project)

        helpdesk_ticket_row(issue_id)
      end

      # The contacts of the loaded tickets the actor may see, `{ id => contact }`, through
      # redmine_contacts' own `Contact.visible` scope. Empty without that plugin.
      def helpdesk_contact(contact_id, issue_id)
        return nil if contact_id.nil?

        related_resolve(:helpdesk_contacts, issue_id) do |id_set|
          ids = id_set.filter_map { |id| helpdesk_ticket_row(id)&.contact_id }.uniq
          contact = ::Issue.reflect_on_association(:helpdesk_ticket).klass.reflect_on_association(:contact)&.klass
          next {} if ids.empty? || contact.nil? || !contact.respond_to?(:visible)

          contact.visible(@actor).where(id: ids).to_a.index_by(&:id)
        end[contact_id]
      end

      # The journals that carry a helpdesk message (redmine_contacts_helpdesk's
      # `journal_message`), as `HelpdeskTicketDrop#messages` listed them — the same
      # journal visibility as `journals`, and nothing for an issue the actor may not open.
      def helpdesk_messages(issue_id)
        related_resolve(:helpdesk_messages, issue_id) do |id_set|
          openable = id_set.select { |id| openable?(id) }
          next {} if openable.empty? || ::Journal.reflect_on_association(:journal_message).nil?

          table = ::Journal.arel_table
          rows = ::Journal.visible(@actor)
                          .where(journalized_type: 'Issue', journalized_id: openable)
                          .joins(:journal_message)
                          .preload(:journal_message, :user)
                          .reorder(table[:journalized_id].asc, table[:created_on].desc, table[:id].desc)
                          .limit(RELATED_ROWS + 1).to_a
          bounded_newest(rows, :journalized_id, RELATED_ROWS, RELATED_PER_ISSUE, :helpdesk_messages)
        end[issue_id] || []
      end

      # ------------------------------------------------------------------
      # redmine_issue_field_visibility and core's available custom fields
      # ------------------------------------------------------------------

      # The core fields redmine_issue_field_visibility hides from the actor in this project
      # (`assigned_to_id`, `estimated_hours`, …), asked of that plugin with the actor passed
      # explicitly — never through its `hide_values` block, which reads the ambient user.
      # Empty without that plugin. Memoised per project.
      def hidden_core_fields(project)
        return [] unless self.class.field_visibility_rule?

        @hidden_core_fields ||= {}
        key = project&.id
        return @hidden_core_fields[key] if @hidden_core_fields.key?(key)

        @hidden_core_fields[key] =
          Array(::RedmineIssueFieldVisibility.hidden_core_fields(@actor, project)).map(&:to_s).freeze
      end

      # The custom field ids enabled for this project AND tracker, core's
      # `Issue#available_custom_fields`. Two queries per distinct pair and render. nil when
      # it cannot be asked (no project or tracker id), which leaves the values unfiltered
      # by this rule; the role rule (`custom_field_values`) still applies.
      def available_custom_field_ids(project, tracker_id)
        return nil if project.nil? || tracker_id.nil? || !project.respond_to?(:all_issue_custom_fields)

        @available_custom_fields ||= {}
        key = [project.id, tracker_id]
        return @available_custom_fields[key] if @available_custom_fields.key?(key)

        @budget.check!(:batch_available_custom_fields)
        tracker = ::Tracker.find_by(id: tracker_id)
        @available_custom_fields[key] =
          (tracker ? project.all_issue_custom_fields.map(&:id) & tracker.custom_fields.map(&:id) : []).to_set
      end

      # ------------------------------------------------------------------
      # Availability
      # ------------------------------------------------------------------

      # What each optional accessor needs `Issue` to have. The association is what the
      # query reads; the method is the one the base plugin probed with `respond_to?`, so
      # "installed" means what it meant there.
      RELATED_PROBES = {
        tags: [%i[tags taggings], :tag_list],
        story_points: [%i[agile_data], :story_points],
        color: [%i[agile_color], :color],
        day_in_state: [[], :day_in_state],
        checklists: [%i[checklists], :checklists],
        helpdesk_ticket: [%i[helpdesk_ticket], :helpdesk_ticket]
      }.freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      # The availability probes, on `Batch` itself so a drop or a test can ask without a
      # render.
      module ClassMethods
        def related_available?(key)
          associations, method = RELATED_PROBES.fetch(key)
          defined?(::Issue) && ::Issue.method_defined?(method) &&
            associations.all? { |name| ::Issue.reflect_on_association(name) }
        end

        def field_visibility_rule?
          defined?(::RedmineIssueFieldVisibility) &&
            ::RedmineIssueFieldVisibility.respond_to?(:hidden_core_fields)
        end

        # redmine_view_issue_description's batch method and the per-issue rule it runs.
        def openable_rule?
          defined?(::Issue) && ::Issue.respond_to?(:vid_openable_ids) &&
            ::Issue.method_defined?(:detail_access_granted?)
        end
      end

      private

      def helpdesk_ticket_row(issue_id)
        related_resolve(:helpdesk_ticket, issue_id) do |id_set|
          klass = ::Issue.reflect_on_association(:helpdesk_ticket).klass
          klass.where(issue_id: id_set).to_a.index_by(&:issue_id)
        end[issue_id]
      end

      # `resolve`, with two differences every key in this module needs (independent review,
      # 2026-11-25).
      #
      # THE ISSUE ITSELF MUST BE VISIBLE. A scope is the actor's, but an issue also arrives
      # without one — `issue.parent`, a related issue, a per-record render — and its tags,
      # checklist or helpdesk ticket must not reach a template when the issue itself would
      # not. So the id set is cut to `Issue.visible(actor)` first: one query per key and
      # render, fail closed.
      #
      # AN ISSUE OUTSIDE THE SCOPE IS ASKED ABOUT ITSELF, not answered from the scope's
      # memo — where it is absent and would read as "no journals", "no story points", the
      # silent wrong answer `Batch#resolve`'s comment describes. That costs queries per such
      # issue (a subtask, a parent, a related issue), which is the price of a right answer
      # for an issue the report did not batch.
      def related_resolve(key, issue_id, &block)
        if scope? && !scope_id_set.include?(issue_id)
          cache_key = [key, issue_id]
          return @cache[cache_key] if @cache.key?(cache_key)

          @budget.check!(:"batch_#{key}")
          return @cache[cache_key] = visible_answer([issue_id], &block)
        end

        resolve(key, issue_id) { |id_set| visible_answer(id_set, &block) }
      end

      def visible_answer(id_set)
        visible = visible_ids(id_set)
        visible.empty? ? {} : yield(visible)
      end

      def scope_id_set
        @scope_id_set ||= ids.to_set
      end

      # Memoised per issue id, so the keys of one render share one answer per issue.
      def visible_ids(id_set)
        @visible_issue ||= {}
        unknown = id_set.reject { |id| @visible_issue.key?(id) }
        if unknown.any?
          found = ::Issue.visible(@actor).where(id: unknown).pluck(:id).to_set
          unknown.each { |id| @visible_issue[id] = found.include?(id) }
        end
        id_set.select { |id| @visible_issue[id] }
      end

      # `{ issue_id => value }` off a `has_one` of `Issue`, through its reflection: the
      # foreign key, and the type column for a polymorphic one (`agile_color` is
      # `as: :container`).
      def one_to_one_values(association, column, id_set)
        reflection = ::Issue.reflect_on_association(association)
        relation = reflection.klass.where(reflection.foreign_key => id_set)
        relation = relation.where(reflection.type => 'Issue') if reflection.type
        relation.pluck(reflection.foreign_key, column).to_h
      end

      # Memoised per project, like `visible_field?`: a 5 000-issue report over ten
      # projects asks ten times. `allowed_to?` is core's own answer, admin included.
      def allowed_in?(permission, project)
        return false if project.nil?

        @allowed_in ||= {}
        key = [permission, project.id]
        return @allowed_in[key] if @allowed_in.key?(key)

        @allowed_in[key] = @actor.allowed_to?(permission, project) == true
      end

      # Grouped once by each end, so this is linear in the rows rather than ids × rows.
      def relation_sides(rows, id_set, visible)
        by_from = rows.group_by(&:issue_from_id)
        by_to = rows.group_by(&:issue_to_id)
        id_set.each_with_object({}) do |id, out|
          from = (by_from[id] || []).select { |rel| visible[rel.issue_to_id] }
          to = (by_to[id] || []).select { |rel| visible[rel.issue_from_id] }
          next if from.empty? && to.empty?

          out[id] = {
            from: capped(from, RELATED_PER_ISSUE, :relations).map { |rel| [rel, visible[rel.issue_to_id]] },
            to: capped(to, RELATED_PER_ISSUE, :relations).map { |rel| [rel, visible[rel.issue_from_id]] }
          }
        end
      end

      # Rows sorted newest first per issue → `{ issue_id => newest `per_issue`, oldest first }`.
      def bounded_newest(rows, column, total, per_issue, what)
        cap_rows(rows, total, what).group_by { |row| row.public_send(column) }
                                   .transform_values { |list| capped(list, per_issue, what).reverse }
      end

      def bounded_oldest(rows, column, per_issue, what)
        rows.group_by { |row| row.public_send(column) }
            .transform_values { |list| capped(list, per_issue, what) }
      end

      def cap_rows(rows, limit, what)
        return rows if rows.length <= limit

        degrade(:collection_truncated, seen: limit,
                                       detail: "more than #{limit} #{what} rows in this report; " \
                                               "only the first #{limit} were used")
        rows.first(limit)
      end

      def capped(list, limit, what)
        return list if list.length <= limit

        degrade(:collection_truncated, seen: limit,
                                       detail: "an issue has more than #{limit} #{what}; " \
                                               "only #{limit} were used")
        list.first(limit)
      end
    end
  end
end
