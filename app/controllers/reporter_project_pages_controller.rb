# frozen_string_literal: true

class ReporterProjectPagesController < ApplicationController
  menu_item :reporter_project_page

  before_action :find_project_by_project_id
  before_action :require_dashboard_module
  before_action :authorize, unless: :current_user_admin?
  before_action :find_tabs
  before_action :find_tab, only: [:show, :update_page, :add_block, :remove_block, :move_block]
  before_action :require_manage_page, only: [:update_page, :add_block, :remove_block, :move_block]

  helper :issues
  helper :queries
  helper :projects
  helper :my
  helper :activities
  helper :reporter_project_pages

  def show
    @rows = @tab.block_rows
  end

  # Settings go through BlockSettings.sanitize rather than to_unsafe_hash: the
  # settings column is YAML-serialized and read on every dashboard render, so what
  # goes in has to be typed and bounded, not merely posted by someone with
  # :manage_reporter_project_page. Widgets contributed by other plugins keep working
  # — see the two tiers documented there.
  def update_page
    block_settings = params[:settings].is_a?(ActionController::Parameters) ? params[:settings] : {}
    @updated_blocks = []

    block_settings.each do |block, settings|
      next unless RedmineReporterDashboards::ProjectPage.find_block(block)

      updates = RedmineReporterDashboards::BlockSettings.sanitize(settings, block: block)
      next if updates.empty?

      @tab.update_block_settings(block, updates)
      @updated_blocks << block
    end

    # All four write actions used to ignore what save answered, so a rejected write
    # — a validation failure, a serialized column over its size limit — looked
    # exactly like a successful one: the widget redrew from the in-memory object the
    # user had just changed, and the next page load quietly showed the old settings.
    @save_failed = !@tab.save
    report_save_failure if @save_failed
  end

  def add_block
    @block = params[:block]
    return render_error status: 422 unless @tab.add_block(@block)

    report_save_failure unless @tab.save
    redirect_to project_reporter_page_path(@project, tab: @tab.id)
  end

  def remove_block
    @block = params[:block]
    @tab.remove_block(@block)
    report_save_failure unless @tab.save
    redirect_to project_reporter_page_path(@project, tab: @tab.id)
  end

  def move_block
    @tab.move_block(params[:block], params[:direction])
    report_save_failure unless @tab.save
    redirect_to project_reporter_page_path(@project, tab: @tab.id)
  end

  # Render the same report a dashboard widget shows, as a PDF, reusing the
  # Reporter plugin's own generation (generate_reports + Report#to_pdf) and the
  # 'reports' PDF layout. Tied to the configured widget (tab + block) rather than
  # arbitrary query/template ids, so it exposes nothing the widget doesn't.
  def report_pdf
    tab   = @tabs.find_by(id: params[:tab])
    block = params[:block].to_s
    return render_404 unless tab && RedmineReporterDashboards::ProjectPage.find_block(block)

    # Resolving the widget means touching reporter's report template classes, which on
    # Redmine 7.0 (Rails 8.1) cannot be loaded at all — see the note in the README. A
    # dependency that will not load should produce the same clean error as a
    # wkhtmltopdf failure, not a stack trace.
    begin
      query, report_template, collection = reporter_report_for(block, tab.block_settings(block))
    rescue StandardError => e
      Rails.logger.error("[reporter_dashboards] could not resolve the report widget " \
                         "#{block.inspect} in project #{@project.id}: #{e.class}: #{e.message}")
      return render_error(message: l(:error_reporter_pdf_generation_failed), status: 500)
    end

    return render_404 unless query && report_template

    report = report_template.generate_reports(collection, query.id).first
    return render_404 unless report

    apply_layout!(report.content, 'reports')
    # PDF chart rendering (polyfills) + wait-for-charts delay are handled centrally
    # in Report#to_pdf (report_patch), so every Reporter PDF path benefits.
    pdf = report.to_pdf
    # to_pdf returns nil when wkhtmltopdf fails (missing binary, render error);
    # send_data would raise on nil, so surface a clean error instead of a 500.
    return render_error(message: l(:error_reporter_pdf_generation_failed), status: 500) if pdf.blank?

    send_data pdf,
              type: 'application/pdf',
              filename: report.filename,
              disposition: params[:download].present? ? 'attachment' : 'inline'
  end

  private

  # flash, not flash.now: the three redirecting actions need it on the next request,
  # and update_page's JS reloads the page so Redmine's own flash renders the message
  # rather than this plugin inventing an error area of its own.
  #
  # The plugin's sentence comes first and the record's own messages after it, so the
  # user always learns that nothing was saved even when the failure carries no
  # validation message.
  def report_save_failure
    Rails.logger.warn("[reporter_dashboards] tab #{@tab.id} did not save: " \
                      "#{@tab.errors.full_messages.join(', ').presence || 'no error message'}")
    flash[:error] = ([l(:error_reporter_dashboard_save_failed)] + @tab.errors.full_messages)
                    .join(' ')
  end

  # Resolve the query, report template and AR collection for a report widget,
  # mirroring the two report block partials (and the helper's permission guard:
  # spent-time reports require the time-entries permission).
  #
  # The report template is scoped to in_project_and_global(@project), the same scope
  # the settings picker offers and the same one the block partials now resolve
  # through. The PDF export must not be a way to render a template the widget itself
  # would refuse — the export exists precisely to show "the same report the widget
  # shows", so its resolution has to be identical.
  def reporter_report_for(block, settings)
    case block.to_s.sub(/__\d+\z/, '')
    when 'report_by_issues'
      query = IssueQuery.visible.where(project_id: [nil, @project.id]).find_by(id: settings[:query_id])
      template = IssueListReportTemplate.in_project_and_global(@project)
                                        .find_by(id: settings[:report_template_id])
      [query, template, query&.base_scope]
    when 'report_by_spent_time'
      return [nil, nil, nil] unless User.current.allowed_to?(:view_time_entries, @project, global: true)

      query = TimeEntryQuery.visible.where(project_id: [nil, @project.id]).find_by(id: settings[:query_id])
      template = TimeEntriesReportTemplate.in_project_and_global(@project)
                                          .find_by(id: settings[:report_template_id])
      [query, template, query&.results_scope]
    else
      [nil, nil, nil]
    end
  end

  def require_dashboard_module
    return if @project.module_enabled?(:reporter_project_dashboards)

    render_404
  end

  # Actions that need somewhere to write. Everything else — show, report_pdf — is a
  # read, and a read must not INSERT.
  WRITING_ACTIONS = %w[update_page add_block remove_block move_block].freeze

  def find_tabs
    @tabs = @project.reporter_project_tabs.order(:position)
  end

  # The default tab used to be created from find_tabs, which runs before `show` too,
  # so a plain page view wrote to the database: a crawler or a monitoring probe
  # created rows, the request failed outright against a read-only replica, and two
  # simultaneous first visits each passed the `exists?` check and created a tab.
  #
  # Now `show` renders an UNSAVED default tab — an empty dashboard, with the widget
  # picker and the "add tab" control both working — and the row is created by the
  # first action that actually writes. That also means the tab is named in the
  # language of a user who is able to rename it, instead of in whatever language the
  # first visitor happened to be using.
  def find_tab
    @tab = @tabs.find_by(id: params[:tab]) || @tabs.first
    @tab ||= WRITING_ACTIONS.include?(action_name) ? create_default_tab : unsaved_default_tab
    render_404 unless @tab
  end

  # Serialized on the project row, because `exists?` followed by `create!` is a race:
  # two concurrent first writes would both see no tab and create one each. One extra
  # statement, once per project, and only while the project has no tab at all.
  def create_default_tab
    @project.with_lock do
      @project.reporter_project_tabs.order(:position).first ||
        @project.reporter_project_tabs.create!(title: l(:label_reporter_default_dashboard_tab))
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[reporter_dashboards] could not create the default dashboard tab for " \
                      "project #{@project.id}: #{e.class}: #{e.message}")
    nil
  end

  # Built directly rather than through the association, so an unsaved record never
  # lands in @project.reporter_project_tabs' loaded target.
  def unsaved_default_tab
    ReporterProjectTab.new(project: @project, title: l(:label_reporter_default_dashboard_tab))
  end

  def require_manage_page
    return if current_user_admin?

    deny_access unless User.current.allowed_to?(:manage_reporter_project_page, @project)
  end

  def current_user_admin?
    User.current.admin?
  end
end
