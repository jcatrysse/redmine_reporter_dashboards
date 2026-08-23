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
  # `include_all_helpers = false` (Redmine's `config/application.rb`), so a controller sees
  # its OWN helper and nothing else — HANDOVER §1 records a T-23 view that 500'd in
  # production for exactly this. The report widget renders through the same four helpers
  # the template editor's preview does — `reporter_report_frame`, `reporter_degradation_text`,
  # `reporter_time_entry_visibility_notice` and `reporter_diagnostic_headline` — and shares
  # its `_degradations` partial, so it declares that helper rather than growing a second copy
  # of any of them.
  helper 'reporter_dashboards/templates'

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

  # The widget's own report, as a PDF — this plugin's render path, not the base plugin's.
  #
  # It used to call `IssueListReportTemplate#generate_reports` and `Report#to_pdf`, both
  # owned by the base plugin, through a `reporter_report_for` that resolved the template a
  # SECOND time and had already drifted once (its own comment recorded the fix). There is
  # one resolution now, `WidgetReport`, and the export differs from the widget in exactly
  # one argument: `pdf: true`. Tied to the configured widget (tab + block) rather than to
  # arbitrary query/template ids, so it still exposes nothing the widget does not.
  #
  # `WidgetReport.render` is what enforces visibility here — `Template.visible(actor)` —
  # which the base plugin's `in_project_and_global` never did. `before_action :authorize`
  # has already established that this actor may view this project's dashboard; the
  # template scope is what decides which report they may export.
  def report_pdf
    tab   = @tabs.find_by(id: params[:tab])
    block = params[:block].to_s
    return render_404 unless tab && RedmineReporterDashboards::ProjectPage.find_block(block)
    return render_404 unless report_block_permitted?(block)

    widget = RedmineReporterDashboards::WidgetReport.render(
      project: @project, actor: User.current, block: block,
      settings: tab.block_settings(block), pdf: true, logger: Rails.logger
    )
    # NOT CONFIGURED IS NOT AN ERROR. A widget whose settings name no resolvable template
    # has nothing to export, and the page it sits on offers the settings form instead.
    return render_404 if widget.nil?

    send_report_pdf(widget)
  end

  private

  # A PDF export is a document, so the two states that are a PANEL on a page have to
  # become an HTTP answer here — and neither of them may become the document itself
  # (INV-5: the base plugin returned the exception message AS the PDF bytes).
  #
  # 422 for a refusal and 500 for a failure, the same split
  # `ReporterDashboards::TemplatesController#outcome_status` makes, because a cap refusal
  # is a correct answer to an unreasonable request and paging an operator for it is what
  # T-15 exists to stop.
  REPORT_PDF_REFUSAL_ORIGINS = %i[batch assets].freeze

  def send_report_pdf(widget)
    outcome = widget.outcome
    diagnostic = outcome.diagnostic

    if diagnostic
      Rails.logger.error(
        "[reporter_dashboards] the report PDF for template #{widget.template.id} in " \
        "project #{@project.id} failed: #{diagnostic.origin}/#{diagnostic.code} " \
        "correlation_id=#{diagnostic.correlation_id}"
      )
      status = REPORT_PDF_REFUSAL_ORIGINS.include?(diagnostic.origin) ? 422 : 500
      return render_error(message: l(:error_reporter_pdf_generation_failed), status: status)
    end

    document = outcome.documents.first
    # ZERO DOCUMENTS IS NOT A FILE, and `documents.first.bytes` on an empty batch is a
    # NoMethodError — a 500 for a request that merely had nothing to draw.
    return render_404 if document.nil?

    send_data document.bytes,
              type: 'application/pdf',
              filename: report_pdf_filename(widget.template),
              disposition: params[:download].present? ? 'attachment' : 'inline'
  end

  # The same rule the dashboard applies before rendering the widget (`M1` in
  # `ReporterProjectPagesHelper#render_reporter_project_block`): a spent-time report needs
  # the time-entries permission, which `authorize` does not cover because it grants the
  # DASHBOARD. Stated in one place and asked by both, so the export cannot outlive the
  # widget's own guard.
  def report_block_permitted?(block)
    return true unless RedmineReporterDashboards::ProjectPage.base_block_name(block) ==
                       'report_by_spent_time'

    User.current.allowed_to?(:view_time_entries, @project, global: true)
  end

  # Same shape as `TemplatesController#download_filename` and deliberately not shared with
  # it: that one is a private method of another controller, and reaching across for six
  # lines would couple two entry points that have no other relationship.
  def report_pdf_filename(template)
    stem = template.name.to_s.gsub(/[^0-9A-Za-z._-]+/, '_')[0, 100]
                        .gsub(/\A[_.]+|[_.]+\z/, '')
    stem = 'report' if stem.blank?
    "#{stem}.pdf"
  end

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
