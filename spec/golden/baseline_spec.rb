# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'baseline'
require_relative 'kernel_exception'
require_relative 'code_only'

# The corpus and gate G7 both compare against one commit. If that commit stops
# resolving, or stops being the thing it claims to be, every comparison built on it
# is meaningless — and would go on passing, because a comparison against nothing
# finds no differences. So the reference is checked, against real git output, rather
# than trusted.
RSpec.describe RrdGolden::Baseline do
  # These examples need git history, and they will NOT get it in the mirrored run.
  #
  # redmine_clone.sh rsyncs the plugin into redmine/plugins/<name>/ with `--exclude
  # .git/`, so the copy the suite normally executes from has no history at all. That
  # is not a defect to work around: history is a property of the repository, not of
  # the code under test, and there is genuinely nothing to check in a copy.
  #
  # The consequence has to be stated, though, because a skipped guard looks exactly
  # like a passing one: **the `corpus` job must run this from the plugin checkout**,
  # not from inside the Redmine clone. If it runs only in the mirror, gate G7 has no
  # reference check at all and will report green forever.
  before do
    next if File.directory?(File.join(described_class.repo_root, '.git'))

    skip 'no git history here — this is the rsynced copy inside the Redmine clone ' \
         '(redmine_clone.sh excludes .git). The corpus job must run these from the ' \
         'plugin checkout, or gate G7 loses its reference check silently.'
  end

  it 'resolves to a real commit' do
    expect(described_class.resolved_commit).to eq(described_class::COMMIT),
                                               'the baseline commit is unreachable: history was rewritten, or a ' \
                                               'squash merge dropped it. See the note in baseline.rb — this is a ' \
                                               'finding, not something to fix by editing the SHA.'
  end

  it 'is the commit that declares the baseline version' do
    init = described_class.file_at_baseline('init.rb')

    expect(init).to include("version '#{described_class::VERSION}'".b)
  end

  # The whole point of naming a commit instead of a tag.
  it 'is an ancestor of the current HEAD, so it survives an ordinary merge' do
    require 'open3'
    _out, _err, status = Open3.capture3('git', '-C', described_class.repo_root,
                                        'merge-base', '--is-ancestor', described_class::COMMIT, 'HEAD')

    expect(status.success?).to be(true),
                              'HEAD no longer descends from the baseline commit, so `git show <baseline>:file` will ' \
                              'stop working once the branch is gone. Tag it before that happens.'
  end

  describe 'the code-identity reference for gate G7' do
    it 'can read every kernel file at the baseline' do
      described_class::KERNEL_FILES.each_value do |baseline_path|
        content = described_class.file_at_baseline(baseline_path)

        expect(content).not_to be_nil, "#{baseline_path} does not exist at the baseline commit"
        expect(content).not_to be_empty, "#{baseline_path} is empty at the baseline commit"
      end
    end

    it 'names the two files the spec says are ported byte-identically, and only those' do
      expect(described_class::KERNEL_FILES).to eq(
        'lib/redmine_reporter_dashboards/aggregation/query_aggregator.rb' =>
          'lib/sql_aggregation/query_aggregator.rb',
        'lib/redmine_reporter_dashboards/aggregation/drill_through.rb' =>
          'lib/sql_aggregation/drill_through.rb'
      )
    end

    # THE G7 ASSERTION: the ported kernel is the v0.5.0 kernel, with every DECLARED hunk
    # applied, comparing CODE. `CodeOnly` says why comments stopped counting; every byte of
    # code is still compared, and a declared hunk is still the only way a code change passes.
    it 'is code-identical to the baseline blob at the ported location' do
      described_class::KERNEL_FILES.each_key do |current_path|
        working = File.join(described_class.repo_root, current_path)

        expect(File.exist?(working)).to be(true),
                                       "#{current_path} is missing. KERNEL_FILES names where the ported " \
                                       'kernel lives; if it moved again, this map moves with it.'
        expect(RrdGolden::CodeOnly.call(File.binread(working)))
          .to eq(RrdGolden::CodeOnly.call(RrdGolden::KernelException.expected_for(current_path))),
              "#{current_path} differs IN CODE from its v0.5.0 blob " \
              "(#{described_class::KERNEL_FILES[current_path]}) by something no declared hunk " \
              'accounts for. Gate G7 holds the kernel code identical: the only change it may ' \
              'carry is the one T-08 argues for, and it has to be declared in ' \
              'kernel_exception.rb rather than discovered here. Comments are free to move.'
      end
    end

    # THE CANONICALISER MUST NOT BE ABLE TO HIDE A CODE CHANGE, and this is where that is
    # proved rather than assumed. A gate that compares a transformation of two files is only
    # as good as the transformation: one that returned '' would pass everything.
    it 'still fails on a one-character code change' do
      path = described_class::KERNEL_FILES.keys.first
      original = File.binread(File.join(described_class.repo_root, path))
      mutated = original.sub(/^(\s*)MAX_/) { "#{Regexp.last_match(1)}XAM_" }

      expect(mutated).not_to eq(original), 'the mutation did not apply; this example proves nothing'
      expect(RrdGolden::CodeOnly.call(mutated))
        .not_to eq(RrdGolden::CodeOnly.call(original))
    end

    it 'ignores a comment-only change, which is the point of lifting byte-identity' do
      path = described_class::KERNEL_FILES.keys.first
      original = File.binread(File.join(described_class.repo_root, path))
      recommented = original.sub(/^(\s*)# .*$/) { "#{Regexp.last_match(1)}# rewritten by the docs pass" }

      expect(recommented).not_to eq(original), 'the mutation did not apply; this example proves nothing'
      expect(RrdGolden::CodeOnly.call(recommented))
        .to eq(RrdGolden::CodeOnly.call(original))
    end

    # The exception mechanism is only worth anything if it is actually load-bearing:
    # a file with no declared hunk must still be held to plain byte-identity, and
    # drill_through.rb is the one that has none.
    it 'holds the kernel file with no declared hunk to the baseline itself' do
      path = 'lib/redmine_reporter_dashboards/aggregation/drill_through.rb'

      expect(RrdGolden::KernelException.entries_for(path)).to be_empty
      expect(RrdGolden::KernelException.expected_for(path))
        .to eq(described_class.file_at_baseline(described_class::KERNEL_FILES.fetch(path)))
    end
  end
end
