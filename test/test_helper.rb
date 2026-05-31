require File.expand_path(File.dirname(__FILE__) + '/../../../test/test_helper')

def redmine_reporter_dashboards_fixtures_directory
  Redmine::Plugin.find(:redmine_reporter_dashboards).directory + '/test/fixtures/'
end

def compatible_request(type, action, parameters = {})
  send(type, action, params: parameters)
end

def compatible_xhr_request(type, action, parameters = {})
  send(type, action, params: parameters, xhr: true)
end
