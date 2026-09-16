# frozen_string_literal: true

# Gate — T-43. NO ERB COMMENT MAY CONTAIN AN ERB TAG.
#
# §Findings **M-4**: `app/views/my/blocks/_report_by_issues.erb` opened a `<%#` header
# comment at line 1 and, at line 29, wrote
#
#     guarded body are the `<%= render %>` calls, and `render` builds its result before
#
# as prose ABOUT the code below it. ERB does not read prose. It closes a comment at the
# first `%>`, so that one terminated the comment and the remaining thirty lines became
# template text — printed above the report on `/my/page`, for every user who added the
# block, ending in a literal `%>`. The suite was green, because no test rendered that view.
#
# --- WHY A SCANNER AND NOT A GREP ---
#
# An ERB comment spans lines and a grep matches one. `rg '<%#.*<%'` finds nothing here: the
# opener is on line 1 and the offending tag is on line 29. The rule is a property of the
# SPAN between `<%#` and the `%>` that closes it, which is what this file walks.
#
# --- IT CHECKS FOR BOTH DELIMITERS, AND THE SECOND ONE COST A ROUND ---
#
# The first version of this gate looked only for an opening `<%` inside the span. The fix
# for M-4 then REINTRODUCED M-4, in the sentence explaining M-4: it said *"ERB closes a
# comment at the first `%>`"*, and that quoted `%>` closed the comment. The gate reported OK,
# because it had taken that `%>` for the terminator and found no `<%` before it — a hole
# exactly the shape of the defect it exists for, found by the integration test rather than
# by the gate.
#
# So there are two rules, and the second is the one worth explaining:
#
#   A  an ERB OPENER inside the span. Unambiguous.
#   B  a span that OPENED ON AN EARLIER LINE and closes mid-line. A real terminator is the
#      last thing on its line — that is how every multi-line comment in this repository is
#      written, and it is how anybody writes one. A multi-line comment that ends in the
#      middle of a sentence ended by accident.
#
# Rule B deliberately does NOT fire on a single-line comment (`<%# note %><p>x</p>` is
# ordinary and correct), which is why it carries the same-line test rather than being a flat
# "the terminator must end its line".
#
# --- WHY THIS REPOSITORY IN PARTICULAR ---
#
# It writes very long view comments on purpose — `_report.html.erb`'s header is thirty lines
# of argument, and that is a good property worth protecting. The next author who quotes an
# ERB tag inside one will reproduce M-4 exactly. So the rule is mechanised rather than
# written down, which is CLAUDE.md §5's "a control specified as mechanical and implemented
# as a comment".
#
# Exit codes, the three-valued convention every gate here follows:
#   0  checked, no findings
#   1  checked, findings printed
#   2  COULD NOT CHECK — an absent subject, an unreadable file. Never a pass.

module ErbCommentIntegrity
  # `<%#` and `<%-#`. Rails' ERB handler accepts both, and a rule that knew only the first
  # would be defeated by a trim-mode comment.
  OPENER = /<%-?#/.freeze

  # Any ERB opener at all inside the span: `<%`, `<%=`, `<%-`, `<%==`. All of them close the
  # comment the moment their own `%>` arrives, so all of them are findings.
  INNER = /<%/.freeze

  Finding = Struct.new(:path, :line, :inner, keyword_init: true) do
    def to_s
      "#{path}:#{line}: an ERB comment contains #{inner.inspect} — the comment ends at that " \
        'tag\'s %> and everything after it is printed'
    end
  end

  module_function

  def scan(root, relative_paths)
    relative_paths.flat_map do |relative|
      absolute = File.join(root, relative)
      body = File.read(absolute, encoding: 'UTF-8')
      findings_in(relative, body)
    end
  end

  # The span walk. From each comment opener, the comment ends at the FIRST `%>` — that is
  # ERB's own rule and it is the whole defect — so anything ERB-shaped before it is a finding.
  def findings_in(relative, body)
    findings = []
    offset = 0

    while (open_at = body.index(OPENER, offset))
      body_start = body.index('%', open_at) # the '%' of '<%'
      close_at = body.index('%>', body_start + 2)
      # An unterminated comment is a different defect and a louder one; ERB itself refuses
      # the template. Reported as a finding rather than skipped, so it cannot hide here.
      if close_at.nil?
        findings << Finding.new(path: relative, line: line_of(body, open_at),
                                inner: '(unterminated comment)')
        break
      end

      span = body[(open_at + 3)...close_at].to_s

      if (inner_at = span.index(INNER))
        # Rule A — an ERB opener inside the span.
        findings << Finding.new(path: relative,
                                line: line_of(body, open_at + 3 + inner_at),
                                inner: span[inner_at, 12])
      elsif span.include?("\n") && !closes_its_line?(body, close_at)
        # Rule B — a multi-line comment that ends in the middle of a line. The `%>` that
        # closed it is almost certainly one somebody wrote INSIDE a sentence.
        findings << Finding.new(path: relative, line: line_of(body, close_at),
                                inner: '%> (mid-line, in a multi-line comment)')
      end

      offset = close_at + 2
    end

    findings
  end

  # Everything after this `%>` on its own line, ignoring whitespace. A terminator that ends
  # its line is deliberate; one with prose after it is not.
  def closes_its_line?(body, close_at)
    rest_of_line = body[(close_at + 2)..].to_s[/\A[^\n]*/].to_s
    rest_of_line.strip.empty?
  end

  def line_of(body, index)
    body[0...index].count("\n") + 1
  end
end

if $PROGRAM_NAME == __FILE__
  root = ARGV[0] || File.expand_path('../..', __dir__)
  search = ARGV[1] || 'app/views'
  directory = File.join(root, search)

  unless File.directory?(directory)
    warn "ERROR: #{search} does not exist under #{root} — nothing was checked."
    exit 2
  end

  paths = Dir.glob(File.join(directory, '**', '*.erb'))
             .map { |path| path.sub("#{root}/", '') }
             .sort

  if paths.empty?
    warn "ERROR: no .erb under #{search} — nothing was checked, and an absent subject is " \
         'not a pass.'
    exit 2
  end

  findings = begin
    ErbCommentIntegrity.scan(root, paths)
  rescue StandardError => e
    warn "ERROR: the scan itself failed (#{e.class}: #{e.message}) — nothing was checked."
    exit 2
  end

  if findings.empty?
    puts "erb_comment_integrity: OK — #{paths.length} view(s) scanned, no ERB tag inside an " \
         'ERB comment.'
    exit 0
  end

  warn 'erb_comment_integrity: FAIL'
  findings.each { |finding| warn "  #{finding}" }
  warn ''
  warn 'An ERB comment ends at the first %>. Write the tag without its delimiters, or move'
  warn 'the sentence outside the comment. See §Findings M-4.'
  exit 1
end
