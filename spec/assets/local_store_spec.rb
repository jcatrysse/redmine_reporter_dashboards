# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/assets'
require_relative '../../lib/redmine_reporter_dashboards/charts'

# T-33 — `LocalStore`, the `:bundled` row of §5.1's table.
#
# Containment is the whole subject, and it is tested from four directions because a string
# check on `..` defeats only the first of them: a literal `..`, a PERCENT-ENCODED one, a
# double-encoded one, and a SYMLINK inside the root pointing outside it — which contains no
# `..` at all and is the one every hand-rolled check misses.
module RedmineReporterDashboards
  module Assets
    RSpec.describe LocalStore do
      # A real tree on disk. A stubbed `File.realpath` would test the code's opinion of
      # containment rather than the filesystem's, and the filesystem is the thing that
      # resolves symlinks.
      around do |example|
        Dir.mktmpdir('rrd-assets') do |dir|
          @tmp = dir
          FileUtils.mkdir_p(File.join(dir, 'root', 'sub'))
          FileUtils.mkdir_p(File.join(dir, 'outside'))
          File.binwrite(File.join(dir, 'root', 'logo.png'), "\x89PNG\r\n\x1a\nfake")
          File.binwrite(File.join(dir, 'root', 'app.css'), 'body { color: red }')
          File.binwrite(File.join(dir, 'root', 'app.js'), 'var x = 1;')
          File.binwrite(File.join(dir, 'root', 'notes.txt'), 'not a web asset')
          File.binwrite(File.join(dir, 'outside', 'secret.png'), 'secret bytes')
          example.run
        end
      end

      let(:root) { File.join(@tmp, 'root') }
      let(:store) { described_class.new(roots: { '/plugin_assets/rrd' => root }) }

      def file_for(path, **options)
        store.file_for(path, **options)
      end

      describe 'the ordinary answer' do
        it 'reads the bytes and types them from the extension' do
          found = file_for('/plugin_assets/rrd/logo.png')

          expect(found.content_type).to eq('image/png')
          expect(found.bytes).to include('PNG')
          expect(found.size).to eq(found.bytes.bytesize)
        end

        it 'reads a file in a sub-directory' do
          File.binwrite(File.join(root, 'sub', 'a.css'), 'a{}')

          expect(file_for('/plugin_assets/rrd/sub/a.css').content_type).to eq('text/css')
        end

        it 'percent-decodes exactly once' do
          File.binwrite(File.join(root, 'a b.png'), 'x')

          expect(file_for('/plugin_assets/rrd/a%20b.png')).not_to be_nil
        end
      end

      # ------------------------------------------------------------------
      describe 'containment' do
        it 'refuses a literal ..' do
          expect(file_for('/plugin_assets/rrd/../outside/secret.png')).to be_nil
          expect(store.reason).to eq(:not_under_root)
        end

        it 'refuses a PERCENT-ENCODED ..' do
          expect(file_for('/plugin_assets/rrd/%2e%2e/outside/secret.png')).to be_nil
          expect(store.reason).to eq(:not_under_root)
        end

        it 'refuses a DOUBLE-encoded .. rather than decoding twice' do
          # `%252e` decodes to `%2e`, and a second pass would turn that into `.`. One
          # decode, then no more: what is left is a filename containing a percent sign,
          # which is not there.
          expect(file_for('/plugin_assets/rrd/%252e%252e/outside/secret.png')).to be_nil
        end

        # DECODE-ONCE ASSERTED WHERE IT IS OBSERVABLE. The example above proves only that the
        # traversal fails, which it also would under two passes; and `a%20b.png` is a fixed point
        # after one pass, so it proves only "at least once". A file whose NAME contains a percent
        # escape is the discriminator: one pass resolves it, two do not.
        it 'decodes EXACTLY once, proven by a filename that is itself an escape' do
          File.binwrite(File.join(root, '%2e%2e.png'), 'literally named %2e%2e')

          # One pass turns `%252e%252e.png` into `%2e%2e.png`, which is the file.
          expect(file_for('/plugin_assets/rrd/%252e%252e.png').bytes).to eq('literally named %2e%2e')
          # And `%2e%2e.png` decodes to `...png` after one pass, which is not.
          expect(file_for('/plugin_assets/rrd/%2e%2e.png')).to be_nil
        end

        it 'refuses a SYMLINK inside the root that points outside it' do
          # No `..` anywhere in this path. This is the case a string check cannot see, and
          # the reason containment is `File.realpath` and not `start_with?`.
          FileUtils.ln_s(File.join(@tmp, 'outside', 'secret.png'),
                         File.join(root, 'innocent.png'))

          expect(file_for('/plugin_assets/rrd/innocent.png')).to be_nil
          expect(store.reason).to eq(:not_under_root)
        end

        it 'allows a symlink that stays INSIDE the root' do
          FileUtils.ln_s(File.join(root, 'logo.png'), File.join(root, 'alias.png'))

          expect(file_for('/plugin_assets/rrd/alias.png')).not_to be_nil
        end

        it 'refuses a NUL byte' do
          expect(file_for("/plugin_assets/rrd/logo.png\0.txt")).to be_nil
          expect(file_for('/plugin_assets/rrd/logo.png%00.txt')).to be_nil
        end

        it 'refuses a path under no configured root' do
          expect(file_for('/attachments/download/1/a.png')).to be_nil
          expect(store.reason).to eq(:no_root)
        end

        it 'refuses a directory' do
          expect(file_for('/plugin_assets/rrd/sub')).to be_nil
          expect(store.reason).to eq(:not_a_file)
        end

        it 'refuses an absent file, and says ABSENT rather than "outside the root"' do
          # These were one refusal in the first draft, and "resolves outside the asset root"
          # for a missing stylesheet sends an operator looking for a traversal that is not
          # there — the most misleading thing a diagnostic can do.
          expect(file_for('/plugin_assets/rrd/missing.png')).to be_nil
          expect(store.reason).to eq(:not_found)
          expect(store.reason_text).to include('does not exist')
        end

        it 'prefers the LONGEST matching root prefix' do
          nested = File.join(@tmp, 'root', 'sub')
          File.binwrite(File.join(nested, 'x.png'), 'nested')
          two = described_class.new(roots: { '/p' => root, '/p/sub' => nested })

          # Both prefixes match `/p/sub/x.png`; the longer one must win, or the file is
          # looked for at `root/sub/sub/x.png`.
          expect(two.file_for('/p/sub/x.png').bytes).to eq('nested')
        end
      end

      # ------------------------------------------------------------------
      describe 'types' do
        it 'refuses an extension it will not type' do
          expect(file_for('/plugin_assets/rrd/notes.txt')).to be_nil
          expect(store.reason).to eq(:unknown_type)
        end

        it 'refuses a file whose type does not match the way the document uses it' do
          # `<img src="app.css">` — the file is fine, the DOCUMENT is wrong, and the
          # refusal says which.
          expect(file_for('/plugin_assets/rrd/app.css', usage: :image)).to be_nil
          expect(store.reason).to eq(:wrong_type_for_usage)
          expect(store.reason_text).to include('is on disk')
        end

        it 'accepts each usage against its own type' do
          expect(file_for('/plugin_assets/rrd/app.css', usage: :stylesheet)).not_to be_nil
          expect(file_for('/plugin_assets/rrd/app.js', usage: :script)).not_to be_nil
          expect(file_for('/plugin_assets/rrd/logo.png', usage: :image)).not_to be_nil
        end

        it 'refuses every type for :other, because a report contains no embedded objects' do
          expect(file_for('/plugin_assets/rrd/logo.png', usage: :other)).to be_nil
        end
      end

      # ------------------------------------------------------------------
      describe 'mappers — the port for everything Redmine owns' do
        it 'accepts an absolute path a mapper answered with, outside every root' do
          # An attachment's `diskfile` is deliberately not under an asset root. The mapper
          # is the caller's code and is where the visibility decision was made (INV-1);
          # this class only reads what somebody upstream already allowed.
          target = File.join(@tmp, 'outside', 'secret.png')
          mapped = described_class.new(
            roots: { '/plugin_assets/rrd' => root },
            mappers: [->(path) { path == '/attachments/download/7/a.png' ? target : nil }]
          )

          expect(mapped.file_for('/attachments/download/7/a.png').bytes).to eq('secret bytes')
        end

        it 'falls through to the roots when no mapper answers' do
          mapped = described_class.new(roots: { '/plugin_assets/rrd' => root },
                                      mappers: [->(_path) { nil }])

          expect(mapped.file_for('/plugin_assets/rrd/logo.png')).not_to be_nil
        end

        it 'still refuses a RELATIVE path from a mapper' do
          mapped = described_class.new(roots: {}, mappers: [->(_path) { 'relative/x.png' }])

          expect(mapped.file_for('/anything')).to be_nil
        end

        it 'gets the DECODED path, so a mapper never has to decode' do
          seen = []
          mapped = described_class.new(roots: {}, mappers: [->(path) { seen << path; nil }])
          mapped.file_for('/attachments/download/7/a%20b.png')

          expect(seen).to eq(['/attachments/download/7/a b.png'])
        end
      end

      # ------------------------------------------------------------------
      # `File.binread` on a 4 GB file allocates 4 GB before anybody can compare it with a cap.
      # The result is `NoMemoryError`, which the render layer deliberately does not rescue, so it
      # takes the process rather than producing a named refusal. The fetcher already applies its
      # cap while reading; this is the same rule for the local half.
      describe 'the size cap, AT the limit and one past it' do
        it 'reads a file AT max_bytes and refuses one byte past it' do
          File.binwrite(File.join(root, 'ten.png'), 'a' * 10)

          expect(file_for('/plugin_assets/rrd/ten.png', max_bytes: 10).size).to eq(10)
          expect(file_for('/plugin_assets/rrd/ten.png', max_bytes: 9)).to be_nil
          expect(store.reason).to eq(:too_large)
        end

        it 'checks the size BEFORE reading, not after' do
          File.binwrite(File.join(root, 'big.png'), 'a' * 100)
          allow(File).to receive(:binread).and_call_original

          expect(file_for('/plugin_assets/rrd/big.png', max_bytes: 10)).to be_nil
          expect(File).not_to have_received(:binread)
        end

        it 'reads without a cap when none is given, because the resolver is not the only caller' do
          File.binwrite(File.join(root, 'uncapped.png'), 'a' * 100)

          expect(file_for('/plugin_assets/rrd/uncapped.png').size).to eq(100)
        end
      end

      describe 'unreadable files' do
        # STUBBED, NOT `chmod 0000`. This container runs as root, where a mode of 000
        # denies nothing, so the filesystem version of this test would pass without
        # exercising the rescue at all — and a `skip` would put a hole in the run for a
        # case that has nothing to do with the environment. Stubbing the read drives the
        # rescue directly and does so on every host.
        it 'answers nil rather than raising when the read itself fails' do
          allow(File).to receive(:binread).and_raise(Errno::EACCES)

          expect(file_for('/plugin_assets/rrd/logo.png')).to be_nil
          expect(store.reason).to eq(:not_a_file)
        end

        it 'lets an UNEXPECTED error class out, because that is a defect and not an absence' do
          # CLAUDE.md §5: rescue the specific class. A `rescue StandardError` here would
          # report a bug in this file as "the file is not there".
          allow(File).to receive(:binread).and_raise(NoMethodError, 'planted')

          expect { file_for('/plugin_assets/rrd/logo.png') }.to raise_error(NoMethodError, /planted/)
        end
      end

      describe BundledAssets do
        it 'points at the plugin\'s own assets/ directory, not the mirrored copy' do
          expect(BundledAssets::ROOT).to eq(File.join(BundledAssets::PLUGIN_ROOT, 'assets'))
          expect(BundledAssets).to be_available
          expect(BundledAssets.roots.keys).to eq([BundledAssets::URL_PREFIX])
        end

        it 'reads the vendored Chart.js the chart layer ships' do
          store = LocalStore.new(roots: BundledAssets.roots)
          path = "#{BundledAssets::URL_PREFIX}/javascripts/#{Charts::CHARTJS_ASSET}"
          found = store.file_for(path, usage: :script)

          expect(found).not_to be_nil
          expect(found.content_type).to eq('text/javascript')
          # The same file `vendor_integrity.sh` recomputes the digest of — so a mirror
          # going stale cannot make these two disagree.
          expect(Digest::SHA256.hexdigest(found.bytes)).to eq(Charts::CHARTJS_SHA256)
        end
      end
    end
  end
end
