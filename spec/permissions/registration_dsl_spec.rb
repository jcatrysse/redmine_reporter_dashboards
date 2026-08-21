# frozen_string_literal: true

# T-40 — does `init.rb`'s LOOP register what the three literal `permission` calls did?
#
# `permission_map_spec.rb` asserts `registrations_by_module`, which is data derived from
# `REGISTERED`. That is necessary and not sufficient: it never executes the loop, so it cannot
# see a break in the `project_module { registrations.each { … } }` closure — and the review of
# T-40 pointed out that the only run which HAD exercised the loop was done out of band and
# thrown away, leaving a HANDOVER claim with nothing behind it.
#
# So the recorder is committed. It mimics `Redmine::Plugin`'s two methods exactly, from
# `lib/redmine/plugin.rb` — byte-identical on 5.1, 6.0, 6.1 and 7.0-stable apart from 7.0
# writing `&` where the others write `&block`:
#
#   def project_module(name, &block)
#     @project_module = name
#     self.instance_eval(&block)
#     @project_module = nil
#   end
#
#   def permission(name, actions, options = {})
#     if @project_module
#       Redmine::AccessControl.map {|map| map.project_module(@project_module) {|map| map.permission(name, actions, options) } }
#     else
#       Redmine::AccessControl.map {|map| map.permission(name, actions, options)}
#     end
#   end
#
# **What this DOES prove:** that `instance_eval` does not break the closure over the loop's
# `registrations` local, that the constant resolves from `init.rb`'s top-level cref, and that
# the three calls arrive with the same name, action map and options — in the same order,
# under the same project module.
#
# **What it does NOT prove, said plainly:** that a real Redmine accepts them. Only the
# `minitest` CI jobs do that, and `test/functional/reporter_project_{pages,tabs}_controller_test.rb`
# are what actually assert a 200/403 from a granted or withheld permission. A fake cannot
# stand in for those, and this file is not offered as their replacement.
#
# The loop below is a VERBATIM copy of `init.rb`'s. A copy can drift, so the first example
# reads `init.rb` and asserts the text still matches — which is cheaper than the alternative
# (executing `init.rb`, which requires Redmine) and fails loudly rather than silently.

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/permissions'

module RedmineReporterDashboards
  RSpec.describe 'init.rb permission registration' do
    ROOT_FOR_REGISTRATION = File.expand_path('../..', __dir__)

    # The two methods, as Redmine defines them. Nothing else: this is a recorder, not a
    # simulation of `AccessControl`.
    class PluginDouble
      attr_reader :calls

      def initialize
        @calls = []
        @project_module = nil
      end

      def project_module(name, &block)
        @project_module = name
        instance_eval(&block)
        @project_module = nil
      end

      def permission(name, actions, options = {})
        @calls << [@project_module, name, actions, options]
      end
    end

    # VERBATIM from init.rb. Kept as a String and `instance_eval`ed so the example below can
    # compare it with the file rather than trusting that somebody kept them in step.
    REGISTRATION_LOOP = <<~RUBY
      RedmineReporterDashboards::Permissions.registrations_by_module
                                            .each do |project_module_name, registrations|
        project_module project_module_name do
          registrations.each { |name, actions, options| permission name, actions, options }
        end
      end
    RUBY

    # The three calls `init.rb` made before T-40 turned them into a loop, transcribed from
    # the v0.5.0-era source. This is the oracle, and it stays EXACTLY as it was: T-23
    # registers five more permissions in a second module, and the thing worth asserting
    # is that doing so left the original three untouched — same order, same action maps,
    # same options. A rewritten oracle would assert that the new code matches itself.
    LITERAL_CALLS = [
      [:reporter_project_dashboards, :view_reporter_project_page,
       { reporter_project_pages: [:show, :report_pdf] }, { read: true }],
      [:reporter_project_dashboards, :manage_reporter_project_page,
       { reporter_project_pages: [:update_page, :add_block, :remove_block, :move_block] },
       {}],
      # `projects: [:settings]` IS NOT A CHANGE TO WHAT THIS PERMISSION GUARDS. The tab this
      # permission owns lives on `ProjectsController#settings`, which has
      # `before_action :authorize` — so without this mapping a role holding only our
      # permission would see the tab in the list and get a 403 opening the page. Core maps
      # the same action from `manage_members` and `manage_versions` for the same reason
      # (`lib/redmine/preparation.rb:46-47`). It comes from `Entry#settings_tab`, never from
      # a hand-written second controller key — see `Permissions::SETTINGS_TAB_ACTIONS`.
      [:reporter_project_dashboards, :manage_reporter_project_tabs,
       { reporter_project_tabs: [:create, :update, :destroy, :order],
         projects: [:settings] }, {}]
    ].freeze

    def record
      plugin = PluginDouble.new
      plugin.instance_eval(REGISTRATION_LOOP)
      plugin.calls
    end

    it 'is the loop init.rb actually contains' do
      # Compared line by line with leading whitespace stripped: the loop sits inside
      # `Redmine::Plugin.register do`, so the file's copy is indented and its continuation
      # line is aligned to a different column. Everything else must match exactly, and the
      # lines must be consecutive.
      squash = ->(text) { text.lines.map(&:strip).reject(&:empty?) }
      wanted = squash.call(REGISTRATION_LOOP)
      actual = squash.call(File.read(File.join(ROOT_FOR_REGISTRATION, 'init.rb'),
                                    encoding: 'UTF-8'))

      expect(actual.each_cons(wanted.size)).to include(wanted),
                                               'init.rb no longer contains this loop, so ' \
                                               'every assertion below is about a copy. ' \
                                               'Update REGISTRATION_LOOP with init.rb.'
    end

    it 'still registers exactly the three literal calls first, in order' do
      # `first(3)` and not `==`: T-23 appends a second module. The dashboards module is
      # declared first in `Permissions::ENTRIES` and the spec for that ordering lives in
      # `permission_map_spec.rb`, so what this file has to prove is narrower and older —
      # that the loop reproduces the three calls the literals made.
      expect(record.first(3)).to eq(LITERAL_CALLS)
    end

    it 'sets the project module on every call, which is what the roles screen groups by' do
      expect(record.map(&:first).uniq)
        .to eq([:reporter_project_dashboards, :reporter_dashboards_reports])
    end

    it 'declares each module ONCE, in a single contiguous run' do
      # `registrations_by_module` groups, so two runs of one module would mean the loop
      # opened `project_module` twice — which Redmine accepts and which silently reorders
      # the roles screen relative to `ENTRIES`. Cheap to assert, invisible otherwise.
      modules = record.map(&:first)

      expect(modules.chunk_while { |a, b| a == b }.map(&:first))
        .to eq(modules.uniq)
    end

    it 'survives `instance_eval` rebinding self — the closure is over the loop, not the plugin' do
      # If `instance_eval` broke the closure, `registrations` would be a NameError inside the
      # `project_module` block rather than the array the loop is iterating. This is the whole
      # reason the recorder exists.
      expect { record }.not_to raise_error
      expect(record.size)
        .to eq(RedmineReporterDashboards::Permissions::REGISTERED.size)
    end

    it 'passes an options Hash Redmine can read, never a nil third argument' do
      record.each { |(_, _, _, options)| expect(options).to be_a(Hash) }
    end

    it 'hands out no action map that a caller could mutate' do
      # `Permission#initialize` copies the hash rather than keeping it, so this is defence in
      # depth rather than a live bug — but the model is described as frozen data throughout
      # and an `Array#freeze` on REGISTERED alone would not have made it so.
      record.each do |(_, _, actions, _)|
        expect(actions).to be_frozen
        actions.each_value { |list| expect(list).to be_frozen }
      end
    end
  end
end
