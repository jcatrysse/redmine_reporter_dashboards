# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'reference_date'

RSpec.describe RrdGolden::ReferenceDate do
  # ENV is process-global and the suite runs in random order, so every example that
  # touches it restores what it found. A leaked pin would silently move another
  # spec's fixture, which is the failure mode this whole file exists to prevent.
  around do |example|
    previous = ENV.fetch(described_class::ENV_VAR, nil)
    begin
      example.run
    ensure
      if previous.nil?
        ENV.delete(described_class::ENV_VAR)
      else
        ENV[described_class::ENV_VAR] = previous
      end
    end
  end

  def pin(value)
    if value.nil?
      ENV.delete(described_class::ENV_VAR)
    else
      ENV[described_class::ENV_VAR] = value
    end
  end

  describe 'the default the corpus is generated with' do
    subject(:default) { Date.iso8601(described_class::DEFAULT) }

    # This is the reason 2025-12-29 was chosen over any other day, so it is asserted
    # rather than left in a comment: if someone moves DEFAULT to a date without the
    # mismatch, the corpus quietly stops covering the one divergence it was picked
    # for and nothing else in the suite would notice.
    it 'is a date whose ISO year differs from its calendar year' do
      expect(default.cwyear).not_to eq(default.year)
      expect([default.year, default.cwyear, default.cweek]).to eq([2025, 2026, 1])
    end

    it 'is a Monday, so it is the first day of its ISO week rather than a day inside one' do
      expect(default.strftime('%A')).to eq('Monday')
    end

    it 'spans three distinct ISO years across the 400-day sweep' do
      sweep = (0...400).map { |i| default - i }

      expect(sweep.map(&:cwyear).uniq.sort).to eq([2024, 2025, 2026])
    end
  end

  describe '.date' do
    it 'is nil when unset, so the adapter fixture stays relative to today' do
      pin(nil)

      expect(described_class.date).to be_nil
    end

    it 'is nil when set to whitespace only' do
      pin("  \t ")

      expect(described_class.date).to be_nil
    end

    it 'parses an extended ISO-8601 date' do
      pin('2025-12-29')

      expect(described_class.date).to eq(Date.new(2025, 12, 29))
    end

    it 'rejects the compact ISO-8601 form, so one date has exactly one spelling' do
      pin('20251229')

      expect { described_class.date }.to raise_error(described_class::Malformed, /extended ISO-8601/)
    end

    it 'rejects a date-time' do
      pin('2025-12-29T00:00:00Z')

      expect { described_class.date }.to raise_error(described_class::Malformed, /extended ISO-8601/)
    end

    it 'rejects a well-shaped string that is not a real date' do
      pin('2025-02-30')

      expect { described_class.date }.to raise_error(described_class::Malformed, /not a real date/)
    end

    it 'names the environment variable and the expected default in its complaint' do
      pin('nonsense')

      expect { described_class.date }
        .to raise_error(described_class::Malformed, /RRD_REFERENCE_DATE.*2025-12-29/m)
    end
  end

  describe '.pinned?' do
    it 'is false when unset' do
      pin(nil)

      expect(described_class).not_to be_pinned
    end

    it 'is true when set' do
      pin('2024-01-01')

      expect(described_class).to be_pinned
    end
  end

  describe '.require!' do
    it 'returns the pinned date' do
      pin('2024-02-29')

      expect(described_class.require!).to eq(Date.new(2024, 2, 29))
    end

    # The refusal, not a warning. An unpinned corpus goes red daily for the wrong
    # reason and is switched off within a week — which is how this mitigation fails
    # in practice rather than in theory.
    it 'refuses to run unpinned' do
      pin(nil)

      expect { described_class.require! }
        .to raise_error(described_class::NotPinned, /is not set.*oracle/m)
    end

    it 'tells the reader which value to set' do
      pin(nil)

      expect { described_class.require! }
        .to raise_error(described_class::NotPinned, /RRD_REFERENCE_DATE=2025-12-29/)
    end

    it 'still refuses when the variable is present but empty' do
      pin('')

      expect { described_class.require! }.to raise_error(described_class::NotPinned)
    end
  end
end
