# frozen_string_literal: true

require 'json'
require 'date'
require 'bigdecimal'
require 'digest'

module RrdGolden
  # Turns an aggregation result into the one byte sequence the corpus stores for it.
  #
  # The corpus is a differential oracle: it only earns its keep if a difference in
  # the bytes means a difference in the numbers, and a difference in the numbers
  # always shows up in the bytes. Everything below serves one of those two
  # directions, and the rules are `technical-spec.md` §2 Step 0's, not invented here.
  #
  #   keys sorted recursively   two runs that build the same Hash in a different
  #                             order are the same result
  #   array order PRESERVED     `buckets`, `labels`, `rows` and `series` are
  #                             ordering contracts — sorting them would hide a
  #                             regression in the very thing being frozen
  #   symbols -> strings        the aggregator returns sentinels as symbols; JSON has
  #                             no symbol, so they round-trip as their literal name
  #   nil / 0 / "" distinct     "no value", "measured zero" and "empty string" are
  #                             three different answers; JSON keeps them apart and
  #                             nothing here may collapse them
  #   floats at 4 dp            PostgreSQL's CAST(x AS numeric) and MySQL's
  #                             CAST(x AS DECIMAL(20,4)) do not agree past the
  #                             fourth decimal, so 4 dp IS the declared contract.
  #                             Beyond it there is nothing to be faithful to
  #
  # There is deliberately NO floating-point tolerance. A tolerance hides drift; the
  # per-adapter overlay (see the generator) names it.
  module CorpusCanonicaliser
    SCALE = 10_000

    # A float becomes a two-element tagged pair: the scaled integer that comparison
    # actually uses, and its 4-dp rendering so a failing diff is readable by a human
    # instead of being a wall of digits.
    #
    # The string is derived FROM the integer, never measured alongside it. Computed
    # independently the two could disagree — `%.4f` and `(v * SCALE).round` do not
    # round the same way at a tie — and the corpus would then fail on a
    # representation artefact rather than on a number.
    FLOAT_TAG = '__f4'

    class NonFiniteValue < ArgumentError; end
    class UnsupportedValue < ArgumentError; end

    class << self
      # The canonical Ruby structure: JSON-safe, deterministically ordered.
      def canonicalise(value)
        case value
        when nil, true, false, Integer, String then scalar(value)
        when Symbol                            then value.to_s
        when Float                             then float(value)
        when BigDecimal, Rational              then float(value.to_f)
        when Hash                              then hash(value)
        when Array                             then value.map { |v| canonicalise(v) }
        when Time, DateTime                    then value.to_datetime.iso8601(9)
        when Date                              then value.iso8601
        else
          raise UnsupportedValue,
                "#{value.class} has no canonical corpus form (value: #{value.inspect}). Add one " \
                'deliberately — falling back on #to_s would freeze whatever Ruby happens to print.'
        end
      end

      # One corpus record as the line that is written to disk. Generated and verified
      # through the same method, so the comparison can never be looser than the file.
      def line(value)
        JSON.generate(canonicalise(value))
      end

      def encode(records)
        records.map { |record| line(record) }.join("\n") + "\n"
      end

      # Each line is parsed back independently, so one malformed line names itself
      # rather than failing the whole file at an offset.
      #
      # Accumulated explicitly rather than with filter_map, which would drop a record
      # that legitimately parses to nil and so break the one rule this file exists to
      # keep: nil, 0 and "" are three different answers.
      def decode(text)
        records = []
        text.each_line.with_index(1) do |raw, number|
          next if raw.strip.empty?

          begin
            records << JSON.parse(raw)
          rescue JSON::ParserError => e
            raise JSON::ParserError, "corpus line #{number} is not valid JSON: #{e.message}"
          end
        end
        records
      end

      # Identity of a whole corpus file, for the "bit-reproducible across two
      # independent runs" check. Over the encoded bytes, so it cannot pass while the
      # file on disk differs.
      def digest(records)
        Digest::SHA256.hexdigest(encode(records))
      end

      private

      def scalar(value)
        value
      end

      def hash(value)
        # Symbol and string keys must not become two entries that only differ by how
        # the aggregator happened to build them, and `sort` on mixed types raises —
        # so keys are stringified first, then sorted, then checked for collisions.
        keyed = value.map { |k, v| [hash_key(k), v] }

        duplicates = keyed.map(&:first).tally.select { |_, n| n > 1 }.keys
        unless duplicates.empty?
          raise UnsupportedValue,
                "canonical key collision on #{duplicates.sort.inspect}: the same key appears both " \
                'as a Symbol and as a String, so the two values cannot both be recorded. Fix the ' \
                'result shape rather than the canonicaliser.'
        end

        keyed.sort_by(&:first).to_h { |k, v| [k, canonicalise(v)] }
      end

      def hash_key(key)
        case key
        when String, Symbol then key.to_s
        when Integer        then key.to_s
        else
          raise UnsupportedValue,
                "#{key.class} is not usable as a canonical corpus key (#{key.inspect})."
        end
      end

      def float(value)
        unless value.finite?
          raise NonFiniteValue,
                "#{value} cannot be recorded in the corpus. A non-finite aggregate is a defect in " \
                'the aggregation, not a value to freeze — usually a division by a zero count.'
        end

        scaled = (value * SCALE).round
        { FLOAT_TAG => [scaled, format('%.4f', scaled.to_f / SCALE)] }
      end
    end
  end
end
