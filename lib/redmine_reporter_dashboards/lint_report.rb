# frozen_string_literal: true

require_relative 'template_linter'

module RedmineReporterDashboards
  # T-37 — `rake reporter_dashboards:lint_templates`, as text.
  #
  # `technical-spec.md` §9b.1 names this task in the same breath as the editor's panel:
  # *"a findings panel below the editor fed by the same linter that runs in
  # `rake reporter_dashboards:lint_templates`* — one implementation, two surfaces."* The
  # task did not exist when that was written, so the sentence described a parity that had
  # nothing to be parallel to. It does now, and this file is the CLI half.
  #
  # --- WHAT IS SHARED AND WHAT IS NOT ---
  #
  # SHARED: `TemplateLinter.analyse`, called with a body and nothing else. That is the
  # whole linter — the rules, the scopes, the collapsing, the line and the column — and
  # it is the object T-37's `Accept:` line means by *"the same linter object"*.
  # `test/functional/…_lint_parity_test.rb` runs this file and the editor over one fixture
  # and compares the finding LISTS rather than the rendered text, so the two cannot come
  # to disagree about a finding while agreeing about a paragraph.
  #
  # NOT SHARED: the presentation. This is a terminal, so it is plain ASCII with no I18n —
  # `layer_purity.sh` keeps Rails out of this directory, and a rake task's output is read
  # by an operator over ssh, not by a browser. The editor's panel is a partial with locale
  # keys. Sharing the *rendering* would mean either a translated CLI or an untranslated
  # panel, and both are worse than two presentations of one analysis.
  #
  # --- WHY IT REPORTS OUR TEMPLATES AND `Import::PlanReport` REPORTS THEIRS ---
  #
  # `Import::PlanReport` surveys the BASE PLUGIN's `report_templates` through raw SQL
  # (its id is deliberately not spelled here: `script/gates/zero_reporter.sh` counts every
  # occurrence of it outside an allowlist, and the count has to keep falling — this file
  # tripped it on its first gate run, and a comment is not worth an allowlist entry)
  # for a migration, and answers "which of these need rework before they are copied".
  # This answers "are the templates in this installation clean", over our own model, and
  # is the one an operator runs after the migration is done. Same linter, different
  # subject; neither is a copy of the other.
  module LintReport
    # A template and what the linter said about it. `label` is built by the caller
    # (`#id name`, or a path for a file) so this module never has to know whether its
    # subject came from a table or from disk.
    Entry = Struct.new(:label, :analysis, keyword_init: true) do
      def errors
        analysis.errors
      end

      def rework?
        analysis.rework?
      end
    end

    # A bound, for the same reason `Import::Survey` has one: the detail is per template
    # and an installation with 4 000 templates would otherwise produce a report nobody
    # can read out of a terminal. The COUNTS above it stay complete, and the truncation
    # is stated — never a quietly shorter list.
    MAX_DETAILED = 50

    # Per template, because a single template with 900 findings is one bad paste and
    # should not push every other template off the screen.
    MAX_FINDINGS_PER_TEMPLATE = 25

    WRAP_WIDTH = 76
    MESSAGE_INDENT = '              '

    class << self
      # `bodies` is anything that answers `each` with objects carrying `label` and the
      # body — see `Reader` below. Kept as a separate step from `render` so a caller (a
      # test, a future JSON formatter) can have the data without the paragraphs.
      def analyse(subjects)
        subjects.map do |label, body|
          Entry.new(label: label, analysis: TemplateLinter.analyse(body))
        end
      end

      def render(entries)
        lines = header(entries)
        lines.concat(summary(entries))
        lines.concat(detail(entries))
        lines << ''
        lines
      end

      # THE EXIT CODE IS DECIDED HERE AND NOT IN THE RAKE FILE, so it is testable
      # without a Rake application.
      #
      # ERRORS FAIL, WARNINGS DO NOT. `Analysis#rework?` is already "has at least one
      # error" and is what `import:plan` uses to answer "which templates need rework";
      # an exit code that also fired on warnings would be non-zero on almost every real
      # installation, and a non-zero exit that is always non-zero is one nobody reads
      # (the same argument T-25 records for a draft schedule).
      def failed?(entries)
        entries.any?(&:rework?)
      end

      private

      def header(entries)
        ['',
         '=' * 78,
         'reporter_dashboards — template lint',
         '=' * 78,
         '',
         "  #{entries.length} template(s) examined."]
      end

      def summary(entries)
        errors   = entries.sum { |entry| entry.analysis.errors.sum(&:count) }
        warnings = entries.sum { |entry| entry.analysis.warnings.sum(&:count) }
        rework   = entries.count(&:rework?)

        ['',
         "  #{errors} error(s), #{warnings} warning(s).",
         "  #{rework} template(s) have at least one error.",
         '',
         '  An error is something that will break when the render path changes; a warning',
         '  may be a false positive and says so in its own message.']
      end

      def detail(entries)
        # NOTHING TO LINT IS NOT A CLEAN BILL OF HEALTH. A fresh installation has no
        # templates, and "every template is clean" about zero templates is the kind of
        # true-and-misleading line an operator quotes back later.
        return ['', '  There are no report templates in this installation yet.'] if entries.empty?

        offenders = entries.reject { |entry| entry.analysis.findings.empty? }
        return ['', '  Nothing to report — every template is clean.'] if offenders.empty?

        lines = ['', '-' * 78, 'findings', '-' * 78]
        offenders.first(MAX_DETAILED).each { |entry| lines.concat(entry_detail(entry)) }
        if offenders.length > MAX_DETAILED
          lines << ''
          lines << "  … and #{offenders.length - MAX_DETAILED} more template(s) with findings, " \
                   'not detailed here. The counts above are complete; the detail is not.'
        end
        lines
      end

      def entry_detail(entry)
        findings = entry.analysis.findings
        lines = ['', "  #{entry.label}  #{entry.analysis.lines} lines"]

        findings.first(MAX_FINDINGS_PER_TEMPLATE).each do |finding|
          marker = finding.error? ? 'ERROR  ' : 'warning'
          times  = finding.count > 1 ? " (x#{finding.count} on this line)" : ''
          # `Finding#position` — "line:column", the one spelling the editor's panel also
          # prints. See the method's own comment for why it is not formatted here.
          lines << format('    %s %-9s %s%s', marker, finding.position, finding.rule, times)
          wrap(finding.message).each { |line| lines << "#{MESSAGE_INDENT}#{line}" }
          lines << "#{MESSAGE_INDENT}> #{finding.excerpt}" unless finding.excerpt.empty?
        end
        if findings.length > MAX_FINDINGS_PER_TEMPLATE
          lines << format('    … and %d more finding(s) in this template',
                          findings.length - MAX_FINDINGS_PER_TEMPLATE)
        end
        lines
      end

      # Greedy word wrap, the same one `Import::PlanReport` uses and for the same reason:
      # a word longer than the width is left alone rather than broken, because the long
      # words here are rule ids and code fragments and a broken identifier is not
      # searchable.
      def wrap(text, width = WRAP_WIDTH)
        text.to_s.split(/\s+/).reject(&:empty?).each_with_object([]) do |word, lines|
          if lines.empty? || (lines.last.length + 1 + word.length) > width
            lines << word
          else
            lines[-1] = "#{lines.last} #{word}"
          end
        end
      end
    end
  end
end
