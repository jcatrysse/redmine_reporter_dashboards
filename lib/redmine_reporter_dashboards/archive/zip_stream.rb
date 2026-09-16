# frozen_string_literal: true

require 'zlib'

module RedmineReporterDashboards
  # T-29 — the archive namespace, and it names NEITHER the Liquid layer nor the render
  # layer, deliberately.
  #
  # §Findings E-6's third bullet is *"streamed archives with no `Content-Length`"*, and it
  # says where the thing may not go in the same sentence: *"a zip built in `render/` would
  # be the layer violation `layer_purity.sh` exists to catch, and building it anywhere else
  # means building the controller that serves it."*
  #
  # So this is the same shape T-33 settled for `charts/` and `assets/` (findings F-13 /
  # F-13b): a sibling of `render/` that names no layer, so that both layers — and the
  # composition root — may name IT. `script/gates/layer_purity.sh` has an arm for this
  # directory for exactly the reason it has one for the other two: without it, "a namespace
  # that names neither layer" decays into "the place where anything is allowed", and the
  # boundary between Liquid and render would hold only transitively, by luck.
  #
  # The division of labour with the controller is the other half of E-6's sentence. THIS
  # class turns entries into bytes and knows nothing about HTTP; the CONTROLLER decides
  # that those bytes go out without a `Content-Length`. Neither could be moved into the
  # other without breaking one of the two rules.
  module Archive
    # A ZIP writer that yields its output in pieces instead of returning a file.
    #
    # --- WHY THIS IS WRITTEN RATHER THAN REQUIRED ---
    #
    # `rubyzip` is not in Redmine's Gemfile on any supported branch, so requiring it would
    # add a gem dependency to a plugin whose entire premise (ADR-004) is *removing* one —
    # and it buys nothing here. Everything this needs is in the standard library:
    # `Zlib.crc32` and `Array#pack`. T-30 took the same decision for the same reason and
    # wrote `Render::MinimalPdf`, and the caution that comes with it is the same one:
    # **this is not a general archiving library and must not become one.** It writes
    # STORED entries into a single-disk archive under the ZIP64 thresholds, it refuses
    # anything else, and the moment it needs compression, encryption or a 5 GB member the
    # answer is a gem and a curator decision, not another 200 lines here.
    #
    # --- WHY `STORED` AND NOT `DEFLATE` ---
    #
    # Every member of this archive is a PDF, and a PDF's content streams are already
    # Flate-compressed. Deflating them a second time spends CPU per document to save
    # approximately nothing, and it would put a `Zlib::Deflate` object between the caller
    # and the output — which is a second place the streaming property could be lost. The
    # cost of the decision is honest and bounded: the archive is the sum of its members
    # plus about 100 bytes of bookkeeping each.
    #
    # --- WHY THERE ARE NO DATA DESCRIPTORS ---
    #
    # The usual reason a streaming zip needs them (bit 3 of the general-purpose flags) is
    # that the writer must emit a local header before it knows the member's CRC and size.
    # That is not this case: each entry arrives with its bytes complete, so the CRC and
    # both sizes are known before its header is written. Skipping the descriptors keeps
    # the archive readable by the strictest unpackers, and it is the reason the entry
    # source is an enumerable of COMPLETE entries rather than an IO to copy from.
    class ZipStream
      # One member. `bytes` is the whole member — see the note on data descriptors above.
      Entry = Struct.new(:name, :bytes, keyword_init: true)

      # THE ARCHIVE IS REFUSED RATHER THAN WRITTEN WRONG. Every field below is 16 or 32
      # bits wide in the format this class writes, and a value that does not fit does not
      # raise on its own — `pack('V')` silently truncates, which would produce an archive
      # that opens, lists the right names and yields corrupt members. That is the
      # plausible-looking wrong answer this repository keeps deleting, so each bound is
      # checked and the failure is loud.
      class TooLarge < StandardError; end

      # 4 GiB - 1: the widest value a 32-bit size or offset field can carry. Past any of
      # these the format requires ZIP64, which this class does not write.
      MAX_UINT32 = 0xFFFF_FFFF
      # 65 535 members, the widest value the end-of-central-directory count can carry.
      MAX_ENTRIES = 0xFFFF

      LOCAL_HEADER_SIGNATURE   = 0x0403_4b50
      CENTRAL_HEADER_SIGNATURE = 0x0201_4b50
      END_OF_CENTRAL_DIRECTORY = 0x0605_4b50

      # 2.0 — the minimum for a STORED entry, and what every unpacker in use understands.
      VERSION_NEEDED = 20
      METHOD_STORED = 0

      # Bit 11 of the general-purpose flags, the "language encoding flag" (EFS) added by
      # APPNOTE 6.3.0. WITHOUT IT A NON-ASCII NAME IS UNDEFINED: the historical encoding
      # of a zip member name is IBM Code Page 437, so a member called `Bericht Übersicht`
      # unpacks as mojibake on any reader that believes the header.
      #
      # NOT REACHED BY THE ONLY CALLER TODAY, and the comment used to imply it was. An
      # independent review measured every member of a non-ASCII archive coming back
      # `flag=0x0000`, because `TemplatesController#archive_entry_name` builds
      # `<stem>-<record id>.pdf` through a closed `[^0-9A-Za-z._-] -> _` filter. This is
      # defence for the next caller, not a description of the current one. Set only when
      # the name actually needs it, because an
      # ASCII name is identical under both interpretations and flagging it would be a
      # claim the archive does not need to make.
      FLAG_UTF8_NAMES = 0x0800

      # The MS-DOS epoch. A timestamp before 1980 cannot be represented in the 16-bit date
      # field at all, so it is CLAMPED rather than allowed to wrap into a plausible wrong
      # year — 1979 would otherwise pack as 2107.
      DOS_EPOCH_YEAR = 1980

      # `entries` is anything answering `#each` and yielding `Entry`. An Array works; so
      # does a lazy Enumerator, which is the point — see `#each`.
      #
      # `mtime` is INJECTED AND HAS NO CLOCK DEFAULT. CLAUDE.md §6 forbids a bare
      # `Time.now` in anything a test asserts on, and an archive whose bytes depend on the
      # second it was built in cannot be compared with anything. The caller passes the
      # timestamp it wants recorded and the tests pass a fixed one.
      def initialize(entries:, mtime:)
        @entries = entries
        @mtime = mtime
        freeze
      end

      # THE STREAMING PROPERTY, AND WHAT IT IS AND IS NOT.
      #
      # This yields the archive in pieces and never holds a whole one. What it retains
      # across the walk is one central-directory record per entry — a name and four
      # integers, tens of bytes — because the central directory is by construction at the
      # END of a zip and cannot be written before the members it indexes. The MEMBER bytes
      # are yielded and dropped.
      #
      # So the bound this class contributes is: peak = one member + O(entries) of
      # bookkeeping, rather than the sum of every member. It is deliberately NOT a claim
      # that the whole pipeline is lazy — the caller decides how its entries are produced,
      # and `TemplatesController` produces them from documents it has already rendered.
      # The reason it renders first is written down there and is a correctness argument,
      # not an oversight.
      #
      # `spec/archive/zip_stream_spec.rb` asserts the interleaving directly — that a chunk
      # is yielded before the LAST entry has been pulled from the source — because a
      # writer that quietly buffered everything and yielded it at the end would satisfy
      # every other assertion in that file.
      def each
        return to_enum(:each) unless block_given?

        directory = []
        offset = 0
        names = {}

        @entries.each do |entry|
          record = build_record(entry, offset, names)
          directory << record

          yield record[:local_header]
          yield record[:bytes]

          offset += record[:local_header].bytesize + record[:bytes].bytesize
        end

        # CHECKED HERE BECAUSE A LAZY SOURCE HAS NO LENGTH. Asking the entry source how
        # many members it has would force it, which is the one thing `#each` exists not to
        # do — so the count is checked at the point it becomes knowable, which is after
        # the walk and before the end-of-central-directory record that would carry it
        # truncated. The members are already on the wire by then; that is a real limit of
        # streaming and it is unreachable from this plugin, because `Render::BatchGuard`
        # refuses any batch over 50 documents long before an archive is asked for.
        refuse_entry_count(directory.length)
        yield_central_directory(directory, offset) { |chunk| yield chunk }
      end

      private

      def build_record(entry, offset, names)
        bytes = binary(entry.bytes.to_s)
        name = binary(unique_name(entry.name.to_s, names))
        crc = Zlib.crc32(bytes)

        # THE MEMBER'S OWN SIZE, CHECKED BEFORE ITS HEADER IS WRITTEN. `pack('V')` would
        # take a 5 GB size modulo 2**32 without a word.
        refuse_size(bytes.bytesize, "member #{name}")
        # AND ITS OFFSET, which is the field that overflows FIRST in practice: the 4 001st
        # megabyte of an archive is past the limit even when every member is small.
        refuse_size(offset, 'the archive')

        {
          name: name, crc: crc, size: bytes.bytesize, offset: offset, bytes: bytes,
          local_header: local_header(name, crc, bytes.bytesize)
        }
      end

      # A DUPLICATE NAME IS RESOLVED, NOT EMITTED. Two members with one name is legal in
      # the container format and a mess everywhere else: unpackers variously keep the
      # first, keep the last, or silently overwrite — so a per-record export of two issues
      # whose names collide would hand somebody an archive with a document missing and
      # nothing to say which. The caller cannot always prevent it (a filename is a
      # sanitised issue subject, and sanitising maps many subjects onto one name), so it
      # is closed here, where every name in the archive is visible at once.
      def unique_name(name, names)
        name = 'document' if name.empty?
        seen = names[name]

        unless seen
          names[name] = 1
          return name
        end

        # `report.pdf` -> `report-2.pdf`. The suffix goes before the extension so the
        # member still opens by double-click, and it counts from 2 so the pair reads as
        # "the first one and the second one" rather than starting at an invisible 1.
        names[name] = seen + 1
        extension = File.extname(name)
        stem = extension.empty? ? name : name[0...-extension.length]
        unique_name("#{stem}-#{seen + 1}#{extension}", names)
      end

      def local_header(name, crc, size)
        [
          LOCAL_HEADER_SIGNATURE, VERSION_NEEDED, flags_for(name), METHOD_STORED,
          dos_time, dos_date, crc, size, size, name.bytesize, 0
        ].pack('VvvvvvVVVvv') + name
      end

      def central_header(record)
        [
          CENTRAL_HEADER_SIGNATURE,
          # "Version made by". 20 = MS-DOS, which is what a writer that sets no external
          # file attributes should claim: announcing a Unix origin would invite readers to
          # interpret the (zero) external attributes as a mode of 000.
          VERSION_NEEDED, VERSION_NEEDED, flags_for(record[:name]), METHOD_STORED,
          dos_time, dos_date, record[:crc], record[:size], record[:size],
          record[:name].bytesize,
          0, 0, 0, 0, 0,
          record[:offset]
        ].pack('VvvvvvvVVVvvvvvVV') + record[:name]
      end

      def yield_central_directory(directory, offset)
        start = offset
        size = 0

        directory.each do |record|
          header = central_header(record)
          size += header.bytesize
          yield header
        end

        refuse_size(start, 'the archive')
        refuse_size(size, 'the central directory')

        yield [END_OF_CENTRAL_DIRECTORY, 0, 0, directory.length, directory.length,
               size, start, 0].pack('VvvvvVVv')
      end

      # ASCII-8BIT EVERYWHERE, AND IT IS NOT DEFENSIVE. A zip is bytes, and joining a
      # UTF-8 header to a binary PDF raises `Encoding::CompatibilityError` the moment the
      # PDF carries a byte above 0x7F — which every PDF does. HANDOVER §1's encoding trap
      # one layer down: name the encoding rather than inheriting it.
      def binary(string)
        string.dup.force_encoding(Encoding::ASCII_8BIT)
      end

      def flags_for(name)
        # `ascii_only?` on a binary string answers the question that matters — whether any
        # byte is above 0x7F — without reinterpreting the bytes.
        name.ascii_only? ? 0 : FLAG_UTF8_NAMES
      end

      def refuse_size(value, subject)
        return if value <= MAX_UINT32

        raise TooLarge,
              "#{subject} is #{value} bytes, past the #{MAX_UINT32}-byte limit of a " \
              'non-ZIP64 archive; this writer refuses rather than truncating the field'
      end

      def refuse_entry_count(count)
        return if count <= MAX_ENTRIES

        raise TooLarge,
              "this archive has #{count} members and the limit is #{MAX_ENTRIES}; " \
              'this writer refuses rather than truncating the field'
      end

      def dos_time
        (@mtime.hour << 11) | (@mtime.min << 5) | (@mtime.sec / 2)
      end

      # CLAMPED AT BOTH ENDS. The 7-bit year field spans 1980-2107; below it the value
      # would wrap into a plausible future year and above it `pack('v')` would truncate —
      # the one place this file's own "refuse rather than truncate" rule was applied in
      # only one direction. Unreachable from the shipped caller (`mtime` is the clock) and
      # clamped rather than refused because a timestamp is metadata: refusing to write an
      # archive over a bad clock would be a worse answer than writing it with a bad date.
      DOS_MAX_YEAR = DOS_EPOCH_YEAR + 127

      def dos_date
        year = @mtime.year
        return (1 << 5) | 1 if year < DOS_EPOCH_YEAR
        return (127 << 9) | (12 << 5) | 31 if year > DOS_MAX_YEAR

        ((year - DOS_EPOCH_YEAR) << 9) | (@mtime.month << 5) | @mtime.day
      end
    end
  end
end
