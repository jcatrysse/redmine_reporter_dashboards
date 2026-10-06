# The owned Liquid layer's runtime dependency (ADR-004, technical-spec.md §4).
#
# Until now the plugin never loaded Liquid itself — it registered tags into whatever
# Liquid `redmine_reporter` had already loaded, which is precisely the coupling this
# plan exists to remove. A plugin that owns its Liquid layer has to declare the gem.
#
# The range is deliberately wide. §4 requires the layer to work on Liquid 4 AND 5,
# because an install that already has reporter has 4.x and must not be forced to
# upgrade, and the per-context resource-limit mechanism the execution policy is built
# on is verified identical on 4.0.4 and 5.13.0.
#
# BELOW 5.6 ON RUBY OLDER THAN 3.3 (Redmine 7 migration, measured 2026-10-06). Since 5.6.1
# Liquid calls StringScanner#peek_byte and declares strscan >= 3.1.1. On Ruby 3.2 (the newest
# Redmine 5.1 runs, and one 6.x allows) Bundler loads ERB, and with it the default strscan
# 3.0.5, before it puts the bundle's strscan on the load path; measured with Bundler 2.4.19
# (Ruby 3.2's own), 2.5.23 and 4.0.18, with vendor/bundle and with a system-wide strscan
# 3.1.8 alike. So EVERY template parse raised NoMethodError: on Redmine 5.1-stable-GEOxyz
# with Ruby 3.2.6 and Liquid 5.13/5.14, 71 unit tests and 275 of 373 spec_liquid examples
# failed, and no report renders. HANDOVER §"Running spec_liquid" records 5.5.x as working on
# Ruby 3.2. On Ruby 3.3+ (Redmine 7.0) 5.14.0 is measured working and is kept. RUBY_VERSION
# is the Ruby that runs `bundle install`, which is the Ruby that runs Redmine.
if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.3')
  gem 'liquid', '>= 4.0', '< 5.6'
else
  gem 'liquid', '>= 4.0', '< 6.0'
end

group :test do
  gem 'rspec-rails'
  gem 'rails-controller-testing'
  # The SVG chart specs parse their output with REXML. Redmine 5.1's Gemfile declares
  # rexml; Redmine 7.0's no longer does, and since Ruby 3.0 it is a bundled gem that
  # Bundler hides unless a Gemfile names it. Guarded so 5.1 does not list it twice.
  gem 'rexml', require: false unless dependencies.any? { |d| d.name == 'rexml' }
end
