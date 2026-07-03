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

  def update_page
    block_settings = params[:settings].is_a?(ActionController::Parameters) ? params[:settings] : {}
    @updated_blocks = []

    block_settings.each do |block, settings|
      next unless settings.respond_to?(:to_unsafe_hash)
      next unless RedmineReporterDashboards::ProjectPage.find_block(block)

      @tab.update_block_settings(block, settings.to_unsafe_hash)
      @updated_blocks << block
    end
    @tab.save
  end

  def add_block
    @block = params[:block]
    if @tab.add_block(@block)
      @tab.save
      redirect_to project_reporter_page_path(@project, tab: @tab.id)
    else
      render_error status: 422
    end
  end

  def remove_block
    @block = params[:block]
    @tab.remove_block(@block)
    @tab.save
    redirect_to project_reporter_page_path(@project, tab: @tab.id)
  end

  def move_block
    @tab.move_block(params[:block], params[:direction])
    @tab.save
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

    query, report_template, collection = reporter_report_for(block, tab.block_settings(block))
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

  # Resolve the query, report template and AR collection for a report widget,
  # mirroring the two report block partials (and the helper's permission guard:
  # spent-time reports require the time-entries permission).
  def reporter_report_for(block, settings)
    case block.to_s.sub(/__\d+\z/, '')
    when 'report_by_issues'
      query = IssueQuery.visible.where(project_id: [nil, @project.id]).find_by(id: settings[:query_id])
      template = IssueListReportTemplate.find_by(id: settings[:report_template_id])
      [query, template, query&.base_scope]
    when 'report_by_spent_time'
      return [nil, nil, nil] unless User.current.allowed_to?(:view_time_entries, @project, global: true)

      query = TimeEntryQuery.visible.where(project_id: [nil, @project.id]).find_by(id: settings[:query_id])
      template = TimeEntriesReportTemplate.find_by(id: settings[:report_template_id])
      [query, template, query&.results_scope]
    else
      [nil, nil, nil]
    end
  end

  def require_dashboard_module
    return if @project.module_enabled?(:reporter_project_dashboards)

    render_404
  end

  def find_tabs
    ensure_default_tab
    @tabs = @project.reporter_project_tabs.order(:position)
  end

  def ensure_default_tab
    return if @project.reporter_project_tabs.exists?

    @project.reporter_project_tabs.create!(title: l(:label_reporter_default_dashboard_tab))
  end

  def find_tab
    @tab = @tabs.find_by(id: params[:tab]) || @tabs.first
    render_404 unless @tab
  end

  def require_manage_page
    return if current_user_admin?

    deny_access unless User.current.allowed_to?(:manage_reporter_project_page, @project)
  end

  def current_user_admin?
    User.current.admin?
  end
end
