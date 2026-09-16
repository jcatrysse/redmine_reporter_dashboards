# frozen_string_literal: true

module RedmineReporterDashboards
  module Assets
    # A CLOSED extension -> content-type map, and a CLOSED usage -> acceptable-type
    # check. Both are closed for the same reason `Render::Capabilities::ALL` is: an open
    # map lets a reference declare its own type, and a type nobody checked is what turns
    # `<img src="/x.svg">` into a script-execution surface on an engine that honours
    # SVG's `<script>`.
    #
    # Deliberately NOT `Rack::Mime` or `MiniMime`. This layer runs in a bare RSpec
    # process with no Rails (mechanism E2), and a lookup table with 800 entries answers
    # a question nobody asked: what a REPORT may contain is a much smaller set than what
    # a web server may serve.
    module ContentTypes
      BY_EXTENSION = {
        '.png' => 'image/png',
        '.jpg' => 'image/jpeg',
        '.jpeg' => 'image/jpeg',
        '.gif' => 'image/gif',
        '.webp' => 'image/webp',
        '.svg' => 'image/svg+xml',
        '.ico' => 'image/x-icon',
        '.bmp' => 'image/bmp',
        '.css' => 'text/css',
        '.js' => 'text/javascript',
        '.mjs' => 'text/javascript',
        '.woff' => 'font/woff',
        '.woff2' => 'font/woff2',
        '.ttf' => 'font/ttf',
        '.otf' => 'font/otf',
        '.eot' => 'application/vnd.ms-fontobject'
      }.freeze

      # What each usage may legitimately be. A stylesheet reference answering with
      # `image/png` is either a misconfiguration or a content-type confusion attack, and
      # both are refusals rather than "inline it and hope".
      ACCEPTABLE = {
        image: %w[image/png image/jpeg image/gif image/webp image/svg+xml image/x-icon
                  image/vnd.microsoft.icon image/bmp].freeze,
        stylesheet: %w[text/css].freeze,
        script: %w[text/javascript application/javascript application/ecmascript
                   application/x-javascript text/ecmascript].freeze,
        font: %w[font/woff font/woff2 font/ttf font/otf font/sfnt
                 application/vnd.ms-fontobject application/font-woff
                 application/font-woff2 application/x-font-ttf
                 application/x-font-otf].freeze,
        # `:other` is `<object data>` / `<embed src>`. Nothing is acceptable: an
        # embedded plugin object in a report is not a subresource this plugin will
        # resolve, and refusing NAMES it rather than leaving a silent gap (INV-4).
        other: [].freeze
      }.freeze

      module_function

      # nil for an extension this layer does not know. The caller REFUSES on nil rather
      # than guessing `application/octet-stream`: a `data:` URI needs a real type, and
      # an engine handed the wrong one draws nothing and says nothing.
      def for_path(path)
        BY_EXTENSION[File.extname(path.to_s).downcase]
      end

      # `text/css; charset=utf-8` is a `text/css`. Parameters are dropped before
      # comparison, and the comparison is case-insensitive, because both are true of
      # every real server and neither is true of a naive `==`.
      def normalize(content_type)
        content_type.to_s.split(';', 2).first.to_s.strip.downcase
      end

      def acceptable?(content_type, usage)
        allowed = ACCEPTABLE[usage.to_sym]
        return false if allowed.nil?

        allowed.include?(normalize(content_type))
      end

      # SVG is an image AND a document with script and external-reference surface. It is
      # accepted as an `<img>` source — where every engine treats it as an image and
      # runs nothing — and the caller is expected not to inline it into markup position.
      def svg?(content_type)
        normalize(content_type) == 'image/svg+xml'
      end
    end
  end
end
