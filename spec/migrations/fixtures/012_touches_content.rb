class TouchesContent < ActiveRecord::Migration[6.1]
  def change
    RedmineReporterDashboards::Template.update_all(content: "x")
  end
end
