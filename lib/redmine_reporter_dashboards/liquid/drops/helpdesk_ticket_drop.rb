# frozen_string_literal: true

require_relative 'record_drop'
require_relative 'user_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # `issue.helpdesk_ticket` — redmine_contacts_helpdesk's ticket of an issue, with the
      # surface of that plugin's own `HelpdeskTicketDrop`: `message_id is_incoming
      # from_address to_address cc_address ticket_date vote vote_comment reaction_time
      # first_response_time resolve_time contact messages`. The three times are in MINUTES,
      # as there. `ticket_date` is in the actor's zone.
      #
      # Reached only where the actor holds `view_helpdesk_tickets` in the issue's project
      # (`BatchRelated#helpdesk_ticket`); otherwise `issue.helpdesk_ticket` is nil.
      class HelpdeskTicketDrop < RecordDrop
        def message_id
          record.message_id
        end

        def is_incoming # rubocop:disable Naming/PredicatePrefix -- the helpdesk plugin's own name
          record.is_incoming
        end

        def from_address
          record.from_address
        end

        def to_address
          record.to_address
        end

        def cc_address
          record.cc_address
        end

        def ticket_date
          in_actor_zone(record.ticket_date)
        end

        def vote
          record.vote
        end

        def vote_comment
          record.vote_comment
        end

        def reaction_time
          minutes(record.reaction_time)
        end

        def first_response_time
          minutes(record.first_response_time)
        end

        def resolve_time
          minutes(record.resolve_time)
        end

        # The ticket's contact, when the actor may see it (redmine_contacts'
        # `Contact.visible`); nil otherwise.
        def contact
          return @contact if defined?(@contact)

          found = batch.helpdesk_contact(record.contact_id, record.issue_id)
          @contact = found && ContactDrop.new(found, context: render_context)
        end

        # The journals that carry a helpdesk message, oldest first, with the journal
        # visibility of `issue.journals`.
        def messages
          @messages ||= batch.helpdesk_messages(record.issue_id)
                             .map { |journal| JournalMessageDrop.new(journal, context: render_context) }
        end

        def to_s
          from_address.to_s
        end

        private

        def minutes(seconds)
          seconds.nil? ? nil : seconds.to_i / 60
        end
      end

      # One message of a helpdesk ticket: the journal and its `journal_message`, with the
      # helpdesk plugin's own names (`JournalMessageDrop`).
      class JournalMessageDrop < RecordDrop
        def is_incoming # rubocop:disable Naming/PredicatePrefix -- the helpdesk plugin's own name
          message&.is_incoming
        end

        def to_address
          message&.to_address
        end

        def bcc_address
          message&.bcc_address
        end

        def cc_address
          message&.cc_address
        end

        def message_id
          message&.message_id
        end

        def notes
          record.notes
        end

        def private_notes
          record.private_notes ? true : false
        end

        def created_on
          in_actor_zone(record.created_on)
        end

        def user
          return @user if defined?(@user)

          @user = record.user && UserDrop.new(record.user, context: render_context)
        end

        def to_s
          notes.to_s
        end

        private

        def message
          record.journal_message
        end
      end

      # The helpdesk ticket's contact (redmine_contacts), reduced to what a report prints:
      # the names, company, job title, e-mail addresses, phones and website. Only built for
      # a contact the actor may see.
      class ContactDrop < RecordDrop
        def name
          record.name.to_s
        end

        def first_name
          record.first_name
        end

        def last_name
          record.last_name
        end

        def middle_name
          record.middle_name
        end

        def company
          record.company
        end

        def job_title
          record.job_title
        end

        def is_company # rubocop:disable Naming/PredicatePrefix -- redmine_contacts' own name
          record.is_company ? true : false
        end

        def website
          record.website
        end

        def primary_email
          record.primary_email
        end

        def emails
          record.email.to_s.split(',').map(&:strip).reject(&:empty?)
        end

        def phones
          record.phone.to_s.split(',').map(&:strip).reject(&:empty?)
        end

        def to_s
          name
        end
      end
    end
  end
end
