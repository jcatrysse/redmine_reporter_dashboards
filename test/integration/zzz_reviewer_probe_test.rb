# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# REVIEWER PROBE — NOT PART OF THE DELIVERABLE. Delete before merge.
class ZzzReviewerProbeTest < Redmine::IntegrationTest
  include Redmine::I18n

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  ShareLink = RedmineReporterDashboards::ShareLink
  ShareLinkAccess = RedmineReporterDashboards::ShareLinkAccess
  Snapshot = RedmineReporterDashboards::Reporting::Snapshot
  Template = RedmineReporterDashboards::Template

  # BINARY: NUL bytes, invalid UTF-8 (\xFF\xFE), a lone \x80 continuation byte, CRLF,
  # and a high-bit run. This is what a real PDF looks like and it is NOT what the
  # author's ASCII-safe fixture tested.
  BINARY_BYTES = (+"%PDF-1.4\r\n\x00\x01\x02\xFF\xFE\x80\xC3\x28\x00").force_encoding(Encoding::BINARY) +
                 (+"\x00\xFF" * 500).force_encoding(Encoding::BINARY) +
                 (+"\n%%EOF").force_encoding(Encoding::BINARY)

  class BinaryEngine
    def capabilities = []
    def id = 'fake'

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: ZzzReviewerProbeTest::BINARY_BYTES, engine: 'fake', engine_version: '1.0'
      )
    end
  end

  # A UTF-8-tagged string carrying bytes that are not valid UTF-8 — what a real engine
  # hands back when it read a file with the wrong external encoding.
  class BadEncodingEngine
    def capabilities = []
    def id = 'fake'

    def render(_request)
      RedmineReporterDashboards::Render::Success.new(
        bytes: (+"%PDF-1.4\n\xC3\x28\xA0\xA1\n%%EOF").force_encoding(Encoding::UTF_8),
        engine: 'fake', engine_version: '1.0'
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

  def capture_with(engine_class, overrides = {})
    RedmineReporterDashboards::Render::Registry.isolated do
      RedmineReporterDashboards::Render::Registry.register(:fake, engine_class)
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

  # ---------------------------------------------------------------- P1 binary bytes

  def test_p1_binary_bytes_round_trip_through_store_and_http
    result = capture_with(BinaryEngine)
    assert result.ok?, "capture refused: #{result.code} #{result.message}"

    doc = result.document
    puts "P1 byte_size=#{doc.byte_size} expected=#{BINARY_BYTES.bytesize}"
    puts "P1 digest_matches=#{doc.digest == Digest::SHA256.hexdigest(BINARY_BYTES)}"
    puts "P1 bytes_encoding=#{doc.bytes.encoding} bytes_equal=#{doc.bytes == BINARY_BYTES}"

    _l, token = mint(doc)
    get "/reporter/s/#{token}"
    puts "P1 http_status=#{response.status} body_bytesize=#{response.body.bytesize} " \
         "body_equal=#{response.body.b == BINARY_BYTES}"
    puts "P1 headers=#{response.headers.to_h.slice('Content-Type', 'Content-Disposition', 'Cache-Control', 'X-Content-Type-Options', 'Content-Length').inspect}"
    assert true
  end

  def test_p2_utf8_tagged_invalid_bytes
    result = capture_with(BadEncodingEngine)
    puts "P2 ok=#{result.ok?} code=#{result.code} message=#{result.message.inspect}"
    if result.ok?
      puts "P2 stored_size=#{result.document.byte_size} bytes_equal=" \
           "#{result.document.bytes == (+"%PDF-1.4\n\xC3\x28\xA0\xA1\n%%EOF").b}"
    end
    assert true
  end

  # ---------------------------------------------------------------- P3 filenames

  def test_p3_filename_for_non_latin_and_empty_template_names
    ['Отчёт за квартал', '季度报告', '   ', '../../etc/passwd', 'a' * 400].each do |name|
      @template.update_columns(name: name)
      result = capture_with(BinaryEngine)
      if result.ok?
        att = ::Attachment.find(result.document.attachment_id)
        puts "P3 name=#{name[0, 24].inspect} -> filename=#{att.filename.inspect} " \
             "disk_filename=#{att.disk_filename.inspect}"
        _l, token = mint(result.document)
        get "/reporter/s/#{token}"
        puts "P3   Content-Disposition=#{response.headers['Content-Disposition'].inspect}"
      else
        puts "P3 name=#{name[0, 24].inspect} -> REFUSED #{result.code} #{result.message}"
      end
    end
    assert true
  end

  # ---------------------------------------------------------------- P4 token leakage

  def test_p4_the_token_in_the_signin_redirect
    result = capture_with(BinaryEngine)
    _l, token = mint(result.document, public_link: false)

    get "/reporter/s/#{token}"
    loc = response.headers['Location'].to_s
    puts "P4 status=#{response.status}"
    puts "P4 Location=#{loc}"
    puts "P4 token_in_location=#{loc.include?(token) || loc.include?(CGI.escape(token))}"

    # And what the login page then puts in its own HTML
    follow_redirect!
    puts "P4 login_page_contains_token=#{response.body.include?(token) || response.body.include?(CGI.escapeHTML(token))}"
    assert true
  end

  def test_p5_the_token_in_the_rails_log
    result = capture_with(BinaryEngine)
    _l, token = mint(result.document, public_link: false)

    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    Rails.logger.level = Logger::INFO
    begin
      get "/reporter/s/#{token}"
    ensure
      Rails.logger = old
    end
    log = io.string
    puts "P5 token_appears_in_log=#{log.include?(token) || log.include?(CGI.escape(token))}"
    puts "P5 log_excerpt=#{log.lines.grep(/reporter|Redirect|Started/).first(4).map(&:strip).inspect}"
    assert true
  end

  # ---------------------------------------------------------------- P6 format suffix

  def test_p6_a_format_suffix_on_a_refusal
    result = capture_with(BinaryEngine)
    _l, token = mint(result.document)

    %w[json xml csv pdf atom].each do |fmt|
      begin
        get "/reporter/s/#{ShareLink.generate_token}.#{fmt}"
        puts "P6 unknown-token .#{fmt} -> status=#{response.status}"
      rescue StandardError => e
        puts "P6 unknown-token .#{fmt} -> RAISED #{e.class}: #{e.message[0, 120]}"
      end
    end

    # a real token, but the link is revoked so it goes down the refusal path
    link = ShareLink.find_by_token(token)
    link.revoke!
    %w[json xml].each do |fmt|
      begin
        get "/reporter/s/#{token}.#{fmt}"
        puts "P6 revoked .#{fmt} -> status=#{response.status}"
      rescue StandardError => e
        puts "P6 revoked .#{fmt} -> RAISED #{e.class}: #{e.message[0, 120]}"
      end
    end
    assert true
  end

  def test_p6b_accept_header_variations
    result = capture_with(BinaryEngine)
    _l, token = mint(result.document, max_uses: nil)

    [['application/json', 'json'], ['*/*', 'star'], ['text/csv', 'csv']].each do |accept, name|
      begin
        get "/reporter/s/#{ShareLink.generate_token}", headers: { 'HTTP_ACCEPT' => accept }
        puts "P6b accept=#{name} unknown-token -> status=#{response.status}"
      rescue StandardError => e
        puts "P6b accept=#{name} -> RAISED #{e.class}: #{e.message[0, 120]}"
      end
    end
    assert true
  end

  # ---------------------------------------------------------------- P7 HEAD burns a use

  def test_p7_a_head_request_consumes_a_use_and_returns_no_bytes
    result = capture_with(BinaryEngine)
    link, token = mint(result.document, max_uses: 1)

    head "/reporter/s/#{token}"
    puts "P7 head_status=#{response.status} body_bytesize=#{response.body.bytesize} " \
         "use_count=#{link.reload.use_count}"

    get "/reporter/s/#{token}"
    puts "P7 subsequent_get_status=#{response.status} " \
         "(410 means the HEAD burned the only use)"
    assert true
  end

  # ---------------------------------------------------------------- P8 core attachment route

  def test_p8_core_attachment_route_is_actually_closed
    result = capture_with(BinaryEngine)
    att = ::Attachment.find(result.document.attachment_id)

    log_user('admin', 'admin')
    ['/attachments/%d' % att.id,
     '/attachments/%d/%s' % [att.id, att.filename],
     '/attachments/download/%d' % att.id,
     '/attachments/thumbnail/%d' % att.id].each do |path|
      begin
        get path
        puts "P8 admin GET #{path} -> #{response.status} len=#{response.body.bytesize}"
      rescue StandardError => e
        puts "P8 admin GET #{path} -> RAISED #{e.class}: #{e.message[0, 100]}"
      end
    end
    assert true
  end

  # ---------------------------------------------------------------- P9 link outliving doc

  def test_p9_a_link_may_outlive_the_document_it_points_at
    result = capture_with(BinaryEngine, expires_at: 1.hour.from_now)
    doc = result.document

    link, token = ShareLink.create_with_token!(
      template: @template, project: @project, created_by: @jsmith,
      scope_kind: ShareLink::SCOPE_SNAPSHOT, rendered_document_id: doc.id,
      render_as_user_id: @jsmith.id, public_link: true,
      expires_at: 300.days.from_now
    )
    puts "P9 link_valid=#{link.persisted?} link_expires=#{link.expires_at} doc_expires=#{doc.expires_at}"
    puts "P9 link outlives its document by #{((link.expires_at - doc.expires_at) / 86_400).round} days"

    # the document is expired but not purged: does the endpoint still serve it?
    doc.update_columns(expires_at: 1.hour.ago)
    get "/reporter/s/#{token}"
    puts "P9 serving an EXPIRED document -> status=#{response.status} len=#{response.body.bytesize}"
    puts "P9 Document.expired scope includes it = #{RedmineReporterDashboards::Document.expired.exists?(doc.id)}"
    assert true
  end

  # ---------------------------------------------------------------- P10 audit growth

  def test_p10_a_revoked_link_still_writes_an_audit_row_per_request
    result = capture_with(BinaryEngine)
    link, token = mint(result.document)
    link.revoke!

    before = ShareLinkAccess.count
    20.times { get "/reporter/s/#{token}", headers: { 'HTTP_USER_AGENT' => 'X' * 4000 } }
    after = ShareLinkAccess.count
    puts "P10 rows_written_by_20_requests_on_a_REVOKED_link=#{after - before}"
    puts "P10 stored_user_agent_length=#{ShareLinkAccess.order(id: :desc).first.user_agent.length}"
    assert true
  end

  # ---------------------------------------------------------------- P11 capture raises

  def test_p11_an_out_of_bound_expiry_raises_instead_of_answering_a_result
    begin
      r = capture_with(BinaryEngine, expires_at: 2.years.from_now)
      puts "P11 expires_at=2y -> ok=#{r.ok?} code=#{r.code}"
    rescue StandardError => e
      puts "P11 expires_at=2y -> RAISED #{e.class}: #{e.message[0, 160]}"
    end

    begin
      r = capture_with(BinaryEngine, expires_at: nil)
      puts "P11 expires_at=nil -> ok=#{r.ok?} code=#{r.code}"
    rescue StandardError => e
      puts "P11 expires_at=nil -> RAISED #{e.class}: #{e.message[0, 160]}"
    end

    begin
      r = capture_with(BinaryEngine, expires_at: 1.hour.ago)
      puts "P11 expires_at=past -> ok=#{r.ok?} code=#{r.code} doc_expired=#{r.ok? && r.document.expired?}"
    rescue StandardError => e
      puts "P11 expires_at=past -> RAISED #{e.class}: #{e.message[0, 160]}"
    end
    assert true
  end

  # ---------------------------------------------------------------- P12 cross-project

  def test_p12_the_document_can_be_filed_under_a_project_the_template_is_not_in
    other = Project.find(2)
    result = capture_with(BinaryEngine, project: other)
    puts "P12 ok=#{result.ok?} code=#{result.code}"
    if result.ok?
      puts "P12 template.project_id=#{@template.project_id} document.project_id=#{result.document.project_id}"
    end
    assert true
  end

  # ---------------------------------------------------------------- P13 verb surface

  def test_p13_which_verbs_reach_the_endpoint
    result = capture_with(BinaryEngine)
    _l, token = mint(result.document, max_uses: nil)
    %i[post put patch delete].each do |verb|
      begin
        send(verb, "/reporter/s/#{token}")
        puts "P13 #{verb.upcase} -> #{response.status}"
      rescue StandardError => e
        puts "P13 #{verb.upcase} -> RAISED #{e.class}: #{e.message[0, 80]}"
      end
    end
    assert true
  end
end
