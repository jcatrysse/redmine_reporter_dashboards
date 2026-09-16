# frozen_string_literal: true

require 'json'
require_relative 'adapter_overlay'
require_relative 'baseline'
require_relative 'corpus_canonicaliser'
require_relative 'reference_date'

module RrdGolden
  # Where the golden aggregation corpus lives on disk, and what has to be true of it
  # before a comparison against it means anything.
  #
  # Two files, and the split is deliberate:
  #
  #   values.jsonl   one canonical JSON record per case, in the case list's order.
  #                  THE ORACLE. A difference here is a difference in the numbers.
  #   manifest.json  provenance: the baseline commit, the pinned reference date, the
  #                  time zone, the engine it was generated on, the record count, the
  #                  digest of values.jsonl and the digest of the CASE LIST.
  #
  # The manifest is not decoration. Three ways a corpus silently stops being an
  # oracle, each closed by one field in it:
  #
  #   * someone edits values.jsonl by hand to make a failing case pass  -> `digest`
  #   * someone changes the case list and does not regenerate, so the file
  #     describes a different set of questions than the one being asked
  #                                                                     -> `cases`
  #   * the corpus was generated against a different date or zone, so every
  #     period window in it is answering a different question
  #                                    -> `reference_date` / `time_zone`
  #
  # SQL strings are deliberately NOT here. They live in spec/golden/sql/, because SQL
  # is expected to change at the re-seam and the numbers are not; a differential that
  # fails for the wrong reason gets switched off (technical-spec.md §2 Step 0).
  module Corpus
    DIR       = File.expand_path('aggregation', __dir__)
    VALUES    = File.join(DIR, 'values.jsonl')
    MANIFEST  = File.join(DIR, 'manifest.json')

    # Set to regenerate instead of verify. Named on the failure message of every
    # mismatch, so the reader is never left guessing how the file is produced.
    WRITE_ENV = 'RRD_CORPUS_WRITE'

    # And this one regenerates the PER-FAMILY OVERLAY instead. Two variables rather
    # than one that means different things on different engines: `RRD_CORPUS_WRITE` on
    # a MySQL server would otherwise rewrite the canonical corpus with that engine's
    # numbers, which is the one destructive mistake available here.
    OVERLAY_WRITE_ENV = 'RRD_CORPUS_OVERLAY_WRITE'

    class Missing < StandardError; end
    class Corrupt < StandardError; end
    class WrongEngine < StandardError; end

    class << self
      def write?
        flag?(WRITE_ENV)
      end

      def overlay_write?
        flag?(OVERLAY_WRITE_ENV)
      end

      def flag?(name)
        %w[1 true yes].include?(ENV.fetch(name, '').to_s.strip.downcase)
      end

      def exist?
        File.exist?(VALUES) && File.exist?(MANIFEST)
      end

      # Records as canonical Ruby structures — the same form the generator produces,
      # so a comparison is structure-to-structure and never string-to-structure.
      def records
        raise Missing, missing_message unless exist?

        CorpusCanonicaliser.decode(File.read(VALUES))
      end

      def manifest
        raise Missing, missing_message unless exist?

        JSON.parse(File.read(MANIFEST))
      end

      def by_case
        records.each_with_object({}) do |record, out|
          id = record['case']
          raise Corrupt, "a corpus record has no case id: #{record.inspect}" if id.nil?
          raise Corrupt, "duplicate corpus record for case #{id.inspect}" if out.key?(id)

          out[id] = record
        end
      end

      def save(records, cases_digest:, adapter:)
        family = AdapterOverlay.family_for(adapter)
        unless family == AdapterOverlay::CANONICAL_FAMILY
          raise WrongEngine,
                "refusing to write the canonical corpus from a #{family} server. The committed " \
                "corpus is generated on #{AdapterOverlay::CANONICAL_FAMILY} and the differences " \
                "on other engines belong in the overlay — set #{OVERLAY_WRITE_ENV}=1 instead."
        end

        Dir.mkdir(DIR) unless Dir.exist?(DIR)
        body = CorpusCanonicaliser.encode(records)
        File.binwrite(VALUES, body)
        File.binwrite(MANIFEST, "#{JSON.pretty_generate(
          build_manifest(records, body, cases_digest: cases_digest, adapter: adapter)
        )}\n")
        records
      end

      # Everything a reader needs to know whether this corpus answers their question.
      # `generated_on` is the engine that produced the numbers — informational, not a
      # claim that the others were checked. What proves the other two engines is the
      # `corpus` CI job running this verification on each of them.
      def build_manifest(records, body, cases_digest:, adapter:)
        {
          'baseline_commit' => Baseline::COMMIT,
          'reference_date'  => ReferenceDate.require!.iso8601,
          'time_zone'       => 'UTC',
          'generated_on'    => adapter.to_s,
          'record_count'    => records.length,
          'digest'          => Digest::SHA256.hexdigest(body),
          'cases'           => cases_digest
        }
      end

      def missing_message
        "the golden corpus is not committed (expected #{VALUES} and #{MANIFEST}). " \
          "Generate it with #{WRITE_ENV}=1 and RRD_REFERENCE_DATE set, against a " \
          'database, then commit both files.'
      end
    end
  end
end
