# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'baseline'

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

  describe 'the byte-identity reference for gate G7' do
    it 'can read every kernel file at the baseline' do
      described_class::KERNEL_FILES.each do |path|
        content = described_class.file_at_baseline(path)

        expect(content).not_to be_nil, "#{path} does not exist at the baseline commit"
        expect(content).not_to be_empty, "#{path} is empty at the baseline commit"
      end
    end

    it 'names the two files the spec says are ported byte-identically, and only those' do
      expect(described_class::KERNEL_FILES).to contain_exactly(
        'lib/sql_aggregation/query_aggregator.rb',
        'lib/sql_aggregation/drill_through.rb'
      )
    end

    # Today the working tree still holds the originals, so this passes trivially. It
    # is here for after the port: it is the assertion that turns "we moved the
    # aggregator" into "we moved the aggregator without changing a byte".
    it 'matches the working tree while the kernel has not yet been moved' do
      described_class::KERNEL_FILES.each do |path|
        working = File.join(described_class.repo_root, path)
        next unless File.exist?(working)

        expect(File.binread(working)).to eq(described_class.file_at_baseline(path)),
                                                        "#{path} differs from the baseline. If the kernel has been " \
                                                        'ported, this belongs in the corpus job against the new ' \
                                                        'location; if it has not, the kernel was edited and G7 is broken.'
      end
    end
  end
end
