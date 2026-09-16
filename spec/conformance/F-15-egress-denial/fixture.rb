# frozen_string_literal: true

# INV-8, asserted from the OUTSIDE.
#
# The document points four different subresource types at a socket the harness itself
# is listening on. The pass condition is not "the page reported an error" — a page can
# report an error about a connection the engine happily opened, and that is exactly the
# posture this invariant forbids. The pass condition is that NOTHING ARRIVED HERE.
#
# Four references rather than one because engines route them through different code:
# an `<img>`, a stylesheet `<link>`, an XHR and a `fetch`. An engine can deny three and
# allow the fourth, and one allowed subresource is all an SSRF needs.
#
# NEGATIVE-TESTED, per HANDOVER §1's rule that a gate is worthless until you have
# watched it fail: `spec/conformance/conformance_harness_spec.rb` drives this same
# listener with an engine that does NOT carry the egress flags and asserts the hits
# arrive. A check that has never been seen to fail is a check nobody has tested.
#
# This is defence in depth, not the primary control: under `asset_policy: :bundled` an
# absolute URL never reaches the engine at all, because `AssetResolver` refuses it
# first (T-33). This fixture is what stands behind that when it is wrong.
RedmineReporterDashboards::Conformance.fixture(
  'F-15-egress-denial', 'the engine reaches nothing on the network', dir: __dir__
) do |f|
  f.request!(page_size: 'A4')
  f.readiness!(timeout_ms: 4_000, client_timeout_ms: 3_000)

  f.check('not one subresource reached the listener') do |v|
    v.expect_equal(v.egress.hit_count, 0,
                   "connections the engine made to the harness's socket " \
                   "(#{v.egress.hits.inspect})")
  end

  f.check('the document rendered anyway, without the assets it could not have') do |v|
    v.expect_includes(v.flat_text, 'EGRESS-MARKER', 'body text')
  end
end
