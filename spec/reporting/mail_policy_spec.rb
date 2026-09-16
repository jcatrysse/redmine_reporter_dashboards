# frozen_string_literal: true

# `require_relative`, LIKE EVERY SIBLING IN THIS DIRECTORY, and a bare `require` here
# turned all four CI `rspec` jobs red while passing locally on every Redmine branch.
#
# The local checkout happens to put `<plugin>/lib` on `$LOAD_PATH`, so
# `require 'redmine_reporter_dashboards/reporting/mail_policy'` resolved here and nowhere
# else; CI checks the plugin out into `plugin/` and the same line is a `LoadError` that
# aborts the whole file before one example runs. `require_relative` resolves against THIS
# FILE and cannot depend on the load path at all.
require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/reporting/mail_policy'

# T-32 / FR-61 — who this installation will put a report in front of.
#
# Every example here is a sentence from FR-61 or §4.1 turned into a check. The two that
# matter most are the COLLAPSE (an empty allowlist means off, not "any domain") and the
# EXACT domain match, because both are the kind of control that fails open when it fails.
RSpec.describe RedmineReporterDashboards::Reporting::MailPolicy do
  def policy(settings)
    described_class.from_settings(settings)
  end

  describe 'the default' do
    # §4.1: "recipients are Redmine users unless an admin enables external addresses".
    # Nothing configured must therefore mean nothing external, and the empty Hash is what
    # an installation that has never opened the settings page actually has.
    it 'refuses every external address when nothing is configured' do
      expect(policy({}).external_enabled).to be(false)
      expect(policy({}).external_permitted?('anyone@example.com')).to be(false)
    end

    it 'carries the documented rate limit and window' do
      expect(policy({}).rate_limit).to eq(described_class::DEFAULT_RATE_LIMIT)
      expect(policy({}).rate_window_minutes).to eq(described_class::DEFAULT_RATE_WINDOW_MINUTES)
    end
  end

  describe 'the collapse — FR-64s rule applied to mail' do
    # THE ONE THAT MUST FAIL CLOSED. An administrator who ticks the box and saves an empty
    # list has expressed an intention and configured nothing; reading that as "any domain"
    # is the spoofing-relay finding §7b.5 exists to close.
    it 'is off when the box is ticked and the allowlist is empty' do
      result = policy('mail_external_addresses' => '1', 'mail_external_domains' => '')

      expect(result.external_enabled).to be(false)
      expect(result.external_permitted?('anyone@example.com')).to be(false)
    end

    # A control that fails closed SILENTLY is a control an administrator believes is on.
    it 'says so, so the settings page can warn' do
      expect(policy('mail_external_addresses' => '1',
                    'mail_external_domains' => '').collapsed?).to be(true)
    end

    it 'is not "collapsed" when external addresses were never asked for' do
      expect(policy({}).collapsed?).to be(false)
      expect(policy('mail_external_addresses' => '1',
                    'mail_external_domains' => 'example.com').collapsed?).to be(false)
    end
  end

  describe 'the allowlist' do
    let(:enabled) do
      policy('mail_external_addresses' => true,
             'mail_external_domains' => "Example.COM\npartner.example.org")
    end

    it 'accepts an address in a listed domain, case-insensitively' do
      expect(enabled.external_permitted?('Someone@Example.com')).to be(true)
      expect(enabled.external_permitted?('a@partner.example.org')).to be(true)
    end

    # SUFFIX MATCHING IS THE BUG THIS EXAMPLE EXISTS FOR. `end_with?('example.com')` also
    # accepts `notexample.com`, which is somebody else's domain entirely, and it accepts
    # every subdomain — which is a different mail destination that an administrator
    # listing `example.com` has not named.
    it 'refuses a domain that merely ends with a listed one' do
      expect(enabled.external_permitted?('a@notexample.com')).to be(false)
      expect(enabled.external_permitted?('a@evil-example.com')).to be(false)
    end

    it 'refuses a subdomain of a listed domain' do
      expect(enabled.external_permitted?('a@mail.example.com')).to be(false)
    end

    it 'refuses an unlisted domain' do
      expect(enabled.external_permitted?('a@elsewhere.com')).to be(false)
    end

    # A SECOND `@` IS NOT AN ADDRESS, and splitting on the LAST one would read
    # `a@evil.com@example.com` as being in `example.com` while the MTA reads it as
    # something else entirely.
    it 'refuses an address with more than one @' do
      expect(enabled.external_permitted?('a@evil.com@example.com')).to be(false)
      expect(enabled.external_permitted?('a@@example.com')).to be(false)
    end

    it 'refuses text that is not an address at all' do
      ['', '   ', 'example.com', 'a@', '@example.com', nil].each do |value|
        expect(enabled.external_permitted?(value)).to be(false), "accepted #{value.inspect}"
      end
    end

    it 'drops an entry that is not a hostname and records why' do
      result = policy('mail_external_addresses' => true,
                      'mail_external_domains' => "example.com\nnot a domain")

      expect(result.domains).to eq(['example.com'])
      expect(result.dropped.map { |d| d[:key] }).to include('mail_external_domains')
    end

    it 'normalises a leading @ and a trailing dot' do
      result = policy('mail_external_addresses' => true,
                      'mail_external_domains' => "@example.com.\n")

      expect(result.domains).to eq(['example.com'])
    end
  end

  describe 'the switch' do
    # Redmine's checkbox posts '1'/'0' and a default Hash carries true/false. Reading only
    # one spelling is how a spec passes against a shape production never produces.
    it 'reads both the checkbox and the boolean spelling' do
      %w[1 true yes on].each do |on|
        expect(policy('mail_external_addresses' => on,
                      'mail_external_domains' => 'example.com').external_enabled).to be(true)
      end
      expect(policy('mail_external_addresses' => true,
                    'mail_external_domains' => 'example.com').external_enabled).to be(true)
    end

    # ANYTHING ELSE IS OFF. A value nobody anticipated must not turn egress on.
    it 'is off for any other value' do
      ['0', 'false', 'no', '', 'maybe', nil].each do |off|
        expect(policy('mail_external_addresses' => off,
                      'mail_external_domains' => 'example.com').external_enabled)
          .to be(false), "#{off.inspect} enabled external addresses"
      end
    end

    it 'reads a Symbol-keyed Hash as well as a String-keyed one' do
      expect(policy(mail_external_addresses: true,
                    mail_external_domains: 'example.com').external_enabled).to be(true)
    end
  end

  describe 'the rate limit' do
    it 'refuses once the count reaches the limit, and not before' do
      result = policy('mail_rate_limit' => '3')

      expect(result.rate_limited?(2)).to be(false)
      expect(result.rate_limited?(3)).to be(true)
      expect(result.rate_limited?(4)).to be(true)
    end

    # ZERO IS A LEGITIMATE SETTING and is not clamped up to the default: it is the only way
    # an administrator can switch ad-hoc mail off installation-wide, and §4.1 puts
    # installation policy in a setting.
    it 'treats zero as "off" rather than as unset' do
      result = policy('mail_rate_limit' => '0')

      expect(result.rate_limit).to eq(0)
      expect(result.rate_limited?(0)).to be(true)
    end

    it 'clamps an absurd value and records it' do
      result = policy('mail_rate_limit' => '999999')

      expect(result.rate_limit).to eq(described_class::MAX_RATE_LIMIT)
      expect(result.dropped.map { |d| d[:key] }).to include('mail_rate_limit')
    end

    # NEGATIVE IS A TYPO, NOT A SMALLER NUMBER. Left as-is it would make `rate_limited?`
    # answer true for every count, which is a working "off" reached by accident — and
    # `remaining` would print a negative allowance.
    it 'falls back to the default for a negative value, and records it' do
      result = policy('mail_rate_limit' => '-5')

      expect(result.rate_limit).to eq(described_class::DEFAULT_RATE_LIMIT)
      expect(result.dropped.map { |d| d[:key] }).to include('mail_rate_limit')
    end

    it 'falls back to the default for text, and records it' do
      result = policy('mail_rate_limit' => 'lots')

      expect(result.rate_limit).to eq(described_class::DEFAULT_RATE_LIMIT)
      expect(result.dropped.map { |d| d[:key] }).to include('mail_rate_limit')
    end

    it 'bounds the window too' do
      expect(policy('mail_rate_window_minutes' => '99999').rate_window_minutes)
        .to eq(described_class::MAX_RATE_WINDOW_MINUTES)
    end
  end

  describe 'the object itself' do
    # A frozen value object cannot acquire a lazy memo later — HANDOVER §1 has the entry
    # about `Assets::Reference`, where exactly that raised `FrozenError` on the first real
    # run and every accessor looked correct while reading.
    it 'is frozen' do
      expect(policy({})).to be_frozen
    end
  end
end
