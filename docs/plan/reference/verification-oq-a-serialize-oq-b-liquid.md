# Verification — OQ-A (`serialize … coder:`) and OQ-B (`{{ issue.closed? }}`)

Both were flagged in `technical-spec.md` §12 as candidate **existing defects**, to be checked
before anything was built on top of them. Both were measured on 2026-08-04. **Both original
claims are wrong**, and OQ-B's correction changes what §3.2 is allowed to do.

Method: run the construct, on the real gem versions, and read the result — rather than reason
about the signature. Everything below is reproducible with the two scripts at the end.

---

## OQ-A — `serialize :layout, coder: YAML` on Rails 6.1

**Claim under test:** the keyword form is Rails 7.1+, so `app/models/reporter_project_tab.rb:9-10`
already breaks on Redmine 5.1 / Rails 6.1 — which would make the 5.1 support claim false today.

**Result: it works, identically, on all three Rails majors in the span.** Not "works by luck at
class definition and fails later": a full write → raw-column → read-back round trip produces the
same bytes on every version.

| activerecord | class defines | raw column after write | reads back | `== written` |
|---|---|---|---|---|
| 6.1.7.10 | OK | `---\n- columns:\n  - - a\n    - b\n  - - c\n` | `[{"columns"=>[["a","b"],["c"]]}]` | true |
| 7.2.3.2 | OK | *identical* | *identical* | true |
| 8.1.3 | OK | *identical* | *identical* | true |

`nil` stays `nil`, dirty tracking still fires, and `settings` behaves the same.

**Mechanism** — and it matters, because it is not the mechanism anyone assumed. Rails 6.1's
signature is:

```ruby
# activerecord-6.1.7.10/lib/active_record/attribute_methods/serialization.rb:66
def serialize(attr_name, class_name_or_coder = Object, **options)
```

Identical in **6.1.0**, so this holds for every 6.1 patch level, not just the latest. That
`**options` swallows `coder: YAML` and **ignores it**, leaving `class_name_or_coder` at its
`Object` default — which selects the YAML coder anyway. The two paths coincide.

Rails 7.2 and 8.1 changed the signature to `serialize(attr_name, coder: nil, type: Object, …)`,
where the keyword is read rather than discarded. So the same source line means two different
things and produces one result.

**Disposition:**

- `reporter_project_tab.rb:9-10` is **not** an existing defect. The Redmine 5.1 support claim is
  not falsified by it.
- `CLAUDE.md` §5's forbidden-construct row for this line, and its stated reason ("Rails 6.1 does
  not accept it"), were factually wrong and are corrected.
- **The `compat/serialize.rb` shim is still worth having, for a different and better reason.** On
  6.1 the keyword is *silently discarded*, so `serialize :x, coder: JSON` there would store YAML
  with no error at all. The construct is safe only while the intended coder happens to be the
  default one. That is a latent trap for the next person, not a present bug.
- The positional forms are the ones that are **not** portable, in the opposite direction:
  `serialize :layout, YAML` raises `ArgumentError: wrong number of arguments` on 7.2 and 8.1, and
  `serialize :layout, Hash` works on 6.1 only.

---

## OQ-B — is `{{ issue.closed? }}` parseable by Liquid?

**Claim under test** (`technical-spec.md` §3.2): "`{{ issue.closed? }}` is very likely not
parseable", which would mean five delegated `?` accessors on the gem's `IssueDrop` were never
reachable — dead surface, free to drop.

**Result: it parses AND resolves, on Liquid 4.0.4 and 5.13.0, in all three error modes**
(`lax`, `warn`, `strict`), bare, inside `{% if %}`, and through a filter.

```
{{ issue.subject }}                              => "SUBJECT"
{{ issue.closed? }}                              => "CLOSED-Q"
{{ issue.visible? }}                             => "VISIBLE-Q"
{{ issue.is_private? }}                          => "PRIVATE-Q"
{{ issue["closed?"] }}                           => "CLOSED-Q"
{% if issue.closed? %}YES{% else %}NO{% endif %} => "YES"
{{ issue.closed? | upcase }}                     => "CLOSED-Q"
A{{ issue.closed? }}B                            => "ACLOSED-QB"
```

The parser keeps the `?` as part of the lookup, rather than dropping or choking on it:

```
issue.closed?  -> VariableLookup @name="issue", @lookups=["closed?"]
```

**Mechanism:** Liquid's lexer allows a trailing `?` on a variable segment *explicitly*. It is a
deliberate feature, not an accident of a permissive regex:

```ruby
# liquid 4.0.4  lib/liquid.rb:31,41
VariableSegment = /[\w\-]/
VariableParser  = /\[[^\]]+\]|#{VariableSegment}+\??/o
#                                                ^^^
# liquid 5.13.0 lib/liquid.rb:36,46 — same trailing \?? on the modern bracket form
VariableParser  = /\[(?>[^\[\]]+|\g<0>)*\]|#{VariableSegment}+\??/o
```

**Disposition — this one has teeth:**

- The five `?` accessors were **always reachable**. They are not dead surface.
- §3.2's plan (rename to bare names, keep the `?` spellings as aliases) is still right, but its
  *justification* is inverted: keeping the aliases is a **backward-compatibility requirement**,
  because a real template may use them. Dropping them would be a breaking change, not a cleanup.
- A template linter rule that flags `{{ … .closed? }}` as unparseable would be wrong.
- Relevant version fact: Liquid arrives pinned **`> 4.0, < 5.0`** via the `redmineup` gem
  (`gem dependency redmineup -v 1.1.12`), so 4.x is what production actually runs today. Both
  4.x and 5.x behave the same here, so the owned layer's floor does not turn on this.

---

## Reproducing

Neither script needs Redmine, a database, or either plugin.

**OQ-A** — one `Gemfile` per version (`activerecord` + `sqlite3`), then:

```ruby
require 'logger'   # Ruby 3.3 no longer has Logger loaded before ActiveSupport 6.1 wants it;
                   # an artefact of running 6.1 on 3.3, not part of what is under test
require 'active_record'
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Schema.define { create_table(:tabs, force: true) { |t| t.text :layout, :settings } }

class Tab < ActiveRecord::Base
  serialize :layout, coder: YAML       # exactly reporter_project_tab.rb:9
  serialize :settings, coder: YAML
end

Tab.create!(layout: [{ 'columns' => [%w[a b], ['c']] }], settings: { 'x' => 1 })
puts Tab.connection.select_value('SELECT layout FROM tabs LIMIT 1').inspect
puts Tab.first.layout.inspect
```

**OQ-B** — one `Gemfile` per version (`liquid`), then:

```ruby
require 'liquid'

class IssueProbe < Liquid::Drop
  def closed?   = 'CLOSED-Q'
  def closed    = 'CLOSED-BARE'
  def subject   = 'SUBJECT'
end

%i[lax warn strict].each do |mode|
  puts Liquid::Template.parse('{{ issue.closed? }}', error_mode: mode)
                       .render('issue' => IssueProbe.new).inspect
end
```
