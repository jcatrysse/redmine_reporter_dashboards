# frozen_string_literal: true

require 'spec_helper'
require File.expand_path('../lib/redmine_reporter_dashboards/pdf_polyfills', __dir__)

RSpec.describe RedmineReporterDashboards::PdfPolyfills do
  describe '.charts?' do
    it 'detects a canvas element (chart)' do
      expect(described_class.charts?('<div><canvas id="c"></canvas></div>')).to be true
    end

    it 'detects a self-closing / bare canvas tag' do
      expect(described_class.charts?('<canvas>')).to be true
      expect(described_class.charts?('<canvas/>')).to be true
    end

    it 'is case-insensitive' do
      expect(described_class.charts?('<CANVAS></CANVAS>')).to be true
    end

    it 'returns false for chart-less HTML' do
      expect(described_class.charts?('<table><tr><td>1</td></tr></table>')).to be false
    end

    it 'does not match the word canvas outside a tag' do
      expect(described_class.charts?('<p>a canvas print</p>')).to be false
    end

    it 'is nil-safe and non-string-safe' do
      expect(described_class.charts?(nil)).to be false
      expect(described_class.charts?(123)).to be false
    end
  end

  describe '.inject' do
    it 'inserts the shims right after <body>' do
      html = '<html><body><canvas></canvas></body></html>'
      result = described_class.inject(html)
      body_index   = result.index('<body>')
      script_index = result.index('ES2015 shims')
      canvas_index = result.index('<canvas>')
      expect(script_index).to be > body_index
      expect(script_index).to be < canvas_index
    end

    it 'preserves attributes on the body tag' do
      html = '<body class="report" data-x="1">x</body>'
      result = described_class.inject(html)
      expect(result).to include('<body class="report" data-x="1">')
      expect(result).to include('ES2015 shims')
    end

    it 'prepends the shims when there is no body tag' do
      html = '<canvas></canvas>'
      result = described_class.inject(html)
      expect(result).to start_with(described_class::SCRIPT)
      expect(result).to end_with(html)
    end

    it 'returns nil unchanged' do
      expect(described_class.inject(nil)).to be_nil
    end

    it 'injects the shims only once' do
      html = '<body></body>'
      result = described_class.inject(html)
      expect(result.scan('ES2015 shims').size).to eq(1)
    end
  end
end
