# frozen_string_literal: true

module RedmineReporterDashboards
  module Assets
    # THIS INSTALL'S OWN BASE URL, as a value object — and the answer to the question
    # F-15 asked: *where does an absolute plugin-asset URL come from?*
    #
    # It comes from `Setting.protocol` and `Setting.host_name`, which is what Redmine
    # itself uses everywhere it must build a URL with no request to hang one off — mail,
    # notifications, and this. `Liquid::Drops::AbsoluteUrl` already wraps exactly that
    # pair for the drop layer; this is the same fact, parsed, for a layer that must
    # COMPARE hosts rather than concatenate them.
    #
    # **And having found it: an absolute URL is the wrong tool for a bundled asset.**
    # `<script src="https://redmine.example/plugin_assets/…">` turns a file that is
    # sitting on the same disk as the renderer into an EGRESS REQUIREMENT — one that
    # fails on every install where the application cannot reach itself by its public
    # name (internal DNS, a reverse proxy terminating TLS, a container with no route
    # back), and one that `asset_policy: :bundled` exists to refuse. The resolver's
    # answer is the opposite direction: a same-origin URL is mapped BACK to the file on
    # disk and inlined. So this class exists to recognise "that is us" — never to build
    # a URL for the renderer to go and fetch.
    #
    # `Setting.host_name` may carry a path prefix (`redmine.example/redmine`), and it is
    # preserved for the same reason `AbsoluteUrl` preserves it: an install mounted under
    # a sub-path is exactly the install where a hand-built URL goes wrong.
    class Origin
      DEFAULT_PORTS = { 'http' => 80, 'https' => 443 }.freeze

      attr_reader :scheme, :host, :port, :prefix

      # nil host is a legitimate state, not an error: a bare RSpec process and a rake
      # task with no configured `host_name` both have one, and the resolver's answer is
      # then "nothing is same-origin", which is the fail-closed direction.
      def self.parse(base_url)
        text = base_url.to_s.strip
        return new if text.empty?

        scheme, rest =
          if (match = text.match(%r{\A([A-Za-z][A-Za-z0-9+.\-]*)://(.*)\z}))
            [match[1].downcase, match[2]]
          else
            ['http', text.sub(%r{\A//}, '')]
          end

        authority, _, path = rest.partition('/')
        host, port = split_authority(authority)
        return new if host.nil?

        new(scheme: scheme, host: host, port: port || DEFAULT_PORTS[scheme],
            prefix: path.empty? ? '' : "/#{path.sub(%r{/\z}, '')}")
      end

      # `Setting.protocol` + `Setting.host_name`, kept in one place so a caller in the
      # Redmine-facing layer reads two settings and nothing else.
      def self.from_settings(protocol, host_name)
        parse("#{protocol}://#{host_name}")
      end

      # PUBLIC, and `Reference` is the second caller. A pure `host[:port]` parser with no
      # security surface of its own — the checks that matter are the allowlist and the
      # post-resolution IP check, both elsewhere. Reaching it with `send` from another
      # file would be the same "resolve a name past its visibility" shape §3.6 removes
      # `call_method` for, so it says public here instead.
      def self.split_authority(authority)
        return [nil, nil] if authority.to_s.empty?
        # IPv6 literal — `[::1]:3000`. Split on the LAST colon only outside the brackets.
        if authority.start_with?('[')
          host, _, rest = authority.partition(']')
          return ["#{host}]".downcase, rest.start_with?(':') ? Integer(rest[1..], 10) : nil]
        end

        host, colon, port = authority.rpartition(':')
        return [authority.downcase, nil] if colon.empty?
        return [authority.downcase, nil] unless /\A\d+\z/.match?(port)

        [host.downcase, Integer(port, 10)]
      rescue ArgumentError
        [authority.to_s.downcase, nil]
      end

      def initialize(scheme: nil, host: nil, port: nil, prefix: '')
        @scheme = scheme&.downcase
        @host = host&.downcase
        @port = port
        @prefix = prefix.to_s
        freeze
      end

      def known?
        !host.nil?
      end

      # HOST AND PORT, never host alone. `redmine.example:3000` and
      # `redmine.example:8080` are different origins, and treating them as one is how a
      # development instance's asset gets inlined into a production report.
      def same?(other_host, other_port, other_scheme = nil)
        return false unless known?
        return false unless host == other_host.to_s.downcase

        # FAIL CLOSED on a port that cannot be determined. The first version ended
        # `|| port`, i.e. "if I cannot work out the port, assume it is ours" — which in a
        # same-origin test means "assume this reference is local and may be read off disk".
        # That branch is unreachable through `Reference` today (a scheme this layer will not
        # fetch is classified `:unresolvable` before it gets here), but the default was the
        # wrong way round and a later caller would have inherited it.
        effective_other = other_port || DEFAULT_PORTS[other_scheme.to_s]
        return false if effective_other.nil?

        effective_other == port
      end

      # The path a same-origin URL refers to, with this install's mount prefix removed —
      # so `/redmine/plugin_assets/x.png` on a sub-path install becomes
      # `/plugin_assets/x.png`, which is what `LocalStore` knows how to map.
      def strip_prefix(path)
        return path if prefix.empty?
        return path unless path.start_with?("#{prefix}/") || path == prefix

        stripped = path[prefix.length..].to_s
        stripped.empty? ? '/' : stripped
      end

      def to_s
        return '' unless known?

        default = DEFAULT_PORTS[scheme]
        authority = port && port != default ? "#{host}:#{port}" : host
        "#{scheme}://#{authority}#{prefix}"
      end
    end
  end
end
