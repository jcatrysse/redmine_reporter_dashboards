# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/liquid/render_context'

# T-31 / §Findings **S-13** — the render context SAYS which table its scope is over.
#
# --- WHY THIS IS AN ATTRIBUTE AND NOT A QUESTION ASKED OF THE RELATION ---
#
# `QueryAggregator` counts `DISTINCT issues.id`. Handed a time-entry relation it does not
# raise — `TimeEntryQuery#base_scope` calls `.left_join_issue`, so the issue columns resolve
# and it answers issue counts under time-entry labels. Four entries over two issues came
# back as `2` in every bucket.
#
# The guard therefore has to know which table it is looking at, and asking the relation is
# the wrong way round: every legacy-path scope is an issue scope and correctly carries no
# annotation, and the tag specs' scope doubles answer no `model`, `klass` or `table_name` at
# all — so a sniffing check would raise on the doubles and fail OPEN on precisely the object
# it could not identify. The producer knows, because `template.source` is a column.
RSpec.describe RedmineReporterDashboards::Liquid::RenderContext do
  let(:actor) { Object.new }

  it 'defaults to issues, which is what every caller predating T-31 holds' do
    expect(described_class.new(actor: actor).source).to eq(:issues)
  end

  it 'accepts the second source' do
    expect(described_class.new(actor: actor, source: :time_entries).source)
      .to eq(:time_entries)
  end

  it 'accepts a String, because a column answers one' do
    expect(described_class.new(actor: actor, source: 'time_entries').source)
      .to eq(:time_entries)
  end

  # A CLOSED SET, AND NOT COERCED TO A DEFAULT. `output` takes the opposite approach —
  # an unknown value there falls back to `:html` — and the difference is deliberate: a
  # wrong output binding draws a canvas instead of an SVG, while a wrong SOURCE decides
  # which table a number came from. §7 rule 5 makes "an install one minor behind reading a
  # newer row" routine, so the two have to be told apart at the moment behaviour is chosen.
  it 'refuses a source it does not know rather than defaulting to issues' do
    expect { described_class.new(actor: actor, source: :invoices) }
      .to raise_error(ArgumentError, /not a report source/)
  end

  it 'names the closed set in the refusal, so the caller can see the two options' do
    expect { described_class.new(actor: actor, source: :invoices) }
      .to raise_error(ArgumentError, /issues.*time_entries/)
  end

  # THE DERIVATIONS MUST CARRY IT. `RenderContext` is frozen, so "the same context with one
  # thing changed" is a new object — and `TemplateRenderer` derives one per render for the
  # budget, `ReportRun` derives one per binding for the output, and `Batch` derives one of
  # its own. A derivation that dropped the source would silently answer `:issues` and put
  # S-13's wrong numbers straight back.
  describe 'derivations' do
    subject(:context) { described_class.new(actor: actor, source: :time_entries) }

    it 'survives with_output' do
      expect(context.with_output(:pdf).source).to eq(:time_entries)
    end

    it 'survives with_budget' do
      expect(context.with_budget(RedmineReporterDashboards::Liquid::Budget::NULL).source).to eq(:time_entries)
    end

    it 'survives with_batch' do
      expect(context.with_batch(context.batch).source).to eq(:time_entries)
    end
  end
end
