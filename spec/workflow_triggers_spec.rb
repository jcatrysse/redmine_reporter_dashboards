# frozen_string_literal: true

require 'yaml'
require_relative 'spec_helper'

# Jan's decision of 2026-10-07, for every GEOxyz plugin: GitHub Actions run MANUALLY only
# (`workflow_dispatch`). No push, pull_request or schedule trigger: a workflow starts when a
# person starts it. Asserted on every workflow file, so a trigger added back later fails here
# rather than spending CI minutes unnoticed.
RSpec.describe 'GitHub Actions triggers' do
  workflows = Dir[File.expand_path('../.github/workflows/*.{yml,yaml}', __dir__)].sort

  it 'finds the workflow files it is meant to check' do
    expect(workflows.map { |f| File.basename(f) }).to include('ci.yml', 'gotenberg-cve.yml')
  end

  workflows.each do |file|
    it "#{File.basename(file)} is started by workflow_dispatch only" do
      doc = YAML.safe_load(File.read(file), aliases: true)
      # YAML 1.1 reads a bare `on:` key as the boolean true, which is what Psych does.
      triggers = doc.key?('on') ? doc['on'] : doc[true]
      names = triggers.is_a?(Hash) ? triggers.keys.map(&:to_s) : Array(triggers).map(&:to_s)

      expect(names).to eq(['workflow_dispatch'])
    end
  end
end
