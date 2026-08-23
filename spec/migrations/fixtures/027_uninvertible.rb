class Uninvertible < ActiveRecord::Migration[6.1]
  def change
    change_column :reporter_dashboards_templates, :name, :text
    remove_column :reporter_dashboards_templates, :description
    drop_table :reporter_project_tabs
  end
end
