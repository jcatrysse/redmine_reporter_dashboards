# frozen_string_literal: true

require 'erb'

require_relative 'record_drop'
require_relative 'user_drop'

module RedmineReporterDashboards
  module Liquid
    module Drops
      # A file attached to an issue.
      #
      # --- `file_url` IS GONE, AND IT IS A SECURITY REMOVAL ---
      #
      # The gem's attachment surface offers `file_url`, which resolves to the anonymous
      # token URL (`filters.rb:151-153`). Those tokens are `Digest::MD5` and they never
      # expire — the same mechanism §7b.1 replaces for share links. A report that
      # embeds one has published a permanent unauthenticated URL to a file whose issue
      # may be private, and it has done so in a PDF that gets forwarded.
      #
      # §3.6 lists it among the four filters dropped for a stated security reason, and
      # the replacement is `| inline` (T-19): the bytes go INTO the document, so the
      # recipient needs no URL and the URL grants nobody anything.
      #
      # `url` and `download_url` below are ordinary authenticated Redmine paths. They
      # require a session and they enforce the issue's visibility, which is precisely
      # what the token URL does not.
      class AttachmentDrop < RecordDrop
        def filename
          record.filename
        end

        def filesize
          record.filesize
        end

        def content_type
          record.content_type
        end

        def description
          record.description
        end

        def created_on
          in_actor_zone(record.created_on)
        end

        def author
          @author ||= (record.author && UserDrop.new(record.author, context: render_context))
        end

        def url
          absolute("/attachments/#{id}")
        end

        # Redmine's download route carries the filename so the browser names the file
        # correctly. It is URL-escaped here rather than interpolated raw: a filename is
        # user input, and one containing `?` or `#` would otherwise truncate the path.
        def download_url
          absolute("/attachments/download/#{id}/#{escape(filename)}")
        end

        def to_s
          filename.to_s
        end

        private

        # `CGI.escape` encodes a space as `+`, which is wrong in a path segment.
        # `ERB::Util.url_encode` is the right one and it is stdlib, so this needs no
        # ActiveSupport — which matters because the drop specs run against the bare
        # Liquid gem.
        def escape(value)
          ERB::Util.url_encode(value.to_s)
        end
      end
    end
  end
end
