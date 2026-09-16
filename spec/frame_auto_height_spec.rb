# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/report_frame'

# T-44, §Findings M-5 — THE FRAME MEASURES ITSELF, AND BOTH HALVES OF THE PROTOCOL ARE HERE.
#
# `_report.html.erb` used to argue that auto-sizing died with the opaque origin. The argument
# reasoned from `contentWindow.document`, which a parent genuinely cannot read across one.
# `postMessage` crosses it by design, and the parent authenticates the sender by OBJECT
# IDENTITY rather than by origin — which is the check an opaque origin is supposed to force,
# because its origin is the string `"null"` and every sandboxed frame on the page shares it.
#
# --- WHY NODE AND NOT A SYSTEM TEST ---
#
# A system test asserts that it works in one browser. What has to be asserted here is what
# happens when the message is HOSTILE or MISATTRIBUTED, and a browser will not send those.
# So the two scripts are driven under node against a stub DOM, the way `mermaid_boot_spec.rb`
# and `chart_form_js_spec.rb` already do it. The browser half is measured instead, and the
# measurement is recorded in the T-44 commit: three surfaces, three runs, stable.
#
# NAMESPACED, because a constant assigned inside `RSpec.describe` lands on `Object` — the trap
# three other spec files in this directory carry a header about.
module FrameAutoHeightSpecSupport
  PARENT_PATH = File.expand_path('../assets/javascripts/redmine_reporter_dashboards.js', __dir__)

  # The child half is embedded in Ruby, so it is read from the constant rather than from a
  # file: a copy in this spec would be the thing tested and not the thing shipped.
  def self.child_script
    RedmineReporterDashboards::ReportFrame::AUTO_HEIGHT_SCRIPT
      .sub(%r{\A\s*<script>}, '').sub(%r{</script>\s*\z}, '')
  end
end

RSpec.describe 'the report frame\'s self-measurement' do
  # G12's three-state rule, applied to a tool rather than to a capability: a runner without
  # node has not verified the postMessage protocol, and saying so is not the same as
  # passing. A BARE `skip` would be the §5 violation; this one carries its reason and is
  # counted in the skip inventory (G10).
  before do
    unless system('command -v node > /dev/null 2>&1')
      skip 'node is not on PATH, so the frame protocol is UNVERIFIED here rather than green'
    end
  end

  def node(script)
    Dir.mktmpdir('rrd-frame-height') do |dir|
      path = File.join(dir, 'run.js')
      File.write(path, script, encoding: 'UTF-8')
      out, err, status = Open3.capture3('node', path)
      raise "node failed: #{err}" unless status.success?

      out
    end
  end

  # ------------------------------------------------------------------ the parent half

  # A window and a document small enough to read. `frames` is the list the parent re-queries
  # per message — re-queried rather than captured, because a widget saved over AJAX inserts a
  # frame after page load.
  def parent_harness(frames:, messages:)
    <<~JS
      var listeners = {};
      var loadHandlers = [];
      var readyHandlers = [];

      var frames = #{frames};
      frames.forEach(function (f) {
        f.style = {};
        f.className = 'reporter-report-frame';
        // The attribute bag the parent keeps its per-frame write budget in. Real
        // attributes are strings, including the ones written as numbers, so this returns
        // strings — a bag that handed back integers would hide a `parseInt` that is not
        // there.
        f.attributes = {};
        f.getAttribute = function (name) {
          return Object.prototype.hasOwnProperty.call(this.attributes, name)
            ? this.attributes[name] : null;
        };
        f.setAttribute = function (name, value) { this.attributes[name] = String(value); };
      });

      global.document = {
        querySelectorAll: function () { return frames; }
      };
      global.window = {
        addEventListener: function (name, fn) { (listeners[name] = listeners[name] || []).push(fn); }
      };
      global.jQuery = function (subject) {
        return {
          ready: function (fn) { readyHandlers.push(fn); },
          on: function (name, fn) { if (name === 'load') { loadHandlers.push(fn); } },
          length: 0,
          val: function () {}
        };
      };
      global.jQuery.fn = {};

      #{File.read(FrameAutoHeightSpecSupport::PARENT_PATH, encoding: 'UTF-8')}

      // The page finishing: this is where the parent asks every frame for its height.
      readyHandlers.forEach(function (fn) { fn(); });
      loadHandlers.forEach(function (fn) { fn(); });

      (#{messages}).forEach(function (message) {
        (listeners.message || []).forEach(function (fn) { fn(message); });
      });

      console.log(JSON.stringify(frames.map(function (f) {
        return {
          height: f.style.height,
          minHeight: f.style.minHeight,
          asked: f.asked || 0,
          writes: f.getAttribute('data-rrd-height-writes')
        };
      })));
    JS
  end

  # THE SELECTOR, ASSERTED ON THE SOURCE. The harness's `querySelectorAll` ignores its
  # argument and hands back every frame, which is what makes the identity examples readable
  # — and it means nothing in this file would notice the parent looking for the wrong
  # element. A frame whose class the helper stopped emitting would leave the protocol
  # silently dead on every page. `PAGE_CHROME` and `WIDGET_CHROME` both start with the class
  # the selector names, so the two cannot drift apart without this failing.
  it 'looks for the element the frame helper actually emits' do
    source = File.read(FrameAutoHeightSpecSupport::PARENT_PATH, encoding: 'UTF-8')
    frame = RedmineReporterDashboards::ReportFrame

    expect(source).to include("querySelectorAll('iframe.#{frame::PAGE_CHROME}')")
    expect(frame::WIDGET_CHROME.split.first).to eq(frame::PAGE_CHROME)
  end

  # One frame whose `contentWindow` is a recognisable object, so identity can be asserted
  # rather than assumed.
  FRAMES_ONE = <<~JS
    [{ contentWindow: { id: 'a', postMessage: function () { this.owner.asked = (this.owner.asked || 0) + 1; } } }]
      .map(function (f) { f.contentWindow.owner = f; return f; })
  JS

  def run_parent(messages)
    JSON.parse(node(parent_harness(frames: FRAMES_ONE, messages: messages)))
  end

  it 'sets the height a frame reports, and clears the CSS floor so it can shrink' do
    result = run_parent("[{ source: { id: 'x' }, data: { rrdFrameHeight: 812 } }]")
    # `source` is a DIFFERENT object with the same shape, so identity is what decides.
    expect(result.first['height']).to be_nil

    result = run_parent(
      "[{ source: document.querySelectorAll()[0].contentWindow, data: { rrdFrameHeight: 812 } }]"
    )
    expect(result.first['height']).to eq('812px')
    expect(result.first['minHeight']).to eq('0')
  end

  it 'asks every frame for its height when the page is ready, so the ordering cannot lose one' do
    result = run_parent('[]')
    # Twice: once on ready, once on load. A frame that answered the first is unharmed by the
    # second — it sends the same number — and a frame inserted between them needs the second.
    expect(result.first['asked']).to eq(2)
  end

  # THE ADVERSARIAL HALF, and the reason this is a node spec rather than a system test.
  it 'ignores everything that is not a positive finite number from the right frame' do
    hostile = [
      '{ source: document.querySelectorAll()[0].contentWindow, data: null }',
      '{ source: document.querySelectorAll()[0].contentWindow, data: "600" }',
      '{ source: document.querySelectorAll()[0].contentWindow, data: { rrdFrameHeight: "600" } }',
      '{ source: document.querySelectorAll()[0].contentWindow, data: { rrdFrameHeight: -5 } }',
      '{ source: document.querySelectorAll()[0].contentWindow, data: { rrdFrameHeight: 0 } }',
      '{ source: document.querySelectorAll()[0].contentWindow, data: { rrdFrameHeight: Infinity } }',
      '{ source: document.querySelectorAll()[0].contentWindow, data: { rrdFrameHeight: NaN } }',
      '{ source: document.querySelectorAll()[0].contentWindow, data: { rrdFrameHeight: { valueOf: function () { return 900; } } } }',
      '{ source: { id: "other" }, data: { rrdFrameHeight: 900 } }'
    ]

    result = run_parent("[#{hostile.join(',')}]")
    expect(result.first['height']).to be_nil
    expect(result.first['minHeight']).to be_nil
  end

  # THE OSCILLATION, which is the failure a live layout produces and which the first version
  # of this file could not see: it drove hostile VALUES and never a hostile SEQUENCE.
  #
  # Two media queries in a report's own CSS make the height a two-cycle — 2000 at a short
  # viewport, 100 at a tall one — and the child's one-step `last` memo does not damp a
  # cycle, because neither value ever equals the one before it. Unbounded, this runs at
  # ResizeObserver frequency for as long as the dashboard is open. Found by an independent
  # review.
  it 'stops writing a frame that never settles, rather than following it forever' do
    alternating = (1..60).map do |n|
      height = n.odd? ? 2000 : 100
      "{ source: document.querySelectorAll()[0].contentWindow, " \
        "data: { rrdFrameHeight: #{height} } }"
    end

    result = run_parent("[#{alternating.join(',')}]")

    # The budget, spelt out rather than read from the source: twenty writes, then nothing.
    expect(result.first['writes']).to eq('20')
    # And it is still a real height, not a frame left at zero or cleared.
    expect(result.first['height']).to match(/\A(?:2000|100)px\z/)
  end

  # THE BUDGET IS SPENT BY CHANGE, NOT BY MESSAGES. A frame that answers the parent's
  # request with the height it already has must not cost anything, or a page that asks twice
  # — which this one does, on ready and on load — would burn two of every frame's twenty.
  it 'does not spend the budget on a height it is already at' do
    repeats = (1..30).map do
      "{ source: document.querySelectorAll()[0].contentWindow, data: { rrdFrameHeight: 500 } }"
    end

    result = run_parent("[#{repeats.join(',')}]")

    expect(result.first['writes']).to eq('1')
    expect(result.first['height']).to eq('500px')
  end

  # A frame is a box on somebody's dashboard. A report that could name its own height without
  # a ceiling could take the page.
  it 'clamps an absurd height rather than obeying it' do
    result = run_parent(
      '[{ source: document.querySelectorAll()[0].contentWindow, data: { rrdFrameHeight: 9e9 } }]'
    )
    expect(result.first['height']).to eq('20000px')
  end

  # ------------------------------------------------------------------- the child half

  def run_child(script_tail)
    JSON.parse(node(<<~JS))
      var posted = [];
      var listeners = {};
      var bodyHeight = 400;

      global.window = {
        parent: { postMessage: function (message) { posted.push(message); } },
        addEventListener: function (name, fn) { (listeners[name] = listeners[name] || []).push(fn); }
      };
      global.window.parent.parent = global.window.parent;
      global.document = {
        readyState: 'complete',
        addEventListener: function () {},
        get body() { return { scrollHeight: bodyHeight, offsetHeight: bodyHeight }; }
      };

      #{FrameAutoHeightSpecSupport.child_script}

      #{script_tail}

      console.log(JSON.stringify(posted));
    JS
  end

  it 'posts its content height once, and not again for the same height' do
    posted = run_child('(listeners.message || []).forEach(function (fn) { fn({ data: {} }); });')
    expect(posted).to eq([{ 'rrdFrameHeight' => 400 }])
  end

  # THE HANDSHAKE, and it is what makes the ordering irrelevant. On `/my/page` the parent's
  # script is included in body position, so a frame has always already posted by the time the
  # listener exists. Without the answer to a request, that frame keeps its CSS floor for ever.
  it 'answers a request even when it has already sent that exact height' do
    posted = run_child(<<~JS)
      (listeners.message || []).forEach(function (fn) {
        fn({ data: { rrdFrameHeightRequest: true } });
      });
    JS

    expect(posted).to eq([{ 'rrdFrameHeight' => 400 }, { 'rrdFrameHeight' => 400 }])
  end

  # ------------------------------------------------------------------- the frame element

  it 'ships the script inside the frame document and nowhere else' do
    document = RedmineReporterDashboards::ReportFrame.document('<p>x</p>')

    expect(document).to include('rrdFrameHeight')
    # The PDF binding shares `ReportDocument` and must NOT carry it: a PDF has no parent.
    expect(RedmineReporterDashboards::ReportDocument.wrap('<p>x</p>')).not_to include('rrdFrameHeight')
  end

  # The token that would make all of this unnecessary and the sandbox pointless. Asserted on
  # the constant, beside the code that would have been the temptation.
  it 'still has no allow-same-origin' do
    expect(RedmineReporterDashboards::ReportFrame::SANDBOX).to eq('allow-scripts')
    expect(RedmineReporterDashboards::ReportFrame::AUTO_HEIGHT_SCRIPT)
      .not_to include('allow-same-origin')
  end

  # ES5, for the reason `mermaid_boot.js` is: this runs inside whatever engine draws the
  # document, and one arrow function kills the whole block at parse time on the oldest.
  it 'is ES5, like every other script this plugin puts inside a document' do
    # COMMENTS ARE STRIPPED FIRST. The prose in this script quotes identifiers in backticks
    # the way the rest of the repository does, and a check that punished that would teach
    # people to delete the rationale — which is `no_thread_local.sh`'s own lesson, in a
    # different file.
    code = FrameAutoHeightSpecSupport.child_script.gsub(%r{//[^\n]*}, '')

    expect(code).not_to match(/=>/)
    expect(code).not_to match(/\b(?:const|let|class)\s/)
    expect(code).not_to include('`')
    expect(code).not_to include('...')
  end
end
