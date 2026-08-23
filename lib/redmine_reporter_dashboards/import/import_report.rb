# frozen_string_literal: true

module RedmineReporterDashboards
  module Import
    # T-24 — what `import:run` and `import:status` print.
    #
    # A separate class for the same reason `PlanReport` is one: a rake file that grew a
    # method is a place tests cannot reach, and the thing most worth testing about an
    # importer's output is that it cannot report a clean run when something was skipped.
    #
    # --- IT IS PLAIN TEXT AND DELIBERATELY NOT LOCALISED ---
    #
    # CLAUDE.md §10 forbids a hardcoded user-facing string "in a view, controller or
    # mailer", and this is none of those. It is an operator tool run from a terminal by
    # somebody following an English migration guide, its output is meant to be pasted into
    # an issue, and `PlanReport` set the precedent. A locale key per line here would make
    # the migration instructions untranslatable-in-practice against a translated output.
    module ImportReport
      # The order matters: it is worst-first, so the line an operator has to act on is the
      # one they read before scrolling.
      ORDER = %i[skipped diverged stale source_absent created updated unchanged].freeze

      LABELS = {
        created: 'created',
        updated: 'updated from the source',
        unchanged: 'already up to date',
        diverged: 'EDITED HERE — left alone',
        stale: 'the source has moved',
        source_absent: 'the source is gone',
        skipped: 'SKIPPED — not imported'
      }.freeze

      class << self
        def render(result, heading: 'Import run')
          lines = []
          lines << heading
          lines << ('=' * heading.length)
          lines << ''
          # `dry_run` is what `import:run --dry` sets. `import:status` also writes nothing
          # but is not a dry run of anything, and printing "DRY RUN" over it invited the
          # reader to think a real one would have changed something.
          if result.dry_run && heading.start_with?('Import run')
            lines << 'DRY RUN — nothing was written.'
            lines << ''
          end

          lines.concat(summary_lines(result))
          lines.concat(detail_lines(result))
          lines.concat(widget_lines(result))
          lines.concat(note_lines(result))
          lines.concat(verdict_lines(result))

          lines.join("\n")
        end

        private

        # §Findings S-29 — THE DASHBOARDS. Printed as its own section rather than folded
        # into the counts above, because a reader scanning for "did my templates come
        # across" and a reader asking "are my widgets still pointing at the right report"
        # are asking different questions, and the second one had no answer at all.
        #
        # Every `:unknown` is listed individually and none is summarised away: it is the
        # only line in this report that names a widget somebody has to go and re-pick by
        # hand, and a count would tell them how many without telling them which.
        def widget_lines(result)
          changes = result.widget_changes
          return [] if changes.empty?

          rewritten = changes.count { |change| change.status == :rewritten }
          unknown = changes.select { |change| change.status == :unknown }

          lines = ['Dashboard report widgets']
          lines << format('  %-28s %d', 'repointed at the copy', rewritten)
          lines << format('  %-28s %d', 'COULD NOT BE MAPPED', unknown.length) if unknown.any?
          lines << ''
          unknown.each do |change|
            lines << "  project #{change.project_id} tab #{change.tab_id} " \
                     "widget #{change.block}: stored template #{change.from} was not " \
                     'imported, so it was left alone — re-pick it in the widget settings'
          end
          lines << '' if unknown.any?
          lines
        end

        def summary_lines(result)
          if result.outcomes.empty?
            # ONE SENTENCE, NOT TWO THAT DISAGREE. Over zero rows the old code printed
            # "No template was found to import." and then the verdict added "Every template
            # is imported and matches its source."
            return ['Nothing to report: no template has been imported yet.', '']
          end

          lines = ['Summary']
          ORDER.each do |status|
            count = result.count(status)
            next if count.zero?

            lines << format('  %-28s %d', LABELS.fetch(status, status.to_s), count)
          end
          lines << ''
          lines
        end

        # ONLY THE OUTCOMES THAT NEED ACTING ON ARE LISTED ROW BY ROW.
        #
        # A migration can be thousands of templates and `unchanged` is the common case, so
        # printing every one buries the four lines that matter. The counts above are the
        # complete picture; this is the part somebody has to do something about.
        def detail_lines(result)
          actionable = result.outcomes.select do |outcome|
            %i[skipped diverged stale source_absent].include?(outcome.status)
          end
          return [] if actionable.empty?

          lines = ['Needs attention']
          actionable.each do |outcome|
            lines << format('  [%s] source #%s %s', LABELS.fetch(outcome.status),
                            outcome.source_id, outcome.name)
            lines << "      #{outcome.reason}" if outcome.reason.present?
          end
          lines << ''
          lines
        end

        def note_lines(result)
          return [] if result.notes.empty?

          lines = ['Notes']
          result.notes.each { |note| lines << "  - #{note}" }
          lines << ''
          lines
        end

        # THE LAST LINE IS NEVER A BARE "OK" WHEN SOMETHING WAS SKIPPED.
        #
        # Same rule as T-14's preflight headline and for the same reason: an operator reads
        # the bottom of the output and a summary that says "done" over a skipped template is
        # the small lie this project keeps deleting. `import:run` exits 1 on the same
        # condition, so a script sees it too.
        def verdict_lines(result)
          return [] if result.outcomes.empty?

          if result.count(:skipped).positive?
            ["#{result.count(:skipped)} template(s) were NOT imported. See above; the task " \
             'exits 1.']
          elsif result.count(:diverged).positive? || result.count(:stale).positive?
            ['Every template has a copy here. Some have drifted from their source — that is ' \
             'expected after editing, and nothing was overwritten.']
          else
            ['Every template is imported and matches its source.']
          end
        end
      end
    end
  end
end
