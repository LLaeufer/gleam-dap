# How do dicts, functions, pids and long values look?

**Already built:** `src/gleam_dap/value.gleam` renders values the way Gleam
code or `echo` would show them, with limits.

## Where and when it came up

Step 3 of PLAN.md lists the built-ins to render and says to "fall back to
Erlang notation for anything we cannot type". The open details were the
types Gleam has no literal syntax for, and how big a rendered value may get
(the ElixirLS weaknesses list in the plan calls out "no size limit").

## What I chose

| Value | Shown as |
| --- | --- |
| Custom type with labels | `Person(name: "Ada", age: 36)` |
| Custom type without labels / atom | `Circle(2.0)`, `Nil`, `True`, `Some(1)` |
| String | `"Hello"` with Gleam escapes |
| Non-UTF-8 binary, bit array | `<<255, 0>>`, `<<1:3>>` |
| List, tuple | `[1, 2, 3]`, `#(1, "a")` |
| Map | `dict.from_list([#("a", 1)])` |
| Function | `//fn lists.map/2`; anonymous ones as `//fn(_, _) { … } in sample.main` |
| Pid, reference, port | `//erl(<0.83.0>)`, `//erl(#Ref<...>)`, `//erl(#Port<...>)` |
| Float | Gleam's float format (`2.0`, `1.0e-10`) |

Values are cut after 1,000 characters and collections after 100 items in
the one-line view. Expanding a list, map or tuple with more than 100 items
pages it (see [21-paging.md](21-paging.md); before PR #5 expanding showed
only the first 100).

## Options

### A. Gleam-style with `//`-prefixed opaque values (chosen)

- Matches what Gleam's `echo` and `string.inspect` print, so values look
  familiar, and opaque values are clearly not Gleam literals.
- Some forms can't be pasted back into code (`//fn ...`).

### B. Erlang notation for everything that isn't a custom type

- Unambiguous for Erlang users.
- `#{<<"a">> => 1}` in a Gleam debugger is exactly what the plan wants to
  avoid.

### Limits: 1,000 characters and 100 items (chosen) vs. no limits vs. smaller

- Keeps the variables view responsive with huge values.
- Items past the 100th are paged when expanding (built in PR #5).
- Smaller limits truncate ordinary records; no limits can freeze the editor
  on a large list.

## Why

A follows Gleam's own printing conventions, and the limits fix a known
ElixirLS weakness.

## How to change it

`render` in `src/gleam_dap/value.gleam`; the limits are the defaults of
`value.Options`.
