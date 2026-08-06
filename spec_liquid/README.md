# `spec_liquid/` — the specs that need the real Liquid gem

**Why this is not under `spec/`.**

`spec/spec_helper.rb` defines a minimal `Liquid` stub so the DB-less specs can load the
plugin's tags without the gem installed. That stub and the real gem **cannot coexist in
one process**: whichever is defined first wins, and the two disagree about things the
tag specs depend on — `Liquid::Tag.new` is public on the stub and *private* on Liquid 5,
and the constructor signatures differ.

Keeping these files under `spec/` was tried and is what proved it. `rspec spec` loads
every `*_spec.rb` it finds, so a file here requiring the real gem pulled it into the
shared process and broke 200+ tag examples that had loaded the stub — an ordering
failure that depends on filename order, which is the worst kind.

So they live in their own directory and run as their own invocation:

```bash
bundle exec rspec -r liquid spec_liquid
```

`-r liquid` requires the gem **before** any spec file loads, so there is no window in
which the stub could win.

**This is a workaround for a migration nobody has done yet**, not a design. The tag
specs are written against the stub's constructor; moving them onto the real gem is
`implementation-plan.md` §Findings **E-7**, and it belongs with T-18/T-19, which rewrite
those tags anyway. When that lands, this directory folds back into `spec/`.
