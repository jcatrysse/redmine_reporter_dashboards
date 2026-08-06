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
gem 'liquid', '>= 4.0', '< 6.0'

group :test do
  gem 'rspec-rails'
  gem 'rails-controller-testing'
end
