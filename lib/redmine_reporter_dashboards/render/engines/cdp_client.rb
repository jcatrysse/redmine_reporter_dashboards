# frozen_string_literal: true

require 'json'
require 'base64'
require 'fcntl'
require 'fileutils'
require 'securerandom'
require 'tmpdir'

module RedmineReporterDashboards
  module Render
    module Engines
      # The Chrome DevTools Protocol, over a PIPE.
      #
      # --- WHY A PIPE AND NOT A PORT ---
      #
      # The usual way to drive Chromium is `--remote-debugging-port=9222` and a
      # WebSocket. That opens a control channel on a TCP socket, and a DevTools endpoint
      # is a total-control endpoint: anything that can reach it can navigate the browser,
      # read any page it has open, and fetch arbitrary URLs *from inside the render
      # host*. On a box that runs Redmine, a render engine holding an open debugging
      # port is an SSRF primitive with a documentation page.
      #
      # `--remote-debugging-pipe` gives the same protocol over inherited file
      # descriptors 3 and 4 — NUL-delimited JSON, no listener, nothing to reach from off
      # the box, and no port to forget to firewall. It also removes the WebSocket
      # handshake and frame masking, which is a hundred lines of code this file does not
      # contain.
      #
      # --- THE TRAP THAT COST AN HOUR, WRITTEN DOWN ---
      #
      # Ruby's `IO.pipe` returns descriptors with `O_NONBLOCK` SET, and that flag lives
      # on the open file description — so the child inherits it. Chromium's pipe reader
      # treats the resulting `EAGAIN` as a closed connection: it answers EXACTLY ONE
      # command, logs "Connection terminated while reading from pipe", and exits. The
      # symptom is a browser that responds to `Browser.getVersion` and then dies on
      # whatever you send second, which reads as a CDP protocol error and is nothing of
      # the kind. `blocking!` below is the whole fix.
      #
      # --- NEVER RAISES PAST THE ADAPTER ---
      #
      # Everything here can throw `CdpError`. The adapter converts it into a typed
      # `Failure`; nothing above this file ever sees an exception from a browser.
      class CdpClient
        class CdpError < StandardError; end
        class LaunchFailed < CdpError; end
        class ProtocolTimeout < CdpError; end

        # Chromium's own default is 128 KiB per read; this is the harness side and only
        # affects how many syscalls a big PDF costs.
        READ_CHUNK = 1 << 16

        # --- THE FLAGS, AND WHY EACH ONE IS HERE ---
        #
        # Not a copied incantation. Every flag below closes something, and the ones that
        # are ABSENT matter as much as the ones present:
        #
        #   --no-sandbox is NOT set, and never will be. A browser rendering
        #   attacker-influenced HTML with its sandbox off is the configuration this whole
        #   design exists to avoid. Chromium refuses to run as root without it, which
        #   means "run the render process as a non-root user" is enforced by the browser
        #   rather than by a note in a README.
        BASE_FLAGS = [
          '--headless=new',
          # --- EGRESS DENIAL, IN TWO PARTS, AND THE FIRST PART IS NOT ENOUGH ---
          #
          # `--host-resolver-rules` only rewrites NAME RESOLUTION. A URL that carries a
          # literal IP address never asks the resolver anything, so this flag alone lets
          # `http://127.0.0.1:8080/` and `http://10.0.0.5/` straight through. Conformance
          # fixture F-15 caught exactly that: with only this flag set, four subresources
          # — a stylesheet, an image, an XHR and a fetch — arrived at the harness's own
          # listening socket. The flag looked like a control and was half of one.
          #
          # So every scheme that can reach the network is also pointed at a proxy that
          # does not exist, and the implicit localhost bypass is REMOVED (`<-loopback>`),
          # because localhost is where a Redmine host keeps everything worth stealing:
          # the application itself, a metadata service, a database admin panel. Requests
          # then fail at connect, before DNS, before TCP to the real target.
          '--host-resolver-rules=MAP * 0.0.0.0',
          '--proxy-server=127.0.0.1:1',
          '--proxy-bypass-list=<-loopback>',
          '--disable-background-networking',
          '--disable-component-update',
          '--disable-domain-reliability',
          '--disable-client-side-phishing-detection',
          '--disable-sync',
          '--no-first-run',
          '--no-default-browser-check',
          '--disable-extensions',
          '--disable-gpu',
          # /dev/shm is 64 MB in most containers and Chromium will crash on a large
          # document without this. A crash that only happens on big reports is the worst
          # kind of intermittent.
          '--disable-dev-shm-usage',
          '--mute-audio',
          '--disable-default-apps',
          '--metrics-recording-only',
          '--no-pings',
          # Nothing may be written anywhere except the profile we hand it.
          '--disable-background-timer-throttling',
          '--disable-backgrounding-occluded-windows',
          '--disable-renderer-backgrounding'
        ].freeze

        # Where to look, in order. `RRD_CHROMIUM_BINARY` first so an operator can pin a
        # build without editing code, and a Playwright-managed browser last because a
        # developer machine often has one and a server never does.
        BINARY_CANDIDATES = %w[
          chromium chromium-browser google-chrome-stable google-chrome chrome
        ].freeze

        attr_reader :binary, :pid

        def initialize(binary: nil, extra_flags: [], launch_timeout_ms: 20_000)
          @binary = binary || self.class.detect_binary
          @extra_flags = Array(extra_flags)
          @launch_timeout_ms = Integer(launch_timeout_ms)
          @next_id = 0
          @buffer = +''
          @pending = {}
          @profile_dir = nil
        end

        class << self
          def detect_binary
            from_env = ENV['RRD_CHROMIUM_BINARY'].to_s
            return from_env unless from_env.empty?

            BINARY_CANDIDATES.each do |name|
              path = which(name)
              return path if path
            end
            playwright_binary || BINARY_CANDIDATES.first
          end

          def which(name)
            ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
              candidate = File.join(dir, name)
              return candidate if File.executable?(candidate) && !File.directory?(candidate)
            end
            nil
          end

          # A developer machine that has run Playwright has a browser here. A server
          # does not, which is why this is the last place looked rather than the first.
          def playwright_binary
            root = ENV['PLAYWRIGHT_BROWSERS_PATH'].to_s
            return nil if root.empty?

            Dir[File.join(root, 'chromium-*', 'chrome-linux', 'chrome')].sort.last
          end
        end

        def running?
          return false unless @pid

          Process.waitpid(@pid, Process::WNOHANG).nil?
        rescue Errno::ECHILD
          false
        end

        def start
          return self if running?

          @profile_dir = Dir.mktmpdir('rrd-chromium-profile')
          spawn_browser
          @version = command('Browser.getVersion', {}, timeout_ms: @launch_timeout_ms)
                     .fetch('product', 'Chromium/unknown')
          self
        rescue CdpError
          stop
          raise
        end

        def version
          start unless running?
          @version
        end

        # One page target, attached flat so its session rides the same pipe. Created
        # fresh per render rather than reused: a page carries the previous document's
        # timers, listeners and JavaScript state, and a readiness signal left set by the
        # last render would make the next one look instantly ready.
        def with_page
          start unless running?
          target_id = command('Target.createTarget', { url: 'about:blank' }).fetch('targetId')
          channel = command('Target.attachToTarget',
                            { targetId: target_id, flatten: true }).fetch('sessionId')
          yield Page.new(self, target_id, channel)
        ensure
          if target_id
            begin
              command('Target.closeTarget', { targetId: target_id }, timeout_ms: 2_000)
            rescue CdpError
              nil
            end
          end
        end

        # Send one command and wait for its reply. Events and other sessions' replies
        # are drained rather than queued: nothing in this adapter subscribes to events,
        # and an unbounded buffer of them is a slow memory leak in a long-lived process.
        # `channel` is the CDP session id. Named `channel` on the Ruby side on purpose:
        # `script/gates/layer_purity.sh` forbids the word "session" under `render/**`,
        # and it is right to — an HTTP session in the render layer would mean the layer
        # can make a visibility decision, which belongs upstream of it (INV-1/INV-3).
        # A CDP session is a protocol multiplexing id and has nothing to do with that,
        # so the wire spelling `sessionId` is exempted in the gate and the Ruby spelling
        # avoids the collision entirely rather than leaning on the exemption.
        def command(method, params = {}, channel: nil, timeout_ms: 30_000)
          id = (@next_id += 1)
          message = { id: id, method: method, params: params }
          message[:sessionId] = channel if channel
          write(JSON.generate(message))

          reply = await(id, timeout_ms)
          error = reply['error']
          raise CdpError, "#{method}: #{error['message']} (#{error['code']})" if error

          reply.fetch('result', {})
        end

        def stop
          if @pid
            begin
              Process.kill('TERM', @pid)
              wait_for_exit(2_000) || Process.kill('KILL', @pid)
              Process.waitpid(@pid)
            rescue Errno::ESRCH, Errno::ECHILD
              nil
            end
          end
          [@writer, @reader].each { |io| io&.close unless io&.closed? }
          FileUtils.rm_rf(@profile_dir) if @profile_dir
        ensure
          @pid = nil
          @writer = nil
          @reader = nil
          @profile_dir = nil
        end

        private

        def spawn_browser
          child_read, @writer = IO.pipe
          @reader, child_write = IO.pipe
          # THE TRAP. See the class comment: an inherited O_NONBLOCK makes Chromium
          # hang up after one command, and the failure reads like a protocol bug.
          blocking!(child_read)
          blocking!(child_write)
          @writer.sync = true

          argv = [@binary, *BASE_FLAGS, "--user-data-dir=#{@profile_dir}", *@extra_flags,
                  '--remote-debugging-pipe', 'about:blank']
          @stderr_path = File.join(@profile_dir, 'chromium.stderr')

          @pid = Process.spawn(*argv, 3 => child_read, 4 => child_write,
                                      out: File::NULL, err: @stderr_path)
          child_read.close
          child_write.close
        rescue Errno::ENOENT, Errno::EACCES => e
          raise LaunchFailed, launch_message(e)
        end

        def launch_message(error)
          hint = if Process.uid.zero?
                   ' — and note that Chromium refuses to run as root without ' \
                   '--no-sandbox, which this adapter deliberately does not set. Run the ' \
                   'render process as a non-root user.'
                 else
                   ''
                 end
          "cannot start #{@binary.inspect}: #{error.class}: #{error.message}#{hint}"
        end

        def blocking!(io)
          io.fcntl(Fcntl::F_SETFL, io.fcntl(Fcntl::F_GETFL) & ~Fcntl::O_NONBLOCK)
        end

        def write(payload)
          @writer.write("#{payload}\0")
        rescue Errno::EPIPE, IOError => e
          raise CdpError, "the browser closed the control pipe: #{e.class}#{stderr_tail}"
        end

        # Blocking read with a DEADLINE, monotonic. A wedged renderer — a synchronous
        # infinite loop in a template's script is the ordinary case — never answers, and
        # a read without a deadline here is the 504-with-a-burning-worker failure T-15
        # is written to prevent.
        def await(id, timeout_ms)
          deadline = monotonic + (timeout_ms / 1000.0)
          loop do
            message = next_message(deadline)
            return message if message['id'] == id
            # A reply to a command we have already given up on, or an event. Dropped.
          end
        end

        def next_message(deadline)
          loop do
            if (index = @buffer.index("\0"))
              return JSON.parse(@buffer.slice!(0..index).chomp("\0"))
            end

            remaining = deadline - monotonic
            raise ProtocolTimeout, "the browser did not answer within the deadline#{stderr_tail}" if
              remaining <= 0

            ready = IO.select([@reader], nil, nil, remaining)
            raise ProtocolTimeout, "the browser did not answer within the deadline#{stderr_tail}" unless ready

            begin
              @buffer << @reader.readpartial(READ_CHUNK)
            rescue EOFError
              raise CdpError, "the browser exited while we were waiting for it#{stderr_tail}"
            end
          end
        end

        # Chromium's stderr is where the real reason lives — a missing shared library, a
        # sandbox refusal, a crashed GPU process. Carrying the tail of it into the error
        # message is the difference between "the browser did not answer" and a diagnosis.
        def stderr_tail(lines: 3)
          return '' unless @stderr_path && File.exist?(@stderr_path)

          tail = File.readlines(@stderr_path, encoding: 'UTF-8')
                     .reject { |line| line.include?('dbus') }
                     .last(lines).map(&:strip).reject(&:empty?)
          tail.empty? ? '' : " [chromium: #{tail.join(' | ')}]"
        rescue StandardError
          ''
        end

        def wait_for_exit(timeout_ms)
          deadline = monotonic + (timeout_ms / 1000.0)
          while monotonic < deadline
            return true if Process.waitpid(@pid, Process::WNOHANG)

            sleep 0.02
          end
          false
        rescue Errno::ECHILD
          true
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # One attached page, and the four things this adapter ever asks of one.
        class Page
          attr_reader :target_id, :channel

          def initialize(client, target_id, channel)
            @client = client
            @target_id = target_id
            @channel = channel
          end

          def call(method, params = {}, timeout_ms: 30_000)
            @client.command(method, params, channel: @channel, timeout_ms: timeout_ms)
          end

          # `Page.setDocumentContent` rather than a `data:` URL or a temporary file: the
          # document never touches the filesystem and never becomes a navigable URL, so
          # there is nothing for a later navigation, a bookmark or a crash dump to pick
          # up. It also keeps the origin opaque, which is what makes the document unable
          # to read anything of its own accord.
          def set_content(html, timeout_ms:)
            call('Page.enable', {}, timeout_ms: timeout_ms)
            call('Page.setDocumentContent', { frameId: @target_id, html: html },
                 timeout_ms: timeout_ms)
          end

          def evaluate(expression, timeout_ms: 5_000)
            result = call('Runtime.evaluate',
                          { expression: expression, returnByValue: true, awaitPromise: false },
                          timeout_ms: timeout_ms)
            result.dig('result', 'value')
          end

          def print_to_pdf(params, timeout_ms:)
            data = call('Page.printToPDF', params, timeout_ms: timeout_ms).fetch('data')
            Base64.decode64(data)
          end
        end
      end
    end
  end
end
