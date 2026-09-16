# frozen_string_literal: true
#
# T-02's survey against a real engine.
#
# It needs a database rather than a double for three reasons the double would not
# catch: `table_exists?`/`columns` are adapter behaviour, `quoted_true` differs between
# PostgreSQL (TRUE) and MySQL (1), and the whole point of the task is a claim about
# what it does to somebody's production database — "writes nothing" is only worth
# stating if something checks it against a connection that could be written to.
#
# The reporter-shaped tables are created HERE, not in adapter_helper.rb: they belong to
# this spec the way rrd_positioned_items belongs to positioned_spec.rb, and every other
# adapter spec would otherwise carry three tables it never reads.

require_relative 'adapter_helper'
require_relative '../../lib/redmine_reporter_dashboards/import/survey'

if !RrdAdapterHarness.configured?
  RSpec.describe 'RedmineReporterDashboards::Import::Survey' do
    it 'is skipped without a database URL' do
      skip RrdAdapterHarness.skip_reason
    end
  end
else
  # Reporter's schema as this repository understands it. Not a guess dressed as fact:
  # the column list is what `reference/source-inventory.md` and `technical-spec.md` §7
  # record about it, and the survey introspects rather than trusting it — which is what
  # the "missing column" examples below exercise.
  module RrdSurveyFixture
    TEMPLATE_BODIES = {
      # Needs rework: v2 axes, the handshake, an unfiltered interpolation, a footer token.
      'IssueListReportTemplate' => <<~LIQUID,
        <h1>{{ issue.subject }}</h1>
        <footer>[page] / [topage]</footer>
        <script>
          window.status = 'geo-ready';
          var labels = ["{{ version.name }}"];
          new Chart(ctx, { type: 'horizontalBar', scales: { xAxes: [{}] } });
        </script>
      LIQUID
      # Clean, and uses this plugin's own surface plus one gem-only accessor.
      'IssueReportTemplate' => <<~LIQUID,
        {% sql_aggregate from: issues, group_by: status, assign_to: by_status %}
        <p>{{ issue.story_points }} {{ issue.target_version.name }}</p>
        <script>var data = {{ by_status.buckets | json }};</script>
      LIQUID
      # Clean and chart-less.
      'TimeEntriesReportTemplate' => "<table>{% for e in entries %}<tr></tr>{% endfor %}</table>\n"
    }.freeze

    class << self
      def create!
        c = ActiveRecord::Base.connection

        c.create_table(:report_templates, force: true) do |t|
          t.string  :type, :name
          t.text    :description, :content
          t.integer :project_id, :author_id
          t.string  :orientation
          t.datetime :created_on, :updated_on
        end

        c.create_table(:report_schedules, force: true) do |t|
          t.integer  :project_id, :template_id, :query_id
          t.string   :repeat, :email_subject
          t.boolean  :enabled, null: false, default: true
          t.datetime :start_date, :end_date
        end

        # id: false, exactly as technical-spec.md §7 records — "so a join row is
        # unaddressable". The survey confirms that against the live schema rather than
        # repeating it, because it is the argument for the replacement table's
        # primary key.
        c.create_table(:report_schedules_users, id: false, force: true) do |t|
          t.integer :report_schedule_id, :user_id
        end
      end

      def seed!
        c = ActiveRecord::Base.connection
        truncate!

        TEMPLATE_BODIES.each_with_index do |(type, body), index|
          insert(c, :report_templates,
                 id: index + 1, type: type, name: "template #{index + 1}",
                 content: body, project_id: index.zero? ? nil : 1)
        end

        insert(c, :report_schedules, id: 1, template_id: 1, repeat: 'daily', enabled: true)
        insert(c, :report_schedules, id: 2, template_id: 1, repeat: 'weekly', enabled: true)
        insert(c, :report_schedules, id: 3, template_id: 2, repeat: 'weekly', enabled: false)

        [[1, 7], [1, 8], [2, 7]].each do |schedule_id, user_id|
          insert(c, :report_schedules_users, report_schedule_id: schedule_id, user_id: user_id)
        end
      end

      def truncate!
        c = ActiveRecord::Base.connection
        %w[report_schedules_users report_schedules report_templates].each do |table|
          c.delete("DELETE FROM #{c.quote_table_name(table)}") if c.table_exists?(table)
        end
      end

      def drop!
        c = ActiveRecord::Base.connection
        %w[report_schedules_users report_schedules report_templates].each do |table|
          c.drop_table(table, if_exists: true)
        end
      end

      # Written by hand rather than through a model: reporter's models may not exist,
      # and the survey is asserted to touch none, so the fixture should not need one
      # either.
      def insert(connection, table, values)
        columns = values.keys.map { |key| connection.quote_column_name(key) }.join(', ')
        binds   = values.values.map { |value| connection.quote(value) }.join(', ')
        connection.execute("INSERT INTO #{connection.quote_table_name(table)} " \
                           "(#{columns}) VALUES (#{binds})")
      end
    end
  end

  RSpec.describe 'RedmineReporterDashboards::Import::Survey' do
    survey = RedmineReporterDashboards::Import::Survey

    before(:context) do
      RrdSurveyFixture.create!
      RrdSurveyFixture.seed!
    end

    after(:context) { RrdSurveyFixture.drop! }

    # Each example re-establishes the fixture, because two of them deliberately drop a
    # column or a table. Cheap (six rows) and it removes the ordering question
    # entirely — §6 forbids depending on which example ran first.
    before do
      RrdSurveyFixture.create!
      RrdSurveyFixture.seed!
    end

    subject(:result) { survey.run }

    # ----------------------------------------------------------------
    # INV-6 — writes nothing. The claim the whole task rests on.
    # ----------------------------------------------------------------

    describe 'read-only' do
      it 'issues nothing but SELECT' do
        statements = RrdAdapterHarness.count_queries { survey.run }

        expect(statements).not_to be_empty
        offenders = statements.reject { |sql| sql.match?(/\A\s*(?:SELECT|SHOW)\b/i) }
        expect(offenders).to eq([]),
                             "import:plan must write nothing (INV-6). Not a SELECT:\n#{offenders.join("\n")}"
      end

      it 'leaves every row untouched' do
        before_rows = ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM report_templates')

        survey.run

        after_rows = ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM report_templates')
        expect(after_rows).to eq(before_rows)
      end
    end

    # ----------------------------------------------------------------
    # R-15's three answerable queries
    # ----------------------------------------------------------------

    it 'counts templates by type (R-15 query 1)' do
      expect(result.template_counts).to eq(
        'IssueListReportTemplate' => 1, 'IssueReportTemplate' => 1, 'TimeEntriesReportTemplate' => 1
      )
    end

    it 'counts schedules, splits enabled from stored, and groups by period (R-15 query 2)' do
      expect(result.schedules['total']).to eq(3)
      expect(result.schedules['enabled']).to eq(2)
      expect(result.schedules['enabled_column']).to eq('enabled')
      expect(result.schedules['by_period']).to eq('daily' => 1, 'weekly' => 2)
    end

    it 'counts recipient rows and distinct recipients' do
      expect(result.recipients['rows']).to eq(3)
      expect(result.recipients['distinct_users']).to eq(2)
    end

    it 'reports that a recipient row cannot be addressed, because the table has no key' do
      expect(result.recipients['addressable']).to be(false)
      expect(result.notes.join("\n")).to match(/no id column/)
    end

    it 'sweeps accessor usage across every template body (R-15 query 3)' do
      usage = result.usage
      gem_only = usage.keys.find { |key| key.include?('paid-plugin') }
      own      = usage.keys.find { |key| key.include?('own surface') }

      expect(usage[gem_only]).to eq('story_points' => 1)
      expect(usage[own]).to include('{% sql_aggregate %}' => 1, 'issue.target_version' => 1)
    end

    it 'inventories the Chart.js instances and their types' do
      expect(result.chart_types).to eq([['horizontalBar', 1]])
    end

    it 'always reports the fourth R-15 query as unanswerable, with the command' do
      note = result.notes.find { |line| line.include?('query 4') }

      expect(note).not_to be_nil
      expect(note).to include(survey::LOG_GREP_COMMAND)
    end

    # ----------------------------------------------------------------
    # Which templates need rework
    # ----------------------------------------------------------------

    it 'names only the templates with a blocking finding' do
      rework = result.templates_needing_rework

      expect(rework.map(&:type)).to eq(['IssueListReportTemplate'])
      expect(rework.first.analysis.errors.map(&:rule)).to include(
        'chartjs2.scales_axes', 'chartjs2.horizontal_bar', 'handshake.window_status',
        'footer.engine_page_token', 'script.unfiltered_interpolation'
      )
    end

    it 'gives every finding a line number inside the stored body' do
      finding = result.templates_needing_rework.first.analysis.findings.first

      expect(finding.line).to be_a(Integer)
      expect(finding.line).to be >= 1
    end

    it 'reads every template in id order, so two runs report the same thing' do
      expect(result.templates.map(&:id)).to eq(survey.run.templates.map(&:id))
      expect(result.templates.map(&:id)).to eq(result.templates.map(&:id).sort)
    end

    # ----------------------------------------------------------------
    # The schemas it was not built for
    # ----------------------------------------------------------------

    context 'when reporter was never installed' do
      before { RrdSurveyFixture.drop! }

      it 'reports every table absent instead of raising' do
        expect(result.tables.map(&:present?)).to eq([false, false, false])
        expect(result.reporter_installed?).to be(false)
      end

      it 'still reports the query it could not answer' do
        expect(result.notes.join).to include('query 4')
      end

      it 'returns empty counts rather than nil' do
        expect(result.template_counts).to eq({})
        expect(result.templates).to eq([])
        expect(result.usage).to eq({})
      end
    end

    context 'when the templates table has no content column' do
      before { ActiveRecord::Base.connection.remove_column(:report_templates, :content) }

      it 'says nothing was linted, rather than reporting a clean sweep' do
        expect(result.templates).to eq([])
        expect(result.notes.join("\n")).to match(/no content column.*Nothing was linted/m)
      end

      it 'still answers the count-by-type query, which does not need content' do
        expect(result.template_counts.values.sum).to eq(3)
      end

      it 'lists the column as missing on the table' do
        state = result.tables.find { |table| table.name == survey::TEMPLATES }

        expect(state.missing_columns).to eq(['content'])
      end
    end

    context 'when the schedules table has no enabled flag' do
      before { ActiveRecord::Base.connection.remove_column(:report_schedules, :enabled) }

      it 'reports the total and says the active split is unknown' do
        expect(result.schedules['total']).to eq(3)
        expect(result.schedules).not_to have_key('enabled')
        expect(result.notes.join("\n")).to match(/"active" could not be distinguished/)
      end
    end

    # ----------------------------------------------------------------
    # The bound — at the limit and one past it
    # ----------------------------------------------------------------

    describe 'the template bound' do
      it 'is a number large enough for any real installation' do
        expect(survey::MAX_TEMPLATES).to be >= 1_000
      end

      it 'surveys every template when the count is exactly AT the limit' do
        stub_const("#{survey}::MAX_TEMPLATES", 3)

        expect(result.truncated).to be(false)
        expect(result.templates.length).to eq(3)
      end

      it 'truncates one PAST the limit and says the counts are a lower bound' do
        stub_const("#{survey}::MAX_TEMPLATES", 2)

        expect(result.truncated).to be(true)
        expect(result.templates.length).to eq(2)
        expect(result.notes.join("\n")).to match(/only the first 2 by id.*lower bound/m)
      end
    end
  end
end
