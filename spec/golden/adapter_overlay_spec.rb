# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'adapter_overlay'
require_relative 'corpus_cases'

# The ratchet, mechanically. `technical-spec.md` §2 Step 0: "an empty overlay passes,
# a GROWING overlay is a ratchet failure". A number in a comment is not a ratchet —
# this file is.
#
# It needs no database, so it runs in the DB-less job on every supported Redmine: the
# constraint on the overlay must be checked even on a machine that cannot run the
# corpus at all.
RSpec.describe RrdGolden::AdapterOverlay do
  describe 'the ratchet' do
    it 'is not exceeded by the entries' do
      expect(described_class::ENTRIES.length).to be <= described_class::RATCHET,
                                                 'the overlay has grown past its ratchet. Each ' \
                                                 'entry is a documented hole in gate G7 — argue ' \
                                                 'for it in the pull request and raise RATCHET ' \
                                                 'deliberately, or fix the divergence.'
    end

    # The other direction, and the one that rots: an entry is deleted because the
    # divergence went away, and the ratchet is left where it was, silently granting
    # room for the next one.
    it 'is not larger than the entries, so a deleted entry lowers it too' do
      expect(described_class::RATCHET).to eq(described_class::ENTRIES.length)
    end
  end

  describe 'every entry' do
    it 'names a case that exists in the corpus matrix' do
      described_class::ENTRIES.each do |entry|
        expect(RrdGolden::CorpusCases.ids).to include(entry[:case].to_s)
      end
    end

    it 'names a family the corpus is verified against' do
      described_class::ENTRIES.each do |entry|
        expect(described_class::FAMILIES).to include(entry[:family].to_s)
      end
    end

    # Not decoration: an entry without a reason is a tolerance with extra steps.
    it 'carries a written reason long enough to be one' do
      described_class::ENTRIES.each do |entry|
        expect(entry[:reason].to_s.strip.length).to be > 40, "#{entry[:case]} has no real reason"
      end
    end

    it 'is unique per case and family' do
      keys = described_class::ENTRIES.map { |entry| [entry[:case], entry[:family]] }

      expect(keys.tally.select { |_, n| n > 1 }).to eq({})
    end

    # An overlay entry replaces one expected value. A wildcard would replace an
    # unknown number of them, which is the thing this mechanism exists instead of.
    it 'is a literal case id, never a pattern' do
      described_class::ENTRIES.each do |entry|
        expect(entry[:case].to_s).not_to match(/[*?\[\]]/)
      end
    end
  end

  describe 'the canonical family' do
    it 'is one of the families' do
      expect(described_class::FAMILIES).to include(described_class::CANONICAL_FAMILY)
    end

    # The corpus is generated on the canonical engine, so an overlay entry for it
    # would be an exception to its own source of truth.
    it 'has no entries of its own' do
      expect(described_class.entries_for(described_class::CANONICAL_FAMILY)).to be_empty
    end
  end

  describe '.family_for' do
    it 'maps PostgreSQL' do
      expect(described_class.family_for('PostgreSQL')).to eq('postgresql')
    end

    it 'maps MySQL and MariaDB to one family, because the kernel branches once' do
      expect(described_class.family_for('Mysql2')).to eq('mysql')
      expect(described_class.family_for('Trilogy')).to eq('mysql')
    end

    # Fails closed. Treating an unknown engine as "no overlay applies" would report a
    # divergence on an unverified engine as a corpus failure, which reads like drift.
    it 'refuses an engine the kernel has no branch for' do
      expect { described_class.family_for('SQLite') }
        .to raise_error(ArgumentError, /neither the PostgreSQL nor the MySQL family/)
    end
  end

  describe 'the recorded values' do
    it 'has a file for every family that declares entries, holding exactly those cases' do
      described_class::FAMILIES.each do |family|
        declared = described_class.case_ids_for(family)
        next if declared.empty?

        expect(described_class.exist?(family)).to be(true),
                                                 "#{described_class.path_for(family)} is missing"
        expect(described_class.records_for(family).keys.sort).to eq(declared.sort)
      end
    end

    it 'has no file for a family that declares nothing' do
      described_class::FAMILIES.each do |family|
        next unless described_class.case_ids_for(family).empty?

        expect(described_class.exist?(family)).to be(false),
                                                 "#{described_class.path_for(family)} exists but " \
                                                 'no entry names that family — a recorded ' \
                                                 'exception nobody declared is not an exception, ' \
                                                 'it is a second corpus'
      end
    end
  end
end
