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
    # The families the corpus is verified against.
    #
    # MariaDB is its OWN family, not a flavour of mysql, and that was learned the hard
    # way: the first real CI run measured defect D-1 on both MariaDB 10.11 and 11 and
    # NOT on MySQL 8.0.46, which answers correctly. Folding the two together — as this
    # file did until that run — declares an exception on an engine that does not need
    # one, and the exhaustiveness assertion then fails on MySQL for the opposite
    # reason to the one it was written for.
    #
    # They still share every branch INSIDE the kernel (DATE_FORMAT, DECIMAL(20,4)),
    # and the mysql2 adapter reports "Mysql2" for both — which is why the family
    # cannot be derived from the adapter name alone. See .family_for.
    FAMILIES = %w[postgresql mysql mariadb].freeze

    # The family the committed corpus itself is generated on. One family has to be
    # canonical or the overlay has no direction; PostgreSQL is this project's default
    # engine and the one the local scripts set up.
    CANONICAL_FAMILY = 'postgresql'

    DIR = File.expand_path('aggregation/overlay', __dir__)

    # ------------------------------------------------------------------
    # THE ENTRIES
    # ------------------------------------------------------------------
    #
    # EMPTY, and that is the state it is supposed to be in: "an empty overlay passes".
    #
    # It held two entries between 2026-08-05 and this commit, both `cap/age.*` on
    # MariaDB, both for DEFECT D-1 — the `age` dimension grouped on a generated CASE,
    # ActiveRecord read the group key back out of the row BY THE EXPRESSION'S OWN TEXT,
    # and MariaDB truncates a returned column label at 256 characters (measured: 261
    # works, 262 does not), so past four boundaries every key came back nil and the
    # whole result collapsed into "(none)". MySQL 8.0.46 and PostgreSQL 16 were
    # measured unaffected, which is why the entries were MariaDB's alone and why this
    # file has a `mariadb` family separate from `mysql` in the first place.
    #
    # D-1 is fixed: the counted age axis no longer groups at all. So both entries are
    # gone, RATCHET is back to 0, and `aggregation/overlay/mariadb.jsonl` is deleted —
    # the spec beside this file fails if a recorded file outlives the entry that
    # declared it, because a recorded exception nobody declares is a second corpus.
    #
    # This is reason 2 in the list above working as intended: a named pre-existing
    # defect is a TEMPORARY entry, and the commit that fixes it deletes the entry and
    # lowers the ratchet. Kept as history rather than deleted outright because the
    # separate `mariadb` family only makes sense next to the measurement that forced
    # it, and the next long grouped expression will meet the same 256-character limit.
    ENTRIES = [].freeze

    # The ratchet. It is the COMMITTED SIZE of ENTRIES, not a budget: the spec beside
    # this file fails when ENTRIES is longer AND when RATCHET is larger than ENTRIES,
    # so a lowered ratchet can never be silently left behind either.
    RATCHET = 0

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
          count = case_ids_for(family).length
          raise "#{path_for(family)} is missing, but the overlay declares #{count} " \
                "#{count == 1 ? 'entry' : 'entries'} for #{family}. Regenerate it with " \
                'RRD_CORPUS_OVERLAY_WRITE=1 against that engine.'
        end

        CorpusCanonicaliser.decode(File.read(path_for(family)))
                           .each_with_object({}) { |record, out| out[record['case']] = record }
      end

      # nil means "no overlay for this case on this engine", which is the answer for
      # every case on PostgreSQL and MySQL, and for all but D-1's two on MariaDB.
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

      # PostgreSQL / MySQL / MariaDB -> the family the overlay is keyed by.
      #
      # `mariadb:` is a separate argument on purpose: the mysql2 adapter reports
      # "Mysql2" for MariaDB as well, so the name alone CANNOT tell them apart, and
      # the two now behave differently (D-1). The caller answers the question from the
      # server version — RrdAdapterHarness#mariadb? — and this method stays a pure
      # mapping that the DB-less spec can exercise in both directions.
      #
      # Raises rather than guessing: an unrecognised engine must not be treated as "no
      # overlay applies", which would report a divergence as a corpus failure on an
      # engine nobody has verified at all.
      def family_for(adapter_name, mariadb: false)
        name = adapter_name.to_s
        return 'postgresql' if name.match?(/postgres/i)
        return mariadb ? 'mariadb' : 'mysql' if name.match?(/mysql|maria|trilogy/i)

        raise ArgumentError,
              "#{adapter_name.inspect} is neither the PostgreSQL nor the MySQL family. The " \
              'corpus is only meaningful on an engine the aggregator has a branch for.'
      end
    end
  end
end
