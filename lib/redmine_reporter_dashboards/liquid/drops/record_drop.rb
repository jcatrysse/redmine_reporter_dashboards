# frozen_string_literal: true

require_relative 'absolute_url'
require_relative '../render_context'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # One record, plus the handle on the render it belongs to.
      #
      # --- THE CONTEXT IS REQUIRED, AND THAT IS INV-1 ---
      #
      # A drop that can be built without a context is a drop that will be built without
      # one, and the first thing it will do is reach for `User.current` to convert a
      # timestamp. That is the ambient-actor read INV-1 exists to forbid, and it is the
      # easiest thing in this project to lose silently: the code looks the same, the
      # tests pass because the test set `User.current`, and in production a scheduled
      # report renders as whoever happened to run last.
      #
      # So the constructor refuses. `RenderContext` already refuses a nil actor; this
      # class refuses a nil context. Between them there is no path from a template to a
      # timestamp that does not go through an explicit actor.
      #
      # --- EVERY PUBLIC METHOD HERE IS TEMPLATE SURFACE ---
      #
      # `Liquid::Drop.invokable_methods` is `public_instance_methods - Drop's own`, so
      # a public helper on this base class is reachable as `{{ issue.helper }}` on every
      # subclass. That is how the gem ended up exposing its internals. Helpers are
      # `private`; the only public methods are ones a template is meant to call.
      #
      # `NamedRefDrop`'s comment records what happens when this is got wrong — a public
      # `key?` made every accessor on that class render EMPTY — and the lesson
      # generalises: adding a public method here is a decision about what templates can
      # reach, not a convenience.
      class RecordDrop < ::Liquid::Drop
        # `record` is the ActiveRecord object. `context` is the RenderContext.
        def initialize(record, context:)
          unless context.is_a?(RenderContext)
            raise ArgumentError,
                  'a drop needs a RenderContext (INV-1: the actor is explicit, never ' \
                  "ambient User.current). Got #{context.class}"
          end

          @record = record
          # `@render_context`, NOT `@context`. `Liquid::Drop` declares
          # `attr_writer :context` and ASSIGNS `@context` to the Liquid::Context every
          # time a template touches the drop — then reads it back in its own
          # `liquid_method_missing` to decide whether `strict_variables` is on. A drop
          # storing its own object under that name silently breaks Liquid's internals
          # and, in the other direction, has its own field overwritten mid-render.
          #
          # It is the same class of defect as `NamedRefDrop`'s `key?`: a name that looks
          # free and is not. Found by test, which is the only way it gets found — the
          # first symptom was `NoMethodError: undefined method 'actor' for an instance of
          # Liquid::Context`, three frames away from the assignment that caused it.
          @render_context = context
          super()
        end

        def id
          @record.id
        end

        # The subject/name, so `{{ issue }}` and `{{ project }}` print something a
        # reader recognises rather than `#<Drop>`. Subclasses override.
        def to_s
          id.to_s
        end

        def inspect
          "#<#{self.class.name.split('::').last} id=#{id.inspect}>"
        end

        private

        attr_reader :record, :render_context

        def actor
          render_context.actor
        end

        def batch
          render_context.batch
        end

        def diagnostics
          render_context.diagnostics
        end

        def budget
          render_context.budget
        end

        def absolute(path)
          AbsoluteUrl.absolute(path)
        end

        # THE TIMEZONE FIX, in one place.
        #
        # §3.2 records the defect it closes: the base plugin converts `created_on` and
        # `updated_on` to the viewer's timezone and NOT `closed_on`
        # (`issues_drop.rb:22-28`) — three date accessors in two timezones, in the same
        # row of the same table. A report that prints all three shows one of them in
        # UTC and the other two in Brussels, and nothing says which.
        #
        # So all three go through here, and here reads the actor rather than
        # `User.current`.
        #
        # `respond_to?` on both sides rather than a version check: the zone is a user
        # PREFERENCE and may legitimately be nil (Redmine falls back to the instance
        # default, which is what an unconverted Time already is), and `in_time_zone`
        # comes from ActiveSupport, which this layer does not require — the drop specs
        # run against the bare Liquid gem.
        def in_actor_zone(time)
          return nil if time.nil?
          return time unless time.respond_to?(:in_time_zone)

          zone = actor.respond_to?(:time_zone) ? actor.time_zone : nil
          zone.nil? ? time : time.in_time_zone(zone)
        end

        # A reference that is still a String to every template that ever printed it.
        # nil in, nil out: `{{ issue.category }}` on an issue with no category must
        # render empty, not "0" and not the word "nil".
        # `path` is a format string with one `%d` for the record id, or nil for a record
        # Redmine has no page for — a time-entry activity is the concrete case. nil
        # rather than a guessed route: a link to a 404 is worse than no link.
        def named_ref(record, path:, attributes: {})
          return nil if record.nil?

          NamedRefDrop.new(id: record.id, name: record.name.to_s,
                           url: path && absolute(format(path, record.id)),
                           attributes: attributes)
        end

        # Read an association WITHOUT triggering a query when the collection preloaded
        # it, and through the batch registry when it did not.
        #
        # This is the seam between §3.4's two mechanisms. M1 (`CollectionDrop#each`'s
        # preload) has already loaded the association for every issue in a loop, so the
        # loaded check hits and costs nothing. M2 (the batch's `:named_refs` key) serves
        # the case a preload cannot reach — `{{ issues[42].status }}`, one issue fetched
        # by id — with one query per referenced class rather than one per issue.
        def reference(association, klass, column)
          if @record.respond_to?(:association) && @record.association(association).loaded?
            return @record.public_send(association)
          end

          batch.named_ref(klass, @record.public_send(column), column: column)
        end
      end
    end
  end
end
