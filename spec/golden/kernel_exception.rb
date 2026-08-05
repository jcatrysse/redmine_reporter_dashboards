# frozen_string_literal: true

require_relative 'baseline'

module RrdGolden
  # Gate G7's declared exceptions: the argued, counted, byte-exact hunks the ported
  # aggregation kernel is allowed to carry against its v0.5.0 blob.
  #
  # G7 is byte-identity, and `baseline_spec.rb` could express exactly two states:
  # identical, or different. "Identical except one argued hunk" had no spelling at
  # all — so the moment the kernel legitimately had to change, the only ways to a
  # green gate were to delete the assertion or to move the reference. Both destroy
  # the oracle. This is the third way, and it is deliberately modelled on
  # `AdapterOverlay`: named entries, a written reason each, and a RATCHET that caps
  # how many may exist.
  #
  # --- What an entry is ---
  #
  # A pair of byte fragments: the exact lines as they stand in the baseline blob, and
  # the exact lines that replace them. The check is NOT a diff — it reconstructs the
  # expected file by applying every declared hunk to the baseline and asserts the
  # working file equals it, byte for byte. So an entry can only ever license the ONE
  # change it spells out; a second change anywhere in the file, including inside a
  # declared hunk, fails the gate as loudly as it did before.
  #
  # Reconstruction rather than `git diff --no-index` on purpose: a recorded diff is a
  # statement about git's output format and its choice of hunk boundaries, which is a
  # comparison this project does not control and cannot pin across git versions.
  # Reconstruction only depends on the bytes.
  #
  # --- What an entry is NOT ---
  #
  # It is not a licence to keep editing. There is no writer for these files, and that
  # is the point: `RRD_CORPUS_OVERLAY_WRITE=1` exists because an overlay records a
  # MEASUREMENT, while this records an ARGUMENT. Regenerating an argument on demand
  # is how a byte-identity gate becomes a formality. A new hunk is recorded by hand,
  # with its reason, and RATCHET goes up in the same commit that a reviewer reads.
  #
  # --- The only admissible reason ---
  #
  # The plan grants the exception to exactly one task and one defect. T-08's `Accept:`
  # line says it "owns the fix for defect D-1 … the only place the kernel may
  # legitimately change a byte". Anything else is a finding, not an entry.
  module KernelException
    DIR = File.expand_path('kernel_exception', __dir__)

    # The kernel file every entry below applies to. Named once so an entry cannot
    # quietly point at the other kernel file, which carries no exception at all.
    KERNEL = 'lib/redmine_reporter_dashboards/aggregation/query_aggregator.rb'

    # ------------------------------------------------------------------
    # THE ENTRIES
    # ------------------------------------------------------------------
    #
    # DEFECT D-1 (found 2026-08-05 by the golden corpus on MariaDB 10.11, confirmed by
    # the first CI run on MariaDB 11, measured ABSENT on MySQL 8.0.46 and PostgreSQL
    # 16). ActiveRecord reads a grouped result back BY THE GROUP EXPRESSION'S OWN TEXT,
    # and MariaDB truncates a returned column label at 256 characters — measured with
    # this shape, 261 works and 262 does not. The age dimension groups on a generated
    # CASE that passes 256 at FOUR boundaries, and DEFAULT_AGE_BUCKETS is four. Past
    # the limit every group key came back nil, the whole axis collapsed into the
    # "(none)" bucket, and the total was taken from whichever group the server
    # returned last — so an issue could vanish from the count as well.
    #
    # ONE hunk, in ONE method, and the smallness is the argument: `measure_groups`
    # stops asking ActiveRecord for a grouped `.count` and reads the same GROUP BY
    # positionally instead. Nothing about the dimensions, the axis or the SQL changes —
    # only how the result rows are taken off the wire.
    #
    # Shortening the expression was the plan's original prescription and does not
    # survive measurement: the alias is ALREADY truncated on PostgreSQL (limit 63) and
    # PostgreSQL answers correctly, because ActiveRecord asks for the same truncated
    # name it sent. The defect is the two ends DISAGREEING, so a shorter CASE only
    # moves the cliff — and MAX_AGE_BUCKETS is 24, which cannot fit in 256 characters
    # at ~60 characters a branch. Introducing a select alias is not available either:
    # `execute_grouped_calculation` overwrites the relation's select list unless there
    # is a HAVING clause, so `.select("… AS x").group("x")` raises.
    #
    # Counting each bucket with its own conditional aggregate and dropping the GROUP BY
    # was written, pushed, and MEASURED WORSE: that shape costs ~25-50s per call on
    # MariaDB at 10 000 issues (the `completeness.seven` cells in the same CI job say
    # so) against ~0.02s for the grouped read. It removed the alias and re-broke the
    # engine it was fixing. Reading the same GROUP BY positionally removes the alias
    # and keeps the plan.
    ENTRIES = [
      { id: 'grouped-counts', file: KERNEL,
        reason: 'DEFECT D-1: a counted axis is read through `grouped_counts` — SELECT ' \
                '<group expression>, COUNT(DISTINCT issues.id) ... GROUP BY <same>, taken ' \
                'back BY POSITION — instead of ActiveRecord\'s grouped `.count`, which ' \
                'looks each key up by a column alias derived from the expression\'s text ' \
                'and that MariaDB truncates at 256 characters. Same statement, same ' \
                'query count; only the read changes. Measures (sum/avg/distinct) still ' \
                'go through `.count`/`.sum`/`.average` and are still exposed — README, ' \
                'database section.' }
    ].freeze

    # The ratchet. Like AdapterOverlay's, it is the COMMITTED SIZE of ENTRIES and not a
    # budget: the spec fails when ENTRIES is longer AND when RATCHET is larger, so
    # neither a smuggled hunk nor a ratchet left high after one is removed can pass.
    RATCHET = 1

    class << self
      def entries_for(current_path)
        ENTRIES.select { |entry| entry[:file] == current_path }
      end

      def baseline_fragment(id)
        read_fragment(id, 'baseline')
      end

      def current_fragment(id)
        read_fragment(id, 'current')
      end

      def path_for(id, side)
        File.join(DIR, "#{id}.#{side}.rbfrag")
      end

      # The bytes the working file MUST equal: the v0.5.0 blob with every declared hunk
      # applied, in order. With no entries this is the blob itself, which is the plain
      # byte-identity check G7 has always been.
      #
      # Raises rather than falling back. A hunk that no longer matches the baseline, or
      # that matches it in more than one place, means the recorded exception has stopped
      # describing the file it was written against — and an exception that cannot be
      # located must never degrade into "no exception applies", which would report a
      # licensed change as a gate failure and an unlicensed one as fine.
      def expected_for(current_path)
        baseline_path = Baseline::KERNEL_FILES.fetch(current_path)
        expected      = Baseline.file_at_baseline(baseline_path)
        raise "#{baseline_path} is unreadable at the baseline commit" if expected.nil?

        entries_for(current_path).each do |entry|
          from  = baseline_fragment(entry[:id])
          count = expected.scan(from).length
          unless count == 1
            raise "declared hunk #{entry[:id]} matches #{count} places in #{baseline_path}; " \
                  'it no longer describes the baseline it was recorded against'
          end

          expected = expected.sub(from, current_fragment(entry[:id]))
        end
        expected
      end

      private

      # Binary, like everything else that compares against git output: File.read
      # applies an encoding, and one em-dash then reads as a three-byte difference
      # that is not a difference.
      def read_fragment(id, side)
        path = path_for(id, side)
        raise "#{path} is missing — a declared hunk with no recorded bytes" unless File.exist?(path)

        File.binread(path)
      end
    end
  end
end
