# frozen_string_literal: true

module RedmineReporterDashboards
  module Reporting
    # A REDMINE ATTACHMENT URL -> THE FILE ON DISK, for an actor who may see it (F-16).
    #
    # `Assets::LocalStore` takes a list of `mappers` and documents exactly this as the
    # reason they exist: *"An attachment lives at `Attachment#diskfile`, which needs
    # ActiveRecord, a visibility decision and a `User.current` this layer must not have
    # (INV-1). So `mappers` is a list of callables the Redmine-facing caller supplies."*
    # Since T-33 the port has had no implementation, so the only same-origin URL that
    # resolved was a `/plugin_assets/…` one — and an attachment, which is what a report
    # author actually references, resolved to nothing.
    #
    # --- THE ACTOR IS AN ARGUMENT, NEVER `User.current` (INV-1) ---
    #
    # A scheduled render runs from a rake task as Anonymous unless something sets the
    # identity, and `ScheduledDelivery` sets it around the render precisely because
    # `IssueQuery#statement` reads it ambiently. Reading it ambiently HERE too would mean
    # the answer to *"may this person see this file"* depends on a global that a second
    # caller is responsible for — which is the coupling INV-1 exists to forbid. So the
    # actor is a constructor argument, and `ReportRun` passes the same one it renders
    # under.
    #
    # --- WHY `visible?` AND NOT A PERMISSION CHECK ---
    #
    # `Attachment#visible?(user)` delegates to `container.attachments_visible?(user)`,
    # which is what `AttachmentsController#download` itself authorises with. Reproducing
    # the rule here would be a second copy of a visibility decision — the defect
    # `Template.visible` was two clauses short of on its first version (T-23). Ask the
    # model.
    #
    # --- ONLY THE DOWNLOAD ROUTES, AND THE OMISSIONS ARE DELIBERATE ---
    #
    # Redmine routes four attachment shapes (`config/routes.rb:325-328`). This maps the
    # two that unambiguously denote THE FILE'S BYTES:
    #
    #     /attachments/download/:id                    -> attachments#download
    #     /attachments/download/:id/:filename          -> attachments#download
    #
    # `/attachments/:id/:filename` is `attachments#show`, an HTML PAGE about the file, so
    # mapping it to the raw bytes would answer a different question than the URL asked.
    # `/attachments/thumbnail/:id(/:size)` names a DERIVED, resized image that
    # `Attachment#thumbnail` generates through ImageMagick; substituting the full-size
    # original would put a 4000px image where a 100px one was asked for and say nothing.
    # A plausible answer that is not the one requested is the failure mode this repository
    # keeps deleting, so both are left to the resolver's named refusal instead — the
    # reader is told which URL and why, which is INV-4 and is a strictly better outcome
    # than a blank image. Recorded as a known limitation in §Findings F-16.
    #
    # --- THE FILENAME IN THE URL IS NOT CHECKED, AND CORE DOES NOT CHECK IT EITHER ---
    #
    # `attachments#download` finds by `:id` alone; the filename segment is cosmetic. So a
    # mismatched filename resolves to the file the id names, exactly as it does in a
    # browser. Diverging from core here would make a URL that works in Redmine fail in a
    # report, for no security gain — the id is the authority and `visible?` is the check.
    class AttachmentMapper
      # Anchored, and `\z`-terminated on both arms so nothing after the filename can be
      # smuggled in. The id is digits only, which is the same constraint the route places
      # on it (`:id => /\d+/`), so a non-numeric id is not an attachment URL at all rather
      # than a lookup that happens to miss.
      DOWNLOAD_PATH = %r{\A/attachments/download/(\d+)(?:/[^/]*)?\z}

      def initialize(actor:, logger: nil)
        # `unless actor` and not `if actor.nil?`. The nil form let `false` through — the
        # guard read stronger than it was, which is the one thing a guard must not do. It
        # failed closed downstream either way; this is about the message being true.
        raise ArgumentError, 'an attachment mapper needs an actor (INV-1)' unless actor

        @actor = actor
        @logger = logger
      end

      # The port's whole contract: an absolute file path, or nil. `LocalStore` types the
      # result, applies `asset_max_bytes` BEFORE reading it, and `realpath`s it — so this
      # method deliberately does no size, type or containment work of its own. Two places
      # deciding one thing is how they drift.
      def call(path)
        match = DOWNLOAD_PATH.match(path.to_s)
        return nil if match.nil?

        diskfile_for(match[1])
      end

      private

      # THE RESCUE SPANS THE LOOKUP *AND* THE VISIBILITY CALL, and an earlier draft of
      # this file guarded only the lookup while its comment claimed otherwise — the
      # cited-control defect §Findings S-28 records this project shipping four times.
      # `visible?` is the half more likely to raise: it delegates to
      # `container.attachments_visible?`, so a container whose class was removed with its
      # plugin, or a dangling `container_id`, raises from there and not from `find_by`.
      #
      # `find_by` and not `find`: a dangling id in a report body is an ordinary authoring
      # mistake, and `RecordNotFound` escaping into a render would turn it into a 500 —
      # the untyped-error shape INV-5 exists to forbid. Every arm here answers nil, which
      # the resolver turns into a refusal NAMING THE URL, so nothing becomes silent.
      #
      # `visible?` and not `readable?`: the second asks whether the file is on disk, which
      # `LocalStore` finds out for itself and reports with a reason an operator can act on
      # (`:not_found`). Answering nil for that here would collapse "you may not see this"
      # and "it is missing" into one indistinguishable outcome.
      def diskfile_for(id)
        attachment = ::Attachment.find_by(id: Integer(id, 10))
        return nil if attachment.nil?
        return nil unless attachment.visible?(@actor)

        attachment.diskfile
      rescue StandardError => e
        @logger&.warn("[reporter_dashboards] attachment #{id} could not be resolved for " \
                      "asset embedding (#{e.class}); the reference will be refused")
        nil
      end
    end
  end
end
