# frozen_string_literal: true

module RedmineReporterDashboards
  # Are the base plugin's report-template classes actually USABLE here?
  #
  # This is a different question from `ReporterPresence.present?`, and conflating the
  # two is what left `/my/page` returning 500. Presence is a fact about the plugin
  # REGISTRY; this is a fact about whether a constant can be resolved on this Rails.
  # An install can answer yes to the first and no to the second, and Redmine 7.0 is
  # not a hypothetical instance of it:
  #
  #   Redmine 7.0.0.stable / Rails 8.1.3.1, measured 2026-08-12
  #     enum status: { a: 1 }    -> ArgumentError: wrong number of arguments (given 0, expected 1..2)
  #     enum :status, { a: 1 }   -> accepted
  #
  # The base plugin's `IssueListReportTemplate` is reported to use the first form,
  # removed in Rails 8.0, so on Redmine 7.0 the plugin registers, `installed?` says
  # yes, and every reference to the class raises. That is its defect to fix.
  # Rendering a 500 over it is ours.
  #
  # --- THIS IS A PRE-CHECK, AND A PRE-CHECK IS NOT A SAFETY NET ---
  #
  # The first version of this module was only the pre-check, and an independent review
  # proved `/my/page` still returned 500 — with `usable?` answering TRUE. Resolving the
  # constants says nothing about the three OTHER things the widget needs, all owned by
  # the base plugin: its TABLES (`find_by` on an unmigrated schema), its ROUTE HELPER
  # (`report_content_report_template_path`, which this plugin does not define), and its
  # PARTIAL (`my/report_settings`, which this plugin does not ship). Measured: base
  # plugin installed, constants resolving, tables absent -> 500; partial absent -> 404,
  # and the block VANISHED with its own close button.
  #
  # So callers get both halves. `usable?` decides whether to try, and
  # `log_render_failure` is what the caller's rescue reports with — because the thing a
  # my-page partial cannot do is let anything escape.
  #
  # --- WHY THIS RESCUES, WHEN `ReporterPresence` REFUSES TO ---
  #
  # `reporter_presence.rb` states the rule: absence is a positive question put to the
  # registry, "never a `rescue NameError` around one of the base plugin's constants",
  # because inferring absence from a swallowed error is how the vendor-gem coupling
  # stayed invisible for a release line. That rule is kept here, not broken:
  #
  #   * ABSENCE is still answered by the registry — `present?` is asked FIRST, and if it
  #     says no this module never touches one of those constants at all.
  #   * The rescue only ever runs when the registry has already said the plugin IS
  #     there, so it can only mean "installed but unusable" — a defect, and one that
  #     cannot be established any other way than by trying.
  #   * Nothing is swallowed. The error is logged with its class and message, and the
  #     caller degrades VISIBLY — which is what CLAUDE.md §5 asks for in place of a
  #     silent `rescue nil`.
  #
  # `ScriptError` as well as `StandardError`, and the FIRST version of this comment got
  # the reason wrong. Measured on this Redmine: a missing constant raises `NameError`
  # and a missing SUPERCLASS also raises `NameError` — both of which ARE `StandardError`,
  # and `NotImplementedError` is raised by neither. The real reason is narrower: a class
  # body that fails to PARSE raises `SyntaxError`, which is a `ScriptError` and not a
  # `StandardError`, and a `require` that cannot find its file raises `LoadError`, also a
  # `ScriptError`. Both reach a view exactly as fatally as a `NameError`.
  module ReporterReportTemplates
    # The classes this plugin's widgets can ask about. Asking is PER CLASS, deliberately:
    # an earlier version asked about both at once, which meant a broken time-entry class
    # disabled the perfectly healthy issue widget, for no reason and with no test either
    # way. Nothing this module guards names both.
    CLASS_NAMES = %w[IssueListReportTemplate TimeEntriesReportTemplate].freeze

    class << self
      # True when `class_name` may safely be named by a widget.
      def usable?(class_name)
        return false unless RedmineReporterDashboards.reporter_present?

        load_error(class_name).nil?
      end

      # `nil` when the class resolves, otherwise the exception raised.
      #
      # Memoised per class, and the memo is `key?` rather than the value's truthiness —
      # which is the whole reason a successful resolve (`nil`) is not re-walked on every
      # my-page render of a WORKING install. An earlier version also stored `|| false`
      # for that purpose and claimed in a comment that removing it would reintroduce the
      # per-render walk. That was FALSE: mutation testing removed it and nothing changed,
      # because `key?` had already made it redundant. The line is gone rather than
      # wrapped in a test of its fiction; `test_a_resolving_class_is_not_looked_up_twice`
      # asserts the surviving claim on `resolve` itself.
      def load_error(class_name)
        name = validated(class_name)
        errors = (@load_errors ||= {})
        return errors[name] if errors.key?(name)

        errors[name] = resolve(name)
      end

      # Reports a failure from the CALLER's rescue — the half a pre-check cannot cover.
      #
      # ERROR with a truncated backtrace, matching `reporter_project_pages_helper.rb`'s
      # `reporter_project_block_error` rather than inventing a second regime for the
      # same event (CLAUDE.md hard rule 6). The two log levels in this file are two
      # different events, not two ways of reporting one: a class that will not load is a
      # KNOWN, named condition an operator can read and act on, so it is WARN and said
      # once; an arbitrary exception from a widget body is an unknown defect, so it is
      # ERROR with a backtrace, every time, exactly as the project dashboard does it.
      def log_render_failure(error)
        Rails.logger.error(
          "[reporter_dashboards] my-page report widget could not be rendered: " \
          "#{error.class}: #{error.message}\n" \
          "#{Array(error.backtrace).first(5).join("\n")}"
        )
        nil
      end

      # For specs, and for a development reload that rebuilds the plugin registry in a
      # live process. Mirrors `ReporterPresence.reset!` deliberately, and
      # `RedmineReporterDashboards.reset_reporter_presence!` calls BOTH — two memoised
      # answers about the same optional dependency must not be clearable one at a time.
      def reset!
        @load_errors = nil
      end

      private

      def validated(class_name)
        name = class_name.to_s
        return name if CLASS_NAMES.include?(name)

        raise ArgumentError, "#{name} is not one of #{CLASS_NAMES.join(', ')}"
      end

      def resolve(name)
        Object.const_get(name)
        nil
      rescue StandardError, ScriptError => e
        log(e)
        e
      end

      # WARN rather than ERROR because the operator cannot fix it here — it is the
      # dependency's bug — and rather than INFO because, unlike a plugin that is simply
      # not installed, this IS a broken configuration and somebody should see it.
      #
      # Said once per class because `load_error` memoises the outcome, so `resolve` runs
      # at most once between resets. An earlier version also carried a `@logged` flag,
      # which was dead: it could never fire, and deleting it moved the "once" claim onto
      # the memo, where a test can actually see it.
      #
      # The plugin is named from `ReporterPresence::PLUGIN_ID` rather than spelled as a
      # literal, so the sentence and the thing actually looked for cannot drift apart.
      # The Redmine version is deliberately NOT interpolated: Redmine prints its own
      # version in the footer and in /admin/info, the exception already identifies the
      # cause, and reading `Redmine::VERSION` here would have to be routed through
      # `compat/` to satisfy `compat_size.sh` — 22% more code in the one directory that
      # exists to stay small, for a log decoration.
      def log(error)
        Rails.logger.warn(
          "[reporter_dashboards] #{ReporterPresence::PLUGIN_ID} is installed but " \
          "#{error.class}: #{error.message} — its report template classes do not load " \
          'on this Redmine. The report widgets degrade to a placeholder until that is ' \
          "fixed in #{ReporterPresence::PLUGIN_ID}."
        )
      end
    end
  end
end
