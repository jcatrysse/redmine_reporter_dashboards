# frozen_string_literal: true

require_relative '../spec_helper'
require 'tmpdir'
require_relative '../../lib/redmine_reporter_dashboards/render/engines/chromium_cdp'
require_relative '../../lib/redmine_reporter_dashboards/render/engines/wkhtmltopdf'
require_relative '../../lib/redmine_reporter_dashboards/render/engine_catalogue'

module RedmineReporterDashboards
  module Render
    module Engines
      # WHAT THIS FILE IS FOR, and what it deliberately is not.
      #
      # The conformance corpus (`spec/conformance/`) is what proves an engine DOES the
      # right thing, and it needs the engine. This file proves the adapter ASKS for the
      # right thing, and it needs nothing — no browser, no binary, no database. That
      # matters twice over:
      #
      #   * it runs in the ordinary `rspec` job, on every branch, on every push, where
      #     the corpus does not;
      #   * it is the ONLY verification available for `:wkhtmltopdf`, whose binary is
      #     not installable in the container this was developed in. An argv assertion is
      #     a weaker claim than a rendered page and it is not nothing: the flags in
      #     question are the ones whose absence is a security or correctness defect, and
      #     the corpus will judge the rest in CI.
      #
      # Read every example here as "the adapter asked for X", never as "the engine did X".
      RSpec.describe 'the render adapters' do
        def request(**overrides)
          DocumentRequest.new(
            body: '<html><body>x</body></html>', correlation_id: 'spec', **overrides
          )
        end

        describe ChromiumCdp do
          subject(:adapter) { described_class.new(binary: '/nonexistent/chrome') }

          it 'is registered under its own id, and the registry is a closed map' do
            expect(Registry.fetch(:chromium_cdp)).to eq(described_class)
            expect { Registry.fetch(:not_an_engine) }.to raise_error(Registry::UnknownEngine)
          end

          it 'declares exactly what config/capabilities.yml declares for it' do
            declared = EngineCatalogue.load['chromium_cdp'].capabilities
            expect(adapter.capabilities.sort).to eq(declared.sort)
          end

          # --- THE FLAGS, WHICH ARE THE SECURITY POSTURE ---

          # Chromium refuses to run as root without it, and that refusal is how "run the
          # render process as a non-root user" stops being a line in a README. A future
          # commit adding this flag to make a CI job green would be trading the entire
          # threat model for a tick, so the absence is asserted rather than assumed.
          it 'never passes --no-sandbox' do
            expect(CdpClient::BASE_FLAGS).not_to include('--no-sandbox')
            expect(CdpClient::BASE_FLAGS.join(' ')).not_to include('no-sandbox')
          end

          # Conformance fixture F-15 found this the hard way: with only the resolver
          # rule set, four subresources reached the harness's own listening socket,
          # because a URL carrying a literal IP never asks the resolver anything. Both
          # halves are asserted here so the pair cannot be separated by a later edit
          # that "tidies up the flags".
          it 'denies egress by name AND by address' do
            flags = CdpClient::BASE_FLAGS

            expect(flags).to include('--host-resolver-rules=MAP * 0.0.0.0')
            expect(flags).to include('--proxy-server=127.0.0.1:1')
            expect(flags).to include('--proxy-bypass-list=<-loopback>'),
                             'without this, localhost is exempt from the proxy — and localhost is ' \
                             'where a Redmine host keeps everything worth stealing'
          end

          it 'opens no debugging port; the control channel is a pipe' do
            expect(CdpClient::BASE_FLAGS.join(' ')).not_to include('remote-debugging-port')
          end

          # --- THE REQUEST, TRANSLATED ---

          it 'converts millimetres to inches and keeps A4 at A4' do
            options = adapter.send(:print_options, request(page_size: 'A4'))

            expect(options[:paperWidth]).to be_within(0.01).of(8.2677)
            expect(options[:paperHeight]).to be_within(0.01).of(11.6929)
          end

          it 'swaps the axes for landscape rather than asking the engine to rotate' do
            options = adapter.send(:print_options, request(page_size: 'A4', orientation: :landscape))

            expect(options[:paperWidth]).to be > options[:paperHeight]
          end

          # The default that costs every badge colour if it is passed through.
          it 'prints backgrounds by default, against the engine default of false' do
            expect(adapter.send(:print_options, request)[:printBackground]).to be(true)
            expect(adapter.send(:print_options, request(print_backgrounds: false))[:printBackground])
              .to be(false)
          end

          it 'sends no header or footer document when there is no furniture' do
            expect(adapter.send(:print_options, request)[:displayHeaderFooter]).to be(false)
          end

          # --- PAGE FURNITURE, where two defects lived ---

          it 'compiles the closed token set into this engine and no other' do
            html = adapter.send(:compile_tokens, '{{page}} of {{pages}}')

            expect(html).to include('<span class="pageNumber"></span>')
            expect(html).to include('<span class="totalPages"></span>')
            expect(html).not_to include('[page]'), 'that is wkhtmltopdf\'s spelling'
          end

          # F-04 caught this in pixels: Chromium collapses a whitespace-only text node
          # next to an inline element in the footer document, and `Page {{page}} of
          # {{pages}}` printed as "Page1of3".
          it 'keeps the spaces around a token, which this engine otherwise eats' do
            html = adapter.send(:compile_tokens, 'Page {{page}} of {{pages}}')

            expect(html).to include('Page&nbsp;')
            expect(html).to include('&nbsp;of&nbsp;')
            expect(html).not_to match(/Page <span/)
          end

          it 'escapes literal slot text rather than interpolating it as markup' do
            html = adapter.send(:compile_tokens, '<b>x</b> & "y" {{page}}')

            expect(html).to include('&lt;b&gt;x&lt;/b&gt;')
            expect(html).to include('&amp;')
            expect(html).to include('<span class="pageNumber"></span>')
          end

          it 'leaves a token it has no native spelling for as literal text' do
            expect(adapter.send(:compile_tokens, '{{engine}}')).to include('{{engine}}')
          end

          # --- FAILURE, WITHOUT A BROWSER ---

          # The whole point of `Result`: a missing binary is a typed refusal, not an
          # exception on its way to a mailer, and not a zero-byte PDF.
          it 'answers a typed Failure when the binary is not there' do
            result = described_class.new(binary: '/nonexistent/chrome').render(request)

            expect(result).to be_a(Failure)
            expect(result.code).to eq(:engine_unavailable)
            expect(result.correlation_id).to eq('spec')
            expect { result.bytes }.to raise_error(NoMethodError)
          end
        end

        describe Wkhtmltopdf do
          subject(:adapter) { described_class.new(binary: '/nonexistent/wkhtmltopdf') }

          def argv(**overrides)
            adapter.send(:build_argv, request(**overrides), '/tmp/out.pdf')
          end

          it 'is registered, and is not the default engine' do
            expect(Registry.fetch(:wkhtmltopdf)).to eq(described_class)
            expect(EngineCatalogue.load.default_engine.id).to eq('chromium_cdp')
          end

          it 'declares exactly what config/capabilities.yml declares for it' do
            declared = EngineCatalogue.load['wkhtmltopdf'].capabilities
            expect(adapter.capabilities.sort).to eq(declared.sort)
          end

          it 'declares neither a readiness expression nor tagged PDF, which it cannot do' do
            expect(adapter.capabilities).not_to include(:readiness_expression)
            expect(adapter.capabilities).not_to include(:tagged_pdf)
            expect(adapter.capabilities).not_to include(:asset_http)
          end

          # --- THE FLAG THIS TASK EXISTS TO REMOVE ---
          #
          # Today's render path passes `no_stop_slow_scripts: true` with a flat
          # `javascript_delay: 3000`: the engine's only protection against a script that
          # never returns, switched off, with a guess in its place. Both halves are
          # asserted absent, because re-adding either would restore the defect while
          # every other test stayed green.
          it 'leaves the runaway-script guard ON' do
            expect(argv.join(' ')).not_to include('no-stop-slow-scripts')
          end

          it 'waits for the readiness status, not for a fixed delay' do
            line = argv(readiness: Readiness.new).join(' ')

            expect(line).to include("--window-status #{Readiness::STATUS}")
            # The floor closes --window-status's own race (a status set before the
            # watcher started); it is not a guess at how long charts take.
            expect(line).to include("--javascript-delay #{Readiness::WINDOW_STATUS_FLOOR_MS}")
            expect(line).not_to include('--javascript-delay 3000')
          end

          it 'asks for no readiness machinery at all when the caller wanted none' do
            expect(argv.join(' ')).not_to include('--window-status')
          end

          # INV-8 in this engine's vocabulary: it cannot fetch, so it cannot be made
          # into an SSRF by a template that names a URL.
          # Both halves, for the same reason they are asserted together for Chromium:
          # the first CI run of this adapter watched three subresources reach the
          # harness's socket with only the file-access flag set.
          it 'denies the filesystem AND the network' do
            expect(argv).to include('--disable-local-file-access')
            expect(argv.join(' ')).to include('--proxy 127.0.0.1:1'),
                                      'file-access denial does not stop it reaching the network — F-15 measured that'
          end

          it 'carries margins in millimetres, per edge' do
            line = argv(margins_mm: { 'top' => 25, 'right' => 5, 'bottom' => 25, 'left' => 5 }).join(' ')

            expect(line).to include('--margin-top 25mm')
            expect(line).to include('--margin-left 5mm')
          end

          it 'passes the page size and orientation it was asked for' do
            expect(argv(page_size: 'Letter').join(' ')).to include('--page-size Letter')
            expect(argv(orientation: :landscape).join(' ')).to include('--orientation Landscape')
            expect(argv.join(' ')).to include('--orientation Portrait')
          end

          it 'prints backgrounds by default and suppresses them only when asked' do
            expect(argv).to include('--background')
            expect(argv(print_backgrounds: false)).to include('--no-background')
          end

          it 'compiles the token set into wkhtmltopdf spelling and no other' do
            furniture = PageFurniture.new(right: '{{page}}/{{pages}}')
            line = argv(footer: furniture).join(' ')

            expect(line).to include('[page]/[topage]')
            expect(line).not_to include('pageNumber'), 'that is the Chromium spelling'
          end

          it 'reads the document from stdin and writes the PDF to a file' do
            expect(argv.last(2)).to eq(['-', '/tmp/out.pdf'])
          end

          # --- WHAT IT SAYS ABOUT ITSELF ---

          # A PDF drawn by a deprecated engine has to say so somewhere a reader can find
          # it six months later, and a degradation is the channel that already reaches
          # the diagnostics view, the log and the document metadata.
          it 'stamps every result as drawn by a legacy engine' do
            degradations = adapter.send(:degradations, request)

            expect(degradations.map(&:capability)).to include(:legacy_engine)
            expect(degradations.first.detail).to include('scheduled for removal')
          end

          it 'records each capability the request wanted and it lacks' do
            wanted = request(required_capabilities: %i[tagged_pdf outline])
            expect(adapter.send(:degradations, wanted).map(&:capability))
              .to include(:tagged_pdf, :outline)
          end

          it 'is declared deprecated in the catalogue, with a removal condition' do
            entry = EngineCatalogue.load['wkhtmltopdf']

            expect(entry).to be_deprecated
            expect(entry.deprecation).to include('two releases')
          end

          it 'answers a typed Failure when the binary is not there' do
            result = adapter.render(request)

            expect(result).to be_a(Failure)
            expect(result.code).to eq(:engine_unavailable)
            expect { result.bytes }.to raise_error(NoMethodError)
          end

          # A BINARY THAT EXISTS AND CANNOT BE EXECUTED IS THE OPERATOR'S, and it used to
          # share both the code and the sentence with "not installed" (§Findings E-29's
          # recommendation, taken). The two are one `chmod` apart and only one of them is
          # ambiguous: `ENOENT` might be a missing package or a mistyped
          # `RRD_WKHTMLTOPDF_BINARY` and this side cannot tell, while `EACCES` has exactly
          # one remedy.
          it 'tells a binary it may not execute apart from one that is not there' do
            Dir.mktmpdir do |dir|
              present = File.join(dir, 'wkhtmltopdf')
              File.write(present, "#!/bin/sh\nexit 0\n")
              File.chmod(0o000, present)

              denied = described_class.new(binary: present).render(request)
              absent = described_class.new(binary: File.join(dir, 'nope')).render(request)

              expect(denied.code).to eq(:engine_misconfigured)
              expect(denied.message).to include('cannot be executed')
              expect(denied.detail).to include('EACCES')
              expect(absent.code).to eq(:engine_unavailable)
              expect(absent.message).to include('not installed')
            end
          end

          # --- REGRESSION, and the corpus in CI is what found it ---
          #
          # Rewriting `run` to use `IO.select` replaced a block that also contained
          # `engine_failure`, so every NON-ZERO EXIT raised `NoMethodError` instead of
          # producing a typed Failure — an exception reaching the caller, which is the
          # exact defect `Result` exists to prevent, reintroduced by a refactor that
          # looked local. Nothing here noticed because this path needs the engine to run
          # AND fail, and only conformance fixture F-15 makes it do that.
          #
          # `/bin/false` is a binary that exists, starts, reads nothing and exits 1 —
          # which is the shape of the failure path without needing wkhtmltopdf, an
          # engine this container cannot install at all.
          it 'answers a typed Failure when the engine runs and exits non-zero' do
            result = described_class.new(binary: '/bin/false').render(request)

            expect(result).to be_a(Failure)
            expect(Failure::CODES).to include(result.code)
            expect(result.detail).to match(/exit 1/)
            expect { result.bytes }.to raise_error(NoMethodError)
          end

          # A blocked asset is a DEGRADATION, not a failure — the same rule as the
          # reference engine, because making the two disagree about whether a missing
          # image destroys a report is the abstraction failing at the point it exists
          # for. Under egress denial this is the EXPECTED case: every http reference is
          # pointed at a proxy that does not exist, so wkhtmltopdf exits 1 with
          # `ConnectionRefusedError` and a perfectly good PDF beside it. Measured in CI
          # on fixture F-15.
          it 'keeps a document the engine produced despite exiting non-zero' do
            pdf = "%PDF-1.4\n#{'x' * 2000}\n%%EOF"
            adapter = described_class.new(binary: '/bin/sh')
            allow(adapter).to receive(:build_argv) do |_req, path|
              File.binwrite(path, pdf)
              # argv.last is the output path — that is `build_argv`'s contract and
              # `run` reads the document from it.
              ['/bin/sh', '-c',
               'echo "Exit with code 1 due to network error: ConnectionRefusedError" >&2; exit 1',
               path]
            end

            result = adapter.render(request)

            expect(result).to be_a(Success)
            expect(result.degradations.map(&:capability)).to include(:asset_unresolved)
          end

          # …and the guard is the OUTPUT, not the stderr text: no plausible PDF means the
          # engine genuinely failed, and the typed Failure stands.
          it 'still fails when a non-zero exit produced nothing usable' do
            adapter = described_class.new(binary: '/bin/sh')
            allow(adapter).to receive(:build_argv)
              .and_return(['/bin/sh', '-c', 'echo "boom" >&2; exit 1'])

            expect(adapter.render(request)).to be_a(Failure)
          end

          it 'does not carry an asset degradation into the next render' do
            pdf = "%PDF-1.4\n#{'x' * 2000}\n%%EOF"
            adapter = described_class.new(binary: '/bin/sh')
            call = 0
            allow(adapter).to receive(:build_argv) do |_req, path|
              call += 1
              File.binwrite(path, pdf)
              script = call == 1 ? 'exit 1' : 'exit 0'
              ['/bin/sh', '-c', script, path]
            end

            first = adapter.render(request)
            second = adapter.render(request)

            expect(first.degradations.map(&:capability)).to include(:asset_unresolved)
            expect(second.degradations.map(&:capability)).not_to include(:asset_unresolved)
          end

          it 'reads the reason out of stderr rather than guessing from the exit code' do
            # wkhtmltopdf exits 1 both for "an asset failed to load" and for a broken
            # install, so the code comes from what stderr said.
            missing_lib = described_class.new(binary: '/bin/sh')
            allow(missing_lib).to receive(:build_argv)
              .and_return(['/bin/sh', '-c', 'echo "cannot open shared object file" >&2; exit 1'])

            result = missing_lib.render(request)

            expect(result.code).to eq(:engine_unavailable)
          end
        end
      end
    end
  end
end
