# frozen_string_literal: true

require_relative 'report_document'

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
  # No `html_safe` anywhere in this file (INV-9), and since T-27 that is ENFORCED rather
  # than merely true: `script/gates/no_html_safe.sh` fails on `html_safe` applied to a
  # value anywhere under `app/` or `lib/`, and runs in CI's `gates` job. This comment used
  # to cite that gate while it did not exist, which a review correctly called out as
  # reading like coverage that was not there. The
  # frame is
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

    # `default-src 'none'` with deliberate holes, and no `connect-src`, so nothing in a
    # report can call home.
    #
    # --- `data:` ON SCRIPT AND STYLE, AND THIS POLICY REFUSED ITS OWN ASSET BINDING
    #     WITHOUT IT (T-41, §Findings M-2, MEASURED 2026-09-16) ---
    #
    # `Assets::Resolver` embeds every subresource a report references. It has two ways to
    # do that: RESTRUCTURE the element — `<script src=…>` becomes `<script>…</script>` —
    # or, when it cannot, rewrite the attribute to a `data:` URI. It cannot restructure a
    # file above `inline_max_bytes`, and Mermaid is 3.5 MB, so every `{% mermaid %}`
    # document reached this frame carrying
    # `<script src="data:text/javascript;base64,…">` — which `script-src 'unsafe-inline'`
    # does not permit. The browser refused the plugin's own vendored library and the
    # reader saw the diagram's SOURCE as text, while the same document rendered correctly
    # as a PDF, where no CSP is involved. The srcdoc was 4.7 MB of refused script.
    #
    # So this is not a widening of what a template may do; it is this policy agreeing with
    # the binding that feeds it. The author's privilege is unchanged, and saying why is the
    # point of this paragraph: `'unsafe-inline'` is ALREADY here, because INV-9 makes
    # template authoring a code-execution privilege by design, and the frame is an opaque
    # origin with no `allow-same-origin`, so script that runs here cannot reach the
    # viewer's session whatever URL it arrived under. `data:` adds a second spelling of a
    # capability an author already has — it does not add the capability.
    #
    # `style-src` gets it for the identical reason: a stylesheet above the threshold is
    # rewritten the same way, and a refused stylesheet is a report that silently loses its
    # layout.
    #
    # What is still absent is what matters: no `'self'`, no host, no `connect-src`,
    # no `default-src`. An opaque origin's `'self'` is nothing, and a host source would
    # let a template pull code from anywhere that host serves — which IS a widening, and
    # is not needed, because the binding has already embedded everything the document uses.
    #
    # This is delivered as a `<meta>` rather than a response header, which is a deviation
    # from §4's wording and is reported rather than absorbed (CLAUDE.md §11.3): the
    # security property is the one §4 asks for; the delivery differs because one mechanism
    # has to serve both a saved report and an unsaved preview, and a second mechanism for
    # the second case is the "two ways of doing one thing" §6 forbids.
    CONTENT_SECURITY_POLICY =
      "default-src 'none'; img-src data:; style-src 'unsafe-inline' data:; " \
      "script-src 'unsafe-inline' data:"

    # THE TWO SURFACES, SAID ONCE — T-38.
    #
    # These used to be string literals at three call sites (the helper's default and two
    # widget partials), which is the shape HANDOVER §1 records as "when you find the same
    # regexp in three files, the fourth copy is the bug". Only the HEIGHT differs between
    # them; every security token is on the element and comes from here.
    #
    # --- `box` IS NOT IN EITHER OF THEM, AND THE FIRST VERSION PUT IT IN ONE -------------
    #
    # `chrome_no_design_tokens.sh` took the frame's own `border` and `background` away, so
    # something else has to draw its edge, and Redmine's `box` is the native answer (§9b:
    # "adopts Redmine's own markup, classes and icon set per version" — it has carried a
    # padded, bordered container since 1.x, painted from `--oc-gray-*` on 7.0 and from hex
    # on the older branches). The first version put `box` ON THE IFRAME, and an independent
    # review rejected it with two reasons, both right:
    #
    #   * `templates/preview.html.erb:66` ALREADY wraps the frame in `<div class="box">`, so
    #     the preview became a box inside a box — the exact defect the widget variant exists
    #     to avoid, missed because the reasoning only considered `.mypage-box`.
    #   * `.box` carries `padding: 10px` and a `1px` border, and `.reporter-report-frame` is
    #     `width: 100%` with no `box-sizing` — and Redmine 7.0's stylesheet sets no universal
    #     `border-box`. Content-box arithmetic makes the used width overflow its container by
    #     22px.
    #
    # So `box` goes on a CONTAINER, which is what Redmine puts it on everywhere — never on a
    # replaced element. `templates/show.html.erb` wraps the frame in one; `preview` already
    # did; the widget surfaces are inside `.mypage-box`, which is the same container under
    # another name.
    PAGE_CHROME = 'reporter-report-frame'
    WIDGET_CHROME = 'reporter-report-frame reporter-report-frame--widget'

    class << self
      # The frame element. `title:` is supplied by the caller so each surface can name it
      # in its own words while the security tokens stay here.
      def frame(body, title:, css_class: PAGE_CHROME)
        view.content_tag(:iframe, '',
                         srcdoc: document(body),
                         sandbox: SANDBOX,
                         class: css_class,
                         title: title)
      end

      # The standalone document the frame parses. The POLICY is assembled here, and
      # nowhere else, so the sandbox and the body it constrains cannot be separated by
      # an edit to one of two files.
      #
      # T-38 MOVED THE REST OF THE DOCUMENT to `ReportDocument`, and the property this
      # comment used to protect is unchanged: that module never invents a `head`, it
      # only concatenates the one its caller owns. What it adds is the report
      # stylesheet — which the PDF binding needs identically, and a second assembler
      # is how the HTML view and the PDF stop being the same document (§9b.4).
      #
      # `style-src 'unsafe-inline'` is what makes the inlined stylesheet legal under
      # this policy; a `<link>`ed one would be a fetch `default-src 'none'` denies.
      def document(body)
        ReportDocument.wrap(body, head: csp_meta)
      end

      # The policy, as the element that carries it. One method so the string appears
      # once and the `document` above reads as what it is: a policy plus a body.
      def csp_meta
        %(<meta http-equiv="Content-Security-Policy" ) +
          %(content="#{CONTENT_SECURITY_POLICY}">\n)
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
