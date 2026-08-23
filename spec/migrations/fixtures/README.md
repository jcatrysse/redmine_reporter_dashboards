# Migration lint fixtures — one broken migration per rule

These are **not** migrations. Nothing runs them, and they are deliberately outside
`db/migrate/` so Rails never sees them. Each one breaks exactly one of
`script/gates/migration_reversibility.rb`'s rules, and `../reversibility_spec.rb` asserts
that the rule it breaks is the rule that fires.

## Why they exist

The failure mode of reading an AST is the opposite of a regexp's: a construct the reader
never learned makes it return **nothing**, and every assertion built on it passes
vacuously. `docs/plan/HANDOVER.md` §1 records this costing T-40 a whole gate — its review
got past the permission check four times with ordinary controller code — and the answer
there was the same as the answer here: a directory of fixtures the reader must be able to
see.

**Eight of these are bypasses an independent review walked straight through** — `021`…`028`
were each CLEAN against the first version of the reader, which reported nothing at all:

| fixture | what it does | why the first reader missed it |
|---|---|---|
| `021` | `define_method(:down)` | the `def` scan only sees `DEFN` nodes |
| `022` | `c = connection; c.update(…)`, `send(:execute, …)` | the data rule required a *receiverless* call |
| `023` | `"…".constantize.update_all` | reaches a model without ever writing a constant |
| `024` | `create_table …, if_not_exists: true` | not an `if`, and its **down is unconditional** — it drops a table it did not create |
| `025` | `t.index` inside `create_table` | the length rule only looked at `add_index` |
| `026` | `add_index …, name: <a variable>` | fell back to measuring the *derived* name, which the database never sees |
| `027` | `change_column`, blockless `drop_table` | Rails raises `IrreversibleMigration` at down-time; nothing checked for it |
| `sub/028` | a migration in a **subdirectory** | Rails globs `**/[0-9]*_*.rb`; the reader globbed one level |

`024` is the sharpest of them. It reads like a safe guard and it is the exact hazard FR-69
clause 2 exists to prevent, wearing a keyword argument: Rails records the `create_table` and
inverts it to a plain `drop_table`, so the guard applies to the up direction only.

**Three of the reader's own bugs were found by these files and by nothing else**, all
during T-36 and all silent:

1. `add_index`'s arguments live at `children[1]` on an `FCALL` and `children[2]` on a
   `CALL`. Reading `children[2]` unconditionally returned `nil`, so **every** index in
   the tree passed the length rule. Found by `014_long_index.rb`.
2. `ActiveRecord::IrreversibleMigration` parses as `COLON2` whose second child is a plain
   **Symbol**, not a `CONST` node — so a search for a `CONST` by that name found nothing.
   Found by `015_irreversible.rb`.
3. `Node#children` builds **fresh wrapper objects on every call**, so `object_id` is not
   a stable identity and the "skip the constant nested inside a `::`" logic skipped
   nothing. Every migration in the tree reported a spurious bare `ActiveRecord`. Found by
   running the reader against the real `db/migrate/`.

## The rule

**If you extend the reader, add a fixture.** A construct that is not in this directory is
a construct the gate cannot see, and a gate that cannot see something reports it as clean.
`reversibility_spec.rb` has a meta-test asserting that *every* rule id in
`MigrationReversibility::RULES` is fired by at least one fixture, so forgetting is a test
failure rather than a quiet hole.
