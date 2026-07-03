# frozen_string_literal: true

# Project dashboard
get 'projects/:project_id/reporter', to: 'reporter_project_pages#show', as: 'project_reporter_page'
post 'projects/:project_id/reporter', to: 'reporter_project_pages#update_page'
post 'projects/:project_id/reporter/add_block', to: 'reporter_project_pages#add_block', as: 'add_reporter_project_block'
post 'projects/:project_id/reporter/remove_block', to: 'reporter_project_pages#remove_block', as: 'remove_reporter_project_block'
post 'projects/:project_id/reporter/move_block', to: 'reporter_project_pages#move_block', as: 'move_reporter_project_block'
get 'projects/:project_id/reporter/report_pdf', to: 'reporter_project_pages#report_pdf', as: 'report_pdf_reporter_project_page'

post 'projects/:project_id/reporter/tabs', to: 'reporter_project_tabs#create', as: 'create_reporter_project_tab'
match 'projects/:project_id/reporter/tabs/:id', to: 'reporter_project_tabs#update', via: :patch, as: 'update_reporter_project_tab'
match 'projects/:project_id/reporter/tabs/:id', to: 'reporter_project_tabs#destroy', via: :delete, as: 'delete_reporter_project_tab'
post 'projects/:project_id/reporter/tabs/:id/order', to: 'reporter_project_tabs#order', as: 'order_reporter_project_tab'

# SQL aggregation statistics JSON endpoint — no format default; the controller
# always renders JSON via render json: so no .json suffix needed, and omitting
# the default keeps params[:format] nil so Redmine's session auth is not bypassed.
get 'sql/stats/monthly_flow', to: 'sql_stats#monthly_flow', as: :sql_stats_monthly_flow
