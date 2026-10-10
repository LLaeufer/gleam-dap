# gleam-dap: plan

A debugger for Gleam programs running on the Erlang VM, speaking the
[Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/)
(DAP) so it works in VS Code and in IntelliJ through
[LSP4IJ](https://github.com/redhat-developer/lsp4ij).

This is a personal tool for exploring Gleam more comfortably. It is not
intended for upstreaming.

Detailed plans:

- [docs/line-mapping.md](docs/line-mapping.md): how `.gleam` lines map to
  what the BEAM runs, every approach we considered, and the chosen one.
- [docs/elixirls-features.md](docs/elixirls-features.md): how each feature of
  ElixirLS's debugger works and how we port it.

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
- Gleam versions before 1.19 (see "What we already know").
- The advanced features in step 5: attach, evaluate, conditional
  breakpoints, logpoints, hit counts and function breakpoints.

## What we already know

These findings come from experiments with Gleam 1.12.0, Gleam 1.19.0 and
OTP 25 on small sample projects. Details are in
[docs/line-mapping.md](docs/line-mapping.md).

1. **Gleam's BEAM files can be interpreted by `int`.** Gleam compiles every
   module with `debug_info`. Breakpoints are hit,
   `int:meta(Meta, bindings, nostack)` returns variables, `step` moves to the
   next expression and `backtrace` returns the call stack.
2. **Gleam 1.19 gives us Gleam line numbers for free.** Since v1.19.0
   (released 5 October 2026) Gleam generates Erlang abstract forms instead of
   Erlang source, annotated with the Gleam line of every expression. `int`
   then breaks, steps and reports in `.gleam` lines with no mapping at all.
   Before 1.19 the only link back to Gleam was one `-file` attribute per
   function, and `int` used lines of the generated `.erl` file. We therefore
   **require Gleam ≥ 1.19**, which in turn needs **OTP ≥ 27**.
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
7. **Step over follows tail calls.** `int`'s "next" stops inside a function
   called in tail position, because the call doesn't add a stack level.
   Gleam code is full of tail calls, so the adapter has to correct this.

## Approach: our own adapter on `int` or adapting ElixirLS

The two options are less different than they look. ElixirLS's debug adapter
is itself built on `int`: it calls `:int.ni`, `:int.break`,
`:int.auto_attach`, `:int.meta`, `:int.snapshot` and friends, exactly the API
our own adapter would use. So the real choice is between writing the DAP and
session layer ourselves in Gleam, or taking ElixirLS's existing one (written
in Elixir) and teaching it about Gleam.

What ElixirLS's debug adapter is, as of its `master` in August 2026:

- About 5,500 lines of Elixir in `apps/debug_adapter`, 3,400 of them in one
  `server.ex`. Apache-2.0 licensed, so forking it is fine.
- Supports launch and attach (including remote nodes), line and function
  breakpoints, conditions, hit counts and logpoints, step in/over/out, pause,
  per-process threads, stack traces, variables, evaluate and completions in
  the debug console, and stdout capture.
- Starts programs through Mix: `launch` runs Mix's `compile` and `app.start`
  and then a Mix task. Gleam projects have no Mix project.
- Finds the module for a breakpoint through the `source` recorded in each
  BEAM file. Gleam 1.19 BEAM files record no source at all, so this would
  need replacing.
- Evaluates expressions with `Code.eval_string`, so the debug console speaks
  Elixir.

### The Gleam-specific work is the same either way

Mapping `.gleam` files to modules, fixing stepping over tail calls, demangling `X@1`
into `x`, rendering records and `Option`/`Result` the Gleam way, and reading
Gleam error maps are all needed in both approaches. Neither `int` nor
ElixirLS knows anything about Gleam. Step 3 of this plan is the same amount
of work whichever way we go. The difference is in steps 2 and 4.

### Comparison

| | Own adapter in Gleam on `int` | Adapt ElixirLS's debug adapter |
| --- | --- | --- |
| **Time to first breakpoint** | Slower. The DAP transport, session state, thread and variable bookkeeping need writing (step 2). | Faster for raw DAP features, which already work. But launch has to be rewritten first, because it assumes a Mix project. |
| **Feature set** | Only what we build. Conditions, logpoints, attach and evaluate come later, if at all. | A lot for free: function breakpoints, conditions, hit counts, logpoints, attach to remote nodes, pause, completions. |
| **Fitting Gleam in** | Gleam concepts are built in from the start. Line mapping, names and values sit in the core instead of being bolted on. | Needs changes in many places: breakpoint-to-module lookup, stack frame paths, variable naming and rendering, error reporting. Most of that lives in one large `server.ex`. |
| **Debug console** | No evaluate at first. Erlang evaluation via `erl_eval` is cheap to add later. | Evaluate works, but in Elixir syntax, which is confusing in a Gleam session. Gleam evaluation is hard in both. |
| **Runtime requirements** | Erlang/OTP with `debugger`, which Gleam users already have. | Additionally Elixir and Mix at runtime, plus ElixirLS's own dependencies, which Gleam users may not have installed. |
| **Language of the code** | Gleam, which is the language you want to get better at. | Elixir. |
| **Maintenance** | Small codebase we fully understand. Only `int` and Gleam's compiler output can break it. | A fork of an actively developed project. Pulling in upstream changes means merging into a heavily modified `server.ex`; not merging means the fork slowly goes stale. |
| **Editor integration** | We write a small VS Code extension and an LSP4IJ config. | ElixirLS's VS Code extension is tied to Elixir and the language server, so we would still write our own small extension. LSP4IJ config is the same work either way. |
| **Learning value** | High: DAP, `int` and OTP from the inside. | Lower on the DAP side, higher on reading a mature codebase. |

### Recommendation

Write our own adapter in Gleam on `int`, and use ElixirLS as the reference
implementation rather than as a base.

- The hard and interesting part, making `int` understand Gleam, is the same
  in both approaches, and fits more naturally into a codebase designed around
  it.
- The part ElixirLS saves us, the DAP and session layer, is the most
  mechanical part and is well specified by the protocol.
- Mix coupling, Elixir at runtime and a large fork to maintain cost more than
  the free features are worth for a personal tool.
- ElixirLS is still valuable to read: how it handles `int` edge cases,
  process and thread bookkeeping, output capture, breakpoint conditions and
  attach. When we hit a problem there, we check how it solved it first.

**When adapting ElixirLS would win:** if you want the full feature set
(conditions, logpoints, attach) soon, and don't mind Elixir and Mix being
installed.

**Decision:** our own adapter, with ElixirLS as the reference (decided
10 October 2026). How each ElixirLS feature carries over is in
[docs/elixirls-features.md](docs/elixirls-features.md).

## Architecture

```
 Editor (VS Code / IntelliJ)
        │  DAP over stdio (Content-Length framed JSON)
        ▼
 ┌─────────────────────────────── one BEAM VM ───────────────────────────────┐
 │  dap/transport   reads and writes DAP messages                            │
 │  dap/session     request handling and state (OTP actor)                   │
 │  debugger/int    thin FFI wrapper over Erlang's int and meta processes    │
 │  gleam/*         module ↔ file index, names, values, stepping fixes       │
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
  `beam_lib`, and group leaders.
- **Shipped as an Erlang shipment** (`gleam export erlang-shipment`), started
  by a small launcher script that the editor runs. Requires Erlang/OTP with
  the `debugger` application installed (on Debian/Ubuntu that is the
  `erlang-debugger` package).

Likely dependencies: `gleam_stdlib`, `gleam_erlang`, `gleam_otp` and
`gleam_json`, plus possibly `glance` (a Gleam parser written in Gleam) for
reading custom type definitions. The adapter must never interpret the
modules it uses itself (see the feature plan).

## Step 1: Feasibility spike

Turn the findings above into a small, repeatable proof before building on
them.

- A fixture Gleam project in `test/fixtures/` covering functions, `case`,
  `use`, pipelines, anonymous functions, records, shadowed variables and
  a module in a subdirectory.
- An Erlang/Gleam script that builds the fixture, interprets its modules,
  sets a breakpoint, steps through a function and prints bindings and the
  backtrace at each stop.
- Run it with Gleam 1.19 on OTP 27 and 28. Our experiments ran Gleam 1.19's
  abstract forms on OTP 25, because Gleam 1.19's own build needs OTP 27.
- Golden files of each fixture module's breakable lines, so a compiler change
  shows up as a test diff.

**Done when** the script reliably stops on the right `.gleam` line in every
interesting construct in the fixture, on OTP 27 and 28.

## Step 2: Core adapter

A working debugger, even if names and values still look like Erlang. The
details of each request, and what we take from ElixirLS, are in
[docs/elixirls-features.md](docs/elixirls-features.md).

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
| `launch` | Check Gleam and OTP versions, run `gleam build`, add `build/dev/erlang/*/ebin` to the code path, build the module ↔ file index and interpret the project's own modules (dependencies opt-in via a launch option). |
| `setBreakpoints` / `breakpointLocations` | Map the file to its module and call `int:break/2` on the Gleam line, moving breakpoints on lines without code to the next line that has some. |
| `configurationDone` | Start the program with `<module>:main()`. |
| `threads` | Interpreted processes from `int:snapshot/0` plus the program's own processes, not the adapter's. |
| `stackTrace` | From the meta process's backtrace, read outside the session actor with a timeout. |
| `scopes` / `variables` | Locals from `int:meta(Meta, bindings, nostack)`; tuples, lists and maps expand into children. |
| `continue`, `next`, `stepIn`, `stepOut` | `int:continue/1`, `next/1`, `step/1`, `finish/1`, with step over corrected for tail calls. |
| `disconnect` / `terminate` | Stop the program, clear breakpoints, exit cleanly. |

**Events:** `initialized`, `stopped` (breakpoint, step), `output`, `thread`
(started and exited), `exited` and `terminated`. Like ElixirLS, we use
`int:auto_attach([break], ...)` with a callback that only notifies the
session, so every stop is reported without attaching to processes.

**Done when** VS Code, configured by hand, can debug the fixture project end to
end. This is the point where the pull request with working code opens.

## Step 3: Make it feel like Gleam

Line numbers are already right with Gleam 1.19, so this step is about names,
values, stack frames and errors. See
[docs/line-mapping.md](docs/line-mapping.md) for the line-related details
and [docs/elixirls-features.md](docs/elixirls-features.md) for the rest.

**Names**
- `X@1` → `x`, `My_var` → `my_var`.
- When a variable is shadowed, show only the latest binding by default, with
  older ones in a collapsed "shadowed" group.
- Hide compiler temporaries such as `_pipe` and `_use0`, or group them.

**Values**
- Learn custom types (constructor names, labels, field order) from the
  record headers Gleam generates or from parsing each module's source.
- Show `Person(name: "Ada", age: 2)` instead of `{person, <<"Ada">>, 2}`.
- Built-ins: `String`, `List`, `Nil`, `Bool`, `Option`, `Result`, `Dict`,
  tuples, `BitArray`, functions shown by name and arity.
- Fall back to Erlang notation for anything we cannot type.

**Stack frames, errors and pause**
- Stack frames show the Gleam module (`foo/bar`) and function name, and
  anonymous functions as "anonymous function in `name`".
- Stop on uncaught Gleam errors (`panic`, `todo`, `let assert`) using
  `int:auto_attach([exit], ...)` and the error map's `file`, `line` and
  message.
- `pause` that really suspends the process, through `int:meta(Meta, stop)`.

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

## Step 5: Advanced features

The rest of ElixirLS's feature set, in roughly this order. Each is described
in [docs/elixirls-features.md](docs/elixirls-features.md).

- Function breakpoints (`app/user.greet/1`) through `int:break_in/3`.
- Conditional breakpoints, hit counts and logpoints through
  `int:test_at_break/3`, with Erlang expressions at first.
- Evaluate in the debug console, watch and hover: variable and field lookups
  first, then Erlang expressions.
- Completions for variable, module and function names.
- Attach to a running node.
- Terminate single threads and cancel slow requests.
- A `debug.break()` function to stop from code.

**Done when** each feature works in both editors against the fixture.

## Testing

- Unit tests (gleeunit) for DAP message framing and JSON codecs, name
  demangling, value rendering and line mapping against the fixture.
- Integration tests that start the adapter, send a scripted DAP session
  (initialize, launch, setBreakpoints, continue, step, variables) and assert
  on the responses and events.
- A CI workflow running both on a recent OTP version.

## Risks and open questions

- **Depending on Gleam 1.19.** Line numbers rely on the abstract forms
  Gleam has generated since 1.19 and on OTP 27 or newer. Older Gleam versions
  would need one of the mapping approaches in
  [docs/line-mapping.md](docs/line-mapping.md).
- **Compiler output changes.** Names, values and stepping fixes rely on the
  shape of Gleam's generated code (`X@1`, `_pipe`, tuples for records). We pin
  a tested Gleam version range and keep fixtures to catch changes.
- **`int` speed.** Interpreted code is much slower. Interpreting only the
  project's own modules by default keeps this manageable.
- **OTP processes.** Code running inside actors and supervisors should work
  because `int` works per module, but needs testing.
- **Package access.** The Hex package registry is not reachable from the
  current cloud environment, which blocks fetching dependencies there. This
  needs to be allowed before step 2 can be built and tested in the cloud.
