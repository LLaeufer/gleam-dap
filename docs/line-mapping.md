# Line mapping: from `.gleam` lines to what the BEAM runs

The debugger has to answer two questions all the time:

1. **Gleam → BEAM.** The user clicks line 12 of `src/app/user.gleam`. Which
   module and which line does `int` need a breakpoint on?
2. **BEAM → Gleam.** A process stopped in module `app@user` at line N. Which
   file and line should the editor highlight, and what do the stack frames say?

This document explains the options, what we verified, and the plan.

## Summary

- **Gleam v1.19.0 (released 5 October 2026) solves most of this for us.**
  It no longer generates Erlang source. It now emits Erlang abstract forms
  (`_gleam_artefacts/<module>.abstr`) whose annotations hold the **original
  Gleam line of every expression**. The forms are compiled with `debug_info`,
  so the BEAM files carry the same lines. We verified that `int` then stops
  on, steps through and reports Gleam lines with no translation at all.
- For Gleam before 1.19 there is no usable line information: only one `-file`
  attribute per function. We would have to compute the mapping ourselves,
  which is possible but large.
- **Plan:** support Gleam ≥ 1.19 only, use its line numbers directly, and build
  a thin layer for what lines alone don't cover: file paths, breakpoint
  validation, columns and stepping through compiler-generated code. The
  pre-1.19 approaches are documented below in case we ever need them.

## What we verified

All experiments used a fixture covering pipelines, `use`, anonymous
functions, multi-line expressions, `case` with guards, record updates,
`let assert`, blocks and string concatenation.

### Gleam 1.12 (generates `.erl` source)

- One `-file("src/foo.gleam", N).` attribute in front of each function, with
  `N` the line where the Gleam function starts. Nothing inside function
  bodies.
- `int` ignores those attributes for breakpoints: it undoes them
  (`epp:interpret_file_attribute/1` in `dbg_iload`), so breakpoint and
  `break_at` lines are **raw lines of the generated `.erl` file**.
- `epp:parse_file/2` on the same file *does* apply the `-file` attributes.
  That gives "Gleam function start + offset in the Erlang file" lines that
  look Gleam-like but are wrong inside function bodies.

### Gleam 1.19 (generates abstract forms)

- Every expression is annotated with its Gleam line, including inner
  expressions. Examples from the fixture:
  - A three-line pipeline `x |> double |> double` becomes `_pipe = X` (line
    18), `_pipe@1 = double(_pipe)` (19), `double(_pipe@1)` (20).
  - `use y <- with_callback` becomes a call at line 24 whose callback body
    keeps lines 25 and 26.
  - A multi-line `let total = double(1) + double(2)` keeps line 41 on the
    `let`, 42 and 45 on the calls and 43 and 46 on the arguments.
  - `let assert 1 = x` becomes a `case` on line 61 whose success clause
    holds the rest of the function (lines 62 to 66) and whose failure clause
    raises the Gleam error map, also on line 61.
- A module-level `-file("src/foo.gleam", 0)` attribute names the source file.
- `int:i({Module, GleamSrcPath, BeamPath, BeamBinary})` interprets the
  module. Breakpoints, `break_at` events, stepping and backtraces all use
  Gleam lines: stepping from line 9 went 9 → 10 → 11 → 12, then into
  `greet/1` at 16 and 17.
- Stack traces from compiled (non-interpreted) code also say
  `{file, "src/rich.gleam"}, {line, 61}`.
- The BEAM file's `compile_info` has no `source` (the compiler uses
  `compile:forms/2`), so `int:i(Module)` cannot find the source by itself. We
  pass the Gleam path explicitly using the four-tuple form above.
- Gleam 1.19's build script uses the `maybe` expression, so it needs
  **OTP 27 or newer**. Our experiments ran the abstract forms on OTP 25, so
  `int` on OTP 27 and 28 is still to be checked (step 1).
- Only lines are recorded, no columns.

## Approaches

### A. Native Gleam 1.19 line numbers (chosen)

Use the Gleam lines that 1.19 puts in the BEAM files as they are.

- **Gleam → BEAM:** file path to module name (`src/app/user.gleam` →
  `app@user`), line unchanged.
- **BEAM → Gleam:** module to file path through the module's `-file`
  attribute (read from the `debug_info` chunk), line unchanged.

| Advantages | Disadvantages |
| --- | --- |
| No mapping to build or keep correct. | Requires Gleam ≥ 1.19 and OTP ≥ 27. |
| Accurate down to inner expressions. | Lines only, no columns. |
| Also correct in stack traces of non-interpreted code. | Depends on Gleam keeping this behaviour, though it's a stated goal of the change. |

### B. Compute a mapping and rewrite the annotations (pre-1.19)

Compute a Gleam ↔ Erlang line table (see D, E or F below), then rewrite the
annotations of the generated Erlang forms with Gleam lines before handing
them to `int`:

1. `epp:parse_file/2` on the generated `.erl`, then
   `epp:interpret_file_attribute/1` to get raw `.erl` lines back.
2. `erl_parse:map_anno/2` to replace every line using the table.
3. `compile:forms/2` with `debug_info` to get a BEAM binary in memory.
4. `int:i({Module, GleamSrcPath, BeamPath, Binary})`.

We verified this works: with a hand-written table, `int` stopped on and
stepped through Gleam lines exactly as in A. Its advantage over translating
at runtime (C) is that `int` sees Gleam lines everywhere, so nothing else in
the adapter needs to know about mapping.

| Advantages | Disadvantages |
| --- | --- |
| Works with older Gleam versions. | Only as good as the table it is given. |
| Once applied, the rest of the adapter is identical to A. | Interpreted code differs from what is on disk; non-interpreted stack traces still show `.erl` lines. |

### C. Translate at the adapter boundary (pre-1.19)

Keep `int` working on raw `.erl` lines and translate in both directions in the
adapter: on `setBreakpoints`, on every `stopped` event and on every stack
frame.

| Advantages | Disadvantages |
| --- | --- |
| No recompilation; `int` loads the files as they are. | Every place that touches a line must translate, in both directions. |
| | One Gleam line can map to several Erlang lines and the other way round, so breakpoints need several `int` breakpoints and stepping needs filtering. |

B is simpler than C for the same table, so if we ever need pre-1.19 support,
B is the way to apply a mapping.

### D. Align the two syntax trees (pre-1.19, to build the table)

Parse the Gleam source with [`glance`](https://hexdocs.pm/glance/) (which
gives byte spans for every node) and the generated Erlang with `epp`. Pair
functions by name (Gleam `foo/bar.baz` ↔ Erlang `foo@bar:baz`), then walk both
function bodies together, pairing each Gleam statement with the Erlang
expressions generated for it:

- `let x = e` ↔ `X = E` (watch for renamed shadowed variables, `X@1`).
- A pipeline of N steps ↔ N matches on `_pipe`, `_pipe@1`, ...
- `use` ↔ a call whose last argument is a `fun`.
- `let assert` ↔ a `case` with the rest of the function in its success clause.
- `case` ↔ `case`, clause by clause, guards included.

| Advantages | Disadvantages |
| --- | --- |
| Accurate for every construct we teach it. | A lot of code, mirroring every desugaring in Gleam's code generator. |
| Gives statement-level and often expression-level lines. | Breaks when the compiler output changes, which it did completely in 1.19. |
| | `glance` must parse exactly the same Gleam version as the compiler. |

### E. Match tokens heuristically (pre-1.19, to build the table)

Fingerprint each line by its identifiers, literals and calls (for example
`double`, `"Hi "`, `1`) and match Gleam lines to Erlang lines with similar
fingerprints, in order, within each function.

| Advantages | Disadvantages |
| --- | --- |
| Small and independent of the compiler's internals. | Guesses: lines like `x` or `}` have no fingerprint, repeated calls are ambiguous. |
| Degrades gracefully. | Wrong guesses put breakpoints in the wrong place, which is worse than no breakpoint. |

### F. Function-level only (pre-1.19, simplest)

Use the `-file` attributes as they are: a breakpoint anywhere in a Gleam
function becomes a breakpoint on the first expression of the Erlang function,
and stops are reported at the function's first line.

| Advantages | Disadvantages |
| --- | --- |
| Almost no code, robust. | Stepping is useless: every step reports the same line. |
| Good enough to inspect arguments. | Breakpoints in the middle of a function stop at its start. |

### G. Patch the Gleam compiler (rejected)

Fork the Gleam compiler to emit line annotations or a source map. Gleam 1.19
did exactly this upstream, so there is nothing left to gain.

### H. Use a different debugger engine than `int`

OTP 28 added `erl_debugger`, a native debugging API used by WhatsApp's
[edb](https://github.com/WhatsApp/edb). It doesn't interpret code, so it is
much faster than `int`, and its line breakpoints come from the compiled code's
line table, which in Gleam 1.19 holds Gleam lines. It needs the `+D` emulator
flag and modules compiled with `beam_debug_info`, which Gleam doesn't pass.
We could recompile Gleam modules from their `debug_info` with that option.
The API is marked highly experimental, and only one debugger can be attached
per VM. This doesn't change the line-mapping plan, since lines are the same,
but it's a possible later replacement for `int` if speed becomes a problem.

## The plan (Gleam ≥ 1.19)

Lines are free. These are the pieces that remain, in the order we build
them.

### 1. Module and file index

Build when the session starts and refresh after each `gleam build`.

- For each module in `build/dev/erlang/*/ebin`, read the `-file` attribute
  from its `debug_info` to get its Gleam path. Resolve the path against the
  package root: the project itself, or `build/packages/<dep>/` for
  dependencies.
- Keep both directions: absolute `.gleam` path ↔ module atom.
- Modules without a Gleam file (Erlang FFI modules, OTP) are marked as such.
  Breakpoints in `.erl` FFI files can still work through their own source.

### 2. Breakable lines and breakpoint validation

`int:break/2` accepts any line, even one with no code, and then never stops.
To avoid silent breakpoints:

- Walk each module's abstract code once and collect the set of lines that
  start an expression `int` can stop on, per function.
- On `setBreakpoints`, move a breakpoint on a line without code to the next
  breakable line in the same function and report it with `verified: true`
  and the new line. A line outside any function is reported as unverified
  with a reason.
- Support DAP's `breakpointLocations` request from the same data.

### 3. Columns and several stops per line

Lines are all we have, so:

- Report `column: 1` (or the first non-blank column of the line) on stack
  frames.
- An anonymous function on the same line as its caller (`list.map(xs, fn(x)
  { x + 1 })`) shares that line. A breakpoint there stops both when the call
  is made and inside the function. That is acceptable for a first version
  and matches how Erlang debuggers behave.

### 4. Stepping through generated code

Gleam's desugarings add Erlang code that has a Gleam line but no Gleam
meaning of its own:

- **`let assert` failure clauses** raise the error on the same line as the
  `let assert`. Stepping never lands there unless the assertion fails, which
  is the right place to stop anyway.
- **Pipelines** produce `_pipe` variables. Each pipeline step has its own
  line, so stepping already moves one step at a time. The `_pipe` variables
  are hidden in the variables view (see the feature plan).
- **Tail calls.** `int`'s "next" (step over) stops at the next line on the
  same stack level or lower. A call in tail position replaces the caller's
  frame, so the callee runs on the same level and step over stops inside it.
  We saw this with `use`: stepping over line 24 (`use y <- with_callback`)
  stopped at line 14 inside `with_callback`, then at 25 and 26 in the
  callback. Gleam code is full of tail calls (every function's last
  expression), so this needs fixing for stepping to feel right. Our "step
  over" keeps issuing `next` while the process is in a function other than
  the one it started in, unless that function is an anonymous function
  defined inside the starting function (such as a `use` callback). For the
  `use` example this gives 24 → 25 → 26. A step limit stops runaway loops,
  and a breakpoint hit along the way always stops.
- **Calls into non-interpreted modules** (dependencies, OTP) can't be
  stepped into; `int` steps over them automatically.

### 5. Stack frames

- Frames from `int:meta(Meta, backtrace, all)` give module, function and
  arguments. The current line of each frame comes from the meta process's
  `stack_frame` calls.
- Show Gleam names: `app@user` → `app/user`, and anonymous functions
  (`-pipes/1-fun-0-`) as "anonymous function in `pipes`".
- Frames in non-interpreted code use the line from the process's
  stacktrace, which 1.19 also gives in Gleam lines.

### 6. Version check

At launch, run `gleam --version` and refuse to start with a clear error for
Gleam < 1.19 or OTP < 27, naming the versions found.

## Tests

- A fixture project with one module per construct above.
- Golden tests: for each fixture module, the list of breakable lines and the
  module ↔ file index, so a compiler change that alters them shows up as a
  test diff.
- Integration tests that set a breakpoint on each interesting line, step
  through and assert the reported lines.

## Sources

- [Gleam doesn't compile to Erlang source anymore](https://gleam.run/news/gleam-doesnt-compile-to-erlang-source-anymore/) (Gleam v1.19.0 announcement)
- [`erl_debugger` documentation](https://www.erlang.org/doc/apps/kernel/erl_debugger.html)
- [edb](https://edb.hexdocs.pm/readme.html)
- Experiments run in the planning session with Gleam 1.12.0 and 1.19.0 and
  OTP 25, as described above.
