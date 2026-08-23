# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# AN SMTP FAILURE ON A REPORT MAIL RAISES, AND NOTHING ELSE IN THE PROCESS NOTICES.
#
# --- WHAT THIS FILE IS THE REGRESSION FOR ---
#
# Redmine's `Mailer.deliver_mail` sets `raise_delivery_errors` on the message and then
# decides, in its own `rescue`, whether to re-raise or log — by reading the CLASS ATTRIBUTE
# `ActionMailer::Base.raise_delivery_errors`. Both delivery paths used to get their
# exception by flipping that attribute around their sends and restoring it in an `ensure`:
#
#     previous = ActionMailer::Base.raise_delivery_errors
#     ActionMailer::Base.raise_delivery_errors = true
#     yield
#   ensure
#     ActionMailer::Base.raise_delivery_errors = previous
#
# `ScheduledDelivery` said why that was acceptable *there* — it is a rake process, and the
# window is one occurrence's sends. `AdhocDelivery` copied the mechanism into a web request,
# where the same lines have two consequences the scheduler does not have:
#
#   1. two overlapping sends read and restore each other's value, and the interleaving that
#      ends with the first thread's `ensure` writing the value the second thread had already
#      replaced leaves `true` set FOR THE LIFE OF THE PROCESS;
#   2. for the duration of the window, EVERY OTHER MAIL IN THE PROCESS — issue notifications,
#      password resets, anything — is delivered under a policy a report send chose.
#
# (2) is what the second test below drives, and it is the better probe of the two: it is
# deterministic rather than a race that has to be provoked, and it fails loudly against the
# old implementation instead of failing one run in ten.
#
# --- WHY THESE TESTS CALL `.deliver_mail` DIRECTLY ---
#
# `.deliver_mail(mail) { … }` is the exact seam being changed: `Mail::Message#deliver` calls
# it on the mailer class (its `delivery_handler`) and passes the real delivery as the block.
# Driving it directly means the block can raise `Net::SMTPFatalError` without an SMTP server,
# and — for the second test — can hold the delivery window open on a latch, which no
# end-to-end send could do. The trade is that these tests know one Rails contract; a change
# to it fails here rather than silently, and CI runs this on all four supported branches.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods after a `private` section are silently not run. The helpers below are under
# one, and every `test_` method is above it.
class ReporterDashboardsMailDeliveryErrorsTest < ActiveSupport::TestCase
  def setup
    # THE BASELINE IS "REDMINE SWALLOWS", because that is Redmine's default and it is the
    # setting the assertions below are meaningful against. Set here rather than assumed: a
    # host application that had already turned it on would make every test in this file pass
    # for the wrong reason. This is the one place the attribute is written, it is written
    # before any thread exists, and it is restored in `teardown` — which is precisely the
    # discipline the production code no longer needs to keep.
    @previous = ActionMailer::Base.raise_delivery_errors
    ActionMailer::Base.raise_delivery_errors = false
  end

  def teardown
    ActionMailer::Base.raise_delivery_errors = @previous
  end

  # --- the behaviour itself -----------------------------------------------------------------

  def test_a_report_mail_raises_a_delivery_error_without_the_global_flag_being_set
    assert_equal false, ActionMailer::Base.raise_delivery_errors, 'precondition'

    assert_raises(Net::SMTPFatalError) do
      ReporterDashboardsMailer.deliver_mail(mail_message('report@example.org')) do
        raise Net::SMTPFatalError, 'relay refused'
      end
    end
  end

  def test_delivering_a_report_mail_does_not_touch_the_global_flag
    seen_inside = nil

    assert_raises(Net::SMTPFatalError) do
      ReporterDashboardsMailer.deliver_mail(mail_message('report@example.org')) do
        seen_inside = ActionMailer::Base.raise_delivery_errors
        raise Net::SMTPFatalError, 'relay refused'
      end
    end

    assert_equal false, seen_inside, 'the flag was raised for the duration of the send'
    assert_equal false, ActionMailer::Base.raise_delivery_errors, 'the flag was left changed'
  end

  # THE SCOPE OF THE CHANGE, asserted from the other side. If this ever starts raising, the
  # override has stopped being about this mailer and has become about the application.
  def test_redmine_s_own_mailer_still_swallows_a_delivery_error
    assert_nothing_raised do
      Mailer.deliver_mail(mail_message('unrelated@example.org')) do
        raise Net::SMTPFatalError, 'relay refused'
      end
    end
  end

  # --- the concurrency regression -----------------------------------------------------------

  def test_an_unrelated_mail_keeps_its_own_error_policy_while_a_report_is_mid_flight
    # NOT A PROBABILISTIC RACE. The report send is parked inside its own delivery window on a
    # latch, so the unrelated mail below is delivered at the exact moment the old
    # implementation had `raise_delivery_errors` set to `true` process-wide. Against that
    # implementation this test fails every run; against this one it cannot fail at all,
    # because there is no window to be inside of.
    inside = Queue.new
    release = Queue.new

    reporter = Thread.new do
      ReporterDashboardsMailer.deliver_mail(mail_message('report@example.org')) do
        inside << :parked
        release.pop
        raise Net::SMTPFatalError, 'relay refused'
      end
      :delivered
    rescue Net::SMTPFatalError
      :raised
    end

    begin
      inside.pop # the report send is now holding its delivery window open

      unrelated = begin
        Mailer.deliver_mail(mail_message('unrelated@example.org')) do
          raise Net::SMTPFatalError, 'relay refused'
        end
        :swallowed
      rescue Net::SMTPFatalError
        :raised
      end
    ensure
      release << :go
    end

    assert_equal :raised, reporter.value, 'the report send should still surface its failure'
    assert_equal :swallowed, unrelated,
                 'an unrelated Redmine mail was delivered under the report send\'s error policy'
    assert_equal false, ActionMailer::Base.raise_delivery_errors, 'the flag was left changed'
  end

  def test_two_concurrent_report_sends_cannot_corrupt_the_flag_between_them
    # The lost-restore half of the defect. Both threads are held inside their delivery windows
    # at the same time and released in the opposite order, which is the interleaving that left
    # the old implementation's `ensure` writing a value another thread had already replaced.
    inside = Queue.new
    release = Queue.new

    threads = 2.times.map do |i|
      Thread.new do
        ReporterDashboardsMailer.deliver_mail(mail_message("report-#{i}@example.org")) do
          inside << i
          release.pop
          raise Net::SMTPFatalError, 'relay refused'
        end
        :delivered
      rescue Net::SMTPFatalError
        :raised
      end
    end

    2.times { inside.pop }
    observed = ActionMailer::Base.raise_delivery_errors
    2.times { release << :go }

    assert_equal %i[raised raised], threads.map(&:value)
    assert_equal false, observed, 'the flag was raised while two sends overlapped'
    assert_equal false, ActionMailer::Base.raise_delivery_errors, 'the flag was left changed'
  end

  # --- the `Mailer` behaviour the override must not lose ------------------------------------

  def test_a_message_with_no_recipient_is_refused_rather_than_delivered
    # Redmine's guard, kept: `deliver_mail` returns `false` and never reaches the delivery
    # block. The class comment on `ReporterDashboardsMailer` names this as one of the four
    # `Mailer` behaviours a plugin must not reimplement away.
    delivered = false

    result = ReporterDashboardsMailer.deliver_mail(Mail.new(from: 'redmine@example.org')) do
      delivered = true
    end

    assert_equal false, result
    assert_not delivered, 'a message with no recipient reached the delivery block'
  end

  private

  # `mail_message` AND NOT `message`, which is what this was called for one run.
  # `Minitest::Assertions#message(msg = nil, ending = nil, &default)` is what every assertion
  # calls to build its failure text, so a one-argument `message` here overrode it and turned
  # every assertion in the file into `ArgumentError: wrong number of arguments (given 2,
  # expected 1)` — five errors whose backtrace pointed at this helper and said nothing about
  # the collision. Found by running it.
  def mail_message(to)
    Mail.new(to: to, from: 'redmine@example.org', subject: 'Report', body: 'x')
  end
end
