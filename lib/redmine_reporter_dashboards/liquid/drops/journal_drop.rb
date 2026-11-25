# frozen_string_literal: true

require_relative 'record_drop'
require_relative 'attachment_drop'
require_relative 'user_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # One journal of an issue, reached through `issue.journals` — only journals with
      # notes, as the base plugin listed them, and only those the actor may read (see
      # `BatchRelated#journals`).
      #
      # The surface is the base plugin's `JournalDrop`: `id notes created_on private_notes
      # user issue attachments`. Two differences, both fixes: `created_on` is in the
      # ACTOR's zone like every other timestamp here, and `issue` is the drop that listed
      # the journal rather than a second copy built from it. `url` is the one addition.
      #
      # Not offered: the journal's details (field changes). The base plugin never had them.
      class JournalDrop < RecordDrop
        def initialize(record, context:, issue:)
          @issue = issue
          super(record, context: context)
        end

        attr_reader :issue

        def notes
          record.notes
        end

        def created_on
          in_actor_zone(record.created_on)
        end

        def private_notes
          record.private_notes ? true : false
        end

        def user
          return @user if defined?(@user)

          @user = record.user && UserDrop.new(record.user, context: render_context)
        end

        # The files this journal added, as core lists them under the note.
        def attachments
          @attachments ||= batch.journal_attachments(id, record.journalized_id)
                                .map { |a| AttachmentDrop.new(a, context: render_context) }
        end

        def url
          absolute("/issues/#{record.journalized_id}#change-#{id}")
        end

        def to_s
          notes.to_s
        end
      end
    end
  end
end
