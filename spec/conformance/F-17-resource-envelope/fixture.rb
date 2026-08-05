# frozen_string_literal: true

# A real report's worth of rows, and the envelope it has to come back inside.
#
# 2 000 rows is not a stress test — it is a quarterly issue list, and it is the size at
# which the differences between engines stop being academic. Three bounds, each of
# which has a failure behind it that this project has already seen or been warned about:
#
#   wall clock  a render that takes minutes is a 504 with a burning worker (T-15)
#   byte size   a PDF that embeds one font per row is unopenable in a mail client
#   page count  an engine that silently truncates long tables answers a smaller
#               question and looks FASTER for it — the same defect shape as the
#               aggregation kernel's `EXPECTED_RESULT_SIZE` (HANDOVER §1)
#
# The page-count bound is the one that matters most, and it is why the first and last
# rows are asserted by name: an engine that drew 12 pages and stopped passes a timing
# bound comfortably.
RedmineReporterDashboards::Conformance.fixture(
  'F-17-resource-envelope', '2 000 rows render inside a stated envelope', dir: __dir__
) do |f|
  f.request!(page_size: 'A4', timeout_ms: 60_000)
  f.readiness!(timeout_ms: 8_000, client_timeout_ms: 6_000)

  row_count = 2_000
  f.expand! do |html|
    rows = (1..row_count).map do |i|
      "<tr><td>ROW-#{i}</td><td>Issue subject number #{i}</td><td>#{i * 7 % 97}</td></tr>"
    end
    html.sub('<!--ROWS-->', rows.join("\n"))
  end

  f.check('it renders inside the wall-clock envelope') do |v|
    v.expect_between(v.duration_ms, 0, 30_000, 'render duration (ms) for 2 000 rows')
  end

  f.check('the whole table is on the paper, not a truncated prefix') do |v|
    v.expect_between(v.page_count, 25, 120, 'page count for 2 000 rows')
    v.expect_includes(v.text(page: 1), 'ROW-1', 'first page')
    v.expect_includes(v.text(page: v.page_count), "ROW-#{row_count}", 'last page')
  end

  f.check('the output is a size a mail server will carry') do |v|
    v.expect_between(v.byte_size, 10_000, 8 * 1024 * 1024, 'PDF byte size')
  end
end
