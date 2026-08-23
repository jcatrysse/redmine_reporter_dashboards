# frozen_string_literal: true

# Input nobody wrote on purpose — and the two outcomes that are both acceptable.
#
# A template author with a runaway loop, a custom field holding 200 000 characters
# without a space in it, markup nested 3 000 deep, tags that never close. An engine may
# render this, and an engine may refuse it with a typed Failure. What it may not do is
# hang, crash the caller, or hand back something that is neither arm of `Result` — and
# those are precisely the three things a report generator does at 3 a.m. under a
# scheduler with nobody watching.
#
# `allow_failure!` is what lets one fixture assert that. Pinning a single outcome here
# would encode one engine's behaviour as the contract, and the contract is deliberately
# weaker than that: bounded, typed, and never silent.
RedmineReporterDashboards::Conformance.fixture(
  'F-19-pathological-input', 'malformed and oversized input is bounded, either way', dir: __dir__
) do |f|
  f.request!(page_size: 'A4', timeout_ms: 20_000)
  f.readiness!(timeout_ms: 6_000, client_timeout_ms: 4_000)
  f.allow_failure!

  f.expand! do |html|
    nested = ('<div>' * 3_000) + 'DEEP-MARKER' + ('</div>' * 3_000)
    long_word = 'x' * 200_000
    html.sub('<!--NESTED-->', nested).sub('<!--LONGWORD-->', long_word)
  end

  f.check('it came back at all, inside the timeout') do |v|
    v.expect_between(v.duration_ms, 0, 25_000, 'render duration (ms)')
  end

  # Both arms, stated as one assertion: whatever came back is one of the two things
  # `Result` can be, and if it is a refusal it is a refusal with a name.
  f.check('the answer is a Result, and a refusal is typed') do |v|
    is_result = RedmineReporterDashboards::Render::Result.result?(v.result)
    v.expect_true(is_result, "expected a Success or a Failure, got #{v.result.class}")
    next if v.result.success?

    v.expect_true(RedmineReporterDashboards::Render::Failure::CODES.include?(v.result.code),
                  "#{v.result.code.inspect} is not in the closed failure-code set")
  end

  f.check('a document, if there is one, is a real PDF of bounded size') do |v|
    next unless v.result.success?

    v.expect_between(v.byte_size, 1_025, 32 * 1024 * 1024, 'PDF byte size')
    v.expect_between(v.page_count, 1, 5_000, 'page count')
  end
end
