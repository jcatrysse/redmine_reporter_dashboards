class DataStatement < ActiveRecord::Migration[6.1]
  def change
    create_table(:x) { |t| t.string :a }
    update_all("content = ''")
  end
end
