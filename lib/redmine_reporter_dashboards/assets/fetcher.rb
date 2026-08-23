# frozen_string_literal: true

require 'ipaddr'
require 'net/http'
# EXPLICIT, even though `net/http` happens to pull it in on every Ruby this plugin supports.
# `use_ssl = true` raises without it, and — worse — `rescue OpenSSL::SSL::SSLError` below would
# resolve its constant only when an exception arrived, turning a missing library into a NameError
# raised from inside a rescue clause. A Ruby built `--without-openssl` is rare and the failure it
# produces here would be unreadable.
require 'openssl'
require 'socket'
require 'uri'

module RedmineReporterDashboards
  module Assets
    # THE ONLY EGRESS IN THIS PLUGIN, and every condition on it is mechanical (§5.1,
    # FR-65).
    #
    #   https only            an `http://` reference is refused even to an allowlisted host
    #   anonymous             a CLOSED header set. No cookie, no session, no API key, no
    #                         `Authorization`, ever — "assets are fetched anonymously or
    #                         not at all"
    #   2 s connect, 5 s total  wall clock, monotonic, enforced across redirects too
    #   redirect count 0      a 3xx is a refusal, not a hop
    #   size-capped           `Content-Length` when offered AND the streamed bytes, because
    #                         a header is a claim
    #   content-type-checked  against the reference's USE, not against a general allowlist
    #   IP-checked AFTER DNS  and the connection is made to THAT address, which is the
    #                         only version of this check that closes the rebinding window
    #
    # --- WHY THE TRANSPORT IS A PORT ---
    #
    # `http:` is injectable (mechanism E5) for one reason above all others: T-33's
    # acceptance list requires that "a fetch carries **no** cookie/session/API-key/
    # `Authorization` header — asserted by a request-recording double, not by reading the
    # code". A test that reads the source proves what the source says; a double that
    # records every header proves what was sent. Those are different claims, and the
    # second is the one INV-8 needs.
    #
    # --- WHY DNS REBINDING NEEDS `ipaddr=` AND NOT A SECOND LOOKUP ---
    #
    # Resolve, check the address, then connect BY NAME, and the name can resolve
    # differently the second time — that is the whole rebinding attack, and a check
    # written that way is decoration. `Net::HTTP#ipaddr=` connects to a fixed address
    # while leaving `address` as the hostname, so SNI and the `Host` header stay correct
    # and the socket goes exactly where the check looked. The check and the connection see
    # the same address by construction.
    class Fetcher
      # A refusal, as data. `reason` is for a human; `code` is for a branch.
      Refusal = Struct.new(:code, :reason, keyword_init: true)
      Fetched = Struct.new(:bytes, :content_type, :size, keyword_init: true)

      # RFC1918, loopback, link-local, CGNAT, multicast, and the IPv6 equivalents
      # including the v4-mapped forms — `::ffff:127.0.0.1` is a loopback address wearing
      # a v6 costume, and a check that only looked at `IPAddr#ipv4?` misses it.
      DENIED_RANGES = [
        '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
        '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.168.0.0/16',
        '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4',
        '240.0.0.0/4', '255.255.255.255/32',
        '::/128', '::1/128', 'fc00::/7', 'fe80::/10', 'ff00::/8',
        '::ffff:0:0/96', '2001:db8::/32'
      ].map { |cidr| IPAddr.new(cidr) }.freeze

      # THE COMPLETE SET. Not a starting point — a closed list, so adding one is a diff
      # somebody has to justify. `Accept` is per usage; nothing else varies.
      USER_AGENT = 'redmine_reporter_dashboards asset resolver'

      ACCEPT = {
        image: 'image/*',
        stylesheet: 'text/css',
        script: 'text/javascript, application/javascript',
        font: 'font/*, application/font-woff, application/font-woff2',
        media: '*/*',
        other: '*/*'
      }.freeze

      # RFC 3986's path-and-query character set. Anything outside it — a raw space, a control
      # character, a byte above 0x7E — is refused rather than sent. A CR or LF in particular is a
      # request-splitting primitive, and `Net::HTTP` answers it with a bare `ArgumentError`.
      VALID_PATH = %r{\A[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]*\z}.freeze

      REASONS = {
        scheme: 'is not https — §5.1 permits no other scheme for a fetch',
        path: 'has a path containing characters a request may not carry (RFC 3986)',
        not_allowlisted: 'host is not in asset_allowlist',
        policy: 'asset_policy does not permit fetching this reference',
        dns: 'did not resolve',
        private_address: 'resolves to a private, loopback or link-local address',
        redirect: 'answered with a redirect, and the redirect count is 0',
        status: 'answered with a non-200 status',
        too_large: 'is larger than asset_max_bytes',
        timeout: 'did not answer inside the time cap',
        content_type: 'answered with a content type that is not usable for this reference',
        transport: 'could not be fetched'
      }.freeze

      attr_reader :policy

      def initialize(policy:, http: nil, resolver: nil, logger: nil)
        @policy = policy
        @http = http || NetHttpTransport.new
        @resolver = resolver || method(:resolve_addresses)
        @logger = logger
      end

      # Returns `Fetched` or `Refusal`. Never raises for anything the network can do to
      # you — a refusal is a normal outcome and the resolver turns it into a named
      # `:asset_unresolved`, which is INV-5's shape rather than an exception escaping into
      # a render.
      def fetch(reference)
        unless policy.fetch_allowed?(reference.fetch_classification, reference.host)
          return refuse(policy.may_fetch?(reference.fetch_classification) ? :not_allowlisted : :policy,
                        reference)
        end
        return refuse(:scheme, reference) unless reference.scheme == Policy::FETCH_SCHEME

        addresses = @resolver.call(reference.host)
        return refuse(:dns, reference) if addresses.nil? || addresses.empty?

        denied = addresses.find { |address| denied_address?(address) }
        return refuse(:private_address, reference, denied) if denied

        perform(reference, addresses.first)
      end

      # Public so a caller and a spec can ask the same question about a literal address.
      def denied_address?(address)
        ip = IPAddr.new(address.to_s)
        # A v4-mapped v6 address is checked in BOTH forms: `::ffff:10.0.0.1` is inside
        # `::ffff:0:0/96` above, and its native form is inside `10.0.0.0/8`. Belt and
        # braces, because the two libraries that produce these strings disagree about
        # which form they hand back.
        candidates = [ip]
        candidates << ip.native if ip.ipv6? && ip.ipv4_mapped?
        candidates.any? { |candidate| DENIED_RANGES.any? { |range| range.include?(candidate) } }
      rescue IPAddr::Error
        true
      end

      private

      def perform(reference, address)
        deadline = monotonic + Policy::TOTAL_TIMEOUT_S
        path = request_path(reference)
        # A CONTROL CHARACTER IN THE PATH is refused here rather than left to Net::HTTP, which
        # raises `ArgumentError: path contains CR/LF` — an untyped exception escaping a method
        # documented to answer a `Refusal`. `Reference` already classifies such a URL
        # `:unresolvable`, so this is the second of two closed doors; a fetcher must not depend
        # on its caller having checked.
        return refuse(:path, reference) unless VALID_PATH.match?(path)

        response = @http.get(
          host: reference.host, port: reference.port || 443, path: path,
          address: address, headers: headers_for(reference),
          connect_timeout: Policy::CONNECT_TIMEOUT_S,
          read_timeout: remaining(deadline),
          # THE DEADLINE, not only a per-read timeout. §5.1 says "5 s total", and a per-read
          # timeout bounds each read rather than the exchange: a server that drips one byte every
          # four seconds resets the clock on every chunk and holds the connection for as long as
          # `asset_max_bytes` allows — measured at 16 s against a 5 s documented cap before this
          # was threaded through.
          deadline: deadline,
          max_bytes: policy.asset_max_bytes
        )

        return refuse(:timeout, reference) if response.timed_out
        # And re-checked after the call, so a transport that ignores the deadline cannot spend
        # more than the budget and still be believed.
        return refuse(:timeout, reference) if monotonic > deadline
        return refuse(:too_large, reference) if response.too_large
        return refuse(:redirect, reference, response.status) if redirect?(response.status)
        return refuse(:status, reference, response.status) unless response.status == 200
        return refuse(:too_large, reference) if response.body.to_s.bytesize > policy.asset_max_bytes

        content_type = ContentTypes.normalize(response.content_type)
        unless ContentTypes.acceptable?(content_type, reference.usage)
          return refuse(:content_type, reference, content_type)
        end

        Fetched.new(bytes: response.body, content_type: content_type,
                    size: response.body.to_s.bytesize)
      rescue Transport::Error => e
        # The transport's OWN error class, and nothing wider. A `StandardError` rescue
        # here would swallow a defect in this file and report it as an unreachable host.
        refuse(:transport, reference, e.message)
      end

      # Redirects are refused rather than followed, so this exists only to give the
      # refusal a truthful reason: "it redirected" is actionable and "non-200" is not.
      def redirect?(status)
        (300..399).cover?(status.to_i)
      end

      def request_path(reference)
        path = reference.url.sub(%r{\A[A-Za-z][A-Za-z0-9+.\-]*://}, '').sub(%r{\A//}, '')
        slash = path.index('/')
        slash.nil? ? '/' : path[slash..]
      end

      # THE CLOSED SET, built here and nowhere else. There is no argument through which a
      # caller can add one, which is the property the recording double asserts.
      def headers_for(reference)
        { 'User-Agent' => USER_AGENT,
          'Accept' => ACCEPT.fetch(reference.usage, '*/*'),
          'Accept-Encoding' => 'identity' }.freeze
      end

      def resolve_addresses(host)
        Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq
      rescue SocketError, ArgumentError
        nil
      end

      def refuse(code, reference, detail = nil)
        reason = REASONS.fetch(code)
        reason = "#{reason} (#{detail})" if detail
        @logger&.warn(
          "[reporter_dashboards] asset fetch refused: #{reference.display} — #{reason}"
        )
        Refusal.new(code: code, reason: reason)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def remaining(deadline)
        [deadline - monotonic, 0.1].max
      end

      # The transport port. One method, one value object, so a double is four lines.
      module Transport
        class Error < StandardError; end

        Response = Struct.new(:status, :content_type, :body, :timed_out, :too_large,
                              keyword_init: true)
      end

      # The production transport. Everything security-bearing about it is in one place:
      # `ipaddr=`, `use_ssl`, `verify_mode`, the two timeouts and the streamed size cap.
      class NetHttpTransport
        def get(host:, port:, path:, address:, headers:, connect_timeout:, read_timeout:,
                max_bytes:, deadline: nil)
          http = Net::HTTP.new(host, port)
          # The check and the connection see the same address. See the class comment.
          http.ipaddr = address
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.open_timeout = connect_timeout
          http.read_timeout = read_timeout
          http.write_timeout = read_timeout if http.respond_to?(:write_timeout=)
          http.max_retries = 0

          request = Net::HTTP::Get.new(path)
          headers.each { |name, value| request[name] = value }

          collect(http, request, max_bytes, deadline)
        rescue Net::OpenTimeout, Net::ReadTimeout
          Transport::Response.new(status: 0, content_type: nil, body: '', timed_out: true,
                                  too_large: false)
        rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, Net::HTTPBadResponse,
               Net::ProtocolError, IOError, EOFError => e
          raise Transport::Error, "#{e.class}: #{e.message}"
        rescue ArgumentError, URI::Error => e
          # `Net::HTTP` raises a bare `ArgumentError` for a path it will not send, and `URI`
          # raises its own class. Translated rather than allowed out: everything this method can
          # fail with has to arrive at the caller as a `Transport::Error`, or the fetcher's
          # "never raises for anything the network can do to you" contract is only mostly true.
          raise Transport::Error, "#{e.class}: #{e.message}"
        end

        private

        # STREAMED, and aborted past the cap. `response.body` on a 4 GB answer is a
        # memory-exhaustion primitive against a renderer that has a wall-clock budget and
        # no memory budget at all — the cap has to be applied while reading, not after.
        def collect(http, request, max_bytes, deadline)
          status = nil
          content_type = nil
          buffer = String.new(capacity: 16_384, encoding: Encoding::BINARY)
          too_large = false
          timed_out = false

          http.start do |session|
            session.request(request) do |response|
              status = response.code.to_i
              content_type = response['content-type']
              declared = response['content-length']
              # The header is a CLAIM, checked because it is cheap and then ignored in
              # favour of the bytes, which are the fact.
              if declared && declared.to_i > max_bytes
                too_large = true
                next
              end

              response.read_body do |chunk|
                buffer << chunk
                if buffer.bytesize > max_bytes
                  too_large = true
                  break
                end
                # THE TOTAL BUDGET, checked per chunk. A per-read timeout is reset by every
                # chunk, so a server that drips bytes holds the connection for as long as the
                # size cap allows — effectively unbounded. This is the only place that can stop
                # it, because it is the only place that sees each chunk arrive.
                if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                  timed_out = true
                  break
                end
              end
            end
          end

          Transport::Response.new(status: status.to_i, content_type: content_type,
                                  body: too_large || timed_out ? '' : buffer,
                                  timed_out: timed_out, too_large: too_large)
        end
      end
    end
  end
end
