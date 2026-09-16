# frozen_string_literal: true

# T-38 — "`thead` repeats across pages in a >= 3-page table fixture".
#
# --- WHAT THIS ASSERTS ABOUT, AND IT IS NOT THE ENGINE ---
#
# The document carries `@@REPORT_STYLESHEET@@`, which the runner replaces with the SHIPPED
# `ReportStylesheet.style_element` — the same bytes every report on both bindings gets. A
# fixture with its own `thead { display: table-header-group }` would have asserted that the
# engine can repeat a header, which nobody doubts, and nothing at all about whether the
# stylesheet a report actually receives asks it to. Same rule, same reason, as
# `@@CHART_SHELL@@`.
#
# --- WHY THE COLUMN NAMES ARE THE ASSERTION AND THE PAGE COUNT IS ONLY THE PRECONDITION ---
#
# A long table whose columns are named on page 1 and nowhere else is a table nobody can
# read past the first break: by page 3 the reader has three unlabelled columns of numbers.
# So the check is that `THEAD-HOURS` is on EVERY page — and the >= 3 pages is what makes
# that a real question rather than a tautology. Two pages would be satisfied by an engine
# that draws the header once and happens to break late.
#
# 240 rows and not "enough": at 12px with 6px of cell padding an A4 page takes roughly a
# hundred, so this is comfortably past three pages on every engine without being a
# performance fixture — F-17 already owns that question with 2 000 rows.
#
# --- NO `requires!`, AND IT TOOK TWO WRONG ANSWERS TO GET BACK HERE ---
#
# The first version had none, on the reasoning that repeating a table header is basic CSS 2.1
# and every engine does it. The first RUN refuted that: wkhtmltopdf put the header on page 1
# only, and did so on a MINIMAL document carrying nothing but the canonical rule — which is
# how the engine was told apart from our stylesheet. So a `:repeating_table_header` capability
# was written and this fixture was given a `requires!` so that engine would SKIP.
#
# **Both were wrong, and the reason is recorded in HANDOVER §1 in capitals.** The measurement
# was taken against `apt install wkhtmltopdf` — Ubuntu's 0.12.6, built against UNPATCHED Qt,
# which is not a supported build and whose own corpus run is 17/1/2 with the footer fixture
# red. On `wkhtmltopdf 0.12.6.1 (with patched qt)`, the release `.deb` CI installs, the header
# repeats on all 7 pages of the same document. There is no support difference, the capability
# was retracted the same day, and this fixture is back to having no `requires!` — which is now
# a MEASURED statement about three engines rather than an assumption about CSS.
RedmineReporterDashboards::Conformance.fixture(
  'F-21-repeating-table-header',
  'the shipped stylesheet repeats a table header on every page of a long table',
  dir: __dir__
) do |f|
  f.request!(page_size: 'A4', timeout_ms: 60_000)

  row_count = 240
  f.expand! do |html|
    rows = (1..row_count).map do |i|
      "<tr><td>ROW-#{i}</td><td>Issue subject number #{i}</td>" \
        "<td class=\"rrd-number\">#{(i * 7) % 97}</td></tr>"
    end
    html.sub('<!--ROWS-->', rows.join("\n"))
  end

  f.check('the table is long enough for the question to be a real one') do |v|
    v.expect_between(v.page_count, 3, 40, 'page count for 240 rows')
    v.expect_includes(v.text(page: 1), 'ROW-1', 'first page')
    v.expect_includes(v.text(page: v.page_count), "ROW-#{row_count}", 'last page')
  end

  f.check('every column is named on every page, not only on the first') do |v|
    (1..v.page_count).each do |page|
      %w[THEAD-ISSUE THEAD-SUBJECT THEAD-HOURS].each do |column|
        v.expect_includes(v.flat_text(page: page), column, "page #{page} of #{v.page_count}")
      end
    end
  end
end
