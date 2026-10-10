# gleam-dap: plan

A debugger for Gleam programs running on the Erlang VM, speaking the
[Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/)
(DAP) so it works in VS Code and in IntelliJ through
[LSP4IJ](https://github.com/redhat-developer/lsp4ij).

This is a personal tool for exploring Gleam more comfortably. It is not
intended for upstreaming.

## Goals for the first version

- Launch a Gleam project (Erlang target) from the editor and stop on
  breakpoints set in `.gleam` files.
- Continue, step over, step into and step out.
- See every BEAM process that is stopped as a thread, with a stack trace that
  points at `.gleam` lines.
- Inspect local variables with Gleam names and Gleam-looking values.
- Work in VS Code and IntelliJ (LSP4IJ).

### Not in the first version

- The JavaScript target.
- Attaching to an already running node or a remote node.
- Evaluating Gleam expressions in the debug console. Erlang expressions may
  come cheaply, Gleam expressions would need the compiler.
- Conditional breakpoints, logpoints and hit counts. `int` supports
  conditions, so these are good follow-ups.

## What we already know

These findings come from a quick experiment with Gleam 1.12.0 and OTP 25 on a
small sample project.

1. **Gleam's BEAM files can be interpreted by `int`.** Gleam compiles every
   module with `debug_info`, and `int:i(Module)` loads it as long as the
   generated `.erl` file in `build/dev/erlang/<pkg>/_gleam_artefacts/` is
   still there. Breakpoints are hit, `int:meta(Meta, bindings, nostack)`
   returns variables, `step` moves to the next expression and
   `backtrace` returns the call stack.
2. **Breakpoint lines are lines of the generated `.erl` file.** Gleam does
   not produce a source map. The only link back to Gleam is one
   `-file("src/foo.gleam", N).` attribute in front of each function, giving
   the line where the Gleam function starts. Statement-level mapping is our
   job (see step 3).
3. **Variable names are mangled.** `let x = 1` followed by `let x = x + 1`
   becomes `X` and `X@1` in Erlang, and both show up in the bindings.
4. **Values are plain Erlang terms.** A `Person("Ada", 2)` record is the
   tuple `{person, <<"Ada">>, 2}`, `Nil` is the atom `nil`, `Some(x)` is
   `{some, X}`, and strings are binaries.
5. **Gleam errors carry their location.** `panic`, `todo` and failed
   `let assert` raise an `error` whose reason is a map with `gleam_error`,
   `message`, `module`, `function`, `file` and `line` keys, which is enough
   to report an exception at the right `.gleam` line.
6. **Module names:** `src/foo/bar.gleam` compiles to the Erlang module
   `foo@bar`.

## Architecture

```
 Editor (VS Code / IntelliJ)
        │  DAP over stdio (Content-Length framed JSON)
        ▼
 ┌─────────────────────────────── one BEAM VM ───────────────────────────────┐
 │  dap/transport   reads and writes DAP messages                            │
 │  dap/session     request handling and state (OTP actor)                   │
 │  debugger/int    thin FFI wrapper over Erlang's int and meta processes    │
 │  mapping/*       .gleam ↔ .erl line mapping, name demangling, value view  │
 │                                                                           │
 │  user's program  modules interpreted by int, stdout redirected to the     │
 │                  adapter and sent to the editor as DAP "output" events    │
 └───────────────────────────────────────────────────────────────────────────┘
```

- **Same VM as the program**, like ElixirLS. This keeps `int` local and avoids
  distributed Erlang. The catch is that the program's output must not touch
  the adapter's stdout, so the program runs under its own group leader that
  forwards output to the editor.
- **Written in Gleam**, with small Erlang FFI files where we talk to `int`,
  `epp`/`erl_parse`, and group leaders.
- **Shipped as an Erlang shipment** (`gleam export erlang-shipment`), started
  by a small launcher script that the editor runs. Requires Erlang/OTP with
  the `debugger` application installed (on Debian/Ubuntu that is the
  `erlang-debugger` package).

Likely dependencies: `gleam_stdlib`, `gleam_erlang`, `gleam_otp`,
`gleam_json` and `glance` (a Gleam parser written in Gleam, used for line
mapping and for knowing record shapes).

## Step 1: Feasibility spike

Turn the findings above into a small, repeatable proof before building on
them.

- A fixture Gleam project in `test/fixtures/` covering functions, `case`,
  `use`, pipelines, anonymous functions, records, shadowed variables and
  a module in a subdirectory.
- An Erlang/Gleam script that builds the fixture, interprets its modules,
  sets a breakpoint, steps through a function and prints bindings and the
  backtrace at each stop.
- A first experiment with line mapping (step 3) on the fixture, to see how
  well Gleam statements line up with the generated Erlang.
- Check the oldest OTP version we want to support, and whether OTP 26 and 27
  behave the same as OTP 25.

**Done when** the script reliably stops in every interesting construct in the
fixture and we know whether statement-level line mapping is practical or
whether we start with function-level breakpoints.

## Step 2: Core adapter

A working debugger, even if lines and names still
look like Erlang.

**Transport and session**
- Read and write DAP messages on stdio with `Content-Length` framing and JSON
  via `gleam_json`.
- Typed Gleam representations for the requests, responses and events we use.
- An OTP actor holding session state: breakpoints, threads, frame and
  variable references.
- Log adapter internals to a file, never to stdout.

**Requests to support**

| Request | Behaviour |
| --- | --- |
| `initialize` | Report capabilities (no conditional breakpoints yet). |
| `launch` | Run `gleam build`, add `build/dev/erlang/*/ebin` to the code path, interpret the project's own modules (dependencies opt-in via a launch option), then spawn `<module>:main()`. |
| `setBreakpoints` | Translate `.gleam` lines to `.erl` lines (identity or function start until step 3) and call `int:break/2`. Report each breakpoint as verified or not. |
| `configurationDone` | Start the program. |
| `threads` | One thread per interpreted process, from `int:snapshot/0`. |
| `stackTrace` | From the meta process's backtrace. |
| `scopes` / `variables` | Locals from `int:meta(Meta, bindings, nostack)`; tuples, lists and maps expand into children. |
| `continue`, `next`, `stepIn`, `stepOut`, `pause` | `int:meta/2` with `continue`, `next`, `step`, `finish`; pause via a temporary breakpoint or `int:attach`. |
| `disconnect` / `terminate` | Stop the program, clear breakpoints, exit cleanly. |

**Events:** `initialized`, `stopped` (breakpoint, step, exception), `output`,
`thread` (started and exited), `exited` and `terminated`. We use
`int:auto_attach([break], ...)` so every process that hits a breakpoint gets a
meta process that reports to the session.

**Done when** VS Code, configured by hand, can debug the fixture project end to
end. This is the point where the pull request with working code opens.

## Step 3: Make it feel like Gleam

**Line mapping (`.gleam` ↔ `.erl`)**
- For each module, parse the Gleam source with `glance` and the generated
  `.erl` with `epp`/`erl_parse` (through FFI).
- Pair functions using the `-file` attributes and function names.
- Walk both function bodies together to pair each Gleam statement or
  expression with its Erlang counterpart, producing a table in both
  directions.
- Where the walk cannot match something, fall back to the start of the
  enclosing function and mark the breakpoint as moved, so the editor shows
  where it really is.
- Cache mappings per module and rebuild them when the `.erl` file changes.

**Names**
- `X@1` → `x`, `My_var` → `my_var`.
- When a variable is shadowed, show only the latest binding by default, with
  older ones in a collapsed "shadowed" group.
- Hide compiler temporaries such as `_pipe` and `_use0`, or group them.

**Values**
- Learn custom types (constructor names, labels, field order) from the
  `glance` parse of each module.
- Show `Person(name: "Ada", age: 2)` instead of `{person, <<"Ada">>, 2}`.
- Built-ins: `String`, `List`, `Nil`, `Bool`, `Option`, `Result`, `Dict`,
  tuples, `BitArray`, functions shown by name and arity.
- Fall back to Erlang notation for anything we cannot type.

**Stack frames and exceptions**
- Stack frames show the Gleam module (`foo/bar`) and function name and the
  mapped `.gleam` line.
- Stop on uncaught Gleam errors (`panic`, `todo`, `let assert`) using the
  error map's `file` and `line`, and show the message.

**Stepping**
- Skip over code that has no Gleam counterpart, so one "step over" moves one
  Gleam line.
- Step out of non-interpreted modules (dependencies, OTP) instead of getting
  stuck.

**Done when** debugging the fixture feels like debugging Gleam: breakpoints
land where they were set, steps move line by line in the `.gleam` file, and
variables look like Gleam values.

## Step 4: Editor setup

**VS Code**
- A minimal extension in `editors/vscode/` that registers a `gleam` debug
  type, provides a default `launch.json` snippet and starts the adapter via
  `DebugAdapterExecutable`.
- Installed from a locally built `.vsix`; no Marketplace publishing.

**IntelliJ (LSP4IJ)**
- A documented DAP server configuration for LSP4IJ: the adapter command,
  `.gleam` file mapping and a launch configuration template. Exported as a
  template in `editors/intellij/` if LSP4IJ supports importing one.

**Documentation**
- README covering prerequisites (Gleam, Erlang/OTP with `debugger`), building
  the adapter, installing it for each editor and a quick tour using an example
  project.
- Known limitations.

**Done when** a fresh checkout can be built and used in both editors by
following the README.

## Testing

- Unit tests (gleeunit) for DAP message framing and JSON codecs, name
  demangling, value rendering and line mapping against the fixture.
- Integration tests that start the adapter, send a scripted DAP session
  (initialize, launch, setBreakpoints, continue, step, variables) and assert
  on the responses and events.
- A CI workflow running both on a recent OTP version.

## Risks and open questions

- **Line mapping quality.** Gleam constructs like `use`, pipelines and
  inlined calls may not line up neatly with the generated Erlang. Function-level
  breakpoints are the fallback; the spike tells us how much we need it.
- **Compiler output changes.** The mapping relies on the shape of Gleam's
  generated Erlang. We pin a tested Gleam version range and keep fixtures to
  catch changes.
- **`int` speed.** Interpreted code is much slower. Interpreting only the
  project's own modules by default keeps this manageable.
- **OTP processes.** Code running inside actors and supervisors should work
  because `int` works per module, but needs testing.
- **Package access.** The Hex package registry is not reachable from the
  current cloud environment, which blocks fetching dependencies there. This
  needs to be allowed before step 2 can be built and tested in the cloud.
