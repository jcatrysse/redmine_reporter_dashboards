# frozen_string_literal: true

require 'json'
require_relative 'corpus_canonicaliser'

module RrdGolden
  # THE SCOPE FIXTURE — the genuinely irrecoverable artefact of T-01.
  #
  # `technical-spec.md` §2 Step 0 draws the line: the aggregation NUMBERS are
  # regenerable from the baseline commit, because the kernel's signature does not
  # change. What cannot be reconstructed once `scope_resolution.rb` is deleted is
  # THE SCOPE — "the AR relation 0.5.0's resolve_scope produced for template T, query
  # Q, actor U". T-07 replaces that file with `Liquid::ScopeBinding`, and the only way
  # to know the replacement resolves the same issues is to have written down what the
  # original resolved, first.
  #
  # Two files, for the reason the corpus and the SQL are split:
  #
  #   scope/scope.jsonl    the ORACLE: per triple, the sorted set of issues the
  #                        resolved scope returns, and nil where resolution returns
  #                        nil (which is a supported answer meaning "no drill-through",
  #                        never an error)
  #   sql/scope_sql.jsonl  the SQL the relation generates, tokenised. A SIBLING tree
  #                        because SQL is EXPECTED to change at the re-seam: a
  #                        differential that fails for the wrong reason gets switched
  #                        off, and this one would take the oracle with it
  #
  # --- Why issues are recorded by KEY and not by id ---
  #
  # The plan says "the sorted issue-id set". Recorded literally, that set is not
  # reproducible and not portable, for one reason each:
  #
  #   * the fixture creates its own issues inside a transaction that is rolled back,
  #     so the ids advance on every run — two runs of the same test would disagree;
  #   * Redmine's own fixture set differs between 5.1 and 7.0, so an id recorded on
  #     one branch is a different issue on another, and the CI matrix runs four.
  #
  # So each issue carries a unique `subject` (`sf-01` … ) which IS its identity here,
  # and the recorded set is the sorted list of those keys — the same *set of issues*,
  # spelled portably. The raw ids are still written, into the SQL tree, where
  # instability is expected and harmless. This is a deliberate deviation from the
  # plan's wording in service of the plan's purpose, and it is the reason the fixture
  # can be verified on every supported Redmine instead of one pinned branch.
  module ScopeFixture
    DIR       = File.expand_path('scope', __dir__)
    SQL_DIR   = File.expand_path('sql', __dir__)
    SCOPES    = File.join(DIR, 'scope.jsonl')
    SQL       = File.join(SQL_DIR, 'scope_sql.jsonl')
    WRITE_ENV = 'RRD_SCOPE_WRITE'

    class Missing < StandardError; end

    class << self
      def write?
        %w[1 true yes].include?(ENV.fetch(WRITE_ENV, '').to_s.strip.downcase)
      end

      def exist?
        File.exist?(SCOPES) && File.exist?(SQL)
      end

      def scopes
        read(SCOPES)
      end

      def sql
        read(SQL)
      end

      def save(records)
        require 'fileutils'
        FileUtils.mkdir_p(DIR)
        FileUtils.mkdir_p(SQL_DIR)

        File.binwrite(SCOPES, CorpusCanonicaliser.encode(records.map { |r| scope_record(r) }))
        File.binwrite(SQL, CorpusCanonicaliser.encode(records.map { |r| sql_record(r) }))
        records
      end

      # The oracle half: identity, and what it resolved to — the issue set by key AND
      # by id (the test assigns its own ids, so both are stable), the count, and which
      # IssueQuery came back for drill-through.
      def scope_record(record)
        record.slice('triple', 'template', 'query', 'actor', 'issues', 'issue_ids', 'count',
                     'query_resolved')
      end

      # The sibling half, carrying the Redmine series it was recorded on: Redmine's own
      # visibility SQL is spelled differently across the four supported branches, so a
      # byte comparison is only meaningful against the branch that produced it.
      def sql_record(record)
        record.slice('triple', 'sql', 'redmine')
      end

      private

      def read(path)
        raise Missing, missing_message unless exist?

        CorpusCanonicaliser.decode(File.read(path))
                           .each_with_object({}) { |record, out| out[record['triple']] = record }
      end

      def missing_message
        "the scope fixture is not committed (expected #{SCOPES} and #{SQL}). Generate it with " \
          "#{WRITE_ENV}=1 by running the full-application test suite, then commit both files."
      end
    end
  end
end
