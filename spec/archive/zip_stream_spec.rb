# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/archive/zip_stream'

# T-29 — the streamed archive, §Findings E-6's third bullet.
#
# --- WHY THIS FILE PARSES THE OUTPUT INSTEAD OF COMPARING IT WITH A FIXTURE ---
#
# T-30's PDF writer is the precedent and the warning: its first output opened with
# `%PDF-`, ended with `%%EOF`, was over the minimum size and satisfied `pdfinfo`
# completely — and was malformed, which only `pdftotext`'s STDERR revealed. A byte-length
# assertion or a golden file would have passed on it.
#
# So the assertions here are about STRUCTURE — the reader below walks the central
# directory the way an unpacker does, checks every CRC against the bytes actually emitted,
# and would notice a member whose header disagrees with its payload. The archive was also
# run through two independent real readers (`unzip -t`, which reports "No errors detected",
# and Python's `zipfile.testzip`) during development; neither is available in every
# container, so the committed control is this one.
module ZipStreamSpecSupport
  # HOISTED AND NAMESPACED — HANDOVER §1's first trap. A constant assigned inside
  # `RSpec.describe` is assigned at the FILE's top level, so it is `Object::Reader` for
  # the whole process and collides silently with any other spec wanting the name.
  #
  # A deliberately independent reader: it does not share a line of code with the writer,
  # so a mistake made in both would have to be made twice, in two directions.
  module Reader
    module_function

    EOCD_SIGNATURE = "PK\x05\x06".b

    def read(bytes)
      bytes = bytes.b
      eocd = bytes.rindex(EOCD_SIGNATURE)
      raise 'no end-of-central-directory record' if eocd.nil?

      # OFFSETS 8, 10, 12, 16 — entries-this-disk, TOTAL entries, size, offset. The first
      # version of this line read `unpack('vVV')` from offset 8, which straddles the
      # total-entries field into the size field and produced a central directory that
      # "runs past the file" for a perfectly good archive. It failed 13 examples and the
      # writer was right all along, which is the risk an independent reader carries and
      # the reason both real unpackers were run first.
      _this_disk, count, cd_size, cd_offset = bytes[eocd + 8, 12].unpack('vvVV')
      raise 'central directory runs past the file' if cd_offset + cd_size > bytes.bytesize

      members = []
      cursor = cd_offset
      count.times do
        member, cursor = read_central_record(bytes, cursor)
        members << member
      end

      { count: count, members: members }
    end

    def read_central_record(bytes, cursor)
      raise 'not a central directory header' unless bytes[cursor, 4] == "PK\x01\x02".b

      flags, method, _t, _d, crc, csize, usize, name_len, extra_len, comment_len =
        bytes[cursor + 8, 26].unpack('vvvvVVVvvv')
      offset = bytes[cursor + 42, 4].unpack1('V')
      name = bytes[cursor + 46, name_len]

      # THE MEMBER IS READ THROUGH ITS OWN LOCAL HEADER, at the offset the central
      # directory claims — which is the check that matters. An archive whose directory
      # points at the wrong place opens, lists the right names, and yields the wrong file.
      payload = read_local(bytes, offset, usize)

      [{ name: name, flags: flags, method: method, crc: crc, compressed_size: csize,
         size: usize, offset: offset, payload: payload },
       cursor + 46 + name_len + extra_len + comment_len]
    end

    def read_local(bytes, offset, size)
      raise 'not a local file header' unless bytes[offset, 4] == "PK\x03\x04".b

      name_len, extra_len = bytes[offset + 26, 4].unpack('vv')
      bytes[offset + 30 + name_len + extra_len, size]
    end
  end
end

RSpec.describe RedmineReporterDashboards::Archive::ZipStream do
  # A fixed instant. CLAUDE.md §6: never a bare `Time.now` in an expectation, and the
  # writer takes it as a required argument so that this is expressible at all.
  let(:mtime) { Time.utc(2025, 12, 29, 10, 30, 20) }

  def entry(name, bytes)
    described_class::Entry.new(name: name, bytes: bytes)
  end

  def archive(entries, at: mtime)
    out = +''.b
    described_class.new(entries: entries, mtime: at).each { |chunk| out << chunk }
    out
  end

  describe 'the archive it writes' do
    let(:entries) do
      [entry('report-1.pdf', "%PDF-1.4\n\xFF\xFE binary\n%%EOF\n".b),
       entry('report-2.pdf', 'x' * 5_000)]
    end

    it 'is readable by a reader that shares no code with the writer' do
      read = ZipStreamSpecSupport::Reader.read(archive(entries))

      expect(read[:count]).to eq(2)
      expect(read[:members].map { |m| m[:name] }).to eq(['report-1.pdf', 'report-2.pdf'])
    end

    it 'gives every member back byte for byte' do
      read = ZipStreamSpecSupport::Reader.read(archive(entries))

      expect(read[:members][0][:payload]).to eq(entries[0].bytes)
      expect(read[:members][1][:payload]).to eq(entries[1].bytes)
    end

    # THE CRC IS THE ONLY FIELD AN UNPACKER USES TO DECIDE THE FILE IS INTACT, so a wrong
    # one is the difference between an archive and an archive that reports corruption on
    # somebody else's machine. Recomputed here from the emitted payload rather than
    # compared with the writer's own number, which would compare a value with itself.
    it 'records a CRC that matches the bytes it emitted' do
      read = ZipStreamSpecSupport::Reader.read(archive(entries))

      read[:members].each do |member|
        expect(member[:crc]).to eq(Zlib.crc32(member[:payload]))
      end
    end

    it 'stores rather than compresses, so the two sizes agree' do
      read = ZipStreamSpecSupport::Reader.read(archive(entries))

      read[:members].each do |member|
        expect(member[:method]).to eq(described_class::METHOD_STORED)
        expect(member[:compressed_size]).to eq(member[:size])
      end
    end

    it 'is binary, so a member carrying a high byte cannot raise on concatenation' do
      expect(archive(entries).encoding).to eq(Encoding::ASCII_8BIT)
    end
  end

  # --- THE PROPERTY THE WHOLE FEATURE IS FOR ------------------------------------------
  describe 'streaming' do
    # A SOURCE THAT RECORDS WHEN IT IS PULLED. Every other assertion in this file would
    # pass against a writer that read all three entries, built the archive in a String and
    # yielded it at the end — which is precisely the implementation E-6 says not to write,
    # because the missing `Content-Length` would then be a lie about a buffered response.
    def recording_source(events, count)
      Enumerator.new do |yielder|
        count.times do |index|
          events << [:pull, index]
          yielder << entry("report-#{index}.pdf", 'x' * 1_000)
        end
      end
    end

    it 'yields a chunk before the last entry has been pulled from its source' do
      events = []
      described_class.new(entries: recording_source(events, 3), mtime: mtime)
                     .each { |chunk| events << [:chunk, chunk.bytesize] }

      first_chunk = events.index { |kind, _| kind == :chunk }
      last_pull = events.rindex { |kind, _| kind == :pull }

      expect(first_chunk).to be < last_pull
    end

    # AND IT INTERLEAVES ALL THE WAY THROUGH, not only at the start. A writer that emitted
    # its first member eagerly and then buffered the rest would pass the assertion above.
    it 'pulls each entry only after the previous one has been written out' do
      events = []
      described_class.new(entries: recording_source(events, 3), mtime: mtime)
                     .each { |chunk| events << [:chunk, chunk.bytesize] }

      kinds = events.map(&:first)
      expect(kinds.first).to eq(:pull)
      # pull, chunk, chunk, pull, chunk, chunk, … — never two pulls in a row, which is
      # what "the whole source was drained first" would look like.
      expect(kinds.each_cons(2).any? { |a, b| a == :pull && b == :pull }).to be(false)
    end

    it 'answers an Enumerator when called without a block, so it can be a Rack body' do
      stream = described_class.new(entries: [entry('a.pdf', 'a')], mtime: mtime)

      expect(stream.each).to be_a(Enumerator)
      expect(stream.each.to_a.join.b).to eq(archive([entry('a.pdf', 'a')]))
    end
  end

  # --- NAMES ---------------------------------------------------------------------------
  describe 'member names' do
    # §Findings S-13's lesson applied to a container format: agreement on the CONTENT says
    # nothing about the LABEL. Two members with one name is legal in a zip and a mess
    # everywhere else — unpackers variously keep the first, keep the last, or overwrite —
    # so an export of two issues whose sanitised names collide would silently lose one.
    it 'resolves a duplicate name rather than emitting it twice' do
      read = ZipStreamSpecSupport::Reader.read(
        archive([entry('report.pdf', 'first'), entry('report.pdf', 'second'),
                 entry('report.pdf', 'third')])
      )

      expect(read[:members].map { |m| m[:name] })
        .to eq(['report.pdf', 'report-2.pdf', 'report-3.pdf'])
    end

    it 'keeps each duplicate\'s own bytes with its own name' do
      read = ZipStreamSpecSupport::Reader.read(
        archive([entry('report.pdf', 'first'), entry('report.pdf', 'second')])
      )

      expect(read[:members].map { |m| m[:payload] }).to eq(%w[first second])
    end

    it 'puts the suffix before the extension, so the member still opens by name' do
      read = ZipStreamSpecSupport::Reader.read(
        archive([entry('a.pdf', '1'), entry('a.pdf', '2')])
      )

      expect(read[:members][1][:name]).to end_with('.pdf')
    end

    it 'gives an empty name something to be called' do
      read = ZipStreamSpecSupport::Reader.read(archive([entry('', 'body')]))

      expect(read[:members][0][:name]).to eq('document')
    end

    # WITHOUT BIT 11 A NON-ASCII NAME IS UNDEFINED — the historical encoding of a zip
    # member name is CP437, so a German or Russian template name unpacks as mojibake on
    # any reader that believes the header. Redmine runs in nine locales.
    it 'flags a non-ASCII name as UTF-8' do
      read = ZipStreamSpecSupport::Reader.read(archive([entry('Übersicht.pdf', 'b')]))

      expect(read[:members][0][:flags] & described_class::FLAG_UTF8_NAMES)
        .to eq(described_class::FLAG_UTF8_NAMES)
      expect(read[:members][0][:name].force_encoding(Encoding::UTF_8)).to eq('Übersicht.pdf')
    end

    # AND DOES NOT FLAG ONE THAT DOES NOT NEED IT. An ASCII name is identical under both
    # interpretations, so setting the bit would be a claim the archive does not need to
    # make — and this assertion is what stops the flag becoming unconditional, which would
    # make the assertion above pass for the wrong reason.
    it 'leaves an ASCII name unflagged' do
      read = ZipStreamSpecSupport::Reader.read(archive([entry('plain.pdf', 'b')]))

      expect(read[:members][0][:flags] & described_class::FLAG_UTF8_NAMES).to eq(0)
    end
  end

  # --- REFUSALS ------------------------------------------------------------------------
  describe 'what it refuses' do
    # `pack('V')` TRUNCATES SILENTLY, which would produce an archive that opens, lists the
    # right names and yields corrupt members — the plausible-looking wrong answer. Driven
    # with a stubbed `bytesize` rather than a real 4 GB String, because allocating one to
    # prove a bounds check is a test nobody will keep.
    # THE LIMIT IS LOWERED RATHER THAN THE INPUT RAISED. Allocating a 4 GiB String to
    # prove a bounds check is a test nobody keeps, and stubbing `bytesize` on the entry
    # does not work — the writer copies the String to force its encoding, and the copy
    # answers its real size. Lowering the constant drives the identical branch.
    it 'refuses a member too large for its 32-bit size field' do
      stub_const("#{described_class}::MAX_UINT32", 8)

      expect { archive([entry('big.pdf', 'x' * 9)]) }
        .to raise_error(described_class::TooLarge, /past the 8-byte limit/)
    end

    it 'names the actual size and the limit, so an operator can act on it' do
      stub_const("#{described_class}::MAX_UINT32", 8)

      expect { archive([entry('big.pdf', 'x' * 9)]) }
        .to raise_error(described_class::TooLarge, /9 bytes.*8/m)
    end

    # THE OFFSET OVERFLOWS FIRST IN PRACTICE: the 4 001st megabyte of an archive is past
    # the limit even when every member is small. Two members that each fit, and together
    # do not.
    it 'refuses an archive whose total length outgrows the offset field' do
      stub_const("#{described_class}::MAX_UINT32", 60)

      expect { archive([entry('a.pdf', 'x' * 20), entry('b.pdf', 'x' * 20)]) }
        .to raise_error(described_class::TooLarge, /the archive/)
    end

    it 'refuses more members than the count field can carry' do
      stub_const("#{described_class}::MAX_ENTRIES", 2)

      expect { archive([entry('a.pdf', ''), entry('b.pdf', ''), entry('c.pdf', '')]) }
        .to raise_error(described_class::TooLarge, /3 members and the limit is 2/)
    end
  end

  # --- TIME ----------------------------------------------------------------------------
  describe 'the timestamp' do
    # A DOS date has a 1980 epoch and 7 bits of year. 1979 would WRAP to a plausible
    # 2107 rather than fail, which is the kind of wrong answer nobody looks at twice.
    it 'clamps a pre-1980 timestamp instead of wrapping it into a plausible year' do
      bytes = archive([entry('a.pdf', 'b')], at: Time.utc(1971, 6, 5, 1, 2, 3))
      # The local header's mod-date field is at offset 12: signature(4), version(2),
      # flags(2), method(2), time(2).
      date = bytes[12, 2].unpack1('v')

      expect(date >> 9).to eq(0)
      expect((date >> 5) & 0x0F).to eq(1)
      expect(date & 0x1F).to eq(1)
    end

    it 'is the same for two archives built from the same entries at the same instant' do
      expect(archive([entry('a.pdf', 'b')])).to eq(archive([entry('a.pdf', 'b')]))
    end
  end

  describe 'an empty archive' do
    # ZERO MEMBERS IS A VALID ZIP and this must not be the branch that raises. The
    # controller never asks for one — it streams only when there is more than one document
    # — but a writer that crashed on an empty source would turn somebody else's future
    # empty case into a 500.
    it 'is still a well-formed archive with no members' do
      read = ZipStreamSpecSupport::Reader.read(archive([]))

      expect(read[:count]).to eq(0)
      expect(read[:members]).to eq([])
    end
  end
end
