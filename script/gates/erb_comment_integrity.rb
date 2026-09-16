# frozen_string_literal: true

# Gate — T-43. NO `%>` MAY APPEAR IN TEMPLATE TEXT.
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
# --- THE RULE, AND IT TOOK THREE VERSIONS TO GET RIGHT ---
#
# Version 1 looked for an ERB **opener** inside a comment span. The fix for M-4 then
# reintroduced M-4 *in the sentence explaining M-4*, by quoting the CLOSING delimiter, and
# the gate reported OK.
#
# Version 2 added a heuristic — a multi-line comment whose terminator is not the last thing
# on its line — and an independent review broke it with two working reproductions in a
# minute. A comment whose accidental `%>` happens to land at a line end defeats it (this
# repository wraps view prose at about 95 characters, so that is one wrap away), and so does
# a single-line comment, which the heuristic had to exempt to stay usable.
#
# Version 3, which is this one, stops guessing. **ERB is a two-state machine**: template
# text, and inside a tag. The scan runs that machine, and the rule is exact:
#
#     a `%>` encountered while in TEMPLATE TEXT is a finding.
#
# A correct template has no such thing. Every `%>` in a correct template closes the tag it
# is inside. M-4's shape produces one by construction: the accidental delimiter closes the
# comment, and the delimiter the author *meant* as the terminator is then sitting in text.
# Both of the review's reproductions produce one. So does the trim-mode variant, so does a
# single-line comment that quotes a closer, and so does a stray `%>` in any other tag. The
# single-line exemption is gone rather than carved around, and there is no heuristic left to
# defeat.
#
# Note what this does NOT claim: a bare `%>` in template text is not an ERB *error* — ERB
# prints it. It is a repository rule, and it is the rule because every instance of it this
# project has ever had was an accident with a visible consequence.
#
# `<%%` — ERB's escape for a literal `<%` — needs no special case, and MEASURING that saved
# one: the first draft of this version skipped it in text state, on the assumption that it
# does not open anything. Erubi says otherwise. `Erubi::Engine.new("<%%= v %>").src` emits
# the literal string `<%= v %>`, so the escape consumes through the matching `%>` exactly
# as a real tag does. Treating `<%` and `<%%` identically is therefore not a simplification,
# it is the correct model, and a view that documents ERB syntax passes.
#
# --- WHY A SCANNER AND NOT A GREP ---
#
# An ERB tag spans lines and a grep matches one. `rg '<%#.*<%'` finds nothing in M-4's file:
# the opener is on line 1 and the offending tag is on line 29. State is what decides, and
# state is what this walks.
#
# --- WHY THIS REPOSITORY IN PARTICULAR ---
#
# It writes very long view comments on purpose — `_report.html.erb`'s header is thirty lines
# of argument, and that is a good property worth protecting. The next author who quotes an
# ERB delimiter inside one will reproduce M-4 exactly. So the rule is mechanised rather than
# written down, which is CLAUDE.md §5's "a control specified as mechanical and implemented
# as a comment".
#
# Exit codes, the three-valued convention every gate here follows:
#   0  checked, no findings
#   1  checked, findings printed
#   2  COULD NOT CHECK — an absent subject, an unreadable file. Never a pass.

module ErbCommentIntegrity
  OPEN = '<%'
  CLOSE = '%>'

  Finding = Struct.new(:path, :line, :kind, keyword_init: true) do
    MESSAGES = {
      stray_close: 'a %> in template text — the tag it was meant to close was already ' \
                   'closed earlier, so everything between the two is printed to the page',
      unterminated: 'an ERB tag is opened and never closed'
    }.freeze

    def to_s
      "#{path}:#{line}: #{MESSAGES.fetch(kind)}"
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

  # THE TWO-STATE WALK. `:text` outside a tag, `:tag` inside one. Nothing here knows or
  # cares what KIND of tag it is in — a comment, an output tag and a scriptlet all end at
  # the same delimiter, which is the fact M-4 is made of.
  def findings_in(relative, body)
    findings = []
    offset = 0

    loop do
      open_at = body.index(OPEN, offset)
      close_at = body.index(CLOSE, offset)

      # A `%>` before the next opener is one nothing opened.
      if close_at && (open_at.nil? || close_at < open_at)
        findings << Finding.new(path: relative, line: line_of(body, close_at),
                                kind: :stray_close)
        offset = close_at + CLOSE.length
        next
      end

      break if open_at.nil?

      tag_end = body.index(CLOSE, open_at + OPEN.length)
      if tag_end.nil?
        findings << Finding.new(path: relative, line: line_of(body, open_at),
                                kind: :unterminated)
        break
      end

      offset = tag_end + CLOSE.length
    end

    findings
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
    puts "erb_comment_integrity: OK — #{paths.length} view(s) scanned, every %> closes a " \
         'tag that was open.'
    exit 0
  end

  warn 'erb_comment_integrity: FAIL'
  findings.each { |finding| warn "  #{finding}" }
  warn ''
  warn 'An ERB tag ends at the first %>. Write the delimiter without its characters, or'
  warn 'move the sentence outside the tag. See §Findings M-4.'
  exit 1
end
