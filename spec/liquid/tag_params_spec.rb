# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/liquid/tag_params'

# CURATOR DECISION #3 (2026-08-13) — A QUOTE MEANS LITERAL TEXT.
#
# The defect this file pins: `PARAM_RE` captured a double-quoted, a single-quoted and a
# bare value into three separate groups, and every one of the five `parse_markup` copies
# collapsed them into one String. By the time `str_param` ran, the quoting was gone and
# it looked EVERY value up in the Liquid context — so `group_by: "user"` meant "whatever
# the variable `user` holds", and `user` is assigned in every report this plugin renders.
#
# The examples below are written from the outside in: what an author typed, and what the
# tag layer is handed. Nothing here stubs the rule it is testing.
RSpec.describe RedmineReporterDashboards::Liquid::TagParams do
  # A context stand-in with the one method `resolve` uses. Deliberately NOT a Liquid
  # context: this module must be testable without the gem, which is what lets it run
  # under both Liquid majors in `spec_liquid/` without a second harness.
  def context(assigns = {})
    assigns
  end

  describe '.parse' do
    it 'records a double-quoted value as quoted' do
      expect(described_class.parse('group_by: "user"').fetch('group_by')).to be_quoted
    end

    it 'records a single-quoted value as quoted' do
      expect(described_class.parse("group_by: 'user'").fetch('group_by')).to be_quoted
    end

    it 'records a bare value as NOT quoted' do
      expect(described_class.parse('group_by: user').fetch('group_by')).not_to be_quoted
    end

    it 'keeps the text itself free of the quotes' do
      expect(described_class.parse('other_label: "Everything else"').fetch('other_label'))
        .to eq('Everything else')
    end

    # `x: ""` has always meant "not given" to `resolve`, and still does — but it must
    # still parse, or the key would be absent and `raw_params.key?` would answer
    # differently for a spelling the author can type.
    it 'parses an empty quoted value as a present, empty, quoted parameter' do
      params = described_class.parse('empty_label: ""')

      expect(params).to have_key('empty_label')
      expect(params.fetch('empty_label')).to be_empty
      expect(params.fetch('empty_label')).to be_quoted
    end

    it 'reads every parameter of a realistic tag, quoted and bare together' do
      params = described_class.parse(
        'group_by: age, age_buckets: "30;60;90", limit: 10, other_label: \'Rest\''
      )

      expect(params.keys).to eq(%w[group_by age_buckets limit other_label])
      expect(params.values.map(&:quoted?)).to eq([false, true, false, true])
    end
  end

  describe '.resolve — the rule' do
    # THE DEFECT, STATED AS AN EXAMPLE. `user` is assigned in every report, so before
    # this change the spent-time source's `user` dimension could not be asked for in any
    # spelling: bare resolved the variable, and quoting resolved it too.
    it 'does NOT look a quoted value up, even when a variable of that name exists' do
      params = described_class.parse('group_by: "user"')

      expect(described_class.resolve(params['group_by'], context('user' => 'Redmine Admin')))
        .to eq('user')
    end

    it 'looks a BARE value up, which is unchanged' do
      params = described_class.parse('group_by: gb')

      expect(described_class.resolve(params['group_by'], context('gb' => 'tracker')))
        .to eq('tracker')
    end

    # The fallback is what makes `group_by: status` mean the FIELD rather than an empty
    # string, and it is the half of the old behaviour that was always right.
    it 'falls back to the literal when a bare value resolves to nothing' do
      params = described_class.parse('group_by: tracker')

      expect(described_class.resolve(params['group_by'], context)).to eq('tracker')
    end

    it 'answers the default for an absent parameter' do
      expect(described_class.resolve(nil, context, default: 'month')).to eq('month')
    end

    it 'answers the default for an empty one, quoted or not' do
      quoted = described_class.parse('period: ""').fetch('period')

      expect(described_class.resolve(quoted, context, default: 'month')).to eq('month')
      expect(described_class.resolve('', context, default: 'month')).to eq('month')
    end

    it 'lets a caller declare nil as the default, which is a real answer' do
      expect(described_class.resolve(nil, context, default: nil)).to be_nil
    end

    it 'stringifies whatever the context held, so a caller never sees a drop' do
      params = described_class.parse('limit: n')

      expect(described_class.resolve(params['limit'], context('n' => 10))).to eq('10')
    end

    # A context that cannot be indexed is treated as no context. `ScopeBinding#query_id_of`
    # has always guarded this and its callers include tests that pass nil.
    it 'treats a nil context as no context rather than raising' do
      params = described_class.parse('query_id: 7')

      expect(described_class.resolve(params['query_id'], nil)).to eq('7')
    end
  end

  # THE VALUE TYPE MUST NOT ESCAPE THIS LAYER. `Value` is a String subclass so that every
  # existing reader keeps working; the price of that trick is that one leaking into a
  # bucket label, a JSON payload or a rendered document would be a String subclass with an
  # ivar in somebody else's data. `resolve` is the only exit and it returns a plain String.
  describe 'Value never leaves the layer' do
    it 'returns a plain String for a quoted literal' do
      params = described_class.parse('other_label: "Rest"')

      expect(described_class.resolve(params['other_label'], context).class).to be(String)
    end

    it 'returns a plain String for a bare fallback' do
      params = described_class.parse('other_label: Rest')

      expect(described_class.resolve(params['other_label'], context).class).to be(String)
    end
  end

  # WHAT THE SUBCLASS HAS TO SURVIVE. Each of these is a real reader in one of the five
  # tags, and each would be a silent defect rather than an exception if `Value` behaved
  # differently from a String.
  describe 'Value behaves as the String every reader expects' do
    let(:params) { described_class.parse('y: "count", width: "640", type: "bar"') }

    it 'works as a Hash key, which is how SeriesReader reads a bucket' do
      expect({ 'count' => 12 }[params['y']]).to eq(12)
    end

    it 'works with Integer(), which is how ChartTag reads width' do
      expect(Integer(params['width'])).to eq(640)
    end

    it 'compares equal to the plain String, which is how every enum check reads' do
      expect(params['type']).to eq('bar')
      expect(%w[bar line].include?(params['type'])).to be(true)
    end

    it 'interpolates without the class showing' do
      expect("type=#{params['type']}").to eq('type=bar')
    end
  end

  describe '.quoted?' do
    # A String a caller built — in a test, or by concatenation — is BARE, which is the
    # pre-decision behaviour. The change is confined to what the author actually typed.
    it 'answers false for a plain String that did not come from .parse' do
      expect(described_class.quoted?('user')).to be(false)
    end

    it 'answers false for nil' do
      expect(described_class.quoted?(nil)).to be(false)
    end
  end
end
