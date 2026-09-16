# frozen_string_literal: true

# S-30 — the reader for a record whose subject is gone.
#
# `spec/golden/scope/scope.jsonl` and `spec/golden/sql/scope_sql.jsonl` froze what
# `Glue::Legacy::ScopeResolution` answered for 46 (template, query, actor) triples, and
# the SQL those scopes generated. That module was deleted on 2026-08-13, so the files
# **cannot be regenerated** — `spec/golden/README.md` says so, and CLAUDE.md §1 names
# them as the one thing in this repository that must survive whatever happens to its
# subject.
#
# --- WHY THIS FILE EXISTS AT ALL ---
#
# The test that used to drive `ScopeFixture` — `test/unit/golden_scope_fixture_test.rb`
# — went with the module, because it INCLUDED it. That left the reader with no caller and
# the two artefacts with nothing that opens them, which is how a record rots: not by being
# deleted, but by nobody noticing it stopped parsing until the day somebody needs it.
#
# Every other module under `spec/golden/` has a paired spec (`baseline_spec`,
# `corpus_cases_spec`, `corpus_canonicaliser_spec`, `kernel_exception_spec`,
# `reference_date_spec`, `performance_spec`). This one lost its pair to a deletion; this
# restores it, pointed at the ONLY thing still assertable about the files — that they are
# there, that they parse, and that they are not empty.
#
# **It asserts a FLOOR on the row count, deliberately.** HANDOVER §1: a glob that matches
# nothing must never be a pass, and this file's whole risk is a truncated or emptied
# artefact reading as a clean run. The numbers below are the committed sizes; if one
# changes, that is a finding to explain, not a number to update.

require_relative '../spec_helper'
require_relative 'scope_fixture'

RSpec.describe RrdGolden::ScopeFixture do
  # Measured from the committed files at the time the reader lost its test. They are
  # frozen artefacts, so these are exact rather than minima — but the assertions below
  # use `>=` for the floor AND `eq` for the exact value, because the two catch different
  # accidents: truncation, and a well-meaning regeneration that no longer can happen.
  # METHODS, NOT CONSTANTS. `X = 1` inside an `RSpec.describe` block defines `Object::X`
  # for the whole process — HANDOVER §1, and S-30's own harness tripped over it twice
  # (`FIXTURES`, then `SPEC_ACTOR`). `expected_scope_rows` is exactly the sort of generic
  # name a second spec file would pick.
  # Plain `def` — the endless form is Ruby 3.0 and this repo's floor is 2.7.
  # `.codex/check_ruby_floor.sh` caught the first draft of these two lines.
  def expected_scope_rows
    46
  end

  def expected_sql_rows
    46
  end

  describe 'the irreplaceable artefacts' do
    it 'still has the scope oracle on disk' do
      expect(File.exist?(described_class::SCOPES)).to be(true),
                                                     "#{described_class::SCOPES} is gone — " \
                                                     'it cannot be regenerated (S-30 deleted its subject)'
    end

    it 'still has the SQL oracle on disk' do
      expect(File.exist?(described_class::SQL)).to be(true)
    end
  end

  describe 'they still parse' do
    it 'reads every scope record as JSON' do
      rows = described_class.scopes

      expect(rows).to be_an(Enumerable)
      expect(rows.length).to be >= expected_scope_rows
      expect(rows.length).to eq(expected_scope_rows)
    end

    it 'reads every SQL record as JSON' do
      rows = described_class.sql

      expect(rows.length).to be >= expected_sql_rows
      expect(rows.length).to eq(expected_sql_rows)
    end
  end

  describe 'the records still carry what makes them a record' do
    # Not a behavioural assertion — there is no behaviour left to assert. This is the
    # shape a reader needs in order to learn anything from the file, so it is what a
    # truncation or a re-encode would break.
    it 'keys every scope record by its triple' do
      described_class.scopes.each do |key, _value|
        expect(key).to be_a(String), "expected a triple key, got #{key.inspect}"
        expect(key).not_to be_empty
      end
    end

    it 'never answers an empty set for a key it lists' do
      empty = described_class.scopes.select { |_k, v| v.nil? }

      expect(empty).to be_empty, "these triples resolved to nil: #{empty.keys}"
    end
  end
end
