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
    def reporter_diagnostic_headline(diagnostic)
      case diagnostic.origin
      when :template then l(:label_reporter_report_failed_template)
      when :batch then l(:label_reporter_report_refused)
      else l(:label_reporter_report_failed_engine)
      end
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
    #                             `data:` (T-33 has already inlined them), inline styles
    #                             and inline scripts.
    #
    # **This is a deviation from §4's wording and is reported rather than absorbed**
    # (CLAUDE.md §11.3): the security property is the one §4 asks for, the delivery
    # differs because one mechanism has to serve both a saved report and an unsaved
    # preview, and a second mechanism for the second case is the "two ways of doing one
    # thing" §6 forbids. If the curator wants the header, it needs a content endpoint and
    # a way to address unsaved content, which is a task.
    CONTENT_SECURITY_POLICY =
      "default-src 'none'; img-src data:; style-src 'unsafe-inline'; " \
      "script-src 'unsafe-inline'".freeze

    # NO `allow-same-origin`. That one token is the difference between a sandbox and a
    # decoration, so it is written here once, next to the reason.
    SANDBOX = 'allow-scripts'

    def reporter_report_frame(section)
      content_tag(:iframe, '',
                  srcdoc: reporter_sandboxed_document(section.body),
                  sandbox: SANDBOX,
                  class: 'reporter-report-frame',
                  title: l(:label_reporter_report_frame))
    end

    # The standalone document the frame parses. Assembled here rather than in a view so
    # that the policy and the body cannot be separated by an edit to one of two files.
    def reporter_sandboxed_document(body)
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="#{CONTENT_SECURITY_POLICY}">
        </head><body>#{body}</body></html>
      HTML
    end

    # §9b.2: "preview of 50 of 1 284" — never silently truncated.
    def reporter_preview_bound_notice(outcome)
      l(:text_reporter_preview_bounded,
        shown: number_with_delimiter(outcome.shown_count),
        total: number_with_delimiter(outcome.total_count))
    end
  end
end
