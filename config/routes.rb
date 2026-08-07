# frozen_string_literal: true

# Project dashboard
get 'projects/:project_id/reporter', to: 'reporter_project_pages#show', as: 'project_reporter_page'
# Verbs match what each action does to the dashboard: update_page and move_block
# change an existing tab, remove_block deletes from it, add_block creates a widget.
# They were all POST, which meant a delete and two updates were indistinguishable
# from a create to anything reading the access log or a proxy's method rules.
patch 'projects/:project_id/reporter', to: 'reporter_project_pages#update_page'
post 'projects/:project_id/reporter/add_block', to: 'reporter_project_pages#add_block', as: 'add_reporter_project_block'
delete 'projects/:project_id/reporter/remove_block', to: 'reporter_project_pages#remove_block', as: 'remove_reporter_project_block'
patch 'projects/:project_id/reporter/move_block', to: 'reporter_project_pages#move_block', as: 'move_reporter_project_block'
get 'projects/:project_id/reporter/report_pdf', to: 'reporter_project_pages#report_pdf', as: 'report_pdf_reporter_project_page'

post 'projects/:project_id/reporter/tabs', to: 'reporter_project_tabs#create', as: 'create_reporter_project_tab'
match 'projects/:project_id/reporter/tabs/:id', to: 'reporter_project_tabs#update', via: :patch, as: 'update_reporter_project_tab'
match 'projects/:project_id/reporter/tabs/:id', to: 'reporter_project_tabs#destroy', via: :delete, as: 'delete_reporter_project_tab'
post 'projects/:project_id/reporter/tabs/:id/order', to: 'reporter_project_tabs#order', as: 'order_reporter_project_tab'

# T-23 — report templates. One controller for CRUD, preview and exchange.
#
# EVERY LINE ROUTES WITH THE `to:` STRING FORM, and that is a requirement rather than a
# style:
# `spec/permissions/permission_map_spec.rb` reads this file to check that every ROUTED
# action is permission-mapped, and it FAILS on a line it cannot parse rather than
# skipping it. A `resources` block would hide six endpoints from that check.
#
# `new` is declared before `:id` so that `templates/new` is not resolved as a template
# whose id is "new". `preview` and `import` are POST for the same reason `#run` on the
# preflight is: both execute something.
#
# `#document` IS A GET AND THAT IS DELIBERATE, though it does start a render engine. The
# preflight's POST exists because an installation-wide diagnostic that spawns a browser
# must not be fireable by a crawler; a report download is the reader's own intent, is
# what `view_reporter_dashboards_reports` authorises, and has to be a link in a page.
# `Render::BatchGuard`'s cap and deadline are what bound it.
get 'projects/:project_id/reporter/templates', to: 'reporter_dashboards/templates#index', as: 'project_reporter_templates'
get 'projects/:project_id/reporter/templates/new', to: 'reporter_dashboards/templates#new', as: 'new_project_reporter_template'
post 'projects/:project_id/reporter/templates', to: 'reporter_dashboards/templates#create'
post 'projects/:project_id/reporter/templates/preview', to: 'reporter_dashboards/templates#preview', as: 'preview_project_reporter_templates'
post 'projects/:project_id/reporter/templates/import', to: 'reporter_dashboards/templates#import', as: 'import_project_reporter_templates'
get 'projects/:project_id/reporter/templates/:id', to: 'reporter_dashboards/templates#show', as: 'project_reporter_template'
get 'projects/:project_id/reporter/templates/:id/edit', to: 'reporter_dashboards/templates#edit', as: 'edit_project_reporter_template'
patch 'projects/:project_id/reporter/templates/:id', to: 'reporter_dashboards/templates#update'
delete 'projects/:project_id/reporter/templates/:id', to: 'reporter_dashboards/templates#destroy'
get 'projects/:project_id/reporter/templates/:id/document', to: 'reporter_dashboards/templates#document', as: 'document_project_reporter_template'
get 'projects/:project_id/reporter/templates/:id/export', to: 'reporter_dashboards/templates#export', as: 'export_project_reporter_template'
# BOTH VERBS, AND THE SECOND ONE IS NOT DECORATION. The editor's Preview button lives on
# the SAME form as Save, so it can carry the author's unsaved content — and that form is a
# PATCH, which Rails implements as a POST with a hidden `_method=patch` field. A submit
# button's `formmethod="post"` changes the HTTP verb but not the form body, so
# `Rack::MethodOverride` (in Rails' default stack) reads the hidden field and rewrites the
# request to PATCH before routing. With only the POST route declared, every press of
# Preview on a saved template was a 404 — for every user, always. Found by the independent
# review of T-23; `test/integration/reporter_dashboards_preview_flow_test.rb` submits the
# form the way a browser does, because a controller test that calls `post :preview`
# directly cannot see this at all.
match 'projects/:project_id/reporter/templates/:id/preview', to: 'reporter_dashboards/templates#preview', via: [:post, :patch], as: 'preview_project_reporter_template'

# T-14 — the render preflight, admin only (the controller requires it per action).
# GET shows the page and runs NOTHING; POST is what starts a browser. A GET with an
# engine launch behind it is a GET a crawler or a prefetching proxy can fire.
get 'admin/reporter_dashboards/preflight', to: 'reporter_preflight#show', as: 'reporter_preflight'
post 'admin/reporter_dashboards/preflight', to: 'reporter_preflight#run', as: 'run_reporter_preflight'

# SQL aggregation statistics JSON endpoint — no format default; the controller
# always renders JSON via render json: so no .json suffix needed, and omitting
# the default keeps params[:format] nil so Redmine's session auth is not bypassed.
get 'sql/stats/monthly_flow', to: 'sql_stats#monthly_flow', as: :sql_stats_monthly_flow
