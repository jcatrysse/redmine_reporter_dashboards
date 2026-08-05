# frozen_string_literal: true

# The same never-signalling page as F-11, with `strict` set — and the opposite outcome.
#
# `strict` is for the caller who would rather have nothing than something incomplete:
# a scheduled report mailed to a customer, where a silently chart-less PDF is worse
# than a failure somebody has to look at. It inverts the default, so it has to be
# tested against the same document that produces a Success without it. Two fixtures
# over one page is the only way to show that the flag is what moved the outcome.
RedmineReporterDashboards::Conformance.fixture(
  'F-12-readiness-strict', 'strict turns the same timeout into a typed failure', dir: __dir__
) do |f|
  f.requires!(:javascript)
  f.request!(page_size: 'A4')
  f.readiness!(timeout_ms: 3_000, client_timeout_ms: 2_900, strict: true)
  f.expect_failure!(:readiness_timeout)

  f.check('the failure is typed, and carries the correlation id') do |v|
    v.expect_failure_code(:readiness_timeout)
    v.expect_true(!v.result.correlation_id.empty?, 'the failure carries a correlation id')
  end

  # INV-5, at the point it is easiest to breach: there must be no bytes to attach.
  # `Failure#bytes` raises rather than answering nil, because a nil that reaches
  # `attachment.write` is a zero-byte PDF in somebody's inbox.
  f.check('there is nothing that could be attached') do |v|
    raised = begin
      v.result.bytes
      false
    rescue NoMethodError
      true
    end
    v.expect_true(raised, 'Failure#bytes must raise rather than answer nil')
  end
end
