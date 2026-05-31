# frozen_string_literal: true

class SqlStatsController < ApplicationController
  before_action :require_login

  def monthly_flow
    project = Project.visible.find_by!(identifier: params[:project_id])

    unless User.current.allowed_to?(:view_issues, project)
      return render json: { error: 'Forbidden' }, status: :forbidden
    end

    raw    = params[:months].to_i
    months = raw.positive? ? [raw, 24].min : 6

    result = SqlAggregation::QueryAggregator.aggregate(
      Issue.where(project_id: project.id),
      period:  'month',
      periods: months
    )

    render json: {
      labels:       result['labels'],
      created:      result['created'],
      closed:       result['closed'],
      open_now:     result['open_now'],
      total:        result['total'],
      project:      project.identifier,
      months:       months,
      generated_at: Time.now.iso8601
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Project not found' }, status: :not_found
  end
end
