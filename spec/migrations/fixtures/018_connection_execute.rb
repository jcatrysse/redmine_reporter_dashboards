class ConnectionExecute < ActiveRecord::Migration[6.1]
  def change
    ActiveRecord::Base.connection.execute("DELETE FROM reporter_dashboards_templates")
  end
end
