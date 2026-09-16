class IfNotExists < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_project_tabs, if_not_exists: true do |t|
      t.string :title
    end
  end
end
