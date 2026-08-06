# frozen_string_literal: true

module RedmineReporterDashboards
  module Assets
    # A URL PATH -> A FILE ON DISK, or nothing. The `:bundled` row of §5.1's table is
    # this class: "same-origin Redmine URLs are **rewritten to the on-disk file** and
    # inlined; never fetched".
    #
    # --- CONTAINMENT IS `realpath`, NEVER A STRING CHECK ---
    #
    # `path.include?('..')` is not containment. It is defeated by `%2e%2e%2f`, by
    # `....//`, by a UTF-8 overlong encoding, and — the one nobody remembers — by a
    # SYMLINK inside the root that points outside it, which contains no `..` at all. So
    # the check is: decode once, join, `File.realpath`, and assert the result is inside
    # the root's own `realpath`. Anything else is nil.
    #
    # Nil rather than an exception, because "no file here" is a normal answer that the
    # resolver turns into either a fetch or a named refusal depending on policy. A raise
    # would make an ordinary missing image an internal error.
    #
    # --- MAPPERS ARE THE PORT FOR EVERYTHING REDMINE OWNS ---
    #
    # An attachment lives at `Attachment#diskfile`, which needs ActiveRecord, a
    # visibility decision and a `User.current` this layer must not have (INV-1). So
    # `mappers` is a list of callables the Redmine-facing caller supplies: given a path,
    # answer an absolute file path or nil. The visibility decision stays with the caller,
    # where the actor is explicit — this class only ever reads a file somebody upstream
    # already decided the viewer may see.
    class LocalStore
      # What was found: the bytes, and the type the engine needs in order to draw them.
      LocalFile = Struct.new(:path, :bytes, :content_type, :size, keyword_init: true) do
        def to_s
          "#{path} (#{content_type}, #{size} bytes)"
        end
      end

      # A refusal reason, so the resolver can say WHICH of the four things went wrong
      # instead of "not found".
      # `:not_found` and `:not_under_root` are DELIBERATELY SEPARATE, and the first draft
      # collapsed them. A missing stylesheet then reported "resolves outside the asset
      # root", which sends an operator to look for a traversal that is not there — the
      # single most misleading thing a diagnostic can do. `File.realpath` raises the same
      # `ENOENT` for both, so the distinction has to be made by asking whether the join
      # would have been contained.
      REASONS = {
        not_found: 'does not exist on disk',
        not_under_root: 'resolves outside the asset root',
        not_a_file: 'is not a regular file',
        unknown_type: 'has an extension this plugin will not type, so no data: URI can name it',
        wrong_type_for_usage: 'is on disk, but its type is not usable for the way the ' \
                              'document references it',
        no_root: 'matches no configured asset root'
      }.freeze

      attr_reader :roots, :reason

      def initialize(roots: {}, mappers: [])
        # Longest prefix first: `/plugin_assets/x/sub` must win over `/plugin_assets/x`
        # if both are configured, and Hash order is not a specification.
        @roots = roots.to_h { |prefix, dir| [prefix.to_s.sub(%r{/\z}, ''), File.expand_path(dir)] }
                      .sort_by { |prefix, _| -prefix.length }
                      .to_h
                      .freeze
        @mappers = Array(mappers).freeze
        @reason = nil
      end

      # The whole point of the class. `usage` is checked against the file's type, because
      # a `<link rel=stylesheet href="/plugin_assets/…/logo.png">` is either a mistake or
      # a content-type confusion, and inlining it would make the engine draw nothing and
      # say nothing.
      def file_for(path, usage: nil)
        @reason = nil
        decoded = decode(path)
        return refuse(:not_under_root) if decoded.nil?

        absolute, source = absolute_for(decoded)
        return refuse(:no_root) if absolute.nil?

        real = real_path(absolute, source)
        return refuse(File.exist?(absolute) ? :not_under_root : :not_found) if real.nil?
        return refuse(:not_a_file) unless File.file?(real)

        content_type = ContentTypes.for_path(real)
        return refuse(:unknown_type) if content_type.nil?
        # TWO DIFFERENT REFUSALS, and the first draft used one for both. "unknown type" for
        # a `.css` referenced by an `<img>` sends an operator to check the file extension,
        # which is fine — the mismatch is the DOCUMENT's, not the file's.
        return refuse(:wrong_type_for_usage) if usage && !ContentTypes.acceptable?(content_type,
                                                                                   usage)

        bytes = File.binread(real)
        LocalFile.new(path: real, bytes: bytes, content_type: content_type, size: bytes.bytesize)
      rescue SystemCallError, IOError
        # A file that exists and cannot be read — permissions, a dangling mount. Same
        # answer as absent, and NOT `rescue StandardError`: an unexpected class here is a
        # defect and must reach the caller (CLAUDE.md §5).
        refuse(:not_a_file)
      end

      def reason_text
        REASONS[@reason]
      end

      private

      def refuse(reason)
        @reason = reason
        nil
      end

      # ONE decode, then no more. Decoding twice is how `%252e%252e%252f` gets through a
      # check that ran between the two passes, so a path that still contains a percent
      # escape after one pass is refused rather than decoded again.
      def decode(path)
        text = path.to_s
        return nil if text.empty?
        return nil if text.include?("\0")

        decoded = text.gsub(/%([0-9A-Fa-f]{2})/) { [::Regexp.last_match(1)].pack('H*') }
        return nil if decoded.include?("\0")

        decoded
      end

      # Two sources, and they are containment-checked differently — which is why the
      # source travels with the answer instead of being re-derived from the path's shape.
      #
      #   :mapper  the caller answered with an absolute path of its own (an attachment's
      #            diskfile), deliberately outside every asset root. The mapper IS the
      #            decision: it is the caller's code, and it is where the visibility call
      #            was made. All this class still requires is that the path be absolute.
      #   :root    a URL prefix matched a configured directory, and the join has to be
      #            proven to stay inside it.
      def absolute_for(decoded)
        @mappers.each do |mapper|
          mapped = mapper.call(decoded)
          return [mapped.to_s, :mapper] if mapped
        end

        prefix, dir = @roots.find do |candidate, _|
          decoded == candidate || decoded.start_with?("#{candidate}/")
        end
        return [nil, nil] if prefix.nil?

        [File.join(dir, decoded[prefix.length..].to_s), :root]
      end

      # `File.realpath` raises rather than answering for a path that is not there, and
      # that raise IS the answer. The containment comparison is against the ROOT'S
      # realpath too — a root that is itself a symlink (`/var` on macOS) otherwise fails
      # every check for the wrong reason.
      def real_path(absolute, source)
        return nil unless absolute.start_with?(File::SEPARATOR)

        real = File.realpath(absolute)
        return real if source == :mapper

        @roots.each_value do |dir|
          root_real = File.realpath(dir)
          return real if real == root_real || real.start_with?("#{root_real}#{File::SEPARATOR}")
        end
        nil
      rescue Errno::ENOENT, Errno::ELOOP, Errno::ENAMETOOLONG, Errno::EACCES, Errno::ENOTDIR
        nil
      end
    end
  end
end
