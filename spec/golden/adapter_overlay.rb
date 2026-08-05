# frozen_string_literal: true

require 'json'
require_relative 'corpus_canonicaliser'

module RrdGolden
  # The per-adapter overlay: the named, counted exceptions to "one corpus, three
  # engines".
  #
  # `technical-spec.md` §2 Step 0 is explicit about the mechanism and about why it is
  # not a tolerance:
  #
  #   Cases that cannot agree at 4 dp go in a per-adapter overlay WITH A WRITTEN
  #   REASON; an empty overlay passes, a GROWING overlay is a ratchet failure. No
  #   floating tolerance — a tolerance hides drift, an overlay names it.
  #
  # A tolerance is a standing licence: once `delta < 0.0001` is in the comparison,
  # every later divergence inside it is invisible, defects included. An overlay entry
  # is the opposite — one case, one engine family, a reason a reviewer can check, and
  # RATCHET capping how many may exist.
  #
  # --- The two admissible reasons ---
  #
  # 1. A GENUINE ENGINE PROPERTY at the fourth decimal place. The declared contract is
  #    4 dp, and PostgreSQL `numeric` and MySQL `DECIMAL(20,4)` do not agree past it.
  #    Such an entry is permanent.
  # 2. A NAMED PRE-EXISTING DEFECT that this task may not fix. Gate G7 freezes the
  #    aggregation kernel byte for byte, so a defect the corpus discovers cannot be
  #    corrected in the same breath as being frozen. Such an entry MUST name the
  #    defect, and it is TEMPORARY: the commit that fixes the defect deletes the entry
  #    and lowers RATCHET, and until then the entry is the reason the corpus can be
  #    green on an engine that is answering wrongly.
  #
  # Row ORDER is never a reason — see the two `normalise` notes in CorpusCases.
  #
  # --- What an entry does NOT do ---
  #
  # It never relaxes a comparison and it cannot be a wildcard: no adapter globbing, no
  # case prefixes, no "approximately". The expected values live in
  # aggregation/overlay/<family>.jsonl, written by the SAME generator that writes the
  # corpus, so an overlay record is a measurement and not a hand-typed hope. The
  # verifier additionally asserts that the cases which differ on an engine are
  # EXACTLY the cases listed here — an overlay cannot cover for a divergence nobody
  # declared.
  module AdapterOverlay
    # The families the corpus is verified against. `mysql` covers MariaDB: the mysql2
    # adapter reports "Mysql2" for both, and both take the DATE_FORMAT /
    # DECIMAL(20,4) branch of every divergence in the kernel. An entry true of one and
    # not the other must say so in its reason.
    FAMILIES = %w[postgresql mysql].freeze

    # The family the committed corpus itself is generated on. One family has to be
    # canonical or the overlay has no direction; PostgreSQL is this project's default
    # engine and the one the local scripts set up.
    CANONICAL_FAMILY = 'postgresql'

    DIR = File.expand_path('aggregation/overlay', __dir__)

    # ------------------------------------------------------------------
    # THE ENTRIES
    # ------------------------------------------------------------------
    #
    # DEFECT D-1 (found 2026-08-05 by this corpus, on MariaDB 10.11, reproducible on
    # any MySQL-family server; PostgreSQL 16 is unaffected):
    #
    #   The `age` dimension groups on a generated CASE expression. ActiveRecord reads
    #   the group key back out of the result row by the expression's own text, and the
    #   MySQL family truncates a returned column label at 256 characters. Measured
    #   with this expression shape: 261 characters still works, 262 does not. Past the
    #   limit the lookup misses, EVERY group key comes back nil, and the whole result
    #   collapses into the "(none)" bucket — with a total taken from whichever group
    #   the server happened to return last.
    #
    #   FOUR age boundaries are enough to cross it, and DEFAULT_AGE_BUCKETS is
    #   [30, 60, 90, 180] — four. So on MySQL and MariaDB the DEFAULT age dimension
    #   reports every issue as having no age, today, in production. The existing
    #   adapter execution specs missed it because each of them happens to use three
    #   boundaries or fewer.
    #
    #   Not fixed here, and not because it is small: T-01 freezes the kernel and gate
    #   G7 diffs it byte for byte against the baseline commit, so the fix belongs to
    #   the task that may touch it (T-08 re-seams the dimension layer; see the plan's
    #   §Findings note). These two entries are what keeps that fact visible instead of
    #   letting a green MySQL run imply the numbers agree.
    ENTRIES = [
      { case: 'cap/age.at', family: 'mysql',
        reason: 'DEFECT D-1: a 24-boundary age CASE is 1 506 characters, past the ' \
                "MySQL family's 256-character column-label limit, so every row lands " \
                'in (none). Delete this entry when D-1 is fixed.' },
      { case: 'cap/age.past', family: 'mysql',
        reason: 'DEFECT D-1, same CASE: the 25th boundary is dropped by MAX_AGE_BUCKETS, ' \
                'so this case generates the identical statement and fails identically.' }
    ].freeze

    # The ratchet. It is the COMMITTED SIZE of ENTRIES, not a budget: the spec beside
    # this file fails when ENTRIES is longer AND when RATCHET is larger than ENTRIES,
    # so a lowered ratchet can never be silently left behind either.
    RATCHET = 2

    class << self
      def entries_for(family)
        ENTRIES.select { |entry| entry[:family].to_s == family.to_s }
      end

      def case_ids_for(family)
        entries_for(family).map { |entry| entry[:case].to_s }
      end

      def path_for(family)
        File.join(DIR, "#{family}.jsonl")
      end

      def exist?(family)
        File.exist?(path_for(family))
      end

      # The recorded results for one family, keyed by case id. Empty when the family
      # has no entries — which is the state the corpus should be in.
      def records_for(family)
        return {} if case_ids_for(family).empty?

        unless exist?(family)
          raise "#{path_for(family)} is missing, but the overlay declares " \
                "#{case_ids_for(family).length} entr(y|ies) for #{family}. Regenerate it with " \
                'RRD_CORPUS_OVERLAY_WRITE=1 against that engine.'
        end

        CorpusCanonicaliser.decode(File.read(path_for(family)))
                           .each_with_object({}) { |record, out| out[record['case']] = record }
      end

      # nil means "no overlay for this case on this engine", which is the answer for
      # every case on PostgreSQL and for all but D-1's two on MySQL.
      def expected_for(case_id, family)
        return nil unless case_ids_for(family).include?(case_id.to_s)

        record = records_for(family)[case_id.to_s]
        raise "#{path_for(family)} has no record for #{case_id}" if record.nil?

        record['result']
      end

      def save(family, records)
        listed = case_ids_for(family)
        wanted = records.select { |record| listed.include?(record['case']) }
        missing = listed - wanted.map { |record| record['case'] }
        raise "no result generated for overlay case(s) #{missing.inspect}" unless missing.empty?

        require 'fileutils'
        FileUtils.mkdir_p(DIR)
        File.binwrite(path_for(family), CorpusCanonicaliser.encode(wanted))
        wanted
      end

      # PostgreSQL / MySQL / MariaDB -> the family the overlay is keyed by. Raises
      # rather than guessing: an unrecognised engine must not be treated as "no
      # overlay applies", which would report a divergence as a corpus failure on an
      # engine nobody has verified at all.
      def family_for(adapter_name)
        name = adapter_name.to_s
        return 'postgresql' if name.match?(/postgres/i)
        return 'mysql'      if name.match?(/mysql|maria|trilogy/i)

        raise ArgumentError,
              "#{adapter_name.inspect} is neither the PostgreSQL nor the MySQL family. The " \
              'corpus is only meaningful on an engine the aggregator has a branch for.'
      end
    end
  end
end
