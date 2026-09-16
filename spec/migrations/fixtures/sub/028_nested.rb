class Nested < ActiveRecord::Migration[6.1]
  def change
    execute "DROP TABLE reporter_project_tabs"
  end
end
