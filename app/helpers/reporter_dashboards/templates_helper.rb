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

    # ONE DEGRADATION, AS A SENTENCE A READER CAN ACT ON — and, where a key exists, in their
    # own language.
    #
    # --- WHAT THIS FIXES, AND WHAT IT DELIBERATELY DOES NOT ---
    #
    # `Degradation#to_s` answers `aggregation_dimension_unknown: group_by: "activty" is not a
    # time-entry dimension (2x)` — a symbol and an English sentence built in `lib/`, printed
    # verbatim. An independent review of T-31 called that correctly: CLAUDE.md §10's letter is
    # kept, because `to_s` is not a literal in an ERB, and its purpose is missed.
    #
    # The whole gap is §Findings **S-17** and it spans fifteen codes across four layers,
    # which is its own task. What this closes is the eight `aggregation_*` codes — the ones
    # T-31 introduced or inherited on the same path — through the mechanism S-17's full fix
    # will use: a key per code, the degradation's own `data` as interpolation, and the RAW
    # `to_s` as the fallback. So every other code prints exactly as it did today, and adding
    # a key later is the only change needed to localise it.
    #
    # THE FALLBACK IS NOT DECORATION. `technical-spec.md` §7 rule 5 makes "an install one
    # minor behind reading a newer row" routine, and a code from a newer version of this
    # plugin — or a typo in a key — must still print something the reader can quote into a
    # bug report rather than nothing at all. `default: ''` and `rescue` are what guarantee
    # that; a missing interpolation argument is the realistic failure and it is caught.
    # TWO VOCABULARIES REACH THIS LIST, AND ONLY ONE OF THEM ANSWERED `#code`.
    #
    # `Outcome#degradations` is `diagnostics.degradations + batch.successes.flat_map(...)`
    # — a `Liquid::Diagnostics::Degradation` (`code`/`detail`/`data`/`count`) next to a
    # `Render::Degradation` (`capability`/`detail`), and the two classes are deliberately
    # separate: `diagnostics.rb` argues at length that "the collection was truncated" and
    # "the browser could not fetch a font" are fixed by different people.
    #
    # This method read `#code`, `#data` and `#count` off both. `Render::Degradation` has
    # none of the three, and `reporter_degradation_sentence`'s rescue lists
    # `MissingInterpolationArgument` and `ArgumentError`, so the `NoMethodError` escaped:
    # **every wkhtmltopdf render 500'd this page**, because that adapter stamps
    # `Degradation(:legacy_engine)` into every `Success` by design — which the partial's
    # own comment says it renders. Measured, not read: `Render::Degradation.new(...)
    # .respond_to?(:code)` is `false`. §Findings **E-25**.
    #
    # The fix is here rather than on `Render::Degradation`, because giving the render type
    # a `code`, a `data` and a `count` it has no use for would merge the two vocabularies
    # the gate and the design keep apart. The view is the one place that must speak both,
    # so it is the one place that normalises them — and F-16's asset degradations, which
    # travel as `Render::Degradation`s, are what made the latent defect reachable a second
    # way.
    def reporter_degradation_text(degradation)
      body = reporter_degradation_sentence(degradation) || degradation.to_s
      count = reporter_degradation_count(degradation)
      return body unless count > 1

      "#{body} (#{count}x)"
    end

    def reporter_degradation_sentence(degradation)
      code = reporter_degradation_code(degradation)
      return nil if code.nil?

      key = :"text_reporter_degradation_#{code}"
      sentence = l(key, default: '', **reporter_degradation_data(degradation))
      sentence.to_s.strip.empty? ? nil : sentence
    rescue ::I18n::MissingInterpolationArgument, ::ArgumentError
      nil
    end

    # `code` on the Liquid side, `capability` on the render side. Both name the same thing
    # — which degradation this is — so both get a `text_reporter_degradation_<name>` key
    # and neither needs one: the raw `to_s` fallback is unchanged for both.
    def reporter_degradation_code(degradation)
      return degradation.code if degradation.respond_to?(:code)
      return degradation.capability if degradation.respond_to?(:capability)

      nil
    end

    # A `Render::Degradation` carries no interpolation data and is not deduplicated, so it
    # is one occurrence with no arguments. Answering that here keeps the two shapes out of
    # `reporter_degradation_text`, where a `respond_to?` per field would read as a puzzle.
    def reporter_degradation_data(degradation)
      return {} unless degradation.respond_to?(:data)

      degradation.data.transform_keys(&:to_sym)
    end

    def reporter_degradation_count(degradation)
      return 1 unless degradation.respond_to?(:count)

      degradation.count
    end

    # THE OPAQUE-ORIGIN SANDBOX — `technical-spec.md` §4, and INV-9's third mechanism.
    #
    # --- WHY A REPORT BODY MAY NOT BE INLINED INTO THE PAGE ---
    #
    # A template is written by somebody holding an `authoring: true` permission, which
    # §4.1 labels a code-execution privilege — and `require: :member` means that is an
    # ordinary project member. §4 is explicit that the permission label is NOT the
    # boundary and lists the sandbox as a separate mechanism, because the alternative is
    # this: a member writes `<script>fetch('/users/1/memberships', …)</script>`, makes the
    # template public, and every viewer who opens it — an administrator included, whose
    # flag bypasses every permission check — runs it same-origin with their own session.
    # Privilege escalation by report.
    #
    # So the body never becomes markup in the viewer's document. It goes into an
    # `srcdoc` ATTRIBUTE, which Rails escapes on the way in, and the browser parses it as
    # a separate document inside a frame carrying `sandbox="allow-scripts"` **without**
    # `allow-same-origin` — which is what §4 means by an opaque origin: the frame has no
    # access to cookies, to `localStorage`, or to the parent DOM, and its own `fetch`
    # carries no credentials for this site.
    #
    # --- WHY THERE IS NO `html_safe` HERE ANY MORE, AND THAT IS THE POINT ---
    #
    # §4: *"No `html_safe` anywhere."* The first version of this helper marked the body
    # safe and dropped it into a `<div>`; the independent review of T-23 refused it
    # against exactly this section. Escaping the body into an attribute is not a
    # workaround for the invariant — it is the invariant: the parent document never
    # contains author-controlled markup at all.
    #
    # --- THE POLICY IS SPLIT BETWEEN TWO CARRIERS, DELIBERATELY ---
    #
    # §4 asks for `Content-Security-Policy: sandbox allow-scripts; default-src 'none';
    # img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'` on "the
    # content endpoint". There is no content endpoint here — a PREVIEW renders content
    # that exists only in the request body and has no URL — so the same policy is
    # delivered by the two carriers that work for a `srcdoc` document:
    #
    #   the `sandbox` ATTRIBUTE   the sandbox itself. CSP's `sandbox` DIRECTIVE is
    #                             header-only and is ignored in a `<meta>`, so putting it
    #                             there and calling it done would be a policy that does
    #                             not exist — the failure mode this repository keeps
    #                             deleting.
    #   the `<meta>` CSP          every other directive, which `<meta http-equiv>` does
    #                             honour: no network of any kind, images only from
    #                             `data:`, inline styles and inline scripts.
    #
    # **`img-src data:` IS ONLY SURVIVABLE BECAUSE SOMETHING INLINES THE IMAGES, and for a
    # long time nothing did.** This comment used to say "(T-33 has already inlined them)".
    # T-33 built the resolver and no producer called it (§Findings ~~F-16~~), so every
    # URL-referenced image in this iframe was blocked by this very directive and drew
    # blank — a cited control with no call site, which is the defect class this project has
    # shipped four times. F-16's first version then wired the PDF path and left this one,
    # so the claim stayed false on the surface an author looks at first. It is true now:
    # `ReportRun#html_only` resolves every section through `Assets::Resolver` with
    # `HTML_CAPABILITIES` — `[:asset_inline]`, chosen to match this line — before the body
    # reaches the view. If you narrow this directive, that is the code to change with it.
    #
    # **This is a deviation from §4's wording and is reported rather than absorbed**
    # (CLAUDE.md §11.3): the security property is the one §4 asks for, the delivery
    # differs because one mechanism has to serve both a saved report and an unsaved
    # preview, and a second mechanism for the second case is the "two ways of doing one
    # thing" §6 forbids. If the curator wants the header, it needs a content endpoint and
    # a way to address unsaved content, which is a task.
    # THE TOKENS AND THE DOCUMENT NOW LIVE IN `RedmineReporterDashboards::ReportFrame`,
    # and these two constants are delegations rather than copies.
    #
    # They moved because `include_all_helpers = false` makes this helper unreachable from a
    # my-page widget, and T-26a needs the same frame on that surface. The comment that used
    # to sit here said the policy and the body must not be separable by an edit to one of
    # two files — which is exactly why the move was a MOVE and not a second copy: that
    # module is now the only place either is assembled, and everything else delegates.
    # One copy used twice cannot drift; two copies can.
    CONTENT_SECURITY_POLICY = ::RedmineReporterDashboards::ReportFrame::CONTENT_SECURITY_POLICY
    SANDBOX = ::RedmineReporterDashboards::ReportFrame::SANDBOX

    def reporter_report_frame(section)
      ::RedmineReporterDashboards::ReportFrame.frame(
        section.body, title: l(:label_reporter_report_frame)
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
  end
end
