# frozen_string_literal: true

module RrdGolden
  # The commit the golden corpus is generated against, and the one the ported
  # aggregation kernel is diffed against.
  #
  # The plan says "the v0.5.0 tag". There is no such tag — this repository has no
  # tags at all — so the reference is the COMMIT instead, which is strictly better:
  # a tag can be moved or deleted, a SHA cannot.
  #
  # `main` was at this commit before any of the standalone work landed, and
  # `init.rb` there declares `version '0.5.0'`, so it is v0.5.0 in every sense but
  # the missing ref. The spec beside this file asserts both of those facts against
  # real `git` output, so the claim cannot rot quietly.
  #
  # --- The one way this reference can be lost ---
  #
  # It is an ancestor of every branch built on it, so an ordinary merge (or a
  # fast-forward, or a rebase-merge) keeps it reachable from `main` forever.
  #
  # A SQUASH merge does not: the squashed commit has no ancestry, and once the
  # feature branch is deleted the original commit becomes unreachable and is
  # eventually garbage-collected. If this repository ever adopts squash merges,
  # create the tag before the first one:
  #
  #     git tag -a v0.5.0 eddb8fa -m 'v0.5.0' && git push origin v0.5.0
  #
  # Do not "fix" a failing baseline spec by editing the SHA below. The SHA is the
  # oracle; if it no longer resolves, the history moved and that is the finding.
  module Baseline
    COMMIT = 'eddb8fa17c9c47e28044b41345c6533ec7898f5d'

    # What COMMIT is expected to declare, so "is this really 0.5.0?" is checkable
    # rather than asserted.
    VERSION = '0.5.0'

    # The two files ported without changing their code (technical-spec.md §1.3, gate G7).
    #
    # A MAP, not a list, because T-08 moved them: the key is where the file lives in the
    # working tree now, the value is where its blob lives at COMMIT. Before the move the
    # two were the same string and this check passed trivially; after it, the same
    # assertion is the real thing — "we moved the aggregator without changing a byte".
    #
    # Keep both sides. Collapsing to one path is how the reference gets lost: `git show
    # COMMIT:<new path>` does not resolve, and a check that cannot read its reference is
    # one bad `rescue` away from reporting success.
    KERNEL_FILES = {
      'lib/redmine_reporter_dashboards/aggregation/query_aggregator.rb' =>
        'lib/sql_aggregation/query_aggregator.rb',
      'lib/redmine_reporter_dashboards/aggregation/drill_through.rb' =>
        'lib/sql_aggregation/drill_through.rb'
    }.freeze

    class << self
      def repo_root
        File.expand_path('../..', __dir__)
      end

      # nil when the commit is not reachable — which is a finding, not a fallback.
      def resolved_commit
        out = git('rev-parse', '--verify', "#{COMMIT}^{commit}")
        out&.strip
      end

      def reachable?
        !resolved_commit.nil?
      end

      # Raw BYTES, deliberately. Comparing a git-captured string against a file read as
      # UTF-8 compares two different encodings of the same content: an em-dash shows up as
      # a three-byte difference that is not a difference. Pair this with File.binread, and
      # hand both sides to `CodeOnly` before comparing.
      def file_at_baseline(path)
        git('show', "#{COMMIT}:#{path}")
      end

      private

      def git(*args)
        require 'open3'
        out, _err, status = Open3.capture3('git', '-C', repo_root, *args)
        return nil unless status.success?

        out.force_encoding(Encoding::BINARY)
      end
    end
  end
end
