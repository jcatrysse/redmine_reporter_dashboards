# frozen_string_literal: true

module RedmineReporterDashboards
  module Import
    # Turns a Survey::Result into the lines `rake reporter_dashboards:migrate_from_reporter:plan`
    # prints. Separate from the survey for one reason: a formatter that returns an
    # Array of String can be asserted on, and a rake task that puts straight to stdout
    # cannot. The rake file stays four lines long and there is no logic in it.
    #
    # The section order is the order an operator needs the answers in:
    #
    #   1. WHAT IS THERE      — if reporter's tables are absent, nothing else matters
    #   2. TEMPLATES BY TYPE  — R-15 query 1, the blast radius by count
    #   3. SCHEDULES          — R-15 query 2, the blast radius that mails people
    #   4. USAGE              — R-15 query 3, the evidence for what the owned drop
    #                           layer must build and what it may drop
    #   5. REWORK             — which templates break, with line numbers
    #   6. NOT ANSWERED HERE  — R-15 query 4 and every column the survey could not find
    #
    # Section 6 is last and is never omitted. A report that listed only what it found
    # would read as completeness; the whole value of a survey is knowing where its
    # own edges are.
    module PlanReport
      RULE = ('-' * 78).freeze

      # Findings are per template and a template can have many. Printing all of them
      # for 5 000 templates is not a report, it is a log — so the detail is bounded and
      # the truncation is stated.
      MAX_TEMPLATES_DETAILED = 50
      MAX_FINDINGS_PER_TEMPLATE = 10

      # Rule messages are one to three sentences, and an operator reads this in an
      # 80-column terminal. Wrapped here rather than shortened in the rule table: the
      # message has to be complete enough to act on, and the place that knows how wide
      # the output is is the formatter.
      WRAP_WIDTH = 74
      MESSAGE_INDENT = ' ' * 14

      class << self
        def render(result)
          lines = []
          lines.concat(heading('reporter_dashboards:migrate_from_reporter:plan — read-only survey'))
          lines << 'Nothing was written. This task only reads.'
          lines.concat(tables_section(result))
          # Section 6 is appended on BOTH paths. An "absent" report that dropped the
          # unanswered-questions section would be the one place this tool could imply
          # completeness it does not have — and it is the path an operator hits first,
          # on a machine that is not the one holding the data.
          return lines.concat(absent_section).concat(notes_section(result)) unless result.reporter_installed?

          lines.concat(templates_section(result))
          lines.concat(schedules_section(result))
          lines.concat(usage_section(result))
          lines.concat(rework_section(result))
          lines.concat(notes_section(result))
          lines
        end

        # ----------------------------------------------------------------

        def heading(title)
          ['', RULE, title, RULE]
        end

        def tables_section(result)
          lines = heading("1. reporter's tables")
          result.tables.each do |table|
            state = table.present? ? 'present' : 'ABSENT'
            lines << format('  %-24s %s', table.name, state)
            table.missing_columns.each do |column|
              lines << format('  %-24s   (no %s column)', '', column)
            end
          end
          lines
        end

        def absent_section
          [
            '',
            'None of the tables above exists in this database, so there is nothing to',
            'survey here. That is the expected result on an installation that never had',
            'redmine_reporter — it is not an error, and it is not evidence that the',
            'production installation has nothing either. Run this task against the',
            'database that actually holds the templates.',
            '',
            'Sections 2 to 5 are omitted for that reason — the numbering below stays',
            'fixed so a section number always means the same thing.'
          ]
        end

        def templates_section(result)
          lines = heading('2. templates by type  (R-15 query 1)')
          if result.template_counts.empty?
            lines << '  no templates, or no type column to group by'
          else
            result.template_counts.each { |type, count| lines << format('  %-34s %6d', type, count) }
            lines << format('  %-34s %6d', 'TOTAL', result.template_counts.values.sum)
          end
          lines << "  surveyed in detail: #{result.templates.length}"
          lines
        end

        def schedules_section(result)
          lines = heading('3. schedules and recipients  (R-15 query 2)')
          schedules = result.schedules

          if schedules['present']
            lines << format('  %-34s %6d', 'schedules stored', schedules['total'])
            if schedules.key?('enabled')
              lines << format('  %-34s %6d', "enabled (#{schedules['enabled_column']} = true)",
                              schedules['enabled'])
            end
            (schedules['by_period'] || {}).each do |period, count|
              lines << format('    %-32s %6d', period.empty? ? '(blank)' : period, count)
            end
          else
            lines << '  report_schedules is absent'
          end

          recipients = result.recipients
          if recipients['present']
            lines << format('  %-34s %6d', 'recipient rows', recipients['rows'])
            if recipients.key?('distinct_users')
              lines << format('  %-34s %6d', 'distinct recipients', recipients['distinct_users'])
            end
            lines << format('  %-34s %s', 'recipient rows addressable',
                            recipients['addressable'] ? 'yes' : 'NO — the table has no primary key')
          else
            lines << '  report_schedules_users is absent'
          end
          lines
        end

        def usage_section(result)
          lines = heading('4. what the templates actually use  (R-15 query 3)')
          usage = result.usage

          if usage.empty?
            lines << '  no tracked accessor, filter or tag appears in any template body.'
            lines << '  For the gem-only groups that is the answer the keep/drop decision needs:'
            lines << '  nothing here depends on them.'
          else
            usage.each do |group, markers|
              lines << ''
              lines << "  #{group}"
              markers.sort_by { |label, count| [-count, label] }.each do |label, count|
                lines << format('    %-46s %6d', label, count)
              end
            end
          end

          charts = result.chart_types
          lines << ''
          if charts.empty?
            lines << '  Chart.js instances: none'
          else
            lines << "  Chart.js instances: #{charts.sum { |_type, count| count }}, by type:"
            charts.each { |type, count| lines << format('    %-46s %6d', type, count) }
          end
          lines
        end

        def rework_section(result)
          rework = result.templates_needing_rework
          lines  = heading('5. templates needing rework')
          lines << format('  %d of %d template(s) have at least one blocking finding.',
                          rework.length, result.templates.length)

          if rework.empty?
            lines << '  Nothing here blocks the render-path change.'
            return lines
          end

          rework.first(MAX_TEMPLATES_DETAILED).each { |template| lines.concat(template_detail(template)) }
          if rework.length > MAX_TEMPLATES_DETAILED
            lines << ''
            lines << "  … and #{rework.length - MAX_TEMPLATES_DETAILED} more, not detailed here. " \
                     'The count above is complete; the detail is not.'
          end
          lines
        end

        def template_detail(template)
          findings = template.analysis.findings
          lines = ['', "  #{template.label}  [#{template.type}]  #{template.analysis.lines} lines"]

          findings.first(MAX_FINDINGS_PER_TEMPLATE).each do |finding|
            marker = finding.error? ? 'ERROR  ' : 'warning'
            times  = finding.count > 1 ? " (x#{finding.count} on this line)" : ''
            # `Finding#position` rather than `finding.line` — T-37 gave a finding a
            # column and this report is one of the three surfaces that must read it the
            # same way the editor's panel does.
            lines << format('    %s line %-9s %s%s', marker, finding.position, finding.rule, times)
            wrap(finding.message).each { |line| lines << "#{MESSAGE_INDENT}#{line}" }
            lines << "#{MESSAGE_INDENT}> #{finding.excerpt}" unless finding.excerpt.empty?
          end
          if findings.length > MAX_FINDINGS_PER_TEMPLATE
            lines << format('    … and %d more finding(s) in this template',
                            findings.length - MAX_FINDINGS_PER_TEMPLATE)
          end
          lines
        end

        # Greedy word wrap. A word longer than the width is left on its own line
        # rather than broken: the long words here are rule ids and code fragments, and
        # a broken identifier is not searchable.
        def wrap(text, width = WRAP_WIDTH)
          text.to_s.split(/\s+/).reject(&:empty?).each_with_object([]) do |word, lines|
            if lines.empty? || (lines.last.length + 1 + word.length) > width
              lines << word
            else
              lines[-1] = "#{lines.last} #{word}"
            end
          end
        end

        def notes_section(result)
          lines = heading('6. what this survey could NOT answer')
          result.notes.each do |note|
            lines << ''
            note.to_s.each_line { |line| lines << "  #{line.chomp}" }
          end
          lines
        end
      end
    end
  end
end
