# frozen_string_literal: true

module RedmineReporterDashboards
  # The sandboxed frame a rendered report is displayed in — ONE construction site.
  #
  # --- WHY THIS IS A MODULE AND NOT (ONLY) A HELPER ---
  #
  # It used to live entirely in `ReporterDashboards::TemplatesHelper`, which is correct for
  # the template editor and unreachable from anywhere else: Redmine sets
  # `include_all_helpers = false` (`config/application.rb:73`), so a controller sees its
  # OWN helper and nothing more, and `MyController` declares five core helpers and none of
  # ours. A my-page widget therefore cannot call `reporter_report_frame`, and neither can a
  # partial it renders, because a partial runs in the CALLING controller's view context.
  #
  # Two ways out of that. Declaring our helper onto `MyController` is one line and a normal
  # Redmine technique — and it patches a core controller for what is presentation plumbing,
  # with no precedent for such a patch in this plugin. The other is this: move the markup
  # somewhere both surfaces can reach.
  #
  # **The objection to moving it was that the CSP and the body must not be separable, and
  # `templates_helper.rb:289` says so in as many words.** That objection is answered by
  # construction rather than by a comment: this module is the ONLY place that assembles the
  # document or names the sandbox, and `TemplatesHelper` now DELEGATES here. There is one
  # copy used twice, not two copies that can drift — which is the property the original
  # comment was protecting, kept while making it reachable.
  #
  # No `html_safe` anywhere in this file (INV-9, and the `no_html_safe` gate). The frame is
  # built with `content_tag`, whose `srcdoc:` value is escaped as an attribute by Rails, and
  # the document string is deliberately NOT marked safe: it is attribute DATA, not markup
  # the page parses. The frame's own document is parsed by the browser inside an opaque
  # origin under the policy below, which is the whole mechanism.
  module ReportFrame
    # THE OPAQUE-ORIGIN SANDBOX — `technical-spec.md` §4, and INV-9's third mechanism.
    #
    # NO `allow-same-origin`. That one token is the difference between a sandbox and a
    # decoration: with it, template JavaScript reads the viewer's session cookie and calls
    # the API as them. It is written here once, next to the reason.
    SANDBOX = 'allow-scripts'

    # `default-src 'none'` with three deliberate holes: `data:` images so a chart or an
    # inlined asset renders, and inline style/script so a template's own presentation and
    # the chart bootstrap run. No `connect-src`, so nothing in a report can call home.
    #
    # This is delivered as a `<meta>` rather than a response header, which is a deviation
    # from §4's wording and is reported rather than absorbed (CLAUDE.md §11.3): the
    # security property is the one §4 asks for; the delivery differs because one mechanism
    # has to serve both a saved report and an unsaved preview, and a second mechanism for
    # the second case is the "two ways of doing one thing" §6 forbids.
    CONTENT_SECURITY_POLICY =
      "default-src 'none'; img-src data:; style-src 'unsafe-inline'; " \
      "script-src 'unsafe-inline'"

    class << self
      # The frame element. `title:` is supplied by the caller so each surface can name it
      # in its own words while the security tokens stay here.
      def frame(body, title:, css_class: 'reporter-report-frame')
        view.content_tag(:iframe, '',
                         srcdoc: document(body),
                         sandbox: SANDBOX,
                         class: css_class,
                         title: title)
      end

      # The standalone document the frame parses. Assembled here, with the policy, so the
      # two cannot be separated by an edit to one of two files.
      def document(body)
        <<~HTML
          <!DOCTYPE html>
          <html><head><meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="#{CONTENT_SECURITY_POLICY}">
          </head><body>#{body}</body></html>
        HTML
      end

      private

      # `ActionController::Base.helpers` rather than a passed-in view context: the callers
      # are a helper (which has one) and a my-page partial (whose view context cannot see
      # our helper at all), and the element does not depend on the request.
      def view
        ActionController::Base.helpers
      end
    end
  end
end
