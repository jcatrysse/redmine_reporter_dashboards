# frozen_string_literal: true

# A refusal, and the shape of one.
#
# The base plugin's render path signals trouble by returning `e.message` AS THE
# DOCUMENT CONTENT: a recipient gets a green-looking mail with a broken report in it
# and nothing anywhere records a failure. INV-5 exists to make that unrepresentable,
# and a refusal is where it is easiest to lose — it is the path nobody looks at.
#
# The fixture asks the engine for a capability IT ITSELF says it does not have, chosen
# at run time from its own declaration rather than hard-coded, so the case keeps
# working as adapters gain capabilities. An engine that declares everything gets a skip
# with that as the reason, which is the honest answer: there is nothing to refuse.
#
# What T-12 can assert here is the render layer's half — typed code, no bytes, a
# correlation id. "No attachment and no journal row" is the SAME invariant one layer up
# and belongs to T-15, which owns the controller path; it is named here so the gap is
# visible rather than assumed covered.
RedmineReporterDashboards::Conformance.fixture(
  'F-16-failure-semantics', 'an unsupported capability is refused, in type', dir: __dir__
) do |f|
  f.request!(page_size: 'A4')
  f.expect_failure!(:capability_unsupported)

  f.request_for! do |engine|
    absent = RedmineReporterDashboards::Render::Capabilities::ALL - Array(engine.capabilities)
    if absent.empty?
      "#{engine.id} declares every capability in the vocabulary, so there is nothing " \
        'it can be asked to refuse'
    else
      # The first is enough, and taking the first of a sorted list keeps the fixture
      # deterministic across engines and runs.
      wanted = [absent.sort.first]
      { required_capabilities: wanted, essential_capabilities: wanted }
    end
  end

  f.check('the refusal is typed and names what was missing') do |v|
    v.expect_failure_code(:capability_unsupported)
    v.expect_true(v.result.message.length.positive?, 'the failure carries a message for a human')
    v.expect_true(!v.result.correlation_id.empty?, 'the failure carries a correlation id')
  end

  f.check('the failure names the engine and its version') do |v|
    v.expect_true(!v.result.engine.nil?, 'Failure#engine')
    v.expect_true(!v.result.engine_version.nil?, 'Failure#engine_version')
  end

  f.check('there are no bytes anywhere near it') do |v|
    raised = begin
      v.result.bytes
      false
    rescue NoMethodError
      true
    end
    v.expect_true(raised, 'Failure#bytes must raise rather than answer nil or empty bytes')
  end
end
