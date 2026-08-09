# frozen_string_literal: true

module RedmineReporterDashboards
  module Reporting
    # T-29 — what `import:plan` and `import:run` print.
    #
    # A separate module for the reason `Import::ImportReport` is one, and its comment says
    # it best: "a rake file that grew a method is a place tests cannot reach, and the thing
    # most worth testing about an importer's output is that it cannot report a clean run
    # when something was skipped."
    #
    # --- PLAIN TEXT AND DELIBERATELY NOT LOCALISED, on the same precedent ---
    #
    # CLAUDE.md §10 forbids a hardcoded user-facing string "in a view, controller or
    # mailer". This is none of those: it is an operator tool run from a terminal, its
    # output is meant to be pasted into an issue, and `PlanReport` and `ImportReport` both
    # established the shape. The strings this task DOES put in front of a user in a browser
    # — the archive's refusals and its download button — are locale keys in all nine files.
    module BundleReport
      # WORST FIRST, so the line an operator has to act on is the one they read before
      # scrolling. `ImportReport::ORDER` makes the same choice for the same reason.
      ORDER = %i[failed skip rename update create].freeze

      LABELS = {
        failed: 'FAILED — not imported',
        skip: 'SKIPPED — already here',
        rename: 'imported under a new name',
        update: 'OVERWRITTEN — the previous content is in the version history',
        create: 'imported'
      }.freeze

      class << self
        def render(report, heading: 'Template bundle')
          lines = [heading, '=' * heading.length, '']

          if report.planned
            # SAID ONCE AND SAID FIRST. `plan` writing nothing is the whole reason the two
            # steps exist, and an operator who mistakes a plan for an apply will not
            # re-run it.
            lines << 'PLAN ONLY — nothing was written.'
            lines << ''
          end

          lines.concat(provenance_lines(report))
          lines.concat(summary_lines(report))
          lines.concat(detail_lines(report))
          lines.concat(note_lines(report))
          lines.concat(verdict_lines(report))

          lines.join("\n")
        end

        private

        # WHERE THE FILE CAME FROM. `Bundle::Parsed` keeps the envelope rather than
        # discarding it precisely so this can be printed: an operator deciding whether to
        # apply a bundle wants to know when it was written and by which plugin version,
        # and a reader that dropped those would send them to an editor to find out.
        def provenance_lines(report)
          bundle = report.bundle
          return [] if bundle.nil?

          [
            "format_version: #{bundle.format_version}",
            "exported_at:    #{bundle.exported_at || '(not stated)'}",
            "plugin_version: #{bundle.plugin_version || '(not stated)'}",
            "templates:      #{report.outcomes.length}",
            ''
          ]
        end

        def summary_lines(report)
          counts = report.counts
          present = ORDER.select { |action| counts[action].to_i.positive? }
          return ['nothing in this bundle.', ''] if present.empty?

          present.map { |action| format('%-6d %s', counts[action], LABELS[action]) } + ['']
        end

        def detail_lines(report)
          ordered = report.outcomes.sort_by { |o| [ORDER.index(o.action) || 99, o.name.to_s] }

          ordered.map { |outcome| detail_line(outcome) } + ['']
        end

        def detail_line(outcome)
          line = +"  #{outcome.name}"
          line << " -> #{outcome.applied_name}" if renamed?(outcome)
          line << ": #{LABELS[outcome.action] || outcome.action}"
          line << " (#{outcome.reason})" if outcome.reason
          line << lint_suffix(outcome)
          line
        end

        def renamed?(outcome)
          outcome.applied_name && outcome.applied_name != outcome.name
        end

        # THE LINT COUNTS ARE PRINTED EVEN WHEN THEY ARE ZERO-FOR-ERRORS BUT NOT FOR
        # WARNINGS, and `nil` is a third state rather than zero: `lint_counts` answers nil
        # when the linter itself raised, and printing "0 errors" there would be a claim
        # nobody made. §7b.2 asks the plan to carry "lint findings"; a plan that silently
        # dropped them on the one template that broke the linter would be hiding the
        # template most worth looking at.
        def lint_suffix(outcome)
          if outcome.lint_errors.nil? && outcome.lint_warnings.nil?
            return ' [lint did not run]'
          end

          parts = []
          parts << "#{outcome.lint_errors} lint error(s)" if outcome.lint_errors.to_i.positive?
          parts << "#{outcome.lint_warnings} warning(s)" if outcome.lint_warnings.to_i.positive?
          parts.empty? ? '' : " [#{parts.join(', ')}]"
        end

        def note_lines(report)
          return [] if report.notes.empty?

          ['Notes:'] + report.notes.map { |note| "  * #{note}" } + ['']
        end

        # THE VERDICT IS NOT "OK" WHENEVER NOTHING RAISED. A bundle where every template
        # was skipped is a bundle that imported nothing, and an operator reading a bare
        # "OK" would believe the opposite — the same reason `PreflightCommand` separates
        # `ok?` from `complete?` and never prints a bare OK when a check was skipped.
        def verdict_lines(report)
          return ['FAILED — see the reasons above.'] if report.failed?
          return ['Nothing was imported: every template in this bundle was skipped.'] if
            all_skipped?(report)

          [report.planned ? 'Plan complete.' : 'OK.']
        end

        def all_skipped?(report)
          report.outcomes.any? && report.outcomes.all? { |o| o.action == :skip }
        end
      end
    end
  end
end
