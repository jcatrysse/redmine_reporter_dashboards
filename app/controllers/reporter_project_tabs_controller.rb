# frozen_string_literal: true

class ReporterProjectTabsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :require_dashboard_module
  before_action :authorize
  before_action :require_manage_tabs
  before_action :find_tab, only: [:update, :destroy, :order]

  def create
    @tab = @project.reporter_project_tabs.new(tab_params)
    if @tab.save
      redirect_to project_reporter_page_path(@project, tab: @tab.id)
    else
      flash[:error] = @tab.errors.full_messages.join(', ')
      redirect_to project_reporter_page_path(@project, tab: next_tab_id, anchor: 'reporter-dashboard-settings')
    end
  end

  def update
    if @tab.update(tab_params)
      redirect_to project_reporter_page_path(@project, tab: @tab.id)
    else
      flash[:error] = @tab.errors.full_messages.join(', ')
      redirect_to project_reporter_page_path(@project, tab: @tab.id, anchor: 'reporter-dashboard-settings')
    end
  end

  def destroy
    if @project.reporter_project_tabs.count <= 1
      flash[:error] = l(:label_reporter_dashboard_tabs_required)
      redirect_to project_reporter_page_path(@project, tab: @tab.id, anchor: 'reporter-dashboard-settings')
    else
      next_id = @project.reporter_project_tabs.where.not(id: @tab.id).order(:position).first&.id
      @tab.destroy
      redirect_to project_reporter_page_path(@project, tab: next_id, anchor: 'reporter-dashboard-settings')
    end
  end

  def order
    direction = params[:direction]
    case direction
    when 'up', 'left'
      @tab.move_higher
    when 'down', 'right'
      @tab.move_lower
    end
    redirect_to project_reporter_page_path(@project, tab: @tab.id, anchor: 'reporter-dashboard-settings')
  end

  private

  def find_tab
    @tab = @project.reporter_project_tabs.find(params[:id])
  end

  def require_dashboard_module
    render_404 unless @project.module_enabled?(:reporter_project_dashboards)
  end

  def require_manage_tabs
    deny_access unless User.current.allowed_to?(:manage_reporter_project_tabs, @project)
  end

  def tab_params
    params.require(:reporter_project_tab).permit(:title, :description)
  end

  def next_tab_id
    @tab&.id || @project.reporter_project_tabs.order(:position).first&.id
  end
end
