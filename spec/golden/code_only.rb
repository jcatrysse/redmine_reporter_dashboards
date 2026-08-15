# frozen_string_literal: true

require 'ripper'

module RrdGolden
  # Gate G7 compares the ported aggregation kernel against its v0.5.0 blob. This is what
  # it compares: the file with every comment removed.
  #
  # WHY NOT BYTES ANY MORE. G7's claim has always been "the aggregator was moved without
  # changing it". Bytes were a cheap way to state that, and for a long time an exact one.
  # They also froze 834 lines of comment in the two largest files in the tree, so the
  # documentation pass could not reach the code that most needed it — and a comment cannot
  # change a number. Curator decision, 2026-08-15: the gate holds the CODE identical and
  # lets the prose move.
  #
  # WHAT DID NOT CHANGE. Every byte of code is still compared, still against the same
  # commit, and a declared hunk in `KernelException` is still the only way a code change
  # can pass. Nothing here is a diff or a tolerance: two files that differ by one character
  # of code fail exactly as loudly as before.
  #
  # RIPPER, NOT A REGULAR EXPRESSION. `^\s*#` is wrong inside a heredoc, and `#[^"]*$` is
  # wrong for every string containing a `#`. The lexer knows which `#` starts a comment
  # because it is the thing that decides. `=begin`/`=end` blocks are removed too.
  module CodeOnly
    COMMENT_TOKENS = %i[on_comment on_embdoc_beg on_embdoc on_embdoc_end].freeze

    class << self
      # `source` is bytes — from `File.binread` or from `git show`. The result is a UTF-8
      # string with comments removed, comment-only lines dropped, and trailing whitespace
      # stripped from any line a comment was cut off.
      def call(source)
        text = String(source).dup.force_encoding(Encoding::UTF_8)
        cuts = comment_cuts(text)
        return text if cuts.empty?

        lines = text.lines
        kept = lines.each_with_index.filter_map do |line, index|
          spans = cuts[index + 1]
          next line if spans.nil?

          stripped = remove(line, spans)
          # A line that held nothing but a comment goes entirely; one that held code and a
          # trailing comment keeps the code without the whitespace that led up to the `#`.
          next nil if stripped.strip.empty?

          "#{stripped.rstrip}\n"
        end

        kept.join
      end

      private

      # `{ line_number => [[column, length], …] }`, columns in characters.
      def comment_cuts(text)
        Ripper.lex(text).each_with_object({}) do |((line, column), type, token, _state), cuts|
          next unless COMMENT_TOKENS.include?(type)

          (cuts[line] ||= []) << [column, token.length]
        end
      end

      # Right to left, so an earlier span's columns stay valid.
      def remove(line, spans)
        spans.sort_by { |column, _| -column }
             .reduce(line) { |acc, (column, length)| acc.slice(0, column).to_s + acc.slice(column + length..).to_s }
      end
    end
  end
end
