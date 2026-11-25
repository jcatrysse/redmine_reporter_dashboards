# frozen_string_literal: true

# Stand-ins for the four things the drop layer touches that a bare `rspec -r liquid`
# process does not have: Redmine's `Setting`, ActiveRecord records, an ActiveRecord
# relation, and the `Batch` registry's database side.
#
# --- WHY FAKES AND NOT THE ADAPTER HARNESS ---
#
# Because these specs answer a different question. What is under test here is the
# DISPOSITION TABLE (`technical-spec.md` §3.2) and the drop protocol: which accessors
# exist, what they are called, what they return, and how a real Liquid template sees
# them. None of that is a question about SQL, and running it against a database would
# make it slower, dependent on an engine, and — worse — unable to run in the CI step
# that pins Liquid 4.0.4 and 5.x, which is the step that proves the protocol claims.
#
# The database side has its own spec and it is `spec/adapter/drop_performance_spec.rb`:
# zero `Issue` instantiations, one query per batch key, the cap. Two questions, two
# harnesses, and neither pretending to answer the other's.
#
# THESE FAKES ARE DELIBERATELY DUMB. A fake that reimplements ActiveRecord is a fake
# that can be wrong in the same way the real thing is; each one below answers exactly
# what the drop asks it and raises on anything else, so a drop reaching for something
# unexpected fails loudly here rather than silently in production.

unless defined?(::Setting)
  # Redmine's settings object, reduced to the two keys `AbsoluteUrl` reads.
  class ::Setting
    class << self
      attr_accessor :protocol, :host_name
    end
    self.protocol = 'https'
    # A PATH PREFIX ON PURPOSE. An install mounted under a sub-path is exactly the
    # install where a hand-built URL goes wrong, and `AbsoluteUrl` documents that
    # `host_name` may carry one. A fixture without it would let a regression through.
    self.host_name = 'redmine.example/rm'
  end
end

# The five model constants `IssueDrop#reference` names. They have to exist even when
# the association is preloaded and the batch is never reached, because Ruby evaluates
# `reference(:status, ::IssueStatus, :status_id)`'s arguments before the call — a fact
# worth knowing, since a spec covering only the preloaded path would still fail on a
# missing constant and the failure would read as a bug in the drop.
%w[IssueStatus Tracker IssuePriority IssueCategory Version].each do |name|
  Object.const_set(name, Class.new) unless Object.const_defined?(name, false)
end

module DropFakes
  # A time that records whether it was converted and to which zone, so a spec can
  # assert the CONVERSION rather than assert a formatted string — which would only
  # prove that the fixture and the expectation agree.
  class Time
    include Comparable

    attr_reader :label, :zone

    def initialize(label, zone: nil)
      @label = label
      @zone = zone
    end

    def in_time_zone(zone)
      self.class.new(@label, zone: zone)
    end

    def to_s
      @zone.nil? ? @label : "#{@label}@#{@zone}"
    end

    # Liquid's `sort: 'created_on'` compares the values; the labels are ISO times, so
    # their order is the times' order.
    def <=>(other)
      other.is_a?(self.class) ? label <=> other.label : nil
    end

    # Liquid asks every value for this before printing it. Without it the drop's
    # accessor looks broken when the fixture is what is missing a method.
    def to_liquid
      self
    end
  end

  # `loaded?` is the whole of it: `RecordDrop#reference` uses it to decide between the
  # preloaded association and the batch's `:named_refs` key, and both branches need
  # covering.
  class Association
    def initialize(loaded)
      @loaded = loaded
    end

    def loaded?
      @loaded
    end
  end

  # The base every fake record shares. Attributes come from a hash; anything not in it
  # raises, so a drop reading a column nobody declared is a test failure and not a nil.
  class Record
    # Both call shapes, because both read well at the call site: a long fixture wants
    # `new({...}, loaded_associations: [...])` and a two-field one wants
    # `new(id: 5, name: 'Closed')`. In Ruby 3 the second arrives as keywords, so it is
    # collected rather than mistaken for a missing positional.
    def initialize(attributes = {}, loaded_associations: [], **extra)
      @attributes = attributes.merge(extra)
      @loaded = loaded_associations.map(&:to_sym)
    end

    def attributes
      @attributes
    end

    def association(name)
      Association.new(@loaded.include?(name.to_sym))
    end

    def respond_to_missing?(name, include_private = false)
      @attributes.key?(name.to_sym) || super
    end

    def method_missing(name, *args)
      return @attributes.fetch(name) if @attributes.key?(name)

      super
    end
  end

  class NamedRecord < Record
    def id
      @attributes.fetch(:id)
    end

    def name
      @attributes.fetch(:name)
    end
  end

  class User < Record
    def id
      @attributes.fetch(:id)
    end

    def name
      @attributes.fetch(:name)
    end

    def time_zone
      @attributes[:time_zone]
    end

    def login
      @attributes.fetch(:login)
    end
  end

  # A relation, iterable and countable, with the two shapes `CollectionDrop#each_record`
  # branches on: `order_values` empty (walked with `find_each`) and non-empty (walked in
  # one capped query so the author's order survives).
  class Relation
    attr_reader :records, :order_values, :preloaded, :limited, :calls

    # `calls` is SHARED with every relation derived from this one. `preload` and `limit`
    # return copies, exactly as ActiveRecord does, so a spec that stubbed the original
    # would be stubbing an object the drop never touches — which reads as "the walk did
    # not happen" when what did not happen was the stub. Recording on a shared array is
    # the fix, and it is why this fake has a journal at all.
    def initialize(records, order_values: [], calls: [])
      @records = records
      @order_values = order_values
      @preloaded = []
      @limited = nil
      @calls = calls
    end

    def preload(*associations)
      dup_with { |copy| copy.instance_variable_set(:@preloaded, associations) }
    end

    def limit(count)
      dup_with { |copy| copy.instance_variable_set(:@limited, count) }
    end

    def count
      @records.length
    end

    def find_by(id:)
      @records.find { |record| record.id == id }
    end

    def find_each(batch_size:, &block)
      raise ArgumentError, 'find_each needs a batch size' unless batch_size.positive?

      @calls << [:find_each, batch_size]
      # find_each FORCES primary-key order and discards any the scope carried. Modelled,
      # because that discarding is exactly what `CollectionDrop#each_record` branches to
      # avoid on an ordered scope, and a fake that quietly preserved the order would let
      # the wrong branch pass.
      window = @limited ? @records.first(@limited) : @records
      window.sort_by(&:id).each(&block)
      self
    end

    def each(&block)
      @calls << [:each, @limited]
      window = @limited ? @records.first(@limited) : @records
      window.each(&block)
      self
    end

    def to_a
      @limited ? @records.first(@limited) : @records
    end

    private

    def dup_with
      copy = self.class.new(@records, order_values: @order_values, calls: @calls)
      copy.instance_variable_set(:@preloaded, @preloaded)
      copy.instance_variable_set(:@limited, @limited)
      yield copy
      copy
    end
  end

  # The registry's answers, without its queries. `asked` records every key a drop
  # touched, which is how "the accessor the template never used cost nothing" becomes an
  # assertion rather than a claim.
  class Batch
    attr_reader :asked, :limit

    def initialize(limit: 5_000, custom_field_values: {}, custom_fields: {},
                   spent_hours: {}, attachments: {}, time_entries: {}, subtasks: {},
                   named_refs: {}, todo_lists: {}, closed_to: [], related: {})
      @limit = limit
      @custom_field_values = custom_field_values
      @custom_fields = custom_fields
      @spent_hours = spent_hours
      @attachments = attachments
      @time_entries = time_entries
      @subtasks = subtasks
      @named_refs = named_refs
      @todo_lists = todo_lists
      # The keys restored on 2026-11-25 (`BatchRelated`). `closed_to` lists the issue ids
      # the actor may see but not OPEN (redmine_view_issue_description); `related` holds
      # the other answers by key, `{ journals: { 42 => [...] }, tags: { 42 => [...] } … }`.
      @closed_to = closed_to
      @related = related
      @asked = []
    end

    # redmine_issue_field_visibility and core's available fields: nothing hidden, no filter,
    # unless the fixture says so (`related: { hidden_core_fields: [...] }`).
    def hidden_core_fields(_project)
      @related.fetch(:hidden_core_fields, [])
    end

    def available_custom_field_ids(_project, _tracker_id)
      @related[:available_custom_field_ids]
    end

    def openable?(issue_id)
      @asked << :openable
      !@closed_to.include?(issue_id)
    end

    def journals(issue_id)
      related_answer(:journals, issue_id, [])
    end

    def journal_attachments(journal_id, _issue_id)
      related_answer(:journal_attachments, journal_id, [])
    end

    def relations(issue_id)
      related_answer(:relations, issue_id, { from: [], to: [] })
    end

    def tags(issue_id)
      related_answer(:tags, issue_id, [])
    end

    def story_points(issue_id)
      related_answer(:story_points, issue_id, nil)
    end

    def color(issue_id)
      related_answer(:color, issue_id, nil)
    end

    # Like the real one: nil when redmine_agile is absent (no `:day_in_state` key given),
    # else the last change or the fallback.
    def day_in_state(issue_id, created_on)
      @asked << :day_in_state
      return nil unless @related.key?(:day_in_state)

      @related[:day_in_state][issue_id] || created_on
    end

    def checklists(issue_id, _project)
      related_answer(:checklists, issue_id, [])
    end

    def helpdesk_ticket(issue_id, _project)
      related_answer(:helpdesk_ticket, issue_id, nil)
    end

    def helpdesk_contact(contact_id, _issue_id)
      related_answer(:helpdesk_contacts, contact_id, nil)
    end

    def helpdesk_messages(issue_id)
      related_answer(:helpdesk_messages, issue_id, [])
    end

    def related_answer(key, id, default)
      @asked << key
      (@related[key] || {}).fetch(id, default)
    end

    def custom_field_values(issue_id, _project)
      @asked << :custom_field_values
      @custom_field_values[issue_id] || {}
    end

    def visible_custom_fields
      @custom_fields
    end

    def spent_hours(issue_id)
      @asked << :spent_hours
      @spent_hours.fetch(issue_id, 0.0)
    end

    def attachments(issue_id)
      @asked << :attachments
      @attachments[issue_id] || []
    end

    def time_entries(issue_id)
      @asked << :time_entries
      @time_entries[issue_id] || []
    end

    def subtasks(issue_id)
      @asked << :subtasks
      @subtasks[issue_id] || []
    end

    def todo_lists(issue_id)
      @asked << :todo_lists
      @todo_lists[issue_id] || []
    end

    def named_ref(klass, id, column: nil)
      @asked << [:named_ref, klass.name, column]
      (@named_refs[klass.name] || {})[id]
    end
  end
end
