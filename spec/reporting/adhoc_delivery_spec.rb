# frozen_string_literal: true

require 'yaml'

# `require_relative`, for the reason spelled out in `mail_policy_spec.rb`: a bare require
# of anything under this plugin resolves locally and raises `LoadError` in CI.
require_relative '../spec_helper'

# T-32 — the structural claims `AdhocDelivery` and migration 009 make about themselves.
#
# --- WHY THIS FILE IS SOURCE-LEVEL AND NOT BEHAVIOURAL ---
#
# The behaviour lives in `test/functional/reporter_dashboards_mail_controller_test.rb`,
# where there is a real database, a real `Issue.visible` and a real `Mailer`. A double
# cannot fail an index and cannot forge a header, so driving this class DB-less would test
# the double.
#
# What CAN only be asserted here is a set of claims about the shape of the code — the
# "control that was specified as mechanical and implemented as a comment" that CLAUDE.md §7
# names as a review failure. **An independent review found three such comments in T-32, each
# citing a spec file that had never been written.** This is that file, and every example
# below is one of those citations turned into a check.
RSpec.describe 'the ad-hoc mail layer, structurally' do
  def plugin_root
    File.expand_path('../..', __dir__)
  end

  def read(relative)
    File.read(File.join(plugin_root, relative), encoding: 'UTF-8')
  end

  # Comments are stripped before every scan below. HANDOVER §1's E-14 lesson, twice over: a
  # scanner that reads prose reports the sentence explaining the rule as a violation of it,
  # and every one of these files explains its rule at length.
  def code_only(relative)
    read(relative).lines.reject { |line| line.strip.start_with?('#') }
                  .map { |line| line.sub(/\s+#(?![{$@]).*\z/, '') }.join
  end

  let(:delivery) { 'lib/redmine_reporter_dashboards/reporting/adhoc_delivery.rb' }
  let(:mailer)   { 'app/models/reporter_dashboards_mailer.rb' }

  describe 'S-19: the audit address is written by nothing that sends' do
    # THE CONTROL S-19's WHOLE ARGUMENT RESTS ON.
    #
    # `reporter_dashboards_mail_send_recipients.address` is the one address column this
    # schema permits, and the reason it is not the `to`/`cc`/`bcc`/`from` §7 refuses is the
    # DIRECTION of the data: those are delivery inputs, this is a record written after the
    # policy decision. That distinction is only true while the delivery cannot read it —
    # and migration 009's comment claimed a spec asserted exactly this, when none did.
    it 'never names the recipient model' do
      expect(code_only(delivery)).not_to include('MailSendRecipient')
    end

    # The delivery takes its recipients as ARGUMENTS. If it ever queried for them, the
    # column would become an input no matter what the comments said.
    it 'never queries the audit tables at all' do
      source = code_only(delivery)

      expect(source).not_to match(/MailSend\b.*\.(where|find|pluck|all)/)
      expect(source).not_to include('reporter_dashboards_mail_send')
    end

    # And the write side is the controller's, not the delivery's — so "nothing that sends
    # reads it" and "nothing that reads it sends" are both true.
    it 'is written by the controller and not by the delivery' do
      expect(code_only('app/controllers/reporter_dashboards/mail_controller.rb'))
        .to include('MailSendRecipient')
    end
  end

  describe 'the sender has no channel' do
    # §7b.5's finding is a FORGED SENDER. Redmine's `Mailer#mail` merges `From` with
    # `reverse_merge!`, so a caller-supplied header WINS — inheriting `Mailer` is therefore
    # not the mechanism, and the absence of a parameter is. The parameter lists themselves
    # are asserted in the functional test, where the class is loaded; this is the other
    # half, which is that no header Hash is built anywhere on the path.
    it 'sets no From header anywhere on the ad-hoc path' do
      [delivery, mailer].each do |file|
        expect(code_only(file)).not_to match(/['"]From['"]\s*=>/),
                                       "#{file} builds a From header"
      end
    end

    it 'never reads a sender out of params' do
      expect(code_only('app/controllers/reporter_dashboards/mail_controller.rb'))
        .not_to match(/params\[:(from|sender|reply_to)\]/)
    end
  end

  describe 'every refusal the delivery can produce is a sentence in nine languages' do
    # THE PROMISE THE CONTROLLER'S FALLBACK MAKES.
    #
    # `adhoc_failure_text` falls back to the delivery's raw English message when a code has
    # no locale key. That fallback exists so a future code degrades to a sentence rather
    # than to a blank form — it is NOT a licence to ship one untranslated, and without this
    # example nothing would notice. The blank-form defect it replaced was found by review,
    # and the fallback alone would have hidden the next one.
    let(:codes) do
      # THREE SPELLINGS, and the meta-check below caught the first version reading only
      # one of them: most refusals go through the positional `refusal(:code, …)` and
      # `refuse(mail_send, :code, …)` helpers rather than through a `code:` keyword, so a
      # scan for `code:` alone found TWO codes and every locale example under it would
      # have passed while checking almost nothing.
      #
      # Read from the source rather than listed here, because a list is a second place to
      # forget — but read with a check that the reading worked, because a scan that
      # silently matches nothing is the AST reader's failure mode from T-40 (§Findings
      # E-20) one regexp in.
      code_only(delivery)
        .scan(/\bcode:\s*:([a-z_]+)|\brefusal\(:([a-z_]+)|\brefuse\([a-z_]+,\s*:([a-z_]+)/)
        .flatten.compact.uniq -
        # Not a refusal: `:sent` is the success result.
        ['sent']
    end

    it 'finds the refusal codes in the source at all' do
      # The meta-check. A scan that silently matched nothing would make every assertion
      # below pass vacuously — the AST reader's failure mode from T-40 (§Findings E-20),
      # one regexp in.
      expect(codes.length).to be >= 6
      expect(codes).to include('issues_not_visible', 'issue_ids_malformed',
                               'query_unavailable', 'no_recipients')
    end

    %w[de en es hu it pl pt-BR ru zh].each do |locale|
      it "has a key for each of them in #{locale}.yml" do
        strings = YAML.load_file(File.join(plugin_root, "config/locales/#{locale}.yml"))
                      .values.first
        missing = codes.reject { |code| strings.key?("error_reporter_adhoc_#{code}") }

        expect(missing).to eq([])
      end
    end
  end

  # THE "passes locally, fails in CI" CLASS, made mechanical.
  #
  # `mail_policy_spec.rb` shipped with `require 'redmine_reporter_dashboards/…'`. It
  # resolved on this machine — the checkout puts the plugin's `lib` on `$LOAD_PATH` — and
  # raised `LoadError` on all four CI `rspec` jobs, aborting the file before a single
  # example ran. Nothing local could have caught it, which is exactly why the check has to
  # be on the SHAPE of the require rather than on the run.
  #
  # CLAUDE.md §3 names this class in as many words for the reviewer role; this is the
  # cheapest possible version of it.
  describe 'no spec depends on the load path to find this plugin' do
    it 'requires plugin files relatively, everywhere under spec/' do
      offenders = Dir[File.join(plugin_root, 'spec/**/*.rb')].sort.filter_map do |path|
        line = File.read(path, encoding: 'UTF-8').lines.find do |l|
          l.match?(/^\s*require\s+['"]redmine_reporter_dashboards/)
        end
        "#{path.sub("#{plugin_root}/", '')}: #{line.strip}" if line
      end

      expect(offenders).to eq([])
    end
  end

  describe 'the scope is resolved once, and refuses rather than falling back' do
    # BOTH BLOCKERS AN INDEPENDENT REVIEW FOUND WERE A MISSING REFUSAL, and both were a
    # silent fallback to a WIDER scope than the requester asked for: an unresolvable
    # `query_id` fell back to the whole project, and an unparseable `issue_ids` fell back to
    # everything visible. The behaviour is tested in the functional suite; this is the
    # structural half, which is that the two arguments that make the fallback possible are
    # not present.
    it 'asks ReportScope to raise on a query it cannot resolve' do
      expect(code_only(delivery)).to include('on_missing_query: :raise')
    end

    it 'builds its scope through ReportScope and nowhere else' do
      source = code_only(delivery)

      expect(source).to include('ReportScope.build')
      # §Findings S-15: the defect was a second caller building `Issue.visible` itself.
      expect(source).not_to match(/Issue\.visible|TimeEntry\.visible/)
    end
  end
end
