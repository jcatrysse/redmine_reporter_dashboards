# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'corpus_canonicaliser'

RSpec.describe RrdGolden::CorpusCanonicaliser do
  def canon(value)
    described_class.canonicalise(value)
  end

  describe 'key ordering' do
    it 'sorts keys recursively, so two runs that build a Hash differently agree' do
      a = { 'b' => { 'z' => 1, 'a' => 2 }, 'a' => 3 }
      b = { 'a' => 3, 'b' => { 'a' => 2, 'z' => 1 } }

      expect(described_class.line(a)).to eq(described_class.line(b))
      expect(described_class.line(a)).to eq('{"a":3,"b":{"a":2,"z":1}}')
    end

    it 'sorts symbol and string keys together rather than by type' do
      expect(canon({ :b => 1, 'a' => 2 }).keys).to eq(%w[a b])
    end

    it 'refuses a Hash whose symbol and string keys collide' do
      expect { canon({ :a => 1, 'a' => 2 }) }
        .to raise_error(described_class::UnsupportedValue, /key collision on \["a"\]/)
    end
  end

  describe 'array ordering' do
    # buckets / labels / rows / series ARE the ordering contract. Sorting them here
    # would hide exactly the regression the corpus is meant to catch.
    it 'preserves array order' do
      expect(canon([3, 1, 2])).to eq([3, 1, 2])
    end

    it 'makes a reordered array a different record' do
      expect(described_class.line(%w[a b])).not_to eq(described_class.line(%w[b a]))
    end

    it 'preserves order inside a nested value while still sorting that value\'s keys' do
      expect(described_class.line({ 'buckets' => [{ 'v' => 2, 'k' => 'x' }, { 'k' => 'y', 'v' => 1 }] }))
        .to eq('{"buckets":[{"k":"x","v":2},{"k":"y","v":1}]}')
    end
  end

  describe 'sentinels' do
    it 'round-trips a symbol as its literal name' do
      expect(canon(:total)).to eq('total')
    end

    it 'round-trips a symbol nested in a structure' do
      expect(canon({ measure: :count })).to eq({ 'measure' => 'count' })
    end

    # Deliberate and documented: JSON has no symbol, so :total and "total" collapse.
    # Asserted so the collapse is a decision on record rather than a surprise.
    it 'renders a symbol and its string identically' do
      expect(described_class.line(:total)).to eq(described_class.line('total'))
    end
  end

  describe 'nil / 0 / empty string' do
    it 'keeps all three distinct' do
      lines = [nil, 0, ''].map { |v| described_class.line(v) }

      expect(lines).to eq(%w[null 0 ""])
      expect(lines.uniq.length).to eq(3)
    end

    it 'keeps a nil value distinct from an absent key' do
      expect(described_class.line({ 'a' => nil })).not_to eq(described_class.line({}))
    end

    it 'keeps integer 0 distinct from float 0.0' do
      expect(described_class.line(0)).not_to eq(described_class.line(0.0))
    end

    it 'keeps false distinct from nil' do
      expect(described_class.line(false)).not_to eq(described_class.line(nil))
    end
  end

  describe 'floats at the declared 4-decimal contract' do
    it 'stores the scaled integer and its 4-dp rendering' do
      expect(canon(100.5)).to eq({ '__f4' => [1_005_000, '100.5000'] })
    end

    it 'derives the string from the integer, so the pair can never disagree' do
      canon(1.00005).fetch('__f4').then do |scaled, text|
        expect(format('%.4f', scaled.to_f / described_class::SCALE)).to eq(text)
      end
    end

    it 'treats a difference beyond the fourth decimal as no difference' do
      expect(described_class.line(1.000_000_1)).to eq(described_class.line(1.0))
    end

    it 'treats a difference at the fourth decimal as a difference' do
      expect(described_class.line(1.0001)).not_to eq(described_class.line(1.0))
    end

    it 'records a negative float' do
      expect(canon(-0.0005)).to eq({ '__f4' => [-5, '-0.0005'] })
    end

    it 'coerces BigDecimal through the same path' do
      expect(canon(BigDecimal('2.5'))).to eq(canon(2.5))
    end

    it 'coerces Rational through the same path' do
      expect(canon(Rational(1, 4))).to eq(canon(0.25))
    end

    # A non-finite aggregate is a division by a zero count, i.e. a defect. Freezing
    # it would enshrine the defect as the expected answer.
    it 'refuses NaN' do
      expect { canon(Float::NAN) }
        .to raise_error(described_class::NonFiniteValue, /defect in the aggregation/)
    end

    it 'refuses Infinity' do
      expect { canon(Float::INFINITY) }.to raise_error(described_class::NonFiniteValue)
    end
  end

  describe 'dates and times' do
    it 'records a Date as an ISO-8601 date' do
      expect(canon(Date.new(2025, 12, 29))).to eq('2025-12-29')
    end

    it 'records a Time with full precision, in its own offset' do
      expect(canon(Time.utc(2025, 12, 29, 12, 0, 0))).to eq('2025-12-29T12:00:00.000000000+00:00')
    end
  end

  describe 'unsupported values' do
    it 'refuses a value it has no deliberate form for' do
      expect { canon(Object.new) }
        .to raise_error(described_class::UnsupportedValue, /no canonical corpus form/)
    end

    it 'refuses an unusable key type' do
      expect { canon({ [1] => 2 }) }
        .to raise_error(described_class::UnsupportedValue, /not usable as a canonical corpus key/)
    end
  end

  describe 'the file format' do
    let(:records) { [{ 'b' => 1, 'a' => 2 }, [1, 2.5], nil] }

    it 'writes one JSON object per line and ends with a newline' do
      expect(described_class.encode(records))
        .to eq(%({"a":2,"b":1}\n[1,{"__f4":[25000,"2.5000"]}]\nnull\n))
    end

    it 'round-trips through decode' do
      expect(described_class.decode(described_class.encode(records)))
        .to eq(records.map { |r| canon(r) })
    end

    it 'ignores blank lines on the way back in' do
      expect(described_class.decode("{}\n\n  \n[]\n")).to eq([{}, []])
    end

    it 'names the offending line number when a line is not JSON' do
      expect { described_class.decode("{}\nnot json\n") }
        .to raise_error(JSON::ParserError, /corpus line 2/)
    end
  end

  describe 'reproducibility' do
    it 'gives the same digest for the same records' do
      expect(described_class.digest([{ 'a' => 1.5 }])).to eq(described_class.digest([{ 'a' => 1.5 }]))
    end

    it 'gives the same digest regardless of how the Hash was built' do
      expect(described_class.digest([{ 'b' => 1, 'a' => 2 }]))
        .to eq(described_class.digest([{ 'a' => 2, 'b' => 1 }]))
    end

    it 'gives a different digest when a number changes at the fourth decimal' do
      expect(described_class.digest([{ 'a' => 1.0001 }]))
        .not_to eq(described_class.digest([{ 'a' => 1.0 }]))
    end

    it 'is taken over the encoded bytes, so it cannot pass while the file differs' do
      records = [{ 'a' => 1 }]

      expect(described_class.digest(records))
        .to eq(Digest::SHA256.hexdigest(described_class.encode(records)))
    end
  end
end
