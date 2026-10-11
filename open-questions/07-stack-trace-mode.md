# Which stack trace mode by default?

**Already built:** `stackTraceMode` defaults to `"all"`
(`launch.decode_config`).

## Where and when it came up

`int` has three stack trace modes, set with `int:stack_trace/1`: `all`,
`no_tail` and `false`. ElixirLS exposes the same option, and
[docs/elixirls-features.md](../docs/elixirls-features.md) already proposes
`all` as the default. It is recorded here because testing a long-running
loop (`fixtures/sample`'s `loop_main`) showed the memory cost, which makes
the default worth a second look.

## What I chose

`all`, with `no_tail` and `false` available, and `true`/`false` accepted as
aliases for `all`/`false`.

## Options

### A. `all` (chosen)

- Tail calls stay on the stack, so the call stack shows how the code got
  there. Gleam has no loops; everything is recursion and tail calls, so with
  `no_tail` most frames vanish.
- `int`'s `next` behaves better: a tail call adds a level, so it isn't
  stepped into.
- Memory grows with every tail call in a long-running loop (a server's
  receive loop, a recursive counter), as the interpreter keeps every frame.

### B. `no_tail`

- Bounded memory in long-running loops.
- Stack traces often show only the current function; step over relies more
  on the adapter's tail-call correction.

### C. `false`

- Fastest, least memory.
- No stack trace beyond the current frame, and step out can't work.

## Why

Most debugging sessions are short and the stack is what people look at. The
memory cost only matters for long loops, and the README says to switch to
`no_tail` for those.

## How to change it

The default in `launch.decode_config` (`src/gleam_dap/launch.gleam`) and in
`editors/vscode/package.json`.
