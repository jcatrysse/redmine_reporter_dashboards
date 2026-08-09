# frozen_string_literal: true

require_relative 'reporting/bundle'
require_relative 'reporting/bundle_import'
require_relative 'reporting/bundle_report'

module RedmineReporterDashboards
  # T-29 — the argument handling behind `rake reporter_dashboards:exchange:*`.
  #
  # It exists for the reason `Import::Survey` and `Scheduling::RunCommand` exist: a rake
  # file that grew a method is a place tests cannot reach, and every decision below is one
  # somebody can get wrong at a terminal — an unreadable file, a project that does not
  # exist, a conflict policy spelled differently, an actor who is not an administrator.
  # Each of those has to produce a SENTENCE rather than a stack trace, and a sentence is
  # exactly the kind of thing that is only ever right if a test read it.
  #
  # WHAT IT DELIBERATELY DOES NOT DO IS EXIT. The exit code is the rake task's, computed
  # from the report it gets back, so this module can be driven in a test without taking
  # the process down with it.
  module ExchangeTasks
    # A typed refusal, so the rake task can tell "the operator's arguments were wrong"
    # (print the sentence, exit 2) from "a template failed to import" (print the report,
    # exit 1). Collapsing the two would make a typo in a filename look like a bad bundle.
    class Refused < StandardError; end

    class << self
      def call(plan:)
        content = read_file(ENV['RRD_FILE'])
        project = find_project(ENV['RRD_PROJECT'])
        actor = resolve_actor(ENV['RRD_ACTOR'])

        importer = Reporting::BundleImport.new(
          project: project, actor: actor,
          on_conflict: ENV['RRD_ON_CONFLICT'].presence ||
                       Reporting::BundleImport::DEFAULT_CONFLICT_POLICY,
          logger: defined?(Rails) ? Rails.logger : nil
        )

        plan ? importer.plan(content) : importer.apply(content)
      end

      # `nil` MEANS "TEMPLATES WITH NO PROJECT", WHICH IS A REAL AND DIFFERENT THING from
      # "every project" — `Template#project` is `optional: true` and a project-less
      # template is admin-only by construction (`#editable_by?`). So an ABSENT
      # `RRD_PROJECT` selects that set rather than meaning "all", and an operator who
      # wanted a project's templates and forgot the variable gets an empty bundle with an
      # obvious cause instead of every template in the installation.
      def find_project(reference)
        return nil if reference.nil? || reference.to_s.strip.empty?

        reference = reference.to_s.strip
        project = if reference.match?(/\A\d+\z/)
                    ::Project.find_by(id: Integer(reference, 10))
                  else
                    ::Project.find_by(identifier: reference)
                  end

        raise Refused, "no project matches RRD_PROJECT=#{reference}" if project.nil?

        project
      end

      # THE SAME RULE AS `import:run`, AND IT REUSES THAT IMPLEMENTATION RATHER THAN
      # RESTATING IT. `Import::Runner.resolve_actor` answers an ACTIVE ADMINISTRATOR, and
      # the `.active` on both of its branches is there because an independent review found
      # them disagreeing — `RRD_ACTOR=locked-admin` authored every imported template as an
      # account that cannot log in. A second copy of that rule here would be a second
      # chance to lose the fix.
      def resolve_actor(reference)
        require_relative 'import/runner'

        actor = Import::Runner.resolve_actor(reference)
        return actor if actor

        # THE MESSAGE DISTINGUISHES THE TWO CASES, because they need different actions. It
        # used to say "set RRD_ACTOR" even when RRD_ACTOR *was* set and named a locked or
        # non-administrator account — sending the operator to fix the thing they had
        # already done.
        if reference.to_s.strip.empty?
          raise Refused,
                'no active administrator to own the imported templates. Set RRD_ACTOR to ' \
                'a login or user id, or create an administrator first.'
        end

        raise Refused,
              "RRD_ACTOR=#{reference} did not resolve to an ACTIVE ADMINISTRATOR. It must " \
              'name an administrator account that is not locked.'
      end

      def read_file(path)
        raise Refused, 'set RRD_FILE to the bundle to read' if path.nil? || path.to_s.empty?
        raise Refused, "#{path} does not exist" unless File.exist?(path)
        raise Refused, "#{path} is a directory" if File.directory?(path)

        # THE SIZE IS CHECKED BEFORE THE BYTES ARE READ, not after. `Bundle::MAX_BYTES`
        # bounds what the PARSER accepts, which is one `File.binread` too late: a 4 GB file
        # is already in this process by the time the parser can refuse it. One `File.size`
        # makes the bound real on the path where the input is a filename.
        size = File.size(path)
        if size > Reporting::Bundle::MAX_BYTES
          raise Refused,
                "#{path} is #{size} bytes and the limit is #{Reporting::Bundle::MAX_BYTES}"
        end

        # `binread` AND NOT `read`. HANDOVER §1: `File.read` applies the locale's external
        # encoding, so a bundle containing an em-dash raises `invalid byte sequence in
        # US-ASCII` on a bare container and works on a developer's machine. `Bundle.parse`
        # names UTF-8 itself and answers a typed refusal for bytes that are not — which it
        # can only do if it is handed the bytes.
        File.binread(path)
      rescue SystemCallError => e
        # NOT `rescue StandardError`: an unreadable file is an operator problem with a
        # sentence, and anything else here is a defect that must reach the log as one.
        raise Refused, "#{path} could not be read: #{e.message}"
      end

      # The version an export stamps itself with. Read from the registered plugin rather
      # than from a constant, because `init.rb` is where it is declared and a second
      # literal would be a second thing to forget on release day. Degrades to nil — a
      # bundle whose provenance is unknown is still a bundle, and `BundleReport` prints
      # "(not stated)" for it.
      def plugin_version
        return nil unless defined?(::Redmine::Plugin)

        ::Redmine::Plugin.find(:redmine_reporter_dashboards)&.version
      rescue ::Redmine::PluginNotFound
        nil
      end
    end
  end
end
