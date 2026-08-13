# frozen_string_literal: true

require 'digest'

module RedmineReporterDashboards
  # T-37 / FR-73 — THE STARTER GALLERY. "Start from an example, never from empty."
  #
  # `technical-spec.md` §9b.1 clause 3: *"**New template** offers a starter gallery … each
  # with a one-line description and a thumbnail rendered by the plugin itself in CI, so the
  # thumbnail cannot show something the code no longer produces. This is the single largest
  # onboarding lever available and it costs almost nothing … `[CITE: the two templates the
  # curator supplied in 00-idea.md are 747 lines of Liquid; nobody writes that from a blank
  # textarea]`."*
  #
  # --- WHAT IS IN THE GALLERY, AND WHY IT IS NOT THE TWO LEGACY EXAMPLES ---
  #
  # §9b.1's list is *"the three existing example templates (cleaned, Chart.js 4, no
  # handshake, `| json` throughout) plus a minimal issue document and a minimal aggregate
  # report"*. Two of those three are `examples/sample_report_template.liquid` (202 lines) and
  # `examples/version_status_dashboard.liquid` (598 lines), and "cleaned" understates what
  # they need by a wide margin: measured, they carry 12 and 44 lint findings, and every one
  # of them is a hand-built Chart.js 2 config, a `window.status` handshake or a CDN script
  # tag — the plumbing `{% chart %}` (T-16) and the readiness contract (T-11) replaced
  # wholesale. Modernising them is not a clean-up, it is a REWRITE of somebody else's
  # 800-line dashboard, and the result would still be an 800-line dashboard: the worst
  # possible first template for the author this gallery exists for.
  #
  # They also carry a second job. `spec/shipped_templates_lint_spec.rb` holds them at a
  # RATCHET and the README cites them, deliberately, as what the old idiom looked like;
  # `docs/plan/reference/example-template-*.liquid` are the frozen evidence a verification
  # document cites line numbers into. Rewriting the shipped copies would leave the README
  # teaching from a file that no longer matches its own prose.
  #
  # So the gallery is five PURPOSE-BUILT starters under `starters/`, each short enough to
  # read in one sitting, each lint-clean at zero rather than at a ratchet, and each using the
  # modern surface — `{% sql_aggregate %}`, `{% chart %}`, `{% version_rollup %}` and T-38's
  # three public classes. The legacy examples stay where they are, with their ratchet and
  # their role. **Reported rather than absorbed** (CLAUDE.md §11.3): this is a deviation from
  # §9b.1's literal list, the reason is above, and retiring the two legacy files once the
  # gallery covers their ground is a later decision, not this task's.
  #
  # --- THE IDS ARE A CLOSED SET AND THE PATHS ARE CONSTANTS ---
  #
  # A starter is chosen by an id in a query parameter, and that id NEVER becomes part of a
  # path: `find` looks it up in a frozen Hash and answers nil for anything else. Same rule as
  # FR-55's closed type map — a file name assembled from a request parameter is a traversal
  # waiting for somebody to notice it, and "but the value is validated" is what the base
  # plugin's YAML loader said too.
  module StarterGallery
    # `source` and `output` are the two axes a starter has to set for itself: a per-issue
    # document and a combined report are different templates, and a spent-time starter
    # resolves through a different query class. The gallery prefills them so a starter that
    # is applied and previewed immediately WORKS — an author whose first preview refuses
    # because the output class was wrong learns nothing except that this is fiddly.
    Entry = Struct.new(:id, :file, :source, :output, keyword_init: true) do
      # Locale keys are DERIVED from the id, so a starter cannot be added without its two
      # keys existing — `spec/starter_gallery_spec.rb` asserts every one of them is present
      # in every locale file, which is the check §10 asks for and the one that has been
      # skipped before.
      def key_suffix
        id.tr('-', '_')
      end

      def name_key
        :"label_reporter_starter_#{key_suffix}"
      end

      def description_key
        :"text_reporter_starter_#{key_suffix}"
      end

      def thumbnail_file
        "#{id}.png"
      end
    end

    ROOT = File.expand_path('../..', __dir__)
    DIRECTORY = File.join(ROOT, 'starters')

    # The thumbnails and the digest of the body each was rendered from. See
    # `#stale_thumbnails` — the digest is the whole mechanism.
    THUMBNAIL_DIRECTORY = File.join(ROOT, 'assets/images/starters')
    THUMBNAIL_MANIFEST = File.join(THUMBNAIL_DIRECTORY, 'thumbnails.yml')

    # A bound on a file this plugin ships, which is not paranoia about the file — it is that
    # `body` feeds a Liquid render and every other body on that path is bounded too
    # (`TemplateLinter::MAX_BODY_BYTES`, `Template`'s own column). One limit that is never
    # reached is cheaper than a special case for the one path that has none.
    MAX_BODY_BYTES = 128 * 1024

    ENTRIES = [
      Entry.new(id: 'issue-document', file: 'issue-document.liquid',
                source: 'issues', output: 'per_record'),
      Entry.new(id: 'aggregate-report', file: 'aggregate-report.liquid',
                source: 'issues', output: 'combined'),
      Entry.new(id: 'chart-report', file: 'chart-report.liquid',
                source: 'issues', output: 'combined'),
      Entry.new(id: 'spent-time-report', file: 'spent-time-report.liquid',
                source: 'time_entries', output: 'combined'),
      Entry.new(id: 'version-status', file: 'version-status.liquid',
                source: 'issues', output: 'combined')
    ].freeze

    BY_ID = ENTRIES.each_with_object({}) { |entry, out| out[entry.id] = entry }.freeze

    class << self
      def entries
        ENTRIES
      end

      # nil for anything that is not one of the five. The caller decides what to do about
      # that; this method does not raise, because an unknown id arrives in a query parameter
      # and a 500 is the wrong answer to a mistyped URL.
      def find(id)
        BY_ID[id.to_s]
      end

      def path(entry)
        File.join(DIRECTORY, entry.file)
      end

      def body(entry)
        File.read(path(entry), encoding: 'UTF-8')[0, MAX_BODY_BYTES]
      end

      # SHA-256 of the body as bytes. It is what the thumbnail manifest records, so an edited
      # starter and a thumbnail drawn from the previous version cannot both be committed.
      def digest(entry)
        Digest::SHA256.hexdigest(body(entry))
      end

      def thumbnail_path(entry)
        File.join(THUMBNAIL_DIRECTORY, entry.thumbnail_file)
      end

      def thumbnail?(entry)
        File.file?(thumbnail_path(entry))
      end

      # --- WHY A DIGEST AND NOT A PIXEL COMPARISON ---
      #
      # §9b.1 wants a thumbnail *"rendered by the plugin itself in CI, so the thumbnail
      # cannot show something the code no longer produces"*. The obvious mechanism —
      # regenerate and diff the bytes — is one this repository has already refused twice:
      # a rendered PNG depends on the font stack, the engine build and the DPI, so a
      # byte comparison fails on somebody else's machine for reasons that are not defects.
      # §9b.5 says as much: the perceptual diff is *"advisory — non-deterministic — not a
      # correctness guarantee"*, and CLAUDE.md §7 forbids reporting an advisory check as
      # PASS/FAIL.
      #
      # So the check is DETERMINISTIC and about provenance rather than pixels: the manifest
      # records the digest of the body each thumbnail was drawn from, and a starter whose
      # body has moved since is reported. That fails on exactly the condition §9b.1 names —
      # a thumbnail showing something the code no longer produces — and on nothing else.
      def recorded_digests
        return {} unless File.file?(THUMBNAIL_MANIFEST)

        require 'yaml'
        loaded = YAML.safe_load(File.read(THUMBNAIL_MANIFEST, encoding: 'UTF-8'))
        loaded.is_a?(Hash) ? loaded : {}
      end

      # [[entry, reason], …] — every starter whose thumbnail is missing, or was drawn from a
      # body that has since changed.
      def stale_thumbnails
        recorded = recorded_digests

        entries.filter_map do |entry|
          next [entry, 'no thumbnail has been generated'] unless thumbnail?(entry)

          was = recorded[entry.id]
          next [entry, 'the thumbnail is not recorded in thumbnails.yml'] if was.nil?
          next if was == digest(entry)

          [entry, "the starter has changed since its thumbnail was drawn (recorded #{was[0, 12]}…, " \
                  "now #{digest(entry)[0, 12]}…)"]
        end
      end

      def record_digests(pairs)
        require 'yaml'
        # SORTED AND WITH ITS OWN HEADER, because this file is committed and read in a diff.
        # `to_yaml` on a Hash keeps insertion order, so the sort is what makes a regeneration
        # a one-line diff rather than a reordering.
        body = <<~HEADER
          # GENERATED — the sha256 of the starter body each thumbnail in this directory was
          # drawn from. Written by `rake reporter_dashboards:gallery:verify RRD_THUMBNAILS=1`.
          # `spec/starter_gallery_spec.rb` fails when a starter has moved since its thumbnail
          # was drawn, which is FR-73's "the thumbnail cannot show something the code no
          # longer produces" — checked by provenance rather than by comparing pixels, because
          # a rendered PNG depends on the font stack and would fail for reasons that are not
          # defects (§9b.5).
        HEADER
        File.write(THUMBNAIL_MANIFEST, body + pairs.sort.to_h.to_yaml)
      end
    end
  end
end
