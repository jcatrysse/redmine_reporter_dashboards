# frozen_string_literal: true

class ReporterProjectPagesController < ApplicationController
  menu_item :reporter_project_page

  before_action :find_project_by_project_id
  before_action :require_dashboard_module
  before_action :authorize, unless: :current_user_admin?
  before_action :find_tabs
  before_action :find_tab, only: [:show, :update_page, :add_block, :remove_block, :order_blocks]
  before_action :require_manage_page, only: [:update_page, :add_block, :remove_block, :order_blocks]

  helper :issues
  helper :queries
  helper :projects
  helper :my
  helper :activities
  helper :reporter_project_pages

  def show
    @groups = RedmineReporterDashboards::ProjectPage.groups
    @blocks = @tab.block_layout
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
      respond_to do |format|
        format.html { redirect_to project_reporter_page_path(@project, tab: @tab.id) }
        format.js
      end
    else
      render_error status: 422
    end
  end

  def remove_block
    @block = params[:block]
    @tab.remove_block(@block)
    @tab.save
    respond_to do |format|
      format.html { redirect_to project_reporter_page_path(@project, tab: @tab.id) }
      format.js
    end
  end

  def order_blocks
    blocks = params[:blocks].is_a?(Array) ? params[:blocks] : []
    @tab.order_blocks(params[:group], blocks)
    @tab.save
    head :ok
  end

  private

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
