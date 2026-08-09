# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# REVIEWER PROBE 2 — NOT PART OF THE DELIVERABLE. Delete before merge.
class ZzzReviewerProbe2Test < Redmine::IntegrationTest
  include Redmine::I18n

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  ShareLink = RedmineReporterDashboards::ShareLink
  Snapshot = RedmineReporterDashboards::Reporting::Snapshot
  Template = RedmineReporterDashboards::Template

  PDF_BYTES = "%PDF-1.4\n#{'0' * 2_000}\n%%EOF"

  class FakeEngine
    def capabilities = []
    def id = 'fake'

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: ZzzReviewerProbe2Test::PDF_BYTES, engine: 'fake', engine_version: '1.0'
      )
    end
  end

  def setup
    @project = Project.find(1)
    @project.enable_module!(:reporter_dashboards_reports)
    @jsmith = User.find_by!(login: 'jsmith')
    role = Role.find(1)
    role.permissions = %w[view_issues view_reporter_dashboards_reports]
    role.save!
    @template = Template.create!(project: @project, author: @jsmith, name: 'Quarterly',
                                 content: '<p>hello</p>', source: 'issues', output: 'combined')
  end

  def teardown
    User.current = nil
  end

  def capture(overrides = {})
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, FakeEngine)
      Snapshot.capture(**{ template: @template, render_as: @jsmith, project: @project,
                           created_by: @jsmith, expires_at: 30.days.from_now }.merge(overrides))
    end
  end

  def mint(document, overrides = {})
    ShareLink.create_with_token!({ template: @template, project: @project,
                                   created_by: @jsmith,
                                   scope_kind: ShareLink::SCOPE_SNAPSHOT,
                                   rendered_document_id: document.id,
                                   render_as_user_id: @jsmith.id,
                                   public_link: true,
                                   expires_at: 30.days.from_now }.merge(overrides))
  end

  # --------------------------------------------------------------- Q1 disk collision

  def test_q1_three_snapshots_do_not_share_a_disk_file
    docs = 3.times.map do
      @template.update_columns(name: "Отчёт #{rand(1000)}")
      r = capture
      raise r.message.to_s unless r.ok?

      ::Attachment.find(r.document.attachment_id)
    end
    docs.each { |a| puts "Q1 id=#{a.id} filename=#{a.filename} disk=#{a.disk_directory}/#{a.disk_filename} exists=#{File.exist?(a.diskfile)}" }
    puts "Q1 unique_disk_paths=#{docs.map(&:diskfile).uniq.size} of #{docs.size}"
    puts "Q1 all_bytes_correct=#{docs.all? { |a| File.binread(a.diskfile) == PDF_BYTES }}"
    assert true
  end

  # --------------------------------------------------------------- Q2 long template name

  def test_q2_the_template_name_length_at_which_a_snapshot_becomes_impossible
    max = RedmineReporterDashboards::Template::MAX_STRING rescue 255
    puts "Q2 Template MAX_STRING=#{max}"
    [200, 230, 240, 245, 250, max].uniq.each do |n|
      @template.update_columns(name: 'a' * n)
      r = capture
      puts "Q2 name_len=#{n} -> ok=#{r.ok?} code=#{r.code} msg=#{r.message.to_s[0, 70]}"
    end
    # and a name that is legal for a Template
    t = Template.new(project: @project, author: @jsmith, name: 'a' * max,
                     content: '<p>x</p>', source: 'issues', output: 'combined')
    puts "Q2 a #{max}-character template name is valid for Template: #{t.valid?}"
    assert true
  end

  # --------------------------------------------------------------- Q3 response headers

  def test_q3_the_headers_a_public_snapshot_is_served_with
    r = capture
    _l, token = mint(r.document, max_uses: nil)
    get "/reporter/s/#{token}"
    puts "Q3 status=#{response.status}"
    response.headers.each { |k, v| puts "Q3 header #{k}: #{v.to_s[0, 120]}" }
    assert true
  end

  # --------------------------------------------------------------- Q4 does a refusal leak

  def test_q4_the_refusal_page_for_an_anonymous_visitor
    r = capture
    link, token = mint(r.document)
    link.revoke!
    get "/reporter/s/#{token}"
    puts "Q4 status=#{response.status} len=#{response.body.bytesize}"
    puts "Q4 mentions_project=#{response.body.include?(@project.identifier)} " \
         "mentions_template=#{response.body.include?('Quarterly')}"
    puts "Q4 title=#{response.body[/<title>(.*?)<\/title>/m, 1].to_s.strip[0, 80]}"
    puts "Q4 has_login_link=#{response.body.include?('/login')}"
    assert true
  end

  # --------------------------------------------------------------- Q5 concurrency of use!

  def test_q5_two_threads_racing_a_single_use_link_over_http_is_not_testable_here
    # instead: a direct check that use! is atomic under the DB, at the limit and one past
    r = capture
    link, = mint(r.document, max_uses: 2)
    puts "Q5 use1=#{link.use!.inspect} use2=#{link.use!.inspect} use3=#{link.use!.inspect}"
    puts "Q5 final_use_count=#{link.reload.use_count}"
    assert true
  end

  # --------------------------------------------------------------- Q6 the document TTL

  def test_q6_is_there_anything_that_ever_collects_an_expired_document
    r = capture(expires_at: 1.hour.from_now)
    r.document.update_columns(expires_at: 10.days.ago)
    puts "Q6 Document.expired.count=#{RedmineReporterDashboards::Document.expired.count}"
    tasks = Rake.application.tasks.map(&:name).grep(/reporter/) rescue []
    puts "Q6 rake tasks mentioning reporter: #{tasks.inspect}"
    _l, token = mint(r.document)
    get "/reporter/s/#{token}"
    puts "Q6 a link still serves a 10-day-expired document: status=#{response.status} len=#{response.body.bytesize}"
    assert true
  end

  # --------------------------------------------------------------- Q7 unfiltered params

  def test_q7_is_the_token_in_the_parameter_filter
    puts "Q7 filter_parameters=#{Rails.application.config.filter_parameters.inspect}"
    r = capture
    _l, token = mint(r.document, public_link: false)
    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    Rails.logger.level = Logger::INFO
    begin
      get "/reporter/s/#{token}"
    ensure
      Rails.logger = old
    end
    puts "Q7 log lines:"
    io.string.lines.first(6).each { |l| puts "Q7   #{l.strip[0, 160]}" }
    assert true
  end
end
