# frozen_string_literal: true

require_relative '../template_linter'

module RedmineReporterDashboards
  module Import
    # The read-only survey behind `rake reporter_dashboards:import:plan`.
    #
    # `technical-spec.md` §7a: "`import:plan` — **read-only dry run**, reporting counts
    # by type, per-template lint findings, active schedules, and which templates need
    # rework. **This task is also the vehicle for the four R-15 production queries**:
    # shipping them as a repeatable tool rather than a one-off SQL session is the
    # cheapest way to guarantee they actually run."
    #
    # R-15 scores 16 and `04-risks.md` calls running those four queries "the single
    # highest-value action in the dossier". Three of the four are SQL and are here.
    # The fourth is a log grep and cannot be done from a database connection — it is
    # reported as **unanswerable, with the command**, rather than quietly omitted.
    #
    # --- Why raw SQL and not reporter's models ---
    #
    # `ReportTemplate` and `ReportSchedule` belong to the private `redmine_reporter`
    # plugin. Three reasons not to touch them:
    #
    #   1. T-05 made reporter OPTIONAL. Its classes may simply not exist.
    #   2. The migration case is precisely "reporter has been removed but its tables
    #      are still in the database" — the survey has to work there, which a model
    #      cannot.
    #   3. Touching a model risks a callback. This must write NOTHING (INV-6), and
    #      SELECT through a quoted-identifier query is the only way to be sure by
    #      construction rather than by inspection.
    #
    # Every table and column name comes from a frozen constant in this file. Nothing
    # from the database, and nothing from a caller, is ever interpolated into SQL.
    #
    # --- Why it introspects instead of assuming ---
    #
    # Reporter's schema is not in this repository. Rather than hard-code a column list
    # and crash on an installation that differs, the survey asks the connection which
    # of the columns it wants actually exist, uses those, and REPORTS the missing ones.
    # A survey that dies on an unexpected schema tells the operator nothing; one that
    # says "I could not find `enabled`, so I could not count active schedules" tells
    # them exactly what to look at.
    module Survey
      TEMPLATES  = 'report_templates'
      SCHEDULES  = 'report_schedules'
      RECIPIENTS = 'report_schedules_users'

      TABLES = [TEMPLATES, SCHEDULES, RECIPIENTS].freeze

      # Without `type` there is no count by type and without `content` there is
      # nothing to lint, so those two are what the survey needs; the rest improve the
      # report and their absence is reported, not fatal.
      TEMPLATE_REQUIRED_COLUMNS = %w[id type content].freeze
      TEMPLATE_OPTIONAL_COLUMNS = %w[name project_id updated_on created_on].freeze

      # Reporter's own spelling is unknown to this repository, so both plausible names
      # are tried and the one that exists is used. First match wins, in this order.
      SCHEDULE_ENABLED_COLUMNS = %w[enabled active].freeze
      SCHEDULE_PERIOD_COLUMNS  = %w[repeat interval period frequency].freeze

      # A bound, because a survey over an operator's database must not be able to
      # consume unbounded memory reading `content` blobs. 5 000 is ~200x the largest
      # installation anyone has described; past it the survey reports the truncation
      # rather than silently sampling.
      MAX_TEMPLATES = 5_000

      # The R-15 question a database connection cannot answer. Reported with the
      # command, so "we never ran it" cannot be mistaken for "there was nothing".
      LOG_GREP_COMMAND =
        "grep -cE '(/issue_mails|[?&]token=)' log/production.log*"

      Template = Struct.new(:id, :type, :name, :project_id, :bytes, :analysis, keyword_init: true) do
        def label
          parts = ["##{id}"]
          parts << name.to_s unless name.to_s.strip.empty?
          parts.join(' ')
        end
      end

      TableState = Struct.new(:name, :present, :missing_columns, keyword_init: true) do
        def present?
          present
        end
      end

      Result = Struct.new(:tables, :templates, :template_counts, :schedules, :recipients,
                          :truncated, :notes, keyword_init: true) do
        def templates_needing_rework
          templates.select { |template| template.analysis.rework? }
        end

        # Usage summed across every template — the R-15 sweep's actual answer.
        def usage
          templates.each_with_object({}) do |template, out|
            template.analysis.usage.each do |group, markers|
              bucket = (out[group] ||= {})
              markers.each { |label, count| bucket[label] = bucket.fetch(label, 0) + count }
            end
          end
        end

        def chart_types
          templates.flat_map { |template| template.analysis.chart_types }
                   .tally.sort_by { |type, count| [-count, type] }
        end

        def reporter_installed?
          tables.any?(&:present?)
        end
      end

      class << self
        def run(connection: default_connection)
          tables = TABLES.map { |name| table_state(connection, name) }
          notes  = [unanswerable_note]

          templates, truncated = survey_templates(connection, notes)

          Result.new(
            tables: tables,
            templates: templates,
            template_counts: count_by_type(connection),
            schedules: survey_schedules(connection, notes),
            recipients: survey_recipients(connection, notes),
            truncated: truncated,
            notes: notes
          )
        end

        def default_connection
          ActiveRecord::Base.connection
        end

        # ------------------------------------------------------------------

        def table_state(connection, name)
          present = table_exists?(connection, name)
          TableState.new(name: name, present: present,
                         missing_columns: present ? missing_columns(connection, name) : [])
        end

        def missing_columns(connection, name)
          return [] unless name == TEMPLATES

          wanted = TEMPLATE_REQUIRED_COLUMNS + TEMPLATE_OPTIONAL_COLUMNS
          wanted - column_names(connection, name)
        end

        def table_exists?(connection, name)
          connection.table_exists?(name)
        end

        def column_names(connection, name)
          return [] unless table_exists?(connection, name)

          connection.columns(name).map { |column| column.name.to_s }
        end

        # R-15 query 1: SELECT type, count(*) FROM report_templates GROUP BY type.
        def count_by_type(connection)
          return {} unless table_exists?(connection, TEMPLATES)
          return {} unless column_names(connection, TEMPLATES).include?('type')

          rows = select_rows(connection, <<~SQL)
            SELECT #{q(connection, 'type')}, COUNT(*) FROM #{qt(connection, TEMPLATES)}
            GROUP BY #{q(connection, 'type')} ORDER BY #{q(connection, 'type')}
          SQL
          rows.each_with_object({}) { |(type, count), out| out[type.to_s] = count.to_i }
        end

        # R-15 query 3: the `content LIKE` sweep, done as one read of the bodies and a
        # scan in Ruby rather than one LIKE per accessor. Same answer, one query
        # instead of forty, and it gets line numbers and the lint findings for free.
        def survey_templates(connection, notes)
          return [[], false] unless table_exists?(connection, TEMPLATES)

          available = column_names(connection, TEMPLATES)
          missing   = TEMPLATE_REQUIRED_COLUMNS - available
          unless missing.empty?
            notes << "#{TEMPLATES} has no #{missing.join(', ')} column, so no template could be " \
                     'read. Nothing was linted and the usage sweep is empty — this is a missing ' \
                     'answer, not a clean result.'
            return [[], false]
          end

          columns = (TEMPLATE_REQUIRED_COLUMNS + TEMPLATE_OPTIONAL_COLUMNS) & available
          rows    = select_rows(connection, <<~SQL)
            SELECT #{columns.map { |c| q(connection, c) }.join(', ')}
            FROM #{qt(connection, TEMPLATES)}
            ORDER BY #{q(connection, 'id')}
            LIMIT #{MAX_TEMPLATES + 1}
          SQL

          truncated = rows.length > MAX_TEMPLATES
          if truncated
            rows = rows.first(MAX_TEMPLATES)
            notes << "more than #{MAX_TEMPLATES} templates: only the first #{MAX_TEMPLATES} by id " \
                     'were surveyed. Every count below is a lower bound.'
          end

          [rows.map { |row| build_template(columns, row) }, truncated]
        end

        def build_template(columns, row)
          values  = columns.zip(row).to_h
          content = values['content'].to_s

          Template.new(id: values['id'], type: values['type'].to_s, name: values['name'],
                       project_id: values['project_id'], bytes: content.bytesize,
                       analysis: TemplateLinter.analyse(content))
        end

        # R-15 query 2: the active schedule count.
        def survey_schedules(connection, notes)
          unless table_exists?(connection, SCHEDULES)
            notes << "#{SCHEDULES} is not present, so no schedule could be counted."
            return { 'present' => false }
          end

          available = column_names(connection, SCHEDULES)
          out = { 'present' => true, 'total' => count(connection, SCHEDULES) }

          enabled_column = SCHEDULE_ENABLED_COLUMNS.find { |name| available.include?(name) }
          if enabled_column
            out['enabled'] = count(connection, SCHEDULES,
                                   "#{q(connection, enabled_column)} = #{connection.quoted_true}")
            out['enabled_column'] = enabled_column
          else
            notes << "#{SCHEDULES} has none of #{SCHEDULE_ENABLED_COLUMNS.join(', ')}, so " \
                     '"active" could not be distinguished from "stored". The total is still ' \
                     'the blast radius; the split is unknown.'
          end

          period_column = SCHEDULE_PERIOD_COLUMNS.find { |name| available.include?(name) }
          out['by_period'] = group_count(connection, SCHEDULES, period_column) if period_column

          out
        end

        def survey_recipients(connection, notes)
          unless table_exists?(connection, RECIPIENTS)
            notes << "#{RECIPIENTS} is not present, so recipients could not be counted."
            return { 'present' => false }
          end

          available = column_names(connection, RECIPIENTS)
          out = { 'present' => true, 'rows' => count(connection, RECIPIENTS) }

          if available.include?('user_id')
            out['distinct_users'] = select_value(connection, <<~SQL).to_i
              SELECT COUNT(DISTINCT #{q(connection, 'user_id')}) FROM #{qt(connection, RECIPIENTS)}
            SQL
          end

          # technical-spec.md §7: report_schedules_users "is `id: false`, so a join row
          # is unaddressable". Worth confirming against the live schema rather than
          # repeating: it is the reason the replacement table gains an id, and if an
          # installation already has one, that argument is weaker there.
          out['addressable'] = available.include?('id')
          unless out['addressable']
            notes << "#{RECIPIENTS} has no id column, so an individual recipient row cannot be " \
                     'addressed — removing one recipient means rewriting the set. The ' \
                     'replacement table fixes this by having a primary key.'
          end

          out
        end

        # Hard-wrapped rather than left to the terminal: an operator reads this in an
        # 80-column window and a 170-character line wraps mid-word.
        def unanswerable_note
          [
            'R-15 query 4 — how much the ad-hoc mail and public-token paths are actually',
            'used — cannot be answered from a database connection. It lives in the request',
            'log. Run this on the Redmine host:',
            '',
            "    #{LOG_GREP_COMMAND}",
            '',
            'Until it has been run, the keep/drop decision for those two features rests on',
            'inference rather than measurement.'
          ].join("\n")
        end

        # ------------------------------------------------------------------
        # Read-only primitives. Every identifier is quoted and comes from a frozen
        # constant above; `where` is only ever built here, never passed in.
        # ------------------------------------------------------------------

        def count(connection, table, where = nil)
          sql = "SELECT COUNT(*) FROM #{qt(connection, table)}"
          sql = "#{sql} WHERE #{where}" if where
          select_value(connection, sql).to_i
        end

        def group_count(connection, table, column)
          rows = select_rows(connection, <<~SQL)
            SELECT #{q(connection, column)}, COUNT(*) FROM #{qt(connection, table)}
            GROUP BY #{q(connection, column)} ORDER BY #{q(connection, column)}
          SQL
          rows.each_with_object({}) { |(value, n), out| out[value.to_s] = n.to_i }
        end

        def select_rows(connection, sql)
          connection.select_rows(sql, 'RRD import:plan')
        end

        def select_value(connection, sql)
          connection.select_value(sql, 'RRD import:plan')
        end

        def q(connection, name)
          connection.quote_column_name(name)
        end

        def qt(connection, name)
          connection.quote_table_name(name)
        end
      end
    end
  end
end
