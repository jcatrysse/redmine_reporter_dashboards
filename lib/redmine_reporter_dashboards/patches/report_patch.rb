# frozen_string_literal: true

require 'stringio'

# Re-applies two fixes to redmine_reporter's Report model (originally made inline
# in the reporter plugin, now carried here so the vendor plugin stays pristine):
#
#   1. to_pdf — when no wkhtmltopdf_exe_path is configured, fall back to the
#      binary shipped by the `wkhtmltopdf-binary` gem so PDF export works
#      out-of-the-box (and in CI) instead of failing.
#   2. create_attachment — wrap the generated PDF bytes in a StringIO so
#      Attachment stores a valid file instead of an empty/corrupt attachment.
#
# Implemented as a prepend so it overrides the vendor methods without editing
# them. Both methods are replaced wholesale because the fixes are inline.
module RedmineReporterDashboards
  module Patches
    module ReportPatch
      def to_pdf
        exe_path = Redmine::Configuration['wkhtmltopdf_exe_path']
        if exe_path.blank? && defined?(Gem)
          spec = Gem::Specification.find_all_by_name('wkhtmltopdf-binary').first
          exe_path = spec ? Gem.bin_path('wkhtmltopdf-binary', 'wkhtmltopdf') : nil
        end
        if exe_path.present?
          WickedPdf.config = { exe_path: exe_path }
        end
        wicked_pdf = WickedPdf.new
        wicked_pdf.pdf_from_string(
          @content,
          encoding: 'UTF-8',
          page_size: 'A4',
          orientation: @orientation == ReportTemplate::ORIENTATION_LANDSCAPE ? 'Landscape' : 'Portrait',
          lowquality: wicked_pdf.binary_version.to_s == "0.12.4",
          margin: { top: 20, bottom: 20, left: 20, right: 20 },
          footer: { right: '[page]/[topage]' }
        )
      rescue StandardError => e
        Rails.logger.error("[report_patch] PDF generation failed: #{e.message}")
        nil
      end

      def create_attachment
        pdf_data = to_pdf
        if pdf_data.nil?
          Rails.logger.error("[report_patch] Skipping attachment — PDF generation failed for #{@filename}")
          return nil
        end
        Attachment.create(
          file: StringIO.new(pdf_data),
          author: User.current,
          filename: @filename,
          content_type: 'application/pdf'
        )
      end
    end
  end
end

begin
  # Object.const_get triggers Zeitwerk autoload of reporter's Report model in
  # development; in production it is already eager-loaded.
  report_class = Object.const_get('Report')
  unless report_class.ancestors.include?(RedmineReporterDashboards::Patches::ReportPatch)
    report_class.prepend(RedmineReporterDashboards::Patches::ReportPatch)
  end
rescue NameError
  Rails.logger.warn('[reporter_dashboards] Report class not found — PDF patch skipped')
end
