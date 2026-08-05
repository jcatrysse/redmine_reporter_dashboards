# frozen_string_literal: true

module RedmineReporterDashboards
  # VERSION DIVERGENCE lives here, one method per divergence, each naming the
  # versions it spans (CLAUDE.md §4). Never a scattered `if Rails::VERSION`.
  #
  # ONE FILE, not a compat/ directory, and that is a Zeitwerk constraint rather than a
  # preference: Redmine puts a plugin's lib/ on the autoload paths, so
  # `compat/base_record.rb` is required to define `Compat::BaseRecord` and raises
  # Zeitwerk::NameError when it defines a method on `Compat` instead. The plan's future
  # `compat/serialize.rb` and `compat/enum.rb` therefore have to define
  # `Compat::Serialize` and `Compat::Enum`, or live here as methods too — this file is
  # where the next divergence goes until one of them needs a class of its own.
  module Compat
    # The class this plugin's models inherit from.
    #
    #   Redmine 6.0+  app/models/application_record.rb exists: ApplicationRecord,
    #                 an abstract_class that adds Redmine's own
    #                 human_attribute_name translation defaults.
    #   Redmine 5.1   HAS NO SUCH CLASS. Models inherit ActiveRecord::Base, and the
    #                 identical human_attribute_name body is monkey-patched onto it
    #                 by config/initializers/10-patches.rb — verified against
    #                 5.1-stable, the two bodies are the same code moved.
    #
    # So the two branches are behaviourally equivalent for a plugin model, and this
    # is a naming divergence rather than a feature one.
    #
    # WHY THIS EXISTS AT ALL: `class ReporterProjectTab < ApplicationRecord` has been
    # in this plugin since v0.5.0, and on Redmine 5.1 it raises
    # `NameError: uninitialized constant ApplicationRecord` the moment the model is
    # first referenced — which is every dashboard page and every plugin test. The
    # plugin has therefore NEVER worked on Redmine 5.1, while the README listed 5.1
    # as tested. Nothing caught it because the full-application suite could not run
    # in CI until the secret was removed (T-09); its first 5.1 run reported 92 errors,
    # all of them this one line. That is INV-7's failure mode exactly: an untested
    # configuration was claimed as supported.
    #
    # const_defined?, not defined?: under Zeitwerk the constant is registered as an
    # autoload before its file is read, and const_defined? answers true for a pending
    # autoload without forcing it. A `rescue NameError` around the reference would
    # also "work" and is a forbidden construct — it is exactly how a coupling like
    # this stays invisible (CLAUDE.md §5).
    def self.base_record
      Object.const_defined?(:ApplicationRecord) ? ::ApplicationRecord : ::ActiveRecord::Base
    end

    # Whether the running Redmine paints icons through the SVG sprite system.
    #
    #   Redmine 6.0+  IconsHelper#sprite_icon exists and the core sprite carries the
    #                 angle-* set the move controls use.
    #   Redmine 5.1   HAS NEITHER. IconsHelper arrived in 6.0, so `sprite_icon` does
    #                 not merely render nothing there — it raises NoMethodError. That
    #                 was 27 of the 92 errors the first 5.1 CI run reported (D-3).
    #
    # Asked of Redmine's VERSION rather than of the helper, because the caller is a
    # helper module that HAS IconsHelper mixed in on 6+ and needs the answer before it
    # calls anything. Lives here rather than in the helper because E4 (technical-spec
    # §1.2) and CLAUDE.md §4 both say version divergence has exactly one home: a
    # scattered `Redmine::VERSION::MAJOR >= 6` is the shape that ossifies, and
    # `compat_size.sh` is what now stops the next one being written in a view.
    def self.svg_icons?
      ::Redmine::VERSION::MAJOR >= 6
    end
  end
end
