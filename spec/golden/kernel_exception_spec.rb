# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'kernel_exception'
require_relative 'code_only'
require_relative 'baseline'

# The ratchet on gate G7's declared exceptions, mechanically — the same shape as
# adapter_overlay_spec.rb, for the same reason: a number in a comment is not a
# ratchet, this file is.
#
# The entry-level examples need no database and no git history, so they run in the
# DB-less job on every supported Redmine. The constraint on how much the frozen
# kernel may carry has to be checked even on a machine that can run neither the
# corpus nor `git show`.
RSpec.describe RrdGolden::KernelException do
  describe 'the ratchet' do
    it 'is not exceeded by the entries' do
      expect(described_class::ENTRIES.length).to be <= described_class::RATCHET,
                                                 'the kernel carries more declared hunks than its ' \
                                                 'ratchet allows. Each one is an argued hole in gate ' \
                                                 "G7's byte-identity — argue for it in the pull " \
                                                 'request and raise RATCHET deliberately.'
    end

    # The direction that rots: a hunk is dropped because the kernel went back to the
    # blob, and the ratchet is left where it was, silently granting room for the next.
    it 'is not larger than the entries, so a deleted hunk lowers it too' do
      expect(described_class::RATCHET).to eq(described_class::ENTRIES.length)
    end
  end

  describe 'every entry' do
    it 'names a file gate G7 actually freezes' do
      described_class::ENTRIES.each do |entry|
        expect(RrdGolden::Baseline::KERNEL_FILES).to have_key(entry[:file])
      end
    end

    # Not decoration. An exception without a reason is "the gate was in the way".
    it 'carries a written reason long enough to be one' do
      described_class::ENTRIES.each do |entry|
        expect(entry[:reason].to_s.strip.length).to be > 40, "#{entry[:id]} has no real reason"
      end
    end

    it 'names the defect it is granted for, so an unrelated hunk cannot borrow the mechanism' do
      described_class::ENTRIES.each do |entry|
        expect(entry[:reason]).to match(/D-1/), "#{entry[:id]} does not say which finding it is for"
      end
    end

    it 'has a unique id' do
      ids = described_class::ENTRIES.map { |entry| entry[:id] }

      expect(ids.tally.select { |_, n| n > 1 }).to eq({})
    end

    it 'has both recorded fragments on disk' do
      described_class::ENTRIES.each do |entry|
        %w[baseline current].each do |side|
          path = described_class.path_for(entry[:id], side)

          expect(File.exist?(path)).to be(true), "#{path} is missing"
          expect(File.binread(path)).not_to be_empty, "#{path} is empty"
        end
      end
    end

    # A no-op hunk is worse than no hunk: it spends a ratchet slot and licenses
    # nothing, so the next person reads the count and believes the kernel moved.
    it 'actually changes something' do
      described_class::ENTRIES.each do |entry|
        expect(described_class.baseline_fragment(entry[:id]))
          .not_to eq(described_class.current_fragment(entry[:id])), "#{entry[:id]} changes nothing"
      end
    end
  end

  # These read the baseline blob, so they need history — and will not get it in the
  # rsynced copy inside the Redmine clone (redmine_clone.sh excludes .git). Same skip
  # as baseline_spec.rb, and the same consequence: the `corpus` job must run these
  # from the plugin checkout or the mechanism has no reference check at all.
  describe 'against the baseline blob' do
    before do
      next if File.directory?(File.join(RrdGolden::Baseline.repo_root, '.git'))

      skip 'no git history here — this is the rsynced copy inside the Redmine clone ' \
           '(redmine_clone.sh excludes .git). The corpus job must run these from the ' \
           'plugin checkout, or the G7 exception mechanism loses its reference check.'
    end

    it 'locates every recorded hunk exactly once' do
      described_class::ENTRIES.each do |entry|
        blob = RrdGolden::Baseline.file_at_baseline(
          RrdGolden::Baseline::KERNEL_FILES.fetch(entry[:file])
        )

        expect(blob.scan(described_class.baseline_fragment(entry[:id])).length).to eq(1),
                                                                                  "#{entry[:id]} does not match the baseline in exactly one place. A hunk " \
                                                                                  'that cannot be located has stopped describing the file it was ' \
                                                                                  'recorded against — re-record it, do not delete the check.'
      end
    end

    # The whole mechanism in one line: the working kernel is the blob plus exactly the
    # declared hunks, and nothing else — IN CODE. Comments are outside G7 since the curator
    # lifted byte-identity on 2026-08-15 (`code_only.rb`), and they are outside this
    # statement for the same reason: a rewritten comment is not an undeclared edit.
    #
    # baseline_spec.rb makes this gate G7; here it is stated as a property of the mechanism
    # itself, so a broken reconstruction is distinguishable from an undeclared edit.
    it 'reconstructs the working kernel from the blob and the declared hunks alone' do
      described_class::ENTRIES.map { |entry| entry[:file] }.uniq.each do |current_path|
        working = File.binread(File.join(RrdGolden::Baseline.repo_root, current_path))

        expect(RrdGolden::CodeOnly.call(described_class.expected_for(current_path)))
          .to eq(RrdGolden::CodeOnly.call(working))
      end
    end

    # Fail closed. A hunk recorded against a baseline it no longer matches must raise,
    # never quietly reduce to "no exception applies" — which would pass an unlicensed
    # kernel and fail a licensed one, in whichever order is most confusing.
    it 'raises rather than skipping a hunk it cannot locate' do
      entry = described_class::ENTRIES.first
      allow(described_class).to receive(:baseline_fragment)
        .with(entry[:id]).and_return("# a hunk that is not in the baseline\n")

      expect { described_class.expected_for(entry[:file]) }
        .to raise_error(/matches 0 places/)
    end
  end
end
