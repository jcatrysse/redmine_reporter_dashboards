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

    # Issue.visible, not Issue.where(project_id:): :view_issues on the project is
    # not the whole story. Redmine also hides private issues and, per role,
    # whole trackers. Aggregating over the raw project scope would let a user who
    # may see *some* issues read totals, statuses and a time series covering the
    # ones they may not.
    result = SqlAggregation::QueryAggregator.aggregate(
      Issue.visible(User.current, project: project),
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
      generated_at: Time.current.iso8601
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Project not found' }, status: :not_found
  end
end
