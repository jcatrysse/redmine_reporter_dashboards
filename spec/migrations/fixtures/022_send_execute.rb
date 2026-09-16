class SendExecute < ActiveRecord::Migration[6.1]
  def change
    c = connection
    c.update("UPDATE reporter_dashboards_templates SET content = ''")
    send(:execute, "DELETE FROM reporter_dashboards_templates")
  end
end
