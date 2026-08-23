# frozen_string_literal: true

module ReporterDashboards
  # T-23 — the small amount of presentation logic the template views share.
  #
  # Everything here exists because the alternative is the same three lines in two views,
  # which is how a label diverges between the page that creates a thing and the page that
  # shows it.
  module TemplatesHelper
    # CORE'S OWN THREE LABELS, and finding S-4 in one method.
    #
    # The specs called the third value "project"; Redmine calls it PUBLIC and labels it
    # *"to any users"* (`config/locales/en.yml:1076`). The stated goal was *"an
    # administrator meets one concept rather than two"*, and that is only met by using
    # core's words — which are already translated into every locale Redmine ships, so this
    # plugin adds no key and can never drift from the saved-query form an administrator
    # already knows.
    def reporter_template_visibility_options
      [[l(:label_visibility_private), RedmineReporterDashboards::Template::VISIBILITY_PRIVATE],
       [l(:label_visibility_roles), RedmineReporterDashboards::Template::VISIBILITY_ROLES],
       [l(:label_visibility_public), RedmineReporterDashboards::Template::VISIBILITY_PUBLIC]]
    end

    def reporter_template_visibility_label(template)
      case template.visibility
      when RedmineReporterDashboards::Template::VISIBILITY_ROLES then l(:label_visibility_roles)
      when RedmineReporterDashboards::Template::VISIBILITY_PUBLIC then l(:label_visibility_public)
      else l(:label_visibility_private)
      end
    end

    # `Role.givable` is what the saved-query form offers, so the two forms cannot come to
    # disagree about which roles are selectable.
    def reporter_template_role_options
      Role.givable.sorted
    end

    def reporter_template_output_options
      RedmineReporterDashboards::Template::OUTPUTS.map do |output|
        [l(:"label_reporter_template_output_#{output}"), output]
      end
    end

    # T-31 — THE COPY FOLLOWS THE SOURCE. An independent review measured an hours report
    # telling its reader *"This template produces one document per issue"* and, on the empty
    # state a `:none` actor lands on, *"This report covers no issues … Widen the issue
    # selection"*. Both are wrong on a time-entry template, and the empty state is exactly
    # where a confused reader ends up.
    #
    # AN EXPLICIT MAP RATHER THAN A DERIVED NAME. The first version suffixed the base key
    # with the source and produced `…_no_issues_time_entries`, which is both ugly and a key
    # that did not exist — a derived name fails by reaching for a translation nobody wrote,
    # where a map falls back to the base string, which is at worst imprecise rather than
    # missing. A source with no entry keeps the issue wording deliberately.
    SOURCE_COPY = {
      text_reporter_template_per_record_html: {
        'time_entries' => :text_reporter_template_per_record_html_time_entries
      },
      text_reporter_template_no_issues: {
        'time_entries' => :text_reporter_template_no_time_entries
      }
    }.freeze

    def reporter_source_key(base, source)
      SOURCE_COPY.dig(base, source.to_s) || base
    end

    # T-31. One picker for both sources, from the model's own closed list.
    def reporter_template_source_options
      RedmineReporterDashboards::Template::SOURCES.map do |source|
        [l(:"label_reporter_template_source_#{source}"), source]
      end
    end

    # §Findings **S-14** — the narrowing is VISIBLE, never silent.
    #
    # `TimeEntry.visible` branches on `Role#time_entries_visibility`, so an actor whose role
    # says `own` gets their own hours and nothing else. The report is correct; what would be
    # wrong is letting them read a smaller, entirely believable project total without
    # knowing it is their own timesheet. Same shape as §9b.2's "Preview of 50 of 1 284
    # issues": the bound is stated rather than applied quietly.
    #
    # Answers nil for an issue template and for an actor who sees everything, so a view can
    # render it unconditionally.
    def reporter_time_entry_visibility_notice(template, user, project)
      return nil unless template.respond_to?(:source) && template.source.to_s == 'time_entries'

      case RedmineReporterDashboards::Reporting::TimeEntryVisibility.state(user, project)
      when :own then l(:text_reporter_time_entries_own_only)
      when :none then l(:text_reporter_time_entries_not_visible)
      end
    end

    def reporter_template_orientation_options
      RedmineReporterDashboards::Template::ORIENTATIONS.map do |orientation|
        [l(:"label_reporter_template_orientation_#{orientation}"), orientation]
      end
    end

    # THE HEADLINE IS TRANSLATED AND THE MESSAGE IS NOT, and the split is the point.
    #
    # A diagnostic's `message` is written where the failure happened — in `BatchGuard`, in
    # `TemplateRenderer`, in an engine adapter — and it carries the numbers that make it
    # actionable ("this export asks for 84 documents and the limit is 50"). Those layers
    # have no I18n and must not grow one: `layer_purity.sh` keeps Rails out of `render/`
    # on purpose. So the sentence a reader sees FIRST is a locale key chosen by `origin`,
    # and the precise message sits under it as the technical line — the same shape as the
    # preflight page, where the check titles are keys and the details are not.
    # A `case` WITH AN `else` IS NOT A CLOSED SET, and this one used to be: three `when`
    # arms and an `else` meaning "engine", so F-16's `:assets` origin — where no engine is
    # ever started — would have been headlined *"the PDF engine failed"*, sending the
    # reader to check a binary that had nothing to do with it. The same shape T-25's review
    # found reporting success while mailing the wrong person's data.
    #
    # `fetch` against `Diagnostic`'s own map, which is the set the constructor validates
    # against, so an origin that reaches here always has a label and an origin that does
    # not cannot be constructed.
    def reporter_diagnostic_headline(diagnostic)
      l(::RedmineReporterDashboards::Reporting::Diagnostic::ORIGIN_LABEL_KEYS
          .fetch(diagnostic.origin))
    end

    # THE SENTENCES NOW LIVE IN `RedmineReporterDashboards::DegradationText`, and these
    # four methods are delegations rather than copies.
    #
    # They moved for the reason `ReportFrame`'s constants moved in the same task:
    # `include_all_helpers = false`, so a my-page widget cannot reach this helper at all,
    # and T-26a increment 3 needs the same sentences there. One copy used by three surfaces
    # cannot drift; two copies can. The argument for every line of them — the two
    # vocabularies (`code` vs `capability`, §Findings E-25), why the raw `to_s` fallback is
    # load-bearing rather than decoration, and which codes S-17 still owes — is in that
    # module, next to the code it explains.
    def reporter_degradation_text(degradation)
      ::RedmineReporterDashboards::DegradationText.for(degradation)
    end

    def reporter_degradation_sentence(degradation)
      ::RedmineReporterDashboards::DegradationText.sentence(degradation)
    end

    def reporter_degradation_code(degradation)
      ::RedmineReporterDashboards::DegradationText.code_of(degradation)
    end

    def reporter_degradation_data(degradation)
      ::RedmineReporterDashboards::DegradationText.data_of(degradation)
    end

    def reporter_degradation_count(degradation)
      ::RedmineReporterDashboards::DegradationText.count_of(degradation)
    end

    # THE OPAQUE-ORIGIN SANDBOX — INV-9's third mechanism.
    #
    # A template is written by somebody holding an authoring permission, which is a
    # code-execution privilege held by an ordinary project member. The permission label is
    # NOT the boundary, because the alternative is: a member writes
    # `<script>fetch('/users/1/memberships', …)</script>`, makes the template public, and
    # every viewer who opens it — an administrator included, whose flag bypasses every
    # permission check — runs it same-origin with their own session.
    #
    # So the body never becomes markup in the viewer's document. It goes into a `srcdoc`
    # ATTRIBUTE, which Rails escapes on the way in, and the browser parses it as a separate
    # document inside a frame carrying `sandbox="allow-scripts"` WITHOUT
    # `allow-same-origin`: no cookies, no `localStorage`, no parent DOM, and its own `fetch`
    # carries no credentials for this site.
    #
    # Escaping the body into an attribute is not a workaround for "no `html_safe` anywhere"
    # — it is the invariant: the parent document never contains author-controlled markup.
    #
    # THE POLICY IS SPLIT BETWEEN TWO CARRIERS, and it has to be:
    #
    #   the `sandbox` ATTRIBUTE  the sandbox itself. CSP's `sandbox` DIRECTIVE is
    #                            header-only and is ignored in a `<meta>`, so putting it
    #                            there would be a policy that does not exist.
    #   the `<meta>` CSP         every other directive, which `<meta http-equiv>` does
    #                            honour: no network, images only from `data:`, inline styles
    #                            and inline scripts.
    #
    # `img-src data:` IS ONLY SURVIVABLE BECAUSE SOMETHING INLINES THE IMAGES.
    # `ReportRun#html_only` resolves every section through `Assets::Resolver` with
    # `HTML_CAPABILITIES` — `[:asset_inline]`, chosen to match this line — before the body
    # reaches the view. Narrow this directive and that is the code to change with it.
    #
    # There is no content ENDPOINT to carry the policy as a header: a preview renders
    # content that exists only in the request body and has no URL. One mechanism has to
    # serve both a saved report and an unsaved preview.
    #
    # The tokens and the document live in `ReportFrame`; these two constants are
    # delegations rather than copies, because that module is also reachable from a my-page
    # widget where `include_all_helpers = false` makes this helper invisible. One copy used
    # twice cannot drift.
    CONTENT_SECURITY_POLICY = ::RedmineReporterDashboards::ReportFrame::CONTENT_SECURITY_POLICY
    SANDBOX = ::RedmineReporterDashboards::ReportFrame::SANDBOX

    # `css_class:` is forwarded rather than fixed here because the two surfaces differ:
    # a preview owns the page and draws its own native `box`, a dashboard widget is one
    # box among several and is already inside one. Both spellings are constants on
    # `ReportFrame` (T-38) rather than literals here, so the two surfaces cannot drift.
    # The security tokens stay in `ReportFrame` where a caller cannot reach them — this
    # argument only ever reaches the `class` attribute.
    def reporter_report_frame(section,
                              css_class: ::RedmineReporterDashboards::ReportFrame::PAGE_CHROME)
      ::RedmineReporterDashboards::ReportFrame.frame(
        section.body, title: l(:label_reporter_report_frame), css_class: css_class
      )
    end

    def reporter_sandboxed_document(body)
      ::RedmineReporterDashboards::ReportFrame.document(body)
    end

    # §9b.2: "preview of 50 of 1 284" — never silently truncated.
    def reporter_preview_bound_notice(outcome)
      l(:text_reporter_preview_bounded,
        shown: number_with_delimiter(outcome.shown_count),
        total: number_with_delimiter(outcome.total_count))
    end

    # ------------------------------------------------------------------ T-37, the panel

    # A BOUND ON THE PANEL, and it is not the same number as the rake task's.
    #
    # One bad paste produces hundreds of findings, and a page that renders all of them is
    # a page an author cannot use to fix the first one. The count above the table stays
    # COMPLETE — the truncation is stated, never a quietly shorter list (INV-4's spirit,
    # and the same rule the preview's "N of M" follows one panel up).
    #
    # It is deliberately larger than `LintReport::MAX_FINDINGS_PER_TEMPLATE` (25): that
    # one is a terminal, where a reader scrolls back through other templates' findings
    # too, and this one is a single template in a browser with a scrollbar.
    PANEL_MAX_FINDINGS = 100

    def reporter_lint_findings(analysis)
      analysis.findings.first(PANEL_MAX_FINDINGS)
    end

    def reporter_lint_undisplayed(analysis)
      [analysis.findings.length - PANEL_MAX_FINDINGS, 0].max
    end

    # THE SUMMARY COUNTS MATCHES, NOT ROWS. `collapse` keeps one finding per (rule, line)
    # with a `count`, so a line carrying six `fontSize:` is one row and six problems; a
    # summary that said "1 warning" would understate the work by the exact factor the
    # collapsing saved.
    def reporter_lint_summary(analysis)
      l(:text_reporter_template_lint_summary,
        errors: analysis.errors.sum(&:count),
        warnings: analysis.warnings.sum(&:count))
    end

    def reporter_lint_severity_label(finding)
      finding.error? ? l(:label_reporter_lint_error) : l(:label_reporter_lint_warning)
    end

    # Redmine's own two states rather than a plugin-local pair of colours — §9b's "look
    # native, not branded", and `chrome_no_design_tokens.sh` (T-38) would refuse a colour
    # here anyway.
    def reporter_lint_severity_class(finding)
      finding.error? ? 'error' : 'warning'
    end

  end
end
