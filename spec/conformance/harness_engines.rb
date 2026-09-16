# frozen_string_literal: true

require_relative '../../lib/redmine_reporter_dashboards/render/result'
require_relative '../../lib/redmine_reporter_dashboards/render/failure'
require_relative '../../lib/redmine_reporter_dashboards/render/capabilities'

module RedmineReporterDashboards
  module Conformance
    # Engines that exist only to exercise the HARNESS.
    #
    # A conformance harness has the same problem as any other gate: until you have
    # watched it fail, you do not know it can. `layer_purity.sh` reported every layer
    # clean while checking nothing, and a planted `Issue.visible` went undetected —
    # caught only because the gate was negative-tested before being wired up
    # (HANDOVER §1). This file is that negative test for T-12: engines that decline
    # capabilities, engines that lie about them, engines that return bytes which are not
    # a PDF, and engines that crash. Each of them must produce the cell it deserves.
    #
    # None of these renders HTML. They cannot: the corpus fixtures are about what a
    # BROWSER does with a document, and a fake that answered them would be testing
    # itself. So the harness spec drives them with its own synthetic fixtures, and the
    # real corpus runs only against a real engine.
    module HarnessEngines
      # A minimal, genuinely valid one-page PDF — built rather than committed as a
      # binary, so that what it contains is readable in the diff. It is padded past
      # `Renderer::MIN_PDF_BYTES` on purpose: a fake that produced a 300-byte PDF would
      # be rejected by the INV-5 post-conditions and every harness test would then be
      # measuring the wrong thing.
      module MinimalPdf
        module_function

        def bytes(text: 'HARNESS-CANNED-PDF')
          objects = [
            '<< /Type /Catalog /Pages 2 0 R >>',
            '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] ' \
            '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
            content_stream(text),
            '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
          ]
          assemble(objects)
        end

        def content_stream(text)
          stream = "BT /F1 24 Tf 72 720 Td (#{text.gsub(/[()\\]/) { |c| "\\#{c}" }}) Tj ET"
          "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
        end

        def assemble(objects)
          out = +"%PDF-1.4\n"
          offsets = objects.each_with_index.map do |object, i|
            offset = out.bytesize
            out << "#{i + 1} 0 obj\n#{object}\nendobj\n"
            offset
          end
          out << "% padding, so this clears Renderer::MIN_PDF_BYTES #{'-' * 900}\n"
          start_xref = out.bytesize
          out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
          offsets.each { |offset| out << format("%010d 00000 n \n", offset) }
          out << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n" \
                 "startxref\n#{start_xref}\n%%EOF\n"
          out.b
        end
      end

      # The base: declares what it is told to declare, returns what it is told to
      # return. Everything below is one line of configuration on top of it.
      class Scripted
        attr_reader :id, :version, :capabilities, :calls

        def initialize(id: :scripted, version: 'test-1', capabilities: Render::Capabilities::ALL,
                       body: nil, raise_with: nil, degradations: [], delay_ms: 0)
          @id = id
          @version = version
          @capabilities = Array(capabilities).map(&:to_sym).freeze
          @body = body.nil? ? MinimalPdf.bytes : body
          @raise_with = raise_with
          @degradations = degradations
          @delay_ms = delay_ms
          @calls = []
        end

        def preflight
          Render::Success.new(bytes: MinimalPdf.bytes, engine: id, engine_version: version)
        end

        def render(request)
          @calls << request
          raise @raise_with if @raise_with

          sleep(@delay_ms / 1000.0) if @delay_ms.positive?
          Render::Success.new(bytes: @body, engine: id, engine_version: version,
                              degradations: @degradations)
        end
      end

      module_function

      # Declares everything and answers with a real PDF. The pass path.
      def perfect(**options)
        Scripted.new(id: :perfect, **options)
      end

      # Declares a subset. Anything a fixture needs and this does not have must SKIP,
      # and the reason must name the capability — the first arm of G12.
      def limited(without:)
        Scripted.new(id: :limited,
                     capabilities: Render::Capabilities::ALL - Array(without))
      end

      # THE ONE THE THREE-STATE RULE EXISTS FOR: it declares the capability and then
      # does not deliver it. That is a HARD FAILURE, not a skip, because a declaration
      # is a promise and the matrix is built out of promises.
      def liar(body: 'this is not a PDF at all')
        Scripted.new(id: :liar, body: body)
      end

      def crasher(message: 'the engine died')
        Scripted.new(id: :crasher, raise_with: RuntimeError.new(message))
      end
    end
  end
end
