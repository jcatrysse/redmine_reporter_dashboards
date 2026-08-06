require File.expand_path('../test_helper', __dir__)
require 'rake'
require 'stringio'

# The wiring, and only the wiring — the same shape and the same reason as
# `import_plan_rake_test.rb`.
#
# `Render::PreflightCommand` is covered by rspec: the exit codes, the engine selection,
# the two output formats. What no spec can reach is the glue in
# `lib/tasks/reporter_dashboards.rake`: a typo in the namespace, a require pointing at a
# path that moved, the `Setting.host_name` line raising, or `exit` swallowing the status.
# Every one of those produces a green rspec run and a rake task that does not work, which
# is the class of failure this project keeps finding late.
#
# T-14's Accept list says the task EXITS NON-ZERO. `exit` raises `SystemExit`, so that is
# asserted by catching it and reading the status — not by trusting that the call is
# there.
class RenderPreflightRakeTest < ActiveSupport::TestCase
  TASK = 'reporter_dashboards:render:preflight'.freeze
  RAKE_FILE = File.expand_path('../../lib/tasks/reporter_dashboards.rake', __dir__).freeze

  Render = RedmineReporterDashboards::Render

  def setup
    # CLEARED IN setup AS WELL AS teardown. The render-smoke job exports `RRD_*` vars,
    # and if either of these were exported into a test process
    # `test_it_exits_2_when_no_engine_is_registered` would raise `UnknownEngine` instead
    # of returning 2 — a failure whose cause is the environment, in the one file whose
    # whole subject is reading the environment.
    ENV.delete('RRD_ENGINE')
    ENV.delete('RRD_FORMAT')
    @previous = Rake.application
    @previous_metadata = Rake::TaskManager.record_task_metadata
    Rake.application = Rake::Application.new
    # Descriptions are DISCARDED unless this is on: rake records them only when it is
    # about to show them (`rake -T`), so a `desc` assertion against an in-process load
    # reads nil however correct the task file is.
    Rake::TaskManager.record_task_metadata = true
    Rake::Task.define_task(:environment)
    load RAKE_FILE
  end

  def teardown
    Rake.application = @previous
    Rake::TaskManager.record_task_metadata = @previous_metadata
    ENV.delete('RRD_ENGINE')
    ENV.delete('RRD_FORMAT')
  end

  def test_the_task_is_defined_under_the_documented_name
    assert Rake::Task.task_defined?(TASK), "#{TASK} is not defined by #{RAKE_FILE}"
  end

  def test_the_task_describes_its_exit_codes_for_rake_dash_t
    description = Rake::Task[TASK].comment

    assert_not_nil description, 'the task has no desc, so it is invisible in `rake -T`'
    # The exit code is the product — see PreflightCommand. A task whose `-T` line does
    # not say so is a task an operator wires into a deploy step by guessing.
    assert_match(/exit/i, description)
  end

  # THE ACCEPT-LIST PROMISE. Not "the code calls exit" — the status, caught and read.
  def test_it_exits_2_when_no_engine_is_registered
    status = nil
    output = Render::Registry.isolated do
      capture_task { |code| status = code }
    end

    assert_equal Render::PreflightCommand::NOTHING_TO_RUN, status
    assert_match(/NO ENGINE REGISTERED/, output)
  end

  def test_it_exits_1_when_a_check_failed
    status = nil
    output = with_failing_engine { capture_task { |code| status = code } }

    assert_equal Render::PreflightCommand::FAILURES, status
    assert_match(/FAIL/, output)
  end

  def test_it_exits_0_when_everything_passed
    status = nil
    with_passing_engine { capture_task { |code| status = code } }

    assert_equal Render::PreflightCommand::OK, status
  end

  # The env vars are the task's only interface, so they are asserted through it rather
  # than through the class that already has its own spec for them.
  def test_rrd_format_json_produces_parseable_json
    ENV['RRD_FORMAT'] = 'json'
    output = with_passing_engine { capture_task }

    parsed = ActiveSupport::JSON.decode(output)
    assert_equal 1, parsed.length
    assert_equal 'passing', parsed.first['engine']
  end

  def test_rrd_engine_selects_one_engine
    ENV['RRD_ENGINE'] = 'passing'
    output = with_passing_engine do
      Render::Registry.register(:other, passing_adapter)
      capture_task
    end

    assert_equal 1, output.scan('render preflight:').length
  end

  private

  # An adapter CLASS, because that is what the Registry maps an id to and what the task
  # ends up newing up. It never renders: the Preflight is stubbed, so no fake here has
  # to imitate a browser.
  def passing_adapter
    Class.new do
      def id
        :passing
      end

      def version
        'passing-1'
      end
    end
  end

  def with_passing_engine(&block)
    stub_report(:pass)
    Render::Registry.isolated do
      Render::Registry.register(:passing, passing_adapter)
      block.call
    end
  end

  def with_failing_engine(&block)
    stub_report(:fail)
    Render::Registry.isolated do
      Render::Registry.register(:passing, passing_adapter)
      block.call
    end
  end

  def stub_report(state)
    report = Render::Preflight::Report.new(
      engine_id: :passing, engine_version: 'passing-1', duration_ms: 1,
      checks: [Render::Preflight::Check.new(id: :engine, title: 'the engine drew',
                                            state: state, detail: 'd', duration_ms: 1)]
    )
    Render::Preflight.any_instance.stubs(:run).returns(report)
  end

  # `exit` raises SystemExit, which is not a StandardError — catching it explicitly is
  # what makes the exit code assertable instead of merely present in the source.
  def capture_task
    previous = $stdout
    $stdout = StringIO.new
    begin
      Rake::Task[TASK].reenable
      Rake::Task[TASK].invoke
      yield 0 if block_given?
    rescue SystemExit => e
      yield e.status if block_given?
    end
    $stdout.string
  ensure
    $stdout = previous
  end
end
