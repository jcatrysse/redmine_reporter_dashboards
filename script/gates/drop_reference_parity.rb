# frozen_string_literal: true

# T-37 / FR-72 — the drop reference's parity check, as a program.
#
# *"the drop reference is **generated from the drops' declared surfaces**, and CI asserts
# parity in both directions: every documented accessor exists at runtime and every runtime
# accessor is documented."*
#
# Three questions, and each is a different defect:
#
#   1. UNDOCUMENTED   an accessor a template can reach that the reference does not list.
#                     Surface nobody was told about — and, since a drop's public methods
#                     ARE its API (`Liquid::Drop.invokable_methods`), an accidental one.
#   2. ABSENT         an entry in the reference for a method that no longer exists. A
#                     reference that lies: the author writes it, gets an empty render (or,
#                     under `strict_variables`, an error) and the documentation insists it
#                     should work.
#   3. STALE FILE     `docs/drop-reference.md` differs from a fresh generation. Exactly
#                     G9's rule for the support matrix: a generated artefact that is
#                     committed has to be regenerated in the same commit, or the file and
#                     the code are two answers to one question.
#
# A fourth is checked because it would make the other three vacuous: a drop class this
# layer ships with no entry in `DECLARED` at all is skipped by a per-class comparison, so
# it is reported here instead of quietly not being checked.
#
# --- NO RAILS, NO DATABASE ---
#
# The drops need `liquid` and their own files and nothing else, which is what lets
# `spec_liquid/` run them against both Liquid majors. So this gate runs in the `gates` job
# beside the greps rather than needing a Redmine checkout.
#
# Exit codes are the three-valued convention HANDOVER §1 requires of a gate's reader:
#   0  parity holds
#   1  findings, printed
#   2  the reader itself could not run, so this gate knows NOTHING

ROOT = File.expand_path('../..', __dir__)

begin
  require 'liquid'
rescue LoadError => e
  warn "ERROR: the Liquid gem is not loadable, so the drop surface cannot be read: #{e.message}"
  warn '       Run this through `bundle exec` with the plugin\'s Gemfile.'
  exit 2
end

# `ScriptError` AND NOT JUST `LoadError`, and a plant is why. A SyntaxError in the module is
# a `ScriptError` and not a `StandardError`, so it escaped this rescue, and an uncaught Ruby
# exception exits **1** — which the wrapper reads as "findings". A file that does not PARSE
# was therefore reported as a parity failure. `ScriptError` covers SyntaxError, LoadError and
# NotImplementedError; `Exception` would also swallow SignalException and NoMemoryError,
# which CLAUDE.md §5 forbids by name and which must stay fatal.
begin
  require File.join(ROOT, 'lib/redmine_reporter_dashboards/liquid/drop_reference')
rescue ScriptError, StandardError => e
  warn "ERROR: the drop reference did not load: #{e.class}: #{e.message}"
  exit 2
end

REFERENCE = RedmineReporterDashboards::Liquid::DropReference
DOC = File.join(ROOT, 'docs/drop-reference.md')

findings = []

# EVERYTHING BELOW IS WRAPPED, and that is not defensive habit — it is a defect this gate
# had and a plant found. An uncaught Ruby exception exits **1**, which is the wrapper's code
# for "findings", so a typo in `DECLARED` printed a NameError backtrace under a `FAIL:`
# heading and read as a parity finding. A reader that could not run must say 2.
begin
  # Two questions about the CLASS LIST first, because either makes the accessor comparison
  # incomplete: a shipped drop with no entry is not checked at all, and an entry naming no
  # class checks nothing.
  REFERENCE.unreferenced_classes.each do |klass|
    findings << "#{klass} is shipped by liquid/drops but has no entry in DropReference::DECLARED, " \
                'so none of its accessors is checked at all'
  end

  REFERENCE.unknown_classes.each do |klass|
    findings << "DropReference::DECLARED has an entry for #{klass}, which is not a drop class " \
                'this layer ships — a typo, or a class that was deleted without its entry'
  end

  REFERENCE.undocumented.each do |klass, names|
    findings << "#{klass}: reachable from a template and NOT in the reference: #{names.join(', ')}"
  end

  REFERENCE.absent_at_runtime.each do |klass, names|
    findings << "#{klass}: in the reference and NOT reachable at runtime: #{names.join(', ')}"
  end

  # THE COMMITTED FILE, compared byte for byte. An absent file is a finding rather than a
  # pass, for the same reason `layer_purity.sh` refuses to report OK about a directory that
  # is not there.
  if File.file?(DOC)
    committed = File.read(DOC, encoding: 'UTF-8')
    if committed != REFERENCE.markdown
      findings << 'docs/drop-reference.md differs from a fresh generation. Run ' \
                  '`rake reporter_dashboards:drop_reference` and commit the result in the same ' \
                  'change as the accessor that moved.'
    end
  else
    findings << 'docs/drop-reference.md does not exist, so FR-72\'s generated reference is not shipped'
  end

  if findings.empty?
    sections = REFERENCE.sections
    accessors = sections.sum { |section| section.accessors.length }
    puts "drop_reference_parity: OK — #{sections.length} drops, #{accessors} accessors, " \
         'reference and runtime agree in both directions.'
    exit 0
  end
rescue StandardError => e
  warn "ERROR: the drop-reference check raised #{e.class}: #{e.message}"
  warn '       No conclusion about FR-72 is available. Backtrace:'
  warn e.backtrace.take(8).map { |line| "         #{line}" }.join("\n")
  exit 2
end

findings.each { |finding| puts finding }
exit 1
