class Executes < ActiveRecord::Migration[6.1]
  def change
    execute "ALTER TABLE x ADD COLUMN y int"
  end
end
