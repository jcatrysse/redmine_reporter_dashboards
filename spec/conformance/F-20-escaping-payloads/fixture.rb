# frozen_string_literal: true

# The escaping payload set, run through THIS ENGINE'S JavaScript parser.
#
# --- WHY THE ENGINE, AND NOT A UNIT TEST ---
#
# `docs/plan/reference/verification-liquid-js-escaping.md` settled the Ruby half by
# experiment: the documented idiom leaks a backslash, 2 940 payload combinations were
# generated, and every one of them was a SyntaxError in Node — real injection, no
# execution. But "in Node" is the caveat, and it is load-bearing. The document is
# parsed by whatever the PDF engine embeds, which for the compatibility adapter is a
# 2011 JavaScript engine with different error recovery. A payload that is a SyntaxError
# in V8 and is *recovered from* by an older parser is exactly the gap between the two
# halves of that finding, and no unit test on our side can see it.
#
# --- WHAT REPLACES STRING CONCATENATION ---
#
# The forbidden construct (CLAUDE.md §5) is "a JS array literal built by string
# concatenation". The replacement is a `<script type="application/json">` data block,
# and the property that makes it safe is that its contents are DATA to the HTML parser
# — with exactly one escape obligation, `</script>`, which must be written `<\/script>`.
# The block below carries that sequence twice on purpose, in both cases, so a naive
# emitter that only handles the lowercase form is caught.
#
# --- HOW IT IS ASSERTED ---
#
# By fingerprint, not by eye. The page parses the block and reports the parsed values'
# lengths and a checksum; the expected numbers below were computed independently. That
# catches a parser that swallowed a character, doubled a backslash, or decoded an
# escape twice — none of which is visible when you look at the rendered text, because
# the difference is one character in a string that still reads fine.
#
# The renderable payloads are ALSO asserted verbatim, because a fingerprint that
# matches for the wrong reason is a real hazard, and two independent views of the same
# fact is the cheapest defence against it.
RedmineReporterDashboards::Conformance.fixture(
  'F-20-escaping-payloads', "the escaping payload set under this engine's JS parser", dir: __dir__
) do |f|
  f.requires!(:javascript)
  f.request!(page_size: 'A4')
  f.readiness!(timeout_ms: 6_000, client_timeout_ms: 4_000)

  # Computed independently of the page, from the same JSON source, before this fixture
  # was written. If the page agrees, twelve strings survived the engine's parser
  # unchanged; if it does not, the fingerprint says which way it moved.
  f.check('every payload survives the parse byte for byte') do |v|
    v.expect_includes(v.text, 'PAYLOAD-COUNT 12', 'parsed payload count')
    v.expect_includes(v.text, 'PAYLOAD-LENGTHS 2,11,9,4,3,5,2,11,10,10,19,34', 'per-payload lengths')
    v.expect_includes(v.text, 'PAYLOAD-CHECKSUM f13c6e5', 'checksum over the parsed values')
  end

  f.check('the dangerous payloads reach the page as text, not as markup') do |v|
    ['-alert(1)//', '</script>', '<!--', ']]>', '${alert(1)}',
     '&lt;img src=x onerror=alert(1)&gt;'].each do |payload|
      v.expect_includes(v.text, payload, 'rendered payload')
    end
  end

  # The canary. If ANY payload executed, the handler below sets it, and the page
  # reports it — so a passing fingerprint with an executed payload still fails here.
  f.check('nothing in the payload set executed') do |v|
    v.expect_includes(v.text, 'CANARY-CLEAN', 'the execution canary')
    v.expect_excludes(v.text, 'CANARY-TRIPPED', 'the execution canary')
  end

  # A parse error in the data block is silent by default: `JSON.parse` throws, the
  # handler never runs, and the page renders with the placeholder text still in it.
  # That would pass "nothing executed" while proving nothing at all.
  f.check('the data block was actually parsed') do |v|
    v.expect_excludes(v.text, 'PAYLOAD-UNPARSED', 'the pre-parse placeholder')
  end
end
