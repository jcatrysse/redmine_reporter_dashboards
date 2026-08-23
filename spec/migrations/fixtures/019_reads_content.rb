class ReadsContent < ActiveRecord::Migration[6.1]
  def change
    select_values("SELECT content FROM reporter_dashboards_templates").each { |c| c }
  end
end
