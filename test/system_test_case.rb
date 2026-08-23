# frozen_string_literal: true

require File.expand_path('test_helper', __dir__)
require File.expand_path('../../../test/application_system_test_case', __dir__)

# THE BASE CLASS FOR THIS PLUGIN'S BROWSER TESTS — R-02 / C-07.
#
# --- IT SUBCLASSES REDMINE'S, AND ADDS ALMOST NOTHING ---
#
# `ApplicationSystemTestCase` already owns the driver, the screen size, the download
# directory, the `Setting` reset either side of every example and `log_user`. Re-declaring
# `driven_by` here would fork the browser configuration from the host application's, which is
# the one thing a plugin's system suite must not do: an author debugging a failure needs the
# Redmine recipe to apply.
#
# What is added is a project with the modules on, a role holding the plugin's permissions, and
# a signed-in author — because every journey below starts from "a person who is allowed to be
# here", and building that in six files would be six chances to build it differently.
#
# --- THE BROWSER BINARY IS CONFIGURABLE, AND HAS TO BE ---
#
# Redmine's harness honours `GOOGLE_CHROME_OPTS_ARGS` for flags but has no way to say WHERE
# the browser is. On a runner where Chrome is not at a path chromedriver searches — a
# container with Chrome for Testing in a cache, which is the ordinary case — every example
# fails with `unknown error: cannot find Chrome binary`, which reads like a broken suite.
# `RRD_CHROME_PATH` is the seam, and it is read here rather than in each file.
#
# THE FLAGS ARE NOT SET HERE. `--no-sandbox` in particular is the runner's decision and not
# this suite's: a container running as root needs it, a developer's workstation must not be
# silently told to drop the sandbox by a test file. `GOOGLE_CHROME_OPTS_ARGS` is Redmine's
# own env var and CONTRIBUTING.md records the recipe.
class ReporterDashboardsSystemTestCase < ApplicationSystemTestCase
  if ENV['RRD_CHROME_PATH'].present?
    ::Selenium::WebDriver::Chrome.path = ENV['RRD_CHROME_PATH']
  end

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :email_addresses, :issues, :issue_statuses, :trackers, :enumerations,
           :projects_trackers, :versions

  Template = RedmineReporterDashboards::Template
  ShareLink = RedmineReporterDashboards::ShareLink

  # Every permission this plugin registers that a journey below needs. Named explicitly rather
  # than `Redmine::AccessControl.permissions`-and-take-everything: a test that silently gains
  # a permission when one is added is a test that stops being able to say which one it needed.
  AUTHOR_PERMISSIONS = %i[
    view_reporter_project_page
    manage_reporter_project_page
    manage_reporter_project_tabs
    view_reporter_dashboards_reports
    add_reporter_dashboards_templates
    edit_reporter_dashboards_templates
    edit_own_reporter_dashboards_templates
    share_reporter_dashboards_reports
  ].freeze

  # Read from the catalogue rather than restated, so a module rename moves this with it.
  MODULES = [RedmineReporterDashboards::Permissions::DASHBOARDS_MODULE,
             RedmineReporterDashboards::Permissions::REPORTS_MODULE].map(&:to_s).freeze

  def setup
    @project = Project.find(1)
    MODULES.each do |name|
      next if @project.enabled_module_names.include?(name)

      EnabledModule.create!(project: @project, name: name)
    end
    # RELOAD. `enabled_module_names` memoises, and `User#allowed_to?` asks the memoised object
    # — so without this the test's own `@project` answers false for a module the controller,
    # which loads its own copy inside the request, sees as enabled. The functional suite
    # learned this the hard way; the comment there is longer.
    @project.reload

    @role = Role.find(1)
    @role.permissions = (@role.permissions | AUTHOR_PERMISSIONS)
    @role.save!

    @author = User.find(2)
    log_user(@author.login, 'jsmith')
  end

  # WAIT FOR THE BROWSER'S REQUEST, THEN ASSERT ON THE DATABASE.
  #
  # Capybara waits for the PAGE; it does not wait for a row. A click that fires a POST returns
  # as soon as the click is dispatched, so `assert x.reload.moved?` on the next line reads the
  # database while the request may still be in flight. That is not a slow test, it is a
  # NON-DETERMINISTIC one: the first version of the move-control example passed and failed on
  # alternate runs of the same code, which is the exact failure mode CLAUDE.md §6 exists to
  # keep out of this suite — and it would have been read as a real defect the first time CI
  # caught it.
  #
  # The timeout is Capybara's own, so raising it raises this too, and the message is the
  # caller's so a timeout still says which control did not do its job.
  def eventually(message)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time

    loop do
      return if yield
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end

    flunk message
  end
end
