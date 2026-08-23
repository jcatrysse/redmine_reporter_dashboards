class ConnDelete < ActiveRecord::Migration[6.1]
  def change
    create_table(:y) { |t| t.string :a }
    connection.delete("DELETE FROM reporter_dashboards_templates")
  end
end
