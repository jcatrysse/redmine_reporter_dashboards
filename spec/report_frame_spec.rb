# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/report_frame'

# T-41 — the frame's Content-Security-Policy, and §Findings **M-2** is what it is for.
#
# The policy and the asset binding disagreed, and the disagreement was silent. Every
# report that references a subresource reaches this frame with that subresource EMBEDDED:
# `Assets::Resolver` either restructures the element (`<script src=…>` becomes
# `<script>…</script>`) or, when it cannot — a file above `inline_max_bytes`, which
# Mermaid's 3.5 MB always is — rewrites the attribute to a `data:` URI. `script-src
# 'unsafe-inline'` does not permit a `data:` URL, so the browser refused the plugin's own
# vendored library and the reader saw the diagram's source as text. Measured on a real
# install: a 4.7 MB srcdoc, entirely refused.
#
# There is no behavioural expression of "the browser accepted it" in a DB-less suite, so
# what is asserted here is the policy's SHAPE: the three sources the binding needs, and —
# more importantly — the four it must never grow. A CSP is one string, and a string is
# what a later session widens by one word without anybody noticing.
RSpec.describe RedmineReporterDashboards::ReportFrame do
  # A METHOD AND NOT A CONSTANT: a constant assigned inside `RSpec.describe` lands on
  # `Object`, and `POLICY` is about as general a name as could be put there.
  def policy
    RedmineReporterDashboards::ReportFrame::CONTENT_SECURITY_POLICY
  end

  def directive(name)
    policy.split(';').map(&:strip).find { |part| part.start_with?("#{name} ") }.to_s
  end

  it 'permits the two forms the asset binding can produce, on both executable types' do
    # Restructured: an inline element. Not restructurable: a `data:` URL.
    %w[script-src style-src].each do |name|
      expect(directive(name)).to include("'unsafe-inline'")
      expect(directive(name)).to include('data:')
    end
    expect(directive('img-src')).to include('data:')
  end

  # THE HALF THAT MATTERS MORE. `data:` is a second spelling of a capability an author
  # already has, because `'unsafe-inline'` is here by design (INV-9). A HOST source is
  # not: it would let a template pull code from wherever that host serves, and it is not
  # needed, because the binding has already embedded everything the document uses.
  it 'permits no origin, no host and no network at all' do
    expect(policy).to start_with("default-src 'none'")
    expect(policy).not_to include("'self'")
    expect(policy).not_to include('http')
    expect(policy).not_to include('*')
    expect(policy).not_to include('connect-src')
    expect(policy).not_to include("'unsafe-eval'")
  end

  # THE FALLBACK CHAIN, CLOSED. CSP 3 resolves a worker through
  # `worker-src → child-src → script-src`, so `data:` on `script-src` silently made
  # `new Worker('data:text/javascript,…')` legal — the one capability the `data:` widening
  # genuinely added, found by an independent review. `child-src` is named too because it is
  # what a CSP 2 engine reads, and this document is parsed by whatever draws it.
  it 'stops a worker inheriting script-src through the fallback chain' do
    expect(directive('worker-src')).to eq("worker-src 'none'")
    expect(directive('child-src')).to eq("child-src 'none'")
  end

  # The one token that turns the sandbox into a decoration. Asserted here rather than
  # trusted to the comment beside it.
  it 'sandboxes with allow-scripts and nothing else' do
    expect(RedmineReporterDashboards::ReportFrame::SANDBOX).to eq('allow-scripts')
  end

  it 'puts the policy in the document it wraps' do
    document = described_class.document('<p>hello</p>')

    expect(document).to include('http-equiv="Content-Security-Policy"')
    expect(document).to include(policy)
    expect(document).to include('<p>hello</p>')
  end
end
